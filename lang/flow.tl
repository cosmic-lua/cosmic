--- The flow state of the new checker ([`doc/plans/new-checker-types.md`], "narrowing and reachability"): what a
--- function's body knows at one point of it, which [`lang.check`] keeps as a register of its walk and replaces
--- where control branches, joins and loops.
---
--- A [`Flow.State`] holds three things about the places of the body, all keyed by the binding they are about
--- ([`Scopes.Var.id`]), so a name that is declared again is another place:
---
--- * **facts**: a place that has been narrowed, and the type it has been narrowed to. A place is a local (`17`) or a
---   path of fixed fields from one (`17.a.b`). A fact never changes the declared type, which it carries beside the
---   narrowed one so that a join that learns nothing drops it.
--- * **unset**: the locals declared with no value that no path has assigned yet (definite assignment).
--- * **gone**: for a place that lost its fact to an assignment, where the assignment is, so that a use that relied
---   on the fact is told which assignment dropped it.
---
--- `live` says whether control reaches the point. A state that is not live keeps the facts at the jump, and code
--- after the jump is checked from them; a join of a live state and a dead one is the live one.
---
--- A state is a value: every function here answers a new state, or the very one it was given when nothing changes,
--- and writes to none. So an edge of the flow that is kept (a loop's head, a branch, a function's entry) is
--- never changed by what happens on another path, and "nothing changed" is an identity test.
local Scopes = require("lang.scopes")
local Types = require("lang.types")

local type Type = Types.Type

local record Flow
  --- A narrowed place.
  record Fact
    --- What it has been narrowed to.
    type: Type
    --- What it was declared with: the facts hold nothing wider.
    declared: Type
  end

  --- The state at a point.
  record State
    live: boolean
    --- The facts, by place: the id of a local, then `.` and the field for each step of a path.
    facts: {string: Fact}
    --- How many keys of `facts` are paths.
    paths: integer
    --- The locals not yet assigned, by id, and how many.
    unset: {integer: boolean}
    unsets: integer
    --- The assignment that dropped the fact of each place that has none now.
    gone: {string: Scopes.Place}
  end

  --- The state of a body's first statement: live, with nothing known.
  start: function(): State

  --- The fact of the place `key`, or nil.
  get: function(f: State, key: string): Fact | nil

  --- `f` with the place `key` narrowed to `narrowed`, which was declared `declared`. Answers `f` itself when that is
  --- what it holds, and a state with no fact of the place when `narrowed` is `declared`.
  narrow: function(f: State, key: string, narrowed: Type, declared: Type): State

  --- `f` where control does not arrive.
  dead: function(f: State): State

  --- `f` after an assignment to the local `id` ([`Scopes.Var.id`]): its fact and the facts of the paths from it are
  --- gone, `why` says where, and it is assigned.
  assign: function(f: State, id: integer, why: Scopes.Place | nil): State

  --- `f` after the local `id` is declared: it is a place of its own, with no fact and no memory of an assignment, and
  --- it is unset where `unset`.
  declare: function(f: State, id: integer, unset: boolean): State

  --- `f` with the local `id` assigned, where an error has said it is not.
  assigned: function(f: State, id: integer): State

  --- The state a function's body starts from, made where `f` is: live, with the facts of `f` except the places rooted
  --- in a local of `unfixed` (assigned after the function is made), and nothing unset.
  enter: function(f: State, unfixed: {integer: boolean} | nil): State

  --- `f` without any fact, for a loop that does not settle.
  forget: function(f: State): State

  --- The state where the edges `a` and `b` meet. A dead edge is the identity. A place keeps a fact only if both edges
  --- hold one, of the type `unite` gives the two types, unless `covers(declared, united)` says the union tells nothing
  --- the declared type did not. A local is unset if either edge leaves it so. The drop of a place on either edge is
  --- kept while the result holds no fact of it.
  join: function(a: State, b: State, unite: function(Type, Type): Type, covers: function(Type, Type): boolean): State

  --- Whether `a` and `b` hold the same facts and the same unset locals, and are both live or both dead.
  same: function(a: State, b: State): boolean

  --- The id of the local a place key is rooted in.
  root: function(key: string): integer
end

local NONE: {string: Flow.Fact} = {}
local NO_UNSET: {integer: boolean} = {}
local NO_GONE: {string: Scopes.Place} = {}

local function is_path(key: string): boolean
  return key:find(".", 1, true) ~= nil
end

function Flow.root(key: string): integer
  local dot = key:find(".", 1, true)
  return math.tointeger(tonumber(dot ~= nil and key:sub(1, dot - 1) or key)) or 0
end

local function made(live: boolean, facts: {string: Flow.Fact}, paths: integer, unset: {integer: boolean},
                    unsets: integer, gone: {string: Scopes.Place}): Flow.State
  return { live = live, facts = facts, paths = paths, unset = unset, unsets = unsets, gone = gone }
end

function Flow.start(): Flow.State
  return made(true, NONE, 0, NO_UNSET, 0, NO_GONE)
end

function Flow.get(f: Flow.State, key: string): Flow.Fact | nil
  return f.facts[key]
end

local function copy_facts(facts: {string: Flow.Fact}): {string: Flow.Fact}
  local out: {string: Flow.Fact} = {}
  for k, v in pairs(facts) do
    out[k] = v
  end
  return out
end

local function copy_gone(gone: {string: Scopes.Place}): {string: Scopes.Place}
  local out: {string: Scopes.Place} = {}
  for k, v in pairs(gone) do
    out[k] = v
  end
  return out
end

local function copy_unset(unset: {integer: boolean}): {integer: boolean}
  local out: {integer: boolean} = {}
  for k, v in pairs(unset) do
    out[k] = v
  end
  return out
end

function Flow.narrow(f: Flow.State, key: string, narrowed: Type, declared: Type): Flow.State
  local held = f.facts[key]
  if narrowed == declared then
    if held == nil then
      return f
    end
    local facts = copy_facts(f.facts)
    facts[key] = nil
    return made(f.live, facts, f.paths - (is_path(key) and 1 or 0), f.unset, f.unsets, f.gone)
  end
  if held ~= nil and held.type == narrowed and held.declared == declared then
    return f
  end
  local facts = copy_facts(f.facts)
  facts[key] = { type = narrowed, declared = declared }
  local gone = f.gone
  if gone[key] ~= nil then
    gone = copy_gone(gone)
    gone[key] = nil
  end
  local paths = f.paths
  if held == nil and is_path(key) then
    paths = paths + 1
  end
  return made(f.live, facts, paths, f.unset, f.unsets, gone)
end

function Flow.dead(f: Flow.State): Flow.State
  if not f.live then
    return f
  end
  return made(false, f.facts, f.paths, f.unset, f.unsets, f.gone)
end

--- Whether `key` is the place `id` or a path from it.
local function is_rooted(key: string, id: integer): boolean
  local own = tostring(id)
  return key == own or key:sub(1, #own + 1) == own .. "."
end

--- `f` without the facts rooted in `id`, and without the tombstones of its places. Where `why` is given the places
--- that held a fact keep a tombstone of it.
local function without(f: Flow.State, id: integer, why: Scopes.Place | nil): Flow.State
  if next(f.facts) == nil and next(f.gone) == nil then
    return f
  end
  local doomed: {string} = {}
  for k in pairs(f.facts) do
    if is_rooted(k, id) then
      doomed[#doomed + 1] = k
    end
  end
  local old: {string} = {}
  for k in pairs(f.gone) do
    if is_rooted(k, id) then
      old[#old + 1] = k
    end
  end
  if #doomed == 0 and (why ~= nil or #old == 0) then
    return f
  end
  local facts = f.facts
  local paths = f.paths
  if #doomed > 0 then
    facts = copy_facts(facts)
    for _, k in ipairs(doomed) do
      facts[k] = nil
      if is_path(k) then
        paths = paths - 1
      end
    end
  end
  local gone = f.gone
  if why == nil and #old > 0 then
    gone = copy_gone(gone)
    for _, k in ipairs(old) do
      gone[k] = nil
    end
  elseif why ~= nil then
    gone = copy_gone(gone)
    for _, k in ipairs(doomed) do
      gone[k] = why
    end
  end
  return made(f.live, facts, paths, f.unset, f.unsets, gone)
end

function Flow.assign(f: Flow.State, id: integer, why: Scopes.Place | nil): Flow.State
  local g = without(f, id, why)
  if g.unset[id] then
    local unset = copy_unset(g.unset)
    unset[id] = nil
    return made(g.live, g.facts, g.paths, unset, g.unsets - 1, g.gone)
  end
  return g
end

function Flow.declare(f: Flow.State, id: integer, unset: boolean): Flow.State
  local g = without(f, id, nil)
  local was = g.unset[id] == true
  if was == unset then
    return g
  end
  local out = copy_unset(g.unset)
  out[id] = unset or nil
  return made(g.live, g.facts, g.paths, out, g.unsets + (unset and 1 or -1), g.gone)
end

function Flow.assigned(f: Flow.State, id: integer): Flow.State
  if not f.unset[id] then
    return f
  end
  local unset = copy_unset(f.unset)
  unset[id] = nil
  return made(f.live, f.facts, f.paths, unset, f.unsets - 1, f.gone)
end

function Flow.enter(f: Flow.State, unfixed: {integer: boolean} | nil): Flow.State
  local facts = f.facts
  local paths = f.paths
  if unfixed ~= nil and next(facts) ~= nil then
    local doomed: {string} = {}
    for k in pairs(facts) do
      if unfixed[Flow.root(k)] then
        doomed[#doomed + 1] = k
      end
    end
    if #doomed > 0 then
      facts = copy_facts(facts)
      for _, k in ipairs(doomed) do
        facts[k] = nil
        if is_path(k) then
          paths = paths - 1
        end
      end
    end
  end
  return made(true, facts, paths, NO_UNSET, 0, NO_GONE)
end

function Flow.forget(f: Flow.State): Flow.State
  if next(f.facts) == nil then
    return f
  end
  return made(f.live, NONE, 0, f.unset, f.unsets, f.gone)
end

--- The earlier of two places.
local function earlier(a: Scopes.Place, b: Scopes.Place): Scopes.Place
  return b.offset < a.offset and b or a
end

function Flow.join(a: Flow.State, b: Flow.State, unite: function(Type, Type): Type,
                   covers: function(Type, Type): boolean): Flow.State
  if a == b then
    return a
  elseif not a.live and b.live then
    return b
  elseif a.live and not b.live then
    return a
  end
  local facts: {string: Flow.Fact} = {}
  local paths = 0
  local kept = 0
  for key, fa in pairs(a.facts) do
    local fb = b.facts[key]
    if fb ~= nil then
      local t = fa.type
      if fb.type ~= t then
        t = unite(t, fb.type)
      end
      if t == fa.type and fa.declared == fb.declared then
        facts[key] = fa
        kept = kept + 1
      elseif not covers(fa.declared, t) then
        facts[key] = { type = t, declared = fa.declared }
        kept = kept + 1
      end
      if facts[key] ~= nil and is_path(key) then
        paths = paths + 1
      end
    end
  end
  local unset = a.unset
  local unsets = a.unsets
  if b.unsets > 0 then
    for id in pairs(b.unset) do
      if not unset[id] then
        if unset == a.unset then
          unset = copy_unset(unset)
        end
        unset[id] = true
        unsets = unsets + 1
      end
    end
  end
  local gone: {string: Scopes.Place} = {}
  local function note(key: string, place: Scopes.Place)
    if facts[key] == nil then
      local held = gone[key]
      gone[key] = held ~= nil and earlier(held, place) or place
    end
  end
  for key, place in pairs(a.gone) do
    note(key, place)
  end
  for key, place in pairs(b.gone) do
    note(key, place)
  end
  if next(gone) == nil then
    gone = NO_GONE
  end
  local live = a.live
  if kept == 0 then
    facts = NONE
  end
  return made(live, facts, paths, unset, unsets, gone)
end

function Flow.same(a: Flow.State, b: Flow.State): boolean
  if a == b then
    return true
  elseif a.live ~= b.live or a.unsets ~= b.unsets then
    return false
  end
  local count = 0
  for key, fa in pairs(a.facts) do
    local fb = b.facts[key]
    if fb == nil or fb.type ~= fa.type then
      return false
    end
    count = count + 1
  end
  for _ in pairs(b.facts) do
    count = count - 1
  end
  if count ~= 0 then
    return false
  end
  for id in pairs(a.unset) do
    if not b.unset[id] then
      return false
    end
  end
  return true
end

return Flow
