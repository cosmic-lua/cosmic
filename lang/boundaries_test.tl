--- Tests of [`lang.boundaries`]: the kinds each form of type admits, the spelling the worker's `__cosmic_tc` reads, and that
--- the hook takes that spelling. The property over random types is in [`lang.boundaries_fuzz_test`].
local Boundaries = require("lang.boundaries")
local Globals = require("cosmic.internal.globals")
local Programs = require("lang.types_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")
local worker = require("build.test_worker")

Test.policy{}

local record World
  store: Types.Store
  fixture: Programs.Fixture
end

local function world(): World
  local store = Types.new()
  return { store = store, fixture = Programs.fixture(store) }
end

local function decl_of(w: World, name: string): Types.Decl
  local decl = w.fixture.decls[name]
  if decl == nil then
    error("the fixture declares no " .. name, 2)
  end
  return decl
end

local function named(w: World, name: string, args?: {Types.Type}): Types.Type
  return w.store:named(decl_of(w, name), args)
end

--- The spelling of the kinds of `t`, with "-" for a type that is not checked.
local function spec(t: Types.Type): string
  return Boundaries.spec(Boundaries.kinds(t))
end

local function same(got: string, want: string)
  assert(got == want, "\n   got: " .. got .. "\n  want: " .. want)
end

local function test_the_numbers()
  local w = world()
  same(spec(w.store.integer), "integer")
  same(spec(w.store.number), "number")
  same(spec(w.store:union({ w.store.integer, w.store.string })), "integer|string")
  -- `integer` is in `number`, so the pair is the one `number` and no check of the whole number.
  same(spec(w.store:union({ w.store.integer, w.store.number })), "number")
end

local function test_a_string_and_an_enum_are_strings_and_the_enum_keeps_its_members()
  local w = world()
  same(spec(w.store.string), "string")
  local string_kinds = Boundaries.kinds(w.store.string)
  assert(string_kinds ~= nil and string_kinds.strings == nil, "a string has any text")
  local color = named(w, "Color")
  same(spec(color), "string")
  local kinds = Boundaries.kinds(color)
  assert(kinds ~= nil and kinds.strings ~= nil)
  same(table.concat(kinds.strings, ","), "blue,green,red")
  -- Two enums: the values of both. An enum beside `string` is `string`, which any text satisfies.
  local both = Boundaries.kinds(w.store:union({ color, named(w, "Odd") }))
  assert(both ~= nil and both.strings ~= nil)
  same(table.concat(both.strings, ","), "a\"b,blue,green,ok,red,\255")
  local mixed = Boundaries.kinds(w.store:union({ color, w.store.integer }))
  assert(mixed ~= nil and mixed.strings ~= nil and #mixed.strings == 3)
  same(spec(w.store:union({ color, w.store.string })), "string")
end

local function test_booleans_are_boolean_and_nil_is_there_only_where_the_type_has_it()
  local w = world()
  same(spec(w.store.boolean), "boolean")
  same(spec(w.store:atom("true")), "boolean")
  same(spec(w.store:atom("false")), "boolean")
  same(spec(w.store:atom("nil")), "nil")
  same(spec(w.store.string), "string")
  same(spec(w.store:optional(w.store.string)), "string|nil")
  same(spec(w.store:optional(w.store.integer)), "integer|nil")
  same(spec(w.store:optional(named(w, "Node"))), "table|nil")
  same(spec(w.store:union({ w.store:atom("true"), w.store.integer })), "integer|boolean")
end

local function test_collections_records_and_interfaces_are_tables()
  local w = world()
  same(spec(w.store:array(w.store.integer)), "table")
  same(spec(w.store:array(w.store.integer, true)), "table")
  same(spec(w.store:map(w.store.string, w.store.integer)), "table")
  same(spec(named(w, "Node")), "table")
  same(spec(named(w, "Stream.Reader")), "table")
  same(spec(named(w, "List", { w.store.string })), "table")
  -- A declaration used as a value is the table of its functions.
  same(spec(w.store:named(decl_of(w, "Node"), nil, true)), "table")
  local record_kinds = Boundaries.kinds(named(w, "Node"))
  assert(record_kinds ~= nil and record_kinds.classes == nil)
end

local function test_a_class_is_a_table_that_names_its_class()
  local w = world()
  local file = named(w, "File")
  same(spec(file), "table")
  local kinds = Boundaries.kinds(file)
  assert(kinds ~= nil and kinds.classes ~= nil)
  assert(#kinds.classes == 1 and kinds.classes[1] == decl_of(w, "File"))
  -- Where a table of another kind is admitted too, the metatable says nothing.
  local with_record = Boundaries.kinds(w.store:union({ file, named(w, "Node") }))
  assert(with_record ~= nil and with_record.classes == nil)
  local with_array = Boundaries.kinds(w.store:union({ file, w.store:array(w.store.integer) }))
  assert(with_array ~= nil and with_array.classes == nil)
  local as_value = Boundaries.kinds(w.store:named(decl_of(w, "File"), nil, true))
  assert(as_value ~= nil and as_value.classes == nil)
  local optional = Boundaries.kinds(w.store:optional(file))
  assert(optional ~= nil and optional.classes ~= nil and #optional.classes == 1)
end

local function test_a_userdata_is_a_userdata_and_a_function_a_function()
  local w = world()
  same(spec(named(w, "Handle")), "userdata")
  same(spec(w.store:fn({ params = { { type = w.store.integer } } })), "function")
  same(spec(w.store:union({ named(w, "Handle"), w.store:fn({}), w.store.string })), "string|function|userdata")
end

local function test_a_type_that_says_nothing_of_its_value_is_not_checked()
  local w = world()
  same(spec(w.store.any), "-")
  same(spec(w.store.invalid), "-")
  same(spec(w.store:var(0, 0)), "-")
  assert(Boundaries.kinds(w.store.any) == nil)
  -- A variable inside a union leaves it open, and so does one inside an array no value is read from.
  same(spec(w.store:union({ w.store:var(0, 0), w.store.integer })), "-")
  same(spec(w.store:array(w.store.any)), "table")
  same(spec(w.store:optional(w.store.any)), "-")
end

local function test_never_admits_no_kind()
  local w = world()
  local kinds = Boundaries.kinds(w.store.never)
  assert(kinds ~= nil and #kinds.list == 0)
  same(Boundaries.spec(kinds), "")
end

--- `type Json = string | {Json}`, in the module `m`.
local function json(w: World): Types.Type
  local decl = w.store:declare("alias", "m", { "Json" }, 0)
  local use = w.store:named(decl)
  w.store:define(decl, {
    tparams = {}, supers = {}, fields = {}, methods = {}, values = {},
    alias = w.store:union({ w.store.string, w.store:array(use), w.store:map(w.store.string, use) }),
  })
  return use
end

local function test_a_recursive_alias_is_its_top_level_kinds_and_its_elements_are_not_checked()
  local w = world()
  local value = json(w)
  same(spec(value), "string|table")
  same(spec(w.store:optional(value)), "string|table|nil")
  same(spec(w.store:array(value)), "table")
end

local function test_an_alias_with_no_body_yet_is_not_checked()
  local w = world()
  local decl = w.store:declare("alias", "m", { "Later" }, 0)
  same(spec(w.store:named(decl)), "-")
end

--- The call of the worker's hook for a boundary of one value: `__cosmic_tc(2, text, value)`.
local function crossing(): function(text: string, value: any)
  worker.install_checks()
  local make = assert(load("local text, value = ... __cosmic_tc(2, text, value)", "=boundaries_test", "t",
    Globals.table()))
  return function(text: string, value: any)
    make(text, value)
  end
end

local function violations_met(): integer
  local n = 0
  for _, each in ipairs(worker.violations()) do
    n = n + each.count
  end
  return n
end

--- The spelling is the worker's: a value of a kind the type admits passes the hook, a value of another is one violation
--- that names the declared kinds and the kind it was.
local function test_the_hook_takes_the_spelling()
  local w = world()
  local cross = crossing()
  local text = "f;lang/boundaries_test.tl:1;field;" .. spec(w.store:optional(w.store.integer))
  local before = violations_met()
  cross(text, 1)
  cross(text, nil)
  assert(violations_met() == before, "a value the type admits was recorded")
  cross(text, 1.5)
  cross(text, "text")
  local met = worker.violations()
  assert(violations_met() == before + 2, "two values of other kinds were one violation each")
  local last = met[#met]
  assert(last ~= nil and last.kind == "field" and last.declared == "integer|nil" and last.actual == "string")
  -- A type that is not checked is "-": nothing is held to it.
  local free = "f;lang/boundaries_test.tl:2;field;" .. spec(w.store.any)
  cross(free, "anything")
  cross(free, nil)
  assert(violations_met() == before + 2)
end
