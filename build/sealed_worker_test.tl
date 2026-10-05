--- What a worker whose module declares neither `store`, `tool` nor `nests`
--- reads of the program: a sealed database of its module's import
--- closure and the modules every worker loads (build/test.tl's
--- `sealed_for`), so a module beyond them is found by no `Store` read, no
--- searcher called by hand and no `require`, whether the module's own test
--- makes it or a finalizer does after the hold on `require` is
--- lifted. build/sealed_worker_store_test.tl holds that a module that
--- declares `store` still reads the whole program. An unsealed run (one
--- whose program is no portable artifact) is none of this test's; a
--- sandboxed worker not given a sealed database fails it.
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local confine = require("build.confine")

--- Modules of the tree this module's closure does not hold.
local outside <const>: {string} = { "cosmic.zip", "build.writer", "build.sealed_worker_store_test" }

--- Whether this worker runs on a sealed database, which a sandboxed one
--- must (the runner marks every held worker: build.confine's
--- `held_variable`); an unmarked worker is skipped where it is not.
local function sealed(): boolean
  local relaunch = Proc.relaunch()
  local on_database = relaunch ~= nil and relaunch.argv[2] == "--database"
  if Env.get(confine.held_variable) ~= nil then
    assert(on_database, "a sandboxed worker was not given a sealed database")
  end
  if not on_database then Test.skip("this worker does not run on a sealed database") end
  return on_database
end

--- Every way a worker reads the program for `name`, which finds it in none.
local function absent(name: string)
  assert(Store.source(name) == nil, name .. ": its source is in the program")
  assert(Store.bytecode(name) == nil, name .. ": its bytecode is in the program")
  assert(#assert(Store.requires(name)) == 0, name .. ": its imports are in the program")
  for _, db in ipairs(Store.databases()) do
    local rows = assert(Sqlite.text_rows(db,
      "SELECT count(*) FROM modules WHERE path = ?1", { { text = name } }))
    assert(rows[1][1] == "0", name .. ": a database holds its row")
  end
  -- The searchers behind the runner's own hold on `require`, which stands
  -- first only while the test runs.
  for i = 2, #package.searchers do
    local loader = package.searchers[i](name)
    assert(type(loader) ~= "function", name .. ": a searcher loads it")
  end
end

local function test_a_module_outside_the_closure_is_not_in_the_program()
  if not sealed() then return end
  for _, name in ipairs(outside) do absent(name) end
  assert(Store.bytecode("cosmic.store") ~= nil, "a module of the closure is not")
  local ok, why = pcall(require, "cosmic." .. "zip")
  assert(not ok and tostring(why):find("outside the import closure", 1, true), tostring(why))
end

--- The same from a finalizer, which a collection runs where it likes,
--- once the test is over included.
local function test_a_finalizer_finds_no_module_outside_the_closure()
  if not sealed() then return end
  local failure: string = "not run"
  setmetatable({}, { __gc = function()
    local ok, why = pcall(function()
      for _, name in ipairs(outside) do absent(name) end
    end)
    failure = ok and "" or tostring(why)
  end })
  collectgarbage()
  collectgarbage()
  assert(failure == "", failure)
end
