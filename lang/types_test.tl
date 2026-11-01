--- Tests of [`lang.types`]: each form made and displayed, interning, the normal form of a union,
--- the function type's normal form, declarations, and the text a type is written as and read
--- from. The properties over random types are in [`lang.types_fuzz_test`].
local Programs = require("lang.types_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{ cpu_features = true }

local record World
  store: Types.Store
  fixture: Programs.Fixture
end

local function world(): World
  local store = Types.new()
  return { store = store, fixture = Programs.fixture(store) }
end

--- The declaration the fixture makes under `name`.
local function declared(w: World, name: string): Types.Decl
  local decl = assert(w.fixture.decls[name], "the fixture declares " .. name)
  return decl
end

local function named(w: World, name: string, args?: {Types.Type}): Types.Type
  return w.store:named(declared(w, name), args)
end

--- `list` back to front.
local function reversed_copy(list: {Types.Type}): {Types.Type}
  local out: mut {Types.Type} = {}
  for i = #list, 1, -1 do
    local item = assert(list[i], "`i` is within the list")
    out[#out + 1] = item
  end
  return out
end

local function shown(t: Types.Type): string
  return Types.display(t)
end

local function a_union(t: Types.Type): Types.Union
  if (t.tag == "union") then
    return t
  end
  error("not a union: " .. shown(t), 2)
end

local function a_fn(t: Types.Type): Types.Fn
  if (t.tag == "fn") then
    return t
  end
  error("not a function: " .. shown(t), 2)
end

local function same(got: string, want: string)
  assert(got == want, "\n   got: " .. got .. "\n  want: " .. want)
end

--- Whether `f` raises an error that holds `fragment`.
local function raises(f: function(), fragment: string): boolean
  local ok, why = pcall(function()
    f()
  end)
  return not ok and tostring(why):find(fragment, 1, true) ~= nil
end

--- A loader that answers from the declarations of `store`.
local function loading_from(store: Types.Store): Types.Loader
  return function(module: string, name: string): string?
    local decl = store:find(module, name)
    return decl ~= nil and Types.encode_declaration(decl) or nil
  end
end

-- forms and display ------------------------------------------------------------

local function test_an_atom_displays_as_it_is_spelled()
  local store = Types.new()
  local names: {Types.Atom_tag} = { "integer", "number", "string", "boolean", "true", "false", "nil", "never", "any" }
  for _, name in ipairs(names) do
    local t = store:atom(name)
    same(shown(t), name)
    assert(t.tag == name and store:atom(name) == t)
  end
  same(shown(store.invalid), "invalid")
end

local function test_collections_display_as_views_and_mut()
  local s = Types.new()
  same(shown(s:array(s.integer)), "{integer}")
  same(shown(s:array(s.integer, true)), "mut {integer}")
  same(shown(s:map(s.string, s.integer)), "{string: integer}")
  same(shown(s:map(s.string, s:optional(s.integer), true)), "mut {string: integer?}")
  same(shown(s:array(s:union({ s.integer, s.string }))), "{integer | string}")
  assert(s:array(s.integer) ~= s:array(s.integer, true), "mut is part of the type")
  assert(s:map(s.string, s.integer) ~= s:map(s.string, s.integer, true))
end

local function test_a_named_type_is_its_declaration_and_arguments()
  local w = world()
  local s = w.store
  same(shown(named(w, "Node")), "Node")
  same(shown(named(w, "Stream.Reader")), "Stream.Reader")
  same(shown(named(w, "List", { s.integer })), "List<integer>")
  same(shown(named(w, "Pair", { s.string, named(w, "List", { s.integer }) })), "Pair<string, List<integer>>")
  assert(named(w, "List", { s.integer }) == named(w, "List", { s.integer }))
  assert(named(w, "List", { s.integer }) ~= named(w, "List", { s.string }))
  assert(named(w, "Node") ~= named(w, "Tree"))
end

local function test_an_optional_displays_with_a_question_mark_and_parentheses_where_needed()
  local s = Types.new()
  same(shown(s:optional(s.string)), "string?")
  same(shown(s:union({ s.integer, s.string, s:atom("nil") })), "(integer | string)?")
  same(shown(s:optional(s:array(s.string, true))), "mut {string}?")
  same(shown(s:optional(s:fn({}))), "(function())?")
  same(shown(s:union({ s:fn({}), s.string })), "string | (function())")
  same(shown(s:atom("nil")), "nil")
end

local function test_a_union_displays_in_the_order_that_reads_best_whatever_the_order_given()
  local w = world()
  local s = w.store
  local members = { named(w, "Node"), s.string, s:array(s.integer), s.integer, s:atom("true") }
  same(shown(s:union(members)), "integer | string | true | Node | {integer}")
  local reversed = reversed_copy(members)
  same(shown(s:union(reversed)), "integer | string | true | Node | {integer}")
end

local function test_a_function_type_displays_its_parts()
  local w = world()
  local s = w.store
  same(shown(s:fn({})), "function()")
  same(shown(s:fn({ params = { { type = s.string }, { type = s.integer } }, rets = { { items = { s.boolean } } } })),
    "function(string, integer): boolean")
  same(shown(s:fn({ params = { { type = s.string, omittable = true }, { type = s.integer, omittable = true } } })),
    "function(p1?: string, p2?: integer)")
  same(shown(s:fn({ params = { { type = s.string } }, rest = s.integer, rets = { { items = { s.string, s.integer } } } })),
    "function(string, ...: integer): string, integer")
  same(shown(s:fn({ rets = { { items = { s.string }, tail = s.integer } } })), "function(): string, integer...")
  same(shown(s:fn({ rets = { { items = {}, tail = s.integer } } })), "function(): integer...")
  same(shown(s:fn({ rets = {} })), "function(): never")
  same(shown(s:fn({ rets = { { items = { s:fn({}) } } } })), "function(): (function())")
  same(shown(s:fn({ rets = { { items = { s:fn({}), s.string } } } })), "function(): ((function()), string)")
  same(shown(s:fn({ rets = { { items = { s.string }, tail = s:optional(s:union({ s.string, s.integer })) } } })),
    "function(): string, (integer | string)?...")
  same(shown(s:fn({ rets = { { items = {}, tail = s:optional(s:union({ s.string, s.integer })) } } })),
    "function(): ((integer | string)?...)")
  same(shown(s:fn({ params = { { type = s:fn({}) } } })), "function(function())")
end

local function test_a_function_type_before_a_comma_or_a_colon_is_parenthesized()
  local w = world()
  local s = w.store
  local callback = s:fn({ rets = { { items = { s.integer } } } })
  same(shown(s:fn({ params = { { type = callback }, { type = s.string } } })), "function((function(): integer), string)")
  same(shown(s:fn({ params = { { type = s.string }, { type = callback } } })), "function(string, function(): integer)")
  same(shown(s:fn({ params = { { type = callback } }, rest = s.string })), "function((function(): integer), ...: string)")
  same(shown(s:fn({ params = { { type = callback, omittable = true }, { type = s.string } } })),
    "function(p1?: (function(): integer), string)")
  same(shown(named(w, "Pair", { callback, s.string })), "Pair<(function(): integer), string>")
  same(shown(s:map(callback, s.string)), "{(function(): integer): string}")
  same(shown(s:map(s.string, callback)), "{string: function(): integer}")
  same(shown(s:array(callback)), "{function(): integer}")
end

local function test_a_union_of_function_types_as_the_one_return_is_parenthesized_whole()
  local s = Types.new()
  local one = s:fn({ rets = { { items = { s.integer } } } })
  local other = s:fn({ rets = { { items = { s.string } } } })
  same(shown(s:fn({ rets = { { items = { s:union({ one, other }) } } } })),
    "function(): ((function(): integer) | (function(): string))")
  same(shown(s:fn({ rets = { { items = { s:union({ one, other }) }, tail = s.integer } } })),
    "function(): ((function(): integer) | (function(): string), integer...)")
end

local function test_alternatives_display_as_a_union_of_lists_with_true_before_false()
  local s = Types.new()
  same(shown(s:fn({ rets = {
    { items = { s:atom("false"), s.any } },
    { items = { s:atom("true"), s.string } },
  } })), "function(): (true, string) | (false, any)")
  same(shown(s:fn({ rets = { { items = { s.string } }, { items = { s.integer } } } })),
    "function(): (integer) | (string)")
  same(shown(s:fn({ rets = { { items = { s:union({ s.string, s.integer }) } } } })), "function(): integer | string")
end

local function test_a_narrowing_declaration_names_its_parameter_by_position()
  local w = world()
  local s = w.store
  local reader = named(w, "Stream.Reader")
  same(shown(s:fn({ params = { { type = s.any } }, rets = { { items = {}, narrows = { param = 1, to = reader, asserts = false } } } })),
    "function(p1: any): p1 is Stream.Reader")
  same(shown(s:fn({ params = { { type = s:optional(reader) }, { type = s.string } },
    rets = { { items = {}, narrows = { param = 2, to = s.string, asserts = true } } } })),
    "function(Stream.Reader?, p2: string): asserts p2 is string")
end

local function test_a_generic_function_names_its_variables_by_binder_and_bound()
  local w = world()
  local s = w.store
  local a = s:var(0, 0)
  same(shown(s:fn({ tparams = { {} }, params = { { type = s:array(a) }, { type = a } } })), "function<T>({T}, T)")
  same(shown(s:fn({ tparams = { { bound = named(w, "Stream.Reader") }, {} },
    params = { { type = s:var(0, 1) } }, rets = { { items = { s:var(0, 0) } } } })),
    "function<T is Stream.Reader, U>(U): T")
  local inner = s:fn({ tparams = { {} }, params = { { type = s:var(1, 0) }, { type = s:var(0, 0) } } })
  same(shown(s:fn({ tparams = { {} }, params = { { type = inner } } })), "function<T>(function<T_1>(T, T_1))")
  same(shown(s:var(0, 0)), "?0.0")
  same(Types.display(s:var(0, 1), { { "K", "V" } }), "V")
end

local function test_never_and_any_and_invalid_are_the_forms_they_are()
  local s = Types.new()
  assert(s.never.tag == "never" and s.any.tag == "any" and s.invalid.tag == "invalid")
  assert(s.never ~= s.any and s.any ~= s.invalid)
end

--- What `t` is, told by its tag alone: each branch reads what only its form has, and the chain covers every form of
--- [`Types.Type`], so the last return is the atoms'.
local function describe(t: Types.Type): string
  if t.tag == "named" then
    return t.decl.name .. "/" .. tostring(#t.args)
  elseif t.tag == "array" then
    return "{" .. describe(t.element) .. "}"
  elseif t.tag == "map" then
    return "{" .. describe(t.key) .. ": " .. describe(t.value) .. "}"
  elseif t.tag == "union" then
    return "union of " .. tostring(#t.members) .. (if t.nilable then " and nil" else "" end)
  elseif t.tag == "var" then
    return "var " .. tostring(t.depth) .. "." .. tostring(t.index)
  elseif t.tag == "fn" then
    return "fn of " .. tostring(#t.params)
  end
  assert(t.atom == true, "a form this test does not know")
  return t.tag
end

local function test_a_type_is_told_from_the_other_forms_by_its_tag()
  local w = world()
  local s = w.store
  same(describe(s.integer), "integer")
  same(describe(s:atom("invalid")), "invalid")
  same(describe(named(w, "List", { s.integer })), "List/1")
  same(describe(s:array(s.string)), "{string}")
  same(describe(s:map(s.string, s.integer, true)), "{string: integer}")
  same(describe(s:union({ s.string, s:atom("nil") })), "union of 1 and nil")
  same(describe(s:union({ s.string, s.boolean })), "union of 2")
  same(describe(s:var(1, 2)), "var 1.2")
  same(describe(s:fn({ params = { { type = s.string } }, rets = { { items = { s.integer } } } })), "fn of 1")
end

local function test_only_the_ten_first_types_of_a_store_are_atoms()
  local w = world()
  local s = w.store
  local _ = named(w, "Node")
  local _ = s:array(s.string)
  assert(#s.types > 10)
  for i, t in ipairs(s.types) do
    assert((t.atom == true) == (i <= 10), "type " .. tostring(i) .. " " .. shown(t))
  end
end

-- interning ----------------------------------------------------------------------

local function test_equal_parts_make_one_object_for_each_form()
  local w = world()
  local s = w.store
  local function twice(make: function(): Types.Type)
    local first = make()
    local count = s:size()
    assert(make() == first, shown(first))
    assert(s:size() == count, "a second making of " .. shown(first) .. " adds a type")
  end
  twice(function(): Types.Type return s:array(s.string) end)
  twice(function(): Types.Type return s:map(s.string, s.integer, true) end)
  twice(function(): Types.Type return s:union({ s.string, s.integer, s:atom("nil") }) end)
  twice(function(): Types.Type return s:var(1, 2) end)
  twice(function(): Types.Type return named(w, "Pair", { s.string, s.integer }) end)
  twice(function(): Types.Type
    return s:fn({ tparams = { { bound = named(w, "Stream.Reader") } }, params = { { type = s:var(0, 0), omittable = true } },
      rest = s.string, rets = { { items = { s.integer }, tail = s.string } } })
  end)
end

local function test_a_type_of_another_store_is_refused()
  local a, b = Types.new(), Types.new()
  assert(raises(function() local _ = a:array(b.integer) end, "another store"))
  assert(raises(function() local _ = a:union({ a.integer, b.string }) end, "another store"))
  assert(raises(function() local _ = a:fn({ params = { { type = b.integer } } }) end, "another store"))
  local decl = b:declare("record", "m", { "R" })
  assert(raises(function() local _ = a:named(decl) end, "another store"))
end

local function test_a_variable_and_a_declaration_refuse_what_cannot_be_one()
  local s = Types.new()
  assert(raises(function() local _ = s:var(-1, 0) end, "variable"))
  assert(raises(function() local _ = s:declare("record", "m", {}) end, "name"))
  assert(raises(function() local _ = s:declare("record", "m", { "a.b" }) end, "lexer reads"))
  assert(raises(function() local _ = s:declare("record", "", { "R" }) end, "module"))
end

local function test_open_counts_the_binders_a_type_reaches_outside_itself()
  local s = Types.new()
  assert(s.integer.open == 0)
  assert(s:var(0, 0).open == 1 and s:var(2, 0).open == 3)
  assert(s:array(s:var(1, 0)).open == 2)
  local closed = s:fn({ tparams = { {} }, params = { { type = s:var(0, 0) } } })
  assert(closed.open == 0, "its own variable is bound by it")
  local reaching = s:fn({ tparams = { {} }, params = { { type = s:var(1, 0) } } })
  assert(reaching.open == 1)
  local plain = s:fn({ params = { { type = s:var(0, 0) } } })
  assert(plain.open == 1, "a function with no type parameters binds nothing")
  assert(closed == s:fn({ tparams = { {} }, params = { { type = s:var(0, 0) } } }), "a closed signature is one type")
end

local function test_has_mut_says_whether_a_view_of_the_type_differs()
  local w = world()
  local s = w.store
  assert(not s.integer.has_mut and not s:array(s.integer).has_mut)
  assert(s:array(s.integer, true).has_mut)
  assert(s:array(s:array(s.integer, true)).has_mut)
  assert(s:map(s.string, s:array(s.integer, true)).has_mut)
  assert(s:optional(s:array(s.integer, true)).has_mut)
  assert(s:union({ s.string, s:array(s.integer, true) }).has_mut)
  assert(not named(w, "List", { s:array(s.integer, true) }).has_mut, "a view does not reach through a named type")
  assert(not s:fn({ params = { { type = s:array(s.integer, true) } } }).has_mut)
end

-- unions ----------------------------------------------------------------------------

local function test_a_union_flattens_and_drops_repeats_and_never()
  local s = Types.new()
  local flat = s:union({ s.string, s.integer, s.boolean })
  assert(s:union({ s:union({ s.string, s.integer }), s.boolean }) == flat)
  assert(s:union({ s.boolean, s.string, s.integer, s.string, s.never }) == flat)
  assert(s:union({ s.integer, s.integer }) == s.integer)
  assert(s:union({}) == s.never and s:union({ s.never, s.never }) == s.never)
  assert(s:union({ s.string }) == s.string)
end

local function test_nil_is_a_flag_beside_the_other_members()
  local s = Types.new()
  local nil_type = s:atom("nil")
  local optional = s:optional(s.string)
  assert(s:union({ s.string, nil_type }) == optional and s:union({ nil_type, s.string }) == optional)
  assert(s:optional(optional) == optional and s:union({ optional, nil_type }) == optional)
  assert(#a_union(optional).members == 1 and a_union(optional).nilable)
  local both = s:union({ s.string, s.integer, nil_type })
  assert(#a_union(both).members == 2 and a_union(both).nilable)
  assert(s:union({ optional, s.integer }) == both, "an optional member lends its nil")
  assert(s:union({ nil_type, nil_type }) == nil_type and s:union({ nil_type, s.never }) == nil_type)
  assert(s:optional(nil_type) == nil_type and s:optional(s.never) == nil_type)
  assert(s:non_nil(both) == s:union({ s.string, s.integer }) and s:non_nil(optional) == s.string)
  assert(s:non_nil(nil_type) == s.never and s:non_nil(s.string) == s.string)
end

local function test_nil_is_never_absorbed_by_a_member_that_is_not_any()
  local w = world()
  local s = w.store
  for _, t in ipairs({ s.string, s.number, s.boolean, s:array(s.integer), named(w, "Node"), named(w, "Color"),
      s:fn({}) }) do
    local optional = s:optional(t)
    assert(optional ~= t and a_union(optional).nilable, shown(t))
  end
end

local function test_any_absorbs_every_member_and_invalid_absorbs_any()
  local s = Types.new()
  assert(s:union({ s.string, s.any, s.integer }) == s.any)
  assert(s:union({ s.any, s:atom("nil") }) == s.any and s:optional(s.any) == s.any)
  assert(s:union({ s.any, s.never }) == s.any)
  assert(s:union({ s.string, s.invalid, s.any }) == s.invalid)
end

local function test_three_pairs_collapse()
  local w = world()
  local s = w.store
  local yes, no = s:atom("true"), s:atom("false")
  assert(s:union({ s.integer, s.number }) == s.number)
  assert(s:union({ s.integer, s.number, s.string }) == s:union({ s.number, s.string }))
  assert(s:union({ yes, no }) == s.boolean)
  assert(s:union({ yes, s.boolean }) == s.boolean and s:union({ no, s.boolean, yes }) == s.boolean)
  assert(s:union({ yes, no, s.string }) == s:union({ s.boolean, s.string }))
  assert(#a_union(s:union({ yes, s.string })).members == 2)
  local color = named(w, "Color")
  assert(s:union({ color, s.string }) == s.string)
  assert(s:union({ color, s.string, s.integer }) == s:union({ s.string, s.integer }))
  assert(a_union(s:union({ color, s.integer })), "an enum collapses into string alone")
  assert(s:union({ s.boolean, s:atom("nil") }) == s:optional(s.boolean))
  assert(s:union({ yes, no, s:atom("nil") }) == s:optional(s.boolean))
end

local function test_a_union_searches_no_other_subsumption()
  local w = world()
  local s = w.store
  local file, reader = named(w, "File"), named(w, "Stream.Reader")
  local both = s:union({ file, reader })
  assert(#a_union(both).members == 2 and both ~= reader and both ~= file)
  local plain = s:array(s.integer)
  assert(a_union(s:union({ plain, s:array(s.number) })))
  assert(a_union(s:union({ plain, s:array(s.integer, true) })))
end

local function test_a_union_is_the_same_whatever_the_order_it_is_made_in_and_the_store_it_is_made_in()
  local a, b = world(), world()
  -- The second store makes other types first, so that its ids differ from the first's.
  local _ = b.store:array(b.store.string)
  _ = named(b, "List", { b.store.integer })
  local function members(w: World): {Types.Type}
    local s = w.store
    return { named(w, "Node"), s.string, s:array(s.integer), s:fn({ rets = { { items = { s.integer } } } }), s:var(0, 0),
      s:atom("nil"), s:map(s.string, s.number), named(w, "Color") }
  end
  local first = Types.encode(a.store:union(members(a)))
  local flipped = reversed_copy(members(b))
  same(Types.encode(b.store:union(flipped)), first)
end

-- functions -----------------------------------------------------------------------------

local function test_the_alternatives_of_a_function_are_a_set()
  local s = Types.new()
  local yes, no = s:atom("true"), s:atom("false")
  local one = s:fn({ rets = { { items = { yes, s.string } }, { items = { no, s.any } } } })
  assert(s:fn({ rets = { { items = { no, s.any } }, { items = { yes, s.string } } } }) == one)
  assert(s:fn({ rets = { { items = { no, s.any } }, { items = { yes, s.string } }, { items = { no, s.any } } } }) == one)
  assert(#a_fn(one).rets == 2)
end

local function test_an_alternative_with_never_in_it_is_no_list()
  local s = Types.new()
  local never_returns = s:fn({ rets = {} })
  assert(#a_fn(never_returns).rets == 0)
  assert(s:fn({ rets = { { items = { s.string, s.never } } } }) == never_returns)
  assert(s:fn({ rets = { { items = { s.never } }, { items = { s.string } } } }) == s:fn({ rets = { { items = { s.string } } } }))
  assert(s:fn({ rets = { { items = { s.string }, tail = s.never } } }) == s:fn({ rets = { { items = { s.string } } } }))
  assert(s:fn({}) ~= never_returns, "a function with no return annotation answers nothing and does return")
  local answers = a_fn(s:fn({})).rets
  local only = answers[1]
  assert(#answers == 1 and only ~= nil and #only.items == 0)
end

local function test_an_omittable_parameter_is_typed_optional_inside()
  local s = Types.new()
  local f = s:fn({ params = { { type = s.string, omittable = true } } })
  local param = a_fn(f).params[1]
  assert(param ~= nil and param.omittable == true and param.type == s:optional(s.string))
  assert(f == s:fn({ params = { { type = s:optional(s.string), omittable = true } } }))
  assert(f ~= s:fn({ params = { { type = s:optional(s.string) } } }), "string? is required, name?: string is not")
end

local function test_a_narrowing_declaration_answers_a_boolean_or_nothing()
  local s = Types.new()
  local is_string = s:fn({ params = { { type = s.any } }, rets = { { items = { s.integer }, narrows = { param = 1, to = s.string, asserts = false } } } })
  local alt = a_fn(is_string).rets[1]
  assert(alt ~= nil and #alt.items == 1 and alt.items[1] == s.boolean, "the store fills the value list in")
  local asserts_string = s:fn({ params = { { type = s.any } }, rets = { { items = {}, narrows = { param = 1, to = s.string, asserts = true } } } })
  local asserting = a_fn(asserts_string).rets[1]
  assert(asserting ~= nil and #asserting.items == 0)
  assert(is_string ~= asserts_string)
  assert(raises(function()
    local _ = s:fn({ rets = { { items = {}, narrows = { param = 0, to = s.string, asserts = true } } } })
  end, "parameter"))
  assert(raises(function()
    local _ = s:fn({ params = { { type = s.any } }, rets = { { items = {}, narrows = { param = 2, to = s.string, asserts = true } } } })
  end, "names parameter 2 of 1"))
end

local function test_a_narrowing_declaration_is_the_whole_return_list()
  local s = Types.new()
  assert(raises(function()
    local _ = s:fn({ params = { { type = s.any } }, rets = { { items = { s.string } },
      { items = {}, narrows = { param = 1, to = s.string, asserts = true } } } })
  end, "whole return list"))
end

local function test_a_function_type_holds_no_parameter_names()
  local s = Types.new()
  assert(s:fn({ params = { { type = s.string } } }) == s:fn({ params = { { type = s.string } } }))
  assert(s:fn({ params = { { type = s.string } } }) ~= s:fn({ params = { { type = s.string }, { type = s.string } } }))
end

-- declarations ------------------------------------------------------------------------------

local function test_a_declaration_is_found_by_its_path_and_made_once()
  local s = Types.new()
  local r = s:declare("record", "m", { "Outer", "R" })
  assert(s:declare("record", "m", { "Outer", "R" }) == r)
  assert(s:find("m", "Outer.R") == r and s:find("m", "R") == nil and s:find("n", "Outer.R") == nil)
  assert(r.name == "Outer.R" and r.module == "m" and #r.names == 2)
  assert(raises(function() local _ = s:declare("class", "m", { "Outer", "R" }) end, "declared as a record"))
  assert(#s:declarations() == 1)
  assert(s:declare("record", "n", { "Outer", "R" }) ~= r, "the module is part of the path")
end

local function test_a_body_is_given_once_and_must_suit_the_kind()
  local s = Types.new()
  local r = s:declare("record", "m", { "R" })
  local e = s:declare("enum", "m", { "E" })
  local empty: Types.Body = { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} }
  assert(raises(function()
    local _ = s:define(r, { tparams = {}, supers = {}, fields = {}, methods = {}, values = { "a" } })
  end, "only an enum"))
  assert(raises(function()
    local _ = s:define(e, { tparams = {}, supers = {}, fields = { { name = "x", type = s.string } }, methods = {}, values = {} })
  end, "enum"))
  assert(raises(function()
    local _ = s:define(e, { tparams = {}, supers = {}, fields = {}, methods = {}, values = { "a", "a" } })
  end, "twice"))
  assert(raises(function()
    local _ = s:define(r, { tparams = {}, supers = { s.string }, fields = {}, methods = {}, values = {} })
  end, "named"))
  assert(raises(function()
    local _ = s:define(r, { tparams = {}, supers = {}, fields = {}, values = {},
      methods = { { name = "m", type = s.string } } })
  end, "function"))
  assert(s:define(r, empty) == r and r.body ~= nil)
  assert(raises(function() local _ = s:define(r, empty) end, "has a body"))
end

local function test_a_recursive_declaration_is_a_type_like_any_other()
  local w = world()
  local s = w.store
  local node = named(w, "Node")
  local body = declared(w, "Node").body
  assert(body ~= nil and body.array == node)
  local next_field = body.fields[2]
  assert(next_field ~= nil and next_field.type == s:optional(node) and next_field.omittable == true)
  assert(s:array(node) == s:array(named(w, "Node")))
  local tree, forest = declared(w, "Tree").body, declared(w, "Forest").body
  assert(tree ~= nil and forest ~= nil, "Tree and Forest are defined")
  local kids = tree.fields[1]
  assert(kids ~= nil and kids.type == named(w, "Forest") and forest.array == named(w, "Tree"))
end

-- text --------------------------------------------------------------------------------------

local function test_the_text_of_each_form_is_the_draft_s()
  local w = world()
  local s = w.store
  local reader = named(w, "Stream.Reader")
  same(Types.encode(s.integer), "integer")
  same(Types.encode(s:atom("nil")), "nil")
  same(Types.encode(s:array(reader)), '(array (ref "cosmic.stream" "Stream.Reader"))')
  same(Types.encode(s:array(s.string, true)), "(marray string)")
  same(Types.encode(s:map(s.string, s.integer)), "(map string integer)")
  same(Types.encode(s:map(s.string, s:optional(named(w, "Handle")), true)), '(mmap string (union (ref "m" "Handle") nil))')
  same(Types.encode(s:optional(s.string)), "(union string nil)")
  same(Types.encode(named(w, "Pair", { s.string, s.integer })), '(ref "m" "Pair" string integer)')
  same(Types.encode(s:var(1, 2)), "(var 1 2)")
  same(Types.encode(s:fn({ tparams = { { bound = reader } }, params = { { type = s:var(0, 0) } },
    rets = { { items = { s:var(0, 0) } } } })), '(fn (tp (ref "cosmic.stream" "Stream.Reader")) ((var 0 0)) (rets ((var 0 0))))')
  same(Types.encode(s:fn({ tparams = { {} }, params = { { type = s.string, omittable = true } }, rest = s.integer,
    rets = { { items = { s.string }, tail = s.integer } } })),
    "(fn (tp _) ((opt (union string nil)) (rest integer)) (rets (string (... integer))))")
  same(Types.encode(s:fn({ rets = {} })), "(fn (tp) () (rets))")
  same(Types.encode(s:fn({})), "(fn (tp) () (rets ()))")
  same(Types.encode(s:fn({ params = { { type = s.any } }, rets = { { items = {}, narrows = { param = 1, to = s.string, asserts = true } } } })),
    "(fn (tp) (any) (rets ((asserts 1 string))))")
end

local function test_the_plans_example_of_alternatives_is_the_text_of_a_function()
  local s = Types.new()
  local f, why = s:decode('(fn (tp) () (rets (true string) (false any)))')
  assert(f ~= nil, why)
  same(shown(f), "function(): (true, string) | (false, any)")
  -- The alternatives are written in the order of their digests.
  local yes = Types.digest(s:atom("true")) .. " " .. Types.digest(s.string)
  local no = Types.digest(s:atom("false")) .. " " .. Types.digest(s.any)
  if yes < no then
    same(Types.encode(f), '(fn (tp) () (rets (true string) (false any)))')
  else
    same(Types.encode(f), '(fn (tp) () (rets (false any) (true string)))')
  end
end

local function test_the_text_of_a_union_depends_on_structure_alone()
  local a, b = Types.new(), Types.new()
  local _ = b:array(b.number)
  local x = Types.encode(a:union({ a.integer, a.string, a:array(a.boolean), a:atom("nil") }))
  local y = Types.encode(b:union({ b:atom("nil"), b:array(b.boolean), b.string, b.integer }))
  same(y, x)
  assert(x:sub(1, 7) == "(union " and x:sub(-5) == " nil)")
end

local function test_a_string_in_the_text_is_escaped()
  local s = Types.new()
  local weird = s:declare("record", 'a "m"\\x\n', { "R" })
  s:define(weird, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} })
  local text = Types.encode(s:named(weird))
  same(text, '(ref "a \\034m\\034\\092x\\010" "R")')
  local t, why = s:decode(text)
  assert(t == s:named(weird), why)
end

local function test_text_decodes_to_the_same_type_in_the_store_and_in_another()
  local w = world()
  local s = w.store
  local second = Types.new(loading_from(s))
  local samples = {
    s.integer, s:optional(s.string), s:map(s.string, s:array(named(w, "Node"), true), true),
    named(w, "Pair", { s.string, named(w, "List", { named(w, "Tree") }) }),
    s:fn({ tparams = { { bound = named(w, "Stream.Reader") }, {} }, params = { { type = s:var(0, 1), omittable = true } },
      rest = s:var(0, 0), rets = { { items = { s:atom("true"), s:var(0, 0) } }, { items = { s:atom("false"), s.any } } } }),
    s:union({ named(w, "File"), named(w, "Color"), s.integer, s:atom("nil") }),
  }
  for _, t in ipairs(samples) do
    local text = Types.encode(t)
    assert(s:decode(text) == t, text)
    local there, why = second:decode(text)
    assert(there ~= nil, why)
    same(Types.encode(there), text)
    same(shown(there), shown(t))
    assert(second:decode(text) == there, "decoding again finds the one type")
  end
  assert(second:find("m", "Tree") ~= nil and second:find("m", "Forest") ~= nil, "a declaration the text reaches is loaded")
  assert(second:find("m", "Handle") == nil, "and no other")
end

local function test_a_declaration_used_as_a_value_is_a_type_of_its_own_in_text_and_in_every_store()
  local w = world()
  local s = w.store
  local second = Types.new(loading_from(s))
  local decl = declared(w, "File")
  local instance, value = s:named(decl), s:named(decl, {}, true)
  assert(instance ~= value and (value.tag == "named") and value.value and (instance.tag == "named") and not instance.value)
  assert(s:named(decl, {}, true) == value and s:named(decl, nil, false) == instance, "each is interned")
  assert(Types.digest(instance) ~= Types.digest(value))
  same(shown(value), "File (declaration)")
  same(shown(s:optional(value)), "File (declaration)?")
  same(Types.encode(value), '(val "m" "File")')
  assert(s:decode('(val "m" "File")') == value and s:decode('(ref "m" "File")') == instance)
  local there, why = second:decode('(val "m" "File")')
  assert(there ~= nil and (there.tag == "named") and there.value, why)
  same(Types.encode(there), '(val "m" "File")')
  local both = a_union(s:union({ instance, value }))
  assert(#both.members == 2, "a declaration and its value do not collapse into one")
end

local function test_decoding_normalizes_text_that_is_not_canonical()
  local s = Types.new()
  assert(s:decode("(union integer number)") == s.number)
  assert(s:decode("(union string (union integer nil) never)") == s:union({ s.string, s.integer, s:atom("nil") }))
  assert(s:decode("(union)") == s.never and s:decode("(union nil)") == s:atom("nil"))
  assert(s:decode("  ( array\n integer )  ") == s:array(s.integer))
  assert(s:decode("(fn (tp) ((opt string)) (rets () ()))") == s:fn({ params = { { type = s.string, omittable = true } } }))
end

local function test_text_that_is_not_a_type_is_refused_with_a_reason()
  local s = Types.new()
  local bad = {
    "", "(", ")", "(array)", "(array integer", "(array integer integer)", "integer integer", "(frob integer)",
    "frob", '(ref "m" "R")', '(ref "m")', "(var 1)", "(var -1 0)", "(var 1 x)", "(fn (tp) ())", "(fn (tp) () (rets (1)))",
    '(ref "m" "R\\0', '(ref "m" "R\\999")', "(map integer)", "(fn (tp _ _) ((rest integer integer)) (rets))", "(array \"s\")",
  }
  for _, text in ipairs(bad) do
    local t, why = s:decode(text)
    assert(t == nil and why ~= "", "text " .. text .. " decoded")
    assert(why:find("types:", 1, true) == 1, why)
  end
  local count = s:size()
  local t = s:decode("(array (array")
  assert(t == nil and s:size() == count, "a refused text adds no type")
end

local function test_a_deeply_nested_type_has_text_that_decodes_and_text_past_the_limit_is_refused()
  local s = Types.new()
  local t = s.integer
  for _ = 1, 999 do
    t = s:array(t)
  end
  local text = Types.encode(t)
  assert(Types.new():decode(text) ~= nil, "a type nested 1000 deep reads back")
  assert(s:decode(text) == t)
  assert(#Types.display(t) > 1000 and #Types.digest(t) == 32)
  local deeper, why = s:decode(("(array "):rep(1001) .. "integer" .. (")"):rep(1001))
  assert(deeper == nil and why:find("deeper", 1, true) ~= nil, why)
  -- A store refuses the type itself past that, so that no walk of a type runs out of stack.
  local count = s:size()
  assert(raises(function()
    local _ = s:array(t)
  end, "deeper than 1000"))
  assert(s:size() == count)
end

local function test_a_declaration_has_text_that_decodes_to_the_same_declaration()
  local w = world()
  local second = Types.new(loading_from(w.store))
  for _, name in ipairs({ "Node", "Tree", "Forest", "List", "Pair", "Stream.Reader", "File", "Color", "Handle" }) do
    local decl = declared(w, name)
    local text = Types.encode_declaration(decl)
    local there, why = second:decode_declaration(text)
    assert(there ~= nil, name .. ": " .. why)
    same(Types.encode_declaration(there), text)
    assert(second:decode_declaration(text) == there, "a declaration the store has is returned as it is")
  end
  same(Types.encode_declaration(declared(w, "Color")),
    '(decl enum "m" "Color" (tparams) (supers) (fields) (elements) (methods) (values "red" "green" "blue"))')
  local node = Types.encode_declaration(declared(w, "Node"))
  assert(node:find('(field "next" (opt (union (ref "m" "Node") nil)))', 1, true) ~= nil, node)
  assert(node:find('(elements (ref "m" "Node"))', 1, true) ~= nil, node)
  assert(Types.encode_declaration(declared(w, "List")):find('(tparam "T")', 1, true) ~= nil)
  assert(Types.encode_declaration(declared(w, "File")):find('(field "open" mut boolean)', 1, true) ~= nil)
end

local function test_a_declaration_without_a_body_has_no_text()
  local s = Types.new()
  local r = s:declare("record", "m", { "R" })
  assert(raises(function() local _ = Types.encode_declaration(r) end, "no body"))
end

local function test_a_path_the_store_and_the_loader_lack_is_an_unknown_declaration()
  local s = Types.new()
  local t, why = s:decode('(ref "m" "Gone")')
  assert(t == nil and why:find("no declaration m Gone", 1, true) ~= nil, why)
  local asked: {string} = {}
  local loading = Types.new(function(module: string, name: string): string?
    asked[#asked + 1] = module .. " " .. name
    return nil
  end)
  assert(loading:decode('(array (ref "m" "Gone"))') == nil and asked[1] == "m Gone")
  local wrong = Types.new(function(_module: string, _name: string): string?
    return '(decl record "m" "Other" (tparams) (supers) (fields) (elements) (methods) (values))'
  end)
  local got, reason = wrong:decode('(ref "m" "Gone")')
  assert(got == nil and reason:find("answers for m Gone", 1, true) ~= nil, reason)
  assert(wrong:find("m", "Other") == nil and wrong:size() == 10, "a declaration of another path is not defined")
end

local function test_declaration_text_that_is_not_one_is_refused()
  local s = Types.new()
  local bad = {
    "", "(decl", "(decl record)", '(decl widget "m" "R" (tparams) (supers) (fields) (elements) (methods) (values))',
    '(decl enum "m" "E" (tparams) (supers) (fields (field "x" integer)) (elements) (methods) (values))',
    '(decl record "m" "R" (tparams) (supers) (fields) (elements) (methods) (values)) x',
    '(decl record "m" "R" (tparams) (supers) (fields (field "x" frob)) (elements) (methods) (values))',
  }
  for _, text in ipairs(bad) do
    local d, why = s:decode_declaration(text)
    assert(d == nil and why ~= "", "text " .. text .. " decoded")
  end
end

-- a store that refuses and takes back --------------------------------------------------------------

--- A loader that answers the declarations of a fixture, and one that answers `text` for every path.
local function loading_text(text: string): Types.Loader
  return function(_module: string, _name: string): string?
    return text
  end
end

local function test_a_refused_decode_leaves_no_type_and_no_declaration()
  local w = world()
  local second = Types.new(loading_from(w.store))
  local size = second:size()
  -- The declarations load, and the types are made, before the text is found wrong.
  local t, why = second:decode('(array (map (ref "m" "Tree") (ref "m" "Pair" string (ref "m" "List" integer))) frob)')
  assert(t == nil and why:find("types:", 1, true) == 1, why)
  assert(second:size() == size and #second:declarations() == 0, "a refusal adds nothing")
  assert(second:find("m", "Tree") == nil and second:find("m", "Forest") == nil)
  assert(second:decode('(ref "m" "Tree")') ~= nil, "and the same declarations load again")
end

local function test_a_declaration_the_decode_could_not_finish_is_not_left_to_be_used()
  local half = '(decl record "m" "Half" (tparams) (supers) (fields (field "x" frob)) (elements) (methods) (values))'
  local s = Types.new(loading_text(half))
  local t, why = s:decode('(ref "m" "Half")')
  assert(t == nil and why:find("types:", 1, true) == 1, why)
  assert(s:find("m", "Half") == nil)
  local plain = Types.new()
  plain:declare("record", "m", { "Bare" })
  local bare, reason = plain:decode('(ref "m" "Bare")')
  assert(bare == nil and reason:find("has no body", 1, true) ~= nil, reason)
end

local function test_a_decode_that_gives_a_declared_record_its_body_and_fails_takes_it_back()
  local s = Types.new()
  local decl = s:declare("record", "m", { "R" })
  local text = '(decl record "m" "R" (tparams (tparam "T")) (supers) (fields (field "x" (var 0 0))) (elements) (methods) (values))'
  local bad = s:decode_declaration(text .. " junk")
  assert(bad == nil and decl.body == nil and decl.arity == nil, "the stub is as it was")
  assert(s:decode_declaration(text) == decl and decl.arity == 1 and decl.body ~= nil)
end

local function test_a_loader_that_answers_another_path_defines_nothing()
  local other = '(decl record "m" "Other" (tparams) (supers) (fields) (elements) (methods) (values))'
  local s = Types.new(loading_text(other))
  local t, why = s:decode('(ref "m" "Wanted")')
  assert(t == nil and why:find("answers for m Wanted", 1, true) ~= nil, why)
  assert(#s:declarations() == 0)
  local module = Types.new(loading_text(other))
  assert(module:decode('(ref "n" "Other")') == nil and #module:declarations() == 0)
end

local function test_a_chain_of_declarations_far_longer_than_the_limit_is_refused_not_overflowed()
  local asked = { count = 0 }
  local s = Types.new(function(module: string, name: string): string?
    asked.count = asked.count + 1
    local n = math.tointeger(tonumber(name:sub(2)))
    if n == nil then
      return nil
    end
    return '(decl record "' .. module .. '" "' .. name .. '" (tparams) (supers) (fields (field "next" (ref "' ..
      module .. '" "R' .. tostring(n + 1) .. '"))) (elements) (methods) (values))'
  end)
  local t, why = s:decode('(ref "m" "R1")')
  assert(t == nil and why:find("types:", 1, true) == 1 and why:find("deeper", 1, true) ~= nil, why)
  assert(asked.count <= 1002, "the chain is not followed past the limit: " .. asked.count)
  assert(#s:declarations() == 0 and s:size() == 10)
end

local function test_a_loader_that_raises_is_a_refusal_that_says_whose_it_is()
  local s = Types.new(function(_module: string, _name: string): string?
    error("the cache is gone")
  end)
  local t, why = s:decode('(ref "m" "R")')
  assert(t == nil and why:find("types:", 1, true) == 1 and why:find("the cache is gone", 1, true) ~= nil, why)
  local refuses = Types.new()
  local bad, reason = refuses:decode('(fn (tp (ref "m" "R")) () (rets ()))')
  assert(bad == nil and reason:find("types:", 1, true) == 1, reason)
end

local function test_a_declaration_text_for_a_declaration_the_store_has_must_be_its_body()
  local w = world()
  local s = w.store
  local color = Types.encode_declaration(declared(w, "Color"))
  assert(s:decode_declaration(color) == declared(w, "Color"))
  local changed = color:gsub('"blue"', '"violet"')
  local d, why = s:decode_declaration(changed)
  assert(d == nil and why:find("differs", 1, true) ~= nil, why)
  local held = declared(w, "Color").body
  assert(held ~= nil and held.values[3] == "blue", "the declaration is as it was")
  local trailing, reason = s:decode_declaration(color .. " (x)")
  assert(trailing == nil and reason:find("follows", 1, true) ~= nil, reason)
  local new, reason2 = Types.new():decode_declaration(color .. ")")
  assert(new == nil and reason2:find("follows", 1, true) ~= nil, reason2)
  -- A text that is the body in other words is the body.
  local loose = Types.new()
  local first = loose:decode_declaration('(decl record "m" "R" (tparams) (supers) (fields (field "x" (opt string))) (elements) (methods) (values))')
  assert(first ~= nil)
  assert(loose:decode_declaration('(decl record "m" "R" (tparams) (supers) (fields (field "x" (opt (union nil string)))) (elements) (methods) (values))') == first)
end

local function test_text_that_is_not_utf_8_is_refused_and_so_is_a_declaration_named_so()
  local s = Types.new()
  local raw, raw_why = s:decode("(ref \"m\" \"" .. string.char(255) .. "\")")
  assert(raw == nil and raw_why:find("UTF-8", 1, true) ~= nil, raw_why)
  -- An escape can spell any byte, but no declaration is named with one that is not UTF-8.
  local escaped, escaped_why = s:decode('(ref "m\\200" "R")')
  assert(escaped == nil and escaped_why:find("no declaration", 1, true) ~= nil, escaped_why)
  assert(raises(function() local _ = s:declare("record", "m" .. string.char(255), { "R" }) end, "UTF-8"))
  assert(raises(function() local _ = s:declare("record", "m", { "R" .. string.char(200) }) end, "lexer reads"))
  -- A module may be named in any UTF-8, and its text is ASCII.
  local d = s:declare("record", "módulo", { "R" })
  s:define(d, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} })
  local text = Types.encode(s:named(d))
  assert(text == '(ref "m\\195\\179dulo" "R")' and s:decode(text) == s:named(d), text)
end

local function test_no_declaration_takes_the_name_of_a_primitive_type()
  local s = Types.new()
  for _, name in ipairs({ "integer", "string", "any", "nil", "true", "never", "thread" }) do
    assert(raises(function() local _ = s:declare("record", "m", { name }) end, "primitive"), name)
  end
  assert(s:declare("record", "m", { "Outer", "string" }).name == "Outer.string", "a nested one may")
end

local function test_a_module_with_a_nul_byte_is_not_another_path()
  local s = Types.new()
  local one = s:declare("record", "a\0b", { "c" })
  local two = s:declare("record", "a", { "c" })
  local three = s:declare("record", "a\0", { "c" })
  local four = s:declare("record", "a\0bc", { "c" })
  assert(one ~= two and two ~= three and one ~= three and four ~= one)
  assert(s:find("a\0b", "c") == one and s:find("a", "c") == two and s:find("a\0", "c") == three)
  assert(s:find("a\0bc", "c") == four and #s:declarations() == 4)
end

local function test_a_declaration_is_named_with_names_the_lexer_reads()
  local s = Types.new()
  for _, bad in ipairs({ "1x", "a b", "end", "local", "mut", "match", "", "a-b", "Ünï", "a\0b" }) do
    assert(raises(function() local _ = s:declare("record", "m", { bad }) end, "lexer reads"), bad)
    assert(raises(function() local _ = s:declare("record", "m", { "Outer", bad }) end, "lexer reads"), bad)
  end
  for _, good in ipairs({ "type", "record", "x1", "_", "_x", "T_1", "Stream" }) do
    assert(s:declare("record", "m", { good }).name == good, good)
  end
  for _, bad in ipairs({ -1 }) do
    assert(raises(function() local _ = s:declare("record", "m", { "Z" }, bad) end, "0 or more"))
  end
end

local function test_a_type_parameter_and_a_method_are_named_with_names_the_lexer_reads()
  local s = Types.new()
  local r = s:declare("record", "m", { "R" })
  local c = s:declare("class", "m", { "C" })
  assert(raises(function()
    s:define(r, { tparams = { { name = "end" } }, supers = {}, fields = {}, methods = {}, values = {} })
  end, "type parameter's name"))
  assert(raises(function()
    s:define(r, { tparams = { { name = "a b" } }, supers = {}, fields = {}, methods = {}, values = {} })
  end, "type parameter's name"))
  assert(raises(function()
    s:define(c, { tparams = {}, supers = {}, fields = {}, values = {},
      methods = { { name = "a b", type = s:fn({}) } } })
  end, "method's name"))
  assert(r.body == nil and c.body == nil)
end

local function test_a_body_of_strings_that_are_not_utf_8_has_text_that_decodes_to_it()
  local s = Types.new()
  local e = s:declare("enum", "m", { "E" })
  s:define(e, { tparams = {}, supers = {}, fields = {}, methods = {}, values = { "\255", "ok", "\xc3\x28", "a\"b" } })
  local r = s:declare("record", "m", { "R" })
  -- A field may be named by any string, as `["..."]: T` does.
  s:define(r, { tparams = {}, supers = {}, methods = {}, values = {}, fields = {
    { name = "\255", type = s.string }, { name = "foo-bar", type = s.integer, mut = true } } })
  for _, decl in ipairs({ e, r }) do
    local text = Types.encode_declaration(decl)
    assert(text:find("[\128-\255]") == nil, text)
    local second = Types.new()
    local there, why = second:decode_declaration(text)
    assert(there ~= nil, why)
    same(Types.encode_declaration(there), text)
    local body = there.body
    assert(body ~= nil)
    if decl == e then
      assert(body.values[1] == "\255" and body.values[3] == "\xc3\x28" and body.values[4] == 'a"b')
    else
      local first, last = body.fields[1], body.fields[2]
      assert(first ~= nil and last ~= nil and first.name == "\255" and last.name == "foo-bar")
    end
  end
end

-- invariants ------------------------------------------------------------------------------------

local function test_a_use_takes_as_many_arguments_as_the_declaration_has_parameters()
  local w = world()
  local s = w.store
  assert(raises(function() local _ = named(w, "List") end, "takes 1 type arguments, not 0"))
  assert(raises(function() local _ = named(w, "List", { s.integer, s.string }) end, "takes 1"))
  assert(raises(function() local _ = named(w, "Node", { s.integer }) end, "takes 0"))
  assert(raises(function() local _ = s:declare("record", "m", { "List" }, 2) end, "takes 1"))
end

local function test_a_use_made_before_the_parameters_are_known_is_checked_when_they_are()
  local s = Types.new()
  local decl = s:declare("record", "m", { "Wide" })
  local empty: Types.Body = { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} }
  local _ = s:named(decl, { s.integer, s.string })
  assert(raises(function()
    s:define(decl, { tparams = { { name = "T" } }, supers = {}, fields = {}, methods = {}, values = {} })
  end, "takes 1 type arguments, not 2"))
  assert(decl.body == nil)
  assert(raises(function()
    local _ = s:declare("record", "m", { "Wide" }, 1)
  end, "takes 1 type arguments, not 2"))
  assert(decl.arity == nil)
  local ok = s:declare("record", "m", { "Fine" })
  local use = s:named(ok, { s.integer })
  s:define(ok, { tparams = { { name = "T" } }, supers = {}, fields = {}, methods = {}, values = {} })
  assert(s:named(ok, { s.integer }) == use and ok.arity == 1)
  local plain = s:declare("record", "m", { "Plain" })
  s:define(plain, empty)
  assert(plain.arity == 0 and raises(function() local _ = s:named(plain, { s.integer }) end, "takes 0"))
end

local function test_a_variable_names_a_parameter_of_a_binder_it_is_in()
  local s = Types.new()
  assert(raises(function()
    local _ = s:fn({ tparams = { {} }, params = { { type = s:var(0, 1) } } })
  end, "its binder lacks, which has 1"))
  assert(raises(function()
    local _ = s:fn({ tparams = { {}, {} }, rets = { { items = { s:array(s:map(s.string, s:var(0, 2))) } } } })
  end, "which has 2"))
  local fine = s:fn({ tparams = { {}, {} }, params = { { type = s:var(0, 1) } } })
  assert(fine.open == 0)
  -- One binder inside another: the inner one's variable 1 is the outer one's.
  local inner = s:fn({ tparams = { {} }, params = { { type = s:var(1, 3) }, { type = s:var(0, 0) } } })
  assert(inner.open == 1)
  assert(raises(function()
    local _ = s:fn({ tparams = { {} }, params = { { type = inner } } })
  end, "which has 1"))
  local outer = s:fn({ tparams = { {}, {}, {}, {} }, params = { { type = inner } } })
  assert(outer.open == 0)
  assert(s:fn({ params = { { type = s:var(0, 7) } } }).open == 1, "a function with no parameters binds nothing")
end

local function test_the_variables_of_a_body_name_its_own_parameters_and_no_others()
  local s = Types.new()
  local r = s:declare("record", "m", { "R" })
  assert(raises(function()
    s:define(r, { tparams = { { name = "T" } }, supers = {}, methods = {}, values = {},
      fields = { { name = "x", type = s:var(0, 1) } } })
  end, "which has 1 in R"))
  assert(raises(function()
    s:define(r, { tparams = { { name = "T" } }, supers = {}, methods = {}, values = {},
      fields = { { name = "x", type = s:array(s:var(1, 0)) } } })
  end, "no binder"))
  assert(raises(function()
    s:define(r, { tparams = {}, supers = {}, methods = {}, values = {}, fields = { { name = "x", type = s:var(0, 0) } } })
  end, "which has 0"))
  assert(r.body == nil)
  local method = s:fn({ tparams = {}, params = { { type = s:var(0, 0) } } })
  s:define(r, { tparams = { { name = "T" } }, supers = {}, fields = {}, values = {},
    methods = { { name = "m", type = method } } })
  assert(r.body ~= nil)
end

local function test_a_bound_is_an_interface_with_no_arguments()
  local w = world()
  local s = w.store
  local function bounded(bound: Types.Type)
    local _ = s:fn({ tparams = { { bound = bound } } })
  end
  bounded(named(w, "Stream.Reader"))
  assert(raises(function() bounded(s.string) end, "bounded by an interface"))
  assert(raises(function() bounded(named(w, "Node")) end, "bounded by an interface"))
  assert(raises(function() bounded(named(w, "File")) end, "bounded by an interface"))
  assert(raises(function() bounded(s:optional(named(w, "Stream.Reader"))) end, "bounded by an interface"))
  local iface = s:declare("interface", "m", { "Generic" }, 1)
  s:define(iface, { tparams = { { name = "T" } }, supers = {}, fields = {}, methods = {}, values = {} })
  assert(raises(function() bounded(s:named(iface, { s.integer })) end, "no arguments"))
  local r = s:declare("record", "m", { "B" })
  assert(raises(function()
    s:define(r, { tparams = { { name = "T", bound = named(w, "Node") } }, supers = {}, fields = {}, methods = {}, values = {} })
  end, "bounded by an interface"))
  local t, why = s:decode('(fn (tp (ref "m" "Node")) () (rets ()))')
  assert(t == nil and why:find("bounded by an interface", 1, true) ~= nil, why)
end

-- shared parts -----------------------------------------------------------------------------------

--- `Pair<t, t>` made `n` times over `integer`: n + 1 types that hold 2^n.
local function shared_chain(w: World, n: integer): Types.Type
  local t = w.store.integer
  for _ = 1, n do
    t = named(w, "Pair", { t, t })
  end
  return t
end

local function test_a_type_that_shares_its_parts_has_a_weight_and_text_only_as_large_as_it_is_allowed()
  local w = world()
  local s = w.store
  local small = shared_chain(w, 10)
  assert(small.weight == 2047 and small.height == 11)
  local text = Types.encode(small)
  assert(s:decode(text) == small and #text > 10000)
  local big = shared_chain(w, 60)
  assert(big.weight == 1 << 40, "the weight saturates")
  assert(raises(function() local _ = Types.encode(big) end, "too large"))
  assert(raises(function()
    local _ = Types.encode_declaration(s:declare("record", "m", { "Huge" }, 0))
  end, "no body"))
  local shown_big = Types.display(big)
  assert(#shown_big < 60000, #shown_big)
  assert(shown_big:find("...", 1, true) ~= nil, "display ends the rest with ...")
  assert(#Types.digest(big) == 32)
  assert(shown(small):sub(1, 14) == "Pair<Pair<Pair", shown(small):sub(1, 20))
  assert(#shown(small) > 10000, "a type within the budget is shown whole")
end

local function test_a_type_variable_is_never_written_as_a_type_that_has_its_name()
  local w = world()
  local s = w.store
  local clash = named(w, "T")
  same(shown(s:fn({ tparams = { {} }, params = { { type = clash }, { type = s:var(0, 0) } } })), "function<T_>(T, T_)")
  same(shown(s:fn({ tparams = { {}, {} }, params = { { type = clash }, { type = s:var(0, 1) } } })), "function<T_, U>(T, U)")
  local inner = s:fn({ tparams = { {} }, params = { { type = named(w, "T_1") }, { type = s:var(0, 0) }, { type = s:var(1, 0) } } })
  same(shown(s:fn({ tparams = { {} }, params = { { type = inner } } })), "function<T>(function<T_1_>(T_1, T_1_, T))")
  same(shown(s:fn({ tparams = { {} }, params = { { type = s:var(0, 0) } } })), "function<T>(T)")
end

local function test_a_refused_decode_gives_back_the_uses_a_loader_settled()
  local holder: mut {Types.Store} = {}
  local wide: mut {Types.Decl} = {}
  local s = Types.new(function(_module: string, _name: string): string?
    -- The loader re-enters the store, and the decode it serves is refused after it.
    local inside, outer = holder[1], wide[1]
    assert(inside ~= nil and outer ~= nil, "the loader runs once the store and the declaration are held")
    inside:define(outer, { tparams = { { name = "T" } }, supers = {}, fields = {}, methods = {}, values = {} })
    return nil
  end)
  holder[1] = s
  local made = s:declare("record", "m", { "Wide" })
  wide[1] = made
  local _ = s:named(made, { s.integer })
  local t, why = s:decode('(ref "m" "Gone")')
  assert(t == nil and why:find("no declaration", 1, true) ~= nil, why)
  assert(made.body == nil and made.arity == nil, "the declaration is as it was")
  assert(raises(function()
    s:define(made, { tparams = { { name = "A" }, { name = "B" } }, supers = {}, fields = {}, methods = {}, values = {} })
  end, "takes 2 type arguments, not 1"), "and its use is still checked")
end

local function test_what_a_loader_made_in_a_refused_decode_is_dead_and_its_id_is_not_another_type_s()
  local holder: mut {Types.Store} = {}
  local kept: mut {Types.Type} = {}
  local decls: mut {Types.Decl} = {}
  local s = Types.new(function(_module: string, _name: string): string?
    local inside = holder[1]
    assert(inside ~= nil, "the loader runs once the store is held")
    kept[1] = inside:map(inside.string, inside.integer)
    decls[1] = inside:declare("record", "m", { "Kept" })
    return nil
  end)
  holder[1] = s
  local size = s:size()
  assert(s:decode('(ref "m" "Gone")') == nil)
  assert(s:size() == size)
  local fresh = s:array(s.number)
  local kept_type, kept_decl = kept[1], decls[1]
  assert(kept_type ~= nil and kept_decl ~= nil, "the loader made a type and a declaration")
  assert(fresh.id == kept_type.id and fresh ~= kept_type, "the id is the next type's")
  assert(raises(function() local _ = s:optional(kept_type) end, "took back"))
  assert(raises(function() local _ = s:named(kept_decl) end, "another store"))
  assert(s:find("m", "Kept") == nil)
  assert(s:map(s.string, s.integer) ~= kept_type, "and the type is made again")
end

local function test_a_type_parameter_does_not_take_the_first_name_of_a_dotted_declaration()
  local s = Types.new()
  local inner = s:declare("record", "m", { "T", "Inner" }, 0)
  s:define(inner, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} })
  same(shown(s:fn({ tparams = { {} }, params = { { type = s:named(inner) }, { type = s:var(0, 0) } } })),
    "function<T_>(T.Inner, T_)")
end

local function test_a_declaration_that_lists_itself_directly_or_through_others_is_refused_and_left_as_it_was()
  local store = Types.new()
  local a = store:declare("interface", "m", { "A" }, 0)
  local b = store:declare("interface", "m", { "B" }, 0)
  local c = store:declare("interface", "m", { "C" }, 0)
  local function body(...: Types.Type): Types.Body
    return { tparams = {}, supers = { ... }, fields = {}, methods = {}, values = {} }
  end
  local ok, why = pcall(function()
    store:define(a, body(store:named(a)))
  end)
  assert(not ok and tostring(why):find("types: A lists itself", 1, true) ~= nil, tostring(why))
  assert(a.body == nil)
  -- B lists A, and A lists C: C lists B, which lists A, which lists C
  store:define(a, body(store:named(c)))
  store:define(b, body(store:named(a)))
  ok, why = pcall(function()
    store:define(c, body(store:named(b)))
  end)
  assert(not ok and tostring(why):find("types: C lists itself, through A", 1, true) ~= nil, tostring(why))
  assert(c.body == nil)
  -- C may list nothing; listing A would close the cycle again
  store:define(c, body())
  assert(c.body ~= nil)
  assert(Types.listing_cycle(c, { store:named(a) }) == a)
  assert(Types.listing_cycle(b, { store:named(c) }) == nil)
end

local function test_a_type_nested_past_the_depth_limit_is_refused_and_the_limit_is_exported()
  local store = Types.new()
  local t = store.integer
  for _ = 1, Types.max_depth - 1 do
    t = store:array(t)
  end
  assert(t.height == Types.max_depth)
  local ok, why = pcall(function()
    local _ = store:array(t)
  end)
  assert(not ok and tostring(why):find("nested deeper than " .. tostring(Types.max_depth), 1, true) ~= nil, tostring(why))
end

local function test_the_parts_of_a_type_are_the_types_its_text_holds()
  local w = world()
  local s = w.store
  assert(#Types.parts(s.integer) == 0 and #Types.parts(s:var(0, 0)) == 0)
  assert(#Types.parts(s:map(s.string, s.integer)) == 2)
  assert(#Types.parts(named(w, "Pair", { s.integer, s.string })) == 2)
  local f = s:fn({ params = { { type = s.integer } }, rest = s.string, rets = { { items = { s.boolean }, tail = s.number } } })
  assert(#Types.parts(f) == 4)
end
