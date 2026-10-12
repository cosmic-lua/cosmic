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

local record Scope
  vars: {string:any}
  narrows?: {string:boolean}
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
  drop: function({Scope}, Place)
  type_is: function(any, Place, Type): Guard
  value_is: function(any, Place, Type): Guard
  negate: function(any, Guard | nil): Guard | nil
  both: function(any, Guard | nil, Guard | nil): Guard | nil
  either: function(any, Guard | nil, Guard | nil): Guard
  any_of: function(any, Guard | nil, Guard | nil): Guard
  none_of: function(any, {Node}, integer): Guard | nil
  evaluate: function(Host, Guard | nil): {string:Guard}
end

local built: compiler
local narrowing: Narrowing

--- The carried compiler, and [`checker/narrowing.tl`] compiled by it and
--- loaded.
local function setup()
  if built ~= nil then
    return
  end
  built = assert(teal.load(true))
  local env = assert(built.new_env({ defaults = {
    feat_lax = "off", gen_compat = "off", gen_target = "5.4",
  } }))
  local code, result = built.gen(assert(Fs.read("checker/narrowing.tl")), env, nil, "tl")
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
  narrowing = loaded as Narrowing
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
  local held = narrowing.evaluate(host_of(world), guard)
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
  local x = assert(narrowing.place_of(variable("x")))
  assert(x.key == "x" and x.base == "x" and #x.fields == 0)
  local f = assert(narrowing.place_of(op(".", variable("r"), { kind = "identifier", tk = "a" })))
  assert(f.key == "r.a" and f.base == "r" and #f.fields == 1 and f.fields[1] == "a")
  assert(narrowing.local_place("n").key == "n" and narrowing.field_place("n", "m").key == "n.m")
end

local function test_no_other_expression_is_a_place()
  setup()
  local field = op(".", variable("r"), { kind = "identifier", tk = "a" })
  -- A longer path, an index, a call and a literal.
  assert(narrowing.place_of(op(".", field, { kind = "identifier", tk = "b" })) == nil)
  assert(narrowing.place_of(op("@index", variable("t"), { kind = "integer", tk = "1" })) == nil)
  assert(narrowing.place_of(op("@funcall", variable("f"), variable("x"))) == nil)
  assert(narrowing.place_of({ kind = "string", tk = "s" }) == nil)
end

local function test_an_assignment_targets_a_name_by_its_text_else_a_place()
  setup()
  assert(assert(narrowing.target_of(variable("x"))).key == "x")
  -- Its text names the local even where the node is no variable read.
  local named: Node = { kind = "error_node", tk = "x" }
  assert(assert(narrowing.target_of(named)).key == "x")
  assert(narrowing.place_of(named) == nil)
  -- And it wins over the path of a node that has both.
  local both: Node = op(".", variable("r"), { kind = "identifier", tk = "a" })
  both.tk = "t"
  assert(assert(narrowing.target_of(both)).key == "t")
  assert(assert(narrowing.place_of(both)).key == "r.a")
  assert(assert(narrowing.target_of(op(".", variable("r"), { kind = "identifier", tk = "a" }))).key == "r.a")
  assert(narrowing.target_of(op("@index", variable("t"), variable("i"))) == nil)
end

local function test_an_assignment_to_a_local_drops_its_fields_not_itself()
  setup()
  local x = narrowing.local_place("x")
  assert(narrowing.forgets(x, "x.f") and narrowing.forgets(x, "x.f.g"))
  assert(not narrowing.forgets(x, "x"))
  assert(not narrowing.forgets(x, "xy.f") and not narrowing.forgets(x, "y.f"))
end

local function test_an_assignment_to_a_field_drops_that_field()
  setup()
  local f = narrowing.field_place("x", "f")
  assert(narrowing.forgets(f, "x.f"))
  assert(not narrowing.forgets(f, "x.g") and not narrowing.forgets(f, "y.f"))
  assert(not narrowing.forgets(f, "x"))
end

--- The prefix test is the known limit [`checker/narrowing.tl`] holds a
--- TODO for: `x.f` also drops `x.foo`.
local function test_an_assignment_to_a_field_also_drops_a_longer_name()
  setup()
  assert(narrowing.forgets(narrowing.field_place("x", "f"), "x.foo"))
end

local function test_drop_removes_the_names_from_every_scope()
  setup()
  local outer: Scope = {
    vars = { ["x.f"] = true, ["x.g"] = true, x = true, ["y.f"] = true },
    narrows = { ["x.f"] = true, ["x.g"] = true, x = true },
  }
  local inner: Scope = { vars = { ["x.f"] = true, z = true }, narrows = { ["x.f"] = true } }
  narrowing.drop({ outer, inner }, narrowing.field_place("x", "f"))
  assert(outer.vars["x.f"] == nil and inner.vars["x.f"] == nil)
  assert(outer.narrows ~= nil and inner.narrows ~= nil)
  assert(outer.narrows["x.f"] == nil and inner.narrows["x.f"] == nil)
  assert(outer.narrows["x.g"] and outer.narrows["x"])
  assert(outer.vars["x.g"] and outer.vars["x"] and outer.vars["y.f"] and inner.vars["z"])
  narrowing.drop({ outer, inner }, narrowing.local_place("x"))
  assert(outer.vars["x.g"] == nil and outer.vars["x"] and outer.vars["y.f"])
end

local function test_a_type_test_gives_its_type_and_its_negation_the_rest()
  setup()
  local x = narrowing.local_place("x")
  local maybe = union(number, nothing)
  local types = { x = maybe }
  expect({ "x is number" }, (facts(narrowing.type_is(here, x, number), types)))
  expect({ "x is nil" }, (facts(narrowing.negate(here, narrowing.type_is(here, x, number)), types)))
  expect({ "x is nil" }, (facts(narrowing.type_is(here, x, nothing), types)))
  expect({ "x is number" }, (facts(narrowing.negate(here, narrowing.type_is(here, x, nothing)), types)))
end

local function test_a_value_test_gives_its_type_and_its_negation_nothing()
  setup()
  local x = narrowing.local_place("x")
  local types = { x = union(number, string_t) }
  local equals = narrowing.value_is(here, x, number)
  expect({ "x == number" }, (facts(equals, types)))
  expect({ "x == number|string (widened)" }, (facts(narrowing.negate(here, equals), types)))
end

local function test_facts_are_keyed_by_place()
  setup()
  local guard = narrowing.both(here,
    narrowing.type_is(here, narrowing.local_place("x"), number),
    narrowing.type_is(here, narrowing.field_place("r", "a"), nothing))
  expect({ "r.a == nil", "x == number" }, (facts(guard, {
    x = union(number, nothing), ["r.a"] = union(number, nothing),
  })))
end

local function test_both_intersects_what_the_same_place_is_told_twice()
  setup()
  local x = narrowing.local_place("x")
  local guard = narrowing.both(here,
    narrowing.type_is(here, x, union(number, string_t)),
    narrowing.negate(here, narrowing.type_is(here, x, string_t)))
  expect({ "x is number" }, (facts(guard, { x = union(number, string_t, nothing) })))
end

local function test_a_type_and_a_value_fact_together_are_both_value_facts()
  setup()
  local guard = narrowing.both(here,
    narrowing.type_is(here, narrowing.local_place("x"), number),
    narrowing.value_is(here, narrowing.local_place("y"), string_t))
  expect({ "x == number", "y == string" }, (facts(guard, {
    x = union(number, nothing), y = union(string_t, nothing),
  })))
end

local function test_either_keeps_what_both_sides_say_of_a_place()
  setup()
  local x = narrowing.local_place("x")
  local y = narrowing.local_place("y")
  local types = { x = union(number, string_t, nothing), y = union(number, nothing) }
  local same = narrowing.either(here, narrowing.type_is(here, x, number), narrowing.type_is(here, x, string_t))
  expect({ "x is string|number" }, (facts(same, types)))
  local apart = narrowing.either(here, narrowing.type_is(here, x, number), narrowing.type_is(here, y, number))
  expect({}, (facts(apart, types)))
end

local function test_an_or_with_a_side_that_gives_nothing_counts_it_as_truthy()
  setup()
  local x = narrowing.local_place("x")
  local types = { x = union(number, nothing) }
  -- `x or d` is not told by `x` alone: only its falsy side is.
  local guard = narrowing.either(here, narrowing.type_is(here, x, number), nil)
  expect({ "x is nil" }, (facts(guard, types)))
  assert(narrowing.negate(here, nil) == nil)
  assert(narrowing.both(here, nil, nil) == nil)
  expect({}, (facts(narrowing.truthy, types)))
  expect({}, (facts(nil, types)))
  expect({ "x == number" }, (facts(narrowing.both(here, narrowing.type_is(here, x, number), nil), types)))
end

local function test_a_conjunction_with_a_truthy_side_is_told_by_the_other()
  setup()
  local x = narrowing.local_place("x")
  local types = { x = union(number, nothing) }
  local guard = narrowing.both(here, narrowing.type_is(here, x, number), narrowing.truthy)
  expect({ "x is number" }, (facts(guard, types)))
  expect({ "x is nil" }, (facts(narrowing.negate(here, guard), types)))
  -- A disjunction with a truthy side is told by its negation alone.
  expect({ "x is nil" }, (facts(narrowing.either(here, narrowing.type_is(here, x, number), narrowing.truthy), types)))
end

local function test_a_negation_of_a_negation_is_the_guard_itself()
  setup()
  local x = narrowing.local_place("x")
  local types = { x = union(number, nothing) }
  local guard = narrowing.type_is(here, x, number)
  local once = narrowing.negate(here, guard)
  local twice = narrowing.negate(here, once)
  expect({ "x is number" }, (facts(guard, types)))
  expect({ "x is nil" }, (facts(once, types)))
  expect({ "x is number" }, (facts(twice, types)))
  expect({ "x is nil" }, (facts(narrowing.negate(here, twice), types)))
end

local function test_an_or_of_a_type_fact_and_a_value_fact_is_a_value_fact()
  setup()
  local x = narrowing.local_place("x")
  local types = { x = union(number, string_t, nothing) }
  local mixed = narrowing.either(here, narrowing.type_is(here, x, number), narrowing.value_is(here, x, nothing))
  expect({ "x == nil|number" }, (facts(mixed, types)))
  local values = narrowing.either(here, narrowing.value_is(here, x, number), narrowing.value_is(here, x, nothing))
  expect({ "x == nil|number" }, (facts(values, types)))
end

local function test_a_joined_union_test_with_an_absent_side_gives_nothing()
  setup()
  local x = narrowing.local_place("x")
  local types = { x = union(number, nothing) }
  local test = narrowing.type_is(here, x, number)
  -- `either` counts the absent side as truthy; [`any_of`] leaves it absent.
  expect({ "x is nil" }, (facts(narrowing.either(here, test, nil), types)))
  expect({}, (facts(narrowing.any_of(here, test, nil), types)))
  expect({}, (facts(narrowing.any_of(here, nil, test), types)))
end

local function test_the_negation_of_a_conjunction_is_the_disjunction_of_negations()
  setup()
  local x = narrowing.local_place("x")
  local y = narrowing.local_place("y")
  local types = { x = union(number, nothing), y = union(number, nothing) }
  local both = narrowing.both(here, narrowing.type_is(here, x, number), narrowing.type_is(here, y, number))
  expect({}, (facts(narrowing.negate(here, both), types)))
  local either = narrowing.either(here, narrowing.type_is(here, x, nothing), narrowing.type_is(here, y, nothing))
  expect({ "x == number", "y == number" }, (facts(narrowing.negate(here, either), types)))
end

local function test_none_of_negates_each_condition_of_the_branches_before_it()
  setup()
  local x = narrowing.local_place("x")
  local y = narrowing.local_place("y")
  local types = { x = union(number, nothing), y = union(number, nothing) }
  local blocks: {Node} = {
    { kind = "if_block", exp = { kind = "op", guard = narrowing.type_is(here, x, nothing) } },
    { kind = "if_block", exp = { kind = "op", guard = narrowing.type_is(here, y, nothing) } },
    { kind = "if_block" },
  }
  expect({ "x is number" }, (facts(narrowing.none_of(here, blocks, 1), types)))
  expect({ "x == number", "y == number" }, (facts(narrowing.none_of(here, blocks, 2), types)))
  -- An `else` has no condition and adds none: the facts stay type-based.
  expect({ "x is number" }, (facts(narrowing.none_of(here, { blocks[1], blocks[3] }, 2), types)))
  expect({ "x == number", "y == number" }, (facts(narrowing.none_of(here, blocks, 3), types)))
end

local function test_a_local_the_checker_cannot_resolve_is_invalid()
  setup()
  local x = narrowing.local_place("x")
  expect({ "x is invalid" }, (facts(narrowing.type_is(here, x, number), {})))
  expect({ "x == invalid" }, (facts(narrowing.negate(here, narrowing.type_is(here, x, number)), {})))
end

local function test_a_field_the_checker_cannot_resolve_gives_nothing()
  setup()
  local f = narrowing.field_place("r", "a")
  expect({}, (facts(narrowing.type_is(here, f, number), {})))
  expect({}, (facts(narrowing.negate(here, narrowing.type_is(here, f, number)), {})))
end

local function test_a_test_the_type_can_never_pass_is_refused_or_warned()
  setup()
  local x = narrowing.local_place("x")
  local types = { x = string_t }
  local positive, world = facts(narrowing.type_is(here, x, number), types)
  expect({ "x is invalid" }, positive)
  expect({ "x:string:number" }, world.refused)
  assert(#world.warned == 0)
  local negative, other = facts(narrowing.negate(here, narrowing.type_is(here, x, number)), types)
  expect({ "x == invalid" }, negative)
  expect({ "x:string:number" }, other.warned)
  assert(#other.refused == 0)
end

local function test_a_test_the_type_always_passes_is_taken_as_it_stands()
  setup()
  local x = narrowing.local_place("x")
  local held, world = facts(narrowing.type_is(here, x, union(number, string_t)), { x = number })
  expect({ "x is number|string" }, held)
  assert(#world.refused == 0 and #world.warned == 0)
end

local function test_a_type_variable_is_not_narrowed_by_a_negation()
  setup()
  local x = narrowing.local_place("x")
  local variable_t = ty("typevar")
  expect({ "x is number" }, (facts(narrowing.type_is(here, x, number), { x = variable_t })))
  expect({ "x == typevar (widened)" },
    (facts(narrowing.negate(here, narrowing.type_is(here, x, number)), { x = variable_t })))
end

local function test_a_union_of_members_joined_by_any_of_keeps_the_last_pair()
  setup()
  -- `x is string | number | nil` is built as `(x is number) or (x is nil)`
  -- once the first member is lost: the known limit
  -- [`checker/narrowing.tl`] holds a TODO for.
  local x = narrowing.local_place("x")
  local types = { x = union(string_t, number, nothing) }
  local guard = narrowing.any_of(here, narrowing.type_is(here, x, number), narrowing.type_is(here, x, nothing))
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
local function errors_of(body: string): {string}
  setup()
  local env = assert(built.new_env({ defaults = {
    feat_lax = "off", gen_compat = "off", gen_target = "5.4",
  } }))
  local source = prelude .. body .. after
  local ok, raised = pcall(function(): {string}
    local result = built.check_string(source, env, "probe.tl", "tl")
    assert(#result.syntax_errors == 0, "does not parse: " .. body)
    local found: {string} = {}
    for _, e in ipairs(result.type_errors) do
      found[#found + 1] = tostring(e.y - lines_in(prelude)) .. ": " .. e.msg
    end
    return found
  end)
  if not ok then
    return { "raised: " .. tostring(raised):gsub("^[^:]*:%d+: ", "") }
  end
  return raised as {string}
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
  accepted("if q.a then\n  p.a = nil\n  print(q.a + 1)\nend")
  accepted("if q.a then\n  touch(q)\n  print(q.a + 1)\nend")
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

local function test_a_loop_keeps_a_field_it_assigns_at_its_head()
  accepted("if q.a then\n  while maybe() do\n    print(q.a + 1)\n    q.a = nil\n  end\nend")
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
