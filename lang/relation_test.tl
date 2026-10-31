--- Tests of [`lang.relation`]: one small case per rule of the relation,
--- with the reason each refusal carries. The programs the old
--- checker accepted and this one must refuse are in [`lang.relation_refused_test`], and the
--- properties over random types in [`lang.relation_fuzz_test`].
local Programs = require("lang.relation_programs")
local Relation = require("lang.relation")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

--- A union of two members, `first` and `second`, and the `target` it is refused against.
local record Union
  first: Types.Type
  second: Types.Type
  target: Types.Type
end

local world = Programs.world
local named = Programs.named
local steps = Programs.steps
local func = Programs.func
local nothing = Programs.nothing

local shown = Programs.shown
local below = Programs.below
local refusal = Programs.refusal
local refused = Programs.refused
local code_of = Programs.code_of

-- identity and bottom -----------------------------------------------------------------------

local function test_a_type_is_below_itself()
  local w = world()
  local s = w.store
  local types: {Types.Type} = {
    s.integer, s.string, s.any, s.never, s:atom("nil"), named(w, "Node"), named(w, "List", { s.integer }),
    s:array(s.integer, true), s:map(s.string, s.integer), s:optional(s.string),
    func(w, { s.integer }, { s.string }), s:union({ s.integer, s.string }),
  }
  for _, t in ipairs(types) do
    assert(below(w, t, t), shown(t))
  end
end

local function test_never_is_below_every_type_and_nothing_else_is_below_never()
  local w = world()
  local s = w.store
  local types: {Types.Type} = {
    s.integer, s.any, s:atom("nil"), named(w, "Node"), s:array(s.integer, true), s:optional(s.string),
    func(w, {}, {}), s:union({ s.integer, s.string }),
  }
  for _, t in ipairs(types) do
    assert(below(w, s.never, t), shown(t))
    refused(w, t, s.never, "never_target")
  end
  assert(below(w, s.never, s.never))
end

-- nil -------------------------------------------------------------------------------------------

local function test_only_nil_and_a_type_with_nil_admit_nil()
  local w = world()
  local s = w.store
  local null = s:atom("nil")
  assert(below(w, null, null))
  assert(below(w, null, s:optional(s.string)))
  assert(below(w, null, s:optional(named(w, "Node"))))
  assert(below(w, null, s:union({ s.integer, s.string, null })))
  local rest: {Types.Type} = {
    s.string, s.integer, s.boolean, named(w, "Node"), s:array(s.integer), s:map(s.string, s.integer), func(w, {}, {}),
    s:union({ s.integer, s.string }), s.any, s.never,
  }
  for _, t in ipairs(rest) do
    refused(w, null, t, if t.tag == "never" then "never_target" elseif t.tag == "any" then "any_sink" else "nil" end)
  end
end

local function test_a_type_is_below_its_optional_and_an_optional_is_not_below_it()
  local w = world()
  local s = w.store
  assert(below(w, s.string, s:optional(s.string)))
  assert(below(w, s:optional(s.string), s:optional(s.string)))
  assert(below(w, s.integer, s:optional(s.number)))
  local r = refused(w, s:optional(s.string), s.string, "nil", "nil")
  assert(r.sub == s:atom("nil") and r.super == s.string)
  refused(w, s:optional(s.string), s:optional(s.integer), "union_none", "member 1")
end

local function test_a_type_variable_admits_no_nil()
  local w = world()
  local s = w.store
  local v = s:var(0, 0)
  w.judge:enter({ {} })
  refused(w, s:atom("nil"), v, "nil")
  assert(below(w, s.never, v))
  assert(below(w, v, v))
  w.judge:leave()
end

-- numbers, strings, booleans ------------------------------------------------------------------

local function test_integer_is_below_number_and_not_the_reverse()
  local w = world()
  local s = w.store
  assert(below(w, s.integer, s.number))
  assert(below(w, s.integer, s:optional(s.number)))
  refused(w, s.number, s.integer, "number_for_integer")
  refused(w, s.integer, s.string, "mismatch")
  refused(w, s.string, s.integer, "mismatch")
  refused(w, s.integer, s.boolean, "mismatch")
end

local function test_true_and_false_are_below_boolean_and_not_the_reverse()
  local w = world()
  local s = w.store
  local yes, no = s:atom("true"), s:atom("false")
  assert(below(w, yes, s.boolean) and below(w, no, s.boolean))
  assert(below(w, yes, s:union({ yes, s.integer })))
  refused(w, s.boolean, yes, "mismatch")
  refused(w, yes, no, "mismatch")
  refused(w, yes, s.integer, "mismatch")
end

local function test_an_enum_is_below_string_and_a_string_is_not_below_an_enum()
  local w = world()
  local s = w.store
  local color, odd = named(w, "Color"), named(w, "Odd")
  assert(below(w, color, s.string))
  assert(below(w, color, s:optional(s.string)))
  assert(below(w, s:union({ color, s.integer }), s:union({ s.string, s.number })))
  refused(w, s.string, color, "mismatch")
  refused(w, color, odd, "nominal")
  refused(w, color, s.integer, "mismatch")
  refused(w, s.number, color, "mismatch")
end

-- unions ----------------------------------------------------------------------------------------

local function test_a_union_is_below_a_type_when_each_member_is()
  local w = world()
  local s = w.store
  assert(below(w, s:union({ s.integer, s.string }), s:union({ s.number, s.string })))
  assert(below(w, s:union({ s.integer, s.string }), s:union({ s.number, s.string, named(w, "Node") })))
  local r = refusal(w, s:union({ s.integer, s.string }), s.number)
  assert(r.path[1].kind == "member" and r.sub == s.string and r.super == s.number, Relation.trace(r))
  assert(r.code == "mismatch")
end

local function test_a_refusal_names_the_position_of_the_member_that_failed()
  local w = world()
  local s = w.store
  -- Whichever order the store keeps the members in, the position is that of the one that failed.
  local seen: mut {integer: boolean} = {}
  -- a member that is below the target, one that is not, and the target
  local cases: {Union} = {
    { first = s.integer, second = s.string, target = s.number },
    { first = s.integer, second = s.boolean, target = s.number },
    { first = s.integer, second = s:atom("true"), target = s.number },
    { first = named(w, "Color"), second = s.integer, target = s.string },
    { first = named(w, "Color"), second = s.boolean, target = s.string },
    { first = s:atom("true"), second = s.string, target = s.boolean },
    { first = s:atom("false"), second = s.integer, target = s.boolean },
  }
  for _, case in ipairs(cases) do
    local given = s:union({ case.first, case.second })
    assert((given.tag == "union"))
    local r = refusal(w, given, case.target)
    local index = r.path[1].index
    assert(index ~= nil and given.members[index] == case.second and r.sub == case.second, Relation.trace(r))
    seen[index] = true
  end
  assert(seen[1] and seen[2])
end

local function test_a_type_is_below_a_union_when_below_a_member()
  local w = world()
  local s = w.store
  local union = s:union({ s.string, named(w, "Node") })
  assert(below(w, s.string, union))
  assert(below(w, named(w, "Node"), union))
  assert(below(w, named(w, "Color"), union))
  local r = refused(w, s.integer, union, "union_none")
  assert(r.sub == s.integer and r.super == union)
  local alternatives = r.alternatives
  assert(alternatives ~= nil and #alternatives == 2)
  for _, alternative in ipairs(alternatives) do
    assert(alternative.path[1].kind == "target_alternative" and alternative.sub == s.integer)
  end
end

local function test_a_refusal_names_the_position_of_each_member_of_the_union_that_refused()
  local w = world()
  local s = w.store
  local union = s:union({ s.string, named(w, "Node"), named(w, "Tree"), s:array(s.string) })
  assert((union.tag == "union"))
  local r = refused(w, s.integer, union, "union_none")
  local alternatives = r.alternatives
  assert(alternatives ~= nil and #alternatives == 4)
  for i, alternative in ipairs(alternatives) do
    assert(steps(alternative):find("^target_alternative " .. tostring(i)) ~= nil, steps(alternative))
    assert(alternative.super == union.members[i] and alternative.sub == s.integer)
  end
end

local function test_a_union_of_many_members_explains_the_first_few()
  local w = world()
  local s = w.store
  local members: mut {Types.Type} = {}
  for i = 1, 40 do
    members[i] = s:named(s:declare("record", "many", { "R" .. tostring(i) }))
  end
  local r = refused(w, s.integer, s:union(members), "union_none")
  local alternatives = r.alternatives
  assert(alternatives ~= nil and #alternatives == 16, tostring(alternatives and #alternatives))
end

-- collections -----------------------------------------------------------------------------------

local function test_a_view_is_covariant()
  local w = world()
  local s = w.store
  assert(below(w, s:array(s.integer), s:array(s.number)))
  assert(below(w, s:array(s.integer), s:array(s:optional(s.number))))
  assert(below(w, s:map(s.string, s.integer), s:map(s.string, s.number)))
  assert(below(w, s:array(s:array(s.integer)), s:array(s:array(s.number))))
  refused(w, s:array(s.number), s:array(s.integer), "number_for_integer", "element")
  refused(w, s:map(s.string, s.number), s:map(s.string, s.integer), "number_for_integer", "value")
  refused(w, s:array(s:array(s.number)), s:array(s:array(s.integer)), "number_for_integer", "element > element")
end

local function test_a_mut_collection_is_below_a_view_of_a_supertype()
  local w = world()
  local s = w.store
  assert(below(w, s:array(s.integer, true), s:array(s.integer)))
  assert(below(w, s:array(s.integer, true), s:array(s.number)))
  assert(below(w, s:map(s.string, s.integer, true), s:map(s.string, s.number)))
  refused(w, s:array(s.number, true), s:array(s.integer), "number_for_integer", "element")
end

local function test_a_map_key_is_invariant_even_in_a_view()
  local w = world()
  local s = w.store
  local color = named(w, "Color")
  refused(w, s:map(color, s.integer), s:map(s.string, s.integer), "invariant_key", "key")
  refused(w, s:map(s.string, s.integer), s:map(color, s.integer), "invariant_key", "key")
  refused(w, s:map(s.integer, s.integer), s:map(s.number, s.integer), "invariant_key", "key")
end

local function test_a_mut_collection_is_invariant()
  local w = world()
  local s = w.store
  refused(w, s:array(s.integer, true), s:array(s.number, true), "invariant_mut", "element")
  refused(w, s:array(s.number, true), s:array(s.integer, true), "invariant_mut", "element")
  refused(w, s:array(s.integer, true), s:array(s:optional(s.integer), true), "invariant_mut", "element")
  refused(w, s:array(s.never, true), s:array(s.integer, true), "invariant_mut", "element")
  local r = refused(w, s:map(named(w, "Color"), s.integer, true), s:map(s.string, s.integer, true), "invariant_mut",
    "key")
  assert(r.sub == named(w, "Color") and r.super == s.string)
  r = refused(w, s:map(s.string, s.integer, true), s:map(s.string, s.number, true), "invariant_mut", "value")
  assert(r.sub == s.integer and r.super == s.number)
  refused(w, s:map(s.string, s.integer, true), s:map(s:optional(s.string), s.integer, true), "invariant_mut", "key")
  assert(below(w, s:array(s.integer, true), s:array(s.integer, true)))
end

local function test_a_mut_collection_compares_its_element_by_identity_not_by_the_relation()
  -- File | Stream.Reader and Stream.Reader are each below the other, and are two types: a callee
  -- could store a File through a mut {Stream.Reader} into a mut {File | Stream.Reader} and read
  -- back whatever it likes, so the error says to write one of them.
  local w = world()
  local s = w.store
  local file, reader = named(w, "File"), named(w, "Stream.Reader")
  local both = s:union({ file, reader })
  assert(below(w, both, reader) and below(w, reader, both))
  refused(w, s:array(both, true), s:array(reader, true), "invariant_mut", "element")
  refused(w, s:array(reader, true), s:array(both, true), "invariant_mut", "element")
end

local function test_a_view_is_never_below_a_mut_collection()
  local w = world()
  local s = w.store
  refused(w, s:array(s.integer), s:array(s.integer, true), "view_as_mut")
  refused(w, s:map(s.string, s.integer), s:map(s.string, s.integer, true), "view_as_mut")
  refused(w, s:array(s.never), s:array(s.integer, true), "view_as_mut")
end

local function test_a_collection_is_not_another_collection()
  local w = world()
  local s = w.store
  refused(w, s:array(s.integer), s:map(s.integer, s.integer), "mismatch")
  refused(w, s:map(s.integer, s.integer), s:array(s.integer), "mismatch")
  refused(w, s:array(s.integer), s.integer, "mismatch")
end

-- records ---------------------------------------------------------------------------------------

local function test_a_record_with_an_array_part_is_a_view_of_it()
  local w = world()
  local s = w.store
  local node = named(w, "Node")
  assert(below(w, node, s:array(node)))
  assert(below(w, node, s:array(s:optional(node))))
  assert(below(w, node, s:array(s:union({ node, s.string }))))
  assert(below(w, named(w, "Forest"), s:array(named(w, "Tree"))))
  assert(below(w, named(w, "Ring", { s.integer }), s:array(s.integer)))
  assert(below(w, named(w, "Ring", { s.integer }), s:array(s.number)))
  assert(below(w, node, s:union({ s.string, s:array(node) })))
  refused(w, named(w, "Ring", { s.number }), s:array(s.integer), "number_for_integer", "array_part")
  refused(w, node, s:array(s.string), "mismatch", "array_part")
end

local function test_a_record_with_an_array_part_is_never_below_a_mut_collection()
  local w = world()
  local s = w.store
  refused(w, named(w, "Node"), s:array(named(w, "Node"), true), "view_as_mut")
  refused(w, named(w, "Ring", { s.integer }), s:array(s.integer, true), "view_as_mut")
end

local function test_a_record_without_an_array_part_is_no_collection()
  local w = world()
  local s = w.store
  refused(w, named(w, "Tree"), s:array(named(w, "Tree")), "mismatch")
  refused(w, named(w, "List", { s.integer }), s:array(s.integer), "mismatch")
  refused(w, s:array(named(w, "Node")), named(w, "Node"), "mismatch")
end

local function test_a_record_is_not_a_map_and_a_map_is_not_a_record()
  local w = world()
  local s = w.store
  refused(w, named(w, "Tree"), s:map(s.string, s.string), "record_as_map")
  refused(w, named(w, "Node"), s:map(s.integer, named(w, "Node")), "record_as_map")
  refused(w, named(w, "List", { s.integer }), s:map(s.string, s.integer), "record_as_map")
  refused(w, s:map(s.string, s.integer), named(w, "List", { s.integer }), "map_as_record")
  refused(w, s:map(s.string, s.integer, true), named(w, "Tree"), "map_as_record")
end

-- named types -----------------------------------------------------------------------------------

local function test_named_types_are_nominal()
  local w = world()
  local s = w.store
  -- Two records with the same fields are two types.
  local copy = s:declare("record", "m", { "NodeCopy" }, 0)
  s:define(copy, { tparams = {}, supers = {}, methods = {}, values = {}, array = s:named(copy),
    fields = { { name = "name", type = s.string } } })
  refused(w, named(w, "Tree"), named(w, "Node"), "nominal")
  refused(w, s:named(copy), named(w, "Node"), "nominal")
  refused(w, named(w, "Node"), s:named(copy), "nominal")
  refused(w, named(w, "Handle"), named(w, "Node"), "nominal")
  refused(w, named(w, "Node"), s.string, "mismatch")
  refused(w, named(w, "Node"), func(w, {}, {}), "mismatch")
end

local function test_a_class_is_as_nominal_as_a_record_and_a_declaration_used_as_a_value_is_below_itself_alone()
  local w = world()
  local s = w.store
  local fields = { { name = "n", type = s.integer } }
  local one = s:declare("class", "m", { "ClassOne" }, 0)
  local two = s:declare("class", "m", { "ClassTwo" }, 0)
  local plain = s:declare("record", "m", { "PlainOne" }, 0)
  for _, d in ipairs({ one, two, plain }) do
    s:define(d, { tparams = {}, supers = {}, methods = {}, values = {}, fields = fields })
  end
  refused(w, s:named(one), s:named(two), "nominal")
  refused(w, s:named(one), s:named(plain), "nominal")
  refused(w, s:named(plain), s:named(one), "nominal")
  local file, node = s:named(w.fixture.decls["File"]), named(w, "Node")
  local file_value = s:named(w.fixture.decls["File"], {}, true)
  local node_value = s:named(w.fixture.decls["Node"], {}, true)
  assert(below(w, file_value, file_value) and below(w, file_value, s:optional(file_value)))
  refused(w, file_value, file, "declaration_value")
  refused(w, file, file_value, "declaration_value")
  refused(w, file_value, node_value, "nominal")
  -- it lists no interface, is no enum and has no array part
  refused(w, file_value, named(w, "Stream.Reader"), "declaration_value")
  refused(w, node_value, s:array(node), "mismatch")
  refused(w, node_value, s.string, "mismatch")
  assert(below(w, node, s:array(node)))
end

local function test_a_use_of_a_generic_is_invariant_in_its_arguments()
  local w = world()
  local s = w.store
  refused(w, named(w, "List", { s.integer }), named(w, "List", { s.number }), "invariant_generic", "argument 1")
  refused(w, named(w, "List", { s.number }), named(w, "List", { s.integer }), "invariant_generic", "argument 1")
  refused(w, named(w, "List", { s.never }), named(w, "List", { s.integer }), "invariant_generic", "argument 1")
  refused(w, named(w, "Pair", { s.integer, s.string }), named(w, "Pair", { s.integer, s.number }),
    "invariant_generic", "argument 2")
  local r = refusal(w, named(w, "List", { s:array(s.integer) }), named(w, "List", { s:array(s.number) }))
  assert(r.sub == s:array(s.integer) and r.super == s:array(s.number), Relation.trace(r))
  assert(below(w, named(w, "List", { s.integer }), named(w, "List", { s.integer })))
end

local function test_a_type_is_below_an_interface_only_where_its_declaration_lists_it()
  local w = world()
  local s = w.store
  local reader, event = named(w, "Stream.Reader"), named(w, "Event")
  assert(below(w, named(w, "File"), reader))
  assert(below(w, named(w, "KeyEvent"), event))
  assert(below(w, named(w, "MouseEvent"), event))
  assert(below(w, named(w, "File"), s:optional(reader)))
  assert(below(w, named(w, "File"), s:union({ reader, event })))
  refused(w, named(w, "MouseEvent"), named(w, "KeyEvent"), "nominal")
  refused(w, event, named(w, "KeyEvent"), "nominal")
  refused(w, named(w, "Handle"), reader, "not_listed")
  refused(w, named(w, "File"), event, "not_listed")
  refused(w, reader, named(w, "File"), "nominal")
  -- A record with the fields of an interface, and listing nothing, conforms to nothing.
  local lookalike = s:declare("record", "m", { "Lookalike" }, 0)
  s:define(lookalike, { tparams = {}, supers = {}, methods = {}, values = {},
    fields = { { name = "name", type = s.string } } })
  local r = refused(w, s:named(lookalike), event, "not_listed")
  local lists = r.lists
  assert(lists ~= nil and #lists == 0)
end

local function test_a_refusal_for_an_unlisted_interface_names_what_the_declaration_lists()
  local w = world()
  local r = refused(w, named(w, "Duplex"), named(w, "Event"), "not_listed")
  local lists = r.lists
  assert(lists ~= nil and #lists == 2, tostring(lists and #lists))
  assert(lists[1] == named(w, "ReadWriter") and lists[2] == named(w, "Stream.Reader"))
end

local function test_an_interface_is_below_the_interfaces_it_extends()
  local w = world()
  local reader, read_write = named(w, "Stream.Reader"), named(w, "ReadWriter")
  assert(below(w, read_write, reader))
  assert(below(w, named(w, "Duplex"), read_write))
  assert(below(w, named(w, "Duplex"), reader))
  refused(w, reader, read_write, "not_listed")
  refused(w, named(w, "File"), read_write, "not_listed")
  assert(below(w, named(w, "Ranked"), named(w, "Ordered")))
end

local function test_the_arguments_of_a_listing_are_read_through_the_declaration()
  local w = world()
  local s = w.store
  local function source(item: Types.Type): Types.Type
    return named(w, "Source", { item })
  end
  assert(below(w, named(w, "IntSource"), source(s.integer)))
  refused(w, named(w, "IntSource"), source(s.number), "not_listed")
  refused(w, named(w, "IntSource"), source(s.string), "not_listed")
  assert(below(w, named(w, "Box", { s.string }), source(s.string)))
  refused(w, named(w, "Box", { s.string }), source(s.integer), "not_listed")
  assert(below(w, named(w, "Wrapped", { s.integer }), source(s:array(s.integer))))
  refused(w, named(w, "Wrapped", { s.integer }), source(s:array(s.string)), "not_listed")
  refused(w, named(w, "Wrapped", { s.integer }), source(s.integer), "not_listed")
  -- an interface is invariant in its arguments, as any generic
  refused(w, source(s.integer), source(s.number), "invariant_generic", "argument 1")
end

local function test_a_listing_argument_that_holds_a_variable_inside_a_binder_is_read_with_the_variable()
  local w = world()
  local s = w.store
  local function generic(second: Types.Type): Types.Type
    return s:fn({
      tparams = { {} },
      params = { { type = s:var(0, 0) }, { type = second } },
      rets = { { items = { s:var(0, 0) } } },
    })
  end
  local source_of = function(item: Types.Type): Types.Type
    return named(w, "Source", { item })
  end
  assert(below(w, named(w, "Gen", { s.string }), source_of(generic(s.string))))
  refused(w, named(w, "Gen", { s.string }), source_of(generic(s.integer)), "not_listed")
  -- Gen<V> for a variable V of an enclosing binder lists the function over V, one binder further in.
  w.judge:enter({ {} })
  local outer = s:var(0, 0)
  assert(below(w, named(w, "Gen", { outer }), source_of(generic(s:var(1, 0)))))
  refused(w, named(w, "Gen", { outer }), source_of(generic(s:var(0, 0))), "not_listed")
  assert(below(w, named(w, "Box", { outer }), source_of(outer)))
  assert(below(w, named(w, "Wrapped", { outer }), source_of(s:array(outer))))
  w.judge:leave()
end

-- functions ---------------------------------------------------------------------------------------

local function test_a_function_takes_parameters_contravariantly()
  local w = world()
  local s = w.store
  assert(below(w, func(w, { s.number }, {}), func(w, { s.integer }, {})))
  assert(below(w, func(w, { s.string }, {}), func(w, { s.string }, {})))
  local r = refused(w, func(w, { s.integer }, {}), func(w, { s.number }, {}), "number_for_integer", "parameter 1")
  -- The parameter step swaps the roles: the sub of the leaf is the wanted function's parameter.
  assert(r.sub == s.number and r.super == s.integer)
  refused(w, func(w, { s.string, s.integer }, {}), func(w, { s.string, s.number }, {}), "number_for_integer",
    "parameter 2")
  -- a callback parameter swaps twice
  local takes_integer_cb = func(w, { func(w, {}, { s.integer }) }, {})
  local takes_number_cb = func(w, { func(w, {}, { s.number }) }, {})
  assert(below(w, takes_number_cb, takes_integer_cb))
  refused(w, takes_integer_cb, takes_number_cb, "number_for_integer", "parameter 1 > alternative 1 > item 1")
end

local function test_a_function_gives_returns_covariantly()
  local w = world()
  local s = w.store
  assert(below(w, func(w, {}, { s.integer }), func(w, {}, { s.number })))
  assert(below(w, func(w, {}, { s.integer }), func(w, {}, { s:optional(s.number) })))
  refused(w, func(w, {}, { s.number }), func(w, {}, { s.integer }), "number_for_integer", "alternative 1 > item 1")
  refused(w, func(w, {}, { s.integer, s.number }), func(w, {}, { s.integer, s.integer }), "number_for_integer",
    "alternative 1 > item 2")
end

local function test_a_function_gives_as_many_values_as_are_wanted()
  local w = world()
  local s = w.store
  refused(w, func(w, {}, { s.integer, s.string }), func(w, {}, { s.integer }), "return_length", "alternative 1")
  refused(w, func(w, {}, { s.integer }), func(w, {}, { s.integer, s.string }), "return_length", "alternative 1")
  refused(w, nothing(w, {}), func(w, {}, { s.integer }), "return_length", "alternative 1")
  refused(w, func(w, {}, { s.integer }), nothing(w, {}), "return_length", "alternative 1")
  local tail = function(item: Types.Type): Types.Type
    return s:fn({ rets = { { items = { s.string }, tail = item } } })
  end
  assert(below(w, tail(s.integer), tail(s.number)))
  refused(w, tail(s.number), tail(s.integer), "number_for_integer", "alternative 1 > tail")
  refused(w, tail(s.integer), func(w, {}, { s.string, s.integer }), "return_length", "alternative 1")
  refused(w, func(w, {}, { s.string, s.integer }), tail(s.integer), "return_length", "alternative 1")
end

local function test_a_function_that_never_returns_is_below_every_function_of_its_parameters()
  local w = world()
  local s = w.store
  local dies = s:fn({ rets = {} })
  assert(below(w, dies, func(w, {}, { s.string })))
  assert(below(w, dies, nothing(w, {})))
  assert(below(w, dies, dies))
  assert(below(w, s:fn({ params = { { type = s.string } }, rets = {} }), func(w, { s.string }, { s.integer })))
  refused(w, dies, func(w, { s.string }, { s.integer }), "arity")
  local may_return = refused(w, func(w, {}, { s.string }), dies, "may_return", "alternative 1")
  assert(may_return.sub == func(w, {}, { s.string }) and may_return.super == dies)
  refused(w, nothing(w, {}), dies, "may_return", "alternative 1")
end

local function test_a_function_wanted_with_alternatives_takes_one_that_gives_any_of_them()
  local w = world()
  local s = w.store
  local yes, no = s:atom("true"), s:atom("false")
  local function result(...: { Types.Type }): Types.Type
    local alts: mut {Types.Alt} = {}
    for i, items in ipairs({ ... }) do
      alts[i] = { items = items }
    end
    return s:fn({ rets = alts })
  end
  local wanted = result({ yes, s.string }, { no, s.any })
  assert(below(w, result({ yes, s.string }), wanted))
  assert(below(w, result({ no, s.any }), wanted))
  assert(below(w, result({ yes, s.string }, { no, s.any }), wanted))
  assert(below(w, result({ yes, s.string }, { no, s.any }), result({ no, s.any }, { yes, s.string })))
  local r = refusal(w, result({ yes, s.string }, { no, s.any }), result({ yes, s.string }))
  assert(r.code == "mismatch" and r.path[1].kind == "alternative", Relation.trace(r))
end

local function test_a_function_whose_alternative_matches_none_says_why_for_each()
  local w = world()
  local s = w.store
  local yes, no = s:atom("true"), s:atom("false")
  local given = s:fn({ rets = { { items = { yes, s.integer } } } })
  local wanted = s:fn({ rets = { { items = { yes, s.string } }, { items = { no, s.integer } } } })
  local r = refusal(w, given, wanted)
  assert(r.code == "return_unmatched" and steps(r) == "alternative 1", Relation.trace(r))
  local alternatives = r.alternatives
  assert(alternatives ~= nil and #alternatives == 2)
  for _, alternative in ipairs(alternatives) do
    assert(alternative.path[1].kind == "target_alternative")
  end
  -- With one alternative wanted the reason is the one part that differs.
  local only = s:fn({ rets = { { items = { yes, s.string } } } })
  local direct = refusal(w, given, only)
  assert(direct.code == "mismatch" and steps(direct) == "alternative 1 > item 2", Relation.trace(direct))
end

local function test_a_function_takes_as_many_arguments_as_are_passed()
  local w = world()
  local s = w.store
  local function with(params: {Types.Param}, rest?: Types.Type): Types.Type
    return s:fn({ params = params, rest = rest })
  end
  local one = with({ { type = s.integer } })
  local maybe = with({ { type = s.integer, omittable = true } })
  local two = with({ { type = s.integer }, { type = s.integer } })
  local none = with({})
  -- one that takes fewer than are passed, or more that are required, takes not all
  local r = refused(w, none, one, "arity")
  assert(r.index == 1)
  r = refused(w, one, none, "arity")
  assert(r.index == 1)
  refused(w, two, one, "arity")
  refused(w, one, two, "arity")
  -- one that passes an optional argument is met by one that takes it, or a rest parameter
  assert(below(w, maybe, none))
  assert(below(w, maybe, one))
  assert(below(w, maybe, maybe))
  refused(w, one, maybe, "arity")
  refused(w, none, maybe, "arity")
  assert(below(w, with({ { type = s.integer }, { type = s.string, omittable = true } }), one))
  refused(w, with({ { type = s.integer }, { type = s.string } }), one, "arity")
  -- the omitted argument is `nil` or its type: an optional parameter takes the optional's type
  assert(below(w, with({ { type = s.number, omittable = true } }), with({ { type = s.integer, omittable = true } })))
  refused(w, with({ { type = s.integer, omittable = true } }), with({ { type = s.number, omittable = true } }),
    "union_none", "parameter 1 > member 1")
end

local function test_a_function_whose_parameters_are_known_may_drop_only_trailing_ones()
  local w = world()
  local s = w.store
  local j = w.judge
  local function with(...: Types.Type): Types.Type
    local params: mut {Types.Param} = {}
    for _, t in ipairs({ ... }) do
      table.insert(params, { type = t })
    end
    return s:fn({ params = params })
  end
  -- the strict relation refuses a function that takes fewer parameters than are passed
  refused(w, with(s.string), with(s.string, s.integer), "arity")
  assert(Relation.subtype_known(j, with(s.string), with(s.string, s.integer)))
  assert(Relation.subtype_known(j, with(), with(s.string, s.integer)))
  assert(Relation.subtype_known(j, with(s.number), with(s.integer, s.string)))
  assert(Relation.refuse_known(j, with(s.number), with(s.integer, s.string)) == nil)
  -- a union with the function wanted takes it too
  assert(Relation.subtype_known(j, with(s.string), s:optional(with(s.string, s.integer))))
  -- the parameters kept are still taken contravariantly, and a middle one is not dropped
  assert(not Relation.subtype_known(j, with(s.integer), with(s.number, s.string)))
  assert(not Relation.subtype_known(j, with(s.string), with(s.integer, s.string)))
  -- one that requires more than are passed, and the returns, stay as they are
  assert(not Relation.subtype_known(j, with(s.string, s.integer), with(s.string)))
  assert(not Relation.subtype_known(j, func(w, { s.string }, {}), func(w, { s.string, s.integer }, { s.integer })))
  -- a rest parameter wanted is still met by a rest parameter
  assert(not Relation.subtype_known(j, with(s.string), s:fn({ params = { { type = s.string } }, rest = s.integer })))
  -- the refusal of the strict relation is the one given
  local r = Relation.refuse_known(j, with(s.integer), with(s.number, s.string))
  assert(r ~= nil and r.code == "number_for_integer")
  -- only the top level drops: a callback parameter is held to the strict relation
  local takes_short = s:fn({ params = { { type = with(s.string) } } })
  local takes_long = s:fn({ params = { { type = with(s.string, s.integer) } } })
  assert(not Relation.subtype_known(j, takes_long, takes_short))
  assert(not Relation.subtype_known(j, takes_short, takes_long))
end

local function test_a_rest_parameter_meets_the_arguments_after_the_last_parameter()
  local w = world()
  local s = w.store
  local function with(params: {Types.Type}, rest?: Types.Type): Types.Type
    local list: mut {Types.Param} = {}
    for i, p in ipairs(params) do
      list[i] = { type = p }
    end
    return s:fn({ params = list, rest = rest })
  end
  assert(below(w, with({}, s.number), with({ s.integer, s.integer })))
  assert(below(w, with({ s.number }, s.number), with({ s.integer, s.integer })))
  assert(below(w, with({}, s.number), with({}, s.integer)))
  assert(below(w, with({}, s.integer), with({})))
  refused(w, with({}, s.integer), with({ s.number }), "number_for_integer", "parameter 1")
  refused(w, with({}, s.integer), with({}, s.number), "number_for_integer", "rest 1")
  -- a function that passes any number of arguments needs one that takes them
  refused(w, with({ s.integer }), with({}, s.integer), "arity")
  refused(w, with({ s.integer, s.integer }), with({ s.integer }, s.integer), "arity")
  refused(w, with({}), with({}, s.integer), "arity")
  local r = refused(w, with({ s.integer }), with({ s.integer }, s.integer), "arity")
  assert(r.index == 2)
end

local function test_a_method_has_no_receiver_exemption()
  local w = world()
  local s = w.store
  local reader, file = named(w, "Stream.Reader"), named(w, "File")
  -- A function that takes its own type where one that takes the interface is wanted.
  local r = refused(w, func(w, { file }, {}), func(w, { reader }, {}), "nominal", "parameter 1")
  assert(r.sub == reader and r.super == file)
  assert(below(w, func(w, { reader }, {}), func(w, { file }, {})))
  -- the function of an interface field is compared as any function
  local reader_body = w.fixture.decls["Stream.Reader"].body
  assert(reader_body ~= nil)
  local read = reader_body.fields[1].type
  assert(below(w, read, func(w, { file, s:optional(s.integer) }, { s:optional(s.string) })))
  refused(w, func(w, { file, s:optional(s.integer) }, { s:optional(s.string) }), read, "nominal", "parameter 1")
end

local function test_a_function_over_a_narrower_type_is_not_a_callback_for_a_wider_one()
  local w = world()
  local event, key, mouse = named(w, "Event"), named(w, "KeyEvent"), named(w, "MouseEvent")
  assert(below(w, func(w, { event }, {}), func(w, { key }, {})))
  refused(w, func(w, { key }, {}), func(w, { event }, {}), "nominal", "parameter 1")
  refused(w, func(w, { mouse }, {}), func(w, { key }, {}), "nominal", "parameter 1")
end

local function test_an_is_declaration_is_invariant_in_its_type_and_an_asserts_declaration_covariant()
  local w = world()
  local s = w.store
  local event, key = named(w, "Event"), named(w, "KeyEvent")
  local function narrowing(to: Types.Type, param: integer, asserted: boolean): Types.Type
    return s:fn({
      params = { { type = event }, { type = event } },
      rets = { { items = {}, narrows = { param = param, to = to, asserts = asserted } } },
    })
  end
  local plain = func(w, { event, event }, { s.boolean })
  -- `p is T` has a false edge, where the caller removes T from the value: a function that tests for
  -- KeyEvent removes too little where one that tests for Event is wanted, and the reverse removes too much.
  local r = refused(w, narrowing(key, 1, false), narrowing(event, 1, false), "invariant_narrows",
    "alternative 1 > narrows")
  assert(r.sub == key and r.super == event)
  r = refused(w, narrowing(event, 1, false), narrowing(key, 1, false), "invariant_narrows", "alternative 1 > narrows")
  assert(r.sub == event and r.super == key)
  assert(below(w, narrowing(key, 1, false), narrowing(key, 1, false)))
  -- `asserts p is T` has only the edge that returns, so a narrower T is more than is wanted
  assert(below(w, narrowing(key, 1, true), narrowing(event, 1, true)))
  r = refused(w, narrowing(event, 1, true), narrowing(key, 1, true), "nominal", "alternative 1 > narrows")
  assert(r.sub == event and r.super == key)
  refused(w, plain, narrowing(key, 1, false), "narrows_missing", "alternative 1")
  refused(w, plain, narrowing(key, 1, true), "narrows_missing", "alternative 1")
  assert(below(w, narrowing(key, 1, false), plain))
  refused(w, narrowing(key, 2, false), narrowing(key, 1, false), "narrows_other", "alternative 1")
  refused(w, narrowing(key, 1, true), narrowing(key, 1, false), "narrows_other", "alternative 1")
end

local function test_a_generic_function_wanted_is_met_only_by_itself()
  local w = world()
  local s = w.store
  local v = s:var(0, 0)
  local identity = s:fn({ tparams = { {} }, params = { { type = v } }, rets = { { items = { v } } } })
  local again = s:fn({ tparams = { {} }, params = { { type = v } }, rets = { { items = { v } } } })
  assert(identity == again and below(w, identity, again))
  local other = s:fn({ tparams = { {} }, params = { { type = v } }, rets = { { items = { s:array(v) } } } })
  refused(w, identity, other, "generic_function")
  refused(w, func(w, { s.integer }, { s.integer }), identity, "generic_function")
  refused(w, other, identity, "generic_function")
end

local function test_a_generic_function_is_below_the_function_type_its_type_parameters_can_be_taken_from()
  local w = world()
  local s = w.store
  local v = s:var(0, 0)
  local identity = s:fn({ tparams = { {} }, params = { { type = v } }, rets = { { items = { v } } } })
  assert(below(w, identity, func(w, { s.integer }, { s.integer })))
  assert(below(w, identity, func(w, { s.string }, { s.string })))
  assert(below(w, identity, func(w, { s:optional(s.string) }, { s:optional(s.string) })))
  -- The value the wanted type passes is the one the function takes, and what it answers is that value.
  refused(w, identity, func(w, { s.integer }, { s.string }), "generic_function")
  refused(w, identity, func(w, {}, { s.integer }), "arity")
  assert(below(w, identity, func(w, { s.integer }, { s.number })))
  refused(w, identity, func(w, { s.number }, { s.integer }), "generic_function")
  -- The element type comes from the parameter and the result is checked as a function of it.
  local wrap = s:fn({ tparams = { {} }, params = { { type = v } }, rets = { { items = { s:array(v) } } } })
  assert(below(w, wrap, func(w, { s.string }, { s:array(s.string) })))
  refused(w, wrap, func(w, { s.string }, { s:array(s.integer) }), "generic_function")
  -- A type parameter only the result gives is taken from it.
  local make = s:fn({ tparams = { {} }, params = {}, rets = { { items = { s:array(v) } } } })
  assert(below(w, make, func(w, {}, { s:array(s.integer) })))
  -- A type parameter nothing gives has no type to take.
  local unused = s:fn({ tparams = { {} }, params = {}, rets = { { items = { s.integer } } } })
  refused(w, unused, func(w, {}, { s.integer }), "generic_function")
end

local function test_a_generic_function_is_below_a_function_type_only_if_its_instance_meets_the_bound()
  local w = world()
  local s = w.store
  local v = s:var(0, 0)
  local source = named(w, "Source", { s.integer })
  local bounded = s:fn({ tparams = { { bound = named(w, "Event") } }, params = { { type = v } }, rets = { { items = { v } } } })
  local key = named(w, "KeyEvent")
  assert(below(w, bounded, func(w, { key }, { key })))
  refused(w, bounded, func(w, { source }, { source }), "generic_function")
end

-- any ----------------------------------------------------------------------------------------------

local function test_any_is_below_only_any_and_only_never_is_below_it()
  local w = world()
  local s = w.store
  assert(below(w, s.any, s.any))
  assert(below(w, s.never, s.any))
  refused(w, s.any, s.string, "any_source")
  refused(w, s.any, s:optional(s.string), "any_source")
  refused(w, s.any, named(w, "Node"), "any_source")
  refused(w, s.string, s.any, "any_sink")
  refused(w, named(w, "Node"), s.any, "any_sink")
  refused(w, s:atom("nil"), s.any, "any_sink")
  refused(w, s:array(s.string), s.any, "any_sink")
  -- any absorbs a union, so a member is no more below it than the member alone
  refused(w, s.string, s:union({ s.string, s.any }), "any_sink")
end

local function test_a_value_reaches_any_only_as_an_argument_to_a_parameter_declared_any()
  local w = world()
  local s = w.store
  local j = w.judge
  for _, t in ipairs({ s.string, s:atom("nil"), named(w, "Node"), s:array(s.integer, true), func(w, {}, {}), s.any,
      s.never }) do
    assert(j:accepts(t, s.any), shown(t))
    assert(j:refuse_argument(t, s.any) == nil, shown(t))
  end
  assert(j:accepts(s.integer, s.number))
  assert(not j:accepts(s.number, s.integer))
  assert(code_of(j:refuse_argument(s.number, s.integer)) == "number_for_integer")
  -- the data of any is not an argument for anything else
  assert(not j:accepts(s.any, s.string))
  assert(code_of(j:refuse_argument(s.any, s.string)) == "any_source")
  -- only the parameter itself is declared any
  assert(not j:accepts(s:array(s.string), s:array(s.any)))
  assert(code_of(j:refuse_argument(s:array(s.string), s:array(s.any))) == "any_sink")
  -- a union with any is any
  assert(j:accepts(s.string, s:union({ s.integer, s.any })))
end

local function test_any_does_not_widen_a_function_parameter_or_return()
  local w = world()
  local s = w.store
  -- Contravariance does not widen it: a callback that takes any is no callback for one that takes a string.
  refused(w, func(w, { s.any }, {}), func(w, { s.string }, {}), "any_sink", "parameter 1")
  refused(w, func(w, { s.string }, {}), func(w, { s.any }, {}), "any_source", "parameter 1")
  assert(below(w, func(w, { s.any }, {}), func(w, { s.any }, {})))
  refused(w, func(w, {}, { s.string }), func(w, {}, { s.any }), "any_sink", "alternative 1 > item 1")
  refused(w, func(w, {}, { s.any }), func(w, {}, { s.string }), "any_source", "alternative 1 > item 1")
  assert(below(w, func(w, {}, { s.any }), func(w, {}, { s.any })))
  refused(w, func(w, { s.any }, {}), func(w, { named(w, "Node") }, {}), "any_sink", "parameter 1")
end

-- type variables ----------------------------------------------------------------------------------

local function test_a_type_variable_is_below_itself_and_its_bound()
  local w = world()
  local s = w.store
  local reader = named(w, "Stream.Reader")
  local v = s:var(0, 0)
  w.judge:enter({ { bound = reader } })
  assert(below(w, v, v))
  assert(below(w, v, reader))
  assert(below(w, v, s:optional(reader)))
  assert(below(w, v, s:union({ s.integer, reader })))
  assert(below(w, s.never, v))
  local r = refused(w, v, s.integer, "mismatch", "bound")
  assert(r.sub == reader)
  refused(w, v, named(w, "File"), "nominal", "bound")
  refused(w, reader, v, "variable")
  refused(w, s.integer, v, "variable")
  w.judge:leave()
end

local function test_a_type_variable_without_a_bound_is_below_only_itself()
  local w = world()
  local s = w.store
  local v, u = s:var(0, 0), s:var(0, 1)
  w.judge:enter({ {}, {} })
  assert(below(w, v, v))
  refused(w, v, u, "variable")
  refused(w, v, s.string, "variable")
  assert(below(w, v, s:optional(v)))
  refused(w, s:optional(v), v, "nil", "nil")
  w.judge:leave()
end

local function test_a_type_variable_is_bounded_by_the_binder_it_names()
  local w = world()
  local s = w.store
  local reader = named(w, "Stream.Reader")
  local outer, inner = s:var(1, 0), s:var(0, 0)
  w.judge:enter({ { bound = reader } })
  w.judge:enter({ {} })
  assert(below(w, outer, reader))
  refused(w, inner, reader, "variable")
  w.judge:leave()
  assert(below(w, s:var(0, 0), reader))
  w.judge:leave()
end

local function test_a_pair_that_mentions_a_variable_is_settled_for_the_binders_it_was_asked_under()
  local w = world()
  local s = w.store
  local reader = named(w, "Stream.Reader")
  local v = s:var(0, 0)
  refused(w, v, reader, "variable")
  w.judge:enter({ { bound = reader } })
  assert(below(w, v, reader))
  w.judge:leave()
  w.judge:enter({ {} })
  refused(w, v, reader, "variable")
  w.judge:leave()
  refused(w, v, reader, "variable")
end

local function test_the_binder_of_a_declaration_is_its_type_parameters_and_their_bounds()
  local w = world()
  local s = w.store
  local ordered = named(w, "Ordered")
  local bounded = s:declare("record", "m", { "Bounded" }, 1)
  s:define(bounded, { tparams = { { name = "T", bound = ordered } }, supers = {}, fields = {}, methods = {}, values = {} })
  w.judge:enter(Relation.binder(bounded))
  assert(below(w, s:var(0, 0), ordered))
  w.judge:leave()
  assert(#Relation.binder(w.fixture.decls["Pair"]) == 2)
  assert(#Relation.binder(w.fixture.decls["Node"]) == 0)
end

local function test_leaving_without_entering_raises()
  local w = world()
  local ok, why = pcall(function()
    w.judge:leave()
  end)
  assert(not ok and tostring(why):find("relation:", 1, true) ~= nil, tostring(why))
end

-- invalid and the store --------------------------------------------------------------------------

local function test_invalid_relates_to_everything_so_that_a_mistake_reports_once()
  local w = world()
  local s = w.store
  assert(below(w, s.invalid, s.string) and below(w, s.string, s.invalid))
  assert(below(w, s:array(s.invalid), s:array(s.string)))
  assert(below(w, s:array(s.string, true), s:array(s.invalid, true)))
  assert(below(w, s:array(s.invalid, true), s:array(s.string, true)))
  assert(below(w, named(w, "List", { s.invalid }), named(w, "List", { s.integer })))
  assert(below(w, s:map(s.invalid, s.string), s:map(s.integer, s.string)))
  assert(below(w, func(w, { s.invalid }, { s.invalid }), func(w, { s.integer }, { s.string })))
end

local function test_a_type_of_another_store_is_refused()
  local w = world()
  local other = Types.new()
  local ok, why = pcall(function()
    local _ = w.judge:subtype(w.store.integer, other.integer)
  end)
  assert(not ok and tostring(why):find("another store", 1, true) ~= nil, tostring(why))
end

-- reasons ------------------------------------------------------------------------------------------

local function test_a_refusal_names_the_part_that_failed_and_how_to_reach_it()
  local w = world()
  local s = w.store
  local record_of = named(w, "List", { s.integer })
  local given = s:map(s.string, s:array(s:array(s.integer, true)))
  local wanted = s:map(s.string, s:array(s:array(s.number, true)))
  local r = refused(w, given, wanted, "invariant_mut", "value > element > element")
  assert(r.sub == s.integer and r.super == s.number)
  assert(Relation.trace(r) == "invariant_mut at value > element > element: integer is not below number",
    Relation.trace(r))
  local deep = refusal(w, s:array(record_of), s:array(named(w, "List", { s.number })))
  assert(steps(deep) == "element > argument 1" and deep.code == "invariant_generic")
end

local function test_asking_again_gives_the_same_reason()
  local w = world()
  local s = w.store
  local given = s:union({ s.integer, s:array(s.number), named(w, "Node") })
  local wanted = s:union({ s.string, s:array(s.integer) })
  local first = refusal(w, given, wanted)
  local copy = steps(first) .. first.code
  local second = refusal(w, given, wanted)
  assert(steps(second) .. second.code == copy)
end

local function test_a_pair_that_two_parents_reach_in_one_request_is_explained_under_each_and_changed_under_none()
  -- Both alternatives of the function wanted fail on the same pair, number against integer, which one
  -- request explains once. Wrapping it under the first alternative must leave it as it was for the second.
  local w = world()
  local s = w.store
  local given = s:fn({ rets = { { items = { s.number, s.string } } } })
  local wanted = s:fn({ rets = { { items = { s.integer, s.string } }, { items = { s.integer, s.integer } } } })
  local r = refusal(w, given, wanted)
  assert(r.code == "return_unmatched" and steps(r) == "alternative 1", Relation.trace(r))
  local alternatives = r.alternatives
  assert(alternatives ~= nil and #alternatives == 2)
  local indexes: mut {integer: boolean} = {}
  for _, alternative in ipairs(alternatives) do
    local index = alternative.path[1].index
    assert(index ~= nil and steps(alternative) == "target_alternative " .. tostring(index) .. " > item 1", steps(alternative))
    assert(alternative.code == "number_for_integer" and alternative.sub == s.number and alternative.super == s.integer)
    indexes[index] = true
  end
  assert(indexes[1] and indexes[2])
  -- and the same pair asked directly is explained from its own root
  assert(steps(refusal(w, s.number, s.integer)) == "")
end

local function test_a_judge_that_has_settled_a_pair_answers_it_the_same_way_unexplained_and_explained()
  local w = world()
  local s = w.store
  local a, b = s:array(s.number), s:array(s.integer)
  assert(not w.judge:subtype(a, b))
  local r = w.judge:refuse(a, b)
  assert(r ~= nil and r.code == "number_for_integer")
  assert(not w.judge:subtype(a, b))
  assert(w.judge:refuse(b, a) == nil and w.judge:subtype(b, a))
end

local function test_a_ladder_of_interfaces_that_each_list_the_next_twice_has_a_closure_the_judge_cuts_short()
  -- Every rung lists the next as an array and as a map of its argument: the closure holds every
  -- way of wrapping the argument, twice as many for each rung, and the judge stops at 4096.
  local w = world()
  local s = w.store
  local rungs: mut {Types.Decl} = {}
  for i = 1, 14 do
    rungs[i] = s:declare("interface", "m", { "Rung" .. tostring(i) }, 1)
  end
  for i, rung in ipairs(rungs) do
    local supers: {Types.Type} = {}
    local next_rung = rungs[i + 1]
    if next_rung ~= nil then
      supers = { s:named(next_rung, { s:array(s:var(0, 0)) }), s:named(next_rung, { s:map(s.integer, s:var(0, 0)) }) }
    end
    s:define(rung, { tparams = { { name = "T" } }, supers = supers, fields = {}, methods = {}, values = {} })
  end
  local top = s:named(rungs[1], { s.integer })
  assert((top.tag == "named"))
  local listing = w.judge:listed(top)
  assert(#listing.types == 4096 and not listing.complete, #listing.types)
  -- the listings the judge holds are related, and the others are refused
  assert(below(w, top, s:named(rungs[2], { s:array(s.integer) })))
  refused(w, top, named(w, "Event"), "not_listed")
  -- a ladder of fewer rungs is whole
  local middle = s:named(rungs[10], { s.integer })
  assert((middle.tag == "named"))
  local short = w.judge:listed(middle)
  assert(#short.types == 30 and short.complete, #short.types)
end

-- limits ---------------------------------------------------------------------------------------------

local function test_a_type_nested_as_deep_as_the_store_allows_is_related_and_explained()
  local w = world()
  local s = w.store
  local a, b = s.integer, s.number
  for _ = 1, 990 do
    a, b = s:array(a), s:array(b)
  end
  assert(below(w, a, b))
  local r = refusal(w, b, a)
  assert(r.code == "number_for_integer" and #r.path == 990, #r.path)
  local deep = s:union({ a, s.string })
  assert(below(w, a, deep) and not w.judge:subtype(deep, a))
end

local function test_a_listing_whose_argument_is_as_deep_as_the_store_allows_ends_the_closure()
  local w = world()
  local s = w.store
  -- Every rung lists the next with its argument in an array: one level deeper at each step.
  local rungs: mut {Types.Decl} = {}
  for i = 1, 40 do
    rungs[i] = s:declare("interface", "m", { "Wrap" .. tostring(i) }, 1)
  end
  for i, rung in ipairs(rungs) do
    local next_rung = rungs[i + 1]
    local supers: {Types.Type} = {}
    if next_rung ~= nil then
      supers = { s:named(next_rung, { s:array(s:var(0, 0)) }) }
    end
    s:define(rung, { tparams = { { name = "T" } }, supers = supers, fields = {}, methods = {}, values = {} })
  end
  local deep = s.integer
  for _ = 1, 980 do
    deep = s:array(deep)
  end
  local top = s:named(rungs[1], { deep })
  assert((top.tag == "named"))
  local listing = w.judge:listed(top)
  assert(#listing.types > 1 and #listing.types < 39 and not listing.complete, #listing.types)
  refused(w, top, named(w, "Event"), "not_listed")
  -- the same for an array part, whose type would nest one deeper than the store allows
  for _ = 1, 18 do
    deep = s:array(deep)
  end
  local wrap = s:declare("record", "m", { "Wrap" }, 1)
  s:define(wrap, { tparams = { { name = "T" } }, supers = {}, fields = {}, methods = {}, values = {},
    array = s:array(s:array(s:var(0, 0))) })
  refused(w, s:named(wrap, { deep }), s:array(s:array(s.string)), "mismatch")
end

local function test_a_chain_of_listings_that_does_not_grow_is_followed_to_its_end()
  local w = world()
  local s = w.store
  local previous: Types.Type?
  local first: Types.Type?
  for i = 1, 300 do
    local decl = s:declare("interface", "m", { "Chain" .. tostring(i) }, 0)
    local supers: mut {Types.Type} = {}
    if previous ~= nil then
      supers[1] = previous
    end
    s:define(decl, { tparams = {}, supers = supers, fields = {}, methods = {}, values = {} })
    previous = s:named(decl)
    first = first or previous
  end
  assert(previous ~= nil and first ~= nil)
  assert(below(w, previous, first))
  refused(w, first, previous, "not_listed")
end

local function test_a_declaration_read_before_it_is_defined_raises_and_the_judge_goes_on()
  local w = world()
  local s = w.store
  local event, node = named(w, "Event"), named(w, "Node")
  local late = s:declare("record", "m", { "Late" }, 0)
  local use = s:named(late)
  local function raises(a: Types.Type, b: Types.Type, message: string)
    local ok, why = pcall(function()
      local _ = w.judge:subtype(a, b)
    end)
    assert(not ok and tostring(why) == message, tostring(why))
    ok, why = pcall(function()
      local _ = w.judge:refuse(a, b)
    end)
    assert(not ok and tostring(why) == message, tostring(why))
  end
  -- what it lists, and its array part, are read from the body
  raises(use, event, "relation: Late is not defined")
  raises(use, s:array(node), "relation: Late is not defined")
  -- an interface that a class lists, and has not defined, is read too
  local ghost = s:declare("interface", "m", { "Ghost" }, 0)
  local lists_ghost = s:declare("class", "m", { "ListsGhost" }, 0)
  s:define(lists_ghost, { tparams = {}, supers = { s:named(ghost) }, fields = {}, methods = {}, values = {} })
  raises(s:named(lists_ghost), event, "relation: Ghost is not defined")
  -- two uses with different counts of arguments of a declaration whose count is not known
  local unknown = s:declare("record", "m", { "NoArity" })
  raises(s:named(unknown, {}), s:named(unknown, { s.integer }), "relation: NoArity is not defined")
  raises(s:named(unknown, { s.integer }), s:named(unknown, {}), "relation: NoArity is not defined")
  -- a nominal comparison reads no body
  refused(w, use, named(w, "Tree"), "nominal")
  assert(below(w, use, use))
  -- nothing was settled: once defined, the declaration is read as it is
  s:define(late, { tparams = {}, supers = { event }, fields = {}, methods = {}, values = {} })
  assert(below(w, use, event))
end

local function test_a_bound_of_another_store_is_refused_where_a_binder_is_entered()
  local w = world()
  local other = Types.new()
  local foreign = other:named(other:declare("interface", "m", { "Foreign" }, 0))
  local ok, why = pcall(function()
    w.judge:enter({ { bound = foreign } })
  end)
  assert(not ok and tostring(why):find("another store", 1, true) ~= nil, tostring(why))
  -- and nothing was entered
  assert(not pcall(function()
    w.judge:leave()
  end))
  local holder = w.store:declare("record", "m", { "Holder" }, 1)
  w.store:define(holder, { tparams = { { name = "T", bound = named(w, "Event") } }, supers = {}, fields = {},
    methods = {}, values = {} })
  assert(#Relation.binder(holder) == 1)
  holder.owner = holder.owner + 1000
  ok, why = pcall(function()
    local _ = Relation.binder(holder)
  end)
  assert(not ok and tostring(why):find("another store", 1, true) ~= nil, tostring(why))
end

local function test_a_listing_whose_arguments_differ_only_by_invalid_is_listed()
  local w = world()
  local s = w.store
  -- Box<invalid> lists Source<invalid>, which stands for Source<integer> as invalid does everywhere
  assert(below(w, named(w, "Box", { s.invalid }), named(w, "Source", { s.integer })))
  assert(below(w, named(w, "Box", { s.integer }), named(w, "Source", { s.invalid })))
  refused(w, named(w, "Box", { s.invalid }), named(w, "Event"), "not_listed")
  refused(w, named(w, "Box", { s.integer }), named(w, "Source", { s.string }), "not_listed")
end

local function test_the_list_a_refusal_carries_is_a_copy()
  local w = world()
  local first = refused(w, named(w, "Duplex"), named(w, "Event"), "not_listed")
  local lists = first.lists
  assert(lists ~= nil and #lists == 2)
  lists[1] = w.store.string
  lists[#lists + 1] = w.store.integer
  local again = refused(w, named(w, "Duplex"), named(w, "Event"), "not_listed")
  local fresh = again.lists
  assert(fresh ~= nil and #fresh == 2 and fresh[1] == named(w, "ReadWriter"))
  assert(below(w, named(w, "Duplex"), named(w, "Stream.Reader")))
end

local function test_return_lists_that_differ_in_whether_they_end_in_a_tail_are_unrelated_both_ways()
  local w = world()
  local s = w.store
  local tailed = s:fn({ rets = { { items = { s.string }, tail = s.integer } } })
  local plain = s:fn({ rets = { { items = { s.string } } } })
  refused(w, tailed, plain, "return_length", "alternative 1")
  refused(w, plain, tailed, "return_length", "alternative 1")
end

local function test_a_refusal_names_the_position_of_the_alternative_that_failed()
  local w = world()
  local s = w.store
  local yes, no = s:atom("true"), s:atom("false")
  local wanted = s:fn({ rets = { { items = { yes, s.string } } } })
  local seen: mut {integer: boolean} = {}
  for _, failing in ipairs({ no, s.integer, s.boolean }) do
    local given = s:fn({ rets = { { items = { yes, s.string } }, { items = { failing, s.string } } } })
    assert((given.tag == "fn"))
    local r = refusal(w, given, wanted)
    local index = r.path[1].index
    assert(r.path[1].kind == "alternative" and index ~= nil, Relation.trace(r))
    local alt = given.rets[index]
    assert(alt ~= nil and alt.items[1] == failing, Relation.trace(r))
    seen[index] = true
  end
  assert(seen[1] and seen[2])
end

local function test_a_rest_step_names_the_position_it_stands_at()
  local w = world()
  local s = w.store
  -- the rest parameter of the function wanted, against a parameter given
  local given = s:fn({ params = { { type = s.integer, omittable = true } } })
  local wanted = s:fn({ rest = s.number })
  local r = refused(w, given, wanted, "union_none", "rest 1")
  assert(r.path[1].index == 1)
  -- the rest parameters of both, from the position after the last parameter of either
  r = refused(w, s:fn({ rest = s.integer }), s:fn({ rest = s.number }), "number_for_integer", "rest 1")
  assert(r.path[1].index == 1)
  r = refused(w, s:fn({ params = { { type = s.string }, { type = s.number, omittable = true } }, rest = s.integer }),
    s:fn({ params = { { type = s.string } }, rest = s.number }), "number_for_integer", "rest 3")
  assert(r.path[1].index == 3)
end

-- an open decode, a bound, an undefined binder -------------------------------------------------------

local function test_a_bound_that_is_not_an_interface_with_no_arguments_is_refused_where_a_binder_is_entered()
  local w = world()
  local s = w.store
  local v = s:var(0, 1)
  -- An open bound is read unshifted, and two bounds that name each other would never end.
  local open_bound = named(w, "Source", { v })
  local bad: {Types.Type} = { open_bound, named(w, "Source", { s.integer }), named(w, "File"), s.integer, v,
    s:array(v) }
  for _, bound in ipairs(bad) do
    local ok, why = pcall(function()
      w.judge:enter({ { bound = bound }, {} })
    end)
    assert(not ok and tostring(why):find("relation: a bound is an interface", 1, true) ~= nil,
      shown(bound) .. ": " .. tostring(why))
  end
  -- and nothing was entered
  assert(not pcall(function()
    w.judge:leave()
  end))
  w.judge:enter({ { bound = named(w, "Event") } })
  assert(below(w, s:var(0, 0), named(w, "Event")))
  w.judge:leave()
end

local function test_the_binder_of_a_declaration_that_is_not_defined_raises()
  local w = world()
  local late = w.store:declare("record", "m", { "Late" }, 1)
  local ok, why = pcall(function()
    local _ = Relation.binder(late)
  end)
  assert(not ok and tostring(why) == "relation: Late is not defined", tostring(why))
end

local record Holder
  mut judge?: Relation.Judge
  mut store?: Types.Store
  mut raised: string
end

local function test_a_loader_that_relates_types_while_a_decode_is_open_is_refused_and_leaves_no_stale_answer()
  -- A decode that fails gives back the ids it made, which a later type reuses: an answer kept for
  -- one would be for another.
  local holder: Holder = { raised = "" }
  local store = Types.new(function(_: string, _: string): string?
    local judge, mine = holder.judge, holder.store
    assert(judge ~= nil and mine ~= nil)
    local ok, why = pcall(function()
      local _ = judge:subtype(mine:array(mine.string), mine:array(mine.boolean))
    end)
    holder.raised = if ok then "" else tostring(why) end
    return nil
  end)
  local judge = Relation.new(store)
  holder.judge, holder.store = judge, store
  local decoded, why = store:decode('(ref "m" "Missing")')
  assert(decoded == nil and why:find("types:", 1, true) == 1, why)
  assert(holder.raised:find("relation: a decode is open", 1, true) ~= nil, holder.raised)
  assert(not judge:subtype(store:array(store.string), store:array(store.boolean)))
  assert(judge:subtype(store:array(store.integer), store:array(store.number)))
end

-- survivors of a mutation run -------------------------------------------------------------------------

local function test_invalid_as_the_type_of_an_is_declaration_is_equal_to_every_type_on_either_side()
  local w = world()
  local s = w.store
  local event, key = named(w, "Event"), named(w, "KeyEvent")
  local function narrowing(to: Types.Type, asserted: boolean): Types.Type
    return s:fn({
      params = { { type = event } },
      rets = { { items = {}, narrows = { param = 1, to = to, asserts = asserted } } },
    })
  end
  for _, asserted in ipairs({ false, true }) do
    assert(below(w, narrowing(s.invalid, asserted), narrowing(key, asserted)))
    assert(below(w, narrowing(key, asserted), narrowing(s.invalid, asserted)))
  end
end

local function test_a_listing_with_two_arguments_is_read_with_each_in_its_place()
  local w = world()
  local s = w.store
  local i2 = s:declare("interface", "m", { "I2" }, 2)
  s:define(i2, { tparams = { { name = "A" }, { name = "B" } }, supers = {}, fields = {}, methods = {}, values = {} })
  local r2 = s:declare("class", "m", { "R2" }, 2)
  s:define(r2, { tparams = { { name = "A" }, { name = "B" } },
    supers = { s:named(i2, { s:var(0, 1), s:var(0, 0) }) }, fields = {}, methods = {}, values = {} })
  local function use_i2(a: Types.Type, b: Types.Type): Types.Type
    return s:named(i2, { a, b })
  end
  local function use_r2(a: Types.Type, b: Types.Type): Types.Type
    return s:named(r2, { a, b })
  end
  local int, str = s.integer, s.string
  assert(below(w, use_r2(int, str), use_i2(str, int)))
  refused(w, use_r2(int, str), use_i2(int, str), "not_listed")
  -- invalid stands for whatever is in its position, and only there
  assert(below(w, use_r2(s.invalid, str), use_i2(str, int)))
  assert(below(w, use_r2(s.invalid, str), use_i2(str, str)))
  refused(w, use_r2(s.invalid, str), use_i2(int, int), "not_listed")
  assert(below(w, use_r2(int, s.invalid), use_i2(int, int)))
  refused(w, use_r2(int, s.invalid), use_i2(int, str), "not_listed")
  assert(below(w, use_r2(int, s.invalid), use_i2(s.invalid, int)))
  assert(below(w, use_r2(int, s.invalid), use_i2(str, int)))
  refused(w, use_r2(int, s.invalid), use_i2(str, str), "not_listed")
end

local function test_a_closure_that_lists_one_generic_interface_twice_holds_both()
  local w = world()
  local s = w.store
  local both = s:declare("class", "m", { "Both" }, 0)
  s:define(both, { tparams = {}, supers = { named(w, "Source", { s.integer }), named(w, "Source", { s.string }) },
    fields = {}, methods = {}, values = {} })
  local use = s:named(both)
  assert(below(w, use, named(w, "Source", { s.integer })))
  assert(below(w, use, named(w, "Source", { s.string })))
  assert(below(w, use, named(w, "Source", { s.invalid })))
  local r = refused(w, use, named(w, "Source", { s.number }), "not_listed")
  local lists = r.lists
  assert(lists ~= nil and #lists == 2)
end

local function test_an_interface_use_is_below_the_same_use_with_invalid_and_a_mut_map_with_an_invalid_value_is_related()
  local w = world()
  local s = w.store
  assert(below(w, named(w, "Source", { s.integer }), named(w, "Source", { s.invalid })))
  assert(below(w, named(w, "Source", { s.invalid }), named(w, "Source", { s.integer })))
  assert(below(w, s:map(s.string, s.invalid, true), s:map(s.string, s.integer, true)))
  assert(below(w, s:map(s.string, s.integer, true), s:map(s.string, s.invalid, true)))
end

local function test_a_chain_of_listings_longer_than_a_closure_holds_is_followed_as_far_as_it_holds()
  local w = world()
  local s = w.store
  local decls: mut {Types.Decl} = {}
  local uses: mut {Types.Type} = {}
  for i = 1, 4200 do
    decls[i] = s:declare("interface", "m", { "Long" .. tostring(i) }, 0)
    uses[i] = s:named(decls[i])
  end
  -- Defined from the top down, so that the store's check for a cycle stops at a declaration it has no
  -- body for and does not walk the chain below each one (4200 steps each, which took seconds).
  for i = 4200, 1, -1 do
    s:define(decls[i], { tparams = {}, supers = if i > 1 then { uses[i - 1] } else {} end, fields = {}, methods = {},
      values = {} })
  end
  assert(below(w, uses[4200], uses[200]))
  assert(below(w, uses[4200], uses[105]))
  refused(w, uses[4200], uses[100], "not_listed")
  refused(w, uses[4200], uses[1], "not_listed")
end

local function test_a_chain_of_generic_interfaces_that_pass_their_argument_on_is_followed_to_its_end()
  local w = world()
  local s = w.store
  -- 100 generic interfaces, each listing the next with its own argument.
  local decls: mut {Types.Decl} = {}
  for i = 1, 100 do
    decls[i] = s:declare("interface", "m", { "G" .. tostring(i) }, 1)
  end
  for i = 1, 100 do
    local supers: mut {Types.Type} = {}
    if i < 100 then
      supers[1] = s:named(decls[i + 1], { s:var(0, 0) })
    end
    s:define(decls[i], { tparams = { { name = "T" } }, supers = supers, fields = {}, methods = {}, values = {} })
  end
  local root = s:declare("class", "m", { "UnderG" }, 0)
  s:define(root, { tparams = {}, supers = { s:named(decls[1], { s.integer }) }, fields = {}, methods = {},
    values = {} })
  assert(below(w, s:named(root), s:named(decls[100], { s.integer })))
  refused(w, s:named(root), s:named(decls[100], { s.string }), "not_listed")
end

local function test_a_failing_alternative_is_named_by_its_position_whichever_it_is()
  local w = world()
  local s = w.store
  local yes, no = s:atom("true"), s:atom("false")
  -- a function that may return, where one that never does is wanted: the first alternative is the one
  local given = s:fn({ rets = { { items = { yes } }, { items = { no } } } })
  local never = s:fn({ rets = {} })
  local r = refused(w, given, never, "may_return", "alternative 1")
  assert(r.sub == given and r.super == never)
  -- two alternatives wanted, none of which takes the second given
  local wanted = s:fn({ rets = { { items = { yes, s.string } }, { items = { no, s.string } } } })
  local seen: mut {integer: boolean} = {}
  for _, failing in ipairs({ s.integer, s.number, s.boolean }) do
    local one = s:fn({ rets = { { items = { yes, s.string } }, { items = { yes, failing } } } })
    assert((one.tag == "fn"))
    local reason = refusal(w, one, wanted)
    assert(reason.code == "return_unmatched", Relation.trace(reason))
    local index = reason.path[1].index
    assert(index ~= nil)
    local alt = one.rets[index]
    assert(reason.path[1].kind == "alternative" and alt ~= nil and alt.items[2] == failing, Relation.trace(reason))
    seen[index] = true
  end
  assert(seen[1] and seen[2])
end

local function test_a_rest_step_names_a_position_inside_the_parameters()
  local w = world()
  local s = w.store
  -- the rest parameter of the function wanted meets the second parameter of the function given
  local given = s:fn({ params = { { type = s.string }, { type = s.integer, omittable = true } } })
  local wanted = s:fn({ params = { { type = s.string } }, rest = s.number })
  local r = refused(w, given, wanted, "union_none", "rest 2")
  assert(r.path[1].index == 2)
end
