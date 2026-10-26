--- A searcher the worker holds hands the core's raw table beside the loader of a module only to a test whose closure
--- holds the module: a test that loops over `package.searchers` and asks for a module outside its closure is handed a
--- loader that raises and no table. The store is granted whole, so that the searchers know every module.
local Globals = require("cosmic.internal.globals")
local Test = require("cosmic.test")
local _ = require("cosmic.hash")

Test.policy{ grants = { { path = "o/cosmic.db", letters = "r" } } }

--- What every searcher hands beside the loader of `name`: how many raw tables, and how many of the loaders raise.
local ASK <const> = [[
local name = ...
local tables, loaders = 0, 0
for _, searcher in ipairs(package.searchers) do
  local loader, extra = searcher(name)
  if type(loader) == 'function' then loaders = loaders + 1 end
  if type(extra) == 'table' then tables = tables + 1 end
end
return tables .. ' ' .. loaders
]]

local function asked(name: string): integer, integer
  local chunk = assert(load(ASK, "=ask", "t", Globals.table()))
  local answer: any = chunk(name)
  local tables, loaders = tostring(answer):match("^(%d+) (%d+)$")
  return assert(math.tointeger(tonumber(tables))), assert(math.tointeger(tonumber(loaders)))
end

local function test_a_module_outside_the_closure_has_no_raw_table_beside_its_loader()
  for _, name in ipairs({ "cosmic.sqlite", "cosmic.child", "cosmic.net" }) do
    local tables, loaders = asked(name)
    assert(loaders > 0, name .. " has no loader: the store was not granted")
    assert(tables == 0, name .. " is outside the closure but a searcher handed its raw table")
  end
end

local function test_a_module_in_the_closure_has_its_raw_table()
  local tables, _ = asked("cosmic.hash")
  assert(tables > 0, "cosmic.hash is in the closure but no searcher handed its raw table")
end
