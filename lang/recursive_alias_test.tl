--- Tests of the recursive alias ("an alias that reaches itself through the element of an array or the value of a
--- map" in [`lang.declarations`]): `type Value = string | {Value} | {string: Value}` is a type, a table literal is
--- checked against it arm by arm by the shape of its items, and a comparison that does not read the alias as the type
--- it names refuses and never accepts. Each layer is tested where it lives: the store's declaration of kind `alias`,
--- the relation, the lowering, the checker, and the Lua the code generator writes.
local Programs = require("lang.check_programs")
local Relation = require("lang.relation")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{ cpu_features = true }

-- the store and the relation -------------------------------------------------------------------------

--- A store with the alias `V = string | {V}` (declared as the checker declares one: `alias`, no type parameters).
local record World
  store: Types.Store
  judge: Relation.Judge
  v: Types.Type
  body: Types.Type
end

local function world(): World
  local s = Types.new()
  local decl = s:declare("alias", "m", { "V" }, 0)
  local v = s:named(decl, {})
  local body = s:union({ s.string, s:array(v, false) })
  s:define(decl, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {}, alias = body })
  return { store = s, judge = Relation.new(s), v = v, body = body }
end

local function below(w: World, a: Types.Type, b: Types.Type): boolean
  local answer = w.judge:subtype(a, b)
  -- The reason and the answer agree.
  assert((w.judge:refuse(a, b) == nil) == answer, Types.display(a) .. " below " .. Types.display(b))
  return answer
end

local function test_an_alias_is_a_declaration_whose_body_is_the_type_it_names()
  local w = world()
  local v = w.v
  assert((v.tag == "named") and v.decl.kind == "alias")
  assert(Types.unfold(w.v) == w.body)
  assert(Types.unfold(w.body) == w.body)
  assert(Types.unfold(w.store.string) == w.store.string)
  assert(Types.display(w.v) == "V")
  -- The name is a part of nothing: a walk over a type does not meet its body.
  assert(#Types.parts(w.v) == 0)
  -- A use made before the body is known stays itself.
  local s = w.store
  local early = s:named(s:declare("alias", "m", { "Early" }, 0), {})
  assert(Types.unfold(early) == early)
end

local function test_an_alias_declaration_is_text_and_reads_back_as_one()
  local w = world()
  local named = w.v
  assert((named.tag == "named"))
  local text = Types.encode_declaration(named.decl)
  assert(text:find("(alias ", 1, true) ~= nil, text)
  local other = Types.new(function(module: string, name: string): string?
    if module == "m" and name == "V" then
      return text
    end
    return nil
  end)
  local loaded, why = other:decode("(ref \"m\" \"V\")")
  assert(loaded ~= nil, why)
  assert((loaded.tag == "named") and loaded.decl.kind == "alias")
  assert(Types.encode_declaration(loaded.decl) == text)
  assert(Types.display(Types.unfold(loaded)) == "V | string" or Types.display(Types.unfold(loaded)) == "string | {V}")
end

local function test_a_body_of_an_alias_is_the_type_it_names_and_nothing_else()
  local s = Types.new()
  local alias = s:declare("alias", "m", { "A" }, 0)
  local ok = pcall(function()
    s:define(alias, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} })
  end)
  assert(not ok, "an alias without the type it names")
  ok = pcall(function()
    s:define(alias, { tparams = {}, supers = {}, fields = { { name = "x", type = s.string } }, methods = {}, values = {},
      alias = s.string })
  end)
  assert(not ok, "an alias with a field")
  local record_ = s:declare("record", "m", { "R" }, 0)
  ok = pcall(function()
    s:define(record_, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {}, alias = s.string })
  end)
  assert(not ok, "a record that names a type")
end

local function test_a_type_below_the_body_is_below_the_alias_and_the_alias_is_below_what_the_body_is()
  local w = world()
  local s = w.store
  -- Both directions: a mutant that reads the alias on one side only fails one of these.
  assert(below(w, w.v, w.body))
  assert(below(w, w.body, w.v))
  assert(below(w, s.string, w.v))
  assert(below(w, s:array(s.string, false), w.v))
  assert(below(w, s:array(s:array(s.string, false), false), w.v))
  assert(below(w, s:array(w.v, false), w.v))
  assert(below(w, w.v, s:optional(w.v)))
  assert(below(w, s.never, w.v))
  assert(not below(w, s.integer, w.v))
  assert(not below(w, s:array(s.integer, false), w.v))
  assert(not below(w, s:array(s:array(s.integer, false), false), w.v))
  assert(not below(w, s:atom("nil"), w.v))
  assert(not below(w, s.any, w.v))
  assert(not below(w, w.v, s.string))
  assert(not below(w, w.v, s:array(s.string, false)))
  assert(not below(w, s:optional(w.v), w.v))
  assert(not below(w, w.v, s.any))
  -- A mutable array of the arm is below the alias, as it is below a view.
  assert(below(w, s:array(s.string, true), w.v))
  assert(not below(w, s:array(s.integer, true), w.v))
end

local function test_a_nested_value_is_below_the_alias_however_deep_it_is()
  local w = world()
  local s = w.store
  local deep: Types.Type = s.string
  for _ = 1, 200 do
    deep = s:array(deep, false)
  end
  assert(below(w, deep, w.v))
  local wrong: Types.Type = s.integer
  for _ = 1, 200 do
    wrong = s:array(wrong, false)
  end
  assert(not below(w, wrong, w.v))
end

local function test_a_refusal_names_the_alias_as_it_was_written()
  local w = world()
  local s = w.store
  local r = w.judge:refuse(s:array(s.integer, false), w.v)
  assert(r ~= nil and r.code == "union_none", r and r.code or "none")
  assert(r.super == w.v, Types.display(r.super))
  assert(r.sub == s:array(s.integer, false))
  local inner = w.judge:refuse(s:array(s:array(s.integer, false), false), w.v)
  assert(inner ~= nil and inner.code == "union_none")
end

--- Two aliases that name each other: `A = string | {B}` and `B = string | {A}`.
local function pair(): Types.Store, Relation.Judge, Types.Type, Types.Type
  local s = Types.new()
  local da = s:declare("alias", "m", { "A" }, 0)
  local db = s:declare("alias", "m", { "B" }, 0)
  local a, b = s:named(da, {}), s:named(db, {})
  s:define(da, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {}, alias = s:union({ s.string, s:array(b, false) }) })
  s:define(db, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {}, alias = s:union({ s.string, s:array(a, false) }) })
  return s, Relation.new(s), a, b
end

local function test_two_aliases_that_name_each_other_are_two_types_and_the_comparison_ends()
  local s, judge, a, b = pair()
  -- Neither reads the other's body: that would read the bodies for ever. They are related as two declarations are.
  assert(judge:subtype(a, a))
  assert(not judge:subtype(a, b))
  assert(not judge:subtype(b, a))
  assert(not judge:subtype(s:array(a, false), s:array(b, false)))
  assert(judge:subtype(s.string, a) and judge:subtype(s.string, b))
  assert(judge:subtype(s:array(b, false), a))
  assert(not judge:subtype(s:array(a, false), a))
  assert(not judge:subtype(a, s:optional(b)))
  local why = judge:refuse(a, b)
  assert(why ~= nil and why.code == "nominal")
end

local function test_an_alias_whose_body_is_a_single_array_of_itself_relates_to_the_arrays_it_stands_for()
  local s = Types.new()
  local decl = s:declare("alias", "m", { "T" }, 0)
  local t = s:named(decl, {})
  s:define(decl, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {}, alias = s:array(t, false) })
  local judge = Relation.new(s)
  -- `T` is `{T}`: it holds the empty array and the arrays of those, and only them.
  assert(judge:subtype(t, s:array(t, false)))
  assert(judge:subtype(s:array(t, false), t))
  assert(judge:subtype(t, s:array(s:array(t, false), false)))
  assert(not judge:subtype(s.string, t))
  assert(not judge:subtype(s:array(s.string, false), t))
end

local function test_a_record_that_holds_itself_as_its_array_part_ends_the_comparison_and_is_refused()
  local w = world()
  local s = w.store
  -- `record Node is {Node}`: comparing it with `{V}` compares its array part, `Node`, with `V` again, and `V` reads `{V}`.
  local decl = s:declare("record", "m", { "Node" }, 0)
  local node = s:named(decl, {})
  s:define(decl, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {}, array = node })
  assert(below(w, node, s:array(node, false)))
  -- A record is no arm of the alias, so the pair is not read round: the comparison ends and refuses.
  assert(not below(w, node, w.v))
  assert(not below(w, s:array(node, false), w.v))
  assert(not below(w, s:optional(node), s:optional(w.v)))
  local r = w.judge:refuse(node, w.v)
  assert(r ~= nil and r.sub == node and r.super == w.v, r and r.code or "none")
  -- What the alias is below does not depend on what was asked first.
  assert(below(w, s.string, w.v) and below(w, s:array(s.string, false), w.v))
  assert(not below(w, node, w.v))
end

-- the lowering and the checker -------------------------------------------------------------------------

--- The programs that run have no `Null`: a program that makes a userdata is no program the checker takes to run.
local RUN_HEAD <const> = "local type Value = string | number | boolean | {Value} | {string: Value}\n" ..
  "local function take(v: Value): string\n  return \"x\"\nend\n"

local HEAD <const> = "local record Null\n  userdata\nend\nlocal type Value = string | number | boolean | Null | {Value} | {string: Value}\n" ..
  "local function take(v: Value): string\n  return \"x\"\nend\n"

--- Checks that `source` is taken, runs as the Lua the code generator writes with every narrowed read checked, and prints `want`.
local function runs(source: string, want: string)
  local x = Programs.execute(source, true)
  assert(#x.run.before == 0, table.concat(x.run.before, " ") .. " in\n" .. source)
  assert(x.ran, Programs.codes(x.run) .. " in\n" .. source)
  assert(x.fault == nil, tostring(x.fault) .. " in\n" .. x.lua)
  assert(table.concat(x.printed, ",") == want, table.concat(x.printed, ",") .. ", wanted " .. want .. " in\n" .. x.lua)
end

--- The errors of checking `source`, as `line:col code` in order.
local function errors_of(source: string): {string}
  local r = Programs.run(source)
  local out: mut {string} = {}
  for _, e in ipairs(r.lowered.errors) do
    out[#out + 1] = tostring(e.y) .. ":" .. tostring(e.x) .. " " .. e.code
  end
  for _, e in ipairs(r.errors) do
    out[#out + 1] = tostring(e.y) .. ":" .. tostring(e.x) .. " " .. e.code
  end
  return out
end

--- Checks that `source` is taken.
local function takes(source: string)
  local got = errors_of(source)
  assert(#got == 0, table.concat(got, ", ") .. " in\n" .. source)
end

--- An error of the lowering or the checker.
local record Found
  code: string
  msg: string
  fix: string
  y: integer
  x: integer
end

--- Checks that `source` is refused with exactly `codes` (space separated) and answers the errors: those of the lowering first.
local function refuses(source: string, codes: string): Found
  local r = Programs.run(source)
  local found: mut {Found} = {}
  for _, e in ipairs(r.lowered.errors) do
    found[#found + 1] = { code = e.code, msg = e.msg, fix = e.fix, y = e.y, x = e.x }
  end
  for _, e in ipairs(r.errors) do
    found[#found + 1] = { code = e.code, msg = e.msg, fix = e.fix, y = e.y, x = e.x }
  end
  local got: mut {string} = {}
  for i, e in ipairs(found) do
    got[i] = e.code
  end
  assert(table.concat(got, " ") == codes, "wanted " .. codes .. ", got " .. table.concat(got, " ") .. " in\n" .. source)
  return (assert(found[1]))
end

local function test_an_alias_may_reach_itself_through_an_array_or_a_map()
  takes("local type A = string | {A}\nlocal x: A = {\"a\", {\"b\"}}\nlocal _ = x\n")
  takes("local type A = string | {string: A}\nlocal x: A = { a = { b = \"c\" } }\nlocal _ = x\n")
  takes("local type A = {A}\nlocal x: A = { {}, { {} } }\nlocal _ = x\n")
  takes("local type A = string | mut {A}\nlocal x: A = \"s\"\nlocal _ = x\n")
  takes("local type A = string | {B}\nlocal type B = string | {A}\nlocal x: A = { \"a\", { \"b\" } }\nlocal _ = x\n")
  -- A record's field and a function's parameter may hold it.
  takes("local type A = string | {A}\nlocal record R\n  v: A\nend\nlocal r: R = { v = { \"a\" } }\nlocal function f(a: A): A\n  return a\nend\nlocal _ = r\nlocal _ = f\n")
end

local function test_an_alias_that_reaches_itself_with_no_array_or_map_between_has_no_name_and_is_refused()
  local errors = refuses("local type A = A | string\nlocal x: A = \"s\"\nlocal _ = x\n", "alias_cycle")
  assert(errors.fix:find("elements of an array or the values of a map", 1, true) ~= nil, errors.fix)
  refuses("local type A = B\nlocal type B = A\nlocal x: A = 1\nlocal _ = x\n", "alias_cycle")
  -- Through a function type: only an array or a map is a name.
  refuses("local type F = function(F): F\nlocal function use(f: F)\n  local _ = f\nend\nlocal _ = use\n", "alias_cycle alias_cycle")
  -- An alias with type parameters is not named: its uses have arguments.
  refuses("local type G<T> = T | {G<T>}\nlocal x: G<string> = \"s\"\nlocal _ = x\n", "alias_cycle")
  -- The use outside the collection is the cycle, though another use is inside.
  refuses("local type A = A | {A} | string\nlocal x: A = \"s\"\nlocal _ = x\n", "alias_cycle")
end

local function test_a_recursive_alias_is_no_optional_type()
  local errors = refuses("local type A = string | {A}?\nlocal x: A = \"s\"\nlocal _ = x\n", "alias_cycle")
  assert(errors.msg:find("may be nil", 1, true) ~= nil, errors.msg)
  assert(errors.fix:find("`A`?", 1, true) ~= nil, errors.fix)
end

local function test_a_recursive_alias_is_no_key()
  local errors = refuses("local type A = string | {A}\nlocal m: {A: string} = {}\nlocal _ = m\n", "key_type")
  assert(errors.code == "key_type")
end

local function test_a_natural_literal_is_checked_against_the_arms_of_the_alias_by_its_shape()
  takes(HEAD .. "local a = take({ name = \"x\", n = 1, tags = { \"a\", \"b\" } })\nlocal _ = a\n")
  takes(HEAD .. "local a = take({ 1, 2.5, \"x\", true, { 1 }, { k = false } })\nlocal _ = a\n")
  takes(HEAD .. "local a = take({ [\"a b\"] = { { { 1 } } } })\nlocal _ = a\n")
  takes(HEAD .. "local v: Value = { { name = \"x\" }, { name = \"y\" } }\nlocal _ = v\n")
  takes(HEAD .. "local v: Value? = { 1 }\nlocal _ = v\n")
  takes(HEAD .. "local v: {string: Value} = { a = { 1 }, b = \"x\" }\nlocal _ = v\n")
  -- A value of a type is a value of the arm that is its type.
  takes(HEAD .. "local words: {string} = { \"a\" }\nlocal counts: {string: integer} = { a = 1 }\nlocal _ = take(words) .. take(counts)\n")
  takes(HEAD .. "local mutable: mut {string: {string}} = {}\nlocal _ = take(mutable)\n")
end

local function test_names_and_keys_in_brackets_are_one_kind_of_item_that_chooses_the_map_arm()
  takes(HEAD .. "local a = take({ name = \"x\", [\"content-type\"] = \"y\" })\nlocal _ = a\n")
  takes(HEAD .. "local k = \"k\"\nlocal a = take({ name = \"x\", [k] = 1, nested = { [k] = { 1 }, z = true } })\nlocal _ = a\n")
  runs(RUN_HEAD .. "print(take({ name = \"x\", [\"content-type\"] = \"y\" }), take({ [\"a b\"] = 1, c = 2 }))\n", "x\tx")
  -- A positional item beside a key still mixes, and the message says which it saw.
  local mixed = refuses(HEAD .. "local a = take({ name = \"x\", [\"y\"] = 1, \"z\" })\nlocal _ = a\n", "literal_shape")
  assert(mixed.msg:find("some by position and some by key", 1, true) ~= nil, mixed.msg)
end

local function test_a_record_with_an_array_part_is_no_arm_of_the_alias_whatever_else_it_holds()
  local bag = "local record Bag is {string}\n  x: function()\n  y: integer\nend\n"
  refuses(HEAD .. bag .. "local function f(b: Bag): string\n  return take(b)\nend\nlocal _ = f\n", "not_assignable")
  refuses(HEAD .. bag .. "local function f(b: Bag): string\n  return take({ b })\nend\nlocal _ = f\n", "not_assignable")
  refuses(HEAD .. bag .. "local function f(b: Bag): string\n  return take({ k = b })\nend\nlocal _ = f\n", "not_assignable")
  refuses(HEAD .. "local record Plain is {Value}\n  tag: string\nend\nlocal function f(p: Plain): string\n  return take(p)\nend\nlocal _ = f\n",
    "not_assignable")
  -- Not even one that is only its array part: the arms of an alias are the arrays and maps it names.
  refuses(HEAD .. "local record Ring is {string}\nend\nlocal function f(r: Ring): string\n  return take(r)\nend\nlocal _ = f\n", "not_assignable")
  refuses(HEAD .. "local class Box\n  n: integer\nend\nlocal function f(b: Box): string\n  return take(b)\nend\nlocal _ = f\n", "not_assignable")
  -- The array it is below still takes it: a record's array part is a view of the record.
  takes(HEAD .. "local record Ring is {string}\nend\nlocal function f(r: Ring): {string}\n  return r\nend\nlocal _ = f\n")
end

local function test_an_alias_in_a_union_is_read_where_a_test_tells_the_arms_apart()
  takes(HEAD .. "local function f(v: Value?): string\n  if type(v) == \"table\" then\n    return \"t\"\n  end\n  if v == \"x\" then\n    return \"x\"\n  end\n  return \"\"\nend\nlocal _ = f\n")
  refuses(HEAD .. "local function f(v: Value?): string\n  if v is string then\n    return \"\"\n  end\n  local s: string = v\n  return s\nend\nlocal _ = f\n", "not_assignable")
end

local function test_a_literal_that_fits_no_arm_is_one_error_that_names_the_arms_and_the_item()
  local errors = refuses(HEAD .. "local a = take({ name = \"x\", f = print })\nlocal _ = a\n", "not_assignable")
  assert(errors.y == 8, tostring(errors.y) .. ":" .. tostring(errors.x))
  assert(errors.msg:find("`print` is `function", 1, true) ~= nil, errors.msg)
  assert(errors.msg:find("as a value of `{string: Value}`", 1, true) ~= nil, errors.msg)
  assert(errors.msg:find("`Value` is `Null`, `boolean`, `number`, `string`, `{Value}` or `{string: Value}`", 1, true) ~= nil, errors.msg)
  assert(errors.fix:find("one of the arms of `Value`", 1, true) ~= nil, errors.fix)
  -- An item of an array, deep inside.
  refuses(HEAD .. "local a = take({ { { 1, print } } })\nlocal _ = a\n", "not_assignable")
  refuses(HEAD .. "local a = take({ x = { y = { z = take } } })\nlocal _ = a\n", "not_assignable")
end

local function test_a_literal_with_no_items_or_mixed_items_has_no_arm_and_says_how_to_choose()
  local empty = refuses(HEAD .. "local a = take({})\nlocal _ = a\n", "literal_ambiguous")
  assert(empty.msg:find("no items", 1, true) ~= nil, empty.msg)
  assert(empty.fix:find("local v: {Value} = {}", 1, true) ~= nil or empty.fix:find("local v: {string: Value} = {}", 1, true) ~= nil,
    empty.fix)
  local mixed = refuses(HEAD .. "local a = take({ 1, k = 2 })\nlocal _ = a\n", "literal_shape")
  assert(mixed.msg:find("some by position and some by key", 1, true) ~= nil, mixed.msg)
  assert(mixed.msg:find("`{Value}`", 1, true) ~= nil and mixed.msg:find("`{string: Value}`", 1, true) ~= nil, mixed.msg)
  -- The empty literal typed as an arm is the arm.
  takes(HEAD .. "local e: {Value} = {}\nlocal f: {string: Value} = {}\nlocal _ = take(e) .. take(f)\n")
  -- A nested empty literal is the same question one level down.
  refuses(HEAD .. "local a = take({ x = {} })\nlocal _ = a\n", "literal_ambiguous")
end

local function test_a_value_that_is_none_of_the_arms_is_refused_with_the_arms_listed()
  local function none(declared: string, code: string)
    local errors = refuses(HEAD .. "local function g(x: " .. declared .. ")\n  local _ = take(x)\nend\nlocal _ = g\n", code)
    assert(code ~= "not_assignable" or errors.msg:find("`Value` is ", 1, true) ~= nil, errors.msg)
  end
  none("function()", "not_assignable")
  none("nil", "nil_not_allowed")
  none("string?", "nil_not_allowed")
  none("any", "any_use")
  none("{integer: string}", "not_assignable")
  none("{function()}", "not_assignable")
  none("{string: function()}", "not_assignable")
  none("{boolean: string}", "not_assignable")
  none("{string: {integer: boolean}}", "not_assignable")
  -- A record is none of them: it is no map, and its fields are not a map's values.
  refuses(HEAD .. "local record P\n  x: integer\nend\nlocal function g(p: P)\n  local _ = take(p)\nend\nlocal _ = g\n", "not_assignable")
  -- An enum is a string.
  takes(HEAD .. "local enum Color \"red\" end\nlocal function g(c: Color)\n  local _ = take(c)\nend\nlocal _ = g\n")
end

local function test_the_library_adds_its_advice_to_the_fix_of_the_alias_it_declares()
  local library = "local record Json\n  type Value = string | {Json.Value} | {string: Json.Value}\n  encode: function(v: Json.Value): string\nend\n" ..
    "function Json.encode(v: Json.Value): string\n  return \"x\"\nend\nreturn Json\n"
  local use = "local Json = require(\"cosmic.json\")\nlocal record P\n  x: integer\nend\nlocal function f(p: P): string\n  return Json.encode(p)\nend\nlocal _ = f\n"
  local r = Programs.run(use, { ["cosmic.json"] = library })
  assert(#r.before == 0, table.concat(r.before, " "))
  assert(Programs.codes(r) == "not_assignable", Programs.codes(r))
  local first = r.errors[1]
  assert(first ~= nil)
  local fix = first.fix
  assert(fix:find("one of the arms of `Json.Value`", 1, true) ~= nil and fix:find("call `Json.encode_any`", 1, true) ~= nil, fix)
  -- Another alias of the same shape has no advice but its arms.
  local other = Programs.run((use:gsub("cosmic.json", "other.json")), { ["other.json"] = library })
  assert(Programs.codes(other) == "not_assignable")
  local second = other.errors[1]
  assert(second ~= nil)
  local other_fix = second.fix
  assert(other_fix:find("encode_any", 1, true) == nil, other_fix)
end

local function test_a_test_narrows_a_value_of_the_alias_to_the_arms_it_holds()
  takes(HEAD .. "local function f(v: Value): integer\n  if v is string then\n    return #v\n  elseif v is number then\n    return 1\n  end\n  return 0\nend\nlocal _ = f\n")
  takes(HEAD .. "local function f(v: Value): string\n  if type(v) == \"string\" then\n    return v:upper()\n  end\n  return take(v)\nend\nlocal _ = f\n")
  takes(HEAD .. "local function f(v: Value): number\n  if type(v) == \"number\" then\n    return v + 1\n  end\n  return 0\nend\nlocal _ = f\n")
  takes(HEAD .. "local function f(v: Value?): string\n  if v == nil then\n    return \"\"\n  end\n  return take(v)\nend\nlocal _ = f\n")
  takes(HEAD .. "local function f(v: Value): boolean\n  return v == \"x\" or v == 1\nend\nlocal _ = f\n")
  -- What the test did not keep stays an alias's arms: the string is not a number.
  refuses(HEAD .. "local function f(v: Value): number\n  if v is string then\n    return v\n  end\n  return 0\nend\nlocal _ = f\n", "not_assignable")
  refuses(HEAD .. "local function f(v: Value): string\n  if type(v) == \"table\" then\n    return v:upper()\n  end\n  return \"\"\nend\nlocal _ = f\n", "field_unknown")
  -- What a test took out stays out: the rest of the arms is not the arm that was tested.
  refuses(HEAD .. "local function f(v: Value): string\n  if v is string then\n    return \"\"\n  end\n  return v\nend\nlocal _ = f\n", "not_assignable")
  refuses(HEAD .. "local function f(v: Value): number\n  if type(v) == \"table\" then\n    return 0\n  end\n  local n: number = v\n  return n\nend\nlocal _ = f\n", "not_assignable")
  takes(HEAD .. "local function f(v: Value): string\n  if type(v) == \"table\" or v is number or v is boolean or type(v) == \"userdata\" then\n    return take(v)\n  end\n  return v\nend\nlocal _ = f\n")
  -- A value of the alias is none of its arms until it is told: it has no length, no field and no element.
  refuses(HEAD .. "local function f(v: Value): integer\n  return #v\nend\nlocal _ = f\n", "operand_type")
  refuses(HEAD .. "local function f(v: Value): string\n  return v.name\nend\nlocal _ = f\n", "field_unknown")
  refuses(HEAD .. "local function f(v: Value): string\n  return v[1]\nend\nlocal _ = f\n", "not_indexable")
end

local function test_a_value_of_the_alias_moves_between_names_of_the_same_alias_and_no_other()
  takes(HEAD .. "local function f(a: Value): Value?\n  local b: Value = a\n  return b\nend\nlocal _ = f\n")
  takes(HEAD .. "local function f(a: {Value}): Value\n  return a\nend\nlocal _ = f\n")
  -- An alias with the same body under another name is another alias: the bodies would be compared for ever.
  refuses("local type A = string | {A}\nlocal type B = string | {B}\nlocal function f(a: A): B\n  return a\nend\nlocal _ = f\n", "not_assignable")
  refuses(HEAD .. "local function f(a: Value): number\n  return a\nend\nlocal _ = f\n", "not_assignable")
  refuses(HEAD .. "local function f(a: Value): string\n  return a\nend\nlocal _ = f\n", "not_assignable")
  refuses(HEAD .. "local function f(a: Value): {Value}\n  return a\nend\nlocal _ = f\n", "not_assignable")
  refuses(HEAD .. "local function f(a: Value?): Value\n  return a\nend\nlocal _ = f\n", "nil_not_allowed")
end

-- the Lua that runs ---------------------------------------------------------------------------------

local function test_the_literals_and_tests_of_the_alias_run_as_they_were_checked()
  runs(RUN_HEAD .. [[
local function kind(v: Value): string
  if v is string then
    return "s:" .. v
  elseif v is number then
    return "n:" .. tostring(v)
  elseif v is boolean then
    return "b"
  end
  return "t"
end
print(kind("a"), kind(1), kind(2.5), kind(true), kind({ 1 }), kind({ a = "x" }))
]], "s:a\tn:1\tn:2.5\tb\tt\tt")
  runs(RUN_HEAD .. [[
local doc: Value = { name = "x", n = 1, tags = { "a", "b" }, nested = { deep = { 1, { true } } } }
local function is_table(v: Value): boolean
  return type(v) == "table"
end
print(is_table(doc), is_table("s"), is_table({ { 1 }, { 2 } }), is_table({ a = 1 }), is_table(2.5))
]], "true\tfalse\ttrue\ttrue\tfalse")
end

local function test_a_test_of_the_alias_itself_is_refused_as_a_test_of_an_array_is()
  -- Its arms hold arrays and maps, which a run-time tag does not tell from other tables.
  local errors = refuses(HEAD .. "local function is_value(v: any): boolean\n  return v is Value\nend\nlocal _ = is_value\n", "is_on_record")
  assert(errors.msg:find("cannot be told by a run-time tag", 1, true) ~= nil, errors.msg)
  takes(HEAD .. "local function is_text(v: any): boolean\n  return v is string or v is number\nend\nlocal _ = is_text\n")
end

local function test_a_value_the_alias_takes_is_a_value_it_names_at_run_time()
  -- The values the checker takes for the alias: each is a string, a number, a boolean, or a table of these, to any depth.
  runs(RUN_HEAD .. [[
local function shape(v: Value): string
  if v is string then
    return "string"
  elseif v is number then
    return "number"
  elseif v is boolean then
    return "boolean"
  end
  return "table"
end
local words: {string} = { "a", "b" }
local counts: {string: integer} = { a = 1 }
local nested: {{string}} = { { "a" }, {} }
local mutable: mut {string} = { "x" }
print(shape(words), shape(counts), shape(nested), shape(mutable))
]], "table\ttable\ttable\ttable")
end
