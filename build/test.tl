--- Runs every test the tree defines, in-process, and records each
--- verdict into the working database, `o/build.db`, which never ships
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

local Coverage = require("cosmic.coverage")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local coverage_report = require("build.coverage.report")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")
local type compiler = require("build.compiler")

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

local function elapsed_ms(from: integer): integer
  local now = Time.monotonic_ns()
  if now == nil then
    return 0
  end
  return (now - from) // 1000000
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

--- Every line `build.coverage.report` found for every non-vendor module
--- `modules` holds, added as a new snapshot for `run_at_ns`: nothing in
--- `test_runs`/`coverage`/`coverage_by_test` is ever deleted, so a
--- file's coverage trend over many runs is a plain query away rather
--- than only the latest run's numbers. Also writes, for every test
--- that ran, which of the lines it hit into `coverage_by_test`, tagged
--- with that test's own identity (`by_test`, keyed by "path name" the
--- same way a failure line already identifies a test elsewhere in this
--- file). Returns the overall hit and executable-line counts, over
--- every module written for this run, for the run's own verdict line.
local function write_coverage(handle: Sqlite.Handle, built: compiler,
                              modules: {importer.Module},
                              hits: Coverage.Hits,
                              by_test: {string: Coverage.Hits},
                              run_at_ns: integer): integer, integer, string
  local total_hit = 0
  local total_lines = 0
  local made, trouble = Sqlite.transact(handle, function(): boolean, string
    local recorded, run_trouble = Sqlite.run(handle,
      "INSERT OR REPLACE INTO test_runs (ran_at_ns) VALUES (?1)",
      { { integer = run_at_ns } })
    if not recorded then
      return false, run_trouble
    end
    for _, m in ipairs(modules) do
      if m.kind ~= "vendor" then
        local per_line, line_trouble = coverage_report.lines_of(built, m, hits)
        if per_line == nil then
          return false, m.file .. ": " .. line_trouble
        end
        for line, was_hit in pairs(per_line) do
          local ok, write_trouble = Sqlite.run(handle,
            "INSERT INTO coverage (ran_at_ns, path, line, hit) " ..
            "VALUES (?1, ?2, ?3, ?4)",
            { { integer = run_at_ns }, text(m.path), { integer = line },
              { integer = was_hit and 1 or 0 } })
          if not ok then
            return false, write_trouble
          end
          total_lines = total_lines + 1
          if was_hit then
            total_hit = total_hit + 1
          end
        end
      end
    end
    for test_name, test_hits in pairs(by_test) do
      for path, per_line in pairs(test_hits) do
        for line in pairs(per_line) do
          local ok, write_trouble = Sqlite.run(handle,
            "INSERT INTO coverage_by_test (ran_at_ns, path, line, test) " ..
            "VALUES (?1, ?2, ?3, ?4)",
            { { integer = run_at_ns }, text(path), { integer = line },
              text(test_name) })
          if not ok then
            return false, write_trouble
          end
        end
      end
    end
    return true, ""
  end)
  if not made then
    return 0, 0, trouble
  end
  return total_hit, total_lines, ""
end

--- Folds every line `from` holds into `into`, both keyed by module
--- import path then line number -- the shape one test's or one
--- module-load's own coverage window hands back. Used to build the
--- whole-run accumulator up one small window's worth at a time.
local function merge_hits(into: Coverage.Hits, from: Coverage.Hits)
  for path, per_line in pairs(from) do
    local existing = into[path]
    if existing == nil then
      existing = {}
      into[path] = existing
    end
    for line in pairs(per_line) do
      existing[line] = true
    end
  end
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
--- not pass. Every hit line, from this module's own one-time load and
--- from each test in it, is folded into `hits`, the whole-run
--- accumulator; a test's own hits are additionally kept in `by_test`,
--- keyed by that test's own identity, so `write_coverage` can credit
--- specific lines to specific tests. Returns how many tests it ran.
local function run_module(records: Sqlite.Handle, m: importer.Module,
                          failures: {string}, errors: {string}, hits: Coverage.Hits,
                          by_test: {string: Coverage.Hits}): integer
  -- A module's own top-level code -- `local record X ... end`, `local Y
  -- = require(...)` and the like -- runs exactly once, right here, at
  -- first require, not once per test below. Left outside every
  -- coverage window, it would run in the gap between one test's window
  -- and the next and never be recorded as hit at all -- silently
  -- deflating the aggregate percentage. Folded into `hits` like any
  -- other window's hits; not attributed to `by_test`, since there is no
  -- single test to credit module-load code to.
  local module_session, module_start_trouble = Coverage.start()
  if module_session == nil then
    errors[#errors + 1] = m.path .. ": coverage start: " .. module_start_trouble
  end
  local ok, produced = pcall(require, m.path)
  if module_session ~= nil then
    local collected, stop_trouble = Coverage.stop(module_session)
    if collected == nil then
      errors[#errors + 1] = m.path .. ": coverage stop: " .. stop_trouble
    else
      merge_hits(hits, collected)
    end
  end
  if not ok then
    local message = "the module failed to load: " .. tostring(produced)
    for _, name in ipairs(m.tests) do
      failures[#failures + 1] = m.path .. " " .. name .. ": " .. message
      local saved, trouble =
        record_run(records, m.path, name, false, message, Time.now_ns() or 0, {})
      if not saved then
        errors[#errors + 1] = m.path .. " " .. name .. ": record: " .. trouble
      end
    end
    return #m.tests
  end
  local mod = produced as {string:any}
  for _, name in ipairs(m.tests) do
    local fn = mod[name] as function(any...): (any...)
    local test_session, test_start_trouble = Coverage.start()
    if test_session == nil then
      errors[#errors + 1] = m.path .. " " .. name .. ": coverage start: " .. test_start_trouble
    end
    local passed, message, reads = call_test(fn)
    if test_session ~= nil then
      local collected, stop_trouble = Coverage.stop(test_session)
      if collected == nil then
        errors[#errors + 1] = m.path .. " " .. name .. ": coverage stop: " .. stop_trouble
      else
        merge_hits(hits, collected)
        by_test[m.path .. " " .. name] = collected
      end
    end
    local saved, trouble =
      record_run(records, m.path, name, passed, message, Time.now_ns() or 0, reads)
    if not saved then
      errors[#errors + 1] = m.path .. " " .. name .. ": record: " .. trouble
    end
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
  -- Captured once, up front, and threaded through everything below as
  -- this run's own identifier: see build/work.tl for why a nanosecond
  -- timestamp, not an autoincrement id, identifies a run.
  local run_at_ns = Time.now_ns() or 0

  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    complain(root_trouble)
    return 1
  end
  local started = Time.monotonic_ns() or 0
  local own_tree = importer.is_own_tree(root)
  local handle, open_trouble = work.open(root)
  if handle == nil then
    complain(open_trouble)
    return 1
  end
  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    work.close(handle)
    complain(stage_trouble)
    return 1
  end

  -- Same staleness guard `cosmic <file.tl>` applies when the tree under
  -- test is cosmic's own: a stale tool would check and compile it with
  -- a checker or patch set the tree no longer agrees with, and could
  -- execute embedded cosmic.* implementations and tests from an old tree.
  if own_tree then
    local current, hash_trouble = work.boot_hash(handle)
    if current == nil then
      work.close(handle)
      complain(hash_trouble)
      return 1
    end
    local running = Store.meta("boot_hash") or ""
    if current ~= running then
      work.close(handle)
      complain("the tool is stale; run bin/zig build boot")
      return 3
    end
  end

  local built, load_trouble = teal.load()
  if built == nil then
    work.close(handle)
    complain(load_trouble)
    return 1
  end
  local env, env_trouble = teal.environment_for(built, handle)
  if env == nil then
    work.close(handle)
    complain(env_trouble)
    return 1
  end

  local boot_hash = Store.meta("boot_hash") or ""
  local database = root .. "/o/cosmic.db"

  local result, compile_trouble = importer.compile(handle, built, env, boot_hash)
  if result == nil then
    work.record(handle, elapsed_ms(started), staged, 0, 0, "FAIL")
    work.close(handle)
    complain(compile_trouble)
    return 1
  end
  local written, write_trouble =
    writer.write_result(handle, database, result)
  work.record(handle, elapsed_ms(started), staged, result.compiled,
    result.cached, written and "PASS" or "FAIL")
  if not written then
    work.close(handle)
    complain(write_trouble)
    return 1
  end
  report("build: " .. #result.modules .. " modules (" .. result.compiled ..
    " compiled, " .. result.cached .. " cached; " .. staged.files ..
    " files staged, " .. staged.read .. " read) in " ..
    elapsed_ms(started) .. " ms")

  local attached, attach_trouble = Store.attach(database)
  if not attached then
    work.close(handle)
    complain(attach_trouble)
    return 1
  end

  local records_path = root .. "/o/build.db"
  local records = handle.db

  local total = 0
  local modules_run = 0
  local failures: {string} = {}
  local errors: {string} = {}
  -- One collection window per test, not one for the whole run: each
  -- `start`/`stop` pair is a handful of cheap C calls (core/coverage.c),
  -- and the real cost is proportional to lines executed, not to how
  -- many times the hook toggles on and off, so this is not meaningfully
  -- slower than the one-window-per-run design it replaces. What it buys
  -- is attribution: a window scoped to exactly one test's own execution
  -- means the hits it collects can be credited to that test by name,
  -- which one continuous whole-suite window never could. The session
  -- each `start` hands back is what keeps a window its own opener's:
  -- an ordinary test elsewhere in the tree that also calls
  -- `start`/`stop` cannot reset or end a window it did not open, since
  -- it never has that same session value.
  local hits: Coverage.Hits = {}
  local by_test: {string: Coverage.Hits} = {}
  for _, m in ipairs(result.modules) do
    if m.kind == "test" and #m.tests > 0 then
      modules_run = modules_run + 1
      total = total + run_module(records, m, failures, errors, hits, by_test)
    end
  end

  local cov_hit, cov_total, cov_trouble =
    write_coverage(records, built, result.modules, hits, by_test, run_at_ns)
  if cov_trouble ~= "" then
    errors[#errors + 1] = "coverage: " .. cov_trouble
  end
  local closed, close_trouble = work.close(handle)
  if not closed then
    errors[#errors + 1] = "close: " .. close_trouble
  end

  -- A module `importer.compile` refused ran no tests at all; every
  -- other module still compiled and ran above, so this only turns the
  -- overall verdict to FAIL, one line per refusal, rather than aborting
  -- the whole run the way an unrelated compile error still does.
  for _, line in ipairs(result.refused) do
    failures[#failures + 1] = line
  end

  local cov_pct = cov_total > 0 and (cov_hit * 100.0 / cov_total) or 0.0
  local cov_line = string.format("test: coverage %.1f%% (%d/%d lines)",
    cov_pct, cov_hit, cov_total)

  if #failures == 0 and #errors == 0 then
    report("test: PASS (" .. total .. " tests, " .. modules_run .. " modules)")
    report(cov_line)
    return 0
  end
  for _, line in ipairs(failures) do
    report("test: FAIL  " .. line)
  end
  for _, line in ipairs(errors) do
    report("test: ERROR  " .. records_path .. ": " .. line)
  end
  report("test: FAIL (" .. #failures .. " of " ..
    (total + #result.refused) .. " failed, " .. #errors .. " infrastructure errors)")
  if #errors == 0 then
    report(cov_line)
  end
  return 1
end

return test
