--- Inference of the type parameters of a generic function ([`doc/plans/new-checker-types.md`], "calls and
--- overloads" and "generic inference is local to the call"): what each type parameter of a function type is at one
--- call, solved from the types its arguments have and, for a parameter no argument fixes, the type the call is
--- expected to answer. Nothing outlives the call: a [`Generics.Solver`] belongs to one.
---
--- A pattern is a type written in the function, whose own variables are those at depth 0 ([`lang.types`]); the type
--- found is a type of the code around the call. [`Generics.match`] walks both and records, for a variable met in the
--- pattern, the type found there and the way a value flows through the position:
---
--- * `into`: the type found is passed to the pattern (an argument to a parameter). The variable gets a *lower* bound,
---   and the bounds of one variable grow to a type all are below, or conflict.
--- * `from`: the pattern is passed to the type found (a result to the type expected, or a parameter of a function
---   argument). The variable gets an *upper* bound; two upper bounds narrow to the one that is below the other.
--- * `both`: the position is invariant (a `mut` collection, the arguments of a generic, a map's key). The variable is
---   exactly that type, and two exact types are one type or conflict.
---
--- A variable is its exact type, else its lower bound, else its upper bound. A solution is never trusted: the caller
--- puts it in the parameters and checks every argument against them, so a wrong guess here is an error there and never
--- a hole. A position whose shape the type found lacks (a view where a `mut` collection is wanted) taints the variables
--- of the pattern, which are then not reported unsolved: the argument check reports the mistake once.
local Types = require("lang.types")

local type Type = Types.Type
local type Named = Types.Named
local type Fn = Types.Fn
local type Store = Types.Store

local record Generics
  --- How a value flows through the position of a pattern.
  enum Direction
    "into"
    "from"
    "both"
  end

  --- What the caller supplies about types it alone can read.
  record Hooks
    --- Whether `a` is below `b`.
    below: function(a: Type, b: Type): boolean
    --- The interfaces the declaration of `n` lists, with their arguments, as types.
    listed: function(n: Named): {Type}
    --- The element type of the array part of the record `n`, or nil.
    array_part: function(n: Named): Type?
  end

  --- Two types a variable has no one type for.
  record Conflict
    --- The type parameter, from 1.
    index: integer
    first: Type
    second: Type
    --- The `at` of the match that gave each.
    first_at: integer
    second_at: integer
    --- Whether one was required to be the variable exactly.
    exact: boolean
  end

  --- What is known of the type parameters of one function at one call.
  record Solver
    store: Store
    fn: Fn
    hooks: Hooks
    lower: mut {integer: Type}
    upper: mut {integer: Type}
    exact: mut {integer: Type}
    lower_at: mut {integer: integer}
    upper_at: mut {integer: integer}
    exact_at: mut {integer: integer}
    --- The variables of a pattern whose shape the type found lacked.
    tainted: mut {integer: boolean}
    mut conflicts: mut {Conflict}
    --- Set when a type found was `invalid`: the mistake is reported already, so nothing it leaves unsolved is.
    mut invalid: boolean
    --- What the type expected tells, kept apart: it fills a variable nothing else fixed, and a variable only
    --- arguments below it gave takes the type it requires exactly (`hint`).
    fallback: mut {integer: Type}
    hint: mut {integer: Type}
  end

  --- A solver for the type parameters of `fn`, a generic function type.
  new: function(store: Store, fn: Fn, hooks: Hooks): Solver

  --- Records what the type `actual` found at a position says of the variables of `pattern`. `at` labels the source
  --- (an argument's position, say) for a conflict to name.
  match: function(s: Solver, pattern: Type, actual: Type, dir: Direction, at: integer)

  --- Records what the type `expected` of the call says of the variables of `pattern`, for the variables nothing else
  --- fixed.
  expect: function(s: Solver, pattern: Type, expected: Type)

  --- The type of the parameter `index` (from 1): its exact type, else its lower bound, else its upper bound, else what
  --- the type expected said; nil where nothing fixed it. A bound that disagrees with the one chosen is a conflict.
  value: function(s: Solver, index: integer): Type?

  --- Whether a pattern still names a variable that [`Generics.value`] has no type for.
  unsolved: function(s: Solver, pattern: Type): boolean

  --- The own variables `t` names (depth 0 at the top; those of a generic function type inside it are its own).
  names: function(t: Type): {integer: boolean}

  --- The type parameters of `f`, from 1, that none of its parameters or results names. A bound does not name one: a
  --- parameter only another's bound mentions is fixed by no argument and by no result.
  unused: function(f: Fn): {integer}
end

-- Variables ------------------------------------------------------------------------------------

--- Calls `visit` with the index of each variable of the binder `level` binders out that `t` names.
local function walk(t: Type, level: integer, visit: function(index: integer))
  if t.open <= level then
    return
  end
  if (t.tag == "var") then
    if t.depth == level then
      visit(t.index + 1)
    end
    return
  end
  local inside = if ((t.tag == "fn") and #t.tparams > 0) then level + 1 else level end
  for _, part in ipairs(Types.parts(t)) do
    walk(part, inside, visit)
  end
end

function Generics.names(t: Type): {integer: boolean}
  local out: mut {integer: boolean} = {}
  walk(t, 0, function(index: integer)
    out[index] = true
  end)
  return out
end

function Generics.unused(f: Fn): {integer}
  local used: mut {integer: boolean} = {}
  local written: mut {Type} = {}
  for _, p in ipairs(f.params) do
    written[#written + 1] = p.type
  end
  local rest = f.rest
  if rest ~= nil then
    written[#written + 1] = rest
  end
  for _, alt in ipairs(f.rets) do
    for _, item in ipairs(alt.items) do
      written[#written + 1] = item
    end
    local tail = alt.tail
    if tail ~= nil then
      written[#written + 1] = tail
    end
    local narrows = alt.narrows
    if narrows ~= nil then
      written[#written + 1] = narrows.to
    end
  end
  for _, t in ipairs(written) do
    walk(t, 0, function(index: integer)
      used[index] = true
    end)
  end
  local out: mut {integer} = {}
  for i = 1, #f.tparams do
    if used[i] ~= true then
      out[#out + 1] = i
    end
  end
  return out
end

-- The solver ------------------------------------------------------------------------------------

function Generics.new(store: Store, fn: Fn, hooks: Generics.Hooks): Generics.Solver
  return {
    store = store, fn = fn, hooks = hooks, lower = {}, upper = {}, exact = {}, lower_at = {}, upper_at = {}, exact_at = {},
    tainted = {}, conflicts = {}, invalid = false, fallback = {}, hint = {},
  }
end

local function conflict(s: Generics.Solver, index: integer, first: Type, second: Type, first_at: integer, second_at: integer,
                        exact: boolean)
  for _, c in ipairs(s.conflicts) do
    if c.index == index then
      return
    end
  end
  s.conflicts[#s.conflicts + 1] = {
    index = index, first = first, second = second, first_at = first_at, second_at = second_at, exact = exact,
  }
end

--- The type both `a` and `b` are below, or nil. `nil` and a type make that type optional.
local function join(s: Generics.Solver, a: Type, b: Type): Type?
  if a == b then
    return a
  elseif a.tag == "nil" then
    return s.store:optional(b)
  elseif b.tag == "nil" then
    return s.store:optional(a)
  elseif s.hooks.below(a, b) then
    return b
  elseif s.hooks.below(b, a) then
    return a
  end
  return nil
end

--- The type that is below both `a` and `b`, or nil.
local function meet(s: Generics.Solver, a: Type, b: Type): Type?
  if s.hooks.below(a, b) then
    return a
  elseif s.hooks.below(b, a) then
    return b
  end
  return nil
end

local function bind(s: Generics.Solver, index: integer, actual: Type, dir: Generics.Direction, at: integer)
  local tag = actual.tag
  if tag == "invalid" then
    s.invalid = true
    return
  end
  if dir == "into" then
    if tag == "never" then
      return
    end
    local held = s.lower[index]
    if held == nil then
      s.lower[index], s.lower_at[index] = actual, at
      return
    end
    local joined = join(s, held, actual)
    if joined == nil then
      conflict(s, index, held, actual, s.lower_at[index], at, false)
    else
      s.lower[index] = joined
    end
  elseif dir == "from" then
    local held = s.upper[index]
    if held == nil then
      s.upper[index], s.upper_at[index] = actual, at
      return
    end
    local met = meet(s, held, actual)
    if met == nil then
      conflict(s, index, held, actual, s.upper_at[index], at, false)
    else
      s.upper[index] = met
    end
  else
    local held = s.exact[index]
    if held == nil then
      s.exact[index], s.exact_at[index] = actual, at
    elseif held ~= actual then
      conflict(s, index, held, actual, s.exact_at[index], at, true)
    end
  end
end

--- The direction through a position that reverses it: a parameter of a function.
local function flip(dir: Generics.Direction): Generics.Direction
  if dir == "into" then
    return "from"
  elseif dir == "from" then
    return "into"
  end
  return "both"
end

--- The variables of `pattern` are not solved from a shape the type found lacks.
local function taint(s: Generics.Solver, pattern: Type)
  walk(pattern, 0, function(index: integer)
    s.tainted[index] = true
  end)
end

--- The element and mutability of the array `t` is, or of the record's array part, or nil.
local function array_of(s: Generics.Solver, t: Type): Type?, boolean
  if (t.tag == "array") then
    return t.element, t.mut
  elseif (t.tag == "named") and not t.value then
    local part = s.hooks.array_part(t)
    if part ~= nil then
      return part, false
    end
  end
  return nil, false
end

local visit: function(s: Generics.Solver, pattern: Type, actual: Type, dir: Generics.Direction, at: integer)

--- A union pattern with one member that names variables (`A?`, `{A} | string`): that member against what the type
--- found has beside the members the pattern spells out.
local function visit_union(s: Generics.Solver, pattern: Types.Union, actual: Type, dir: Generics.Direction, at: integer)
  local open: Type? = nil
  local plain: mut {Type} = {}
  for _, m in ipairs(pattern.members) do
    if m.open > 0 then
      if open ~= nil then
        taint(s, pattern)
        return
      end
      open = m
    else
      plain[#plain + 1] = m
    end
  end
  if open == nil then
    return
  end
  if dir == "from" then
    -- The pattern flows to the type found: the member that names variables is below it, apart from the nil it adds.
    local target = actual
    if pattern.nilable and (actual.tag == "union") and actual.nilable then
      target = s.store:non_nil(actual)
    end
    visit(s, open, target, dir, at)
    return
  end
  local rest: mut {Type} = {}
  local members: {Type}
  if actual.tag == "union" then
    members = actual.members
  else
    members = { actual }
  end
  for _, m in ipairs(members) do
    local covered = false
    for _, p in ipairs(plain) do
      covered = covered or s.hooks.below(m, p)
    end
    if not covered then
      rest[#rest + 1] = m
    end
  end
  if (actual.tag == "union") and actual.nilable and not pattern.nilable then
    rest[#rest + 1] = s.store:atom("nil")
  end
  if #rest == 0 then
    return
  end
  visit(s, open, s.store:union(rest), dir, at)
end

visit = function(s: Generics.Solver, pattern: Type, actual: Type, dir: Generics.Direction, at: integer)
  if pattern.open == 0 then
    return
  end
  if actual.tag == "invalid" then
    s.invalid = true
    taint(s, pattern)
    return
  end
  if (actual.tag == "union") and not ((pattern.tag == "var")) and not ((pattern.tag == "union")) then
    -- A union of shapes (`{integer} | {string}` for `{T}`) is each member in turn: the members give `T` the type they
    -- agree on, or conflict, and a member that nil makes of it is the argument check's to refuse.
    for _, m in ipairs(actual.members) do
      visit(s, pattern, m, dir, at)
    end
    return
  end
  if (pattern.tag == "var") then
    if pattern.depth == 0 then
      bind(s, pattern.index + 1, actual, dir, at)
    end
  elseif (pattern.tag == "union") then
    visit_union(s, pattern, actual, dir, at)
  elseif (pattern.tag == "array") then
    local element, changes = array_of(s, actual)
    if element == nil then
      taint(s, pattern)
    elseif pattern.mut then
      if changes then
        visit(s, pattern.element, element, "both", at)
      elseif dir == "from" then
        visit(s, pattern.element, element, "from", at)
      else
        taint(s, pattern)
      end
    elseif dir == "from" and changes then
      taint(s, pattern)
    else
      visit(s, pattern.element, element, dir, at)
    end
  elseif (pattern.tag == "map") then
    if not ((actual.tag == "map")) then
      taint(s, pattern)
    elseif pattern.mut then
      if actual.mut then
        visit(s, pattern.key, actual.key, "both", at)
        visit(s, pattern.value, actual.value, "both", at)
      elseif dir == "from" then
        visit(s, pattern.key, actual.key, "both", at)
        visit(s, pattern.value, actual.value, "from", at)
      else
        taint(s, pattern)
      end
    elseif dir == "from" and actual.mut then
      taint(s, pattern)
    else
      visit(s, pattern.key, actual.key, "both", at)
      visit(s, pattern.value, actual.value, dir, at)
    end
  elseif (pattern.tag == "named") then
    if not ((actual.tag == "named")) or actual.value ~= pattern.value then
      taint(s, pattern)
    elseif actual.decl == pattern.decl then
      for i, p in ipairs(pattern.args) do
        local a = actual.args[i]
        if a ~= nil then
          visit(s, p, a, "both", at)
        end
      end
    elseif dir == "into" and pattern.decl.kind == "interface" then
      local found = false
      for _, listed in ipairs(s.hooks.listed(actual)) do
        if (listed.tag == "named") and listed.decl == pattern.decl then
          found = true
          for i, p in ipairs(pattern.args) do
            local a = listed.args[i]
            if a ~= nil then
              visit(s, p, a, "both", at)
            end
          end
          break
        end
      end
      if not found then
        taint(s, pattern)
      end
    else
      taint(s, pattern)
    end
  elseif (pattern.tag == "fn") then
    if not ((actual.tag == "fn")) or #actual.tparams > 0 or #pattern.tparams > 0 then
      taint(s, pattern)
      return
    end
    for i, p in ipairs(pattern.params) do
      local a = actual.params[i]
      if a ~= nil then
        visit(s, p.type, a.type, flip(dir), at)
      end
    end
    local rest, actual_rest = pattern.rest, actual.rest
    if rest ~= nil and actual_rest ~= nil then
      visit(s, rest, actual_rest, flip(dir), at)
    end
    if #pattern.rets == 1 and #actual.rets == 1 then
      local p, a = pattern.rets[1], actual.rets[1]
      assert(p ~= nil and a ~= nil)
      for i, item in ipairs(p.items) do
        local found = a.items[i]
        if found ~= nil then
          visit(s, item, found, dir, at)
        end
      end
      local p_tail, a_tail = p.tail, a.tail
      if p_tail ~= nil and a_tail ~= nil then
        visit(s, p_tail, a_tail, dir, at)
      end
    end
  end
end

function Generics.match(s: Generics.Solver, pattern: Type, actual: Type, dir: Generics.Direction, at: integer)
  visit(s, pattern, actual, dir, at)
end

function Generics.expect(s: Generics.Solver, pattern: Type, expected: Type)
  if pattern.open == 0 then
    return
  elseif expected.tag == "invalid" then
    -- The place was reported when it was made, and a variable only it could fix is not reported again.
    s.invalid = true
    taint(s, pattern)
    return
  elseif expected.tag == "any" then
    -- A parameter that takes every value expects: it says nothing of the type.
    return
  end
  -- Matched in a solver of its own, so that nothing it finds conflicts with what the arguments said.
  local aside = Generics.new(s.store, s.fn, s.hooks)
  local target = expected
  if (target.tag == "union") and not ((pattern.tag == "union")) then
    target = s.store:non_nil(target)
  end
  visit(aside, pattern, target, "from", 0)
  if #aside.conflicts > 0 then
    return
  end
  for i = 1, #s.fn.tparams do
    local held = Generics.value(aside, i)
    if held ~= nil then
      s.fallback[i] = held
      s.hint[i] = aside.exact[i]
    end
  end
  -- Arguments that have no type between them are both below the one the position wants.
  local kept: mut {Generics.Conflict} = {}
  for _, c in ipairs(s.conflicts) do
    local want = s.hint[c.index] or s.fallback[c.index]
    if want ~= nil and not c.exact and s.hooks.below(c.first, want) and s.hooks.below(c.second, want) then
      s.lower[c.index] = want
    else
      kept[#kept + 1] = c
    end
  end
  s.conflicts = kept
end

function Generics.value(s: Generics.Solver, index: integer): Type?
  local exact, lower, upper = s.exact[index], s.lower[index], s.upper[index]
  if exact ~= nil then
    if lower ~= nil and not s.hooks.below(lower, exact) then
      conflict(s, index, exact, lower, s.exact_at[index], s.lower_at[index], true)
    elseif upper ~= nil and not s.hooks.below(exact, upper) then
      conflict(s, index, upper, exact, s.upper_at[index], s.exact_at[index], true)
    end
    return exact
  elseif lower ~= nil then
    local hint = s.hint[index]
    if hint ~= nil and s.hooks.below(lower, hint) and (upper == nil or s.hooks.below(hint, upper)) then
      return hint
    end
    if upper ~= nil and not s.hooks.below(lower, upper) then
      conflict(s, index, lower, upper, s.lower_at[index], s.upper_at[index], false)
    end
    return lower
  end
  return upper or s.fallback[index]
end

function Generics.unsolved(s: Generics.Solver, pattern: Type): boolean
  for index in pairs(Generics.names(pattern)) do
    if Generics.value(s, index) == nil then
      return true
    end
  end
  return false
end

return Generics
