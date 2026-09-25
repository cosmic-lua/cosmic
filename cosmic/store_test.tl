local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

local function test_attaching_a_missing_database_fails(tmp: string)
  local path = tmp .. "/missing.db"
  local ok, trouble = Store.attach(path)
  assert(not ok, "attached a database that does not exist")
  assert(trouble:sub(1, #path + 2) == path .. ": ", trouble)
end

--- Run standalone, where the binary's own database is the only one
--- searched: every module there the searcher hands a raw value is a
--- wrapper the core grants one. A project database then attached holds
--- an impostor under each of those names and under one ordinary
--- `build.*` module; each wrapper must still come from the binary with
--- its raw value, and the ordinary one from the project.
local shadowing <const> = [[
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")

local type Searcher = function(string): any, any

return function(argv: {string}): integer
  local search = package.searchers[#package.searchers] as Searcher
  local binary = assert(Store.databases()[1])
  local wrappers: {string} = {}
  local ordinary: string = nil
  for _, row in ipairs((assert(Sqlite.text_rows(binary,
      "SELECT path FROM modules WHERE kind = 'module' ORDER BY path")))) do
    local name = row[1]
    local _, extra = search(name)
    if extra is table then
      table.insert(wrappers, name)
    elseif ordinary == nil and name:sub(1, 6) == "build." then
      ordinary = name
    end
  end
  assert(ordinary ~= nil, "no ordinary build.* module to compare")

  local db = assert(Sqlite.open(argv[1], true))
  assert(db:exec("CREATE TABLE modules (path TEXT, bytecode BLOB, " ..
    "kind TEXT, source TEXT, file TEXT); CREATE TABLE meta (key TEXT, value TEXT)"))
  local impostor = string.dump((assert(load("return 'impostor'"))))
  local names: {string} = { ordinary }
  for _, name in ipairs(wrappers) do table.insert(names, name) end
  for _, name in ipairs(names) do
    assert(Sqlite.run(db, "INSERT INTO modules (path, bytecode, kind) VALUES (?1, ?2, 'module')",
      { { text = name }, { blob = impostor } }))
  end
  assert(db:close())
  assert(Store.attach(argv[1]))

  for _, name in ipairs(wrappers) do
    local _, extra = search(name)
    assert(extra is table, name .. " was shadowed by the project's database")
    print("wrapper " .. name)
  end
  local loader, extra = search(ordinary)
  assert(extra == ordinary and (loader as function(): any)() == "impostor",
    ordinary .. " did not resolve project first")
  return 0
end
]]

--- Every wrapper the core hands a raw value resolves from the binary's
--- own database ahead of a project's, so a project cannot shadow one
--- into an untrusted load without its raw value -- while any other
--- `build.*` name still resolves project first.
local function test_a_project_cannot_shadow_a_raw_value_wrapper(tmp: string)
  local script = tmp .. "/shadowing.tl"
  assert(Fs.write(script, shadowing))
  local result = assert(Child.run({ assert(Proc.executable()), "--standalone", script,
    tmp .. "/project.db" }, { env = { XDG_CACHE_HOME = tmp .. "/cache" },
    stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(result.code == 0, tostring(result.stderr))
  local out = assert(result.stdout)
  for _, name in ipairs({ "build.artifact", "build.fuzz", "cosmic.store" }) do
    assert(out:find("wrapper " .. name .. "\n", 1, true), name .. " not found: " .. out)
  end
end

--- Inside `alone` only the binary's own database is searched, nothing
--- can be attached or set aside again, and every database is back
--- after it, whether the function returned or raised.
local function test_alone_searches_only_the_binarys_own_database()
  local before = #Store.databases()
  assert(before >= 2, "a test's tree is attached ahead of the binary's")
  local inside = 0
  local attached, nested = true, true
  Store.alone(function()
    inside = #Store.databases()
    attached = pcall(Store.attach, "/nonexistent/cosmic.db")
    nested = pcall(Store.alone, function() end)
  end)
  assert(inside == 1, tostring(inside))
  assert(not attached and not nested)
  assert(#Store.databases() == before)
  local ok, trouble = pcall(function(): string
    Store.alone(function() error("boom", 0) end)
    return ""
  end)
  assert(not ok and trouble == "boom", tostring(trouble))
  assert(#Store.databases() == before)
  -- More results than a C function has free slots are dropped, not kept.
  local many = assert(load("local t = {} for i = 1, 100 do t[i] = i end " ..
    "return table.unpack(t)"))
  Store.alone(many)
  assert(#Store.databases() == before)
  assert(Store.meta("compiler") ~= nil)
end

--- The binary carries the tz database, one TZif file per zone.
local function test_the_binary_carries_the_zones()
  local data, why = Store.zoneinfo("America/New_York")
  assert(data ~= nil, why)
  assert(data:sub(1, 4) == "TZif", "a TZif file")
  local none, trouble = Store.zoneinfo("Nowhere/Nothing")
  assert(none == nil and trouble:find("Nowhere/Nothing", 1, true), trouble)
end

--- The binary's own connection knows the functions every handle does,
--- so a query reads a module's deflated source back the way
--- `Store.source` does.
local function test_the_binary_s_database_inflates_its_source()
  local databases = Store.databases()
  local binary = databases[#databases]
  local rows = assert(Sqlite.text_rows(binary,
    "SELECT CAST(inflate(source) AS TEXT) FROM modules WHERE path = 'cosmic.store'"))
  assert(#rows == 1 and rows[1][1] == assert(Store.source("cosmic.store")),
    "the query and Store.source read the same text")
end
