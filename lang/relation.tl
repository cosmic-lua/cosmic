--- The subtype relation of the new checker
--- ([`doc/plans/new-checker-types.md`], "the relation"): whether a value of one
--- type of a [`lang.types`] store may stand where another is wanted, and, where it
--- may not, a structured reason a later error renders in the program's own terms.
---
--- A [`Relation.Judge`] belongs to one store. [`Relation.Judge.subtype`] answers a
--- boolean; [`Relation.Judge.refuse`] answers nil where the relation holds and a
--- [`Relation.Refusal`] where it does not. [`Relation.Judge.accepts`] and
--- [`Relation.Judge.refuse_argument`] are the one position where a value may
--- reach `any`: an argument to a parameter declared `any`.
---
--- **The rules** are those of "the relation" in the plan, over the interned
--- types of the store, so identity is `==`:
---
--- - `never` is below every type and nothing else is below it. `nil` is below
---   `nil` and a type with the nil flag, and no other type admits it, a type
---   variable included.
--- - `integer` is below `number`, an enum below `string`, `true` and `false`
---   below `boolean`, and nothing else is below an atom.
--- - A union is below a type when each member and its `nil` are; a type is below
---   a union when it is below a member.
--- - A view `{A}` or `{K: V}` is covariant in its element and value, and a
---   map's key is invariant even in a view. A `mut` collection is below a view
---   and below the same `mut` collection, nothing else: its element, key and
---   value must be the same type. A view is never below a `mut` collection. A
---   record with an array part `T` is below `{T}`.
--- - A recursive alias (a [`Named`] of kind `alias`) is below what its body is below and above what is below its
---   body, one level read at a time; two aliases are related only where they are one, and a record, a class or an interface is below none.
--- - A named type is nominal. Two uses of one declaration are related when their
---   arguments are the same types; a use is below an interface only when its
---   declaration lists the interface, or one that extends it, with `is`, the
---   arguments of each listing read through the declaration. A record is not a
---   map and a map is not a record. A declaration used as a value (a [`Named`] with
---   `value`) is below itself alone: it is no instance of the declaration, lists no
---   interface and has no array part.
--- - A function is below another when every argument count the other takes is
---   accepted (a parameter the other may omit is omittable here, one it does not
---   have is omittable here, a rest parameter is met by a rest parameter), each
---   parameter of the other is below the matching one here, and each return
---   alternative here is below one of the other's with as many values. A
---   function that never returns has no alternative and is below every function
---   of its parameters. A method has no receiver exemption. A narrowing declaration is met
---   by one with the same parameter and kind: `asserts v is T` takes a narrower `T`, and
---   `v is T` the same `T`, since the checker removes `T` on its false edge.
--- - A generic function is below a function type that is not generic when its type
---   parameters can be taken from it: each from the parameter of the type wanted in its
---   place, else from what the type wanted answers, and each meeting its bound
---   ([`lang.generics`]). The function with those types in is then compared as any other. A
---   generic function type wanted is met only by itself.
--- - A type variable is below itself and its bound. The bound is read from the
---   binders [`Relation.Judge.enter`] has entered.
--- - `any` is below `any` and nothing below it but `never`.
---
--- **Refusals.** A [`Relation.Refusal`] has the `code` of the rule that failed, the
--- `path` from the pair compared to the parts that failed, and those parts as
--- `sub` and `super`. A `parameter` or `rest` step swaps the roles: the `sub` of the
--- leaf is then a part of the type that was the target of the comparison. The
--- reason is built only on request, so a relation that holds or fails
--- unexplained builds none.
---
--- **Caching.** A judge remembers every pair it has settled, keyed by the ids of the two
--- types: a pair of closed types for good, a pair that mentions a type variable for the
--- binders it was asked under. It also keeps what a declaration lists. It assumes the
--- declarations it has read are final, so a type is related only after the declarations it
--- names are defined: a type whose declaration has no body to read raises `relation:
--- <declaration> is not defined`. Its caches are keyed by the ids of the store, which a
--- refused decode reuses, so a judge raises `relation: a decode is open` when a type is
--- related while one is (a [`lang.types`] loader that relates types would leave the judge
--- with ids that mean other types). A judge is not re-entrant.

local Generics = require("lang.generics")
local Types = require("lang.types")

local type Type = Types.Type
local type Atom = Types.Atom
local type Named = Types.Named
local type Array = Types.Array
local type Map = Types.Map
local type Union = Types.Union
local type Var = Types.Var
local type Fn = Types.Fn
local type Alt = Types.Alt
local type Store = Types.Store

local record Relation
  --- The rule a refusal is about, at the leaf of its path:
  ---
  --- - `mismatch`: no rule relates the two forms. `nominal`: two declarations, the target
  ---   not an interface. `not_listed`: the target is an interface the source's declaration
  ---   does not list. `declaration_value`: a declaration used as a value, the table of its
  ---   functions, where a value of it is wanted, or the reverse. `variable`: a type variable, below only itself and its bound.
  --- - `nil`: the source is `nil` and the target admits none. `number_for_integer`: a `number`
  ---   where an `integer` is wanted. `never_target`: nothing is below `never`.
  --- - `any_source`: the data of `any` is no other type. `any_sink`: a value reaches `any` only as
  ---   an argument to a parameter declared `any`.
  --- - `view_as_mut`: a view, or a record's array part, where a `mut` collection is wanted.
  ---   `invariant_mut`: the elements, keys or values of two `mut` collections are two types.
  ---   `invariant_key`: the keys of two maps are two types. `invariant_generic`: the arguments
  ---   of two uses of one declaration are two types.
  --- - `record_as_map` and `map_as_record`: a record is no map and a map is no record.
  --- - `union_none`: no member of the target union takes the source; `alternatives` says why
  ---   for each.
  --- - `generic_function`: a generic function type is below only itself and the function types its type
  ---   parameters can be solved from; a generic function type wanted is met only by itself.
  --- - `arity`: the functions disagree on whether the argument at `index` is passed.
  ---   `may_return`: the function may return where the target never does. `return_unmatched`:
  ---   none of the alternatives of the target takes an alternative of the source.
  ---   `return_length`: the lists differ in length or in whether one ends in `T...`.
  ---   `narrows_missing` and `narrows_other`: the target narrows an argument and the source
  ---   narrows none, or another, or by `asserts` where the other is `is`. `invariant_narrows`:
  ---   the types of two `v is T` declarations are two types, since the false edge removes T.
  enum Code
    "mismatch"
    "nominal"
    "nil"
    "number_for_integer"
    "never_target"
    "any_source"
    "any_sink"
    "view_as_mut"
    "invariant_mut"
    "invariant_key"
    "invariant_generic"
    "not_listed"
    "declaration_value"
    "record_as_map"
    "map_as_record"
    "variable"
    "union_none"
    "generic_function"
    "arity"
    "may_return"
    "return_unmatched"
    "return_length"
    "narrows_missing"
    "narrows_other"
    "invariant_narrows"
  end

  --- A part of a type a refusal went into. `nil` is the nil of a source union, `bound` the
  --- bound of a type variable, `array_part` the array part of a record, `rest` the rest
  --- parameter of the function wanted, which stands at every position from `index` on,
  --- `narrows` the type of a narrowing declaration and `tail` the `T...` of a list.
  enum StepKind
    "element"
    "key"
    "value"
    "member"
    "nil"
    "target_alternative"
    "argument"
    "array_part"
    "parameter"
    "rest"
    "alternative"
    "item"
    "tail"
    "narrows"
    "bound"
  end

  --- One step from a pair compared to a pair inside it. `index` counts from 1: the
  --- member of a source union, the type argument, the parameter, the alternative
  --- of the function given (`alternative`) or of the one wanted
  --- (`target_alternative`), the item of a return list.
  record Step
    kind: StepKind
    index?: integer
  end

  --- Why `sub` is not below `super`.
  record Refusal
    code: Code
    --- From the pair that was compared to the parts that failed.
    path: {Step}
    --- The parts that failed, as they were compared.
    sub: Type
    super: Type
    --- The position, for `arity`: the parameter from 1 that the functions disagree on.
    index?: integer
    --- For `union_none`, why each member of the target refused (as far as the first
    --- sixteen), and for `return_unmatched`, why each alternative of the function
    --- wanted did. Each has the path from the pair of its own members.
    alternatives?: {Refusal}
    --- For `not_listed`, every interface the declaration of `sub` lists, directly or
    --- through the ones it extends, as the uses its arguments make.
    lists?: {Type}
  end

  --- The binders a judge reads the bounds of type variables from, and what it settled
  --- under them.
  record Scope
    tparams: {Types.TParam}
    memo: {integer: boolean}
  end

  --- What a declaration lists.
  record Closure
    set: {integer: boolean}
    list: {Type}
    --- Whether every listing is in `list`: false where `MAX_LISTED` ended it or a listing would
    --- nest past the store's depth.
    complete: boolean
    --- The uses in `list`, by declaration.
    by_decl: {Types.Decl: {Named}}
  end

  --- What a declaration lists ([`Relation.Judge.listed`]).
  record Listing
    types: {Type}
    --- Whether `types` is all of them. It is not where the closure is as large as the judge reads
    --- (4096) or a listing would nest deeper than a store allows ([`Types.max_depth`]): the
    --- relation then holds for the listings in `types` alone.
    complete: boolean
  end

  --- The relation of one store.
  record Judge
    store: Store
    --- Pairs of closed types, and pairs of types that mention a variable under no binder.
    closed: {integer: boolean}
    free: {integer: boolean}
    scopes: {Scope}
    closures: {integer: Closure}
    sets: {integer: {integer: boolean}}
    --- The reasons built by the request in progress, by pair.
    explained: {integer: Refusal}
    --- What a refusal is when no reason is wanted, so that no refusal allocates.
    none: Refusal
    nil_type: Type

    --- Whether `a` is below `b`. Raises for a type of another store.
    subtype: function(Judge, a: Type, b: Type): boolean
    --- Nil where `a` is below `b`, else why not.
    refuse: function(Judge, a: Type, b: Type): Refusal | nil
    --- Whether `argument` may be passed to a parameter of type `param`: below it, or any
    --- value where the parameter is declared `any`.
    accepts: function(Judge, argument: Type, param: Type): boolean
    --- Nil where `argument` may be passed to `param`, else why not.
    refuse_argument: function(Judge, argument: Type, param: Type): Refusal | nil
    --- Every interface that the declaration of `n` lists after `is`, and every one those extend,
    --- with the arguments of each listing read through the declarations, in the order the
    --- listings are met. Raises where a declaration it reads is not defined.
    listed: function(Judge, n: Named): Listing
    --- Enters a binder: the type variables of the types compared from now on, the nearest
    --- binder's at depth 0, are bounded by `tparams` until [`Relation.Judge.leave`]. A bound is an
    --- interface used with no arguments, as a store requires; anything else raises.
    enter: function(Judge, tparams: {Types.TParam})
    --- Leaves the binder entered last.
    leave: function(Judge)
  end

  --- A judge for the types of `store`.
  new: function(store: Store): Judge

  --- `t`, which is written inside a declaration with type parameters, with each of them replaced
  --- by the matching type of `args`, which stand where the declaration is used; or nil where the
  --- type it makes would nest deeper than the store allows ([`Types.max_depth`]). Raises where `t`
  --- names a variable of a binder other than the one declaration's, or `args` is another store's.
  instantiate: function(store: Store, t: Type, args: {Type}): Type | nil

  --- The binder of a declaration: its type parameters and their bounds. Raises where the
  --- declaration has no body.
  binder: function(decl: Types.Decl): {Types.TParam}

  --- The generic function type `f` with each of its type parameters replaced by the matching type of `args`, which
  --- stand where the function is used: a function type with no type parameters. Nil where the type it makes would
  --- nest deeper than the store allows. The variables of the binders around `f` keep their meaning.
  specialize: function(store: Store, f: Fn, args: {Type}): Fn | nil

  --- The refusal's code and path in one line, for a test or a log: not what an error prints.
  trace: function(r: Refusal): string
end

--- How many members of a target union a refusal explains.
local MAX_ALTERNATIVES <const> = 16

--- How many interfaces a closure holds at most. A store refuses a declaration that lists itself,
--- so a closure is finite, but a ladder of declarations that each list the next twice with
--- other arguments has a closure as large as the ladder is long, doubled each step. The judge
--- stops here, and [`Relation.Judge.listed`] says it did, so that [`lang.declarations`] refuses
--- the declaration whose closure it is.
local MAX_LISTED <const> = 4096

local judge_mt: metatable<Relation.Judge> = { __index = Relation.Judge }

-- Results ------------------------------------------------------------------------------------

--- A refusal about `a` and `b`, or the judge's shared one where no reason is wanted.
local function leaf(j: Relation.Judge, why: boolean, code: Relation.Code, a: Type, b: Type): Relation.Refusal
  if not why then
    return j.none
  end
  return { code = code, path = {}, sub = a, super = b }
end

--- `r` seen from a pair that holds its pair at `kind`. A refusal is never changed, since the
--- reasons of one request are shared.
local function through(why: boolean, kind: Relation.StepKind, index: integer | nil, r: Relation.Refusal): Relation.Refusal
  if not why then
    return r
  end
  local path: {Relation.Step} = { { kind = kind, index = index } }
  for _, step in ipairs(r.path) do
    path[#path + 1] = step
  end
  return {
    code = r.code, path = path, sub = r.sub, super = r.super, index = r.index,
    alternatives = r.alternatives, lists = r.lists,
  }
end

-- Instantiation -------------------------------------------------------------------------------

--- `t` rebuilt with `on_var` answering for each variable that reaches `level` binders out
--- or more. `level` is how many binders of `t` itself the walk is inside. A type that
--- reaches fewer is returned as it is.
local function rewrite(
    store: Store, t: Type, level: integer, on_var: function(v: Var, level: integer): Type, memo: {string: Type}
): Type
  if t.open <= level then
    return t
  end
  local key = t.id .. ":" .. level
  local held = memo[key]
  if held ~= nil then
    return held
  end
  local out: Type
  if t is Var then
    out = on_var(t, level)
  elseif t is Named then
    local args: {Type} = {}
    for i, part in ipairs(t.args) do
      args[i] = rewrite(store, part, level, on_var, memo)
    end
    out = store:named(t.decl, args, t.value)
  elseif t is Array then
    out = store:array(rewrite(store, t.element, level, on_var, memo), t.mut)
  elseif t is Map then
    out = store:map(rewrite(store, t.key, level, on_var, memo), rewrite(store, t.value, level, on_var, memo), t.mut)
  elseif t is Union then
    local members: {Type} = {}
    for i, m in ipairs(t.members) do
      members[i] = rewrite(store, m, level, on_var, memo)
    end
    if t.nilable then
      members[#members + 1] = store:atom("nil")
    end
    out = store:union(members)
  elseif t is Fn then
    local inside = #t.tparams > 0 and level + 1 or level
    local tparams: {Types.TParam} = {}
    for i, tp in ipairs(t.tparams) do
      local bound = tp.bound
      tparams[i] = { bound = bound ~= nil and rewrite(store, bound, inside, on_var, memo) or nil }
    end
    local params: {Types.Param} = {}
    for i, p in ipairs(t.params) do
      params[i] = { type = rewrite(store, p.type, inside, on_var, memo), omittable = p.omittable }
    end
    local rest = t.rest
    local rets: {Alt} = {}
    for i, alt in ipairs(t.rets) do
      local items: {Type} = {}
      for k, item in ipairs(alt.items) do
        items[k] = rewrite(store, item, inside, on_var, memo)
      end
      local tail = alt.tail
      local narrows = alt.narrows
      rets[i] = {
        items = items,
        tail = tail ~= nil and rewrite(store, tail, inside, on_var, memo) or nil,
        narrows = narrows ~= nil and {
          param = narrows.param, to = rewrite(store, narrows.to, inside, on_var, memo), asserts = narrows.asserts,
        } or nil,
      }
    end
    out = store:fn({
      tparams = tparams, params = params,
      rest = rest ~= nil and rewrite(store, rest, inside, on_var, memo) or nil,
      rets = rets,
    })
  else
    out = t
  end
  memo[key] = out
  return out
end

--- `t` with the variables that reach `by` binders further out than they do.
local function shift(store: Store, t: Type, by: integer): Type
  if by == 0 or t.open == 0 then
    return t
  end
  return rewrite(store, t, 0, function(v: Var, _: integer): Type
    return store:var(v.depth + by, v.index)
  end, {})
end

--- `t`, which is written inside a declaration with type parameters, with each of them
--- replaced by the matching type of `args`, which stand where the declaration is used.
local function instantiate(store: Store, t: Type, args: {Type}): Type
  if t.open == 0 then
    return t
  end
  return rewrite(store, t, 0, function(v: Var, level: integer): Type
    -- The body of a declaration names its own binder and no other.
    assert(v.depth == level, "relation: a declaration's body names a variable of no binder")
    local given = args[v.index + 1]
    if given == nil then
      return store.invalid
    end
    return shift(store, given, level)
  end, {})
end

--- [`instantiate`], or nil where the type it makes would nest past what the store allows.
-- TODO: refuse a use of a declaration in [`lang.declarations`] whose arguments would make a listing
-- or an array part nest past the store's depth, and drop this, once the lowering checks the height
-- that each listing chain adds: until then such a listing or array part is dropped, and a pair
-- that holds by it is refused.
local function instantiate_within(store: Store, t: Type, args: {Type}): Type | nil
  local made: {Type} = {}
  local ok, why = pcall(function()
    made[1] = instantiate(store, t, args)
  end)
  if ok then
    return made[1]
  end
  if tostring(why):find("types: a type nested deeper", 1, true) == nil then
    error(why, 0)
  end
  return nil
end

--- Raises where the declaration of `n` has no body to read.
local function defined(n: Named)
  if n.decl.body == nil then
    error("relation: " .. n.decl.name .. " is not defined", 0)
  end
end

-- What a declaration lists --------------------------------------------------------------------

--- Every interface that the declaration of `n` lists after `is`, and every one those
--- extend, with the arguments of `n` put in.
local function closure_of(j: Relation.Judge, n: Named): Relation.Closure
  local held = j.closures[n.id]
  if held ~= nil then
    return held
  end
  local closure: Relation.Closure = { set = {}, list = {}, by_decl = {}, complete = true }
  local queue: {Named} = { n }
  local head = 1
  while head <= #queue do
    local x = queue[head]
    head = head + 1
    defined(x)
    local body = x.decl.body
    if body ~= nil then
      for _, super in ipairs(body.supers) do
        local listed: Type | nil = super
        if #x.args > 0 then
          listed = instantiate_within(j.store, super, x.args)
        end
        if listed == nil then
          closure.complete = false
        elseif listed is Named and not closure.set[listed.id] then
          if #closure.list >= MAX_LISTED then
            closure.complete = false
          else
            closure.set[listed.id] = true
            closure.list[#closure.list + 1] = listed
            local same = closure.by_decl[listed.decl] or {}
            same[#same + 1] = listed
            closure.by_decl[listed.decl] = same
            queue[#queue + 1] = listed
          end
        end
      end
    end
  end
  j.closures[n.id] = closure
  return closure
end

--- Whether the interface `target` is in `closure`, or a use of its declaration whose arguments
--- are its own but for `invalid`, which stands for a mistake already reported.
local function lists(closure: Relation.Closure, target: Named): boolean
  if closure.set[target.id] then
    return true
  end
  for _, listed in ipairs(closure.by_decl[target.decl] or {}) do
    local same = true
    for i, held in ipairs(listed.args) do
      local other = target.args[i]
      if held ~= other and held.tag ~= "invalid" and other.tag ~= "invalid" then
        same = false
        break
      end
    end
    if same then
      return true
    end
  end
  return false
end

--- The type `n`'s declaration gives its array part, with the arguments of `n` put in, or nil.
local function array_part_of(j: Relation.Judge, n: Named): Type | nil
  defined(n)
  local body = n.decl.body
  if body == nil then
    return nil
  end
  local part = body.array
  if part == nil then
    return nil
  end
  if #n.args > 0 then
    return instantiate_within(j.store, part, n.args)
  end
  return part
end

--- The function type `f` with its own variables replaced by `args` and the variables of the binders around it, which
--- the binder of `f` no longer separates from the code around, numbered one binder nearer.
local function specialize(store: Store, f: Fn, args: {Type}): Fn
  local memo: {string: Type} = {}
  local function on_var(v: Var, level: integer): Type
    if v.depth == level then
      local given = args[v.index + 1]
      if given == nil then
        return store.invalid
      end
      return shift(store, given, level)
    end
    return store:var(v.depth - 1, v.index)
  end
  local function part(t: Type): Type
    return rewrite(store, t, 0, on_var, memo)
  end
  local params: {Types.Param} = {}
  for i, p in ipairs(f.params) do
    params[i] = { type = part(p.type), omittable = p.omittable }
  end
  local rest = f.rest
  local rets: {Alt} = {}
  for i, alt in ipairs(f.rets) do
    local items: {Type} = {}
    for k, item in ipairs(alt.items) do
      items[k] = part(item)
    end
    local tail = alt.tail
    local narrows = alt.narrows
    rets[i] = {
      items = items,
      tail = tail ~= nil and part(tail) or nil,
      narrows = narrows ~= nil and { param = narrows.param, to = part(narrows.to), asserts = narrows.asserts } or nil,
    }
  end
  local made = store:fn({ tparams = {}, params = params, rest = rest ~= nil and part(rest) or nil, rets = rets })
  if not (made is Fn) then
    error("relation: a function type is a function type")
  end
  return made
end

--- [`specialize`], or nil where the type it makes would nest past what the store allows.
local function specialize_within(store: Store, f: Fn, args: {Type}): Fn | nil
  local made: {Fn} = {}
  local ok, why = pcall(function()
    made[1] = specialize(store, f, args)
  end)
  if ok then
    return made[1]
  end
  if tostring(why):find("types: a type nested deeper", 1, true) == nil then
    error(why, 0)
  end
  return nil
end

-- The relation ---------------------------------------------------------------------------------

local rel: function(j: Relation.Judge, a: Type, b: Type, why: boolean): Relation.Refusal | nil

--- The memo that a pair may be kept in.
local function memo_of(j: Relation.Judge, a: Type, b: Type): {integer: boolean}
  if a.open == 0 and b.open == 0 then
    return j.closed
  end
  local top = j.scopes[#j.scopes]
  if top ~= nil then
    return top.memo
  end
  return j.free
end

--- The bound of the type variable `v` under the binders entered, or nil.
local function bound_of(j: Relation.Judge, v: Var): Type | nil
  local scope = j.scopes[#j.scopes - v.depth]
  if scope == nil then
    return nil
  end
  local tparam = scope.tparams[v.index + 1]
  if tparam == nil then
    return nil
  end
  return tparam.bound
end

--- The ids of the members of a union.
local function member_set(j: Relation.Judge, u: Union): {integer: boolean}
  local held = j.sets[u.id]
  if held ~= nil then
    return held
  end
  local set: {integer: boolean} = {}
  for _, m in ipairs(u.members) do
    set[m.id] = true
  end
  j.sets[u.id] = set
  return set
end

local function from_union(j: Relation.Judge, a: Union, b: Type, why: boolean): Relation.Refusal | nil
  for i, m in ipairs(a.members) do
    local r = rel(j, m, b, why)
    if r ~= nil then
      return through(why, "member", i, r)
    end
  end
  if a.nilable then
    local r = rel(j, j.nil_type, b, why)
    if r ~= nil then
      return through(why, "nil", nil, r)
    end
  end
  return nil
end

-- TODO: index the members of a target union by form, once the type report shows a union of many
-- arrays, maps or functions in the tree: a type below none of n members, or below only the last
-- of them, is compared with each, and n such types make n^2 comparisons. A member that is one of
-- the target's is found by its id, so a union checked against a superset costs n.
local function into_union(j: Relation.Judge, a: Type, b: Union, why: boolean): Relation.Refusal | nil
  if a.tag == "nil" then
    if b.nilable then
      return nil
    end
    return leaf(j, why, "nil", a, b)
  end
  if member_set(j, b)[a.id] then
    return nil
  end
  for _, m in ipairs(b.members) do
    if rel(j, a, m, false) == nil then
      return nil
    end
  end
  if not why then
    return j.none
  end
  local alternatives: {Relation.Refusal} = {}
  for i, m in ipairs(b.members) do
    if i > MAX_ALTERNATIVES then
      break
    end
    local r = rel(j, a, m, true)
    if r ~= nil then
      alternatives[#alternatives + 1] = through(true, "target_alternative", i, r)
    end
  end
  return { code = "union_none", path = {}, sub = a, super = b, alternatives = alternatives }
end

--- Whether `t` is a recursive alias ([`Types.DeclKind`] `alias`), which is what it names and nothing else.
local function is_alias(t: Type): boolean
  return t is Named and t.decl.kind == "alias"
end

--- `a` below `b` where one of them is a recursive alias: that one is read as the type it names, one level, and
--- the pair is compared again. The comparison ends because the other type is finite and a body names its alias only inside
--- an array or a map, which the comparison then goes into the other type's element or value to meet: each time the alias is
--- read, the other side is one level smaller. Two ways round that are closed. Two aliases are not compared by their bodies
--- (a body that mentions its own alias would send two of them round for ever), and are unrelated, as two declarations are.
--- A type that holds itself (a record whose array part is the record) does not get smaller, and is why a record, a class
--- or an interface is refused here before the alias is read. The refusal names the alias as it was written.
local function from_alias(j: Relation.Judge, a: Type, b: Type, why: boolean): Relation.Refusal | nil
  local a_alias, b_alias = is_alias(a), is_alias(b)
  if a_alias and b_alias then
    return leaf(j, why, "nominal", a, b)
  end
  -- A record, a class or an interface is never an arm of an alias: a record with an array part is below `{T}`, but it may have fields and methods
  -- besides (an encoder meets a table that mixes keys), so only the arrays and maps an alias names stand for it.
  if b_alias and a is Named and (a.decl.kind == "record" or a.decl.kind == "class" or a.decl.kind == "interface") then
    return leaf(j, why, "mismatch", a, b)
  end
  local ua, ub = Types.unfold(a), Types.unfold(b)
  if ua == a and ub == b then
    error("relation: " .. Types.display(a_alias and a or b) .. " is not defined", 0)
  end
  if a_alias and b is Union and member_set(j, b)[a.id] then
    return nil
  end
  local r = rel(j, ua, ub, why)
  if r == nil or not why then
    return r
  end
  return {
    code = r.code, path = r.path, sub = r.sub == ua and a or r.sub, super = r.super == ub and b or r.super,
    index = r.index, alternatives = r.alternatives, lists = r.lists,
  }
end

local function from_atom(j: Relation.Judge, a: Atom, b: Type, why: boolean): Relation.Refusal | nil
  local tag = a.tag
  if tag == "nil" then
    return leaf(j, why, "nil", a, b)
  elseif tag == "integer" and b.tag == "number" then
    return nil
  elseif (tag == "true" or tag == "false") and b.tag == "boolean" then
    return nil
  elseif tag == "number" and b.tag == "integer" then
    return leaf(j, why, "number_for_integer", a, b)
  end
  return leaf(j, why, "mismatch", a, b)
end

local function from_named(j: Relation.Judge, a: Named, b: Type, why: boolean): Relation.Refusal | nil
  if b is Named and a.value ~= b.value then
    return leaf(j, why, "declaration_value", a, b)
  elseif a.value then
    -- The table of a declaration's functions lists no interface, is no enum and has no array part.
    if not (b is Named) then
      return leaf(j, why, "mismatch", a, b)
    end
  end
  if b is Named then
    if a.decl == b.decl then
      if #a.args ~= #b.args then
        -- The count is not known until the declaration is defined.
        error("relation: " .. a.decl.name .. " is not defined", 0)
      end
      for i, held in ipairs(a.args) do
        local other = b.args[i]
        if held ~= other and held.tag ~= "invalid" and other.tag ~= "invalid" then
          return through(why, "argument", i, leaf(j, why, "invariant_generic", held, other))
        end
      end
      return nil
    end
    if b.decl.kind == "interface" then
      local closure = closure_of(j, a)
      if lists(closure, b) then
        return nil
      end
      if not why then
        return j.none
      end
      local copied: {Type} = {}
      for i, listed in ipairs(closure.list) do
        copied[i] = listed
      end
      return { code = "not_listed", path = {}, sub = a, super = b, lists = copied }
    end
    return leaf(j, why, "nominal", a, b)
  elseif b.tag == "string" and a.decl.kind == "enum" then
    return nil
  elseif b is Array then
    local part = array_part_of(j, a)
    if part == nil then
      return leaf(j, why, "mismatch", a, b)
    end
    if b.mut then
      return leaf(j, why, "view_as_mut", a, b)
    end
    local r = rel(j, part, b.element, why)
    if r ~= nil then
      return through(why, "array_part", nil, r)
    end
    return nil
  elseif b is Map then
    return leaf(j, why, "record_as_map", a, b)
  end
  return leaf(j, why, "mismatch", a, b)
end

local function from_array(j: Relation.Judge, a: Array, b: Type, why: boolean): Relation.Refusal | nil
  if not (b is Array) then
    return leaf(j, why, "mismatch", a, b)
  end
  if b.mut then
    if not a.mut then
      return leaf(j, why, "view_as_mut", a, b)
    end
    if a.element ~= b.element and a.element.tag ~= "invalid" and b.element.tag ~= "invalid" then
      return through(why, "element", nil, leaf(j, why, "invariant_mut", a.element, b.element))
    end
    return nil
  end
  local r = rel(j, a.element, b.element, why)
  if r ~= nil then
    return through(why, "element", nil, r)
  end
  return nil
end

local function from_map(j: Relation.Judge, a: Map, b: Type, why: boolean): Relation.Refusal | nil
  if b is Named then
    return leaf(j, why, "map_as_record", a, b)
  elseif not (b is Map) then
    return leaf(j, why, "mismatch", a, b)
  end
  if b.mut and not a.mut then
    return leaf(j, why, "view_as_mut", a, b)
  end
  if a.key ~= b.key and a.key.tag ~= "invalid" and b.key.tag ~= "invalid" then
    return through(why, "key", nil, leaf(j, why, b.mut and "invariant_mut" or "invariant_key", a.key, b.key))
  end
  if b.mut then
    if a.value ~= b.value and a.value.tag ~= "invalid" and b.value.tag ~= "invalid" then
      return through(why, "value", nil, leaf(j, why, "invariant_mut", a.value, b.value))
    end
    return nil
  end
  local r = rel(j, a.value, b.value, why)
  if r ~= nil then
    return through(why, "value", nil, r)
  end
  return nil
end

--- The type of the parameter at `i` of `f`, whether a call may leave it out, and whether it is
--- the rest parameter, which stands at every position past the last parameter. Nil where `f`
--- takes none.
local function slot(f: Fn, i: integer): Type | nil, boolean, boolean
  if i <= #f.params then
    local p = f.params[i]
    return p.type, p.omittable == true, false
  end
  local rest = f.rest
  if rest ~= nil then
    return rest, true, true
  end
  return nil, false, false
end

--- The refusal for parameter `i` where `f` and `g` disagree on whether an argument may be given.
local function arity(j: Relation.Judge, why: boolean, f: Fn, g: Fn, i: integer): Relation.Refusal
  local r = leaf(j, why, "arity", f, g)
  if why then
    r.index = i
  end
  return r
end

--- Whether `f` accepts every argument list that callers of `g` pass, parameter by parameter.
local function parameters_below(j: Relation.Judge, f: Fn, g: Fn, why: boolean): Relation.Refusal | nil
  local widest = math.max(#f.params, #g.params)
  for i = 1, widest do
    local gt, g_may_omit, g_is_rest = slot(g, i)
    local ft, f_may_omit = slot(f, i)
    if gt ~= nil then
      if ft == nil then
        return arity(j, why, f, g, i)
      end
      if g_may_omit and not f_may_omit then
        return arity(j, why, f, g, i)
      end
      local r = rel(j, gt, ft, why)
      if r ~= nil then
        if g_is_rest then
          return through(why, "rest", i, r)
        end
        return through(why, "parameter", i, r)
      end
    elseif not f_may_omit then
      return arity(j, why, f, g, i)
    end
  end
  local g_rest = g.rest
  if g_rest ~= nil then
    local f_rest = f.rest
    if f_rest == nil then
      return arity(j, why, f, g, widest + 1)
    end
    local r = rel(j, g_rest, f_rest, why)
    if r ~= nil then
      return through(why, "rest", widest + 1, r)
    end
  end
  return nil
end

--- Whether the alternative `fa` of `f` is below the alternative `ga` of `g`: as many values, each
--- below the matching one, and the narrowing `ga` declares.
local function alternative_below(
    j: Relation.Judge, f: Fn, g: Fn, fa: Alt, ga: Alt, why: boolean
): Relation.Refusal | nil
  local g_narrows = ga.narrows
  local f_narrows = fa.narrows
  if g_narrows ~= nil then
    if f_narrows == nil then
      return leaf(j, why, "narrows_missing", f, g)
    end
    if f_narrows.param ~= g_narrows.param or f_narrows.asserts ~= g_narrows.asserts then
      return leaf(j, why, "narrows_other", f, g)
    end
  end
  if #fa.items ~= #ga.items or (fa.tail == nil) ~= (ga.tail == nil) then
    return leaf(j, why, "return_length", f, g)
  end
  for k, item in ipairs(fa.items) do
    local r = rel(j, item, ga.items[k], why)
    if r ~= nil then
      return through(why, "item", k, r)
    end
  end
  local f_tail, g_tail = fa.tail, ga.tail
  if f_tail ~= nil and g_tail ~= nil then
    local r = rel(j, f_tail, g_tail, why)
    if r ~= nil then
      return through(why, "tail", nil, r)
    end
  end
  if f_narrows ~= nil and g_narrows ~= nil then
    -- `v is T` has a false edge, where the caller removes T from the value: a narrower T in the
    -- function given would remove too little. `asserts v is T` has only the edge that returns.
    if g_narrows.asserts then
      local r = rel(j, f_narrows.to, g_narrows.to, why)
      if r ~= nil then
        return through(why, "narrows", nil, r)
      end
    elseif f_narrows.to ~= g_narrows.to and f_narrows.to.tag ~= "invalid" and g_narrows.to.tag ~= "invalid" then
      return through(why, "narrows", nil, leaf(j, why, "invariant_narrows", f_narrows.to, g_narrows.to))
    end
  end
  return nil
end

-- TODO: index the alternatives of the function wanted by their first item, once a declaration with
-- many alternatives appears in the tree: an alternative below none of n, or only the last, is
-- compared with each. The tree's functions have two or three.
local function returns_below(j: Relation.Judge, f: Fn, g: Fn, why: boolean): Relation.Refusal | nil
  for i, fa in ipairs(f.rets) do
    local matched = false
    for _, ga in ipairs(g.rets) do
      if alternative_below(j, f, g, fa, ga, false) == nil then
        matched = true
        break
      end
    end
    if not matched then
      if not why then
        return j.none
      end
      if #g.rets == 0 then
        return through(true, "alternative", i, leaf(j, true, "may_return", f, g))
      end
      if #g.rets == 1 then
        local r = alternative_below(j, f, g, fa, g.rets[1], true)
        if r ~= nil then
          return through(true, "alternative", i, r)
        end
      end
      local alternatives: {Relation.Refusal} = {}
      for k, ga in ipairs(g.rets) do
        if k > MAX_ALTERNATIVES then
          break
        end
        local r = alternative_below(j, f, g, fa, ga, true)
        if r ~= nil then
          alternatives[#alternatives + 1] = through(true, "target_alternative", k, r)
        end
      end
      return through(true, "alternative", i, {
        code = "return_unmatched", path = {}, sub = f, super = g, alternatives = alternatives,
      })
    end
  end
  return nil
end

--- The hooks [`lang.generics`] reads the judge's declarations through.
local function hooks_of(j: Relation.Judge): Generics.Hooks
  return {
    below = function(a: Type, b: Type): boolean
      return rel(j, a, b, false) == nil
    end,
    listed = function(n: Named): {Type}
      return closure_of(j, n).list
    end,
    array_part = function(n: Named): Type | nil
      return array_part_of(j, n)
    end,
  }
end

--- The generic function `a` where the function type `b` is wanted: `a` with its type parameters taken from what `b` is
--- called with and answers, below `b`. Each parameter of `a` is solved from the parameter of `b` in its place (the value
--- `b` passes is the one `a` takes), else from the values `b` answers, and has to meet its bound.
local function from_generic(j: Relation.Judge, a: Fn, b: Fn, why: boolean): Relation.Refusal | nil
  local solver = Generics.new(j.store, a, hooks_of(j))
  for i, p in ipairs(a.params) do
    local wanted = b.params[i]
    local given = wanted ~= nil and wanted.type or b.rest
    if given ~= nil then
      Generics.match(solver, p.type, given, "into", i)
    end
  end
  local a_rest, b_rest = a.rest, b.rest
  if a_rest ~= nil and b_rest ~= nil then
    Generics.match(solver, a_rest, b_rest, "into", 0)
  end
  if #a.rets == 1 and #b.rets == 1 then
    local ours, theirs = a.rets[1], b.rets[1]
    for k, item in ipairs(ours.items) do
      local wanted = theirs.items[k]
      if wanted ~= nil then
        Generics.match(solver, item, wanted, "from", 0)
      end
    end
    local ours_tail, theirs_tail = ours.tail, theirs.tail
    if ours_tail ~= nil and theirs_tail ~= nil then
      Generics.match(solver, ours_tail, theirs_tail, "from", 0)
    end
  end
  local args: {Type} = {}
  for i = 1, #a.tparams do
    local held = Generics.value(solver, i)
    if held == nil then
      return leaf(j, why, "generic_function", a, b)
    end
    args[i] = held
  end
  if #solver.conflicts > 0 then
    return leaf(j, why, "generic_function", a, b)
  end
  for i, tp in ipairs(a.tparams) do
    local bound = tp.bound
    if bound ~= nil and rel(j, args[i], bound, false) ~= nil then
      return leaf(j, why, "generic_function", a, b)
    end
  end
  local instance = specialize_within(j.store, a, args)
  if instance == nil then
    return leaf(j, why, "generic_function", a, b)
  end
  local r = parameters_below(j, instance, b, why)
  if r ~= nil then
    return r
  end
  return returns_below(j, instance, b, why)
end

local function from_fn(j: Relation.Judge, a: Fn, b: Type, why: boolean): Relation.Refusal | nil
  if not (b is Fn) then
    return leaf(j, why, "mismatch", a, b)
  end
  if #b.tparams > 0 then
    return leaf(j, why, "generic_function", a, b)
  elseif #a.tparams > 0 then
    return from_generic(j, a, b, why)
  end
  local r = parameters_below(j, a, b, why)
  if r ~= nil then
    return r
  end
  return returns_below(j, a, b, why)
end

local function from_var(j: Relation.Judge, a: Var, b: Type, why: boolean): Relation.Refusal | nil
  local bound = bound_of(j, a)
  if bound == nil or b is Var then
    return leaf(j, why, "variable", a, b)
  end
  local r = rel(j, bound, b, why)
  if r ~= nil then
    return through(why, "bound", nil, r)
  end
  return nil
end

--- `a` below `b` where they are different types, neither `invalid`, `a` is not `never`, and the
--- result is not known.
local function rule(j: Relation.Judge, a: Type, b: Type, why: boolean): Relation.Refusal | nil
  if b.tag == "never" then
    return leaf(j, why, "never_target", a, b)
  elseif a.tag == "any" then
    return leaf(j, why, "any_source", a, b)
  elseif b.tag == "any" then
    return leaf(j, why, "any_sink", a, b)
  elseif a is Union then
    return from_union(j, a, b, why)
  elseif is_alias(a) or is_alias(b) then
    return from_alias(j, a, b, why)
  elseif b is Union then
    return into_union(j, a, b, why)
  elseif b is Var and not (a is Var) and a.tag ~= "nil" then
    return leaf(j, why, "variable", a, b)
  elseif a is Atom then
    return from_atom(j, a, b, why)
  elseif a is Named then
    return from_named(j, a, b, why)
  elseif a is Array then
    return from_array(j, a, b, why)
  elseif a is Map then
    return from_map(j, a, b, why)
  elseif a is Fn then
    return from_fn(j, a, b, why)
  end
  return from_var(j, a, b, why)
end

rel = function(j: Relation.Judge, a: Type, b: Type, why: boolean): Relation.Refusal | nil
  if a == b then
    return nil
  end
  local ta = a.tag
  if ta == "never" or ta == "invalid" or b.tag == "invalid" then
    return nil
  end
  local memo = memo_of(j, a, b)
  local key = (a.id << 32) | b.id
  local known = memo[key]
  if known == true then
    return nil
  elseif known == false and not why then
    return j.none
  end
  if why then
    local explained = j.explained[key]
    if explained ~= nil then
      return explained
    end
  end
  local r = rule(j, a, b, why)
  memo[key] = r == nil
  if why and r ~= nil then
    j.explained[key] = r
  end
  return r
end

-- The judge ---------------------------------------------------------------------------------------

local function owned(j: Relation.Judge, t: Type)
  if j.store.transactions > 0 then
    error("relation: a decode is open", 3)
  end
  if t.owner ~= j.store.owner then
    error("relation: a type of another store", 3)
  end
end

Relation.Judge.subtype = function(self: Relation.Judge, a: Type, b: Type): boolean
  owned(self, a)
  owned(self, b)
  return rel(self, a, b, false) == nil
end

Relation.Judge.refuse = function(self: Relation.Judge, a: Type, b: Type): Relation.Refusal | nil
  owned(self, a)
  owned(self, b)
  self.explained = {}
  local r = rel(self, a, b, true)
  self.explained = {}
  return r
end

Relation.Judge.accepts = function(self: Relation.Judge, argument: Type, param: Type): boolean
  owned(self, argument)
  owned(self, param)
  return param.tag == "any" or rel(self, argument, param, false) == nil
end

Relation.Judge.refuse_argument = function(self: Relation.Judge, argument: Type, param: Type): Relation.Refusal | nil
  if param.tag == "any" then
    owned(self, argument)
    owned(self, param)
    return nil
  end
  return self:refuse(argument, param)
end

Relation.Judge.listed = function(self: Relation.Judge, n: Named): Relation.Listing
  owned(self, n)
  local closure = closure_of(self, n)
  local copied: {Type} = {}
  for i, listed in ipairs(closure.list) do
    copied[i] = listed
  end
  return { types = copied, complete = closure.complete }
end

Relation.Judge.enter = function(self: Relation.Judge, tparams: {Types.TParam})
  local copied: {Types.TParam} = {}
  for i, tp in ipairs(tparams) do
    local bound = tp.bound
    if bound ~= nil then
      owned(self, bound)
      -- The bound is read as it is, with no variable of a binder outside it to shift.
      if not (bound is Named) or bound.decl.kind ~= "interface" or #bound.args > 0 then
        error("relation: a bound is an interface used with no arguments, not " .. Types.display(bound), 2)
      end
    end
    copied[i] = tp
  end
  self.scopes[#self.scopes + 1] = { tparams = copied, memo = {} }
end

Relation.Judge.leave = function(self: Relation.Judge)
  if #self.scopes == 0 then
    error("relation: leave without enter", 2)
  end
  self.scopes[#self.scopes] = nil
end

function Relation.instantiate(store: Store, t: Type, args: {Type}): Type | nil
  for _, a in ipairs(args) do
    if a.owner ~= store.owner then
      error("relation: a type of another store", 2)
    end
  end
  if t.owner ~= store.owner then
    error("relation: a type of another store", 2)
  end
  return instantiate_within(store, t, args)
end

function Relation.specialize(store: Store, f: Fn, args: {Type}): Fn | nil
  for _, a in ipairs(args) do
    if a.owner ~= store.owner then
      error("relation: a type of another store", 2)
    end
  end
  return specialize_within(store, f, args)
end

function Relation.new(store: Store): Relation.Judge
  local judge: Relation.Judge = setmetatable({
    store = store, closed = {}, free = {}, scopes = {}, closures = {}, sets = {}, explained = {},
    none = { code = "mismatch", path = {}, sub = store.invalid, super = store.invalid },
    nil_type = store:atom("nil"),
  }, judge_mt)
  return judge
end

function Relation.binder(decl: Types.Decl): {Types.TParam}
  local out: {Types.TParam} = {}
  local body = decl.body
  if body == nil then
    error("relation: " .. decl.name .. " is not defined", 0)
  end
  for i, tp in ipairs(body.tparams) do
    local bound = tp.bound
    if bound ~= nil and bound.owner ~= decl.owner then
      error("relation: a type of another store", 2)
    end
    out[i] = { bound = bound }
  end
  return out
end

function Relation.trace(r: Relation.Refusal): string
  local parts: {string} = {}
  for _, step in ipairs(r.path) do
    local index = step.index
    parts[#parts + 1] = index ~= nil and step.kind .. " " .. index or step.kind
  end
  local where = #parts > 0 and table.concat(parts, " > ") or "here"
  return r.code .. " at " .. where .. ": " .. Types.display(r.sub) .. " is not below " .. Types.display(r.super)
end

return Relation
