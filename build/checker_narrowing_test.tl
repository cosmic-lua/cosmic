--- Places and guards, [`checker/narrowing.tl`]: what a test tells of a
--- local or a field of one, and what an assignment makes of it. The
--- first half runs the module, compiled here by the compiler the tree
--- carries, against a stand-in for the checker's types. The second half
--- gives the carried checker programs and pins which it accepts: it
--- narrows a place wherever a guard says so, and the limits it keeps for
--- now are pinned as limits.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local teal = require("build.teal")
local type compiler = require("build.compiler")

Test.policy{ grants = { { path = "checker/narrowing.tl", letters = "r" } } }

local record Type
  typename: string
  members?: {Type}
end

local record Place
  base: string
  fields: {string}
  key: string
end

local record Guard
  fact: string
  w: any
  no_infer?: boolean
  f1?: Guard
  f2?: Guard
  place?: Place
  typ?: Type
end

local record Node
  kind: string
  tk?: string
  op?: {string:string}
  e1?: Node
  e2?: Node
  exp?: Node
  guard?: Guard
end

local record Drop
  kind: string
  text: string
  y: integer
  x: integer
  place?: string
end

local record Scope
  vars: {string:any}
  narrows?: {string:boolean}
  dropped?: {string:Drop}
  hidden?: {any}
  journal?: {any}
end

local record Host
  type_of: function(Place, any): Type | nil
  is_a: function(Type, Type): boolean
  unite: function(any, Type, Type): Type
  intersect: function(any, Type, Type): Type
  subtract: function(any, Type, Type): Type
  invalid: function(any): Type
  show: function(Type): string
  warn_never: function(any, string, Type, Type)
  refuse_never: function(any, string, Type, Type)
end

local record Narrowing
  truthy: Guard
  local_place: function(string): Place
  field_place: function(string, string): Place
  place_of: function(Node): Place | nil
  target_of: function(Node): Place | nil
  forgets: function(Place, string): boolean
  drop: function({Scope}, Place, Drop)
  drop_written: function({Scope}, string, Drop)
  drop_paths: function({Scope}, Drop)
  narrowed: function({Scope}): boolean, {string} | nil
  has_paths: function({Scope}): boolean
  note: function({Scope}, string, Drop)
  dropped_by: function({Scope}, string): Drop | nil
  cut: function({Scope}, string, Drop)
  places: function(Guard | nil): {Place}
  renarrowed: function({Scope}, string)
  forget: function(Guard | nil, function(Place): boolean): Guard | nil
  mark: function({Scope}): integer
  undo: function({Scope}, integer)
  enter_function: function({Scope})
  leave_function: function({Scope}, {any})
  type_is: function(any, Place, Type): Guard
  value_is: function(any, Place, Type): Guard
  negate: function(any, Guard | nil): Guard | nil
  both: function(any, Guard | nil, Guard | nil): Guard | nil
  either: function(any, Guard | nil, Guard | nil): Guard
  any_of: function(any, Guard | nil, Guard | nil): Guard
  none_of: function(any, {Node}, integer): Guard | nil
  evaluate: function(Host, Guard | nil): {string:Guard}
end

local built: compiler | nil
local narrowing: Narrowing | nil

--- The carried compiler, and [`checker/narrowing.tl`] compiled by it and
--- loaded.
local function setup(): compiler, Narrowing
  if built ~= nil and narrowing ~= nil then
    return built, narrowing
  end
  local compiled = assert(teal.load(true))
  local env = assert(compiled.new_env({ defaults = {
    feat_lax = "off", gen_compat = "off", gen_target = "5.4",
  } }))
  local code, result = compiled.gen(assert(Fs.read("checker/narrowing.tl")), env, nil, "tl")
  assert(code ~= nil and #result.type_errors == 0, "checker/narrowing.tl does not compile")
  -- The compiler's environment: `os.getenv` is what the module reads its
  -- trace switch with, and the test's own has none.
  local environment: {string:any} = {
    assert = assert, ipairs = ipairs, pairs = pairs, require = require, table = table,
    string = string, io = { stderr = { write = function() end } },
    os = { getenv = function(_name: string): string | nil return nil end },
  }
  local chunk = assert(load(code, "@checker/narrowing.tl", "t", environment as table))
  local loaded: any = chunk()
  built, narrowing = compiled, loaded as Narrowing
  return built, narrowing
end

--- [`checker/narrowing.tl`] as loaded.
local function module(): Narrowing
  local _, loaded = setup()
  return loaded
end

--- A stand-in for the checker's types: a name, and for a union its
--- members. [`is_a`] is membership, which is all the guards ask.
local function ty(name: string): Type
  return { typename = name, members = {} }
end

local function union(...: Type): Type
  return { typename = "union", members = { ... } }
end

local number <const> = ty("number")
local string_t <const> = ty("string")
local nothing <const> = ty("nil")

local function name_of(t: Type): string
  if t.typename == "union" then
    local names: {string} = {}
    for _, m in ipairs(t.members or {}) do
      names[#names + 1] = name_of(m)
    end
    return table.concat(names, "|")
  end
  return t.typename
end

local function members_of(t: Type): {Type}
  if t.typename == "union" then
    return t.members or {}
  end
  return { t }
end

--- What the stand-in host answers, and what it was asked to report.
local record World
  types: {string:Type}
  warned: {string}
  refused: {string}
end

local function host_of(world: World): Host
  local function has(t: Type, wanted: Type): boolean
    for _, m in ipairs(members_of(t)) do
      if m.typename == wanted.typename then
        return true
      end
    end
    return false
  end
  local function pick(t: Type, keep: function(Type): boolean): Type
    local kept: {Type} = {}
    for _, m in ipairs(members_of(t)) do
      if keep(m) then
        kept[#kept + 1] = m
      end
    end
    if #kept == 0 then
      return nothing
    end
    return #kept == 1 and kept[1] or { typename = "union", members = kept }
  end
  return {
    type_of = function(place: Place, _w: any): Type | nil
      return world.types[place.key]
    end,
    is_a = function(t1: Type, t2: Type): boolean
      for _, m in ipairs(members_of(t1)) do
        if not has(t2, m) then
          return false
        end
      end
      return true
    end,
    unite = function(_w: any, t1: Type, t2: Type): Type
      local all: {Type} = {}
      for _, m in ipairs(members_of(t1)) do
        all[#all + 1] = m
      end
      for _, m in ipairs(members_of(t2)) do
        if not has(t1, m) then
          all[#all + 1] = m
        end
      end
      return #all == 1 and all[1] or { typename = "union", members = all }
    end,
    intersect = function(_w: any, t1: Type, t2: Type): Type
      return pick(t1, function(m: Type): boolean return has(t2, m) end)
    end,
    subtract = function(_w: any, t1: Type, t2: Type): Type
      return pick(t1, function(m: Type): boolean return not has(t2, m) end)
    end,
    invalid = function(_w: any): Type
      return ty("invalid")
    end,
    show = name_of,
    warn_never = function(_w: any, who: string, have: Type, wanted: Type)
      world.warned[#world.warned + 1] = who .. ":" .. name_of(have) .. ":" .. name_of(wanted)
    end,
    refuse_never = function(_w: any, who: string, have: Type, wanted: Type)
      world.refused[#world.refused + 1] = who .. ":" .. name_of(have) .. ":" .. name_of(wanted)
    end,
  }
end

local here <const> = { f = "probe.tl", y = 1, x = 1 }

--- The facts `guard` holds when the places have `types`: each as
--- `key = fact name of type`, sorted.
local function facts(guard: Guard | nil, types: {string:Type}): {string}, World
  setup()
  local world: World = { types = types, warned = {}, refused = {} }
  local held = module().evaluate(host_of(world), guard)
  local lines: {string} = {}
  for key, f in pairs(held) do
    lines[#lines + 1] = key .. " " .. f.fact .. " " .. name_of(assert(f.typ)) .. (f.no_infer and " (widened)" or "")
  end
  table.sort(lines)
  return lines, world
end

local function expect(want: {string}, got: {string})
  assert(table.concat(got, "; ") == table.concat(want, "; "),
    "wanted [" .. table.concat(want, "; ") .. "] but got [" .. table.concat(got, "; ") .. "]")
end

local function op(symbol: string, e1: Node, e2: Node): Node
  return { kind = "op", op = { op = symbol }, e1 = e1, e2 = e2 }
end

local function variable(name: string): Node
  return { kind = "variable", tk = name }
end

local function test_a_place_is_a_local_or_a_field_of_one()
  setup()
  local x = assert(module().place_of(variable("x")))
  assert(x.key == "x" and x.base == "x" and #x.fields == 0)
  local f = assert(module().place_of(op(".", variable("r"), { kind = "identifier", tk = "a" })))
  assert(f.key == "r.a" and f.base == "r" and #f.fields == 1 and f.fields[1] == "a")
  assert(module().local_place("n").key == "n" and module().field_place("n", "m").key == "n.m")
end

local function test_no_other_expression_is_a_place()
  setup()
  local field = op(".", variable("r"), { kind = "identifier", tk = "a" })
  -- A longer path, an index, a call and a literal.
  assert(module().place_of(op(".", field, { kind = "identifier", tk = "b" })) == nil)
  assert(module().place_of(op("@index", variable("t"), { kind = "integer", tk = "1" })) == nil)
  assert(module().place_of(op("@funcall", variable("f"), variable("x"))) == nil)
  assert(module().place_of({ kind = "string", tk = "s" }) == nil)
end

local function test_an_assignment_targets_a_name_by_its_text_else_a_place()
  setup()
  assert(assert(module().target_of(variable("x"))).key == "x")
  -- Its text names the local even where the node is no variable read.
  local named: Node = { kind = "error_node", tk = "x" }
  assert(assert(module().target_of(named)).key == "x")
  assert(module().place_of(named) == nil)
  -- And it wins over the path of a node that has both.
  local both: Node = op(".", variable("r"), { kind = "identifier", tk = "a" })
  both.tk = "t"
  assert(assert(module().target_of(both)).key == "t")
  assert(assert(module().place_of(both)).key == "r.a")
  assert(assert(module().target_of(op(".", variable("r"), { kind = "identifier", tk = "a" }))).key == "r.a")
  assert(module().target_of(op("@index", variable("t"), variable("i"))) == nil)
end

local function test_an_assignment_to_a_local_drops_its_fields_not_itself()
  setup()
  local x = module().local_place("x")
  assert(module().forgets(x, "x.f") and module().forgets(x, "x.f.g"))
  assert(not module().forgets(x, "x"))
  assert(not module().forgets(x, "xy.f") and not module().forgets(x, "y.f"))
end

local function test_an_assignment_to_a_field_drops_that_field()
  setup()
  local f = module().field_place("x", "f")
  assert(module().forgets(f, "x.f"))
  assert(not module().forgets(f, "x.g") and not module().forgets(f, "y.f"))
  assert(not module().forgets(f, "x"))
end

--- The prefix test is the known limit [`checker/narrowing.tl`] holds a
--- TODO for: `x.f` also drops `x.foo`.
local function test_an_assignment_to_a_field_also_drops_a_longer_name()
  setup()
  assert(module().forgets(module().field_place("x", "f"), "x.foo"))
end

--- What drops, as the checker names it.
local call <const>: Drop = { kind = "call", text = "clear(...)", y = 3, x = 5 }
local write <const>: Drop = { kind = "write", text = "c.n = ...", y = 4, x = 1 }

local function test_drop_removes_the_names_from_every_scope()
  setup()
  local outer: Scope = {
    vars = { ["x.f"] = true, ["x.g"] = true, x = true, ["y.f"] = true },
    narrows = { ["x.f"] = true, ["x.g"] = true, x = true },
  }
  local inner: Scope = { vars = { ["x.f"] = true, z = true }, narrows = { ["x.f"] = true } }
  module().drop({ outer, inner }, module().field_place("x", "f"), write)
  assert(outer.vars["x.f"] == nil and inner.vars["x.f"] == nil)
  assert(outer.narrows ~= nil and inner.narrows ~= nil)
  assert(outer.narrows["x.f"] == nil and inner.narrows["x.f"] == nil)
  assert(outer.narrows["x.g"] and outer.narrows["x"])
  assert(outer.vars["x.g"] and outer.vars["x"] and outer.vars["y.f"] and inner.vars["z"])
  module().drop({ outer, inner }, module().local_place("x"), write)
  assert(outer.vars["x.g"] == nil and outer.vars["x"] and outer.vars["y.f"])
end

--- A scope with the field facts `keys` narrowed, each held as a narrowed view.
local function holding(...: string): Scope
  local scope: Scope = { vars = {}, narrows = {} }
  for _, key in ipairs({ ... }) do
    scope.vars[key] = { is_specialized = "narrow" }
    assert(scope.narrows)[key] = true
  end
  return scope
end

local function test_a_write_drops_every_path_ending_in_the_field_it_names()
  setup()
  local outer = holding("r.n", "q.n", "r.m", "r.nn", "x")
  local inner = holding("c.n", "r.n")
  module().drop_written({ outer, inner }, "n", write)
  assert(outer.vars["r.n"] == nil and outer.vars["q.n"] == nil and inner.vars["c.n"] == nil and
      inner.vars["r.n"] == nil)
  assert(outer.vars["r.m"] and outer.vars["r.nn"] and outer.vars["x"])
  assert(outer.narrows ~= nil and outer.narrows["r.n"] == nil and outer.narrows["r.m"])
  local told = assert(outer.dropped)
  assert(told["r.n"] == write and told["q.n"] == write)
end

local function test_a_call_drops_every_field_path_and_no_local()
  setup()
  local outer = holding("r.n", "r.m", "x")
  local inner = holding("q.a")
  module().drop_paths({ outer, inner }, call)
  assert(outer.vars["r.n"] == nil and outer.vars["r.m"] == nil and inner.vars["q.a"] == nil)
  assert(outer.vars["x"] and assert(outer.narrows)["x"])
  local told = assert(outer.dropped)
  assert(told["r.m"] == call and told["x"] == nil)
end

local function test_what_a_call_has_to_drop_is_the_paths_and_the_locals_narrowed()
  setup()
  local outer = holding("x", "r.n", "y")
  local inner = holding("x", "q.a", "z")
  local paths, names = module().narrowed({ outer, inner })
  assert(paths and table.concat(assert(names), ",") == "x,y,z")
  assert(module().has_paths({ outer, inner }) and not module().has_paths({ holding("x") }))
  local none, nobody = module().narrowed({ holding("r.n") })
  assert(none and nobody == nil)
  local empty, no_names = module().narrowed({ { vars = {} } })
  assert(not empty and no_names == nil)
end

--- A place is told as dropped until it is narrowed again, and a local that
--- a drop widened (its entry in a scope above is a `widen` view) is too.
local function test_a_place_stays_dropped_until_it_is_narrowed_again()
  setup()
  local outer = holding("r.n")
  local scopes = { outer }
  assert(module().dropped_by(scopes, "r.n") == nil)
  module().drop_paths(scopes, call)
  assert(module().dropped_by(scopes, "r.n") == call)
  assert(module().dropped_by(scopes, "r.m") == nil)
  module().renarrowed(scopes, "r.n")
  assert(module().dropped_by(scopes, "r.n") == nil)
  -- A local narrowed in the outer scope, dropped (so the scope above holds
  -- a widened view), is dropped; narrowed there again, it is not.
  local below = holding("x")
  local above: Scope = { vars = { x = { is_specialized = "widen" } } }
  module().note({ below }, "x", call)
  assert(module().dropped_by({ below, above }, "x") == call)
  module().renarrowed({ below, above }, "x")
  assert(module().dropped_by({ below, above }, "x") == nil)
  -- A fact a guard would have given, cut before it was applied, is told
  -- in the innermost scope.
  module().cut({ below, above }, "r.n", write)
  assert(module().dropped_by({ below, above }, "r.n") == write)
  assert(module().dropped_by({ below }, "r.n") == nil)
end

local function test_a_guard_forgets_the_facts_about_what_may_change()
  setup()
  local path = module().field_place("r", "n")
  local name = module().local_place("x")
  local both = assert(module().both(here, module().type_is(here, path, number),
    module().type_is(here, name, number)))
  local types = { ["r.n"] = union(number, nothing), x = union(number, nothing) }
  expect({ "r.n == number", "x == number" }, (facts(both, types)))
  local function droppable(place: Place): boolean return #place.fields > 0 end
  local kept = module().forget(both, droppable)
  expect({ "x == number" }, (facts(kept, types)))
  assert(#module().places(both) == 2 and module().places(both)[1].key == "r.n")
  -- A negation and a disjunction lose the place the same way: what they
  -- leave is what the other side says of another place.
  local negated = module().negate(here, module().type_is(here, path, number))
  assert(module().forget(negated, droppable) == nil)
  assert(module().forget(nil, droppable) == nil)
  local either = module().either(here, module().type_is(here, path, number), module().type_is(here, name, number))
  expect({}, (facts(module().forget(either, droppable), types)))
end

local function test_the_drops_of_a_block_that_leaves_are_put_back()
  setup()
  local outer = holding("r.n", "r.m")
  local scopes = { outer }
  local marked = module().mark(scopes)
  module().drop_written(scopes, "n", write)
  module().drop_paths(scopes, call)
  assert(outer.vars["r.n"] == nil and outer.vars["r.m"] == nil)
  module().undo(scopes, marked)
  assert(outer.vars["r.n"] and outer.vars["r.m"] and assert(outer.narrows)["r.n"])
  local told = assert(outer.dropped)
  assert(told["r.n"] == nil)
  assert(module().mark(scopes) == marked)
  -- What was narrowed again since is left as it is.
  local before = module().mark(scopes)
  module().drop_paths(scopes, call)
  local again = { is_specialized = "narrow" }
  outer.vars["r.n"] = again
  module().undo(scopes, before)
  assert(outer.vars["r.n"] == again and outer.vars["r.m"] ~= nil)
  -- And the drops before the mark stay.
  module().drop_paths(scopes, call)
  module().undo(scopes, module().mark(scopes))
  assert(outer.vars["r.m"] == nil)
end

local function test_a_function_works_on_copies_of_the_facts_outside_it()
  setup()
  local outer = holding("r.n")
  local inner: Scope = { vars = {} }
  local scopes = { outer, inner }
  module().enter_function(scopes)
  assert(outer.vars["r.n"] == nil and inner.vars["r.n"] ~= nil)
  assert(inner.vars["r.n"] ~= outer.vars["r.n"])
  -- What the body drops, it drops from its copies.
  module().drop_paths(scopes, call)
  assert(inner.vars["r.n"] == nil)
  assert(inner.hidden ~= nil and #inner.hidden == 1)
  local hidden = inner.hidden
  module().leave_function({ outer }, hidden)
  assert(outer.vars["r.n"] ~= nil and assert(outer.narrows)["r.n"])
end

local function test_a_type_test_gives_its_type_and_its_negation_the_rest()
  setup()
  local x = module().local_place("x")
  local maybe = union(number, nothing)
  local types = { x = maybe }
  expect({ "x is number" }, (facts(module().type_is(here, x, number), types)))
  expect({ "x is nil" }, (facts(module().negate(here, module().type_is(here, x, number)), types)))
  expect({ "x is nil" }, (facts(module().type_is(here, x, nothing), types)))
  expect({ "x is number" }, (facts(module().negate(here, module().type_is(here, x, nothing)), types)))
end

local function test_a_value_test_gives_its_type_and_its_negation_nothing()
  setup()
  local x = module().local_place("x")
  local types = { x = union(number, string_t) }
  local equals = module().value_is(here, x, number)
  expect({ "x == number" }, (facts(equals, types)))
  expect({ "x == number|string (widened)" }, (facts(module().negate(here, equals), types)))
end

local function test_facts_are_keyed_by_place()
  setup()
  local guard = module().both(here,
    module().type_is(here, module().local_place("x"), number),
    module().type_is(here, module().field_place("r", "a"), nothing))
  expect({ "r.a == nil", "x == number" }, (facts(guard, {
    x = union(number, nothing), ["r.a"] = union(number, nothing),
  })))
end

local function test_both_intersects_what_the_same_place_is_told_twice()
  setup()
  local x = module().local_place("x")
  local guard = module().both(here,
    module().type_is(here, x, union(number, string_t)),
    module().negate(here, module().type_is(here, x, string_t)))
  expect({ "x is number" }, (facts(guard, { x = union(number, string_t, nothing) })))
end

local function test_a_type_and_a_value_fact_together_are_both_value_facts()
  setup()
  local guard = module().both(here,
    module().type_is(here, module().local_place("x"), number),
    module().value_is(here, module().local_place("y"), string_t))
  expect({ "x == number", "y == string" }, (facts(guard, {
    x = union(number, nothing), y = union(string_t, nothing),
  })))
end

local function test_either_keeps_what_both_sides_say_of_a_place()
  setup()
  local x = module().local_place("x")
  local y = module().local_place("y")
  local types = { x = union(number, string_t, nothing), y = union(number, nothing) }
  local same = module().either(here, module().type_is(here, x, number), module().type_is(here, x, string_t))
  expect({ "x is string|number" }, (facts(same, types)))
  local apart = module().either(here, module().type_is(here, x, number), module().type_is(here, y, number))
  expect({}, (facts(apart, types)))
end

local function test_an_or_with_a_side_that_gives_nothing_counts_it_as_truthy()
  setup()
  local x = module().local_place("x")
  local types = { x = union(number, nothing) }
  -- `x or d` is not told by `x` alone: only its falsy side is.
  local guard = module().either(here, module().type_is(here, x, number), nil)
  expect({ "x is nil" }, (facts(guard, types)))
  assert(module().negate(here, nil) == nil)
  assert(module().both(here, nil, nil) == nil)
  expect({}, (facts(module().truthy, types)))
  expect({}, (facts(nil, types)))
  expect({ "x == number" }, (facts(module().both(here, module().type_is(here, x, number), nil), types)))
end

local function test_a_conjunction_with_a_truthy_side_is_told_by_the_other()
  setup()
  local x = module().local_place("x")
  local types = { x = union(number, nothing) }
  local guard = module().both(here, module().type_is(here, x, number), module().truthy)
  expect({ "x is number" }, (facts(guard, types)))
  expect({ "x is nil" }, (facts(module().negate(here, guard), types)))
  -- A disjunction with a truthy side is told by its negation alone.
  expect({ "x is nil" }, (facts(module().either(here, module().type_is(here, x, number), module().truthy), types)))
end

local function test_a_negation_of_a_negation_is_the_guard_itself()
  setup()
  local x = module().local_place("x")
  local types = { x = union(number, nothing) }
  local guard = module().type_is(here, x, number)
  local once = module().negate(here, guard)
  local twice = module().negate(here, once)
  expect({ "x is number" }, (facts(guard, types)))
  expect({ "x is nil" }, (facts(once, types)))
  expect({ "x is number" }, (facts(twice, types)))
  expect({ "x is nil" }, (facts(module().negate(here, twice), types)))
end

local function test_an_or_of_a_type_fact_and_a_value_fact_is_a_value_fact()
  setup()
  local x = module().local_place("x")
  local types = { x = union(number, string_t, nothing) }
  local mixed = module().either(here, module().type_is(here, x, number), module().value_is(here, x, nothing))
  expect({ "x == nil|number" }, (facts(mixed, types)))
  local values = module().either(here, module().value_is(here, x, number), module().value_is(here, x, nothing))
  expect({ "x == nil|number" }, (facts(values, types)))
end

local function test_a_joined_union_test_with_an_absent_side_gives_nothing()
  setup()
  local x = module().local_place("x")
  local types = { x = union(number, nothing) }
  local test = module().type_is(here, x, number)
  -- `either` counts the absent side as truthy; [`any_of`] leaves it absent.
  expect({ "x is nil" }, (facts(module().either(here, test, nil), types)))
  expect({}, (facts(module().any_of(here, test, nil), types)))
  expect({}, (facts(module().any_of(here, nil, test), types)))
end

local function test_the_negation_of_a_conjunction_is_the_disjunction_of_negations()
  setup()
  local x = module().local_place("x")
  local y = module().local_place("y")
  local types = { x = union(number, nothing), y = union(number, nothing) }
  local both = module().both(here, module().type_is(here, x, number), module().type_is(here, y, number))
  expect({}, (facts(module().negate(here, both), types)))
  local either = module().either(here, module().type_is(here, x, nothing), module().type_is(here, y, nothing))
  expect({ "x == number", "y == number" }, (facts(module().negate(here, either), types)))
end

local function test_none_of_negates_each_condition_of_the_branches_before_it()
  setup()
  local x = module().local_place("x")
  local y = module().local_place("y")
  local types = { x = union(number, nothing), y = union(number, nothing) }
  local blocks: {Node} = {
    { kind = "if_block", exp = { kind = "op", guard = module().type_is(here, x, nothing) } },
    { kind = "if_block", exp = { kind = "op", guard = module().type_is(here, y, nothing) } },
    { kind = "if_block" },
  }
  expect({ "x is number" }, (facts(module().none_of(here, blocks, 1), types)))
  expect({ "x == number", "y == number" }, (facts(module().none_of(here, blocks, 2), types)))
  -- An `else` has no condition and adds none: the facts stay type-based.
  expect({ "x is number" }, (facts(module().none_of(here, { blocks[1], blocks[3] }, 2), types)))
  expect({ "x == number", "y == number" }, (facts(module().none_of(here, blocks, 3), types)))
end

local function test_a_local_the_checker_cannot_resolve_is_invalid()
  setup()
  local x = module().local_place("x")
  expect({ "x is invalid" }, (facts(module().type_is(here, x, number), {})))
  expect({ "x == invalid" }, (facts(module().negate(here, module().type_is(here, x, number)), {})))
end

local function test_a_field_the_checker_cannot_resolve_gives_nothing()
  setup()
  local f = module().field_place("r", "a")
  expect({}, (facts(module().type_is(here, f, number), {})))
  expect({}, (facts(module().negate(here, module().type_is(here, f, number)), {})))
end

local function test_a_test_the_type_can_never_pass_is_refused_or_warned()
  setup()
  local x = module().local_place("x")
  local types = { x = string_t }
  local positive, world = facts(module().type_is(here, x, number), types)
  expect({ "x is invalid" }, positive)
  expect({ "x:string:number" }, world.refused)
  assert(#world.warned == 0)
  local negative, other = facts(module().negate(here, module().type_is(here, x, number)), types)
  expect({ "x == invalid" }, negative)
  expect({ "x:string:number" }, other.warned)
  assert(#other.refused == 0)
end

local function test_a_test_the_type_always_passes_is_taken_as_it_stands()
  setup()
  local x = module().local_place("x")
  local held, world = facts(module().type_is(here, x, union(number, string_t)), { x = number })
  expect({ "x is number|string" }, held)
  assert(#world.refused == 0 and #world.warned == 0)
end

local function test_a_type_variable_is_not_narrowed_by_a_negation()
  setup()
  local x = module().local_place("x")
  local variable_t = ty("typevar")
  expect({ "x is number" }, (facts(module().type_is(here, x, number), { x = variable_t })))
  expect({ "x == typevar (widened)" },
    (facts(module().negate(here, module().type_is(here, x, number)), { x = variable_t })))
end

local function test_a_union_of_members_joined_by_any_of_keeps_the_last_pair()
  setup()
  -- `x is string | number | nil` is built as `(x is number) or (x is nil)`
  -- once the first member is lost: the known limit
  -- [`checker/narrowing.tl`] holds a TODO for.
  local x = module().local_place("x")
  local types = { x = union(string_t, number, nothing) }
  local guard = module().any_of(here, module().type_is(here, x, number), module().type_is(here, x, nothing))
  expect({ "x is nil|number" }, (facts(guard, types)))
end

--- The places a case's statements read, declared around them.
local prelude <const> = [[
local record Inner
   n: number | nil
end
local record R
   a: number | nil
   ab: number | nil
   b: string | nil
   c: Inner | nil
end
local q: R = {}
local p: R = {}
local x: number | nil = nil
local y: number | nil = nil
local function touch(_r: R) print(_r) end
local function maybe(): number | nil return nil end
local function die(): never error("die") end
local function f()
]]
local after <const> = "\nend\nprint(f, p, x, y, touch, maybe, die)\n"

local function lines_in(text: string): integer
  local _, count = text:gsub("\n", "\n")
  return count
end

--- `body`, the statements of a function over the places above, checked by
--- the carried compiler: the line (relative to `body`) and the message of
--- each type error, or the raise, as the compiler said.
local function errors_in(source: string, skipped: integer): {string}
  local compiled = setup()
  local env = assert(compiled.new_env({ defaults = {
    feat_lax = "off", gen_compat = "off", gen_target = "5.4",
  } }))
  local ok, raised = pcall(function(): {string}
    local result = compiled.check_string(source, env, "probe.tl", "tl")
    assert(#result.syntax_errors == 0, "does not parse: " .. source)
    local found: {string} = {}
    for _, e in ipairs(result.type_errors) do
      found[#found + 1] = tostring(e.y - skipped) .. ": " .. e.msg
    end
    return found
  end)
  if not ok then
    return { "raised: " .. tostring(raised):gsub("^[^:]*:%d+: ", "") }
  end
  return raised as {string}
end

local function errors_of(body: string): {string}
  return errors_in(prelude .. body .. after, lines_in(prelude))
end

local plus <const> = "cannot use operator '+' for "

local function accepted(body: string)
  local found = errors_of(body)
  assert(#found == 0, "refused, " .. table.concat(found, "; ") .. ", in " .. body)
end

--- Each of `wanted` begins the message of the error at its place in the
--- checker's, and there are no other errors.
local function refused(body: string, ...: string)
  local wanted: {string} = { ... }
  local found = errors_of(body)
  assert(#found == #wanted, "wanted " .. #wanted .. " errors in " .. body .. " but got [" ..
      table.concat(found, "; ") .. "]")
  for i, want in ipairs(wanted) do
    assert(found[i]:sub(1, #want) == want, "wanted [" .. want .. "] but got [" .. found[i] .. "] in " .. body)
  end
end

local function test_a_field_narrows_on_a_test_of_it()
  accepted("if q.a then print(q.a + 1) end")
  accepted("if q.a ~= nil then print(q.a + 1) end")
  accepted("if q.a == nil then print(1) else print(q.a + 1) end")
  accepted("if not q.a then return end\nprint(q.a + 1)")
  accepted("assert(q.a)\nprint(q.a + 1)")
  refused("print(q.a + 1)", "1: " .. plus:sub(1, 28))
end

local function test_a_field_is_dropped_by_an_assignment_to_it_or_to_its_base()
  refused("if q.a then\n  q.a = nil\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
  refused("if q.a then\n  q = p\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
  accepted("if q.a then\n  q.b = \"x\"\n  print(q.a + 1)\nend")
  accepted("if q.a then\n  p = q\n  print(q.a + 1)\nend")
end

local function test_a_local_assigned_is_widened_back()
  refused("if x then\n  x = maybe()\n  print(x + 1)\nend", "3: " .. plus:sub(1, 28))
  refused("if x then\n  x = maybe()\nend\nprint(x + 1)", "4: " .. plus:sub(1, 28))
  refused("if x then\n  while maybe() do\n    print(x + 1)\n    x = nil\n  end\nend", "3: " .. plus:sub(1, 28))
  refused("if x then\n  local function reset() x = nil end\n  reset()\n  print(x + 1)\nend", "4: " .. plus:sub(1, 28))
  accepted("if x then\n  local x: number = 1\n  print(x + 1)\nend")
end

local function test_a_branch_that_ends_narrows_what_follows_by_the_negation_of_its_conditions()
  accepted("if x == nil then return elseif y == nil then return end\nprint(x + 1, y + 1)")
  accepted("if x == nil then die() end\nprint(x + 1)")
  accepted("if q.a == nil then return end\nprint(q.a + 1)")
  accepted("if x == nil then print(1) elseif y == nil then print(x + 1) else print(x + y) end")
  refused("if x == nil then print(1) end\nprint(x + 1)", "2: " .. plus:sub(1, 28))
  refused("if x == nil then if y then return end end\nprint(x + 1)", "2: " .. plus:sub(1, 28))
end

local function test_not_and_and_or_combine_guards()
  accepted("if x and y then print(x + 1, y + 1) end")
  accepted("if not (x == nil or y == nil) then print(x + 1, y + 1) end")
  accepted("if not not x then print(x + 1) end")
  accepted("print(x and x + 1)")
  accepted("local n: number = x or 0\nprint(n + 1)")
  refused("if x or y then print(x + 1) end", "1: " .. plus:sub(1, 28))
end

local function test_a_type_test_and_is_narrow_a_local()
  accepted("local u: string | number = x or \"s\"\nif type(u) == \"number\" then print(u + 1) else print(#u) end")
  accepted("local u: string | number | nil = maybe()\nif u is number then print(u + 1) end")
  accepted("local u: string | number = x or \"s\"\nif u == 1 then print(u + 1) end")
end

local function test_assert_narrows_what_it_is_given()
  accepted("assert(x)\nprint(x + 1)")
  accepted("assert(x, \"x is nil\")\nprint(x + 1)")
  accepted("assert(x ~= nil)\nprint(x + 1)")
end

--- The limits [`checker/narrowing.tl`] holds TODOs for. Each is pinned as
--- it is, so the change that lifts one flips its case.
local function test_a_field_under_type_and_the_left_of_and_is_not_narrowed_yet()
  refused("if type(q.a) == \"number\" then print(q.a + 1) end", "1: " .. plus:sub(1, 28))
  refused("print(q.a and q.a + 1)", "1: " .. plus:sub(1, 28))
  refused("if q.a is number then print(1) end", "1: can only use 'is' on variables")
end

local function test_a_path_of_two_fields_is_not_a_place_yet()
  refused("assert(q.c.n)\nprint(q.c.n + 1)",
    "1: cannot index key 'n' in type Inn", "2: cannot index key 'n' in type Inn")
  refused("if q.c and q.c.n then print(q.c.n + 1) end",
    "1: cannot index key 'n' in type Inn", "1: cannot index key 'n' in type Inn")
end

local function test_an_assignment_to_a_field_drops_a_field_whose_name_it_begins()
  refused("if q.ab then\n  q.a = 1\n  print(q.ab + 1)\nend", "3: " .. plus:sub(1, 28))
end

local function test_a_union_test_of_three_members_loses_the_first()
  refused("local u: string | number | boolean | nil = maybe()\nif u is string | number | nil then\n  print(u .. \"\")\nend",
    "3: cannot use operator '..' for typ")
end

local function test_dropping_a_narrowed_field_leaves_the_program_checkable()
  -- The fact was once listed as narrowed after it was dropped, and the next
  -- widening of every narrowed name raised "no q.a in scope".
  refused("assert(q.a)\nq.a = 1\nlocal g = function() end\ng = function() print(g) end")
  refused("assert(q.a)\nq.a = 1\nprint(q.a + 1)", "3: " .. plus:sub(1, 28))
end

--- A narrowed field is dropped where the value can change.

--- Whole programs, for the cases the places above do not serve.
local function accepted_source(source: string)
  local found = errors_in(source, 0)
  assert(#found == 0, "refused, " .. table.concat(found, "; ") .. ", in " .. source)
end

local function refused_source(source: string, ...: string)
  local wanted: {string} = { ... }
  local found = errors_in(source, 0)
  assert(#found == #wanted, "wanted " .. #wanted .. " errors in " .. source .. " but got [" ..
      table.concat(found, "; ") .. "]")
  for i, want in ipairs(wanted) do
    assert(found[i]:sub(1, #want) == want, "wanted [" .. want .. "] but got [" .. found[i] .. "] in " .. source)
  end
end

local function test_a_write_through_another_reference_drops_the_field()
  refused("if q.a then\n  p.a = nil\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
  refused("if q.a then\n  p[\"a\"] = nil\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
  -- The reference may be a longer path.
  refused("local i: Inner = {}\nif i.n then\n  if p.c then\n    p.c.n = 1\n    print(i.n + 1)\n  end\nend", "5: " .. plus:sub(1, 28))
  -- Another field of that table, or a field of another name, is not it.
  accepted("if q.a then\n  p.b = \"x\"\n  print(q.a + 1)\nend")
  accepted("if q.a then\n  p.ab = 1\n  print(q.a + 1)\nend")
end

local function test_a_call_drops_every_narrowed_field()
  refused("if q.a then\n  touch(q)\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
  refused("if q.a then\n  touch(p)\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
  refused("if q.b then\n  touch(p)\n  print(#q.b)\nend", "3: cannot use operator '#'")
  accepted("if q.a then\n  print(q.a + 1)\nend")
end

local tostring_head <const> = "local record T\n  metamethod __tostring: function(T): string\nend\n" ..
  "local record H\n  n: number | nil\nend\nlocal t: T = setmetatable({} as T, {})\nlocal h: H = {}\n"

local pairs_head <const> = "local record T\n  x: number\n  metamethod __pairs: function<K, V>(T): function(): (K, V)\nend\n" ..
  "local record H\n  n: number | nil\nend\nlocal t: T = setmetatable({} as T, {})\nlocal h: H = {}\n"

local function test_a_call_that_runs_no_code_of_the_programs_drops_nothing()
  -- `assert` and `type`, a function that never returns, and the standard
  -- library's functions given what they cannot hand to a metamethod.
  accepted("if q.a then\n  assert(x)\n  print(q.a + 1)\nend")
  accepted("if q.a then\n  if type(x) == \"number\" then print(1) end\n  print(q.a + 1)\nend")
  accepted("if q.a then\n  if y then die() end\n  print(q.a + 1)\nend")
  accepted("if q.a then\n  local n = x or die()\n  print(q.a + 1, n)\nend")
  accepted("if q.a then\n  local s = tostring(x) .. string.rep(\"x\", 2) .. (\"y\"):upper()\n  print(q.a + #s)\nend")
  accepted("if q.a then\n  local t: {string} = {}\n  table.insert(t, \"x\")\n  print(q.a + #table.concat(t, \",\"))\nend")
  accepted("if q.a then\n  local total = 0\n  for _, v in ipairs({ 1, 2 }) do total = total + v end\n  print(q.a + total)\nend")
  -- A record handed to one is examined by a metamethod only if its type declares one.
  accepted("if q.a then\n  print(q)\n  print(q.a + 1)\nend")
  accepted("if q.a then\n  tostring(q)\n  print(q.a + 1)\nend")
  refused_source(tostring_head .. "if h.n then\n  print(t)\n  print(h.n + 1)\nend", "11: " .. plus:sub(1, 28))
  refused_source(tostring_head .. "if h.n then\n  local s = tostring(t)\n  print(h.n + #s)\nend", "11: " .. plus:sub(1, 28))
  -- A function may be called.
  refused("if q.a then\n  table.sort({ 3, 1 }, function(l: number, r: number): boolean return l < r end)\n  print(q.a + 1)\nend",
    "3: " .. plus:sub(1, 28))
  -- Nor one among a union's members.
  refused("local type Cmp = function(number, number): boolean\nlocal function g(cmp: Cmp | nil)\n" ..
      "  if q.a then\n    print(cmp)\n    print(q.a + 1)\n  end\nend\nprint(g)", "5: " .. plus:sub(1, 28))
  refused("if q.a then\n  pcall(touch, q)\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
end

--- The limit of "a value dispatches only through metamethods its type
--- declares" (doc/design.md): a metatable attached at run time runs code
--- the checker does not see. Each program is accepted today and wrong at
--- run time, pinned as it is so that the change that lifts the limit
--- (doc/roadmap.md, `setmetatable` attaches only what a record declares)
--- flips its case.
local function test_a_metatable_attached_at_run_time_is_not_seen_yet()
  local drop <const> = "function(): integer p.a = nil return 0 end"
  accepted("local m: {string:integer} = setmetatable({}, {__index = " .. drop .. "})\n" ..
      "if q.a then\n  local v = m.foo\n  print(q.a + 1, v)\nend")
  accepted("local m: {string:integer} = setmetatable({}, {__newindex = function() p.a = nil end})\n" ..
      "if q.a then\n  m.foo = 1\n  print(q.a + 1)\nend")
  accepted("local arr: {integer} = setmetatable({}, {__len = " .. drop .. "})\n" ..
      "if q.a then\n  local n = #arr\n  print(q.a + n)\nend")
  accepted("local r: R = setmetatable({}, {__eq = function(): boolean p.a = nil return true end})\n" ..
      "if q.a then\n  local same = r == p\n  print(q.a + (same and 1 or 0))\nend")
end

--- Code the checker sees: an operand of type `any` may carry any
--- metamethod, and a write at a key that is not a literal may be to any
--- field.
local function test_any_and_a_computed_key_may_run_or_write_anything()
  refused("local a = x as any\nif q.a then\n  local same = a == p\n  print(q.a + (same and 1 or 0))\nend", "4: " .. plus:sub(1, 28))
  refused("local m = (q as {string:any})\nlocal k = \"a\"\nif q.a then\n  m[k] = nil\n  print(q.a + 1)\nend", "5: " .. plus:sub(1, 28))
  refused("local k: string = tostring(x)\nif q.a then\n  (p as {string:any})[k] = nil\n  print(q.a + 1)\nend", "4: " .. plus:sub(1, 28))
  -- A number key is an index of an array.
  accepted("local arr: {integer} = {}\nlocal i = 1\nif q.a then\n  arr[i] = 2\n  print(q.a + 1)\nend")
end

--- `local x: T, y = 1, 2` reads `y` as a second type: it is refused for
--- having more types than variables, not raised on.
local function test_more_types_than_variables_is_refused_not_raised()
  refused_source("local x: integer | nil, y = 1, 2\nprint(x, y)\n",
    "1: number of types exceeds number of variables", "2: unknown variable: y")
end

--- Only a declared `__eq` runs on a comparison of two records.
local function test_a_comparison_of_records_runs_code_only_if_one_declares_eq()
  local head = "local record Node\n  v: integer | nil\nend\nlocal a: Node = {}\nlocal b: Node = {}\n" ..
    "local kids: {Node} = {}\nlocal target: Node = {}\n"
  accepted_source(head .. "if a.v then\n  if a == b then print(1) end\n  print(a.v + 1)\nend\n")
  accepted_source(head .. "if a.v then\n  for _, k in ipairs(kids) do\n    if k == target then print(1) end\n  end\n" ..
      "  print(a.v + 1)\nend\n")
  local eq = "local record Node\n  v: integer | nil\n  metamethod __eq: function(Node, Node): boolean\nend\n" ..
    "local a: Node = {}\nlocal b: Node = {}\n"
  refused_source(eq .. "if a.v then\n  if a == b then print(1) end\n  print(a.v + 1)\nend\n",
    "9: cannot use operator '+'")
  -- An operand of a type that declares none beside one that does.
  refused_source(eq .. "local c: Node | nil = b\nif a.v then\n  if c == b then print(1) end\n  print(a.v + 1)\nend\n",
    "10: cannot use operator '+'")
end

local function test_an_expanded_condition_that_calls_drops()
  local head = "local interface Animal\n  kind: string\nend\n" ..
    "local record H\n  n: number | nil\nend\nlocal h: H = {}\n" ..
    "local function is_cat(a: Animal): boolean\n  h.n = nil\n  return a.kind == \"cat\"\nend\n" ..
    "local record Cat is Animal where is_cat(self)\nend\nlocal a: Animal = { kind = \"dog\" }\n"
  refused_source(head .. "if h.n then\n  if a is Cat then print(1) end\n  print(h.n + 1)\nend\n",
    "17: cannot use operator '+'")
end

local function test_a_call_drops_a_local_a_function_literal_assigns_and_no_other()
  local z = "local z: number | nil = maybe()\n"
  refused(z .. "local function reset() z = nil end\nif z then\n  touch(q)\n  print(z + 1, reset)\nend", "5: " .. plus:sub(1, 28))
  -- Not a local no literal assigns, nor one only the function itself assigns.
  accepted(z .. "if z then\n  touch(q)\n  print(z + 1)\nend")
  accepted(z .. "if z then\n  touch(q)\n  print(z + 1)\n  z = nil\nend")
  -- A literal assigns its own local of the name, not this one.
  accepted(z .. "local function own()\n  local z: number | nil = nil\n  z = 1\n  print(z)\nend\n" ..
      "if z then\n  touch(q)\n  print(z + 1, own)\nend")
  -- A literal made after the call is one that may run before it comes round again.
  refused(z .. "local later: function()\nif z then\n  touch(q)\n  print(z + 1)\nend\nlater = function() z = nil end\nprint(later)",
    "5: " .. plus:sub(1, 28))
  -- A parameter is one local too.
  refused("local function g(n: number | nil)\n  local function reset() n = nil end\n  if n then\n    touch(q)\n    print(n + 1, reset)\n  end\nend\nprint(g)",
    "5: " .. plus:sub(1, 28))
end

local function test_a_read_before_a_call_in_the_same_expression_keeps_its_fact()
  accepted("if q.a then\n  print(q.a + 1, maybe())\nend")
  accepted("if q.a then\n  print(q.a + (maybe() or 0))\nend")
  refused("if q.a then\n  print(maybe(), q.a + 1)\nend", "2: " .. plus:sub(1, 28))
  refused("if q.a then\n  print((maybe() or 0) + q.a)\nend", "2: " .. plus:sub(1, 28))
  -- The arguments of a call are read before it runs, however it is written.
  accepted("if q.a then\n  touch(q)\nend\nif q.a then\n  local n = q.a + 1\n  touch(q)\n  print(n)\nend")
end

local function test_the_test_of_an_operand_holds_past_the_calls_of_a_later_one_only_if_they_cannot_change_it()
  local z = "local z: number | nil = maybe()\nlocal function reset() z = nil end\nprint(reset)\n"
  refused(z .. "if z and maybe() then print(z + 1) end", "4: " .. plus:sub(1, 28))
  accepted(z .. "if z and #\"abc\" > 1 then print(z + 1) end")
  accepted("if y and maybe() then print(y + 1) end")
  refused("if q.a == nil then\n  return\nelseif maybe() then\n  return\nend\nprint(q.a + 1)", "6: " .. plus:sub(1, 28))
  accepted("if q.a == nil then\n  return\nelseif x then\n  return\nend\nprint(q.a + 1)")
  refused("assert(q.a, tostring(maybe()))\nprint(q.a + 1)", "2: " .. plus:sub(1, 28))
  accepted("assert(q.a, \"no a: \" .. tostring(q.b))\nprint(q.a + 1)")
end

--- A condition the checker expands (an `is` of a record with a `where`
--- clause is a macro expression) still counts as a test that ran no code.
local function test_an_expanded_condition_runs_no_code_for_the_conditions_after_it()
  local head = "local interface Animal\n  kind: string\nend\n" ..
    "local record Cat is Animal where self.kind == \"cat\"\nend\n" ..
    "local record H\n  n: number | nil\nend\nlocal h: H = {}\nlocal a: Animal = { kind = \"dog\" }\n"
  accepted_source(head .. "if h.n == nil then\n  return\nelseif a is Cat then\n  return\nend\nprint(h.n + 1)\n")
  refused_source(head .. "local function maybe(): boolean return false end\n" ..
      "if h.n == nil then\n  return\nelseif a is Cat or maybe() then\n  return\nend\nprint(h.n + 1)\n",
    "17: cannot use operator '+'")
end

--- A loop is checked once with the facts from before it, and a read of one
--- the loop itself drops later in the body is refused at the read, for the
--- pass that comes round again.
local looped <const> = ": 'q.a' was narrowed before this loop"

local function test_a_read_of_a_fact_the_loop_drops_later_is_refused_at_the_read()
  refused("if q.a then\n  while y do\n    print(q.a + 1)\n    touch(q)\n  end\nend", "3" .. looped)
  refused("if q.a then\n  for _ = 1, 2 do\n    print(q.a + 1)\n    touch(q)\n  end\nend", "3" .. looped)
  refused("if q.a then\n  for _ = 1, 2 do\n    local n = q.a + 1\n    p.a = nil\n    print(n)\n  end\nend", "3" .. looped)
  refused("if q.a then\n  while y do\n    print(q.a + 1)\n    q.a = nil\n  end\nend", "3" .. looped)
  refused("if q.a then\n  repeat\n    print(q.a + 1)\n    touch(q)\n  until y\nend", "3" .. looped)
  refused("if q.a then\n  for _, v in ipairs({ 1 }) do\n    print(q.a + v)\n    touch(q)\n  end\nend", "3" .. looped)
  -- A drop in a loop inside the loop is one of the outer loop's.
  refused("if q.a then\n  while y do\n    print(q.a + 1)\n    for _ = 1, 2 do touch(q) end\n  end\nend", "3" .. looped)
  -- Each read before the drop is refused, those after it are refused for the drop itself.
  refused("if q.a then\n  while y do\n    print(q.a + 1)\n    print(q.a + 2)\n    touch(q)\n    print(q.a + 3)\n  end\nend",
    "3" .. looped, "4" .. looped, "6: " .. plus:sub(1, 28))
  -- The condition of a loop is its body: what it drops is dropped for the body.
  refused("if q.a then\n  while maybe() do\n    print(q.a + 1)\n  end\nend", "3: " .. plus:sub(1, 28))
  refused("if q.a then\n  repeat\n    touch(q)\n    print(q.a + 1)\n  until y\nend", "4: " .. plus:sub(1, 28))
  refused("if q.a then\n  repeat\n    x = nil\n  until q.a + 1 > 2 or touch(q)\nend", "4" .. looped)
end

local function test_a_branch_that_may_break_or_go_out_does_not_leave()
  -- It ends in `return`, but a path through it breaks out first.
  refused("if q.a then\n  for _ = 1, 3 do\n    print(q.a + 1)\n    while y do\n      if x then\n        touch(q)\n" ..
      "        if y then break end\n        return\n      end\n    end\n  end\nend", "3" .. looped)
  refused("if q.a then\n  for i = 1, 3 do\n    if i == 2 then\n      touch(q)\n      if y then break end\n" ..
      "      return\n    end\n  end\n  print(q.a + 1)\nend", "9: " .. plus:sub(1, 28))
  refused("if q.a then\n  repeat\n    if y then\n      touch(q)\n      if y then break end\n      return\n" ..
      "    end\n  until true\n  print(q.a + 1)\nend", "9: " .. plus:sub(1, 28))
  refused("if q.a then\n  if y then\n    touch(q)\n    if x then goto out end\n    return\n  end\n  ::out::\n" ..
      "  print(q.a + 1)\nend", "8: " .. plus:sub(1, 28))
  -- A `break` of a loop inside the branch stays inside it.
  accepted("if q.a then\n  for i = 1, 3 do\n    if i == 2 then\n      touch(q)\n      for _ = 1, 2 do\n" ..
      "        if y then break end\n      end\n      return\n    end\n  end\n  print(q.a + 1)\nend")
  accepted("if q.a then\n  if y then\n    touch(q)\n    return\n  end\n  print(q.a + 1)\nend")
end

local function test_a_read_in_a_branch_that_leaves_is_not_one_of_the_next_pass()
  accepted("if q.a then\n  for _ = 1, 2 do\n    if y then\n      print(q.a + 1)\n      return\n    end\n    touch(q)\n  end\nend")
  refused("if q.a then\n  for _ = 1, 2 do\n    if y then\n      print(q.a + 1)\n    end\n    touch(q)\n  end\nend", "4" .. looped)
end

local function test_every_loop_around_a_read_refuses_it()
  refused("if q.a then\n  for _ = 1, 3 do\n    for _ = 1, 2 do print(q.a + 1) end\n    touch(q)\n  end\nend", "3" .. looped)
  refused("local k = 0\nif q.a then\n  while q.a + k < 10 do\n    k = k + 1\n    touch(q)\n  end\nend", "3" .. looped)
end

local function test_a_loop_that_drops_nothing_before_a_read_keeps_the_fact()
  accepted("if q.a then\n  for _ = 1, 2 do\n    local n = q.a + 1\n    x = n\n  end\nend")
  -- A function literal in the body runs at no pass of it.
  accepted("if q.a then\n  for _ = 1, 2 do\n    local n = q.a + 1\n    local g = function() touch(q) end\n    x = n\n  end\nend")
  -- A drop in a branch that leaves is not one of the next pass.
  accepted("if q.a then\n  for _ = 1, 2 do\n    print(q.a + 1)\n    if y then\n      touch(q)\n      return\n    end\n  end\nend")
  accepted("if q.a then\n  while y do\n    print(q.a + 1)\n    if x then\n      touch(q)\n      die()\n    end\n  end\nend")
  -- A fact the loop narrows itself is its own.
  accepted("for _ = 1, 2 do\n  if q.a then\n    print(q.a + 1)\n    touch(q)\n  end\nend")
  -- A different field, or a write to another name.
  accepted("if q.a then\n  for _ = 1, 2 do\n    print(q.a + 1)\n    p.b = \"x\"\n  end\nend")
end

local function test_after_a_loop_what_it_dropped_stays_dropped()
  refused("if q.a then\n  for _ = 1, 2 do\n    touch(q)\n  end\n  print(q.a + 1)\nend", "5: " .. plus:sub(1, 28))
  refused("if q.a then\n  while y do\n    p.a = nil\n  end\n  print(q.a + 1)\nend", "5: " .. plus:sub(1, 28))
  accepted("if q.a then\n  for _ = 1, 2 do\n    x = 1\n  end\n  print(q.a + 1)\nend")
end

local function test_a_local_assigned_in_a_loop_in_a_branch_is_widened_at_its_head()
  -- The assignment is in the `else` of a branch, which has no condition.
  accepted("local real: number | nil = nil\nfor _ = 1, 2 do\n  if y then\n    print(1)\n  else\n    if real ~= nil then print(real + 1) end\n    real = x\n  end\nend")
end

local function test_pairs_ipairs_gmatch_and_next_run_none_of_the_programs_code()
  accepted("if q.a then\n  for _, v in ipairs({ 1 }) do print(q.a + v) end\n  print(q.a + 1)\nend")
  accepted("local t: {string:number} = {}\nif q.a then\n  for _, v in pairs(t) do print(q.a + v) end\n  print(q.a + 1)\nend")
  accepted("if q.a then\n  for w in (\"a b\"):gmatch(\"%a+\") do print(q.a + #w) end\n  print(q.a + 1)\nend")
  accepted("local t: {string:number} = {}\nif q.a then\n  for _ in next, t do print(q.a + 1) end\n  print(q.a + 1)\nend")
  -- An iterator function is code, run before every pass.
  refused("if q.a then\n  for v in maybe do\n    print(q.a + (v or 0))\n  end\nend", "3: " .. plus:sub(1, 28))
  refused("if q.a then\n  for v in maybe do\n    print(v)\n  end\n  print(q.a + 1)\nend", "5: " .. plus:sub(1, 28))
  -- `pairs` of a record with a `__pairs` it declares runs it.
  refused_source(pairs_head .. "if h.n then\n  for _ in pairs(t) do print(1) end\n  print(h.n + 1)\nend", "12: " .. plus:sub(1, 28))
end

local function test_a_branch_that_leaves_drops_nothing_for_the_code_after_it()
  accepted("if q.a then\n  if y then\n    touch(q)\n    return\n  end\n  print(q.a + 1)\nend")
  accepted("if q.a then\n  if y then\n    touch(q)\n    die()\n  end\n  print(q.a + 1)\nend")
  -- A branch that goes on, or leaves a loop for the code after it, does.
  refused("if q.a then\n  if y then\n    touch(q)\n  end\n  print(q.a + 1)\nend", "5: " .. plus:sub(1, 28))
  refused("if q.a then\n  while y do\n    if x then\n      touch(q)\n      break\n    end\n  end\n  print(q.a + 1)\nend",
    "8: " .. plus:sub(1, 28))
  -- And the condition of the branch ran either way.
  refused("if q.a then\n  if maybe() then\n    return\n  end\n  print(q.a + 1)\nend", "5: " .. plus:sub(1, 28))
end

local function test_a_label_drops_the_fields_a_goto_below_it_may_have_changed()
  refused("if q.a then\n  ::top::\n  print(q.a + 1)\n  if y then goto top end\nend", "3: " .. plus:sub(1, 28))
  accepted("if x then\n  ::top::\n  print(1)\nend")
  -- A label no goto comes back to is not a place code can arrive from.
  accepted("if q.a then\n  ::top::\n  print(q.a + 1)\nend")
  accepted("if q.a then\n  if y then goto skip end\n  print(q.a + 1)\n  ::skip::\n  print(q.a + 2)\nend")
  -- A trailing `::continue::` drops nothing the loop read before it.
  accepted("if q.a then\n  for _ = 1, 2 do\n    print(q.a + 1)\n    if y then goto continue end\n    ::continue::\n  end\nend")
  -- And a goto that does come back to it is one of the loop.
  refused("if q.a then\n  for _ = 1, 2 do\n    print(q.a + 1)\n    ::again::\n    if y then goto again end\n  end\nend",
    "3" .. looped)
end

local function test_a_function_literal_drops_only_in_its_own_body()
  accepted("if q.a then\n  local g = function() touch(q) end\n  print(q.a + 1, g)\nend")
  refused("if q.a then\n  local g = function()\n    touch(q)\n    print(q.a + 1)\n  end\n  g()\nend", "4: " .. plus:sub(1, 28))
  accepted("if q.a then\n  local function g() p.a = nil end\n  print(q.a + 1, g)\nend")
end

local function test_a_metamethod_runs_code_an_operator_on_a_number_does_not()
  local head = "local record V\n  x: number\n  metamethod __add: function(V, V): V\n" ..
    "  metamethod __index: function(V, string): number\nend\n" ..
    "local record H\n  n: number | nil\nend\n" ..
    "local record E\n  x: number\n  metamethod __eq: function(E, E): boolean\nend\n" ..
    "local v: V = setmetatable({ x = 1 } as V, {})\nlocal w: V = v\nlocal h: H = {}\n" ..
    "local e: E = setmetatable({ x = 1 } as E, {})\nlocal f: E = e\n"
  local plus_at = "cannot use operator '+'"
  -- An operator the record declares, an index its `__index` serves, and a
  -- comparison of two values that may carry `__eq`.
  refused_source(head .. "if h.n then\n  local z = v + w\n  print(h.n + z.x)\nend", "20: " .. plus_at)
  refused_source(head .. "if h.n then\n  local z = v.other\n  print(h.n + z)\nend", "20: " .. plus_at)
  refused_source(head .. "if h.n then\n  local same = e == f\n  print(h.n + (same and 1 or 0))\nend", "20: " .. plus_at)
  -- A field the record declares, a number, a string and an array are not,
  -- nor is a comparison of records that declare no `__eq`.
  accepted_source(head .. "if h.n then\n  local same = v == w\n  print(h.n + (same and 1 or 0))\nend")
  accepted_source(head .. "if h.n then\n  local z = v.x\n  print(h.n + z)\nend")
  accepted_source(head .. "if h.n then\n  local z = 2 * 3 + #\"abc\"\n  local a: {number} = { 1 }\n" ..
      "  local same = a == a and \"s\" == \"t\" and z .. \"\" == \"6\"\n  print(h.n + z + #a + (same and 1 or 0))\nend")
  accepted_source(head .. "if h.n then\n  local nothing = v == nil\n  print(h.n + (nothing and 1 or 0))\nend")
end
