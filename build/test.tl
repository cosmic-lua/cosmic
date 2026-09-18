--- Runs every test the tree defines, in-process, and records each
--- verdict into `o/records.db`, a database of its own that never ships
--- and is never attached to `o/cosmic.db`.
---
--- A `local function test_*` at the top level of a `kind = "test"`
--- module is otherwise unreachable from outside the file it sits in:
--- `build.importer` appends a generated `return { test_foo = test_foo,
--- ... }` to the module's COMPILED Lua, using the same names discovery
--- already found, so `require`ing the module hands this runner every
--- test as a table entry. The Teal source a test's author wrote is
--- never touched.
---
--- A test function receives one argument: the path of a fresh,
--- writable directory `Fs.mkdtemp` made just for it, which the runner
--- does not remove afterward, so a failing test's own files stay
--- around to look at. A test that ignores the argument -- the ordinary
--- shape, a bare `assert()` -- is called with it anyway, and Lua drops
--- an argument nobody asked for.
---
--- Every file `cosmic.fs` opens goes through `cosmic.sys`'s shared
--- `open` field, so wrapping it for the duration of one test's call
--- records every path that test caused to be opened, on every caller's
--- behalf, without any of them knowing. `pcall` around the call means
--- control always comes back here -- pass, fail, or an unrelated Lua
--- error -- so the original is always put back before the next test.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local importer = require("build.importer")
local payload = require("build.payload")
local records_schema = require("build.records_schema")
local teal = require("build.teal")
local writer = require("build.writer")

local record test
end

local function report(line: string)
  Fs.put(Fs.stdout, line .. "\n")
end

local function complain(line: string)
  Fs.put(Fs.stderr, "cosmic: " .. line .. "\n")
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- Opens `o/records.db`, creating its one table when the file is new.
local function open_records(path: string): Sqlite.Handle | nil, string
  local handle, trouble = Sqlite.open(path, true)
  if handle == nil then
    return nil, trouble
  end
  for _, statement in ipairs(records_schema.settings) do
    handle:exec(statement)
  end
  for _, statement in ipairs(records_schema.tables) do
    local ok, failure = handle:exec(statement)
    if not ok then
      handle:close()
      return nil, failure
    end
  end
  return handle
end

local function record_run(handle: Sqlite.Handle, path: string, name: string,
                          passed: boolean, message: string, ran_at_ns: integer,
                          reads: {string}): boolean, string
  return Sqlite.run(handle,
    "INSERT OR REPLACE INTO runs (path, test, passed, message, ran_at_ns, " ..
    "reads) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    { text(path), text(name), { integer = passed and 1 or 0 }, text(message),
      { integer = ran_at_ns }, text(table.concat(reads, "\n")) })
end

--- Calls one test function with a fresh temporary directory as its one
--- argument, through `pcall`, and reports what it observed opening.
local function call_test(fn: function(any...): (any...)): boolean, string, {string}
  local tmp, tmp_trouble = Fs.mkdtemp("cosmic-test-")
  if tmp == nil then
    return false, "could not make a temporary directory: " .. tmp_trouble, {}
  end
  local reads: {string} = {}
  local original = sys.open
  sys.open = function(path: string, flags: integer,
                      mode?: integer): integer | nil, string, integer
    reads[#reads + 1] = path
    return original(path, flags, mode)
  end
  local ok, failure = pcall(fn, tmp)
  sys.open = original
  if ok then
    return true, "", reads
  end
  return false, tostring(failure), reads
end

--- Runs every test one `kind = "test"` module found, recording each
--- into `records` and appending a line to `failures` for any that did
--- not pass. Returns how many tests it ran.
local function run_module(records: Sqlite.Handle, m: importer.Module,
                          failures: {string}): integer
  local ok, produced = pcall(require, m.path)
  if not ok then
    local message = "the module failed to load: " .. tostring(produced)
    for _, name in ipairs(m.tests) do
      failures[#failures + 1] = m.path .. " " .. name .. ": " .. message
      record_run(records, m.path, name, false, message, Time.now_ns() or 0, {})
    end
    return #m.tests
  end
  local mod = produced as {string:any}
  for _, name in ipairs(m.tests) do
    local fn = mod[name] as function(any...): (any...)
    local passed, message, reads = call_test(fn)
    record_run(records, m.path, name, passed, message, Time.now_ns() or 0, reads)
    if not passed then
      failures[#failures + 1] = m.path .. " " .. name .. ": " .. message
    end
  end
  return #m.tests
end

--- Builds the tree in the working directory and runs every test it
--- discovered, printing a verdict line and returning the exit code: 0
--- when every test passed.
function test.run(): integer
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    complain(root_trouble)
    return 1
  end

  -- Same staleness guard `cosmic <file.tl>` applies when the tree under
  -- test is cosmic's own: a stale tool would check and compile it with
  -- a checker or patch set the tree no longer agrees with.
  if importer.is_own_tree(root) then
    local current, hash_trouble = importer.boot_hash(root)
    if current == nil then
      complain(hash_trouble)
      return 1
    end
    local running = Store.meta("boot_hash") or ""
    if current ~= running then
      complain("the tool is stale; run bin/zig build boot")
      return 3
    end
  end

  local built, load_trouble = teal.load()
  if built == nil then
    complain(load_trouble)
    return 1
  end
  local env, env_trouble = teal.environment_for(built, root)
  if env == nil then
    complain(env_trouble)
    return 1
  end

  local made, mkdir_trouble = Fs.mkdirs(root .. "/o")
  if not made then
    complain(mkdir_trouble)
    return 1
  end

  local boot_hash = Store.meta("boot_hash") or ""
  local database = root .. "/o/cosmic.db"
  local images, teal_source, carry_trouble = payload.carried(database)
  if carry_trouble ~= "" then
    complain(carry_trouble)
    return 1
  end

  local result, compile_trouble = importer.compile(root, built, env, boot_hash)
  if result == nil then
    complain(compile_trouble)
    return 1
  end
  local written, write_trouble =
    writer.write_result(database, result, images, teal_source)
  if not written then
    complain(write_trouble)
    return 1
  end

  local attached, attach_trouble = Store.attach(database)
  if not attached then
    complain(attach_trouble)
    return 1
  end

  local records_path = root .. "/o/records.db"
  local records, records_trouble = open_records(records_path)
  if records == nil then
    complain(records_path .. ": " .. records_trouble)
    return 1
  end

  local total = 0
  local modules_run = 0
  local failures: {string} = {}
  for _, m in ipairs(result.modules) do
    if m.kind == "test" and #m.tests > 0 then
      modules_run = modules_run + 1
      total = total + run_module(records, m, failures)
    end
  end
  records:close()

  -- A module `importer.compile` refused ran no tests at all; every
  -- other module still compiled and ran above, so this only turns the
  -- overall verdict to FAIL, one line per refusal, rather than aborting
  -- the whole run the way an unrelated compile error still does.
  for _, line in ipairs(result.refused) do
    failures[#failures + 1] = line
  end

  if #failures == 0 then
    report("test: PASS (" .. total .. " tests, " .. modules_run .. " modules)")
    return 0
  end
  for _, line in ipairs(failures) do
    report("test: FAIL  " .. line)
  end
  report("test: FAIL (" .. #failures .. " of " ..
    (total + #result.refused) .. " failed)")
  return 1
end

return test
