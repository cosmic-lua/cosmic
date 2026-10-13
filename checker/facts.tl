-- Facts: what the checker knows of places at one point in a program,
-- held as a value. A `Facts` maps a place's id (a string) to the type
-- the place has been narrowed to there; the declared types are never
-- touched, so a read is the fact where one is held and the declared type
-- where none is. A place's id is a binding's key (`"17"`), a field path
-- from it (`"17.f"`, `"17.f.g"`) or a global (`"g:name"`).
--
-- A `Facts` is immutable. Every operation here returns a new value, or the
-- very object it was given when nothing changes, and none writes to an
-- argument. The checker keeps one `Facts` as the facts at the point it has
-- reached and puts another in its place wherever they change, so:
--
--  * two edges that meet in a join, a loop's head and a function body's
--    saved entry each hold their own `Facts` for as long as they need it,
--    and nothing that happens on another path can reach into it;
--  * "nothing changed" is an identity test (`==`), which is how a loop
--    finds the facts that came unchanged from its head;
--  * there is nothing to undo when a branch is left: the register goes
--    back to the value it had.
--
-- `nil` stands for no `Facts` at all: control cannot reach this point (after
-- a `return`, a `break`, a call that never returns). Every operation takes it
-- and answers for it: a dead point stays dead under `with`, `without` and
-- the rest, and `meet` of a dead edge and a live one is the live one.
--
-- A place that held a fact and lost it leaves a tombstone in `gone`, the
-- [`facts.Drop`] that removed it, so the refusal of a read that relied on the
-- fact can say what dropped it. A key is in `t` or in `gone`, never both;
-- narrowing the place again takes its tombstone away.
--
-- `paths` and `globals` count the keys that are field paths (they contain a
-- `.`) and globals (they begin with `g:`), so the drop a call makes of both
-- (`without_paths`, `without_globals`) is O(1) when there are none, which is
-- nearly always.
--
-- Read a `Facts` only through `get`, `has`, `is_empty`, `dropped` and `pairs`
-- over `t` and `gone`; never `next`, `rawget` or `#` on them, which a
-- read-only `Facts` (below) answers as if it were empty.
--
-- `facts.debug` makes every `Facts` the module builds read-only (a write to
-- it raises) and checks the counts and the tombstones against its keys. It
-- is for tests: a copy of every table costs more than the checker can spare.
--
-- This file holds only upstream Teal 0.24.8: the boot compiles it with the
-- vendored `tl.lua` (core/bridge.lua), as it does checker/narrowing.tl.
-- It names none of the checker's types: [`facts.Type`] is seen through the
-- one field narrowing.tl reads, and the checker passes `unite`, `is_a` and
-- `fixed`, so this file knows no type beyond its identity.

local record facts
   -- The checker's types, as narrowing.tl sees them: this file compares
   -- them by identity and hands them to the checker's own functions.
   record Type
      typename: string
   end

   -- What removed a fact, in the shape of narrowing.tl's `Drop`: a `kind` of
   -- drop, the expression as a message shows it (`text`), and where it
   -- begins.
   record Drop
      kind: string
      text: string
      y: integer
      x: integer
      place: string
   end

   -- The facts at one point. Never written to after it is returned.
   record Facts
      -- The narrowed type of each place held.
      t: {string:Type}
      -- What removed each place that was held and is not now.
      gone: {string:Drop}
      -- How many keys of `t` are field paths.
      paths: integer
      -- How many keys of `t` are globals.
      globals: integer
   end

   -- Whether the `Facts` built from now on are read-only and checked. Set
   -- by tests.
   debug: boolean

   empty: function(): Facts
   get: function(Facts, string): Type
   has: function(Facts, string): boolean
   is_empty: function(Facts): boolean
   dropped: function(Facts, string): Drop
   with: function(Facts, string, Type): Facts
   without: function(Facts, string, Drop): Facts
   without_prefix: function(Facts, string, Drop): Facts
   without_field: function(Facts, string, Drop): Facts
   without_paths: function(Facts, Drop): Facts
   without_globals: function(Facts, Drop): Facts
   meet: function(Facts, Facts, function(Type, Type): Type): Facts
   restrict: function(Facts, Facts, function(Type, Type): boolean): Facts
   for_body: function(Facts, (function(string): boolean), Drop): Facts
end

facts.debug = false

-- Whether `id` is a field path.
local function is_path(id: string): boolean
   return id:find(".", 1, true) ~= nil
end

-- Whether `id` is a global.
local function is_global(id: string): boolean
   return id:sub(1, 2) == "g:"
end

-- A shallow copy of a map. Reading goes through `pairs`, so a read-only
-- map (below) copies too.
local function copy(map: {string:any}): {string:any}
   local out: {string:any} = {}
   for k, v in pairs(map) do
      out[k] = v
   end
   return out
end

-- Whether two maps hold the same keys with the same (identical) values.
local function same_map(x: {string:any}, y: {string:any}): boolean
   if x == y then
      return true
   end
   local nx = 0
   for k, v in pairs(x) do
      if y[k] ~= v then
         return false
      end
      nx = nx + 1
   end
   local ny = 0
   for _ in pairs(y) do
      ny = ny + 1
   end
   return nx == ny
end

-- The tables `freeze` has made, so freezing one twice is one proxy.
local frozen: {any:boolean} = setmetatable({}, { __mode = "k" }) as {any:boolean}

-- A read-only view of `data`: an empty table that reads through to `data`
-- and raises on a write, existing key or new. It iterates like `data`.
local function freeze(data: {string:any}): {string:any}
   if frozen[data] then
      return data
   end
   local proxy: {string:any} = {}
   local meta: {string:any} = {
      __index = data,
      __newindex = function(_: any, key: any)
         error("facts: a Facts is immutable: write to " .. tostring(key), 2)
      end,
      __pairs = function(): function, {string:any}, any
         local step: any = next
         return step as function, data, nil
      end,
   }
   setmetatable(proxy, meta as metatable<{string:any}>)
   frozen[proxy] = true
   return proxy
end

-- The counts of `t`'s paths and globals, counted.
local function recount(t: {string:facts.Type}): integer, integer
   local paths, globals = 0, 0
   for id in pairs(t) do
      if is_path(id) then
         paths = paths + 1
      end
      if is_global(id) then
         globals = globals + 1
      end
   end
   return paths, globals
end

-- The `Facts` of these tables and counts. In debug mode it first checks
-- the counts against the keys and that no key is both held and gone, then
-- makes every table read-only.
local function finish(t: {string:facts.Type}, gone: {string:facts.Drop},
                      paths: integer, globals: integer): facts.Facts
   local made: facts.Facts = { t = t, gone = gone, paths = paths, globals = globals }
   if facts.debug then
      local counted_paths, counted_globals = recount(t)
      assert(counted_paths == paths, "facts: paths is " .. tostring(paths) ..
         " for " .. tostring(counted_paths) .. " field paths")
      assert(counted_globals == globals, "facts: globals is " .. tostring(globals) ..
         " for " .. tostring(counted_globals) .. " globals")
      for id in pairs(gone) do
         assert(t[id] == nil, "facts: '" .. id .. "' is both held and gone")
      end
      made = {
         t = freeze(t as {string:any}) as {string:facts.Type},
         gone = freeze(gone as {string:any}) as {string:facts.Drop},
         paths = paths,
         globals = globals,
      }
      local proxy = freeze(made as {string:any})
      return proxy as facts.Facts
   end
   return made
end

-- Whether `x` was dropped before `y` in the order a message reads them:
-- by line, column, kind, text and place, so that the choice between two
-- drops is the same whichever is asked first.
local function before(x: facts.Drop, y: facts.Drop): boolean
   if x.y ~= y.y then
      return x.y < y.y
   end
   if x.x ~= y.x then
      return x.x < y.x
   end
   if x.kind ~= y.kind then
      return x.kind < y.kind
   end
   if x.text ~= y.text then
      return x.text < y.text
   end
   return (x.place or "") <= (y.place or "")
end

--- The facts at the start of a program: live, and holding nothing.
function facts.empty(): facts.Facts
   return finish({}, {}, 0, 0)
end

--- The type `id` is narrowed to in `f`; nil when `f` is dead or holds no
--- fact of it.
function facts.get(f: facts.Facts, id: string): facts.Type
   if f == nil then
      return nil
   end
   return f.t[id]
end

--- What removed the fact of `id` from `f`; nil when `f` is dead, holds a
--- fact of `id` or never held one.
function facts.dropped(f: facts.Facts, id: string): facts.Drop
   if f == nil then
      return nil
   end
   return f.gone[id]
end

--- Whether `f` holds a fact of `id`. False for a dead `f`.
function facts.has(f: facts.Facts, id: string): boolean
   return f ~= nil and f.t[id] ~= nil
end

--- Whether `f` is live and holds no fact. False for a dead `f`.
function facts.is_empty(f: facts.Facts): boolean
   if f == nil then
      return false
   end
   for _ in pairs(f.t) do
      return false
   end
   return true
end

--- `f` with `id` narrowed to `ty`, and no tombstone for it. Answers `f`
--- itself when it holds that very type for `id` already, and nil for a dead
--- `f`.
function facts.with(f: facts.Facts, id: string, ty: facts.Type): facts.Facts
   if f == nil then
      return nil
   end
   if ty == nil then
      error("facts.with: no type for '" .. id .. "'", 2)
   end
   local old = f.t[id]
   if old == ty then
      return f
   end
   local t = copy(f.t as {string:any}) as {string:facts.Type}
   t[id] = ty
   local paths, globals = f.paths, f.globals
   if old == nil then
      if is_path(id) then
         paths = paths + 1
      end
      if is_global(id) then
         globals = globals + 1
      end
   end
   local gone = f.gone
   if gone[id] ~= nil then
      gone = copy(gone as {string:any}) as {string:facts.Drop}
      gone[id] = nil
   end
   return finish(t, gone, paths, globals)
end

-- `f` without the keys `matches` accepts, each tombstoned with `why`; `f`
-- itself when none is held.
local function drop_matching(f: facts.Facts, matches: function(string): boolean,
                             why: facts.Drop): facts.Facts
   local doomed: {string} = {}
   for id in pairs(f.t) do
      if matches(id) then
         doomed[#doomed + 1] = id
      end
   end
   if #doomed == 0 then
      return f
   end
   local t = copy(f.t as {string:any}) as {string:facts.Type}
   local gone = copy(f.gone as {string:any}) as {string:facts.Drop}
   local paths, globals = f.paths, f.globals
   for _, id in ipairs(doomed) do
      t[id] = nil
      gone[id] = why
      if is_path(id) then
         paths = paths - 1
      end
      if is_global(id) then
         globals = globals - 1
      end
   end
   return finish(t, gone, paths, globals)
end

--- `f` without the fact of `id`, which `why` removed. Answers `f` when it
--- holds none of `id`. A field path of `id` stays: see [`facts.without_prefix`].
function facts.without(f: facts.Facts, id: string, why: facts.Drop): facts.Facts
   if f == nil or f.t[id] == nil then
      return f
   end
   return drop_matching(f, function(key: string): boolean
      return key == id
   end, why)
end

--- `f` without `id` and every field path under it (`id .. "."` and what
--- follows), which `why` removed: an assignment to a local. A key that
--- merely begins with the characters of `id` (`"10"` for `"1"`) stays.
function facts.without_prefix(f: facts.Facts, id: string, why: facts.Drop): facts.Facts
   if f == nil then
      return nil
   end
   if f.paths == 0 then
      return facts.without(f, id, why)
   end
   local dotted = id .. "."
   return drop_matching(f, function(key: string): boolean
      return key == id or key:sub(1, #dotted) == dotted
   end, why)
end

--- `f` without every key that has the field `name` after its base,
--- which `why` removed: a write to field `name` through any reference
--- may change `a.name` and `a.name.g` and `a.g.name` alike. It matches
--- `"1.f"`, `"1.f.g"` and `"1.g.f"` for `"f"` but not `"1.ff"`, `"1.fx"`
--- or `"f"` (a local). Raises when `name` contains a `.`.
function facts.without_field(f: facts.Facts, name: string, why: facts.Drop): facts.Facts
   if name:find(".", 1, true) ~= nil then
      error("facts.without_field: '" .. name .. "' contains a '.'", 2)
   end
   if f == nil or f.paths == 0 then
      return f
   end
   local wanted = "." .. name .. "."
   return drop_matching(f, function(key: string): boolean
      return (key .. "."):find(wanted, 1, true) ~= nil
   end, why)
end

--- `f` without every field path, which `why` removed: code ran that may
--- have written any field. O(1) when `f` holds none.
function facts.without_paths(f: facts.Facts, why: facts.Drop): facts.Facts
   if f == nil or f.paths == 0 then
      return f
   end
   return drop_matching(f, is_path, why)
end

--- `f` without every global, which `why` removed. O(1) when `f` holds
--- none.
function facts.without_globals(f: facts.Facts, why: facts.Drop): facts.Facts
   if f == nil or f.globals == 0 then
      return f
   end
   return drop_matching(f, is_global, why)
end

--- The facts after two edges join: a key survives only if both hold it,
--- with the type `unite` gives the two types; `unite` answers nil to drop
--- the key (and no tombstone is made for it). A key both hold with the
--- same type object keeps it without asking `unite`. The tombstones are
--- the union of both, and where both have one for a key the earlier drop
--- is kept: by `y`, `x`, `kind`, `text` and `place`, in that order. A dead edge is the identity:
--- `meet(nil, b)` is `b`, `meet(a, nil)` is `a`.
---
--- With `unite` commutative and associative, so is `meet`, and `meet(a, a)`
--- is `a`. The result is `a` or `b` itself when it holds what that one does.
function facts.meet(a: facts.Facts, b: facts.Facts,
                    unite: function(facts.Type, facts.Type): facts.Type): facts.Facts
   if a == nil then
      return b
   end
   if b == nil or a == b then
      return a
   end
   if a.t == b.t and a.gone == b.gone then
      return a
   end
   local ta, tb = a.t, b.t
   local t: {string:facts.Type} = {}
   local paths, globals = 0, 0
   local same_a, same_b = true, true
   local kept = 0
   for id, x in pairs(ta) do
      local y = tb[id]
      local z: facts.Type = nil
      if y ~= nil then
         if x == y then
            z = x
         else
            z = unite(x, y)
         end
      end
      if z == nil then
         same_a = false
      else
         t[id] = z
         kept = kept + 1
         if is_path(id) then
            paths = paths + 1
         end
         if is_global(id) then
            globals = globals + 1
         end
         if z ~= x then
            same_a = false
         end
         if z ~= y then
            same_b = false
         end
      end
   end
   local count_b = 0
   for _ in pairs(tb) do
      count_b = count_b + 1
   end
   same_b = same_b and kept == count_b
   local ga, gb = a.gone, b.gone
   local gone = ga
   if ga ~= gb then
      for id, w in pairs(gb) do
         local have = gone[id]
         local pick = w
         if have ~= nil and before(have, w) then
            pick = have
         end
         if pick ~= have then
            if gone == ga then
               gone = copy(ga as {string:any}) as {string:facts.Drop}
            end
            gone[id] = pick
         end
      end
   end
   if same_a and gone == ga then
      return a
   end
   if same_b and same_map(gone as {string:any}, gb as {string:any}) then
      return b
   end
   return finish(t, gone, paths, globals)
end

--- A loop's exit or body facts held to its back edge: a key of `edge`
--- stays only if `back` holds it with a type that `is_a(back's, edge's)`
--- accepts (a type object both share needs no question). The rest are
--- dropped with `back`'s tombstone for them, where it has one. Answers `edge`
--- itself when every key stays, when `back` is `edge`, and when `back` is dead: a back edge that
--- never arrives supports every fact of the head. A dead `edge` stays dead.
function facts.restrict(edge: facts.Facts, back: facts.Facts,
                        is_a: function(facts.Type, facts.Type): boolean): facts.Facts
   if edge == nil or back == nil or edge == back then
      return edge
   end
   local bt = back.t
   local lost: {string} = {}
   for id, x in pairs(edge.t) do
      local y = bt[id]
      if y == nil or (y ~= x and not is_a(y, x)) then
         lost[#lost + 1] = id
      end
   end
   if #lost == 0 then
      return edge
   end
   local t = copy(edge.t as {string:any}) as {string:facts.Type}
   local gone = copy(edge.gone as {string:any}) as {string:facts.Drop}
   local paths, globals = edge.paths, edge.globals
   for _, id in ipairs(lost) do
      t[id] = nil
      gone[id] = back.gone[id]
      if is_path(id) then
         paths = paths - 1
      end
      if is_global(id) then
         globals = globals - 1
      end
   end
   return finish(t, gone, paths, globals)
end

--- The facts a function literal's body starts from: every field path and
--- global dropped, and a local kept only if `fixed(id)` says nothing assigns
--- it after the literal is made. Each key dropped is tombstoned with `why`.
--- Answers `f` itself when nothing is dropped, and nil for a dead `f`.
function facts.for_body(f: facts.Facts, fixed: function(string): boolean,
                        why: facts.Drop): facts.Facts
   if f == nil then
      return nil
   end
   return drop_matching(f, function(key: string): boolean
      return is_path(key) or is_global(key) or not fixed(key)
   end, why)
end

return facts
