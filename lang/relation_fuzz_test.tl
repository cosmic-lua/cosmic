--- Fuzz properties for the relation ([`lang.relation`]), over the random types of
--- [`lang.types_programs`] and the types made by weakening and strengthening them. Every type is
--- below itself; `never` is below every type and nothing else is below it; only `nil` and a type with
--- the nil flag admit nil; a `mut` collection is invariant and a view is not below it; the laws of a
--- union hold (a type is below its union, a union is below a type when each member is, a type is below
--- a union when below a member); the relation is transitive; a refusal comes with a reason that
--- agrees with the answer, names a pair that is not related, and is the same in a judge that has
--- settled other pairs and in another store. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).
local Fuzz = require("build.fuzz")
local Programs = require("lang.relation_programs")
local Relation = require("lang.relation")
local Test = require("cosmic.test")
local Types = require("lang.types")
local TypesPrograms = require("lang.types_programs")

Test.policy{ cpu_features = true }

local function gen_draws(src: Fuzz.Source): string
  local out: mut {string} = {}
  while Fuzz.more(src, #out, 120) do
    out[#out + 1] = tostring(src:int(0, 99))
  end
  return table.concat(out, " ")
end

local type Type = Types.Type
local type World = Programs.World

-- Weakening and strengthening ---------------------------------------------------------------------

local weaken: function(w: World, t: Type, salt: integer): Type
local strengthen: function(w: World, t: Type, salt: integer): Type

--- The first argument of a use of a declaration the fuzz made with one.
local function first_argument(t: Type): Type
  assert(t.tag == "named")
  local argument = t.args[1]
  assert(argument ~= nil)
  return argument
end

local function use(w: World, name: string, args?: {Type}): Type
  return Programs.named(w, name, args)
end

--- `f` with each parameter type changed by `on_param` and each type it answers by `on_item`. A
--- generic function is as it was, since only an identical one is related to it.
local function map_fn(
    w: World, f: Types.Fn, on_param: function(Type): Type, on_item: function(Type): Type
): Type
  if #f.tparams > 0 then
    return f
  end
  local params: mut {Types.Param} = {}
  for i, p in ipairs(f.params) do
    params[i] = { type = on_param(p.type), omittable = p.omittable }
  end
  local rest = f.rest
  local rets: mut {Types.Alt} = {}
  for i, alt in ipairs(f.rets) do
    local items: mut {Type} = {}
    for k, item in ipairs(alt.items) do
      items[k] = on_item(item)
    end
    local tail = alt.tail
    local narrows = alt.narrows
    rets[i] = {
      items = items,
      tail = tail ~= nil and on_item(tail) or nil,
      -- `v is T` is invariant in T; `asserts v is T` is covariant.
      narrows = if narrows ~= nil then {
        param = narrows.param, to = narrows.asserts and on_item(narrows.to) or narrows.to, asserts = narrows.asserts,
      } else nil end,
    }
  end
  return w.store:fn({
    params = params, rest = rest ~= nil and on_param(rest) or nil, rets = rets,
  })
end

--- A type above `t`, by one of the rules of the relation chosen by `salt`: `integer` into `number`, an
--- enum into `string`, a class into an interface it lists, a record with an array part into the
--- view, a `mut` collection into a view, an element, a value or a return weakened, a parameter
--- strengthened, a union weakened by member, or `t` made optional.
weaken = function(w: World, t: Type, salt: integer): Type
  local s = w.store
  local next_salt = salt * 7 + 3
  local result: Type = t
  if (t.atom == true) then
    local tag = t.tag
    if tag == "integer" then
      result = s.number
    elseif tag == "true" or tag == "false" then
      result = s.boolean
    elseif tag == "nil" then
      result = s:optional(s.string)
    elseif tag == "never" then
      result = salt % 2 == 0 and s.string or s:array(s.integer)
    end
  elseif (t.tag == "named") then
    local name = t.decl.name
    if t.decl.kind == "enum" then
      result = s.string
    elseif name == "File" then
      result = use(w, "Stream.Reader")
    elseif name == "Duplex" then
      result = use(w, if salt % 2 == 0 then "ReadWriter" else "Stream.Reader" end)
    elseif name == "KeyEvent" or name == "MouseEvent" then
      result = use(w, "Event")
    elseif name == "Ranked" then
      result = use(w, "Ordered")
    elseif name == "Node" then
      result = s:array(t)
    elseif name == "IntSource" then
      result = use(w, "Source", { s.integer })
    elseif name == "Box" then
      result = use(w, "Source", { first_argument(t) })
    elseif name == "Wrapped" then
      result = use(w, "Source", { s:array(first_argument(t)) })
    elseif name == "Ring" then
      result = s:array(first_argument(t))
    end
  elseif (t.tag == "array") then
    result = s:array(weaken(w, t.element, next_salt))
  elseif (t.tag == "map") then
    result = s:map(t.key, weaken(w, t.value, next_salt))
  elseif (t.tag == "union") then
    local members: mut {Type} = {}
    for i, m in ipairs(t.members) do
      members[i] = weaken(w, m, next_salt + i)
    end
    if t.nilable then
      members[#members + 1] = s:atom("nil")
    end
    result = s:union(members)
  elseif (t.tag == "fn") then
    result = map_fn(w, t, function(p: Type): Type
      return strengthen(w, p, next_salt)
    end, function(item: Type): Type
      return weaken(w, item, next_salt)
    end)
    if #t.rets == 0 and #t.tparams == 0 then
      -- a function that never returns is below the same function that answers nothing
      local params: mut {Types.Param} = {}
      for i, p in ipairs(t.params) do
        params[i] = { type = p.type, omittable = p.omittable }
      end
      result = s:fn({ params = params, rest = t.rest })
    end
  end
  if salt % 5 == 0 and result.tag ~= "any" then
    result = s:optional(result)
  end
  return result
end

--- A type below `t`, as [`weaken`] is above it.
strengthen = function(w: World, t: Type, salt: integer): Type
  local s = w.store
  local next_salt = salt * 7 + 3
  if (t.atom == true) then
    local tag = t.tag
    if tag == "number" then
      return s.integer
    elseif tag == "boolean" then
      return s:atom("true")
    elseif tag == "string" then
      return use(w, "Color")
    end
    return t
  elseif (t.tag == "named") then
    local name = t.decl.name
    if name == "Stream.Reader" then
      return use(w, "File")
    elseif name == "ReadWriter" then
      return use(w, "Duplex")
    elseif name == "Event" then
      return use(w, if salt % 2 == 0 then "KeyEvent" else "MouseEvent" end)
    elseif name == "Ordered" then
      return use(w, "Ranked")
    elseif name == "Source" and t.args[1] == s.integer then
      return use(w, "IntSource")
    elseif name == "Source" then
      return use(w, "Box", { first_argument(t) })
    end
    return t
  elseif (t.tag == "array") then
    if t.mut then
      return t
    end
    if salt % 2 == 0 then
      return s:array(t.element, true)
    end
    return s:array(strengthen(w, t.element, next_salt))
  elseif (t.tag == "map") then
    if t.mut then
      return t
    end
    if salt % 2 == 0 then
      return s:map(t.key, t.value, true)
    end
    return s:map(t.key, strengthen(w, t.value, next_salt))
  elseif (t.tag == "union") then
    if t.nilable and #t.members > 0 and salt % 2 == 0 then
      return s:union(t.members)
    end
    local member = t.members[1]
    assert(member ~= nil)
    return strengthen(w, member, next_salt)
  elseif (t.tag == "fn") then
    return map_fn(w, t, function(p: Type): Type
      return weaken(w, p, next_salt)
    end, function(item: Type): Type
      return strengthen(w, item, next_salt)
    end)
  end
  return t
end

-- The generator of the relation's own types --------------------------------------------------------

--- Where the choices of [`relation_type`] come from, as [`lang.types_programs`]'s do: an integer is a
--- choice, and one past the end of the draws is the first.
local record Cursor
  values: {integer}
  mut at: integer
  w: World
  --- Whether a type variable of the two binders of [`binders`] may be drawn.
  vars: boolean
  --- Whether `invalid` may be drawn.
  mistakes: boolean
end

local function pick(c: Cursor, n: integer): integer
  c.at = c.at + 1
  local v = c.values[c.at]
  if v == nil then
    return 0
  end
  return v % n
end

--- The binders that the variables of [`relation_type`] name, the outer one first: a bounded variable and one
--- without a bound, then two bounded by other interfaces.
local function binders(w: World): {{Types.TParam}}
  return {
    { { bound = use(w, "Stream.Reader") }, {} },
    { { bound = use(w, "Event") }, { bound = use(w, "Ordered") } },
  }
end

local LISTED <const>: {string} = { "Box", "Wrapped", "Gen", "Source", "List" }
local PLAIN <const>: {string} = {
  "File", "Duplex", "Event", "KeyEvent", "MouseEvent", "Stream.Reader", "Ranked", "Ordered", "ReadWriter", "Color",
  "Node", "IntSource", "Quiet", "Loud", "Handle",
}

--- A random type over the fixture: generic listings (`Source`, `Box`, `Wrapped`, `Gen`, `Ring`), functions with
--- omittable parameters, a rest, several or tailed alternatives and narrowing declarations, `mut`
--- collections, unions, and, where `c` allows, type variables and `invalid`.
local function relation_type(c: Cursor, depth: integer): Type
  local s = c.w.store
  local n = pick(c, if depth >= 3 then 16 else 29 end)
  if n <= 2 then
    return s.integer
  elseif n == 3 then
    return s.number
  elseif n == 4 then
    return s.string
  elseif n == 5 then
    return s:atom("nil")
  elseif n == 6 then
    return s.never
  elseif n == 7 then
    return use(c.w, PLAIN[pick(c, #PLAIN) + 1])
  elseif n == 8 then
    return s.boolean
  elseif n == 9 then
    return s:atom(if pick(c, 2) == 0 then "true" else "false" end)
  elseif n == 10 then
    return s.any
  elseif n == 11 then
    if c.vars then
      return s:var(pick(c, 2), pick(c, 2))
    end
    return s.string
  elseif n == 12 then
    return c.mistakes and s.invalid or s.integer
  elseif n == 13 then
    return use(c.w, LISTED[pick(c, #LISTED) + 1], { relation_type(c, depth + 1) })
  elseif n == 14 then
    return use(c.w, "Ring", { relation_type(c, depth + 1) })
  elseif n == 15 then
    return use(c.w, "Pair", { relation_type(c, depth + 1), relation_type(c, depth + 1) })
  elseif n == 16 then
    return s:optional(relation_type(c, depth + 1))
  elseif n == 17 then
    return s:array(relation_type(c, depth + 1))
  elseif n == 18 then
    return s:array(relation_type(c, depth + 1), true)
  elseif n == 19 then
    local key = relation_type(c, depth + 1)
    return s:map(key, relation_type(c, depth + 1))
  elseif n == 20 then
    local key = relation_type(c, depth + 1)
    return s:map(key, relation_type(c, depth + 1), true)
  elseif n <= 22 then
    return s:union({ relation_type(c, depth + 1), relation_type(c, depth + 1) })
  end
  local params: mut {Types.Param} = {}
  for i = 1, pick(c, 3) do
    params[i] = { type = relation_type(c, depth + 1), omittable = pick(c, 4) == 0 }
  end
  local rest: Type?
  if pick(c, 5) == 0 then
    rest = relation_type(c, depth + 1)
  end
  local alts: {Types.Alt} = {}
  local shape = pick(c, 6)
  if shape == 0 then
    alts = {}
  elseif shape == 1 and #params > 0 then
    alts = { { items = {}, narrows = { param = pick(c, #params) + 1, to = relation_type(c, depth + 1),
      asserts = pick(c, 2) == 0 } } }
  elseif shape == 2 then
    alts = { { items = { relation_type(c, depth + 1), relation_type(c, depth + 1) } },
      { items = { relation_type(c, depth + 1), relation_type(c, depth + 1) } } }
  elseif shape == 3 then
    alts = { { items = { relation_type(c, depth + 1) }, tail = relation_type(c, depth + 1) } }
  elseif shape == 4 then
    alts = { { items = {} } }
  else
    alts = { { items = { relation_type(c, depth + 1) } } }
  end
  return s:fn({ params = params, rest = rest, rets = alts })
end

--- `count` types, then the variables and some interfaces that a test of scopes needs.
local function relation_pool(w: World, draws: {integer}, count: integer, vars: boolean, mistakes: boolean): {Type}
  local c: Cursor = { values = draws, at = 0, w = w, vars = vars, mistakes = mistakes }
  local out: {Type} = {}
  local seen: {integer: boolean} = {}
  local function add(t: Type)
    if not seen[t.id] then
      seen[t.id] = true
      out[#out + 1] = t
    end
  end
  for _ = 1, count do
    add(relation_type(c, 0))
  end
  if vars then
    for depth = 0, 1 do
      for index = 0, 1 do
        add(w.store:var(depth, index))
      end
    end
    add(w.store:optional(w.store:var(0, 0)))
    add(w.store:optional(w.store:var(1, 0)))
    add(use(w, "Stream.Reader"))
    add(use(w, "File"))
    add(use(w, "Ordered"))
    add(use(w, "Event"))
  end
  return out
end

--- Draws for [`relation_pool`]: enough for a few dozen types.
local function gen_long(src: Fuzz.Source): string
  local out: mut {string} = {}
  while Fuzz.more(src, #out, 500) do
    out[#out + 1] = tostring(src:int(0, 99))
  end
  return table.concat(out, " ")
end

-- The pool ----------------------------------------------------------------------------------------

--- A few types that the draws build, each weakened and strengthened, and some that every pool
--- has.
local function pool(w: World, draws: {integer}): {Type}
  local s = w.store
  local out: {Type} = {}
  local seen: {integer: boolean} = {}
  local function add(t: Type)
    if not seen[t.id] then
      seen[t.id] = true
      out[#out + 1] = t
    end
  end
  local function slice(from: integer): {integer}
    local part: mut {integer} = {}
    for i = from, #draws do
      part[#part + 1] = draws[i]
    end
    return part
  end
  local salt = draws[1] or 0
  local count = 1 + (draws[2] or 0) % 3
  for k = 1, count do
    local base = TypesPrograms.generate(s, w.fixture, slice(3 + (k - 1) * 13))
    add(base)
    local up = weaken(w, base, salt + k)
    add(up)
    add(weaken(w, up, salt + k + 1))
    local down = strengthen(w, base, salt + k)
    add(down)
    add(strengthen(w, down, salt + k + 1))
    add(s:optional(base))
  end
  -- Some types of the relation's own generator, which reach listings, rest parameters and narrowing.
  local own = relation_pool(w, slice(3 + count * 13), 3, false, false)
  for _, base in ipairs(own) do
    add(base)
    add(weaken(w, base, salt))
    add(strengthen(w, base, salt))
  end
  add(s.never)
  add(s:atom("nil"))
  add(s.integer)
  add(s.number)
  add(s.string)
  add(s.any)
  add(use(w, "Node"))
  add(use(w, "File"))
  add(use(w, "Stream.Reader"))
  add(use(w, "Color"))
  return out
end

--- The labels a pair of types reaches.
local function label_pair(a: Type, b: Type, holds: boolean)
  Fuzz.label(if holds then "holds" else "refused" end)
  Fuzz.label(tostring(a.tag) .. " below")
  if a.tag ~= b.tag then
    Fuzz.label("different forms")
  end
  if holds and a ~= b then
    Fuzz.label("related and distinct")
  end
end

--- The refusal of `a` against `b` in a line, for a report.
local function traced(w: World, a: Type, b: Type): string
  local r = w.judge:refuse(a, b)
  if r == nil then
    return "no refusal"
  end
  return Relation.trace(r)
end

-- The properties --------------------------------------------------------------------------------------

local function test_a_type_is_below_itself_and_never_is_below_every_type_and_only_it(tmp: string)
  Fuzz.run({
    name = "relation reflexive and bottom",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local w = Programs.world()
      local draws = TypesPrograms.numbers(input)
      for _, t in ipairs(pool(w, draws)) do
        if not w.judge:subtype(t, t) then
          return false, Types.display(t) .. " is not below itself"
        end
        if w.judge:refuse(t, t) ~= nil then
          return false, Types.display(t) .. " is refused itself"
        end
        if not w.judge:subtype(w.store.never, t) then
          return false, "never is not below " .. Types.display(t)
        end
        local below_never = w.judge:subtype(t, w.store.never)
        if below_never ~= (t == w.store.never) then
          return false, Types.display(t) .. (if below_never then " is" else " is not" end) .. " below never"
        end
        if not w.judge:accepts(t, w.store.any) then
          return false, Types.display(t) .. " is not an argument for a parameter declared any"
        end
        Fuzz.label(t.tag)
      end
      return true, ""
    end,
    requires = { "array", "map", "union", "named", "fn", "integer", "any" },
  })
end

--- Whether `t` admits nil by its form.
local function admits_nil(t: Type): boolean
  if t.tag == "nil" then
    return true
  end
  return (t.tag == "union") and t.nilable
end

local function test_only_nil_and_a_type_with_the_nil_flag_admit_nil(tmp: string)
  Fuzz.run({
    name = "relation nil",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local w = Programs.world()
      local s = w.store
      local null = s:atom("nil")
      local draws = TypesPrograms.numbers(input)
      for _, t in ipairs(pool(w, draws)) do
        local below = w.judge:subtype(null, t)
        if below ~= admits_nil(t) then
          return false, "nil is" .. (if below then "" else " not" end) .. " below " .. Types.display(t)
        end
        if w.judge:subtype(null, s:non_nil(t)) then
          return false, "nil is below " .. Types.display(t) .. " without its nil"
        end
        local maybe = s:optional(t)
        if t.tag ~= "any" and not w.judge:subtype(null, maybe) then
          return false, "nil is not below " .. Types.display(maybe)
        end
        if t.tag ~= "any" and not w.judge:subtype(t, maybe) then
          return false, Types.display(t) .. " is not below " .. Types.display(maybe)
        end
        if t.tag ~= "any" and t.tag ~= "never" and t.tag ~= "nil" and not admits_nil(t) and
            w.judge:subtype(maybe, t) then
          return false, Types.display(maybe) .. " is below " .. Types.display(t)
        end
        -- Only as an argument to any does a value, nil among them, reach it.
        if not w.judge:accepts(null, s.any) or w.judge:subtype(null, s.any) then
          return false, "nil and any"
        end
        Fuzz.label(if admits_nil(t) then "admits" else "does not admit" end)
        Fuzz.label(t.tag)
      end
      return true, ""
    end,
    requires = { "admits", "does not admit", "named", "fn", "array", "union" },
  })
end

local function test_a_mut_collection_is_invariant_and_a_view_is_not_below_it(tmp: string)
  Fuzz.run({
    name = "relation mut",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local w = Programs.world()
      local s = w.store
      local j = w.judge
      local draws = TypesPrograms.numbers(input)
      local types = pool(w, draws)
      for i, e1 in ipairs(types) do
        for k, e2 in ipairs(types) do
          local who = Types.display(e1) .. " and " .. Types.display(e2)
          local same = e1 == e2
          if j:subtype(s:array(e1, true), s:array(e2, true)) ~= same then
            return false, "mut arrays of " .. who .. (if same then " are refused" else " are related" end)
          end
          if j:subtype(s:array(e1), s:array(e2, true)) then
            return false, "a view of " .. Types.display(e1) .. " is below mut of " .. Types.display(e2)
          end
          local covariant = j:subtype(e1, e2)
          if j:subtype(s:array(e1), s:array(e2)) ~= covariant or j:subtype(s:array(e1, true), s:array(e2)) ~= covariant then
            return false, "views of " .. who .. " are not covariant"
          end
          -- the key is invariant, the value is not, whether or not the collection is mut
          if j:subtype(s:map(e1, e1, true), s:map(e2, e2, true)) ~= same then
            return false, "mut maps of " .. who .. (if same then " are refused" else " are related" end)
          end
          if j:subtype(s:map(e1, e1), s:map(e2, e2, true)) then
            return false, "a view of a map is below a mut map"
          end
          if j:subtype(s:map(e1, e1), s:map(e2, e2)) ~= same then
            return false, "map views with the keys of " .. who .. " are " .. (if same then "refused" else "related" end)
          end
          if j:subtype(s:map(e1, e1), s:map(e1, e2)) ~= covariant then
            return false, "map views of " .. who .. " are not covariant in the value"
          end
          if j:subtype(s:map(e1, e1, true), s:map(e1, e2)) ~= covariant then
            return false, "a mut map is not below the view of " .. who
          end
          if j:subtype(s:map(e1, e1, true), s:map(e1, e2, true)) ~= same then
            return false, "mut maps of one key and the values " .. who
          end
          Fuzz.label(if same then "same elements" else "different elements" end)
          Fuzz.label(if covariant then "related elements" else "unrelated elements" end)
          if i == k then
            Fuzz.label("the same type twice")
          end
        end
      end
      return true, ""
    end,
    requires = { "same elements", "different elements", "related elements", "unrelated elements" },
  })
end

local function test_the_laws_of_a_union_hold(tmp: string)
  Fuzz.run({
    name = "relation union",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local w = Programs.world()
      local s = w.store
      local j = w.judge
      local draws = TypesPrograms.numbers(input)
      local types = pool(w, draws)
      for _, a in ipairs(types) do
        for _, b in ipairs(types) do
          if a.tag ~= "any" and b.tag ~= "any" then
            local u = s:union({ a, b })
            local who = Types.display(a) .. " | " .. Types.display(b)
            if not j:subtype(a, u) or not j:subtype(b, u) then
              return false, "a member is not below " .. who
            end
            for _, c in ipairs(types) do
              local each = j:subtype(a, c) and j:subtype(b, c)
              if j:subtype(u, c) ~= each then
                return false, who .. " is " .. (if each then "not " else "" end) .. "below " .. Types.display(c) ..
                  ", though its members are " .. (if each then "" else "not " end) .. "both"
              end
              if c.tag ~= "boolean" and not ((c.tag == "union")) then
                -- a type that is no union is below a union when below a member, and not otherwise
                -- (the pair `true` and `false` is the one `boolean`)
                if j:subtype(c, u) ~= (j:subtype(c, a) or j:subtype(c, b)) and not (c.tag == "true" or c.tag == "false") then
                  return false, Types.display(c) .. " against " .. who .. ": below a member and not the union, or the reverse"
                end
              end
            end
            Fuzz.label(if a ~= b then "two members" else "one member" end)
            Fuzz.label(u.tag)
          end
          if a.tag ~= "any" then
            local maybe = s:optional(a)
            local null = s:atom("nil")
            for _, c in ipairs(types) do
              local expected = j:subtype(a, c) and j:subtype(null, c)
              if j:subtype(maybe, c) ~= expected then
                return false, Types.display(maybe) .. " against " .. Types.display(c) .. ": the nil is not read"
              end
            end
          end
        end
      end
      return true, ""
    end,
    requires = { "two members", "union" },
  })
end

local function test_the_relation_is_transitive(tmp: string)
  Fuzz.run({
    name = "relation transitive",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local w = Programs.world()
      local j = w.judge
      local draws = TypesPrograms.numbers(input)
      local types = pool(w, draws)
      for _, a in ipairs(types) do
        for _, b in ipairs(types) do
          local ab = j:subtype(a, b)
          label_pair(a, b, ab)
          if ab then
            for _, c in ipairs(types) do
              if j:subtype(b, c) then
                if not j:subtype(a, c) then
                  return false, Types.display(a) .. " is below " .. Types.display(b) .. ", which is below " ..
                    Types.display(c) .. ", and a is not below c"
                end
                if a ~= b and b ~= c and a ~= c then
                  Fuzz.label("chain")
                end
              end
            end
          end
        end
      end
      return true, ""
    end,
    requires = { "chain", "holds", "refused", "related and distinct", "different forms" },
  })
end

local function test_a_weakening_is_above_a_type_and_a_strengthening_below_it(tmp: string)
  Fuzz.run({
    name = "relation weakening",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local w = Programs.world()
      local draws = TypesPrograms.numbers(input)
      local salt = draws[1] or 0
      for k = 1, 1 + (draws[2] or 0) % 3 do
        local part: mut {integer} = {}
        for i = 3 * k, #draws do
          part[#part + 1] = draws[i]
        end
        local base = TypesPrograms.generate(w.store, w.fixture, part)
        local up = weaken(w, base, salt + k)
        local down = strengthen(w, base, salt + k)
        if not w.judge:subtype(base, up) then
          return false, Types.display(base) .. " is not below its weakening " .. Types.display(up) ..
            ": " .. traced(w, base, up)
        end
        if not w.judge:subtype(down, base) then
          return false, "the strengthening " .. Types.display(down) .. " is not below " .. Types.display(base) ..
            ": " .. traced(w, down, base)
        end
        Fuzz.label(if up ~= base then "weakened" else "not weakened" end)
        Fuzz.label(if down ~= base then "strengthened" else "not strengthened" end)
      end
      return true, ""
    end,
    requires = { "weakened", "strengthened" },
  })
end

--- Why the refusal `r` is not well formed, or "".
local function malformed(w: World, r: Relation.Refusal): string
  if r.sub.owner ~= w.store.owner or r.super.owner ~= w.store.owner then
    return "a part of another store"
  end
  if r.sub == r.super then
    return "the same type " .. Types.display(r.sub) .. " on both sides"
  end
  local code = r.code
  -- A leaf that is a comparison of two types failed that comparison, except where the rule is that
  -- the types differ (a mut collection and a generic compare by identity, not by the relation).
  local by_identity = code == "invariant_mut" or code == "invariant_key" or code == "invariant_generic" or
    code == "invariant_narrows"
  if not by_identity and w.judge:subtype(r.sub, r.super) then
    return code .. " names " .. Types.display(r.sub) .. " against " .. Types.display(r.super) .. ", which is related"
  end
  for _, step in ipairs(r.path) do
    local kind = step.kind
    local counted = kind == "member" or kind == "target_alternative" or kind == "argument" or kind == "parameter" or
      kind == "alternative" or kind == "item"
    if counted and step.index == nil then
      return "a " .. step.kind .. " step without a position"
    end
  end
  local alternatives = r.alternatives
  if code == "union_none" then
    if alternatives == nil or #alternatives == 0 then
      return "union_none without alternatives"
    end
    for _, alternative in ipairs(alternatives) do
      local first = alternative.path[1]
      if first == nil or first.kind ~= "target_alternative" then
        return "an alternative that does not begin at its member"
      end
    end
  end
  if code == "not_listed" and r.lists == nil then
    return "not_listed without what the declaration lists"
  end
  if code == "arity" and r.index == nil then
    return "arity without a position"
  end
  return ""
end

local function test_a_reason_agrees_with_the_answer_and_names_a_pair_that_is_not_related(tmp: string)
  Fuzz.run({
    name = "relation reasons",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local w = Programs.world()
      local draws = TypesPrograms.numbers(input)
      local types = pool(w, draws)
      local seen_codes: mut {string: boolean} = {}
      for _, a in ipairs(types) do
        for _, b in ipairs(types) do
          local answer = w.judge:subtype(a, b)
          local r = w.judge:refuse(a, b)
          local who = Types.display(a) .. " against " .. Types.display(b)
          if answer ~= (r == nil) then
            return false, who .. ": the answer and the reason disagree"
          end
          if r ~= nil then
            local why = malformed(w, r)
            if why ~= "" then
              return false, who .. ": " .. Relation.trace(r) .. ": " .. why
            end
            seen_codes[r.code] = true
            Fuzz.label("code " .. r.code)
          end
          local argument = w.judge:accepts(a, b)
          if argument ~= (b.tag == "any" or answer) then
            return false, who .. ": as an argument"
          end
          if (w.judge:refuse_argument(a, b) == nil) ~= argument then
            return false, who .. ": the reason for an argument disagrees"
          end
        end
      end
      return true, ""
    end,
    requires = { "code mismatch", "code nil", "code any_sink", "code nominal", "code union_none" },
  })
end

--- A store with the declarations of `origin`, loaded as the text of a type meets them, after types of its
--- own so that its ids are not another store's.
local function crowded(origin: Types.Store): Types.Store
  local store = Types.new(function(module: string, name: string): string?
    local decl = origin:find(module, name)
    return decl ~= nil and Types.encode_declaration(decl) or nil
  end)
  local _ = store:array(store:optional(store.number))
  local _ = store:map(store.string, store:array(store.integer, true))
  return store
end

local function test_a_judge_that_has_settled_other_pairs_and_another_store_agree(tmp: string)
  Fuzz.run({
    name = "relation caches and stores",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local w = Programs.world()
      local draws = TypesPrograms.numbers(input)
      local types = pool(w, draws)
      local warmed = Relation.new(w.store)
      -- Settle the pairs in the opposite order, explaining some, so that the memo holds the pairs
      -- of a different walk.
      for i = #types, 1, -1 do
        for k = #types, 1, -1 do
          if (i + k) % 2 == 0 then
            local _ = warmed:refuse(types[i], types[k])
          else
            local _ = warmed:subtype(types[i], types[k])
          end
        end
      end
      local other_store = crowded(w.store)
      local over = Relation.new(other_store)
      local there: mut {Type} = {}
      for i, t in ipairs(types) do
        local decoded, why = other_store:decode(Types.encode(t))
        if decoded == nil then
          return false, "decoding " .. Types.encode(t) .. ": " .. why
        end
        there[i] = decoded
      end
      for i, a in ipairs(types) do
        for k, b in ipairs(types) do
          local fresh = Relation.new(w.store)
          local answer = fresh:subtype(a, b)
          if warmed:subtype(a, b) ~= answer then
            return false, Types.display(a) .. " against " .. Types.display(b) .. ": a judge that settled other pairs disagrees"
          end
          if over:subtype(there[i], there[k]) ~= answer then
            return false, Types.display(a) .. " against " .. Types.display(b) .. ": another store disagrees"
          end
          local r, there_r = fresh:refuse(a, b), over:refuse(there[i], there[k])
          if (r == nil) ~= (there_r == nil) or (r ~= nil and there_r ~= nil and (r.code ~= there_r.code or
              Programs.steps(r) ~= Programs.steps(there_r))) then
            return false, Types.display(a) .. " against " .. Types.display(b) .. ": another store gives another reason"
          end
          Fuzz.label(if answer then "holds" else "refused" end)
        end
      end
      return true, ""
    end,
    requires = { "holds", "refused" },
  })
end

-- A refusal replayed ----------------------------------------------------------------------------------

--- The type a `tail` or `narrows` step reaches in the alternative, or nil.
local function in_list(alt: Types.Alt?, kind: Relation.StepKind): Type?
  if alt == nil then
    return nil
  end
  if kind == "tail" then
    return alt.tail
  end
  local narrows = alt.narrows
  if narrows ~= nil then
    return narrows.to
  end
  return nil
end

--- Follows `path` from the pair `a` and `b` and answers the pair it reaches, or nil and why not. `start` is the
--- alternative of the function given where the path begins inside a list. "skip" says that the
--- replay does not follow that step, and is not a failure.
local function replay(
    w: World, a: Type, b: Type, path: {Relation.Step}, start: Types.Alt?
): Type?, Type?, string
  local s = w.store
  local given_alt: Types.Alt? = start
  local wanted_alt: Types.Alt?
  for _, step in ipairs(path) do
    local kind = step.kind
    local index = step.index
    if kind == "member" then
      if not ((a.tag == "union")) or index == nil then
        return nil, nil, "member of a type that is no union"
      end
      local member = a.members[index]
      if member == nil then
        return nil, nil, "a member that is not there"
      end
      a = member
    elseif kind == "nil" then
      a = s:atom("nil")
    elseif kind == "target_alternative" then
      if (b.tag == "union") and index ~= nil then
        local member = b.members[index]
        if member == nil then
          return nil, nil, "a member that is not there"
        end
        b = member
      elseif (b.tag == "fn") and index ~= nil then
        wanted_alt = b.rets[index]
      else
        return nil, nil, "an alternative of a type that has none"
      end
    elseif kind == "element" then
      if (a.tag == "array") and (b.tag == "array") then
        local from, to = a.element, b.element
        a, b = from, to
      else
        return nil, nil, "the element of types that are no arrays"
      end
    elseif kind == "array_part" then
      local body = if a.tag == "named" then a.decl.body else nil end
      if (a.tag == "named") and body ~= nil and (b.tag == "array") then
        local part = body.array
        if part == nil then
          return nil, nil, "an array part that is not there"
        end
        if #a.args > 0 then
          return nil, nil, "skip"
        end
        a, b = part, b.element
      else
        return nil, nil, "the array part of a type that has none"
      end
    elseif kind == "key" or kind == "value" then
      if (a.tag == "map") and (b.tag == "map") then
        local from, to = a.key, b.key
        if kind == "value" then
          from, to = a.value, b.value
        end
        a, b = from, to
      else
        return nil, nil, "the " .. kind .. " of types that are no maps"
      end
    elseif kind == "argument" then
      if (a.tag == "named") and (b.tag == "named") and index ~= nil then
        local from, to = a.args[index], b.args[index]
        if from == nil or to == nil then
          return nil, nil, "an argument that is not there"
        end
        a, b = from, to
      else
        return nil, nil, "the argument of types that are no uses"
      end
    elseif kind == "parameter" or kind == "rest" then
      if (a.tag == "fn") and (b.tag == "fn") then
        -- The roles swap: the parameter of the function wanted is below the one given.
        local from: Type?
        local to: Type?
        if index ~= nil then
          local given, wanted = a.params[index], b.params[index]
          from = if wanted ~= nil then wanted.type else b.rest end
          to = if given ~= nil then given.type else a.rest end
        end
        if from == nil or to == nil then
          return nil, nil, "a parameter that is not there"
        end
        a, b = from, to
      else
        return nil, nil, "the parameter of types that are no functions"
      end
    elseif kind == "alternative" then
      if (a.tag == "fn") and (b.tag == "fn") and index ~= nil then
        given_alt = a.rets[index]
        wanted_alt = if #b.rets == 1 then b.rets[1] else nil end
      else
        return nil, nil, "an alternative of types that are no functions"
      end
    elseif kind == "item" then
      if given_alt ~= nil and wanted_alt ~= nil and index ~= nil then
        local from, to = given_alt.items[index], wanted_alt.items[index]
        a, b = from, to
        given_alt, wanted_alt = nil, nil
      else
        return nil, nil, "skip"
      end
    elseif kind == "tail" or kind == "narrows" then
      local from = in_list(given_alt, kind)
      local to = in_list(wanted_alt, kind)
      if from ~= nil and to ~= nil then
        a, b = from, to
        given_alt, wanted_alt = nil, nil
      else
        return nil, nil, "skip"
      end
    else
      return nil, nil, "skip"
    end
  end
  return a, b, ""
end

local function test_the_path_of_a_refusal_leads_to_the_pair_it_names(tmp: string)
  Fuzz.run({
    name = "relation refusal paths",
    dir = tmp,
    gen = gen_long,
    check = function(input: string): boolean, string
      local w = Programs.world()
      local types = relation_pool(w, TypesPrograms.numbers(input), 24, false, false)
      for _, a in ipairs(types) do
        for _, b in ipairs(types) do
          local r = w.judge:refuse(a, b)
          if r ~= nil then
            local x, y, why = replay(w, a, b, r.path, nil)
            local who = Types.display(a) .. " against " .. Types.display(b) .. ": " .. Relation.trace(r)
            if x ~= nil and y ~= nil then
              Fuzz.label("replayed")
              if x ~= r.sub or y ~= r.super then
                return false, who .. "; the path leads to " .. Types.display(x) .. " and " .. Types.display(y)
              end
            elseif why ~= "skip" then
              return false, who .. "; the path cannot be followed: " .. why
            end
            local alternatives = r.alternatives
            if alternatives ~= nil and x ~= nil and y ~= nil then
              -- The alternatives begin at the pair the refusal names, and a list begins at the
              -- alternative of the function given.
              local start: Types.Alt?
              local last = r.path[#r.path]
              local at = last ~= nil and last.index or nil
              if r.code == "return_unmatched" and at ~= nil and (x.tag == "fn") then
                start = x.rets[at]
              end
              for k, alternative in ipairs(alternatives) do
                local ax, ay, awhy = replay(w, r.sub, r.super, alternative.path, start)
                if ax ~= nil and ay ~= nil then
                  Fuzz.label("replayed an alternative")
                  if ax ~= alternative.sub or ay ~= alternative.super then
                    return false, who .. "; alternative " .. tostring(k) .. " leads to " .. Types.display(ax) .. " and " ..
                      Types.display(ay)
                  end
                elseif awhy ~= "skip" then
                  return false, who .. "; alternative " .. tostring(k) .. " cannot be followed: " .. awhy
                end
              end
            end
            Fuzz.label("code " .. r.code)
          end
        end
      end
      return true, ""
    end,
    requires = { "replayed", "replayed an alternative", "code union_none", "code return_unmatched",
      "code not_listed", "code arity", "code invariant_mut", "code invariant_generic" },
  })
end

-- Variables under binders -----------------------------------------------------------------------------

local function enter_all(j: Relation.Judge, scopes: {{Types.TParam}}, count: integer)
  for i = 1, count do
    j:enter(scopes[i])
  end
end

local function leave_all(j: Relation.Judge, count: integer)
  for _ = 1, count do
    j:leave()
  end
end

local function test_a_pair_with_variables_is_settled_for_its_binders_and_the_relation_stays_transitive(tmp: string)
  Fuzz.run({
    name = "relation variables under binders",
    dir = tmp,
    gen = gen_long,
    check = function(input: string): boolean, string
      local w = Programs.world()
      local types = relation_pool(w, TypesPrograms.numbers(input), 20, true, false)
      local scopes = binders(w)
      for count = 0, 2 do
        local fresh = Relation.new(w.store)
        enter_all(fresh, scopes, count)
        -- A judge that has settled everything under the other binders first, in another order.
        local history = Relation.new(w.store)
        for other = 2, 0, -1 do
          if other ~= count then
            enter_all(history, scopes, other)
            for i = #types, 1, -1 do
              for k = 1, #types do
                if (i + k) % 3 == 0 then
                  local _ = history:refuse(types[i], types[k])
                else
                  local _ = history:subtype(types[i], types[k])
                end
              end
            end
            leave_all(history, other)
          end
        end
        enter_all(history, scopes, count)
        local answers: mut {integer: {integer: boolean}} = {}
        for _, a in ipairs(types) do
          answers[a.id] = {}
          for _, b in ipairs(types) do
            local answer = fresh:subtype(a, b)
            answers[a.id][b.id] = answer
            local who = Types.display(a) .. " against " .. Types.display(b) .. " under " .. tostring(count) .. " binders"
            if history:subtype(a, b) ~= answer then
              return false, who .. ": a judge that settled the pair under other binders disagrees"
            end
            if (fresh:refuse(a, b) == nil) ~= answer then
              return false, who .. ": the reason disagrees"
            end
            if answer and a.open > 0 then
              Fuzz.label("related with a variable")
            end
          end
        end
        for _, a in ipairs(types) do
          for _, b in ipairs(types) do
            if answers[a.id][b.id] then
              for _, c in ipairs(types) do
                if answers[b.id][c.id] and not answers[a.id][c.id] then
                  return false, Types.display(a) .. " is below " .. Types.display(b) .. ", which is below " ..
                    Types.display(c) .. " under " .. tostring(count) .. " binders, and a is not below c"
                end
              end
            end
          end
        end
        Fuzz.label(tostring(count) .. " binders")
      end
      return true, ""
    end,
    requires = { "0 binders", "1 binders", "2 binders", "related with a variable" },
  })
end

-- A mistake -----------------------------------------------------------------------------------------------

local function test_a_type_with_a_mistake_in_it_is_related_without_raising_and_explained_as_any_other(tmp: string)
  Fuzz.run({
    name = "relation invalid",
    dir = tmp,
    gen = gen_long,
    check = function(input: string): boolean, string
      local w = Programs.world()
      local types = relation_pool(w, TypesPrograms.numbers(input), 24, false, true)
      for _, a in ipairs(types) do
        for _, b in ipairs(types) do
          local who = Types.display(a) .. " against " .. Types.display(b)
          local ok, answer = pcall(function(): boolean
            return w.judge:subtype(a, b)
          end)
          if not ok then
            return false, who .. " raised: " .. tostring(answer)
          end
          if (w.judge:refuse(a, b) == nil) ~= answer then
            return false, who .. ": the reason disagrees"
          end
          if (a.tag == "invalid" or b.tag == "invalid") and not answer then
            return false, who .. ": a mistake already reported is reported again"
          end
          Fuzz.label(if answer then "holds" else "refused" end)
          if Types.encode(a):find("invalid", 1, true) ~= nil then
            Fuzz.label("with a mistake")
          end
        end
      end
      return true, ""
    end,
    requires = { "holds", "refused", "with a mistake" },
  })
end
