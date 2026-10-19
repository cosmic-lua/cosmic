--- Places and guards, [`checker/narrowing.tl`]: what a test tells of a
--- local or a field of one, and what an assignment makes of it. The
--- first half runs the module, compiled here by the compiler the tree
--- carries, against a stand-in for the checker's types. The second half
--- gives the carried checker programs and pins which it accepts: it
--- narrows a local wherever a guard says so, and a field or a global
--- nowhere, and the limits it keeps for now are pinned as limits.
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
  places: function(Guard | nil): {Place}
  forget: function(Guard | nil, function(Place): boolean): Guard | nil
  type_is: function(any, Place, Type): Guard
  value_is: function(any, Place, Type): Guard
  negate: function(any, Guard | nil): Guard | nil
  both: function(any, Guard | nil, Guard | nil): Guard | nil
  either: function(any, Guard | nil, Guard | nil): Guard
  any_of: function(any, Guard | nil, Guard | nil): Guard
  none_of: function(any, {Node}, integer): Guard | nil
  evaluate: function(Host, Guard | nil): {string:Guard}
end

local built = { value = nil as compiler | nil }
local narrowing = { value = nil as Narrowing | nil }

--- The carried compiler, and [`checker/narrowing.tl`] compiled by it and
--- loaded.
local function setup(): compiler, Narrowing
  local value = built.value
  local narrowing_value = narrowing.value
  if value ~= nil and narrowing_value ~= nil then
    return value, narrowing_value
  end
  local compiled = assert(teal.load(true))
  local env = assert(compiled.new_env({ defaults = teal.defaults() }))
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
  built.value, narrowing.value = compiled, loaded as Narrowing
  return built.value, narrowing.value
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
  -- `x or d` held is told nothing of `x`: `x` was truthy, or `x` was nil and
  -- `d` held. Its falsy side is told: `x` was nil.
  local guard = module().either(here, module().type_is(here, x, number), nil)
  expect({}, (facts(guard, types)))
  expect({ "x is nil" }, (facts(module().negate(here, guard), types)))
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
  local either = module().either(here, module().type_is(here, x, number), module().truthy)
  expect({}, (facts(either, types)))
  expect({ "x is nil" }, (facts(module().negate(here, either), types)))
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
  expect({}, (facts(module().either(here, test, nil), types)))
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
local function touch(_r: R) print(_r) end
local function maybe(): number | nil return nil end
local function die(): never error("die") end
local function f(q: R, p: R, x: number | nil, y: number | nil)
]]
local after <const> = "\nprint(p, x, y)\nend\nprint(f, touch, maybe, die)\n"

local function lines_in(text: string): integer
  local _, count = text:gsub("\n", "\n")
  return count
end

--- `body`, the statements of a function over the places above, checked by
--- the carried compiler: the line (relative to `body`) and the message of
--- each type error, or the raise, as the compiler said.
local function errors_in(source: string, skipped: integer): {string}
  local compiled = setup()
  local env = assert(compiled.new_env({ defaults = teal.defaults() }))
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

--- The start of the refusal of a function that assigns the local `name`.
local function captured(name: string): string
  return "'" .. name .. "' is a local of the code around this function"
end

--- The type errors of `source`.
local function errors_of_source(source: string): {compiler.Error}
  local compiled = setup()
  local env = assert(compiled.new_env({ defaults = teal.defaults() }))
  return compiled.check_string(source, env, "probe.tl", "tl").type_errors
end

--- The notes of the errors in `source`, in order: `also` of each, or "-".
local function notes_in(source: string): {string}
  local notes: {string} = {}
  for _, e in ipairs(errors_of_source(source)) do
    notes[#notes + 1] = e.also or "-"
  end
  return notes
end

--- A whole program that relies on the narrowing of a field or a global is
--- refused at each use, and each refusal carries the note that a test of a
--- field or a global narrowed nothing.
local function unnarrowed_source(source: string)
  local notes = notes_in(source)
  assert(#notes > 0, "accepted, though only a local is narrowed, in " .. source)
  for _, note in ipairs(notes) do
    assert(note == "narrowing_not_local", note .. " is not narrowing_not_local, in " .. source)
  end
end

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

local function unnarrowed(body: string)
  unnarrowed_source(prelude .. body .. after)
end

--- What narrowing is for, each accepted: the idioms a change to the checker
--- must keep taking.
local function test_the_idioms_of_narrowing_are_accepted()
  accepted("local v: number | nil = 1\nprint(v + 1)")
  accepted("if x then print(x + 1) end")
  accepted("if x == nil then print(0) else print(x + 1) end")
  accepted("if not x then print(0) else print(x + 1) end")
  accepted("if x == nil then return end\nprint(x + 1)")
  accepted("assert(x)\nprint(x + 1)")
  accepted("local n: number = x or 0\nprint(n + 1)")
  accepted("print(x and x + 1)")
  accepted("if x and y then print(x + y) end")
  accepted("if x == nil then print(1) elseif y == nil then print(x + 1) else print(x + y) end")
  accepted("if x == nil then return elseif y == nil then return end\nprint(x + y)")
  unnarrowed("if q.a then\n  q.ab = 1\n  print(q.a + 1)\nend")
  unnarrowed("if q.a then\n  print(1)\n  print(q.a + 1)\nend")
  accepted("local function own() local z: number | nil = nil z = 1 print(z) end\nif x then\n  own()\n  print(x + 1)\nend")
  accepted("local function g(u: string | number)\n  if type(u) == \"number\" then print(u + 1) else print(#u) end\nend\nprint(g)")
  accepted("local function g(u: string | number | nil)\n  if u is number then print(u + 1) end\nend\nprint(g)")
  accepted("local i = 0\nwhile x and i < 3 do\n  i = i + 1\n  print(x + i)\nend")
  accepted("local i = 0\nrepeat\n  i = i + 1\n  if i > 1 then break end\nuntil i >= 3\nprint(i)")
  accepted("for i = 1, 3 do\n  if x then print(x + i) end\nend")
  accepted("local opts: {number | nil} = { 1, 2 }\nfor _, v in ipairs(opts) do\n  if v then print(v + 1) end\nend")
  accepted("for i = 1, 3 do\n  if i == 2 then goto next end\n  print(i)\n  ::next::\nend")
end

--- Only a local is narrowed. A test of a field narrows nothing: a program
--- that uses the field after it is refused at each use, with the code
--- the note `narrowing_not_local`. The copy of the field in a local, tested instead,
--- is narrowed.
local function test_a_test_of_a_field_narrows_nothing()
  unnarrowed("if q.a then print(q.a + 1) end")
  unnarrowed("if q.a ~= nil then print(q.a + 1) end")
  unnarrowed("if q.a == nil then print(1) else print(q.a + 1) end")
  unnarrowed("if not q.a then return end\nprint(q.a + 1)")
  unnarrowed("assert(q.a)\nprint(q.a + 1)")
  refused("print(q.a + 1)", "1: " .. plus:sub(1, 28))
  accepted("local a = q.a\nif a then print(a + 1) end")
  accepted("local a = q.a\nif a ~= nil then print(a + 1) end")
  accepted("local a = q.a\nif a == nil then print(1) else print(a + 1) end")
  accepted("local a = q.a\nif not a then return end\nprint(a + 1)")
  accepted("local a = q.a\nassert(a)\nprint(a + 1)")
end

--- A test in a loop or an `elseif`, and a `type` test, narrow a field no more
--- than an `if` does.
local function test_no_form_of_test_narrows_a_field()
  unnarrowed("while q.a do\n  print(q.a + 1)\n  break\nend")
  unnarrowed("repeat\n  if q.a then print(q.a + 1) end\nuntil true")
  unnarrowed("if x == nil then print(1) elseif q.a then print(q.a + 1) end")
  unnarrowed("if x == nil then print(1) elseif q.a == nil then print(2) else print(q.a + 1) end")
  unnarrowed("print(q.a ~= nil and q.a + 1)")
  unnarrowed("local n = q.a or 0\nif q.a then print(q.a + n) end")
  accepted("local a = q.a\nwhile a do\n  print(a + 1)\n  break\nend")
  accepted("local a = q.a\nif x == nil then print(1) elseif a then print(a + 1) end")
end

--- A global is narrowed by no test, and by no assignment of a union to it. The
--- copy of a global in a local is narrowed.
local function test_a_test_of_a_global_narrows_nothing()
  local head <const> = "global G: number | nil\nlocal function f(): number\n"
  unnarrowed_source(head .. "  if G then return G + 1 end\n  return 0\nend\nreturn f")
  unnarrowed_source(head .. "  if G == nil then return 0 end\n  return G + 1\nend\nreturn f")
  unnarrowed_source(head .. "  assert(G)\n  return G + 1\nend\nreturn f")
  accepted_source(head .. "  local g = G\n  if g then return g + 1 end\n  return 0\nend\nreturn f")
  accepted_source(head .. "  local g = G\n  if g == nil then return 0 end\n  return g + 1\nend\nreturn f")
  unnarrowed_source("global U: string | number\nlocal function f(): string\n  U = \"x\"\n  return U\nend\nreturn f")
  accepted_source("local function f(): string\n  local u: string | number = 1\n  u = \"x\"\n  return u\nend\nreturn f")
end

--- The refusal says which place was tested, what kind of place it is, and
--- where the test is, for the hint that gives the copy to a local.
local function test_a_refusal_of_a_use_the_test_of_a_field_or_a_global_did_not_narrow_carries_the_test()
  local function only_error(source: string): compiler.Error
    local compiled = setup()
    local env = assert(compiled.new_env({ defaults = teal.defaults() }))
    local result = compiled.check_string(source, env, "probe.tl", "tl")
    assert(#result.type_errors == 1, source)
    return result.type_errors[1]
  end
  local field = only_error(prelude .. "if q.a then\n  print(q.a + 1)\nend" .. after)
  local field_at = lines_in(prelude) + 1
  assert(field.code == "operator_binary" and field.also == "narrowing_not_local" and field.dropped_kind == "field" and field.dropped_place == "q.a" and
      field.dropped_by == "q.a" and field.dropped_y == field_at and field.y == field_at + 1,
    tostring(field.code) .. " " .. tostring(field.dropped_kind) .. " " .. tostring(field.dropped_y))
  local used_global = only_error("global G: number | nil\nlocal function f(): number\n  if G then\n    return G + 1\n  end\n  return 0\nend\nreturn f")
  assert(used_global.also == "narrowing_not_local" and used_global.dropped_kind == "global" and used_global.dropped_place == "G" and
      used_global.dropped_by == "G" and used_global.dropped_y == 3 and used_global.y == 4,
    tostring(used_global.code) .. " " .. tostring(used_global.dropped_kind) .. " " .. tostring(used_global.dropped_y))
  local assigned = only_error("global U: string | number\nlocal function f(): string\n  U = \"x\"\n  return U\nend\nreturn f")
  assert(assigned.also == "narrowing_not_local" and assigned.dropped_kind == "global" and assigned.dropped_by == "U = ...",
    tostring(assigned.code) .. " " .. tostring(assigned.dropped_by))
end

--- A use of a field a test narrowed nothing of keeps the refusal it has, and
--- carries the note that the test narrowed nothing, whatever it was refused
--- for: whether the use relies on the test is for the program to say, so the
--- note is a condition and not a diagnosis. Where the test does not hold (the
--- branch of an `if` that takes the value out) the use relies on nothing, and
--- the refusal carries no note.
local function test_a_refused_use_of_a_tested_field_carries_a_note_and_its_own_refusal()
  local function noted(source: string, code: string)
    local errors = errors_of_source(source)
    assert(#errors > 0, "accepted: " .. source)
    local e = errors[1]
    assert(e.code == code and e.also == "narrowing_not_local",
      tostring(e.code) .. " / " .. tostring(e.also) .. ", wanted " .. code .. " and a note, in " .. source)
  end
  local function plain(source: string, code: string)
    local errors = errors_of_source(source)
    assert(#errors > 0, "accepted: " .. source)
    local e = errors[1]
    assert(e.code == code and e.also == nil,
      tostring(e.code) .. " / " .. tostring(e.also) .. ", wanted " .. code .. " and no note, in " .. source)
  end
  local head <const> = "local record G\n  a: integer\nend\nlocal record R\n  n: integer | nil\n  s: string | nil\n" ..
    "  f: string | nil\n  t: {integer} | nil\n  g: {string:integer} | nil\n  m: {string:integer} | nil\n" ..
    "  k: integer | nil\n  c: G | nil\nend\nlocal enum E\n  \"a\"\n  \"b\"\nend\n" ..
    "local record H\n  e: E | nil\nend\nlocal r: R = {}\nlocal h: H = {}\n" ..
    "local function takes_table(t: {string}) print(t) end\n" ..
    "local function takes_e(e: E) print(e) end\n"
  -- A use the narrowing would mend, and one it would not.
  noted(head .. "if r.n then\n  print(r.n + 1)\nend", "operator_binary")
  noted(head .. "if r.n then\n  print(r.n + {})\nend", "operator_binary")
  noted(head .. "if r.n then\n  takes_table(r.n)\nend", "mismatch")
  noted(head .. "if r.s then\n  print(r.s + 1)\nend", "operator_binary")
  -- A string literal for the other operand, an array, a map, an enum.
  noted(head .. "if r.f then\n  print(r.f .. \"x\")\nend", "operator_binary")
  noted(head .. "if r.t then\n  print(r.t[1])\nend", "cannot_index_object")
  noted(head .. "if r.g then\n  print(r.g.a)\nend", "cannot_index_key")
  noted(head .. "if h.e then\n  takes_e(h.e)\nend", "mismatch")
  -- Both operands tested; a map walked as an array; a length of a map.
  noted(head .. "if r.n and r.k then\n  print(r.n + r.k)\nend", "operator_binary")
  noted(head .. "if r.m then\n  for _, v in ipairs(r.m) do print(v) end\nend", "not_array")
  noted(head .. "if r.m then\n  print(#r.m)\nend", "operator_unary")
  noted(head .. "if r.n and r.f then\n  print(r.n .. r.f)\nend", "operator_binary")
  -- A key the record lacks.
  noted(head .. "if r.c then\n  print(r.c.missing)\nend", "cannot_index_key")
  -- The branch where the test did not hold.
  plain(head .. "if r.n then\n  print(1)\nelse\n  print(r.n + 1)\nend", "operator_binary")
  plain(head .. "if r.n == nil then\n  print(r.n + 1)\nend", "operator_binary")
  plain(head .. "if r.n then\n  return\nend\nprint(r.n + 1)", "operator_binary")
  -- No test, no note.
  plain(head .. "print(r.n + 1)", "operator_binary")
  -- The copy in a local is narrowed, and nothing is noted.
  accepted_source(head .. "local n = r.n\nif n then\n  print(n + 1)\nend")
end

--- The programs from here to the end of the places test a field in each way
--- that code could change it between the test and the use: an assignment, a
--- write through another reference, a call, an operator, a loop, a jump, the
--- end of a block with a `<close>` local. A field is narrowed by no test, so
--- each program that uses the field after its test is refused at the use, with
--- the note `narrowing_not_local`, whether or not code comes between.

local function test_unnarrowed_field_assignment_to_it_or_its_base()
  refused("if q.a then\n  q.a = nil\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
  refused("if q.a then\n  q = p\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
  unnarrowed("if q.a then\n  q.b = \"x\"\n  print(q.a + 1)\nend")
  unnarrowed("if q.a then\n  p = q\n  print(q.a + 1)\nend")
end

local function test_a_local_assigned_is_widened_back()
  refused("if x then\n  x = maybe()\n  print(x + 1)\nend", "3: " .. plus:sub(1, 28))
  refused("if x then\n  x = maybe()\nend\nprint(x + 1)", "4: " .. plus:sub(1, 28))
  refused("if x then\n  while maybe() do\n    print(x + 1)\n    x = nil\n  end\nend", "3: " .. plus:sub(1, 28))
  accepted("if x then\n  local x: number = 1\n  print(x + 1)\nend")
end

local function test_a_branch_that_ends_narrows_what_follows_by_the_negation_of_its_conditions()
  accepted("if x == nil then return elseif y == nil then return end\nprint(x + 1, y + 1)")
  accepted("if x == nil then die() end\nprint(x + 1)")
  unnarrowed("if q.a == nil then return end\nprint(q.a + 1)")
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

--- `type(...) == "..."` and the left operand of `and` narrow a local, and a field
--- not at all.
local function test_unnarrowed_field_type_test_and_left_of_and()
  unnarrowed("if type(q.a) == \"number\" then print(q.a + 1) end")
  unnarrowed("if type(q.a) ~= \"number\" then return end\nprint(q.a + 1)")
  unnarrowed("print(q.a and q.a + 1)")
  unnarrowed("print(q.c and q.c.n)")
  refused("print(q.a and touch(q) and q.a + 1)", "1: " .. plus:sub(1, 28))
  refused("print(q.a and q.a + (maybe() or 0) + q.a)", "1: " .. plus:sub(1, 28))
  refused("print(type(q.a) == \"number\" and maybe() and q.a + 1)", "1: " .. plus:sub(1, 28))
  unnarrowed("print(q.a and q.a + 1 + (touch(q) and q.a + 1 or 0))")
end

--- The limit [`checker/narrowing.tl`] holds a TODO for: `is` on a field.
local function test_is_on_a_field_is_not_narrowed_yet()
  refused("if q.a is number then print(1) end", "1: can only use 'is' on variables")
end

local function test_a_path_of_two_fields_is_not_a_place_yet()
  refused("assert(q.c.n)\nprint(q.c.n + 1)",
    "1: cannot index key 'n' in type Inn", "2: cannot index key 'n' in type Inn")
  -- The left of `and` narrows `q.c` for the index of `q.c.n`, which is no place
  -- to narrow itself.
  unnarrowed("if q.c and q.c.n then print(q.c.n + 1) end")
end

--- The checker narrows no path of two fields today, so a write through another
--- reference cannot leave one standing: the program is refused at the read.
--- This pins that, until paths are places and a write drops a path with the
--- field anywhere after its base.
local function test_a_write_through_another_reference_leaves_no_nested_path_narrowed()
  local records <const> = "local record G\n  g: integer | nil\nend\nlocal record H\n  f: G\nend\nlocal record A\n  f: G\n  ff: G\n  h: H\nend\n" ..
    "local a: A = { f = { g = 1 }, ff = { g = 1 }, h = { f = { g = 1 } } }\nlocal b = a\n"
  local function nested(test: string, stmt: string, read: string): {string}
    return errors_in(records .. "if " .. test .. " then\n  " .. stmt .. "\n  print(" .. read .. " + 1)\nend\nprint(a, b)\n", 13)
  end
  local function plain(found: {string}, what: string)
    assert(#found == 1 and found[1]:find("cannot use operator '+' for types integer | nil", 1, true),
      what .. ": " .. table.concat(found, "; "))
  end
  plain(nested("a.f.g", "b.f = {}", "a.f.g"), "a.f.g after b.f = {}")
  plain(nested("a.f.g", "b.f.g = nil", "a.f.g"), "a.f.g after b.f.g = nil")
  plain(nested("a.ff.g", "b.f = {}", "a.ff.g"), "a.ff.g after b.f = {}")
  plain(nested("a.h.f.g", "b.f = {}", "a.h.f.g"), "a.h.f.g after b.f = {}")
  plain(nested("a.f.g", "b[\"f\"] = {}", "a.f.g"), "a.f.g after b[\"f\"] = {}")
end

local function test_unnarrowed_field_whose_name_another_begins()
  unnarrowed("if q.ab then\n  q.a = 1\n  print(q.ab + 1)\nend")
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

--- A test of a string narrows a local to that string, and an assignment under
--- a second test of it widens the local back to its declared type for
--- the code after that `if`, whatever the outer test said.
local function test_a_local_assigned_under_a_nested_test_of_it_is_widened_back()
  local want = "in local declaration: n: got string, expected integer"
  local at4 = "4: " .. want
  local at5 = "5: " .. want
  refused_source("local enum E\n  \"a\"\n  \"b\"\nend\nlocal function f(ch: string)\n  if ch == \"a\" then\n    do\n      ch = \"z\"\n    end\n    local e: E = ch\n  end\nend\nprint(f)\n", "10: in local declaration: e: string is not a E")
  refused_source("local function f(ch: string)\n  if ch == \"'\" then\n    if ch == \"'\" then ch = \"z\" end\n    local n: integer = ch\n  end\nend\nprint(f)\n", at4)
  refused_source("local function f(ch: string)\n  if ch == \"'\" or ch == \"!\" then\n    if ch == \"'\" then ch = \"z\" end\n    local n: integer = ch\n  end\nend\nprint(f)\n", at4)
  refused_source("local function f(src: string)\n  local ch = src:sub(1, 1)\n  if ch == \"'\" or ch == \"!\" then\n    if ch == \"'\" then ch = \"z\" end\n    local n: integer = ch\n  end\nend\nprint(f)\n", at5)
  refused_source("local function f(ch: string)\n  if ch == \"'\" or ch == \"!\" then\n    if ch == \"'\" then ch = \"z\" elseif ch == \"!\" then ch = \"y\" end\n    local n: integer = ch\n  end\nend\nprint(f)\n", at4)
  refused_source("local function f(ch: string)\n  if ch == \"'\" or ch == \"!\" then\n    do\n      if ch == \"'\" then ch = \"z\" end\n    end\n    local n: integer = ch\n  end\nend\nprint(f)\n", "6: " .. want)
  refused_source("local function f(ch: string)\n  if ch == \"a\" then\n    if ch == \"a\" then\n      if ch == \"a\" then ch = \"z\" end\n      local n: integer = ch\n    end\n    local m: integer = ch\n  end\nend\nprint(f)\n",
    "5: " .. want, "7: in local declaration: m: got string, expected integer")
  refused_source("local enum E\n  \"a\"\n  \"b\"\nend\nlocal function f(ch: string)\n  if ch == \"a\" or ch == \"b\" then\n    if ch == \"a\" then ch = \"z\" end\n    local e: E = ch\n  end\nend\nprint(f)\n", "8: in local declaration: e: string is not a E")
  accepted_source("local enum E\n  \"a\"\n  \"b\"\nend\nlocal function f(x: string, g: function(): string, c: boolean)\n  if x == \"a\" or x == \"b\" then\n    if c then\n      x = g()\n      assert(x == \"a\" or x == \"b\")\n    end\n    local e: E = x\n    print(e)\n  end\nend\nprint(f)\n")
  accepted_source("local enum E\n  \"a\"\n  \"b\"\nend\nlocal function f(ch: string, g: function(): string)\n  if ch == \"a\" or ch == \"b\" then\n    do\n      ch = g()\n      assert(ch == \"a\" or ch == \"b\")\n    end\n    local e: E = ch\n    print(e)\n  end\nend\nprint(f)\n")
  refused_source("local function f(s: string)\n  local ch = s\n  if ch == \"a\" then\n    if ch == \"a\" then ch = \"z\" end\n    local n: integer = ch\n  end\nend\nprint(f)\n", at5)
end

--- Narrowed to a string, a local is not told apart from its declared type by
--- `same_type`, which ignores the literal. Past an assignment it reads as
--- the declared type. A global is not narrowed to a string at all.
local function test_a_string_narrowing_is_not_taken_for_the_declared_type()
  unnarrowed_source("local enum E\n  \"a\"\n  \"b\"\nend\nglobal g: string\nlocal function touch() g = \"zzz\" end\nlocal function f(c: boolean)\n  if g == \"a\" then\n    while c do\n      local e: E = g\n      touch()\n    end\n  end\nend\nprint(f)\n")
  accepted_source("local enum E\n  \"a\"\n  \"b\"\nend\nlocal function f(ch: string)\n  if ch == \"a\" then\n    local e: E = ch\n    if ch == \"a\" then ch = \"b\" end\n  end\nend\nprint(f)\n")
  refused_source("local enum E\n  \"a\"\n  \"b\"\nend\nlocal function f(ch: string)\n  if ch == \"a\" then\n    if ch == \"a\" then ch = \"z\" end\n    local e: E = ch\n  end\nend\nprint(f)\n",
    "8: in local declaration: e: string is not a E")
end

local function test_unnarrowed_field_write_through_another_reference()
  refused("if q.a then\n  p.a = nil\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
  refused("if q.a then\n  p[\"a\"] = nil\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
  -- The reference may be a longer path.
  unnarrowed("local i: Inner = {}\nif i.n then\n  if p.c then\n    p.c.n = 1\n    print(i.n + 1)\n  end\nend")
  -- Another field of that table, or a field of another name, is not it.
  unnarrowed("if q.a then\n  p.b = \"x\"\n  print(q.a + 1)\nend")
  unnarrowed("if q.a then\n  p.ab = 1\n  print(q.a + 1)\nend")
end

local function test_unnarrowed_field_call()
  refused("if q.a then\n  touch(q)\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
  refused("if q.a then\n  touch(p)\n  print(q.a + 1)\nend", "3: " .. plus:sub(1, 28))
  refused("if q.b then\n  touch(p)\n  print(#q.b)\nend", "3: cannot use operator '#'")
  unnarrowed("if q.a then\n  print(q.a + 1)\nend")
end

local tostring_head <const> = "local record T\n  metamethod __tostring: function(T): string\nend\n" ..
  "local record H\n  n: number | nil\nend\nlocal t: T = setmetatable({} as T, {})\nlocal h: H = {}\n"

local pairs_head <const> = "local record T\n  x: number\n  metamethod __pairs: function<K, V>(T): function(): (K, V)\nend\n" ..
  "local record H\n  n: number | nil\nend\nlocal t: T = setmetatable({} as T, {})\nlocal h: H = {}\n"

local function test_unnarrowed_field_call_that_runs_no_code_of_the_programs()
  -- `assert` and `type`, a function that never returns, and the standard
  -- library's functions given what they cannot hand to a metamethod.
  unnarrowed("if q.a then\n  assert(x)\n  print(q.a + 1)\nend")
  unnarrowed("if q.a then\n  if type(x) == \"number\" then print(1) end\n  print(q.a + 1)\nend")
  unnarrowed("if q.a then\n  if y then die() end\n  print(q.a + 1)\nend")
  unnarrowed("if q.a then\n  local n = x or die()\n  print(q.a + 1, n)\nend")
  unnarrowed("if q.a then\n  local s = tostring(x) .. string.rep(\"x\", 2) .. (\"y\"):upper()\n  print(q.a + #s)\nend")
  unnarrowed("if q.a then\n  local t: {string} = {}\n  table.insert(t, \"x\")\n  print(q.a + #table.concat(t, \",\"))\nend")
  unnarrowed("if q.a then\n  local total = 0\n  for _, v in ipairs({ 1, 2 }) do total = total + v end\n  print(q.a + total)\nend")
  -- A record handed to one is examined by a metamethod only if its type declares one.
  unnarrowed("if q.a then\n  print(q)\n  print(q.a + 1)\nend")
  unnarrowed("if q.a then\n  tostring(q)\n  print(q.a + 1)\nend")
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

--- A metatable attached at run time runs code the checker does not see
--- (doc/design.md: a value dispatches only through metamethods its type
--- declares). No program here is accepted: a field the code writes is
--- narrowed by no test.
local function test_unnarrowed_field_metatable_attached_at_run_time()
  local drop <const> = "function(): integer p.a = nil return 0 end"
  unnarrowed("local m: {string:integer} = setmetatable({}, {__index = " .. drop .. "})\n" ..
      "if q.a then\n  local v = m.foo\n  print(q.a + 1, v)\nend")
  unnarrowed("local m: {string:integer} = setmetatable({}, {__newindex = function() p.a = nil end})\n" ..
      "if q.a then\n  m.foo = 1\n  print(q.a + 1)\nend")
  unnarrowed("local arr: {integer} = setmetatable({}, {__len = " .. drop .. "})\n" ..
      "if q.a then\n  local n = #arr\n  print(q.a + n)\nend")
  unnarrowed("local r: R = setmetatable({}, {__eq = function(): boolean p.a = nil return true end})\n" ..
      "if q.a then\n  local same = r == p\n  print(q.a + (same and 1 or 0))\nend")
end

--- Code the checker sees: an operand of type `any` may carry any
--- metamethod, and a write at a key that is not a literal may be to any
--- field.
local function test_unnarrowed_field_any_and_computed_key()
  refused("local a = x as any\nif q.a then\n  local same = a == p\n  print(q.a + (same and 1 or 0))\nend", "4: " .. plus:sub(1, 28))
  refused("local m = (q as {string:any})\nlocal k = \"a\"\nif q.a then\n  m[k] = nil\n  print(q.a + 1)\nend", "5: " .. plus:sub(1, 28))
  refused("local k: string = tostring(x)\nif q.a then\n  (p as {string:any})[k] = nil\n  print(q.a + 1)\nend", "4: " .. plus:sub(1, 28))
  -- A number key is an index of an array.
  unnarrowed("local arr: {integer} = {}\nlocal i = 1\nif q.a then\n  arr[i] = 2\n  print(q.a + 1)\nend")
end

--- `local x: T, y = 1, 2` reads `y` as a second type: it is refused for
--- having more types than variables, not raised on.
local function test_more_types_than_variables_is_refused_not_raised()
  refused_source("local x: integer | nil, y = 1, 2\nprint(x, y)\n",
    "1: number of types exceeds number of variables", "2: unknown variable: y")
end

--- Only a declared `__eq` runs on a comparison of two records.
local function test_unnarrowed_field_comparison_of_records()
  local head = "local record Node\n  v: integer | nil\nend\nlocal a: Node = {}\nlocal b: Node = {}\n" ..
    "local kids: {Node} = {}\nlocal target: Node = {}\n"
  unnarrowed_source(head .. "if a.v then\n  if a == b then print(1) end\n  print(a.v + 1)\nend\n")
  unnarrowed_source(head .. "if a.v then\n  for _, k in ipairs(kids) do\n    if k == target then print(1) end\n  end\n" ..
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

local function test_a_call_drops_no_local()
  local z = "local z: number | nil = maybe()\n"
  accepted(z .. "if z then\n  touch(q)\n  print(z + 1)\nend")
  accepted(z .. "if z then\n  touch(q)\n  print(z + 1)\n  z = nil\nend")
  -- A literal assigns its own local of the name, not this one.
  accepted(z .. "local function own()\n  local z: number | nil = nil\n  z = 1\n  print(z)\nend\n" ..
      "if z then\n  touch(q)\n  print(z + 1, own)\nend")
  -- One that assigns this one is refused where it assigns, whether it is made
  -- before the test, after the call, or for a parameter; the call then drops
  -- nothing of the local.
  refused(z .. "local function reset() z = nil end\nif z then\n  touch(q)\n  print(z + 1, reset)\nend", "2: " .. captured("z"))
  refused(z .. "local later: function()\nif z then\n  touch(q)\n  print(z + 1)\nend\nlater = function() z = nil end\nprint(later)",
    "7: " .. captured("z"))
  refused("local function g(n: number | nil)\n  local function reset() n = nil end\n  if n then\n    touch(q)\n    print(n + 1, reset)\n  end\nend\nprint(g)",
    "2: " .. captured("n"))
end

-- TODO: accept this once a call to a function declared inside the narrowed
-- branch drops only what its body can assign: it drops `x` though its body
-- assigns nothing of it.

--- The first of the limits of what a call drops, pinned as they are so that
--- the change that lifts one flips its case. The fuzz properties of
--- build/checker_fuzz_test.tl draw none of them (their generator keeps them
--- out, with a TODO each): a program goes into their corpus once it passes.
--- This one is safe and refused.
local function test_a_function_declared_in_the_branch_drops_at_a_call_though_it_assigns_nothing()
  refused("if x then\n  local function own() print(1) end\n  own()\n  print(x + 1)\nend", "4: " .. plus:sub(1, 28))
end

--- A function declared in an inner block, or around the test, that assigns a
--- local is refused where it assigns, and the call of it drops nothing: the
--- narrowing of the local stands.
local function test_a_function_declared_in_any_block_that_assigns_a_local_is_refused_there()
  local head = "local function maybe(): number | nil return nil end\nlocal x: number | nil = maybe()\n"
  local zero = "local x: number | nil = 0\n"
  refused_source(zero .. "do\n  local function reset() x = nil end\n  if x == nil then return end\n  reset()\n  print(x + 1)\nend\n",
    "3: " .. captured("x"))
  refused_source(head .. "if x then\n  local function reset() x = nil end\n  if x == nil then return end\n  reset()\n  print(x + 1)\nend\n",
    "4: " .. captured("x"))
  refused_source(zero .. "local function reset() x = nil end\nif x == nil then return end\nreset()\nprint(x + 1)\n",
    "2: " .. captured("x"))
  refused_source(zero .. "local function reset() x = nil end\ndo\n  if x == nil then return end\n  reset()\n  print(x + 1)\nend\n",
    "2: " .. captured("x"))
  -- And an assignment in the same function drops it: the narrowing a write makes is the write's.
  refused_source(zero .. "do\n  if x == nil then return end\n  x = nil\n  print(x + 1)\nend\n",
    "5: " .. plus:sub(1, 28))
end

-- TODO: refuse the first of these once nil is assignable to no type but one
-- that names it (the roadmap's nil item): `local x, y: number | nil = nil, 0`
-- gives `y` the type `number`, and `local x = x` after a test of `x` gives
-- the copy that type too, so `y = nil` is allowed and puts nil in a
-- `number`. The first name, and a local alone, are refused.

--- A local assigned under a test of it is dropped by the assignment. The second
--- name of a declaration of two is `number` here, not `number | nil`, and a
--- limit of the nil rule, pinned as it is.
local function test_an_assignment_under_a_test_drops_it_and_the_second_name_of_a_declaration_keeps_number()
  local head = "local function maybe(): number | nil return nil end\n"
  accepted_source("local x, y: number | nil = nil, 0\ny = nil\nif y then\n  print(y + 1)\nend\n")
  refused_source(head .. "local x: number | nil = maybe()\nif x then\n  x = maybe()\n  print(x + 1)\nend\n",
    "5: " .. plus:sub(1, 28))
  refused_source("local x, y: number | nil = 0, nil\nif x then\n  x = nil\n  print(x + 1)\nend\n",
    "4: " .. plus:sub(1, 28))
end

--- The body of a function literal begins with none of the facts of the
--- places outside it that may change before it runs, though it is checked
--- where it is made: each local that is assigned once it is declared. A local
--- that nothing assigns keeps its facts. A field has none.
local function test_a_function_body_begins_with_the_facts_of_no_place_that_may_change()
  refused("if q.a then\n  local function g(): number return q.a + 1 end\n  q.a = nil\n  print(g())\nend", "2: " .. plus:sub(1, 28))
  refused("if q.a then\n  local g = function(): number return q.a + 1 end\n  print(g())\nend", "2: " .. plus:sub(1, 28))
  refused("if x then\n  local function g(): number return x + 1 end\n  x = nil\n  print(g())\nend", "2: " .. plus:sub(1, 28))
  -- A function expression reads a local that is assigned after it is made
  -- as it was declared, not as it was tested.
  refused("if x then\n  local g = function(): number return x + 1 end\n  x = nil\n  print(g())\nend", "2: " .. plus:sub(1, 28))
  -- A write after the function is made may run before it: the local is hidden.
  refused("local w: number | nil = nil\nw = maybe()\nif w then\n  local g = function(): number return w + 1 end\n  w = nil\n  print(g())\nend", "4: " .. plus:sub(1, 28))
  refused("local w: number | nil = maybe()\nlocal g = function(): number return w or 0 end\nif w then\n  local h = function(): number return w + 1 end\n  w = maybe()\n  print(g(), h())\nend", "4: " .. plus:sub(1, 28))
  -- A write before it cannot: a default, or the best of a loop, then a function.
  accepted("local w: number | nil = nil\nw = maybe()\nif w then\n  local g = function(): number return w + 1 end\n  print(g())\nend")
  accepted("local best: number | nil = nil\nfor _ = 1, 3 do\n  best = maybe()\nend\nif best then\n  local g = function(): number return best + 1 end\n  print(g())\nend")
  accepted_source("local record O\n  x: number | nil\nend\nlocal function f(opts: O | nil): function(): number\n  opts = opts or {}\n  return function(): number return opts.x or 0 end\nend\nprint(f)\n")
  -- But not a write in a loop that also makes the function, which a later pass runs.
  refused("local best: number | nil = nil\nfor _ = 1, 3 do\n  if best then\n    local g = function(): number return best + 1 end\n    print(g())\n  end\n  best = maybe()\nend", "4: " .. plus:sub(1, 28))
  refused("local best: number | nil = nil\nwhile y do\n  best = maybe()\n  if best then\n    local g = function(): number return best + 1 end\n    print(g())\n  end\nend", "5: " .. plus:sub(1, 28))
  -- A local no code assigns after its declaration keeps its test in the body.
  accepted_source("local function maybe(): number | nil return nil end\nlocal z: number | nil = maybe()\nif z then\n  local g = function(): number return z + 1 end\n  print(g())\nend\n")
  accepted_source("local function maybe(): number | nil return nil end\nlocal function each(f: function()) f() end\nlocal z: number | nil = maybe()\nif z then\n  each(function() print(z + 1) end)\nend\n")
  -- And what the body tests itself it keeps, and the copy of a field is a local.
  accepted("local a = q.a\nif a then\n  local g = function(): number return a + 1 end\n  q.a = nil\n  print(g())\nend")
  accepted("local g = function(): number\n  local a = q.a\n  if a then return a + 1 end\n  return 0\nend\nprint(g())")
  unnarrowed("local g = function(): number\n  if q.a then return q.a + 1 end\n  return 0\nend\nprint(g())")
end

--- A narrowing kept in the entry of a scope that widened the name is hidden from
--- a function body that an assignment after it may reach, and a loop that
--- assigns it refuses the read, as for any other narrowing.
local function test_a_narrowing_kept_where_the_name_was_widened_is_hidden_and_read_by_loops()
  local zero = "local x: number | nil = 0\n"
  refused_source(zero .. "do\n  if x == nil then return end\n" ..
      "  local g = function(): number return x + 1 end\n  x = nil\n  print(g)\nend\n", "4: " .. plus:sub(1, 28))
  refused_source(zero .. "do\n  if x == nil then return end\n" ..
      "  for _ = 1, 2 do\n    print(x + 1)\n    x = nil\n  end\nend\n", "5: " .. plus:sub(1, 28))
end

--- A local declared `local x = x` keeps the type it was declared with, so an
--- assignment and a function body each widen or hide it as they do any
--- local. A parameter is a local too, and one that nothing assigns after its
--- test keeps the test in a function body.
local function test_a_copy_of_a_local_and_a_parameter_are_widened_and_hidden_like_any_local()
  local def = "local function f(x: number | nil): number\n  local x = x\n  if x == nil then return 0 end\n"
  refused_source(def .. "  x = nil\n  return x + 1\nend\nprint(f)\n", "5: cannot use operator '+' for types nil")
  refused_source(def .. "  local g = function(): number return x + 1 end\n  x = nil\n  return g()\nend\nprint(f)\n", "4: " .. plus:sub(1, 28))
  -- Not reassigned: the test holds in the body, and in the copy a hint suggests.
  accepted_source(def .. "  local g = function(): number return x + 1 end\n  return g()\nend\nprint(f)\n")
  accepted_source("local function f(x: number | nil): number\n  if x == nil then return 0 end\n  local y = x\n" ..
      "  local g = function(): number return y + 1 end\n  x = nil\n  return g()\nend\nprint(f)\n")
  accepted_source("local function f(x: number | nil): number\n  if x == nil then return 0 end\n  local x = x\n" ..
      "  local g = function(): number return x + 1 end\n  return g()\nend\nprint(f)\n")
  -- A copy in the scope of what it copies is a variable of its own, with its
  -- own assignments: a parameter, an annotated copy, a plain local, and nil.
  local num = "local function num(): string | number return 1 end\n"
  refused_source(num .. "local function f(x: string | number | nil): number\n  if x == nil then return 0 end\n  local x = x\n" ..
      "  if x is number then return 0 end\n  local g = function(): number return #x end\n  x = num()\n  return g()\nend\nprint(f)\n",
    "6: cannot use operator '#'")
  refused_source(num .. "local function f(x: string | number | nil): number\n  if x == nil then return 0 end\n  local x: string | number = x\n" ..
      "  if x is number then return 0 end\n  local g = function(): number return #x end\n  x = num()\n  return g()\nend\nprint(f)\n",
    "6: cannot use operator '#'")
  refused_source("local function f(x: number | nil): number\n  if x == nil then return 0 end\n  local x: number | nil = x\n" ..
      "  if x == nil then return 0 end\n  local g = function(): number return x + 1 end\n  x = nil\n  return g()\nend\nprint(f)\n", "5: " .. plus:sub(1, 28))
  refused_source(num .. "local function f(): number\n  local x: string | number | nil = num()\n  if x == nil then return 0 end\n  local x = x\n" ..
      "  if x is number then return 0 end\n  local g = function(): number return #x end\n  x = num()\n  return g()\nend\nprint(f)\n",
    "7: cannot use operator '#'")
  -- Widening the copy leaves the name below it, another variable, out of it.
  accepted_source("local function f(x: number | string | nil): number | string\n  if x == nil then return 0 end\n  do\n    local x = x\n" ..
      "    if type(x) == \"string\" then return 1 end\n    x = \"s\"\n" ..
      "    local back: number | string = x\n    return back\n  end\nend\nprint(f)\n")
  -- A parameter assigned after the function is made.
  refused_source("local function f(x: number | nil): function(): number\n  if x == nil then error(\"no\") end\n" ..
      "  local g = function(): number return x + 1 end\n  x = nil\n  return g\nend\nprint(f)\n", "3: " .. plus:sub(1, 28))
  accepted_source("local function f(x: number | nil): function(): number\n  if x == nil then error(\"no\") end\n" ..
      "  local g = function(): number return x + 1 end\n  return g\nend\nprint(f)\n")
end

--- The refusal of a local says the function is what hid the test, and the
--- refusal of a field says that only a local is narrowed: each with the copy
--- to a local that keeps the check with the use.
local function test_a_read_in_a_function_body_is_told_the_function_hid_the_test()
  local function only_error(body: string): compiler.Error
    local compiled = setup()
    local source = prelude .. body .. after
    local env = assert(compiled.new_env({ defaults = teal.defaults() }))
    local result = compiled.check_string(source, env, "probe.tl", "tl")
    assert(#result.type_errors == 1, source)
    return result.type_errors[1]
  end
  local found = only_error("local z: number | nil = maybe()\nif z then\n  local g = function(): number return z + 1 end\n  z = nil\n  print(g())\nend")
  assert(found.code == "narrowing_dropped" and found.dropped_kind == "function" and found.dropped_place == "z",
    tostring(found.code) .. " " .. tostring(found.dropped_kind))
  found = only_error("if q.a then\n  local g = function(): number return q.a + 1 end\n  print(g())\nend")
  assert(found.also == "narrowing_not_local" and found.dropped_kind == "field" and found.dropped_place == "q.a",
    tostring(found.code) .. " " .. tostring(found.dropped_kind))
end

--- `assert(x == nil or y)` and `if x == nil or maybe()` tell nothing of `x`:
--- either `x` was nil and the other side held, or it was not. Each was
--- accepted, and failed at run time when `x` was nil.
local function test_an_or_whose_right_side_gives_no_guard_tells_nothing_of_its_left_side()
  refused("assert(x == nil or y)\nprint(x + 1)", "2: " .. plus:sub(1, 28))
  refused("if x == nil or maybe() then print(x + 1) end", "1: " .. plus:sub(1, 28))
  -- What the left side said when it failed is still told in the right.
  accepted("if x == nil or x > 1 then print(1) end")
  accepted("if x ~= nil and maybe() then print(x + 1) end")
  accepted("assert(x ~= nil or y)\nprint(1)")
  accepted("print(x == nil and 1 or x + 1)")
end

local function test_unnarrowed_field_read_before_a_call_in_the_same_expression()
  unnarrowed("if q.a then\n  print(q.a + 1, maybe())\nend")
  unnarrowed("if q.a then\n  print(q.a + (maybe() or 0))\nend")
  refused("if q.a then\n  print(maybe(), q.a + 1)\nend", "2: " .. plus:sub(1, 28))
  refused("if q.a then\n  print((maybe() or 0) + q.a)\nend", "2: " .. plus:sub(1, 28))
  -- The arguments of a call are read before it runs, however it is written.
  unnarrowed("if q.a then\n  touch(q)\nend\nif q.a then\n  local n = q.a + 1\n  touch(q)\n  print(n)\nend")
end

local function test_unnarrowed_field_test_of_an_operand_past_the_calls_of_a_later_one()
  local z = "local z: number | nil = maybe()\n"
  -- A call changes no local.
  accepted(z .. "if z and maybe() then print(z + 1) end")
  accepted(z .. "if z and #\"abc\" > 1 then print(z + 1) end")
  accepted("if y and maybe() then print(y + 1) end")
  refused("if q.a == nil then\n  return\nelseif maybe() then\n  return\nend\nprint(q.a + 1)", "6: " .. plus:sub(1, 28))
  unnarrowed("if q.a == nil then\n  return\nelseif x then\n  return\nend\nprint(q.a + 1)")
  refused("assert(q.a, tostring(maybe()))\nprint(q.a + 1)", "2: " .. plus:sub(1, 28))
  unnarrowed("assert(q.a, \"no a: \" .. tostring(q.b))\nprint(q.a + 1)")
end

--- A condition the checker expands (an `is` of a record with a `where`
--- clause is a macro expression) still counts as a test that ran no code.
local function test_unnarrowed_field_expanded_condition()
  local head = "local interface Animal\n  kind: string\nend\n" ..
    "local record Cat is Animal where self.kind == \"cat\"\nend\n" ..
    "local record H\n  n: number | nil\nend\nlocal h: H = {}\nlocal a: Animal = { kind = \"dog\" }\n"
  unnarrowed_source(head .. "if h.n == nil then\n  return\nelseif a is Cat then\n  return\nend\nprint(h.n + 1)\n")
  refused_source(head .. "local function maybe(): boolean return false end\n" ..
      "if h.n == nil then\n  return\nelseif a is Cat or maybe() then\n  return\nend\nprint(h.n + 1)\n",
    "17: cannot use operator '+'")
end

local function test_unnarrowed_field_read_in_a_loop()
  unnarrowed("if q.a then\n  while y do\n    print(q.a + 1)\n    touch(q)\n  end\nend")
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    print(q.a + 1)\n    touch(q)\n  end\nend")
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    local n = q.a + 1\n    p.a = nil\n    print(n)\n  end\nend")
  unnarrowed("if q.a then\n  while y do\n    print(q.a + 1)\n    q.a = nil\n  end\nend")
  unnarrowed("if q.a then\n  repeat\n    print(q.a + 1)\n    touch(q)\n  until y\nend")
  unnarrowed("if q.a then\n  for _, v in ipairs({ 1 }) do\n    print(q.a + v)\n    touch(q)\n  end\nend")
  -- A drop in a loop inside the loop is one of the outer loop's.
  unnarrowed("if q.a then\n  while y do\n    print(q.a + 1)\n    for _ = 1, 2 do touch(q) end\n  end\nend")
  -- Each read before the drop is refused, those after it are refused for the drop itself.
  unnarrowed("if q.a then\n  while y do\n    print(q.a + 1)\n    print(q.a + 2)\n    touch(q)\n    print(q.a + 3)\n  end\nend")
  -- The condition of a loop is its body: what it drops is dropped for the body.
  refused("if q.a then\n  while maybe() do\n    print(q.a + 1)\n  end\nend", "3: " .. plus:sub(1, 28))
  refused("if q.a then\n  repeat\n    touch(q)\n    print(q.a + 1)\n  until y\nend", "4: " .. plus:sub(1, 28))
  unnarrowed("if q.a then\n  repeat\n    x = nil\n  until q.a + 1 > 2 or touch(q)\nend")
end

local function test_unnarrowed_field_branch_that_may_break_or_go_out()
  -- It ends in `return`, but a path through it breaks out first.
  unnarrowed("if q.a then\n  for _ = 1, 3 do\n    print(q.a + 1)\n    while y do\n      if x then\n        touch(q)\n" ..
      "        if y then break end\n        return\n      end\n    end\n  end\nend")
  refused("if q.a then\n  for i = 1, 3 do\n    if i == 2 then\n      touch(q)\n      if y then break end\n" ..
      "      return\n    end\n  end\n  print(q.a + 1)\nend", "9: " .. plus:sub(1, 28))
  refused("if q.a then\n  repeat\n    if y then\n      touch(q)\n      if y then break end\n      return\n" ..
      "    end\n  until true\n  print(q.a + 1)\nend", "9: " .. plus:sub(1, 28))
  -- A `goto` continues the loop, so it goes out of the branch before `return`.
  refused("if q.a then\n  for _ = 1, 3 do\n    if y then\n      touch(q)\n      if x then goto continue end\n      return\n" ..
      "    end\n    print(q.a + 1)\n    ::continue::\n  end\nend", "8: " .. plus:sub(1, 28))
  -- A `goto` of a loop inside the branch stays inside it.
  unnarrowed("if q.a then\n  for i = 1, 3 do\n    if i == 2 then\n      touch(q)\n      for _ = 1, 2 do\n" ..
      "        if y then goto continue end\n        ::continue::\n      end\n      return\n    end\n  end\n  print(q.a + 1)\nend")
  -- A `break` of a loop inside the branch stays inside it.
  unnarrowed("if q.a then\n  for i = 1, 3 do\n    if i == 2 then\n      touch(q)\n      for _ = 1, 2 do\n" ..
      "        if y then break end\n      end\n      return\n    end\n  end\n  print(q.a + 1)\nend")
  unnarrowed("if q.a then\n  if y then\n    touch(q)\n    return\n  end\n  print(q.a + 1)\nend")
end

local function test_unnarrowed_field_read_in_a_branch_that_leaves()
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    if y then\n      print(q.a + 1)\n      return\n    end\n    touch(q)\n  end\nend")
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    if y then\n      print(q.a + 1)\n    end\n    touch(q)\n  end\nend")
end

local function test_unnarrowed_field_every_loop_around_a_read()
  unnarrowed("if q.a then\n  for _ = 1, 3 do\n    for _ = 1, 2 do print(q.a + 1) end\n    touch(q)\n  end\nend")
  unnarrowed("local k = 0\nif q.a then\n  while q.a + k < 10 do\n    k = k + 1\n    touch(q)\n  end\nend")
end

local function test_unnarrowed_field_loop_that_drops_nothing()
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    local n = q.a + 1\n    x = n\n  end\nend")
  -- A function literal in the body runs at no pass of it.
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    local n = q.a + 1\n    local g = function() touch(q) end\n    x = n\n  end\nend")
  -- A drop in a branch that leaves is not one of the next pass.
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    print(q.a + 1)\n    if y then\n      touch(q)\n      return\n    end\n  end\nend")
  unnarrowed("if q.a then\n  while y do\n    print(q.a + 1)\n    if x then\n      touch(q)\n      die()\n    end\n  end\nend")
  -- A fact the loop narrows itself is its own.
  unnarrowed("for _ = 1, 2 do\n  if q.a then\n    print(q.a + 1)\n    touch(q)\n  end\nend")
  -- A different field, or a write to another name.
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    print(q.a + 1)\n    p.b = \"x\"\n  end\nend")
end

local function test_unnarrowed_field_after_a_loop()
  refused("if q.a then\n  for _ = 1, 2 do\n    touch(q)\n  end\n  print(q.a + 1)\nend", "5: " .. plus:sub(1, 28))
  refused("if q.a then\n  while y do\n    p.a = nil\n  end\n  print(q.a + 1)\nend", "5: " .. plus:sub(1, 28))
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    x = 1\n  end\n  print(q.a + 1)\nend")
end

local function test_a_local_assigned_in_a_loop_in_a_branch_is_widened_at_its_head()
  -- The assignment is in the `else` of a branch, which has no condition.
  accepted("local real: number | nil = nil\nfor _ = 1, 2 do\n  if y then\n    print(1)\n  else\n    if real ~= nil then print(real + 1) end\n    real = x\n  end\nend")
end

local function test_unnarrowed_field_pairs_ipairs_gmatch_and_next()
  unnarrowed("if q.a then\n  for _, v in ipairs({ 1 }) do print(q.a + v) end\n  print(q.a + 1)\nend")
  unnarrowed("local t: {string:number} = {}\nif q.a then\n  for _, v in pairs(t) do print(q.a + v) end\n  print(q.a + 1)\nend")
  unnarrowed("if q.a then\n  for w in (\"a b\"):gmatch(\"%a+\") do print(q.a + #w) end\n  print(q.a + 1)\nend")
  unnarrowed("local t: {string:number} = {}\nif q.a then\n  for _ in next, t do print(q.a + 1) end\n  print(q.a + 1)\nend")
  -- An iterator function is code, run before every pass.
  refused("if q.a then\n  for v in maybe do\n    print(q.a + (v or 0))\n  end\nend", "3: " .. plus:sub(1, 28))
  refused("if q.a then\n  for v in maybe do\n    print(v)\n  end\n  print(q.a + 1)\nend", "5: " .. plus:sub(1, 28))
  -- `pairs` of a record with a `__pairs` it declares runs it.
  refused_source(pairs_head .. "if h.n then\n  for _ in pairs(t) do print(1) end\n  print(h.n + 1)\nend", "12: " .. plus:sub(1, 28))
end

local function test_unnarrowed_field_branch_that_leaves()
  unnarrowed("if q.a then\n  if y then\n    touch(q)\n    return\n  end\n  print(q.a + 1)\nend")
  unnarrowed("if q.a then\n  if y then\n    touch(q)\n    die()\n  end\n  print(q.a + 1)\nend")
  -- A branch that goes on, or leaves a loop for the code after it, does.
  refused("if q.a then\n  if y then\n    touch(q)\n  end\n  print(q.a + 1)\nend", "5: " .. plus:sub(1, 28))
  refused("if q.a then\n  while y do\n    if x then\n      touch(q)\n      break\n    end\n  end\n  print(q.a + 1)\nend",
    "8: " .. plus:sub(1, 28))
  -- And the condition of the branch ran either way.
  refused("if q.a then\n  if maybe() then\n    return\n  end\n  print(q.a + 1)\nend", "5: " .. plus:sub(1, 28))
end

local function test_unnarrowed_field_continue()
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    print(q.a + 1)\n    if y then goto continue end\n    ::continue::\n  end\nend")
  unnarrowed("if q.a then\n  repeat\n    if y then goto continue end\n    print(q.a + 1)\n    ::continue::\n  until x\nend")
  -- What the pass drops before the continue is dropped for the next pass.
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    print(q.a + 1)\n    if y then touch(q) goto continue end\n    ::continue::\n  end\nend")
end

local function test_unnarrowed_field_function_literal()
  unnarrowed("if q.a then\n  local g = function() touch(q) end\n  print(q.a + 1, g)\nend")
  refused("if q.a then\n  local g = function()\n    touch(q)\n    print(q.a + 1)\n  end\n  g()\nend", "4: " .. plus:sub(1, 28))
  unnarrowed("if q.a then\n  local function g() p.a = nil end\n  print(q.a + 1, g)\nend")
end

--- A fact about a field of a name is about the binding it was found on: a
--- binding of the name declared after it (a local, a loop variable) is a
--- table the test did not look at, so the fact is not its.
local function test_a_new_binding_of_a_name_does_not_inherit_its_field_facts()
  local at <const> = plus:sub(1, 28)
  refused("if q.a then\n  local q = p\n  print(q.a + 1)\nend", "3: " .. at)
  refused("if not q.a then return end\nlocal q = p\nprint(q.a + 1)", "3: " .. at)
  refused("if q.a then\n  do\n    local q = p\n    print(q.a + 1)\n  end\nend", "4: " .. at)
  refused("if q.a then\n  local rs: {R} = {}\n  for _, q in ipairs(rs) do\n    print(q.a + 1)\n  end\nend", "4: " .. at)
  -- Each binding in turn.
  refused("if q.a then\n  local q = p\n  if p.a then\n    local q = p\n    print(q.a + 1)\n  end\nend", "5: " .. at)
end

local function test_unnarrowed_field_of_a_new_binding()
  unnarrowed("if q.a then\n  local q = p\n  if q.a then\n    print(q.a + 1)\n  end\nend")
  unnarrowed("if q.c then\n  local q = p\n  if q.c then\n    print(q.c.n)\n  end\nend")
  refused("if q.c then\n  local q = p\n  print(q.c.n)\nend", "3: cannot index")
  unnarrowed("local q = p\nif q.a then\n  print(q.a + 1)\nend")
end

--- `local q = q` is the same value, so it keeps what is known of `q.a`.
local function test_unnarrowed_field_of_a_local_of_the_same_value()
  unnarrowed("if q.a then\n  local q = q\n  print(q.a + 1)\nend")
end

--- A name declared where no local is (a field of a record type that is
--- named `q`) drops nothing of the local `q`.
local function test_unnarrowed_field_type_with_a_member_named_like_a_local()
  unnarrowed("if q.a then\n  local record W\n    record q\n      z: number\n    end\n  end\n  print(q.a + 1, W)\nend")
end

--- A binding of the name drops the facts of its fields for good: the fact
--- does not stand again when the binding's scope ends, though it could.
--- The limit is pinned as a limit.
local function test_a_fact_dropped_by_a_new_binding_does_not_stand_again()
  local at <const> = plus:sub(1, 28)
  refused("if q.a then\n  do\n    local q = p\n    print(q)\n  end\n  print(q.a + 1)\nend", "6: " .. at)
  refused("if q.a then\n  for _, q in ipairs({ p }) do\n    print(q)\n  end\n  print(q.a + 1)\nend", "5: " .. at)
end

--- A binding in a branch that never reaches the code after it drops
--- nothing for that code.
local function test_unnarrowed_field_binding_in_a_branch_that_leaves()
  unnarrowed("if q.a then\n  if x then\n    local q = p\n    touch(q)\n    return\n  end\n  print(q.a + 1)\nend")
  unnarrowed("if q.a then\n  if x then\n    local q = p\n    q.a = nil\n    return\n  end\n  print(q.a + 1)\nend")
  unnarrowed("if q.a then\n  if x then\n    return\n  else\n    local q = p\n    touch(q)\n    return\n  end\n  print(q.a + 1)\nend")
  accepted("if q.a then\n  for _ = 1, 2 do\n    if x then\n      local q = p\n      touch(q)\n      break\n    end\n  end\n  print(1)\nend")
end

--- A binding of the field's base in a loop's body changes nothing for a field:
--- each read is refused.
local function test_unnarrowed_field_binding_in_a_loop()
  unnarrowed("if q.a then\n  while y do\n    print(q.a + 1)\n    local q = p\n    print(q)\n  end\nend")
  unnarrowed("if q.a then\n  repeat\n    print(q.a + 1)\n    local q = p\n    print(q)\n  until y\nend")
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    print(q.a + 1)\n    local q = p\n    print(q)\n  end\nend")
  unnarrowed("if q.a then\n  for _ = 1, 2 do\n    print(q.a + 1)\n    for _, q in ipairs({ p }) do print(q) end\n  end\nend")
  refused("if q.a then\n  for _ = 1, 3 do\n    if y then\n      local q = p\n      print(q)\n      goto continue\n    end\n" ..
      "    print(q.a + 1)\n    ::continue::\n  end\nend", "8: " .. plus:sub(1, 28))
  -- Narrowing again inside the loop does not bring the fact back for the
  -- pass, though the binding comes after it.
  unnarrowed("if q.a then\n  while y do\n    assert(q.a)\n    print(q.a + 1)\n    local q = p\n    print(q)\n  end\nend")
  unnarrowed("if q.a then\n  while y do\n    if q.a then\n      print(q.a + 1)\n    end\n    local q = p\n    print(q)\n  end\nend")
end

--- A write through the new name, which may be the table that was checked, in
--- a loop.
local function test_unnarrowed_field_write_through_a_new_binding_in_a_loop()
  unnarrowed_source("local sink: integer = 0\nlocal x1 = { value = 0 as integer | nil }\nlocal alias = x1\nlocal n = 0\n" ..
      "if x1.value == nil then return sink end\nwhile n < 2 do\n  n = n + 1\n  sink = sink + x1.value + 1\n" ..
      "  local x1 = alias\n  x1.value = nil\nend\nreturn sink")
end

--- A binding in one branch changes nothing for the field in the other.
local function test_unnarrowed_field_binding_in_one_branch()
  refused("if q.a then\n  if x then\n    local q = p\n    print(q)\n  else\n    print(q.a + 1)\n  end\nend", "6: " .. plus:sub(1, 28))
end

local function test_unnarrowed_field_of_a_global_hidden_by_a_local()
  local head <const> = "global record GR\n  a: integer | nil\nend\nlocal function g(other: GR): integer\n"
  refused_source(head .. "  if GR.a then\n    local GR = other\n    return GR.a + 1\n  end\n  return 0\nend\nreturn g",
    "7: " .. plus:sub(1, 28))
  -- It does not stand again after the block, as for a local.
  refused_source(head .. "  if GR.a then\n    do\n      local GR = other\n      print(GR)\n    end\n    return GR.a + 1\n  end\n  return 0\nend\nreturn g",
    "10: " .. plus:sub(1, 28))
end

local function test_unnarrowed_field_operator_metamethod()
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
  unnarrowed_source(head .. "if h.n then\n  local same = v == w\n  print(h.n + (same and 1 or 0))\nend")
  unnarrowed_source(head .. "if h.n then\n  local z = v.x\n  print(h.n + z)\nend")
  unnarrowed_source(head .. "if h.n then\n  local z = 2 * 3 + #\"abc\"\n  local a: {number} = { 1 }\n" ..
      "  local same = a == a and \"s\" == \"t\" and z .. \"\" == \"6\"\n  print(h.n + z + #a + (same and 1 or 0))\nend")
  unnarrowed_source(head .. "if h.n then\n  local nothing = v == nil\n  print(h.n + (nothing and 1 or 0))\nend")
end

--- A global is narrowed by no test, whatever writes to it through `_G` (a
--- cast to a map, or to a record that declares the field) or a key that may
--- be its name.
local function test_unnarrowed_global_write_through_g_or_an_alias()
  local head <const> = "global G: number | nil\nlocal function f(k: string): number\n  if G then\n"
  local tail <const> = "    return G + 1\n  end\n  return 0\nend\nreturn f"
  local at <const> = "5: " .. plus
  refused_source(head .. "    _G.G = nil\n" .. tail, at)
  refused_source(head .. "    _G[\"G\"] = nil\n" .. tail, at)
  refused_source(head .. "    local e = _G as {string:any}\n    e.G = nil\n" .. tail, "6: " .. plus)
  refused_source(head .. "    local e = _G as {string:any}\n    e[k] = nil\n" .. tail, "6: " .. plus)
  refused_source("local record R\n  G: number | nil\nend\n" .. head .. "    local r = _G as R\n    r.G = nil\n" .. tail,
    "9: " .. plus)
  -- A call that writes it already dropped it.
  refused_source(head .. "    rawset(_G as {string:any}, \"G\", nil)\n" .. tail, at)
  -- A write to another field, or a number key, is no write to the global.
  unnarrowed_source("global H: number | nil\n" .. head .. "    _G.H = nil\n" .. tail)
  unnarrowed_source(head .. "    local t: {string:any} = {}\n    t.H = 1\n" .. tail)
  unnarrowed_source(head .. "    local a: {integer} = {}\n    a[1] = 2\n" .. tail)
  -- A local of the name is not the global.
  accepted_source("global G: number | nil\nlocal function f(): number\n  local G: number | nil = 1\n  if G then\n" ..
      "    local t: {string:any} = {}\n    t.G = nil\n    return G + 1\n  end\n  return 0\nend\nreturn f")
  -- A copy of the global in a local is narrowed, and no write to the global changes it.
  accepted_source("global G: number | nil\nlocal function f(): number\n  local g = G\n  if g then\n    _G.G = nil\n    return g + 1\n  end\n  return 0\nend\nreturn f")
end

--- A local of the file that hides a global within a block does not hide it
--- from the code after the block: the global is narrowed by no test.
local function test_unnarrowed_global_hidden_by_a_local_in_a_block()
  local head <const> = "global G: number | nil\nlocal function clear() G = nil end\nlocal function f(): number\n  if G then\n    do\n"
  local tail <const> = "    end\n    return G + 1\n  end\n  return 0\nend\nreturn f"
  local at <const> = "10: " .. plus
  refused_source(head .. "      local G: number | nil = 1\n      _G.G = nil\n      local _p = G\n" .. tail, at)
  refused_source(head .. "      local G: number | nil = 1\n      if G then local _p = G end\n      _G.G = nil\n" .. tail, at)
  refused_source(head .. "      local G: number | nil = 1\n      if G then print(G) end\n      clear()\n" .. tail, at)
  -- A write to another field leaves the fact of a local of the file.
  accepted_source("local function f(): number\n  local G: number | nil = 1\n  if G then\n    do\n      local t: {string:any} = {}\n" ..
      "      t.H = 1\n    end\n    return G + 1\n  end\n  return 0\nend\nreturn f")
end

--- A write to a global replaces the table its field facts are about.
local function test_unnarrowed_field_of_a_global_write_through_g()
  local head <const> = "global record GR\n  a: number | nil\nend\nglobal G: GR = {}\nlocal function f(k: string): number\n  if G.a then\n"
  local tail <const> = "    return G.a + 1\n  end\n  return 0\nend\nreturn f"
  local at <const> = "8: " .. plus
  refused_source(head .. "    _G.G = {}\n" .. tail, at)
  refused_source(head .. "    local e = _G as {string:any}\n    e.G = {}\n" .. tail, "9: " .. plus)
  refused_source(head .. "    local e = _G as {string:any}\n    e[k] = {}\n" .. tail, "9: " .. plus)
  unnarrowed_source("global H: number | nil\n" .. head .. "    _G.H = nil\n" .. tail)
end

--- A to-be-closed local's `__close` runs where its block ends and on each
--- `break` and `goto` that leaves it, so it drops what is known of a field
--- or a global like a call does.
local close_head <const> = "local record C\n  a: number | nil\n  metamethod __close: function(C)\nend\n" ..
  "local record N\n  a: number | nil\nend\n"

local function test_unnarrowed_field_close_at_the_end_of_a_block()
  local head <const> = close_head .. "local function f(q: C, p: C): number\n  if q.a then\n"
  local tail <const> = "    return q.a + 1\n  end\n  return 0\nend\nreturn f"
  refused_source(head .. "    do\n      local c <close> = p\n      local _ = c\n    end\n" .. tail, "14: " .. plus)
  -- The block of an `if` is a block too.
  refused_source(head .. "    if p.a then\n      local c <close> = p\n      local _ = c\n    end\n" .. tail, "14: " .. plus)
  -- A type that declares no `__close` runs nothing.
  unnarrowed_source(close_head .. "local function f(q: N, p: C): number\n  if q.a then\n" ..
      "    do\n      local c <close> = nil\n      local _ = c\n    end\n" .. tail)
  -- A block with no `<close>` local drops nothing.
  unnarrowed_source(head .. "    do\n      local c = p\n      local _ = c\n    end\n" .. tail)
  -- Nothing is read after the block closes.
  unnarrowed_source(head .. "    local n = q.a + 1\n    do\n      local c <close> = p\n      local _ = c\n    end\n    return n\n  end\n  return 0\nend\nreturn f")
end

local function test_unnarrowed_global_close_at_the_end_of_a_block()
  refused_source(close_head .. "global G: number | nil\nlocal function f(p: C): number\n  if G then\n" ..
      "    do\n      local c <close> = p\n      local _ = c\n    end\n    return G + 1\n  end\n  return 0\nend\nreturn f", "15: " .. plus)
  -- A local of the file is assigned by no `__close`.
  accepted_source(close_head .. "local function f(p: C): number\n  local v: number | nil = 1\n  if v then\n" ..
      "    do\n      local c <close> = p\n      local _ = c\n    end\n    return v + 1\n  end\n  return 0\nend\nreturn f")
end

local function test_unnarrowed_field_close_in_a_loop_body()
  local head <const> = close_head .. "local function f(q: C, p: C, y: boolean): number\n  if q.a then\n"
  local tail <const> = "  end\n  return 0\nend\nreturn f"
  unnarrowed_source(head .. "    while y do\n      print(q.a + 1)\n      local c <close> = p\n      local _ = c\n    end\n" .. tail)
  unnarrowed_source(head .. "    for _ = 1, 2 do\n      print(q.a + 1)\n      local c <close> = p\n      local _ = c\n    end\n" .. tail)
  -- A `repeat` closes after its `until`.
  unnarrowed_source(head .. "    repeat\n      print(q.a + 1)\n      local c <close> = p\n      local _ = c\n    until y\n" .. tail)
  -- A fact taken after the loop's closes stands.
  unnarrowed_source(head .. "    while y do\n      do\n        local c <close> = p\n        local _ = c\n      end\n    end\n" ..
      "    if q.a then\n      return q.a + 1\n    end\n" .. tail)
end

local function test_unnarrowed_field_break_or_goto_that_leaves_a_close()
  local head <const> = close_head .. "local function f(q: C, p: C, y: boolean): number\n  if q.a then\n"
  local tail <const> = "  end\n  return 0\nend\nreturn f"
  -- Control leaves the loop with the `__close` run: what is known of `q.a`
  -- before the loop is gone after it.
  refused_source(head .. "    while y do\n      if y then\n        local c <close> = p\n        local _ = c\n        break\n      end\n" ..
      "    end\n    return q.a + 1\n" .. tail, "17: " .. plus)
  refused_source(head .. "    for _ = 1, 2 do\n      do\n        local c <close> = p\n        local _ = c\n        goto continue\n      end\n" ..
      "      ::continue::\n    end\n    return q.a + 1\n" .. tail, "18: " .. plus)
  -- A `break` that leaves no `<close>` local drops nothing.
  unnarrowed_source(head .. "    while y do\n      if y then\n        break\n      end\n    end\n    return q.a + 1\n" .. tail)
end

--- A `break` or `goto` that leaves a block with a `<close>` local changes
--- nothing for a field, in the branch or after the loop.
local function test_unnarrowed_field_jump_out_of_a_close_block()
  unnarrowed_source([[
local record C
   a: number | nil
   metamethod __close: function(C)
end

local function f(q: C, p: C, y: boolean): number
  while y do
    local c <close> = p
    local _ = c
    if q.a then
      if y then break end
      print(q.a + 1)
    end
  end
  return 0
end
return f
]])
  unnarrowed_source([[
local record C
   a: number | nil
   metamethod __close: function(C)
end

local function f(q: C, p: C, y: boolean): number
  for _ = 1, 2 do
    local c <close> = p
    local _ = c
    if q.a then
      if y then goto continue end
      print(q.a + 1)
    end
    ::continue::
  end
  return 0
end
return f
]])
  unnarrowed_source([[
local record C
   a: number | nil
   metamethod __close: function(C)
end

local function f(q: C, p: C, y: boolean): number
  local c <close> = p
  local _ = c
  if q.a then
    for _ = 1, 2 do
      if y then goto continue end
      print(q.a + 1)
      ::continue::
    end
  end
  return 0
end
return f
]])
  unnarrowed_source([[
local record C
   a: number | nil
   metamethod __close: function(C)
end

local function f(q: C, p: C, y: boolean): number
  local c <close> = p
  local _ = c
  if q.a then
    while y do
      if y then break end
      print(q.a + 1)
    end
    return q.a + 1
  end
  return 0
end
return f
]])
  unnarrowed_source([[
local record C
   a: number | nil
   metamethod __close: function(C)
end

local function f(q: C, p: C, y: boolean): number
  if q.a then
    do
      local c <close> = p
      local _ = c
      for _ = 1, 2 do
        if y then goto continue end
        print(q.a + 1)
        ::continue::
      end
    end
  end
  return 0
end
return f
]])
  unnarrowed_source([[
local record C
   a: number | nil
   metamethod __close: function(C)
end

local function f(q: C, p: C, y: boolean): number
  if q.a then
    do
      local c <close> = p
      local _ = c
      while y do
        if y then break end
        print(q.a + 1)
      end
      return q.a + 1
    end
  end
  return 0
end
return f
]])
  refused_source([[
local record C
   a: number | nil
   metamethod __close: function(C)
end

local function f(q: C, p: C, y: boolean): number
  if q.a then
    while y do
      do
        local c <close> = p
        local _ = c
        if y then break end
      end
    end
    return q.a + 1
  end
  return 0
end
return f
]], "15: " .. plus)
  refused_source([[
local record C
   a: number | nil
   metamethod __close: function(C)
end

local function f(q: C, p: C, y: boolean): number
  if q.a then
    for _ = 1, 2 do
      do
        local c <close> = p
        local _ = c
        if y then goto continue end
      end
      ::continue::
    end
    return q.a + 1
  end
  return 0
end
return f
]], "16: " .. plus)
  refused_source([[
local record C
   a: number | nil
   metamethod __close: function(C)
end

local function f(q: C, p: C, y: boolean): number
  if q.a then
    repeat
      local c <close> = p
      local _ = c
      if y then break end
    until y
    return q.a + 1
  end
  return 0
end
return f
]], "13: " .. plus)
end
