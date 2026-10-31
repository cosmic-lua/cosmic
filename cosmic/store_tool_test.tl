--- The cases of cosmic/store_test.tl that start this program, where the binary's own database is the last one searched. It declares
--- `tool` because it starts this program; the cases that read the store
--- beyond their closure are in cosmic/store_handles_test.tl.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local test_child = require("build.test_child")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")

--- The program itself, which the test starts.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- The child that runs as the program does: the binary's own database is the one [`Store.databases`] ends with, and
--- every module there the searcher hands a raw value is a wrapper the core grants one. A project database then attached
--- holds an impostor under each of those names and under one ordinary `build.*` module; each wrapper must still come
--- from the binary with its raw value, and the ordinary one from the project.
test_child.register("shadowing", function(argv: {string}): integer
  local search = assert(package.searchers[#package.searchers])
  local databases = Store.databases()
  local binary = assert(databases[#databases])
  local wrappers: mut {string} = {}
  local ordinary: string? = nil
  for _, row in ipairs((assert(Sqlite.text_rows(binary,
      "SELECT path FROM modules WHERE kind = 'module' ORDER BY path")))) do
    local name = row:text(1)
    local _, extra = search(name)
    if extra is table then
      table.insert(wrappers, name)
    elseif ordinary == nil and name:sub(1, 6) == "build." then
      ordinary = name
    end
  end
  assert(ordinary ~= nil, "no ordinary build.* module to compare")

  local db = assert(Sqlite.open((argv[1] or ""), { writable = true }))
  assert(db:exec("CREATE TABLE modules (path TEXT, bytecode BLOB, " ..
      "kind TEXT, source TEXT, file TEXT); CREATE TABLE meta (key TEXT, value TEXT)"))
  -- An impostor answers its first argument, which the real loader never does.
  local impostor = string.dump(function(...: any): any return ... end)
  local names: mut {string} = { ordinary }
  for _, name in ipairs(wrappers) do table.insert(names, name) end
  for _, name in ipairs(names) do
    assert(Sqlite.run(db, "INSERT INTO modules (path, bytecode, kind) VALUES (?1, deflate(?2), 'module')",
      { { text = name }, { blob = impostor } }))
  end
  assert(db:close())
  assert(Store.attach((argv[1] or ""), { unchecked_bytecode = true }))

  for _, name in ipairs(wrappers) do
    local _, extra = search(name)
    assert(extra is table, name .. " was shadowed by the project's database")
    print("wrapper " .. name)
  end
  local loader, extra = search(ordinary)
  assert(extra == ordinary and loader("impostor") == "impostor",
    ordinary .. " did not resolve project first")
  return 0
end)

--- Every wrapper the core hands a raw value resolves from the binary's
--- own database ahead of a project's, so a project cannot shadow one
--- into an untrusted load without its raw value -- while any other
--- `build.*` name still resolves project first.
local function test_a_project_cannot_shadow_a_raw_value_wrapper(tmp: string)
  local started = this_program.program(test_child.words(tmp, "cosmic.store_tool_test", "shadowing", { tmp .. "/project.db" }),
    { env = { XDG_CACHE_HOME = tmp .. "/cache" },
      stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0, tostring(result.stderr))
  local out = assert(result.stdout)
  for _, name in ipairs({ "build.artifact", "build.fuzz", "cosmic.store" }) do
    assert(out:find("wrapper " .. name .. "\n", 1, true), name .. " not found: " .. out)
  end
end

--- The searcher inflates a module's bytecode before it loads it, and a
--- row that is not a deflate stream is refused by name: `require` raises,
--- and the chunk is never handed to `load` as it stands.
test_child.register("deflated", function(argv: {string}): integer
  local db = assert(Sqlite.open((argv[1] or ""), { writable = true }))
  assert(db:exec("CREATE TABLE modules (path TEXT, bytecode BLOB, kind TEXT, source TEXT, file TEXT); " ..
      "CREATE TABLE meta (key TEXT, value TEXT)"))
  local chunk = string.dump(function(...: any): any return ... end, true)
  assert(Sqlite.run(db, "INSERT INTO modules (path, bytecode, kind) VALUES ('project.packed', deflate(?1), 'module')",
    { { blob = chunk } }))
  assert(Sqlite.run(db, "INSERT INTO modules (path, bytecode, kind) VALUES ('project.plain', ?1, 'module')",
    { { blob = chunk } }))
  assert(db:close())
  assert(Store.attach((argv[1] or "")))
  local search = assert(package.searchers[#package.searchers])
  local loader = assert(search("project.packed"))
  assert(loader("project.packed") == "project.packed")
  local bytes = assert(Store.bytecode("project.packed"))
  assert(bytes == chunk, "the bytecode is answered inflated")
  local ok, trouble = pcall(search, "project.plain")
  assert(not ok and tostring(trouble):find("bad bytecode of module 'project.plain'", 1, true) ~= nil,
    tostring(trouble))
  local plain, why = Store.bytecode("project.plain")
  assert(plain == nil and why:find("project.plain", 1, true) ~= nil, why)
  print("deflated")
  return 0
end)

local function test_the_searcher_inflates_bytecode_and_refuses_a_row_that_is_not_deflated(tmp: string)
  local started = this_program.program(test_child.words(tmp, "cosmic.store_tool_test", "deflated", { tmp .. "/packed.db" }),
    { env = { XDG_CACHE_HOME = tmp .. "/cache" },
      stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0, tostring(result.stderr))
  assert(assert(result.stdout):find("deflated\n", 1, true))
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
