--- The case of cosmic/store_test.tl that starts this program standalone,
--- where the binary's own database is the only one searched. It declares
--- `tool` because it starts this program; the cases that read the store
--- beyond their closure are in cosmic/store_handles_test.tl.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")

--- The program itself, which the test starts.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

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

  local db = assert(Sqlite.open(argv[1], { writable = true }))
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
  local started = this_program.program({ "--standalone", script, tmp .. "/project.db" },
    { env = { XDG_CACHE_HOME = tmp .. "/cache" },
      stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0, tostring(result.stderr))
  local out = assert(result.stdout)
  for _, name in ipairs({ "build.artifact", "build.fuzz", "cosmic.store" }) do
    assert(out:find("wrapper " .. name .. "\n", 1, true), name .. " not found: " .. out)
  end
end

--- A seal with no path, in a process whose cache is the test's own: the
--- file is `<cache>/cosmic/sandbox/<digest>.db` and its bytes are the
--- digest's.
local sealing <const> = [[
local Store = require("cosmic.store")

return function(): integer
  print(assert(Store.seal({ "cosmic.codec" })))
  return 0
end
]]

local function test_a_seal_without_a_path_lands_in_the_cache(tmp: string)
  local script = tmp .. "/sealing.tl"
  assert(Fs.write(script, sealing))
  local started = this_program.program({ "--standalone", script },
    { env = { XDG_CACHE_HOME = tmp .. "/cache", TMPDIR = tmp },
      stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0, tostring(result.stderr))
  local digest = (assert(result.stdout):gsub("%s+$", ""))
  local bytes = assert(Fs.read(tmp .. "/cache/cosmic/sandbox/" .. digest .. ".db"))
  assert(Hash.hex_sha256(bytes) == digest)
end
