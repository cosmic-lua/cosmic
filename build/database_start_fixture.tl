--- What core/database_start_test.tl and core/database_start_sandbox_test.tl
--- share: fixture databases built with the tree's own schema, a bare core
--- started against one past its launcher, and the lines a program of
--- theirs prints. Test support.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local schema = require("build.schema")
local this_program = require("build.this_program")

local record database_start_fixture
  --- A module of a fixture database: Lua source, compiled to the
  --- bytecode the store loads, and the names it requires.
  record Module
    name: string
    kind: string
    source: string
    requires: {string}
  end

  --- What a fixture database records of itself.
  record Made
    --- The program the database names as `main`; nil for none.
    main: string
    --- The digest of the core it was written for; nil for none.
    core: string
    --- Whether it carries the standard library modules its programs load.
    library: boolean
  end
end

local type Module = database_start_fixture.Module
local type Made = database_start_fixture.Made

local function text(value: string): Sqlite.Value
  return { text = value }
end

local function blob(value: string): Sqlite.Value
  return { blob = value }
end

--- The modules `roots` need and the names each requires, from the rows
--- the running binary carries, for a program that loads the same
--- libraries this test does: [`Store.requires`] and [`Store.bytecode`]
--- answer for a module this test's closure holds.
local function closure(roots: {string}): {Module}, {string:string}
  local found: {Module} = {}
  local bytecode: {string:string} = {}
  local seen: {string:boolean} = {}
  local function visit(name: string)
    if seen[name] then return end
    seen[name] = true
    local code, _ = Store.bytecode(name)
    if code == nil then return end
    local requires = assert(Store.requires(name))
    bytecode[name] = code
    found[#found + 1] = { name = name, kind = "module", source = "", requires = requires }
    for _, required in ipairs(requires) do visit(required) end
  end
  for _, root in ipairs(roots) do visit(root) end
  return found, bytecode
end

local LIBRARY <const> = { "cosmic.store", "cosmic.proc", "cosmic.child", "cosmic.sys", "cosmic.fs" }

--- Writes the database at `path` holding `modules`, the library they
--- load when `made.library`, and the meta rows `made` says.
function database_start_fixture.write_database(path: string, modules: {Module}, made: Made)
  local _, _ = Fs.remove(path)
  local db = assert(Sqlite.open(path, { writable = true }))
  for _, statement in ipairs(schema.create("")) do assert(db:exec(statement)) end
  local rows: {Module} = {}
  local bytecode: {string:string} = {}
  if made.library then
    local library, codes = closure(LIBRARY)
    for _, module in ipairs(library) do rows[#rows + 1] = module end
    for name, code in pairs(codes) do bytecode[name] = code end
  end
  for _, module in ipairs(modules) do
    rows[#rows + 1] = module
    local chunk = assert(load(module.source, "=" .. module.name))
    bytecode[module.name] = string.dump(chunk, true)
  end
  for _, module in ipairs(rows) do
    assert(Sqlite.run(db, "INSERT INTO modules (path, file, kind, source_hash, key, bytecode, " ..
        "tests, source) VALUES (?1, ?2, ?3, X'', X'', ?4, '', X'')",
      { text(module.name), text(module.name), text(module.kind), blob(bytecode[module.name]) }))
    for _, required in ipairs(module.requires) do
      assert(Sqlite.run(db, "INSERT OR IGNORE INTO imports (path, requires) VALUES (?1, ?2)",
        { text(module.name), text(required) }))
    end
  end
  local meta: {{string}} = { { "runtime_basis", "fixture-basis" } }
  if made.main ~= nil then meta[#meta + 1] = { "main", made.main } end
  if made.core ~= nil then meta[#meta + 1] = { "core_sha256", made.core } end
  for _, pair in ipairs(meta) do
    assert(Sqlite.run(db, "INSERT INTO meta (key, value) VALUES (?1, ?2)",
      { text(pair[1]), text(pair[2]) }))
  end
  assert(db:close())
end

--- The digest of the core the tests start, which a database it can run
--- against records.
function database_start_fixture.core_digest(): string
  return (assert(Store.meta("host_image"), "this process has no core digest to record"))
end

--- The core to start bare, or nil where this process has none to relaunch
--- (a host program, which a bare core is not).
function database_start_fixture.core_path(): string | nil
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return nil end
  return relaunch.argv[1]
end

--- The environment a bare core is started with: this program's own, less
--- the variables of the portable startup's own tests.
function database_start_fixture.environment(): {string:string}
  local env = this_program.environment()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  env.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  return env
end

function database_start_fixture.run(argv: {string}): Child.Result
  return (assert(Child.run(argv, { env = database_start_fixture.environment(), stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(30) })))
end

--- The program's output as the lines `name<TAB>value` it prints.
function database_start_fixture.fields(output: string): {string:string}
  local out: {string:string} = {}
  for line in output:gmatch("([^\n]*)\n") do
    local name, value = line:match("^([^\t]+)\t(.*)$")
    if name ~= nil then out[name] = value end
  end
  return out
end

--- A program that reports what it runs against.
local INFO <const> = [==[
local Store = require("cosmic.store")
local Proc = require("cosmic.proc")
local Child = require("cosmic.child")
local function say(name, value) print(name .. "\t" .. tostring(value)) end
return function(args)
  if args[1] == "child" then
    say("child_databases", #Store.databases())
    say("child_main", Store.meta("main"))
    say("child_args", table.concat(args, "|"))
    return 0
  end
  local relaunch = assert(Proc.relaunch())
  say("arg0", args[0])
  say("args", table.concat(args, "|"))
  say("databases", #Store.databases())
  say("main", Store.meta("main"))
  say("context", Store.meta("runtime_context"))
  say("host_image", Store.meta("host_image"))
  say("runtime", Store.meta("runtime") ~= nil)
  say("artifact", Store.meta("artifact"))
  say("executable", Proc.executable())
  say("relaunch", table.concat(relaunch.argv, "|"))
  say("relaunch_env", next(relaunch.env) == nil)
  say("relaunch_fds", next(relaunch.fds) == nil)
  if args[1] == "sandboxed" then
    -- This program's own file is the core, which the profile grants.
    local result, why = Child.run({ Proc.executable(), "child", "z" },
      { policy = { profiles = { "cosmic" } }, stdout = "capture", stderr = "capture" })
    if result == nil then
      say("sandbox_refused", why)
    else
      say("child_code", result.code)
      say("child_stderr", result.stderr)
      print(result.stdout)
    end
  end
  if args[1] == "spawn" then
    local argv = {}
    for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
    argv[#argv + 1] = "child"
    argv[#argv + 1] = "x y"
    local result = assert(Child.run(argv, { env = relaunch.env, fds = relaunch.fds,
      cwd = relaunch.cwd, stdout = "capture", stderr = "capture" }))
    say("child_code", result.code)
    say("child_stderr", result.stderr)
    print(result.stdout)
  end
  return 0
end
]==]

function database_start_fixture.info_module(): Module
  return { name = "probe.main", kind = "main", source = INFO, requires = LIBRARY }
end

--- The path of a database the test makes, running `INFO`.
function database_start_fixture.info_database(tmp: string, name?: string): string
  local path = tmp .. "/" .. (name or "program.db")
  database_start_fixture.write_database(path, { database_start_fixture.info_module() },
    { main = "probe.main", core = database_start_fixture.core_digest(), library = true })
  return path
end

return database_start_fixture
