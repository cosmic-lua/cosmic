--- A test worker holds the store, not only `require`, to its module's
--- import closure (`build.test_worker`'s `hold_requires`): a module of
--- the tree outside it, read by `Store.bytecode`, `Store.source` or a
--- searcher called by hand, is none of the store's, and
--- `Store.databases()`, whose handles read every module's rows, raises
--- -- each naming `store`, which this module does not declare. Without
--- the hold such a read reaches the program's own database, which no
--- key of this module's tests holds, and a verdict could stand on it
--- after the module it read changed.

local Store = require("cosmic.store")

--- `build.dispatch`, the program's entry: carried by the program, and in
--- no test's closure. Built at run time, so the build cannot follow it.
local outside <const> = table.concat({ "build", "dispatch" }, ".")

--- Asserts `why` says a hold refused `name` and how to read it.
local function names_the_fix(why: string, name: string)
  assert(why:find("module '" .. name .. "' is held from the store", 1, true), why)
  assert(why:find("build.store_hold_test's verdict is keyed by what the store holds of " ..
    "its import closure alone", 1, true), why)
  assert(why:find("store = true", 1, true), why)
end

local function test_bytecode_of_a_module_outside_the_closure_is_held()
  local bytes, why = Store.bytecode(outside)
  assert(bytes == nil, "read " .. outside .. "'s bytecode past the hold")
  names_the_fix(why, outside)
  assert(Store.bytecode("cosmic.store") ~= nil, "a module of the closure is read")
end

--- The source of a module, and of a name only a declaration answers
--- for, `build.compiler`, which this module's closure holds neither of.
local function test_source_of_a_module_outside_the_closure_is_held()
  local compiler = table.concat({ "build", "compiler" }, ".")
  for _, name in ipairs({ outside, compiler }) do
    local source, why = Store.source(name)
    assert(source == nil, "read " .. name .. "'s source past the hold")
    names_the_fix(why, name)
  end
  assert(Store.source("cosmic.store") ~= nil, "a module of the closure is read")
end

local type Searcher = function(string): any, any

--- No searcher called by hand hands a loader that loads it: the
--- store's says why it holds none.
local function test_a_searcher_called_by_hand_loads_nothing_outside_the_closure()
  local said = ""
  for _, searcher in ipairs(package.searchers as {Searcher}) do
    local loader, extra = searcher(outside)
    if loader is function(string, any): any then
      assert(not pcall(loader, outside, extra), "a searcher loaded " .. outside)
    elseif loader is string then
      said = said .. loader
    end
  end
  names_the_fix(said, outside)
end

local function test_the_databases_are_held()
  local ok, why = pcall(Store.databases)
  assert(not ok, "handed the store's databases past the hold")
  local text = tostring(why)
  assert(text:find("Store.databases() is held", 1, true), text)
  assert(text:find("store = true", 1, true), text)
end

--- The binary's data tables, which the runtime's identity keys, are
--- read as ever.
local function test_the_zones_are_read_under_the_hold()
  local data, why = Store.zoneinfo("America/New_York")
  assert(data ~= nil and data:sub(1, 4) == "TZif", why)
  assert(assert(Store.zone_names())["UTC"], "UTC is a zone")
end
