--- The programs the fork accepts and the plan refuses, as relation questions. The comment of each
--- test names the test of build/teal_test.tl that pins the hole, and the test states the types
--- of the program (the declarations, the annotations and the types of the values it passes) and
--- the verdict of [`lang.relation`]. A test holds what is relation: a type that stands where another is
--- wanted. What is flow (a narrowing the fork loses at a join), an expression (`as`, `rawset`, a call
--- of a union) or a declaration (interface agreement, an overload set) is another piece's.
local Programs = require("lang.relation_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

local world = Programs.world
local named = Programs.named
local func = Programs.func
local nothing = Programs.nothing
local below = Programs.below
local refused = Programs.refused

-- never -------------------------------------------------------------------------------------------

-- `test_a_never_function_is_a_subtype_of_any_function`: `fail: function(string): never` stands for
-- a function of its parameters, and `print`, which may return, does not stand for one that does not.
local function test_a_never_function_stands_for_a_function_of_its_parameters_and_a_returning_one_does_not_stand_for_it()
  local w = world()
  local s = w.store
  local fail = s:fn({ params = { { type = s.string } }, rets = {} })
  assert(below(w, fail, nothing(w, { s.string })))
  assert(below(w, fail, func(w, { s.string }, { s.integer })))
  local print_ = s:fn({ rest = s.any })
  refused(w, print_, s:fn({ rets = {} }), "may_return", "alternative 1")
  refused(w, nothing(w, { s.string }), fail, "may_return", "alternative 1")
  refused(w, func(w, { s.string }, { s.integer }), fail, "may_return", "alternative 1")
end

-- `test_a_record_function_agrees_with_its_field_on_never`: the function that fills a field declared
-- `: never` may not return, and a function that never returns fills a field that may.
local function test_a_function_that_may_return_does_not_fill_a_never_field()
  local w = world()
  local s = w.store
  local why = { s.string }
  local die = s:fn({ params = { { type = s.string } }, rets = {} })
  refused(w, nothing(w, why), die, "may_return", "alternative 1")
  assert(below(w, die, nothing(w, why)))
end

-- `test_a_poly_function_is_never_only_when_every_overload_is`: an overload set is not a type of
-- the store, so what it holds is a question per overload: each is a function type, and one that may
-- return is not below `function(string): never`.
local function test_an_overload_that_may_return_is_not_a_never_function()
  local w = world()
  local s = w.store
  local never_string = s:fn({ params = { { type = s.string } }, rets = {} })
  refused(w, func(w, { s.integer }, { s.string }), never_string, "mismatch", "parameter 1")
  refused(w, func(w, { s.string }, { s.string }), never_string, "may_return", "alternative 1")
end

-- `test_never_agrees_when_nested`: a function that never returns is below one that may in a
-- covariant place (a view, a map's value, a union, a return) and in no place a program writes
-- through (a `mut` collection, a generic's argument, a record's field), where the old checker
-- refused both directions because `never` was a flag. A parameter swaps the direction.
local function test_a_never_function_is_below_a_returning_one_only_where_the_place_is_covariant()
  local w = world()
  local s = w.store
  local dies = s:fn({ rets = {} })
  local returns = s:fn({ rets = { { items = { s.string } } } })
  local function wrap(kind: string, f: Types.Type): Types.Type
    if kind == "array" then
      return s:array(f)
    elseif kind == "map" then
      return s:map(s.string, f)
    elseif kind == "union" then
      return s:optional(f)
    elseif kind == "mut array" then
      return s:array(f, true)
    elseif kind == "mut map" then
      return s:map(s.string, f, true)
    end
    return named(w, "List", { f })
  end
  local covariant: {string: boolean} = { array = true, map = true, union = true }
  local seen = 0
  for _, kind in ipairs({ "array", "map", "union", "mut array", "mut map", "generic" }) do
    local ok = covariant[kind] == true
    -- the type itself, in a return and as a parameter
    local forward = { wrap(kind, dies), wrap(kind, returns) }
    for _, place in ipairs({ "return", "parameter" }) do
      local function mk(t: Types.Type): Types.Type
        if place == "return" then
          return func(w, {}, { t })
        end
        return nothing(w, { t })
      end
      local given_never, given_returns = mk(forward[1]), mk(forward[2])
      -- a parameter swaps: the function over the returning container takes the never one
      local expect_forward = place == "return" and ok
      local expect_back = place == "parameter" and ok
      assert(below(w, given_never, given_returns) == expect_forward, kind .. " " .. place .. " forward")
      assert(below(w, given_returns, given_never) == expect_back, kind .. " " .. place .. " back")
      seen = seen + 1
    end
  end
  assert(seen == 12, tostring(seen))
  -- a record is nominal: one whose field never returns is not one whose field may
  local quiet, loud = named(w, "Quiet"), named(w, "Loud")
  refused(w, quiet, loud, "nominal")
  refused(w, loud, quiet, "nominal")
  refused(w, func(w, {}, { quiet }), func(w, {}, { loud }), "nominal", "alternative 1 > item 1")
end

-- `test_never_agrees_in_a_callback_parameter`: a function that takes a callback that never returns
-- does not stand for one that takes a callback that may, since it would run after the call that
-- returned. The other direction is sound and accepted.
local function test_a_function_over_a_never_callback_is_not_a_function_over_a_returning_one()
  local w = world()
  local s = w.store
  local dies = s:fn({ rets = {} })
  local returns = s:fn({ rets = { { items = { s.string } } } })
  local takes_never = nothing(w, { dies })
  local takes_returning = nothing(w, { returns })
  refused(w, takes_never, takes_returning, "may_return", "parameter 1 > alternative 1")
  assert(below(w, takes_returning, takes_never))
end

-- `test_as_and_is_forge_a_never_function`: `P` and `Q` are records, one whose `die` never returns.
-- A `Q` is no `P` whichever way the cast says, and `print`, which returns, is no `function(): never`.
-- (`v is function(): never` on an `any` and the cast `as` are the expression and flow pieces'.)
local function test_a_record_whose_function_may_return_is_not_one_whose_function_does_not()
  local w = world()
  local s = w.store
  local quiet, loud = named(w, "Quiet"), named(w, "Loud")
  refused(w, loud, quiet, "nominal")
  refused(w, s:fn({ rest = s.any }), s:fn({ rets = {} }), "may_return", "alternative 1")
  -- an `any` is no `function(): never` either
  refused(w, s.any, s:fn({ rets = {} }), "any_source")
  refused(w, s.any, quiet, "any_source")
end

-- `test_a_generic_cannot_write_a_returning_function_into_a_never_container`: `put<T>(t: {T}, v: T)`,
-- `table.insert`, a copy that answers its argument, a generic record, a map, and the callback that
-- takes the container's element. Each writes a function that may return into a container of ones
-- that do not, and each needs the container to stand for `mut {function(): string}`, which is
-- invariant, or the record to stand for another, which is nominal.
local function test_a_container_of_never_functions_is_not_a_container_of_returning_ones()
  local w = world()
  local s = w.store
  local dies = s:fn({ rets = {} })
  local may_return = s:fn({})
  local pairs_of: {{Types.Type}} = {
    { s:array(dies, true), s:array(may_return, true) },
    { s:map(s.string, dies, true), s:map(s.string, may_return, true) },
    { s:array(s:array(dies, true), true), s:array(s:array(may_return, true), true) },
    { s:array(s:array(dies)), s:array(s:array(may_return)) },
  }
  refused(w, pairs_of[1][1], pairs_of[1][2], "invariant_mut", "element")
  refused(w, pairs_of[1][2], pairs_of[1][1], "invariant_mut", "element")
  refused(w, pairs_of[2][1], pairs_of[2][2], "invariant_mut", "value")
  refused(w, pairs_of[2][2], pairs_of[2][1], "invariant_mut", "value")
  refused(w, pairs_of[3][1], pairs_of[3][2], "invariant_mut", "element")
  refused(w, pairs_of[3][2], pairs_of[3][1], "invariant_mut", "element")
  -- the view of views is covariant and cannot be written
  assert(below(w, pairs_of[4][1], pairs_of[4][2]))
  refused(w, pairs_of[4][2], pairs_of[4][1], "may_return", "element > element > alternative 1")
  -- a generic record
  refused(w, named(w, "List", { dies }), named(w, "List", { may_return }), "invariant_generic", "argument 1")
  refused(w, named(w, "List", { may_return }), named(w, "List", { dies }), "invariant_generic", "argument 1")
  -- a record is not a map of its fields, so `put<T>(t: {string:T}, v: T)` takes no record
  refused(w, named(w, "Quiet"), s:map(s.string, dies, true), "record_as_map")
  refused(w, named(w, "Quiet"), s:map(s.string, may_return, true), "record_as_map")
  -- the callback that takes the element: `cb<T>(v: T, f: function(T))`
  refused(w, nothing(w, { dies }), nothing(w, { may_return }), "may_return", "parameter 1 > alternative 1")
end

-- variance ----------------------------------------------------------------------------------------

-- `test_a_function_parameter_is_contravariant`
local function test_a_function_that_takes_a_narrower_type_is_no_function_over_a_wider_one()
  local w = world()
  local s = w.store
  local number_cb, integer_cb = func(w, {}, { s.number }), func(w, {}, { s.integer })
  refused(w, nothing(w, { integer_cb }), nothing(w, { number_cb }), "number_for_integer",
    "parameter 1 > alternative 1 > item 1")
  refused(w, nothing(w, { s.integer }), nothing(w, { s.number }), "number_for_integer", "parameter 1")
  refused(w, nothing(w, { s.string, s.integer }), nothing(w, { s.string, s.number }), "number_for_integer",
    "parameter 2")
  assert(below(w, nothing(w, { s.number }), nothing(w, { s.integer })))
  assert(below(w, nothing(w, { number_cb }), nothing(w, { integer_cb })))
end

-- `test_a_function_return_is_covariant`
local function test_a_function_that_gives_a_wider_type_is_no_function_giving_a_narrower_one()
  local w = world()
  local s = w.store
  assert(below(w, func(w, {}, { s.integer }), func(w, {}, { s.number })))
  refused(w, func(w, {}, { s.number }), func(w, {}, { s.integer }), "number_for_integer", "alternative 1 > item 1")
  refused(w, func(w, {}, { s.integer, s.number }), func(w, {}, { s.integer, s.integer }), "number_for_integer",
    "alternative 1 > item 2")
end

-- `test_a_field_function_takes_a_narrower_receiver`, `test_only_a_record_receiver_of_a_field_function_is_exempt`
-- and `test_a_narrower_receiver_is_taken_wherever_fields_are_compared`: `Reader` is an interface
-- with `read: function(Reader, integer): string` and `Mine` a record that lists it. The old checker
-- took a function over `Mine` for the interface's field (and for a literal's, an assignment's and
-- an inferred table's); a receiver is an ordinary parameter now, so none of them stands.
local function test_a_receiver_is_an_ordinary_parameter()
  local w = world()
  local s = w.store
  local reader, mine = named(w, "Stream.Reader"), named(w, "File")
  local read_integer = func(w, { reader, s.integer }, { s.string })
  local read_mine = func(w, { mine, s.integer }, { s.string })
  refused(w, read_mine, read_integer, "nominal", "parameter 1")
  assert(below(w, read_integer, read_mine))
  refused(w, nothing(w, { mine }), nothing(w, { reader }), "nominal", "parameter 1")
  -- a callback parameter of the record that holds it
  local box = named(w, "Tree")
  refused(w, nothing(w, { box, nothing(w, { reader }) }), nothing(w, { box, nothing(w, { mine }) }), "nominal",
    "parameter 2 > parameter 1")
  assert(below(w, nothing(w, { box, nothing(w, { mine }) }), nothing(w, { box, nothing(w, { reader }) })))
  -- a first parameter that is no record is no receiver, and never was
  refused(w, func(w, { s.integer }, { s.number }), func(w, { s.number }, { s.number }), "number_for_integer",
    "parameter 1")
  -- the other parameters and the returns, with `number` for `integer`
  refused(w, func(w, { mine, s.number }, { s.string }), func(w, { reader, s.integer }, { s.string }), "nominal",
    "parameter 1")
  refused(w, func(w, { mine }, { s.number }), func(w, { mine }, { s.integer }), "number_for_integer",
    "alternative 1 > item 1")
end

-- `test_a_callback_field_with_a_record_parameter_is_the_known_limit`: `Opts.cb: function(Event)` took a
-- function over a `KeyEvent`, a record that lists `Event`, and `Opts.cb2: function(KeyEvent)` did not take
-- one over a `MouseEvent`, which does not.
local function test_a_callback_over_a_record_is_no_callback_over_its_interface()
  local w = world()
  local event, key, mouse = named(w, "Event"), named(w, "KeyEvent"), named(w, "MouseEvent")
  refused(w, nothing(w, { key }), nothing(w, { event }), "nominal", "parameter 1")
  refused(w, nothing(w, { mouse }), nothing(w, { key }), "nominal", "parameter 1")
  assert(below(w, nothing(w, { event }), nothing(w, { key })))
end

-- any ----------------------------------------------------------------------------------------------

-- `test_an_any_parameter_takes_any_parameter`: a function over `string` and `integer` stood for
-- `function(any...): any...` (and for what `coroutine.create` takes, and a `__call`), because the
-- old checker took `any` for the unchecked type in every place. A function stands for one over `any`
-- only if it takes `any`.
local function test_a_function_over_a_type_does_not_stand_for_a_function_over_any()
  local w = world()
  local s = w.store
  local variadic = s:fn({ rest = s.any, rets = { { items = {}, tail = s.any } } })
  local given = func(w, { s.string, s.integer }, { s.string })
  refused(w, given, variadic, "arity")
  -- two parameters of any, as `coroutine.create(function(a: string, b: integer))` is passed
  local r = refused(w, given, s:fn({ params = { { type = s.any }, { type = s.any } } }), "any_source", "parameter 1")
  assert(r.sub == s.any and r.super == s.string)
  refused(w, nothing(w, { s.integer, s.string }), nothing(w, { s.number, s.any }), "number_for_integer",
    "parameter 1")
  refused(w, nothing(w, { s.integer, s.string }), nothing(w, { s.integer, s.any }), "any_source", "parameter 2")
  assert(below(w, nothing(w, { s.any }), nothing(w, { s.any })))
  -- and a function over any does not stand for one over a string: contravariance does not widen it
  refused(w, nothing(w, { s.any }), nothing(w, { s.string }), "any_sink", "parameter 1")
end

-- `test_a_function_index_serves_any`: a function that serves a field answers `any`, and `any` is no
-- `string` (the metatable that held it is gone with the metatables; the function type is the question).
local function test_a_function_that_answers_any_is_no_function_answering_a_type()
  local w = world()
  local s = w.store
  local node = named(w, "Node")
  refused(w, func(w, { node, s.any }, { s.any }), func(w, { node, s.any }, { s.string }), "any_source",
    "alternative 1 > item 1")
  refused(w, func(w, { node, s.any }, { s.any }), func(w, { node, s.any }, { s.integer }), "any_source",
    "alternative 1 > item 1")
  -- and a value of a type is no `any` that a function answers
  refused(w, func(w, { node, s.any }, { s.string }), func(w, { node, s.any }, { s.any }), "any_sink",
    "alternative 1 > item 1")
end

-- `test_an_untyped_value_is_told_the_check_and_the_cast`: what [`Json.decode`] answers is `any` (with a
-- nil that `any` absorbs), and it is no record, no integer, no array.
local function test_untrusted_data_is_no_type_a_program_can_name()
  local w = world()
  local s = w.store
  local decoded = s:optional(s.any)
  assert(decoded == s.any)
  refused(w, decoded, named(w, "Node"), "any_source")
  refused(w, decoded, s.integer, "any_source")
  refused(w, decoded, s:array(s.string), "any_source")
  refused(w, decoded, s:optional(s.string), "any_source")
  assert(w.judge:accepts(named(w, "Node"), s.any))
end

-- `test_rawset_refuses_a_record`: a record whose fields share a type is no map of that type, so
-- `rawset(r, ...)` and a function over `{string: T}` take no record.
local function test_a_record_is_no_map_of_its_fields_even_where_they_share_a_type()
  local w = world()
  local s = w.store
  local same = s:declare("record", "m", { "Same" }, 0)
  s:define(same, { tparams = {}, supers = {}, methods = {}, values = {},
    fields = { { name = "name", type = s.string }, { name = "title", type = s.string } } })
  refused(w, s:named(same), s:map(s.string, s.string), "record_as_map")
  refused(w, s:named(same), s:map(s.string, s.string, true), "record_as_map")
  refused(w, named(w, "Tree"), s:map(s.string, s.any, true), "record_as_map")
  refused(w, s:named(same), s:map(s.integer, s.string), "record_as_map")
end

-- nil ---------------------------------------------------------------------------------------------

-- `test_a_literal_nil_is_refused_for_a_parameter_that_does_not_take_it`,
-- `test_an_argument_that_may_be_nil_is_refused_for_any_parameter`,
-- `test_a_table_argument_that_may_be_nil_is_refused`, `test_a_numeric_for_bound_that_may_be_nil_is_refused`
-- and `test_a_varargs_element_that_may_be_nil_is_refused`: nil, and a type that may be nil, is
-- no `string`, no `integer`, no `{string}`, and no element of a rest parameter `string`.
local function test_nil_and_a_type_that_may_be_nil_stand_for_no_type_that_admits_none()
  local w = world()
  local s = w.store
  local null = s:atom("nil")
  local maybe_string = s:optional(s.string)
  refused(w, null, s.string, "nil")
  refused(w, maybe_string, s.string, "nil", "nil")
  refused(w, s:optional(s.integer), s.integer, "nil", "nil")
  refused(w, s:optional(s:array(s.string)), s:array(s.string), "nil", "nil")
  refused(w, s:optional(s.number), s.number, "nil", "nil")
  refused(w, s:optional(named(w, "Node")), named(w, "Node"), "nil", "nil")
  -- `x: string?` is passed where `string` is wanted, as an argument and as an element of a rest parameter
  local greet = func(w, { s.string }, { s.string })
  local passes_optional = func(w, { maybe_string }, { s.string })
  assert(below(w, passes_optional, greet))
  refused(w, greet, passes_optional, "nil", "parameter 1 > nil")
  local rest = function(t: Types.Type): Types.Type
    return s:fn({ rest = t })
  end
  assert(below(w, rest(maybe_string), rest(s.string)))
  refused(w, rest(s.string), rest(maybe_string), "nil", "rest 1 > nil")
  -- an argument is nil to a parameter that admits it, and to `any`
  assert(w.judge:accepts(null, maybe_string))
  assert(w.judge:accepts(maybe_string, maybe_string))
  assert(w.judge:accepts(null, s.any))
  assert(w.judge:accepts(maybe_string, s.any))
  assert(not w.judge:accepts(null, s.string))
  assert(not w.judge:accepts(maybe_string, s.string))
  -- the elements of a list admit no nil, and the element of an `any` list takes none either
  refused(w, s.string, s:array(s.any), "mismatch")
  refused(w, s:array(s.string), s:array(s.any), "any_sink", "element")
end

-- `test_an_optional_field_admits_nil` and `test_an_optional_interface_field`: a field `name?: string`
-- has the type `string?`: nil is below it, a number is not, and a read is not a `string`.
local function test_an_optional_field_is_a_union_with_nil()
  local w = world()
  local s = w.store
  local field = s:optional(s.string)
  assert(below(w, s:atom("nil"), field))
  assert(below(w, s.string, field))
  refused(w, s.integer, field, "union_none")
  refused(w, field, s.string, "nil", "nil")
  -- a record that lists an interface with an optional field is that interface
  local named_interface = s:declare("interface", "m", { "Named" }, 0)
  s:define(named_interface, { tparams = {}, supers = {}, methods = {}, values = {},
    fields = { { name = "name", type = s.string, omittable = true } } })
  local dog = s:declare("record", "m", { "Dog" }, 0)
  s:define(dog, { tparams = {}, supers = { s:named(named_interface) }, methods = {}, values = {},
    fields = { { name = "name", type = s.string, omittable = true }, { name = "age", type = s.integer } } })
  assert(below(w, s:named(dog), s:named(named_interface)))
  refused(w, s:named(named_interface), s:named(dog), "nominal")
end

-- `test_a_gsub_replacement_takes_strings`: a replacement over `integer` is no replacement over strings.
local function test_a_replacement_over_integers_is_no_replacement_over_strings()
  local w = world()
  local s = w.store
  refused(w, func(w, { s.integer }, { s.string }), func(w, { s.string }, { s.string }), "mismatch", "parameter 1")
  assert(below(w, func(w, { s.string }, { s.string }), func(w, { s.string }, { s.string })))
end
