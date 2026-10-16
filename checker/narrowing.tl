-- Narrowing: what the checker knows of a place after a test of it. A
-- place is what a program names and can change; the fork narrows only a
-- local, and a test of a field of one or of a global is evaluated and
-- refused. A guard is a test (a truthiness read, a comparison, `is`,
-- `type(x) == "..."`, an assert-like call) or a combination of tests
-- (`not`, `and`, `or`). A guard evaluates to the facts it gives, one per
-- place; the checker holds those of a local keyed by the binding, and drops
-- what is known of a place where its value can change. It holds none of a
-- field or a global: a test of one is evaluated and refused
-- (`TypeChecker:refuse_narrowing`), since code that runs between the test and
-- a use can change the place.
--
-- The checker (checker/tl.tl) builds a guard on each expression and applies
-- one wherever a branch begins or an expression is cut short: the body of
-- an `if` or a `while`, the right operand of `and` and `or`, what follows
-- an `assert`, and what follows an `if` all of whose branches end
-- ([`flow.ends_all`]) by the negation of its conditions.
--
-- The facts the checker reads are in `checker/facts.tl`.
--
-- A fact is dropped by an assignment to its place, and by code that runs (a
-- call, an operator that dispatches, the end of a block holding a `<close>`
-- local whose type declares `__close`) where the place is a local that no
-- code of the file alone assigns. Each drop says what dropped the place
-- ([`narrowing.because`]), so the refusal of a use that relied on the fact
-- can say so. A guard built before code ran is cut of the facts that code
-- may have changed ([`narrowing.forget`]).
--
-- Evaluating a guard asks the checker what it alone knows: a place's
-- current type, whether one type is another, how to unite, intersect or
-- subtract two. It answers through a [`narrowing.Host`] it is handed, so
-- this file names none of the checker's types.
--
-- This file holds only upstream Teal 0.24.8: the boot compiles it with
-- the pinned release's seed (build.zig), as it does checker/tl.tl.
--
-- TODO: `Place.fields` carries a field path and `Host.type_of` walks it, so
-- that a guard names the places of a test alike for the refusal that says
-- what the test would have given; the fork narrows none of them. It waits
-- on the new checker, where a path of fixed fields is a place
-- (doc/plans/strict-teal-narrowing.md, doc/roadmap.md's item that makes
-- every guard read every place alike).
--
-- TODO: reading a declared field of a record that declares `__index` or
-- `__newindex` runs it when the field is absent, and drops nothing that is
-- known. It waits on doc/roadmap.md's item that makes a metamethod's run
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
      -- A name free where that test is for a local holding a copy of the
      -- place, for the hint of a refusal to give.
      copy: string
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
   places: function(Guard): {Place}
   forget: function(Guard, function(Place): boolean): Guard
   because: function(string, string, integer, integer): Drop
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

--- What dropped a fact: a `kind` of drop (see [`narrowing.Drop`]), the
--- expression as a message shows it, and where it begins.
function narrowing.because(kind: string, text: string, y: integer, x: integer): narrowing.Drop
   return { kind = kind, text = text, y = y, x = x, place = no_place, copy = no_name }
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

--- What `g` tells of places: a fact of kind `is` or `==` for each place
--- it is about, by key.
function narrowing.evaluate(host: narrowing.Host, g: narrowing.Guard): {string:narrowing.Guard}
   return evaluate(host, g)
end

return narrowing
