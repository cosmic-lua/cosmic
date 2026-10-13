-- Narrowing: what the checker knows of a place after a test of it. A
-- place is what a program names and can change: a local, or a field of
-- one. A guard is a test (a truthiness read, a comparison, `is`,
-- `type(x) == "..."`, an assert-like call) or a combination of tests
-- (`not`, `and`, `or`). A guard evaluates to the facts it gives, one per
-- place; the checker holds those on its scopes, keyed by the place's
-- key, and drops what is known of a place where its value can change.
--
-- The checker (checker/tl.tl) builds a guard on each expression and applies
-- one wherever a branch begins or an expression is cut short: the body of
-- an `if` or a `while`, the right operand of `and` and `or`, what follows
-- an `assert`, and what follows an `if` all of whose branches end
-- ([`flow.ends_all`]) by the negation of its conditions.
--
-- A fact is dropped by an assignment to its place or a prefix of it
-- ([`narrowing.drop`]), by a write to a field of its name through any
-- reference ([`narrowing.drop_written`]), and by code that runs, which may
-- write any field of any table ([`narrowing.drop_paths`]; no local, as no
-- function assigns a local it does not declare). Each drop
-- says what dropped the place, so the refusal of a use that relied on the
-- fact can say so ([`narrowing.dropped_by`]). A guard built before code
-- ran is cut of the facts that code may have changed ([`narrowing.forget`]),
-- the drops of a block that never reaches the code after it are put back
-- ([`narrowing.undo`]), and a function literal's body begins without the
-- facts outside it that may change before it runs
-- ([`narrowing.enter_function`]).
--
-- Evaluating a guard asks the checker what it alone knows: a place's
-- current type, whether one type is another, how to unite, intersect or
-- subtract two. It answers through a [`narrowing.Host`] it is handed, so
-- this file names none of the checker's types.
--
-- This file holds only upstream Teal 0.24.8: the boot compiles it with
-- the vendored `tl.lua` (core/bridge.lua), as it does checker/tl.tl.
--
-- TODO: the places are a local and `x.f` of a local: `place_of` answers
-- nothing for `a.b.c`, and no index (`t[k]`) is a place. `Place.fields`
-- already carries a path and `Host.type_of` walks it. It waits on
-- doc/roadmap.md's item that makes every guard read every place alike;
-- a write to an index then drops every index place, and the checker drops
-- every field path for the write through a key that may be a field name
-- (`TypeChecker:drop_through`).
--
-- TODO: `x.f is T` is refused ("can only use 'is' on variables"), though
-- `x.f` is a place that `type(x.f) == "..."` narrows. It waits on the
-- roadmap item that makes every guard read every place alike.
--
-- TODO: a to-be-closed variable's `__close` runs where its block ends, and
-- reading a declared field of a record that declares `__index` or
-- `__newindex` runs it when the field is absent, and neither drops what is
-- known. They wait on doc/roadmap.md's item that makes a metamethod's run
-- a call wherever it can happen, with the record rules for `__index` and
-- `__newindex`.

local record narrowing
   -- Where a guard was built: the position the checker reports at.
   interface Where
      f: string
      y: integer
      x: integer
   end

   -- The checker's types, seen through the one field this file reads.
   record Type
      typename: string
   end

   -- A local (`fields` is empty) or a field path from one. `key` is the
   -- name a fact about the place is held under: the local's name, or
   -- `base.field`. No Lua name contains a dot, so a key is never another
   -- variable's name.
   record Place
      base: string
      fields: {string}
      key: string
   end

   enum Kind
      "is"     -- type-based: its negation implies the subtracted type
      "=="     -- value-based: its negation proves nothing
      "not"    -- negation: type-based facts subtract, value-based prove nothing
      "and"    -- conjunction: type-based facts intersect, any value-based one downgrades all
      "or"     -- disjunction: type-based facts unite, any value-based one downgrades all
      "truthy" -- an expression that is either truthy or a run-time error
   end

   -- A guard. `is` and `==` are tests of `place` (`typ` is what it is, or
   -- equals); `not` negates `f1`; `and` and `or` combine `f1` and `f2`;
   -- `truthy` says nothing of any place. What a guard evaluates to is
   -- again guards of kind `is` and `==`, one per place.
   record Guard
      fact: Kind
      w: Where
      no_infer: boolean
      f1: Guard
      f2: Guard
      place: Place
      typ: Type
   end

   -- What evaluating a guard asks of the checker.
   record Host
      -- The type a place has now, even the first time it is narrowed;
      -- nil when it has none. A silent query: it reports no error.
      type_of: function(Place, Where): Type
      is_a: function(Type, Type): boolean
      unite: function(Where, Type, Type): Type
      intersect: function(Where, Type, Type): Type
      subtract: function(Where, Type, Type): Type
      -- A type no value has, which a fact that cannot hold is given.
      invalid: function(Where): Type
      show: function(Type): string
      -- A test of `who` that its type, `have`, can never pass: the
      -- warning for a negated test, the error for a plain one.
      warn_never: function(Where, who: string, have: Type, wanted: Type)
      refuse_never: function(Where, who: string, have: Type, wanted: Type)
   end

   -- What dropped a fact: an assignment to the place (`assignment`), a
   -- write to a field of that name through another reference (`write`), a
   -- call (`call`), an operator, index or comparison that runs a
   -- metamethod (`operator`), or a loop whose body does one of these
   -- (`loop`). `text` is the expression as a message shows it, `y` and
   -- `x` where it is.
   record Drop
      kind: string
      text: string
      y: integer
      x: integer
      -- The place a read found dropped; nil on the drop itself, which
      -- may have removed many.
      place: string
   end

   -- The scopes' part a place is dropped from: a scope holds its
   -- variables, and the facts narrowed on them, by key, and lists the
   -- keys it narrowed. A key a drop removed is listed in `dropped` with
   -- what removed it, until the place is narrowed again or the scope ends.
   record Scope
      vars: {string:Var}
      narrows: {string:boolean}
      dropped: {string:Drop}
      hidden: {Hidden}
      -- On the outermost scope: what the drops removed, in order, and the
      -- keys any scope has told a drop of, so a read of any other need not
      -- look.
      journal: {Removed}
      told: {string:boolean}
      -- On the outermost scope: told the index of the scope and the key of
      -- each fact a drop removes or widens, as it does.
      on_drop: function(integer, string, Drop)
   end

   -- A loop being checked: the depth of the scopes outside it, what its
   -- body read of the facts held there, and what its body dropped of them.
   record Loop
      depth: integer
      reads: {Read}
      dropped: {string:{Dropped}}
   end

   -- A read of a fact held outside a loop, at `node`, when `clock` drops
   -- had been met.
   record Read
      node: Node
      key: string
      clock: integer
   end

   -- A drop of a fact held outside a loop, the `clock`th met.
   record Dropped
      clock: integer
      why: Drop
   end

   -- A fact a drop removed from `scope`: `var` held under `key`, which
   -- `narrows` listed, and the drop that `dropped` already told of it.
   record Removed
      scope: Scope
      key: string
      var: Var
      narrowed: boolean
      told: Drop
   end

   -- A fact an enclosing scope holds while a function literal's body is
   -- checked, which the body does not see: `scope` held `var` under `key`.
   -- A fact held in a variable declared there (`restore`) is put back by
   -- giving the variable its `t`, `specialized_from`, `widened_from` and
   -- specialization again; any other is the entry itself, removed.
   record Hidden
      scope: Scope
      key: string
      var: Var
      restore: boolean
      t: Type
      is_specialized: string
      specialized_from: Type
      widened_from: Type
   end

   -- The part of a variable this file reads: whether the scope's entry
   -- for it is a narrowed (or widened) view of a variable declared below.
   record Var
      is_specialized: string
      t: Type
      specialized_from: Type
      widened_from: Type
   end

   -- The syntax-tree fields places and conditions are read from.
   record Operator
      op: string
   end
   record Node
      kind: string
      tk: string
      op: Operator
      e1: Node
      e2: Node
      exp: Node
      guard: Guard
   end

   truthy: Guard
   local_place: function(string): Place
   field_place: function(string, string): Place
   place_of: function(Node): Place
   target_of: function(Node): Place
   forgets: function(Place, string): boolean
   drop: function({Scope}, Place, Drop)
   drop_written: function({Scope}, string, Drop)
   drop_paths: function({Scope}, Drop)
   narrowed: function({Scope}): boolean, {string}
   has_paths: function({Scope}): boolean
   note: function({Scope}, string, Drop)
   dropped_by: function({Scope}, string): Drop
   cut: function({Scope}, string, Drop)
   places: function(Guard): {Place}
   renarrowed: function({Scope}, string)
   forget: function(Guard, function(Place): boolean): Guard
   because: function(string, string, integer, integer): Drop
   mark: function({Scope}): integer
   undo: function({Scope}, integer)
   enter_function: function({Scope}, Drop, function(string): boolean)
   leave_function: function({Scope}, {Hidden})
   type_is: function(Where, Place, Type): Guard
   value_is: function(Where, Place, Type): Guard
   negate: function(Where, Guard): Guard
   both: function(Where, Guard, Guard): Guard
   either: function(Where, Guard, Guard): Guard
   any_of: function(Where, Guard, Guard): Guard
   none_of: function(Where, {Node}, integer): Guard
   evaluate: function(Host, Guard): {string:Guard}
end

--- The place a local names.
function narrowing.local_place(name: string): narrowing.Place
   return { base = name, fields = {}, key = name }
end

--- The place `base.field` names, `base` a local.
function narrowing.field_place(base: string, field: string): narrowing.Place
   return { base = base, fields = { field }, key = base .. "." .. field }
end

--- The place `n`, an expression, names: a local, or `x.f` with `x` a
--- local. Nil for any other expression.
function narrowing.place_of(n: narrowing.Node): narrowing.Place
   if n.kind == "variable" then
      return narrowing.local_place(n.tk)
   end
   if n.kind == "op" and n.op.op == "." and n.e1.kind == "variable" then
      return narrowing.field_place(n.e1.tk, n.e2.tk)
   end
   return nil
end

--- The place an assignment to `n` writes: what it names by its text (a
--- local), else the place of the expression.
function narrowing.target_of(n: narrowing.Node): narrowing.Place
   if n.tk then
      return narrowing.local_place(n.tk)
   end
   return narrowing.place_of(n)
end

--- Whether an assignment to `assigned` drops what is known under `key`:
--- every field of a local assigned, and a field assigned with the paths under
--- it (`r.f` and `r.f.g`, not `r.foo`).
function narrowing.forgets(assigned: narrowing.Place, key: string): boolean
   local prefix = assigned.key .. "."
   return key:sub(1, #prefix) == prefix or (#assigned.fields > 0 and key == assigned.key)
end

-- The place a drop found dropped is none: the drop itself may have removed
-- many. This file holds it in a local because the checker refuses a literal
-- nil where a value is declared.
-- A local this file declares `local x: T = nil` (this one, `absent`,
-- `nowhere`, `evaluate`'s and the rest below) is one whose value the code
-- after it assigns, as in checker/tl.tl.
-- TODO: give each of them its honest type (`T | nil`, narrowed where it is
-- read) or a value, once nil is excluded from every type but one that names
-- it: the checker then refuses `local x: T = nil`, and the checker's own
-- source is the last of the tree to migrate (the roadmap's nil item).
local no_place: string = nil
local no_name: string = nil
local no_type: narrowing.Type = nil

--- What dropped a fact: a `kind` of drop (see [`narrowing.Drop`]), the
--- expression as a message shows it, and where it begins.
function narrowing.because(kind: string, text: string, y: integer, x: integer): narrowing.Drop
   return { kind = kind, text = text, y = y, x = x, place = no_place }
end

-- Says that a drop of `key` is told in some scope.
local function tell(scopes: {narrowing.Scope}, key: string)
   local told = scopes[1].told
   if not told then
      told = {}
      scopes[1].told = told
   end
   told[key] = true
end

-- Removes the fact held under `key` from `scope`, and says in `dropped`
-- what removed it.
local function remove(scopes: {narrowing.Scope}, i: integer, key: string, why: narrowing.Drop)
   local scope = scopes[i]
   local journal = scopes[1].journal
   if not journal then
      journal = {}
      scopes[1].journal = journal
   end
   table.insert(journal, {
      scope = scope, key = key, var = scope.vars[key],
      narrowed = scope.narrows ~= nil and scope.narrows[key] == true,
      told = scope.dropped and scope.dropped[key],
   })
   scope.vars[key] = nil
   if scope.narrows then
      scope.narrows[key] = nil
   end
   scope.dropped = scope.dropped or {}
   scope.dropped[key] = why
   tell(scopes, key)
   local on_drop = scopes[1].on_drop
   if on_drop then
      on_drop(i, key, why)
   end
end

--- Drops from every scope what is known under a key `forgets`, and the
--- key from the names the scope narrowed, which a later widening of every
--- narrowed name would otherwise look for. `why` is what assigned.
function narrowing.drop(scopes: {narrowing.Scope}, assigned: narrowing.Place, why: narrowing.Drop)
   for i = #scopes, 1, -1 do
      local scope = scopes[i]
      for name in pairs(scope.vars) do
         if narrowing.forgets(assigned, name) then
            remove(scopes, i, name, why)
         end
      end
   end
end

-- The keys of `scope` that name a field path (`r.n`: no Lua name
-- contains a dot) and that `wanted` accepts, any when it is nil; nil for none.
local function path_keys(scope: narrowing.Scope, wanted?: function(string): boolean): {string}
   local keys: {string} = nil
   if scope.narrows then
      for key in pairs(scope.narrows) do
         if key:find(".", 1, true) and (wanted == nil or wanted(key)) then
            keys = keys or {}
            keys[#keys + 1] = key
         end
      end
   end
   return keys
end

--- Drops every narrowed place with `.field` among the components after its
--- base (`r.field`, `r.field.g`, `r.g.field`): a write to a field of that
--- name through any reference may be a write to the field of a table that
--- another path names, or to one on the way to it. `why` is the write.
function narrowing.drop_written(scopes: {narrowing.Scope}, field: string, why: narrowing.Drop)
   local component = "." .. field .. "."
   local function names_field(key: string): boolean
      return (key .. "."):find(component, 1, true) ~= nil
   end
   for i = #scopes, 1, -1 do
      local scope = scopes[i]
      local keys = path_keys(scope, names_field)
      if keys then
         for _, key in ipairs(keys) do
            remove(scopes, i, key, why)
         end
      end
   end
end

--- Drops every narrowed field path: what runs may write any field of any
--- table it reaches. `why` is what runs.
function narrowing.drop_paths(scopes: {narrowing.Scope}, why: narrowing.Drop)
   for i = #scopes, 1, -1 do
      local scope = scopes[i]
      local keys = path_keys(scope)
      if keys then
         for _, key in ipairs(keys) do
            remove(scopes, i, key, why)
         end
      end
   end
end

--- Whether any field path is narrowed, and the names of the narrowed locals
--- (nil for none), each once, for the checker to see what a call has to drop.
function narrowing.narrowed(scopes: {narrowing.Scope}): boolean, {string}
   local paths = false
   local seen: {string:boolean} = nil
   local names: {string} = nil
   for i = #scopes, 1, -1 do
      local narrows = scopes[i].narrows
      if narrows then
         for name in pairs(narrows) do
            if name:find(".", 1, true) then
               paths = true
            elseif not (seen and seen[name]) then
               seen = seen or {}
               names = names or {}
               seen[name] = true
               names[#names + 1] = name
            end
         end
      end
   end
   if names then
      table.sort(names)
   end
   return paths, names
end

--- Whether any field path is narrowed.
function narrowing.has_paths(scopes: {narrowing.Scope}): boolean
   for i = #scopes, 1, -1 do
      local narrows = scopes[i].narrows
      if narrows then
         for name in pairs(narrows) do
            if name:find(".", 1, true) then
               return true
            end
         end
      end
   end
   return false
end

--- Says in each scope that narrowed the local `name` that `why` dropped
--- it, which the caller widens.
function narrowing.note(scopes: {narrowing.Scope}, name: string, why: narrowing.Drop)
   for i = #scopes, 1, -1 do
      local scope = scopes[i]
      if scope.narrows and scope.narrows[name] then
         scope.dropped = scope.dropped or {}
         scope.dropped[name] = why
         tell(scopes, name)
         local on_drop = scopes[1].on_drop
         if on_drop then
            on_drop(i, name, why)
         end
      end
   end
end

--- What dropped the fact a read of `key` would have had, nil when the
--- place is narrowed now or was never dropped. A scope that widens the
--- place (a drop of a local) ends the search for a narrowing below it,
--- not for what dropped it.
function narrowing.dropped_by(scopes: {narrowing.Scope}, key: string): narrowing.Drop
   local told = scopes[1].told
   if not told or not told[key] then
      return nil
   end
   local widened = false
   for i = #scopes, 1, -1 do
      local scope = scopes[i]
      local var = scope.vars[key]
      if var and var.is_specialized == "widen" then
         widened = true
      elseif var and var.is_specialized and var.is_specialized ~= "localizing" and not widened then
         return nil
      end
      if scope.dropped and scope.dropped[key] then
         return scope.dropped[key]
      end
   end
   return nil
end

--- Says in the innermost scope that `why` dropped the fact of `key` that a
--- guard would have given there, which no scope holds: the guard was cut
--- before it was applied.
function narrowing.cut(scopes: {narrowing.Scope}, key: string, why: narrowing.Drop)
   local scope = scopes[#scopes]
   scope.dropped = scope.dropped or {}
   scope.dropped[key] = why
   tell(scopes, key)
end

--- The places a guard is about, each once, in the order they are met.
function narrowing.places(g: narrowing.Guard): {narrowing.Place}
   local found: {narrowing.Place} = {}
   local seen: {string:boolean} = {}
   local function walk(f: narrowing.Guard)
      if f == nil then
         return
      end
      if f.place and not seen[f.place.key] then
         seen[f.place.key] = true
         table.insert(found, f.place)
      end
      walk(f.f1)
      walk(f.f2)
   end
   walk(g)
   return found
end

--- Called with a function literal's scope the innermost: hides from the
--- body what is known of the places outside it. The body runs later, when
--- what a test established may no longer hold, so it begins with the types
--- the places were declared with and learns what it tests itself. A field
--- path is hidden always; a local is hidden unless `fixed` says nothing
--- assigns it once it is declared, which no code that runs before the body
--- can change. `why` is told by a read in the body of a place hidden.
--- Creating the function runs none of its body, so the facts outside it
--- stand after it, and `leave_function` puts them back.
function narrowing.enter_function(scopes: {narrowing.Scope}, why: narrowing.Drop,
                                  fixed: function(string): boolean)
   local inner = scopes[#scopes]
   local hidden: {narrowing.Hidden} = {}
   for i = #scopes - 1, 1, -1 do
      local scope = scopes[i]
      local keys: {string} = {}
      for key in pairs(scope.narrows or {}) do
         if key:find(".", 1, true) or not fixed(key) then
            keys[#keys + 1] = key
         end
      end
      table.sort(keys)
      for _, key in ipairs(keys) do
         local var = scope.vars[key]
         -- A local declared `local x = x` that nothing narrowed holds its
         -- declared type; a narrowed one remembers it in `widened_from`.
         if var and (var.is_specialized ~= "localizing" or var.widened_from) then
            local h: narrowing.Hidden = {
               scope = scope, key = key, var = var, restore = false,
               t = no_type, is_specialized = no_name, specialized_from = no_type, widened_from = no_type,
            }
            if var.specialized_from or var.widened_from then
               -- The variable is declared in this scope: it holds its
               -- declared type again until the body is done.
               h.restore = true
               h.t = var.t
               h.is_specialized = var.is_specialized
               h.specialized_from = var.specialized_from
               h.widened_from = var.widened_from
               var.t = var.specialized_from or var.widened_from
               if var.is_specialized ~= "widen" and var.is_specialized ~= "localizing" then
                  var.is_specialized = nil
               end
               var.specialized_from = nil
               var.widened_from = nil
            else
               scope.vars[key] = nil
            end
            table.insert(hidden, h)
            scope.narrows[key] = nil
            inner.dropped = inner.dropped or {}
            inner.dropped[key] = why
            tell(scopes, key)
         end
      end
   end
   inner.hidden = hidden
end

--- Puts back the facts `enter_function` hid, once the function's scope
--- has ended.
function narrowing.leave_function(_scopes: {narrowing.Scope}, hidden: {narrowing.Hidden})
   for i = #hidden, 1, -1 do
      local h = hidden[i]
      if h.restore then
         h.var.t = h.t
         h.var.is_specialized = h.is_specialized
         h.var.specialized_from = h.specialized_from
         h.var.widened_from = h.widened_from
      else
         h.scope.vars[h.key] = h.var
      end
      h.scope.narrows = h.scope.narrows or {}
      h.scope.narrows[h.key] = true
   end
end

--- Where the journal of drops is now, for `undo`.
function narrowing.mark(scopes: {narrowing.Scope}): integer
   local journal = scopes[1].journal
   return journal and #journal or 0
end

--- Puts back what the drops since `mark` removed, newest first, except
--- a fact that has been narrowed again since. The drops of a block that
--- never reaches the code after it do not matter to that code.
function narrowing.undo(scopes: {narrowing.Scope}, mark: integer)
   local journal = scopes[1].journal
   if not journal then
      return
   end
   for i = #journal, mark + 1, -1 do
      local gone = table.remove(journal)
      local scope = gone.scope
      if gone.var and scope.vars[gone.key] == nil then
         scope.vars[gone.key] = gone.var
         if gone.narrowed then
            scope.narrows = scope.narrows or {}
            scope.narrows[gone.key] = true
         end
      end
      if scope.dropped then
         scope.dropped[gone.key] = gone.told
      end
   end
end

--- Forgets that anything dropped `key`: the place is narrowed again.
function narrowing.renarrowed(scopes: {narrowing.Scope}, key: string)
   local told = scopes[1].told
   if not told or not told[key] then
      return
   end
   for i = #scopes, 1, -1 do
      local scope = scopes[i]
      if scope.dropped then
         scope.dropped[key] = nil
      end
   end
end

-- A guard of kind `is` or `==`: a test of `place`. Each field is given,
-- those the kind does not use nil.
local function test(kind: narrowing.Kind, w: narrowing.Where, place: narrowing.Place,
                    typ: narrowing.Type, no_infer: boolean): narrowing.Guard
   assert(w)
   local f1: narrowing.Guard = nil
   local f2: narrowing.Guard = nil
   return { fact = kind, w = w, no_infer = no_infer, f1 = f1, f2 = f2, place = place, typ = typ }
end

-- A guard of kind `not`, `and`, `or` or `truthy`, combining `f1` and `f2`.
local function join(kind: narrowing.Kind, w: narrowing.Where, f1: narrowing.Guard,
                    f2: narrowing.Guard): narrowing.Guard
   local place: narrowing.Place = nil
   local typ: narrowing.Type = nil
   local no_infer: boolean = nil
   return { fact = kind, w = w, no_infer = no_infer, f1 = f1, f2 = f2, place = place, typ = typ }
end

-- What a guard leaves out, nil. This file holds it in locals because the
-- checker refuses a literal nil where a value is declared.
local absent: narrowing.Guard = nil
local nowhere: narrowing.Where = nil

local TRUTHY: narrowing.Guard = join("truthy", nowhere, absent, absent)

--- The guard of an expression that is either truthy or a run-time error:
--- a literal, a table constructor, an arithmetic or concatenation result.
narrowing.truthy = TRUTHY

--- `place` is of type `typ`: a truthiness read, a comparison with nil,
--- `is`, `type(x) == "..."`. Its negation subtracts `typ`.
function narrowing.type_is(w: narrowing.Where, place: narrowing.Place,
                           typ: narrowing.Type): narrowing.Guard
   return test("is", w, place, typ, false)
end

--- `place` equals a value of type `typ`. Its negation proves nothing.
function narrowing.value_is(w: narrowing.Where, place: narrowing.Place,
                            typ: narrowing.Type): narrowing.Guard
   return test("==", w, place, typ, false)
end

--- `not g`; nil when `g` is nil, a test that gives nothing.
function narrowing.negate(w: narrowing.Where, g: narrowing.Guard): narrowing.Guard
   if g then
      return join("not", w, g, absent)
   end
   return nil
end

--- `f1 and f2`; nil when neither gives anything.
function narrowing.both(w: narrowing.Where, f1: narrowing.Guard,
                        f2: narrowing.Guard): narrowing.Guard
   if not f1 and not f2 then
      return nil
   end
   return join("and", w, f1, f2)
end

--- `f1 or f2`, an operand that gives nothing counting as truthy.
function narrowing.either(w: narrowing.Where, f1: narrowing.Guard,
                          f2: narrowing.Guard): narrowing.Guard
   return join("or", w, f1 or TRUTHY, f2 or TRUTHY)
end

-- TODO: the checker joins the tests of `x is A | B | C` pairwise and
-- keeps the last pair's, so the true branch narrows to `B | C`, losing
-- `A`, and the false branch still holds `A`. A join of all the members
-- accepts programs the checker refuses today. It waits on the roadmap
-- item that makes every guard read every place alike.

--- `f1 or f2` as the tests of a union's members are joined: an operand
--- that gives nothing stays absent.
function narrowing.any_of(w: narrowing.Where, f1: narrowing.Guard,
                          f2: narrowing.Guard): narrowing.Guard
   return join("or", w, f1, f2)
end

--- The guard of control reaching past the branches `blocks[1]` to
--- `blocks[n]` of an `if`: none of their conditions held. A branch with
--- no condition (`else`) adds none.
function narrowing.none_of(w: narrowing.Where, blocks: {narrowing.Node}, n: integer): narrowing.Guard
   local f = narrowing.negate(w, blocks[1].exp.guard)
   for e = 2, n do
      local b = blocks[e]
      if b.exp then
         f = narrowing.both(w, f, narrowing.negate(w, b.exp.guard))
      end
   end
   return f
end

--- `g` without the facts about places `droppable` says something can
--- change: what a test established before code ran that may have changed
--- the place it tested. Nil when nothing is left.
function narrowing.forget(g: narrowing.Guard, droppable: function(narrowing.Place): boolean): narrowing.Guard
   if g == nil then
      return nil
   elseif g.fact == "is" or g.fact == "==" then
      if droppable(g.place) then
         return nil
      end
      return g
   elseif g.fact == "truthy" then
      return g
   elseif g.fact == "not" then
      return narrowing.negate(g.w, narrowing.forget(g.f1, droppable))
   end
   local f1 = narrowing.forget(g.f1, droppable)
   local f2 = narrowing.forget(g.f2, droppable)
   if g.fact == "and" then
      return narrowing.both(g.w, f1, f2)
   end
   -- An operand that gives nothing counts as truthy.
   return join("or", g.w, f1 or (g.f1 and TRUTHY), f2 or (g.f2 and TRUTHY))
end

local function describe(host: narrowing.Host, g: narrowing.Guard): string
   if g == nil then
      return "nil"
   end
   local function show(f: narrowing.Guard): string
      return describe(host, f)
   end
   if g.fact == "is" then
      return ("(%s is %s)"):format(g.place.key, host.show(g.typ))
   elseif g.fact == "==" then
      return ("(%s == %s)"):format(g.place.key, host.show(g.typ))
   elseif g.fact == "truthy" then
      return "*"
   elseif g.fact == "not" then
      return ("(not %s)"):format(show(g.f1))
   elseif g.fact == "and" then
      return ("(%s and %s)"):format(show(g.f1), show(g.f2))
   end
   return ("(%s or %s)"):format(show(g.f1), show(g.f2))
end

local function sorted_keys(m: {string:narrowing.Guard}): {string}
   local keys: {string} = {}
   for k, _ in pairs(m) do
      table.insert(keys, k)
   end
   table.sort(keys)
   return keys
end

local evaluate: function(narrowing.Host, narrowing.Guard): {string:narrowing.Guard} = nil
local evaluate_not: function(narrowing.Host, narrowing.Guard): {string:narrowing.Guard} = nil

local function invalid_from(host: narrowing.Host, f: narrowing.Guard): narrowing.Guard
   return test("is", f.w, f.place, host.invalid(f.w), false)
end

-- What a negated test leaves of the places it was about: a type-based
-- fact subtracts its type; a value-based one, or one about a type
-- variable, proves nothing and widens the place back.
local function not_facts(host: narrowing.Host, fs: {string:narrowing.Guard}): {string:narrowing.Guard}
   local ret: {string:narrowing.Guard} = {}
   for var, f in pairs(fs) do
      -- A field's current type is not always one the checker already
      -- tracks for the place: see Host.type_of.
      local typ = host.type_of(f.place, f.w)

      if not typ then
         -- A field that cannot be resolved here has moved past the scope
         -- its fact was built in: drop it silently instead of reporting
         -- an unresolvable variable, which a genuine local miss still does.
         if #f.place.fields == 0 then
            ret[var] = test("==", f.w, f.place, host.invalid(f.w), f.no_infer)
         end
      elseif f.fact == "==" then
         -- nothing is known from negation of equality; widen back
         ret[var] = test("==", f.w, f.place, typ, true)
      elseif typ.typename == "typevar" then
         assert(f.fact == "is")
         -- nothing is known from negation on typeargs; widen back
         ret[var] = test("==", f.w, f.place, typ, true)
      elseif not host.is_a(f.typ, typ) then
         assert(f.fact == "is")
         host.warn_never(f.w, f.place.key, typ, f.typ)
         ret[var] = test("==", f.w, f.place, host.invalid(f.w), f.no_infer)
      else
         assert(f.fact == "is")
         ret[var] = test("is", f.w, f.place, host.subtract(f.w, typ, f.typ), f.no_infer)
      end
   end
   return ret
end

local function or_facts(host: narrowing.Host, fs1: {string:narrowing.Guard},
                        fs2: {string:narrowing.Guard}): {string:narrowing.Guard}
   local ret: {string:narrowing.Guard} = {}

   for var, f in pairs(fs2) do
      if fs1[var] then
         local united = host.unite(f.w, f.typ, fs1[var].typ)
         if fs1[var].fact == "is" and f.fact == "is" then
            ret[var] = test("is", f.w, f.place, united, false)
         else
            ret[var] = test("==", f.w, f.place, united, false)
         end
      end
   end

   return ret
end

-- A place both sides say something of keeps the kind they share, and one
-- only a side says something of is value-based. So a map of two places or
-- more is all value-based: type-based facts about two places are never
-- mixed with value-based ones, and nothing needs to downgrade them.
local function and_facts(host: narrowing.Host, fs1: {string:narrowing.Guard},
                         fs2: {string:narrowing.Guard}): {string:narrowing.Guard}
   local ret: {string:narrowing.Guard} = {}

   for var, f in pairs(fs1) do
      local rt: narrowing.Type
      local kind: narrowing.Kind = "=="
      if fs2[var] then
         if fs2[var].fact == "is" and f.fact == "is" then
            kind = "is"
         end
         rt = host.intersect(f.w, f.typ, fs2[var].typ)
      else
         rt = f.typ
      end
      local ff = test(kind, f.w, f.place, rt, f.no_infer)
      ret[var] = ff
   end

   for var, f in pairs(fs2) do
      if not fs1[var] then
         ret[var] = test("==", f.w, f.place, f.typ, f.no_infer)
      end
   end

   return ret
end

evaluate_not = function(host: narrowing.Host, f: narrowing.Guard): {string:narrowing.Guard}
   if not f then
      return {}
   elseif f.fact == "is" then
      return not_facts(host, { [f.place.key] = f })
   elseif f.fact == "not" then
      return evaluate(host, f.f1)
   elseif f.fact == "and" and f.f2 and f.f2.fact == "truthy" then
      return evaluate_not(host, f.f1)
   elseif f.fact == "or" and f.f2 and f.f2.fact == "truthy" then
      return evaluate_not(host, f.f1)
   elseif f.fact == "and" then
      return or_facts(host, evaluate_not(host, f.f1), evaluate_not(host, f.f2))
   elseif f.fact == "or" then
      return and_facts(host, evaluate_not(host, f.f1), evaluate_not(host, f.f2))
   else
      return not_facts(host, evaluate(host, f))
   end
end

evaluate = function(host: narrowing.Host, f: narrowing.Guard): {string:narrowing.Guard}
   if not f then
      return {}
   elseif f.fact == "is" then
      -- A field's current type is not always one the checker already
      -- tracks for the place: see Host.type_of.
      local typ = host.type_of(f.place, f.w)
      if not typ then
         -- An unresolvable field drops silently rather than reporting an
         -- unresolvable variable: see not_facts.
         if #f.place.fields > 0 then
            return {}
         end
         return { [f.place.key] = invalid_from(host, f) }
      end
      if typ.typename ~= "typevar" then
         if host.is_a(typ, f.typ) then
            -- A warning that the test always holds is dropped, because
            -- nil is a member of every union.
            return { [f.place.key] = f }
         elseif not host.is_a(f.typ, typ) then
            host.refuse_never(f.w, f.place.key, typ, f.typ)
            return { [f.place.key] = invalid_from(host, f) }
         end
      end
      return { [f.place.key] = f }
   elseif f.fact == "==" then
      return { [f.place.key] = f }
   elseif f.fact == "not" then
      return evaluate_not(host, f.f1)
   elseif f.fact == "truthy" then
      return {}
   elseif f.fact == "and" and f.f2 and f.f2.fact == "truthy" then
      return evaluate(host, f.f1)
   elseif f.fact == "or" and f.f2 and f.f2.fact == "truthy" then
      -- `a or b` held with `b` telling nothing: either `a` held, or `a`
      -- failed and `b` held, so what is known is what `a` and `not a` share,
      -- which is nothing.
      return {}
   elseif f.fact == "and" then
      return and_facts(host, evaluate(host, f.f1), evaluate(host, f.f2))
   elseif f.fact == "or" then
      return or_facts(host, evaluate(host, f.f1), evaluate(host, f.f2))
   end
end

if os.getenv("TL_DEBUG_FACTS") then
   local trace = { indent = -1 }
   local untraced = evaluate
   evaluate = function(host: narrowing.Host, known: narrowing.Guard): {string:narrowing.Guard}
      trace.indent = trace.indent + 1
      io.stderr:write(("   "):rep(trace.indent))
      io.stderr:write("eval fact: ", describe(host, known), "\n")
      local facts = untraced(host, known)
      if facts then
         for _, k in ipairs(sorted_keys(facts)) do
            io.stderr:write(("   "):rep(trace.indent), "=> ", describe(host, facts[k]), "\n")
         end
      else
         io.stderr:write(("   "):rep(trace.indent), "=> .\n")
      end
      trace.indent = trace.indent - 1
      return facts
   end
end

--- What `g` tells of places: a fact of kind `is` or `==` for each place
--- it is about, by key.
function narrowing.evaluate(host: narrowing.Host, g: narrowing.Guard): {string:narrowing.Guard}
   return evaluate(host, g)
end

return narrowing
