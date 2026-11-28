--- The subtype relation of the new checker:
--- whether a value of one
--- type of a [`lang.types`] store may stand where another is wanted, and, where it
--- may not, a structured reason a later error renders in the program's own terms.
---
--- A [`Relation.Judge`] belongs to one store. [`Relation.Judge.subtype`] returns a
--- boolean; [`Relation.Judge.refuse`] returns nil where the relation holds and a
--- [`Relation.Refusal`] where it does not. [`Relation.Judge.accepts`] and
--- [`Relation.Judge.refuse_argument`] are the one position where a value may
--- reach `any`: an argument to a parameter declared `any`.
---
--- **The rules** are these, over the interned
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
--- - A named type is nominal. Two uses of one declaration are related by how the declaration uses each type
---   parameter, read from its body ([`Variance.of`]): an argument it only reads out (a field that is not `mut`, a
---   return, an element of a view) is below the other's, one it only takes in (a parameter of a function field or
---   method, a method's receiver aside) is above it, one it does both with (a `mut` field, a `mut` collection, a map's key)
---   is the same type, and so is one it does not use, which an opaque declaration means by its name. A declaration that names itself is read until the uses
---   hold. A use is below an interface when its
---   declaration lists the interface, or one that extends it, with `is`, the
---   arguments of each listing read through the declaration. A record, class or
---   interface that lists none of them is below the interface when it has each
---   field and method of the interface and of what the interface extends, of the
---   same type, `mut` and omittable as declared there, with the interface's
---   receiver read as the type. A record is not a map and a map is not a record.
---   A declaration used as a value (a [`Named`] with `value`) is below itself
---   alone: it is no instance of the declaration, has no fields, lists no
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
---   place, else from what the type wanted returns, and each meeting its bound
---   ([`lang.generics`]). A parameter nothing there says anything of is `never`, the
---   instance that asks least of what `b` passes (`function<T>(x: integer | T)` where
---   `function(x: integer)` is wanted), unless a result names it: a result of type `never`
---   would drop its alternative, and a cast or a declaration needs a real value there, so
---   such a parameter refuses. The function with those types in is then compared as
---   any other: any instance below the type wanted shows the generic function is. A generic
---   function type wanted is met only by itself.
--- - A type variable is below itself and what one of its bounds is below, or an interface whose fields its interface
---   bounds have together. The bounds are read from the
---   binders [`Relation.Judge.enter`] has entered.
--- - `any` is below `any` and nothing below it but `never`.
---
--- **Refusals.** A [`Relation.Refusal`] has the `code` of the rule that failed, the
--- `path` from the pair compared to the parts that failed, and those parts as
--- `sub` and `super`. A `parameter` or `rest` step swaps the roles: the `sub` of the
--- leaf is then a part of the type that was the target of the comparison, and so does an `argument_in` step. The
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
  ---   neither lists nor has each field of; `field` is the first field it lacks.
  ---   `declaration_value`: a declaration used as a value, the table of its
  ---   functions, where a value of it is wanted, or the reverse. `variable`: a type variable, below only itself and its bounds.
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

  --- A part of a type a refusal went into. `argument_in` is a type argument a declaration passes in (a parameter of
  --- its functions), which swaps the roles as a `parameter` step does. `nil` is the nil of a source union, `bound` the
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
    "argument_in"
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
    --- For `not_listed`, the first field of the interface that `sub` does not have as the interface declares it, the
    --- type `sub` would have it at, and whether `sub` has a field or method of that name at all.
    field?: Types.Field
    has_name?: boolean
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
  interface Judge
    store: Store
    --- Pairs of closed types, and pairs of types that mention a variable under no binder.
    closed: {integer: boolean}
    free: {integer: boolean}
    scopes: mut {Scope}
    closures: {integer: Closure}
    --- How each declaration uses its type parameters, as bits: 1 read out, 2 passed in.
    variances: mut {Types.Decl: {integer: integer}}
    sets: {integer: {integer: boolean}}
    --- The reasons built by the request in progress, by pair.
    explained: {integer: Refusal}
    --- What a refusal is when no reason is wanted, so that no refusal allocates.
    none: Refusal
    nil_type: Type

    --- Whether `a` is below `b`. Raises for a type of another store.
    subtype: function(Judge, a: Type, b: Type): boolean
    --- Nil where `a` is below `b`, else why not.
    refuse: function(Judge, a: Type, b: Type): Refusal?
    --- Whether `argument` may be passed to a parameter of type `param`: below it, or any
    --- value where the parameter is declared `any`.
    accepts: function(Judge, argument: Type, param: Type): boolean
    --- Nil where `argument` may be passed to `param`, else why not.
    refuse_argument: function(Judge, argument: Type, param: Type): Refusal?
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
  instantiate: function(store: Store, t: Type, args: {Type}): Type?

  --- The binder of a declaration: its type parameters and their bounds. Raises where the
  --- declaration has no body.
  binder: function(decl: Types.Decl): {Types.TParam}

  --- The type of a field of `x`, an interface, as `self_type` has it: `x`'s arguments put in and the receiver of a
  --- function field, which is `x`, replaced by `self_type`. Nil where the arguments cannot be put in.
  as_listed: function(store: Store, x: Named, field_type: Type, self_type: Type): Type?

  --- `t` with each variable that reaches past its binders reaching `by` binders further out: the type as written one
  --- binder further in, such as a class's type in the signature of a generic method of the class.
  shifted: function(store: Store, t: Type, by: integer): Type

  --- Whether a declaration that leaves `f` out of an interface it lists has it from the interface, where `listed` is
  --- the field's type as `self_type` has it ([`as_listed`]): a class writes a method for each fixed function field
  --- whose first parameter is then `self_type`, the interface as listed, and has every other field.
  brought_in: function(store: Store, decl: Types.Decl, f: Types.Field, listed: Type?, self_type: Type): boolean

  --- For each field of the interface `pattern`, and of those it lists: the field's type as `pattern` declares it, with
  --- its arguments put in and a function field's receiver `actual`, then as `actual` has it, in pairs. Nil where
  --- `actual` is no record, class or interface, or has no field of one of the names. A solver reads the arguments of `pattern` from
  --- them where `actual` conforms by its fields.
  field_pairs: function(judge: Judge, pattern: Named, actual: Named): {Type}?

  --- The generic function type `f` with each of its type parameters replaced by the matching type of `args`, which
  --- stand where the function is used: a function type with no type parameters. Nil where the type it makes would
  --- nest deeper than the store allows. The variables of the binders around `f` keep their meaning.
  specialize: function(store: Store, f: Fn, args: {Type}): Fn?

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
local function through(why: boolean, kind: Relation.StepKind, index: integer?, r: Relation.Refusal): Relation.Refusal
  if not why then
    return r
  end
  local path: mut {Relation.Step} = { { kind = kind, index = index } }
  for _, step in ipairs(r.path) do
    path[#path + 1] = step
  end
  return {
    code = r.code, path = path, sub = r.sub, super = r.super, index = r.index,
    alternatives = r.alternatives, lists = r.lists, field = r.field, has_name = r.has_name,
  }
end

-- Instantiation -------------------------------------------------------------------------------

--- `t` rebuilt with `on_var` standing for each variable that reaches `level` binders out
--- or more. `level` is how many binders of `t` itself the walk is inside. A type that
--- reaches fewer is returned as it is.
local function rewrite(
    store: Store, t: Type, level: integer, on_var: function(v: Var, level: integer): Type, memo: mut {string: Type}
): Type
  if t.open <= level then
    return t
  end
  local key = tostring(t.id) .. ":" .. tostring(level)
  local held = memo[key]
  if held ~= nil then
    return held
  end
  local out: Type
  if (t.tag == "var") then
    out = on_var(t, level)
  elseif (t.tag == "named") then
    local args: mut {Type} = {}
    for i, part in ipairs(t.args) do
      args[i] = rewrite(store, part, level, on_var, memo)
    end
    out = store:named(t.decl, args, t.value)
  elseif (t.tag == "array") then
    out = store:array(rewrite(store, t.element, level, on_var, memo), t.mut)
  elseif (t.tag == "map") then
    out = store:map(rewrite(store, t.key, level, on_var, memo), rewrite(store, t.value, level, on_var, memo), t.mut)
  elseif (t.tag == "union") then
    local members: mut {Type} = {}
    for i, m in ipairs(t.members) do
      members[i] = rewrite(store, m, level, on_var, memo)
    end
    if t.nilable then
      members[#members + 1] = store:atom("nil")
    end
    out = store:union(members)
  elseif (t.tag == "fn") then
    local inside = if #t.tparams > 0 then level + 1 else level end
    local tparams: mut {Types.TParam} = {}
    for i, tp in ipairs(t.tparams) do
      local bounds: mut {Type} = {}
      for k, bound in ipairs(tp.bounds or {}) do
        bounds[k] = rewrite(store, bound, inside, on_var, memo)
      end
      tparams[i] = { bounds = if #bounds > 0 then bounds else nil end }
    end
    local params: mut {Types.Param} = {}
    for i, p in ipairs(t.params) do
      params[i] = { type = rewrite(store, p.type, inside, on_var, memo), omittable = p.omittable }
    end
    local rest = t.rest
    local rets: mut {Alt} = {}
    for i, alt in ipairs(t.rets) do
      local items: mut {Type} = {}
      for k, item in ipairs(alt.items) do
        items[k] = rewrite(store, item, inside, on_var, memo)
      end
      local tail = alt.tail
      local narrows = alt.narrows
      rets[i] = {
        items = items,
        tail = tail ~= nil and rewrite(store, tail, inside, on_var, memo) or nil, -- checked: and_ternary
        narrows = if narrows ~= nil then {
          param = narrows.param, to = rewrite(store, narrows.to, inside, on_var, memo), asserts = narrows.asserts,
        } else nil end,
      }
    end
    out = store:fn({
      tparams = tparams, params = params,
      rest = rest ~= nil and rewrite(store, rest, inside, on_var, memo) or nil, -- checked: and_ternary
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
local function instantiate_within(store: Store, t: Type, args: {Type}): Type?
  local made: mut {Type} = {}
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
  local queue: mut {Named} = { n }
  -- The walk takes the uses it adds, which `ipairs` meets as they are appended.
  for _, x in ipairs(queue) do
    defined(x)
    local body = x.decl.body
    if body ~= nil then
      for _, super in ipairs(body.supers) do
        local listed: Type? = super
        if #x.args > 0 then
          listed = instantiate_within(j.store, super, x.args)
        end
        if listed == nil then
          closure.complete = false -- checked: field_fixed
        elseif (listed.tag == "named") and closure.set[listed.id] ~= true then
          if #closure.list >= MAX_LISTED then
            closure.complete = false -- checked: field_fixed
          else
            closure.set[listed.id] = true -- checked: view_written
            closure.list[#closure.list + 1] = listed -- checked: view_written
            local same = closure.by_decl[listed.decl] or {}
            same[#same + 1] = listed -- checked: view_written
            closure.by_decl[listed.decl] = same -- checked: view_written
            queue[#queue + 1] = listed
          end
        end
      end
    end
  end
  j.closures[n.id] = closure -- checked: view_written
  return closure
end

--- Whether the interface `target` is in `closure`, or a use of its declaration whose arguments
--- are its own but for `invalid`, which stands for a mistake already reported.
local function lists(closure: Relation.Closure, target: Named): boolean
  if closure.set[target.id] == true then
    return true
  end
  for _, listed in ipairs(closure.by_decl[target.decl] or {}) do
    local same = true
    for i, held in ipairs(listed.args) do
      local other = target.args[i]
      if held ~= other and held.tag ~= "invalid" and other ~= nil and other.tag ~= "invalid" then
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
local function array_part_of(j: Relation.Judge, n: Named): Type?
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
    return rewrite(store, t, 0, on_var, memo) -- checked: view_as_mut
  end
  local params: mut {Types.Param} = {}
  for i, p in ipairs(f.params) do
    params[i] = { type = part(p.type), omittable = p.omittable }
  end
  local rest = f.rest
  local rets: mut {Alt} = {}
  for i, alt in ipairs(f.rets) do
    local items: mut {Type} = {}
    for k, item in ipairs(alt.items) do
      items[k] = part(item)
    end
    local tail = alt.tail
    local narrows = alt.narrows
    rets[i] = {
      items = items,
      tail = tail ~= nil and part(tail) or nil, -- checked: and_ternary
      narrows = if narrows ~= nil then { param = narrows.param, to = part(narrows.to), asserts = narrows.asserts } else nil end,
    }
  end
  local made = store:fn({ tparams = {}, params = params, rest = rest ~= nil and part(rest) or nil, rets = rets }) -- checked: and_ternary
  if not ((made.tag == "fn")) then
    error("relation: a function type is a function type")
  end
  return made
end

--- [`specialize`], or nil where the type it makes would nest past what the store allows.
local function specialize_within(store: Store, f: Fn, args: {Type}): Fn?
  local made: mut {Fn} = {}
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

local rel: function(j: Relation.Judge, a: Type, b: Type, why: boolean): Relation.Refusal?

--- How declarations use their type parameters ([`Variance.args_below`]), defined below the relation.
local record Variance
end

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

--- The bounds of the type variable `v` under the binders entered, or nil where it has none.
local function bounds_of(j: Relation.Judge, v: Var): {Type}?
  local scope = j.scopes[#j.scopes - v.depth]
  if scope == nil then
    return nil
  end
  local tparam = scope.tparams[v.index + 1]
  if tparam == nil then
    return nil
  end
  return tparam.bounds
end

--- The ids of the members of a union.
local function member_set(j: Relation.Judge, u: Union): {integer: boolean}
  local held = j.sets[u.id]
  if held ~= nil then
    return held
  end
  local set: mut {integer: boolean} = {}
  for _, m in ipairs(u.members) do
    set[m.id] = true
  end
  j.sets[u.id] = set -- checked: view_written
  return set
end

local function from_union(j: Relation.Judge, a: Union, b: Type, why: boolean): Relation.Refusal? -- checked: not_assigned
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

--- Whether each string of the enum `a` is a value of one of the enums `among`: a string literal type is an enum of its
--- value alone, so `"circle" | "square"` holds `Kind` where `Kind` is those two.
local function enum_within(a: Named, among: {Type}): boolean
  local body = a.decl.body
  if body == nil then
    return false
  end
  local held: mut {string: boolean} = {}
  for _, m in ipairs(among) do
    local other = if (m.tag == "named") and not m.value and m.decl.kind == "enum" then m.decl.body else nil end
    if other ~= nil then
      for _, v in ipairs(other.values) do
        held[v] = true
      end
    end
  end
  for _, v in ipairs(body.values) do
    if held[v] ~= true then
      return false
    end
  end
  return true
end

-- TODO: index the members of a target union by form, once the type report shows a union of many
-- arrays, maps or functions in the tree: a type below none of n members, or below only the last
-- of them, is compared with each, and n such types make n^2 comparisons. A member that is one of
-- the target's is found by its id, so a union checked against a superset costs n.
local function into_union(j: Relation.Judge, a: Type, b: Union, why: boolean): Relation.Refusal?
  if a.tag == "nil" then
    if b.nilable then
      return nil
    end
    return leaf(j, why, "nil", a, b)
  end
  if member_set(j, b)[a.id] == true then
    return nil
  end
  for _, m in ipairs(b.members) do
    if rel(j, a, m, false) == nil then
      return nil
    end
  end
  if (a.tag == "named") and not a.value and a.decl.kind == "enum" and enum_within(a, b.members) then
    -- No member holds each string of the enum, and the members together do.
    return nil
  end
  if not why then
    return j.none
  end
  local alternatives: mut {Relation.Refusal} = {}
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
  return (t.tag == "named") and t.decl.kind == "alias"
end

--- `a` below `b` where one of them is a recursive alias: that one is read as the type it names, one level, and
--- the pair is compared again. The comparison ends because the other type is finite and a body names its alias only inside
--- an array or a map, which the comparison then goes into the other type's element or value to meet: each time the alias is
--- read, the other side is one level smaller. Two ways round that are closed. Two aliases are not compared by their bodies
--- (a body that mentions its own alias would send two of them round for ever), and are unrelated, as two declarations are.
--- A type that holds itself (a record whose array part is the record) does not get smaller, and is why a record, a class
--- or an interface is refused here before the alias is read. The refusal names the alias as it was written.
local function from_alias(j: Relation.Judge, a: Type, b: Type, why: boolean): Relation.Refusal?
  local a_alias, b_alias = is_alias(a), is_alias(b)
  if a_alias and b_alias then
    return leaf(j, why, "nominal", a, b)
  end
  -- A record, a class or an interface is never an arm of an alias: a record with an array part is below `{T}`, but it may have fields and methods
  -- besides (an encoder meets a table that mixes keys), so only the arrays and maps an alias names stand for it. A record
  -- inferred for a literal of named items, or one in braces, has its fields and no others, so it is the read-only map
  -- of them it is below elsewhere ([`from_named`]): `{ id = "x", usage = { n = 1 } }` is a [`Json.Value`].
  if b_alias and (a.tag == "named") and (a.decl.kind == "record" or a.decl.kind == "class" or a.decl.kind == "interface") and
      not (a.decl.kind == "record" and not a.value and (Types.inferred_record(a.decl) or Types.shape_record(a.decl))) then
    return leaf(j, why, "mismatch", a, b)
  end
  local ua, ub = Types.unfold(a), Types.unfold(b)
  if ua == a and ub == b then
    error("relation: " .. Types.display(a_alias and a or b) .. " is not defined", 0) -- checked: and_ternary
  end
  if a_alias and (b.tag == "union") and member_set(j, b)[a.id] == true then
    return nil
  end
  local r = rel(j, ua, ub, why)
  if r == nil or not why then
    return r
  end
  return {
    code = r.code, path = r.path, sub = r.sub == ua and a or r.sub, super = r.super == ub and b or r.super, -- checked: and_ternary*2
    index = r.index, alternatives = r.alternatives, lists = r.lists, field = r.field, has_name = r.has_name,
  }
end

local function from_atom(j: Relation.Judge, a: Atom, b: Type, why: boolean): Relation.Refusal?
  local tag = a.tag
  if tag == "nil" then
    return leaf(j, why, "nil", a, b)
  elseif tag == "integer" and b.tag == "number" then
    return nil
  elseif (tag == "true" or tag == "false") and b.tag == "boolean" then
    return nil
  elseif tag == "number" and b.tag == "integer" then
    return leaf(j, why, "number_for_integer", a, b)
  elseif tag == "Numeric" and b.tag == "number" then
    -- A parameter bounded by `Numeric` is `integer` or `number`, both below `number`.
    return nil
  end
  return leaf(j, why, "mismatch", a, b)
end

--- `f` with `receiver` as the type of its first parameter.
local function with_receiver(store: Store, f: Fn, receiver: Type): Type
  local params: mut {Types.Param} = {}
  for i, p in ipairs(f.params) do
    params[i] = { type = if i == 1 then receiver else p.type end, omittable = p.omittable }
  end
  local rets: mut {Alt} = {}
  for i, alt in ipairs(f.rets) do
    local narrows = alt.narrows
    rets[i] = {
      items = alt.items, tail = alt.tail,
      narrows = if narrows ~= nil then { param = narrows.param, to = narrows.to, asserts = narrows.asserts } else nil end,
    }
  end
  return store:fn({ tparams = f.tparams, params = params, rest = f.rest, rets = rets })
end

--- `t`, a field's type, with the receiver of a function replaced by `self_type` where it is one of `receivers`.
local function with_receiver_of(store: Store, t: Type, receivers: {integer: boolean}, self_type: Type): Type
  -- An omittable function field is `function(...)?`: the receiver is the function's.
  local optional = (t.tag == "union") and t.nilable
  local callable: Type = t
  if optional then
    callable = store:non_nil(t)
  end
  local receiver: Types.Param? = nil
  if callable.tag == "fn" then
    receiver = callable.params[1]
  end
  if not ((callable.tag == "fn")) or receiver == nil then
    return t
  end
  -- A generic function's receiver is written under its own binder, one further in than the field: it is the interface
  -- where it names none of that binder's parameters and is the interface one binder out.
  local written = receiver.type
  local here = self_type
  if #callable.tparams > 0 then
    local own = false
    written = rewrite(store, written, 0, function(v: Var, level: integer): Type
      if v.depth < level then
        return v
      elseif v.depth == level then
        own = true
        return v
      end
      return store:var(v.depth - 1, v.index)
    end, {})
    if own then
      return t
    end
    here = shift(store, self_type, 1)
  end
  if receivers[written.id] == true then
    local replaced = with_receiver(store, callable, here)
    if optional then
      return store:optional(replaced)
    end
    return replaced
  end
  return t
end

function Relation.shifted(store: Store, t: Type, by: integer): Type
  return shift(store, t, by)
end

function Relation.as_listed(store: Store, x: Named, field_type: Type, self_type: Type): Type?
  local instance: Type? = field_type
  if #x.args > 0 then
    instance = instantiate_within(store, field_type, x.args)
  end
  if instance == nil then
    return nil
  end
  return with_receiver_of(store, instance, { [x.id] = true }, self_type)
end

--- Whether a declaration `decl` that lists an interface declaring `f`, and leaves `f` out, has it from the interface:
--- an interface or a record has each such field, and a class each but a fixed function field that takes the interface
--- as listed first (`listed` takes `self_type` first), which it meets with a method of its own. A field that takes
--- another type first, or the interface with other arguments, is data the class holds.
function Relation.brought_in(store: Store, decl: Types.Decl, f: Types.Field, listed: Type?, self_type: Type): boolean
  if decl.kind ~= "class" or f.mut == true or f.type.tag ~= "fn" or listed == nil or listed.tag ~= "fn" then
    return true
  end
  local first = listed.params[1]
  local here = if #listed.tparams > 0 then shift(store, self_type, 1) else self_type end
  return first == nil or first.type ~= here
end

--- A field or method that `n` has, with the arguments of `n` put in.
local record Supplied
  type: Type
  mut: boolean
  omittable: boolean
end

--- The fields and methods of `n`'s declaration named `name`, and the fields it has from the interfaces it lists: for an
--- interface each of theirs, and for a record or class those it leaves out.
local function supplied(j: Relation.Judge, n: Named, name: string): {Supplied}
  local out: mut {Supplied} = {}
  local body = n.decl.body
  if body == nil then
    return out
  end
  local function add(t: Type?, is_mut: boolean, omittable: boolean)
    if t ~= nil then
      out[#out + 1] = { type = t, mut = is_mut, omittable = omittable }
    end
  end
  local function own(t: Type): Type?
    if #n.args > 0 then
      return instantiate_within(j.store, t, n.args)
    end
    return t
  end
  for _, f in ipairs(body.fields) do
    if f.name == name then
      add(own(f.type), f.mut == true, f.omittable == true)
    end
  end
  for _, m in ipairs(body.methods) do
    if m.name == name then
      add(own(m.type), false, false)
    end
  end
  local kind = n.decl.kind
  if kind == "interface" or (#out == 0 and (kind == "record" or kind == "class")) then
    -- What the declaration leaves out it has from the interfaces it lists ([`Relation.brought_in`]).
    for _, x in ipairs(closure_of(j, n).list) do
      local xbody: Types.Body? = nil
      if (x.tag == "named") then
        xbody = x.decl.body
      end
      if (x.tag == "named") and xbody ~= nil then
        for _, f in ipairs(xbody.fields) do
          if f.name == name then
            local listed = Relation.as_listed(j.store, x, f.type, n)
            if kind == "interface" or Relation.brought_in(j.store, n.decl, f, listed, n) then
              add(listed, f.mut == true, f.omittable == true)
            end
          end
        end
      end
    end
  end
  return out
end

--- A copy of `list`, which a refusal hands to code that may change it.
local function copy_of(list: {Type}): {Type}
  local out: mut {Type} = {}
  for i, t in ipairs(list) do
    out[i] = t
  end
  return out
end

--- Whether `a`, a record, class or interface, has every field of the interface `b` and of the interfaces it lists as
--- they declare it: of exactly the type (a function field's receiver is `a`), `mut` exactly where it is, and
--- omittable exactly where it is, the rule a listing with `is` is held to ([`lang.declarations`]). Nil where it
--- does, else the refusal naming the first field it lacks.
local function conforms(j: Relation.Judge, a: Named, b: Named, why: boolean, closure: Relation.Closure): Relation.Refusal?
  local kind = a.decl.kind
  if kind ~= "record" and kind ~= "class" and kind ~= "interface" and kind ~= "userdata" then
    if not why then
      return j.none
    end
    return { code = "not_listed", path = {}, sub = a, super = b, lists = copy_of(closure.list) }
  end
  defined(a)
  defined(b)
  local wanted: mut {Named} = { b }
  -- A function field takes as its receiver the interface that declares it, or one that interface lists.
  local receivers: mut {integer: boolean} = { [b.id] = true }
  for _, x in ipairs(closure_of(j, b).list) do
    if (x.tag == "named") then
      wanted[#wanted + 1] = x
      receivers[x.id] = true
    end
  end
  local bbody = b.decl.body
  if bbody ~= nil and bbody.array ~= nil then
    -- An interface with an array part, which only a store's caller can build (the grammar has none), is met only by a
    -- listing, which checks the part.
    return { code = "not_listed", path = {}, sub = a, super = b, lists = copy_of(closure.list) }
  end
  for _, x in ipairs(wanted) do
    local xbody = x.decl.body
    local fields: {Types.Field} = if xbody ~= nil then xbody.fields else {} end
    for _, f in ipairs(fields) do
      local listed = Relation.as_listed(j.store, x, f.type, a)
      local expected = if listed ~= nil then with_receiver_of(j.store, listed, receivers, a) else nil end
      local found = supplied(j, a, f.name)
      local ok = false
      for _, s in ipairs(found) do
        -- `invalid` stands for a mistake already reported, and for whatever type was meant.
        local same = expected ~= nil and (s.type == expected or s.type.tag == "invalid" or expected.tag == "invalid")
        if same and s.mut == (f.mut == true) and s.omittable == (f.omittable == true) then
          ok = true
          break
        end
      end
      if not ok then
        if not why then
          return j.none
        end
        return {
          code = "not_listed", path = {}, sub = a, super = b, lists = copy_of(closure.list),
          field = { name = f.name, type = expected or f.type, mut = f.mut, omittable = f.omittable }, has_name = #found > 0,
        }
      end
    end
  end
  return nil
end

--- Whether the type variable `a`, bounded by `bounds`, conforms to the interface `b` through the fields of its interface
--- bounds together: each field of `b`, and of the interfaces it lists, is a field of one of them as [`conforms`] holds a
--- field. `T is Titled & Aged` is below an interface of `title` and `age`.
local function conforms_through(j: Relation.Judge, a: Var, bounds: {Type}, b: Named, why: boolean): Relation.Refusal?
  defined(b)
  local wanted: mut {Named} = { b }
  local receivers: mut {integer: boolean} = { [b.id] = true }
  for _, x in ipairs(closure_of(j, b).list) do
    if (x.tag == "named") then
      wanted[#wanted + 1] = x
      receivers[x.id] = true
    end
  end
  local bbody = b.decl.body
  if bbody ~= nil and bbody.array ~= nil then
    return leaf(j, why, "variable", a, b)
  end
  for _, x in ipairs(wanted) do
    local xbody = x.decl.body
    local fields: {Types.Field} = if xbody ~= nil then xbody.fields else {} end
    for _, f in ipairs(fields) do
      local ok = false
      local named = false
      for _, bound in ipairs(bounds) do
        if (bound.tag == "named") and not ok then
          defined(bound)
          local listed = Relation.as_listed(j.store, x, f.type, bound)
          local expected = if listed ~= nil then with_receiver_of(j.store, listed, receivers, bound) else nil end
          for _, s in ipairs(supplied(j, bound, f.name)) do
            named = true
            local same = expected ~= nil and (s.type == expected or s.type.tag == "invalid" or expected.tag == "invalid")
            if same and s.mut == (f.mut == true) and s.omittable == (f.omittable == true) then
              ok = true
              break
            end
          end
        end
      end
      if not ok then
        if not why then
          return j.none
        end
        return {
          code = "not_listed", path = {}, sub = a, super = b, lists = {},
          field = { name = f.name, type = f.type, mut = f.mut, omittable = f.omittable }, has_name = named,
        }
      end
    end
  end
  return nil
end

--- For the solver: each field of the interface `b` and of those it lists, as `b` declares it and as `a` has it, in
--- pairs; nil where `a` is no record, class or interface, or lacks a field by name.
local function field_pairs(j: Relation.Judge, b: Named, a: Named): {Type}?
  local kind = a.decl.kind
  if a.value or (kind ~= "record" and kind ~= "class" and kind ~= "interface" and kind ~= "userdata") then
    return nil
  end
  defined(a)
  defined(b)
  local wanted: mut {Named} = { b }
  local receivers: mut {integer: boolean} = { [b.id] = true }
  for _, x in ipairs(closure_of(j, b).list) do
    if (x.tag == "named") then
      wanted[#wanted + 1] = x
      receivers[x.id] = true
    end
  end
  local out: mut {Type} = {}
  for _, x in ipairs(wanted) do
    local xbody = x.decl.body
    local fields: {Types.Field} = if xbody ~= nil then xbody.fields else {} end
    for _, f in ipairs(fields) do
      local listed = Relation.as_listed(j.store, x, f.type, a)
      local found = supplied(j, a, f.name)[1]
      if listed == nil or found == nil then
        -- A type that lacks a field conforms to no use of the interface: nothing is read from the rest.
        return nil
      end
      out[#out + 1] = with_receiver_of(j.store, listed, receivers, a)
      out[#out + 1] = found.type
    end
  end
  return out
end

--- Whether `a`, a record inferred for a literal of named items ([`Types.inferred_record`]) or a record type in braces
--- ([`Types.shape`]), is below the record `b`, declared, inferred or in braces, as the literal would be: it has each field of `b` that is not omittable or nilable, and no
--- field `b` lacks; a field `b` declares `mut` is of exactly its type, since a write through `b` would store one, and
--- another is below its type. Nil where it is, else the refusal naming the first field that differs.
local function shaped(j: Relation.Judge, a: Named, b: Named, why: boolean): Relation.Refusal?
  defined(b)
  local abody = assert(a.decl.body, "an inferred record is defined where it is made")
  local bbody = assert(b.decl.body, "`defined` holds a body")
  if b.decl.kind ~= "record" or bbody.array ~= nil or #bbody.methods > 0 then
    return leaf(j, why, "nominal", a, b)
  end
  local have: mut {string: Types.Field} = {}
  for _, f in ipairs(abody.fields) do
    have[f.name] = f
  end
  local wanted: mut {string: boolean} = {}
  local function refused(f: Types.Field, found: boolean): Relation.Refusal
    if not why then
      return j.none
    end
    return { code = "not_listed", path = {}, sub = a, super = b, lists = {}, field = f, has_name = found }
  end
  for _, f in ipairs(bbody.fields) do
    wanted[f.name] = true
    local s = supplied(j, b, f.name)[1]
    local mine = have[f.name]
    if s ~= nil then
      local field: Types.Field = { name = f.name, type = s.type, mut = s.mut, omittable = s.omittable }
      if mine == nil then
        -- A field written through `b` would be one the record does not know of, and a read of it as a map would miss.
        if s.mut or (not s.omittable and not (s.type.tag == "nil" or ((s.type.tag == "union") and s.type.nilable))) then
          return refused(field, false)
        end
      elseif s.mut then
        -- A write through `b` changes the field behind what the program knows of it through its own fixed one.
        if mine.type.tag ~= "invalid" and s.type.tag ~= "invalid" and (mine.mut ~= true or mine.type ~= s.type) then
          return refused(field, true)
        end
      elseif rel(j, if mine.omittable == true then j.store:optional(mine.type) else mine.type end,
          if s.omittable then j.store:optional(s.type) else s.type end, false) ~= nil then
        return refused(field, true)
      end
    end
  end
  for _, f in ipairs(abody.fields) do
    if wanted[f.name] ~= true then
      return leaf(j, why, "nominal", a, b)
    end
  end
  return nil
end

local function from_named(j: Relation.Judge, a: Named, b: Type, why: boolean): Relation.Refusal?
  local a_body = a.decl.body
  if a.value and (b.tag == "named") and not b.value and a_body ~= nil and a_body.schema ~= nil and
      b.decl.module == "cosmic.sqlite" and b.decl.name == "Schema" then
    -- A `local schema` used as a value is the value of [`Sqlite.schema`] of its DDL.
    return nil
  end
  if (b.tag == "named") and a.value ~= b.value then
    return leaf(j, why, "declaration_value", a, b)
  elseif a.value then
    -- The table of a declaration's functions lists no interface, is no enum and has no array part.
    if not ((b.tag == "named")) then
      return leaf(j, why, "mismatch", a, b)
    end
  end
  if (b.tag == "named") then
    if a.decl == b.decl then
      if #a.args ~= #b.args then
        -- The count is not known until the declaration is defined.
        error("relation: " .. a.decl.name .. " is not defined", 0)
      end
      if a.value then
        -- The table of a declaration's functions is below itself alone.
        for i, held in ipairs(a.args) do
          local other = b.args[i]
          if held ~= other and held.tag ~= "invalid" and other ~= nil and other.tag ~= "invalid" then
            return through(why, "argument", i, leaf(j, why, "invariant_generic", held, other))
          end
        end
        return nil
      end
      return Variance.args_below(j, a.decl, a.args, b.args, why)
    end
    -- A record type in braces is below one in braces as a literal of its fields would be, and stays apart from a
    -- declared record, which is a type of its own.
    if not a.value and not b.value and b.decl.kind ~= "interface" and
        (Types.inferred_record(a.decl) or (Types.shape_record(a.decl) and Types.shape_record(b.decl))) then
      return shaped(j, a, b, why)
    end
    if not a.value and a.decl.kind == "enum" and b.decl.kind == "enum" then
      -- An enum is the set of its strings, and is below an enum that holds each of them: `"circle"` is below `Kind`.
      if enum_within(a, { b }) then
        return nil
      end
      return leaf(j, why, "nominal", a, b)
    end
    if b.decl.kind == "interface" then
      local closure = closure_of(j, a)
      if lists(closure, b) then
        return nil
      end
      -- A listing of the interface with other arguments is below it as the interface uses them.
      for _, listed in ipairs(closure.by_decl[b.decl] or {}) do
        if Variance.args_below(j, b.decl, listed.args, b.args, false) == nil then
          return nil
        end
      end
      -- A type that lists no interface of `b`'s declaration conforms to it by having its fields.
      return conforms(j, a, b, why, closure)
    end
    if not a.value and not b.value and a_body ~= nil and a_body.schema ~= nil and lists(closure_of(j, a), b) then
      -- A handle of a `local schema` is a handle of [`cosmic.sqlite`], whose class it lists.
      return nil
    end
    return leaf(j, why, "nominal", a, b)
  elseif b.tag == "string" and a.decl.kind == "enum" then
    return nil
  elseif (b.tag == "integer" or b.tag == "number") and a.decl.kind == "integer_enum" then
    return nil
  elseif (b.tag == "array") then
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
  elseif (b.tag == "map") and not a.value and (Types.inferred_record(a.decl) or Types.shape_record(a.decl)) then
    -- A record inferred for a literal of named items, or one in braces, is a map of strings to what each of its fields is below, read
    -- only: a write through the map would add a key or change the type of a field.
    if b.mut then
      return leaf(j, why, "view_as_mut", a, b)
    end
    if b.key ~= j.store.string then
      local r = if (b.key.tag == "var") then rel(j, j.store.string, b.key, why) else leaf(j, why, "record_as_map", a, b) end
      if r ~= nil then
        return through(why, "key", nil, r)
      end
    end
    for _, f in ipairs(assert(a.decl.body, "an inferred record or a shape is defined where it is made").fields) do
      -- A field that may be nil is a key that may be missing, which a read of the map treats alike.
      local held = f.type
      if (held.tag == "union") and held.nilable then
        held = j.store:non_nil(held)
      end
      local r = rel(j, held, b.value, why)
      if r ~= nil then
        return through(why, "value", nil, r)
      end
    end
    return nil
  elseif (b.tag == "map") then
    return leaf(j, why, "record_as_map", a, b)
  end
  return leaf(j, why, "mismatch", a, b)
end

local function from_array(j: Relation.Judge, a: Array, b: Type, why: boolean): Relation.Refusal?
  if not ((b.tag == "array")) then
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

local function from_map(j: Relation.Judge, a: Map, b: Type, why: boolean): Relation.Refusal?
  if (b.tag == "named") then
    return leaf(j, why, "map_as_record", a, b)
  elseif not ((b.tag == "map")) then
    return leaf(j, why, "mismatch", a, b)
  end
  if b.mut and not a.mut then
    return leaf(j, why, "view_as_mut", a, b)
  end
  if a.key ~= b.key and a.key.tag ~= "invalid" and b.key.tag ~= "invalid" then
    return through(why, "key", nil, leaf(j, why, if b.mut then "invariant_mut" else "invariant_key" end, a.key, b.key))
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
local function slot(f: Fn, i: integer): Type?, boolean, boolean
  local p = f.params[i]
  if p ~= nil then
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
    r.index = i -- checked: field_fixed
  end
  return r
end

--- Whether `f` accepts every argument list that callers of `g` pass, parameter by parameter.
---
--- With `drop`, `f` may take fewer parameters than `g` passes: Lua drops the arguments past the last parameter, and
--- `f` never reads them. Only trailing parameters are dropped, the ones kept are compared here, and the rest
--- parameter of `g` is held below. It is allowed only for a function whose own parameter list is known (see
--- [`Relation.subtype_known`]).
local function parameters_below(j: Relation.Judge, f: Fn, g: Fn, why: boolean, drop?: boolean): Relation.Refusal?
  local widest = math.max(#f.params, #g.params)
  for i = 1, widest do
    local gt, g_may_omit, g_is_rest = slot(g, i)
    local ft, f_may_omit = slot(f, i)
    if gt ~= nil then
      if ft == nil and drop ~= true then
        return arity(j, why, f, g, i)
      end
      if ft ~= nil then
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
): Relation.Refusal?
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
    local other = ga.items[k]
    if other == nil then
      return leaf(j, why, "return_length", f, g)
    end
    local r = rel(j, item, other, why)
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
local function returns_below(j: Relation.Judge, f: Fn, g: Fn, why: boolean): Relation.Refusal?
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
      local alternatives: mut {Relation.Refusal} = {}
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
    array_part = function(n: Named): Type?
      return array_part_of(j, n)
    end,
    fields = function(pattern: Named, actual: Named): {Type}?
      return field_pairs(j, pattern, actual)
    end,
  }
end

--- The generic function `a` where the function type `b` is wanted: `a` with its type parameters taken from what `b` is
--- called with and returns, below `b`. Each parameter of `a` is solved from the parameter of `b` in its place (the value
--- `b` passes is the one `a` takes), else from the values `b` returns, and has to meet its bounds.
local function from_generic(j: Relation.Judge, a: Fn, b: Fn, why: boolean): Relation.Refusal?
  local solver = Generics.new(j.store, a, hooks_of(j))
  for i, p in ipairs(a.params) do
    local wanted = b.params[i]
    local given = wanted ~= nil and wanted.type or b.rest -- checked: and_ternary
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
  -- The type parameters a's results name. Unsolved, one of these refuses: as `never` it would
  -- drop the alternative it is in from the store, and a body that casts (`v as T`) or a declared
  -- generic returns a value of no type `never` stands for.
  local answered: mut {integer: boolean} = {}
  for _, alt in ipairs(a.rets) do
    local parts: mut {Type} = {}
    for _, item in ipairs(alt.items) do parts[#parts + 1] = item end
    local tail = alt.tail
    if tail ~= nil then parts[#parts + 1] = tail end
    local narrows = alt.narrows
    if narrows ~= nil then parts[#parts + 1] = narrows.to end
    for _, part in ipairs(parts) do
      for index in pairs(Generics.names(part)) do answered[index] = true end
    end
  end
  local args: mut {Type} = {}
  for i = 1, #a.tparams do
    -- Unsolved, a parameter no result names is `never`: the instance is still compared below,
    -- so the choice only ever admits what an instance shows.
    local solved = Generics.value(solver, i)
    if solved == nil then
      if answered[i] == true then
        return leaf(j, why, "generic_function", a, b)
      end
      solved = j.store.never
    end
    args[i] = solved
  end
  if #solver.conflicts > 0 then
    return leaf(j, why, "generic_function", a, b)
  end
  for i, tp in ipairs(a.tparams) do
    local solved = args[i]
    if solved == nil then
      return leaf(j, why, "generic_function", a, b)
    end
    for _, bound in ipairs(tp.bounds or {}) do
      if rel(j, solved, bound, false) ~= nil then
        return leaf(j, why, "generic_function", a, b)
      end
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

local function from_fn(j: Relation.Judge, a: Fn, b: Type, why: boolean): Relation.Refusal?
  if not ((b.tag == "fn")) then
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

--- A variable is below what one of its bounds is below: `T is A & B` has the fields of both, and is below each.
local function from_var(j: Relation.Judge, a: Var, b: Type, why: boolean): Relation.Refusal?
  local bounds = bounds_of(j, a)
  if bounds == nil or (b.tag == "var") then
    return leaf(j, why, "variable", a, b)
  end
  local first: Relation.Refusal? = nil
  for _, bound in ipairs(bounds) do
    local r = rel(j, bound, b, why)
    if r == nil then
      return nil
    end
    if first == nil then
      first = r
    end
  end
  if #bounds > 1 and (b.tag == "named") and b.decl.kind == "interface" and #b.args == 0 then
    local r = conforms_through(j, a, bounds, b, why)
    if r == nil then
      return nil
    end
    return r
  end
  return through(why, "bound", nil, (assert(first, "a type parameter with bounds has one")))
end

--- Whether `a` is below the built-in bound `b`. `Numeric` holds `integer` and `number`, for which `+`, `-`, `*`, `%`,
--- `//` and unary `-` give the type of their operands; an integer enum is not one, since its sum is no member.
--- `Ordered` holds a type all of whose values are numbers, or all strings, so that `<` of two of its values never
--- raises: a union of a number and a string is none, and a class that declares `__lt` and `__le` is one. `Numeric` is
--- below `Ordered`. `Key` holds the types a map is
--- keyed by ([`Types.keys_a_map`]), an interface among them. `Some` holds every type that is never nil
--- ([`Types.present`]), and each other bound. A type variable is below a bound where one of its own bounds is.
local function into_builtin(j: Relation.Judge, a: Type, b: Type, why: boolean): Relation.Refusal?
  if (a.tag == "var") then
    return from_var(j, a, b, why)
  elseif a.tag == "Numeric" and b.tag == "Ordered" then
    return nil
  elseif b.tag == "Numeric" then
    if a.tag == "integer" or a.tag == "number" then
      return nil
    end
  elseif b.tag == "Key" then
    if Types.keys_a_map(a) then
      return nil
    end
  elseif b.tag == "Some" then
    -- Every bound holds only types that are never nil, so a bounded type variable is below `Some` too ([`from_var`]).
    if Types.present(a) or Types.builtin_bound(a) then
      return nil
    end
  elseif Types.declares_method(a, "__lt") and Types.declares_method(a, "__le") then
    -- A class that declares `__lt` and `__le` compares two of its values with each of `<`, `<=`, `>` and `>=`.
    return nil
  elseif not Types.builtin_bound(a) and
      (rel(j, a, j.store.number, false) == nil or rel(j, a, j.store.string, false) == nil) then
    return nil
  end
  return leaf(j, why, "mismatch", a, b)
end

--- `a` below `b` where they are different types, neither `invalid`, `a` is not `never`, and the
--- result is not known.
local function rule(j: Relation.Judge, a: Type, b: Type, why: boolean): Relation.Refusal?
  if b.tag == "never" then
    return leaf(j, why, "never_target", a, b)
  elseif a.tag == "any" then
    return leaf(j, why, "any_source", a, b)
  elseif b.tag == "any" then
    return leaf(j, why, "any_sink", a, b)
  elseif Types.builtin_bound(b) and not is_alias(a) then
    return into_builtin(j, a, b, why)
  elseif (a.tag == "union") then
    return from_union(j, a, b, why)
  elseif is_alias(a) or is_alias(b) then
    return from_alias(j, a, b, why)
  elseif (b.tag == "union") then
    return into_union(j, a, b, why)
  elseif (b.tag == "var") and not ((a.tag == "var")) and a.tag ~= "nil" then
    return leaf(j, why, "variable", a, b)
  elseif (a.tag == "named") then
    return from_named(j, a, b, why)
  elseif (a.tag == "array") then
    return from_array(j, a, b, why)
  elseif (a.tag == "map") then
    return from_map(j, a, b, why)
  elseif (a.tag == "fn") then
    return from_fn(j, a, b, why)
  elseif (a.tag == "var") then
    return from_var(j, a, b, why)
  end
  return from_atom(j, a, b, why)
end

rel = function(j: Relation.Judge, a: Type, b: Type, why: boolean): Relation.Refusal?
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
  memo[key] = r == nil -- checked: view_written
  if why and r ~= nil then
    j.explained[key] = r -- checked: view_written
  end
  return r
end

-- Variance -----------------------------------------------------------------------------------

--- How a type parameter of a declaration is used, as bits: `COVARIANT` where a value of it is read out (a field that is
--- not `mut`, a return, an element of a view), `CONTRAVARIANT` where one is passed in (a parameter), both where it is
--- written and read (a `mut` field, the element of a `mut` collection, a map's key), and neither where it is unused.
local COVARIANT <const> = 1
local CONTRAVARIANT <const> = 2
local INVARIANT <const> = 3

--- The use `inner`, of a parameter as it stands in a type that is itself used as `outer`.
local function compose(outer: integer, inner: integer): integer
  if inner == 0 or outer == 0 then
    return 0
  elseif inner == INVARIANT or outer == INVARIANT then
    return INVARIANT
  elseif inner == COVARIANT then
    return outer
  end
  return if outer == COVARIANT then CONTRAVARIANT else COVARIANT end
end

--- Adds to `uses` how each type parameter of the declaration being read is used in `t`, which stands there as `at`;
--- `level` is how many generic function binders `t` is inside. `self_decl` is that declaration, read as `current` has
--- it so far. `receiver` says `t` is the type of a method, whose first parameter, where it is the declaring type with its
--- own parameters, is the value the method is called on and says nothing of them.
function Variance.uses_in(j: Relation.Judge, t: Type, at: integer, level: integer, uses: mut {integer: integer}, self_decl: Types.Decl,
                          current: {integer: integer}, receiver?: boolean)
  if at == 0 or t.open <= level then
    return
  end
  if (t.tag == "var") then
    if t.depth == level then
      uses[t.index + 1] = (uses[t.index + 1] or 0) | at
    end
  elseif (t.tag == "named") then
    local given = if t.decl == self_decl then current else Variance.of(j, t.decl) end
    for i, each in ipairs(t.args) do
      Variance.uses_in(j, each, compose(at, if t.value then INVARIANT else (given[i] or INVARIANT) end), level, uses, self_decl,
        current)
    end
  elseif (t.tag == "array") then
    Variance.uses_in(j, t.element, if t.mut then INVARIANT else at end, level, uses, self_decl, current)
  elseif (t.tag == "map") then
    Variance.uses_in(j, t.key, INVARIANT, level, uses, self_decl, current)
    Variance.uses_in(j, t.value, if t.mut then INVARIANT else at end, level, uses, self_decl, current)
  elseif (t.tag == "union") then
    for _, m in ipairs(t.members) do
      Variance.uses_in(j, m, at, level, uses, self_decl, current)
    end
  elseif (t.tag == "fn") then
    local inside = level + (if #t.tparams > 0 then 1 else 0 end)
    local passed = compose(at, CONTRAVARIANT)
    for _, tp in ipairs(t.tparams) do
      for _, bound in ipairs(tp.bounds or {}) do
        Variance.uses_in(j, bound, INVARIANT, inside, uses, self_decl, current)
      end
    end
    for k, p in ipairs(t.params) do
      local own = false
      local pt = p.type
      if k == 1 and receiver == true and (pt.tag == "named") and pt.decl == self_decl and not pt.value then
        own = true
        for i, each in ipairs(pt.args) do
          own = own and (each.tag == "var") and each.depth == inside and each.index == i - 1
        end
      end
      if not own then
        Variance.uses_in(j, pt, passed, inside, uses, self_decl, current)
      end
    end
    local rest = t.rest
    if rest ~= nil then
      Variance.uses_in(j, rest, passed, inside, uses, self_decl, current)
    end
    for _, alt in ipairs(t.rets) do
      for _, item in ipairs(alt.items) do
        Variance.uses_in(j, item, at, inside, uses, self_decl, current)
      end
      local tail = alt.tail
      if tail ~= nil then
        Variance.uses_in(j, tail, at, inside, uses, self_decl, current)
      end
      local narrows = alt.narrows
      if narrows ~= nil then
        Variance.uses_in(j, narrows.to, INVARIANT, inside, uses, self_decl, current)
      end
    end
  end
end

--- How each type parameter of `decl` is used in its body, by its fields, array part, methods (their receiver aside), the
--- interfaces it lists and an alias's type: read until it holds, from unused, for a declaration that names itself. A
--- declaration that names one whose reading is open takes that one's parameters as invariant.
function Variance.of(j: Relation.Judge, decl: Types.Decl): {integer: integer}
  local known = j.variances[decl]
  if known ~= nil then
    return known
  end
  local body = decl.body
  if body == nil then
    -- A declaration not yet defined is read as invariant, as uses of it compared with the same arguments need no body.
    return {}
  end
  local open: mut {integer: integer} = {}
  for i = 1, #body.tparams do
    open[i] = INVARIANT
  end
  -- While it is read, a declaration that names this one takes its parameters as invariant.
  j.variances[decl] = open
  local current: mut {integer: integer} = {}
  for i = 1, #body.tparams do
    current[i] = 0
  end
  while true do
    local uses: mut {integer: integer} = {}
    for i = 1, #body.tparams do
      uses[i] = 0
    end
    for _, f in ipairs(body.fields) do
      -- A function field may be called with any value as its first argument (`b.f(other)`), so its first parameter
      -- counts, the declaring type there too.
      Variance.uses_in(j, f.type, if f.mut == true then INVARIANT else COVARIANT end, 0, uses, decl, current)
    end
    local array = body.array
    if array ~= nil then
      Variance.uses_in(j, array, COVARIANT, 0, uses, decl, current)
    end
    for _, s in ipairs(body.supers) do
      Variance.uses_in(j, s, COVARIANT, 0, uses, decl, current)
    end
    local alias = body.alias
    if alias ~= nil then
      Variance.uses_in(j, alias, COVARIANT, 0, uses, decl, current)
    end
    for _, m in ipairs(body.methods) do
      Variance.uses_in(j, m.type, COVARIANT, 0, uses, decl, current, true)
    end
    local same = true
    for i = 1, #body.tparams do
      same = same and uses[i] == current[i]
    end
    current = uses
    if same then
      break
    end
  end
  -- A parameter the body does not use is invariant: an opaque declaration (`Coroutine<Y, R, S>`) or a tag
  -- (`Tagged<Meters>`) means it by its name alone.
  for i = 1, #body.tparams do
    if current[i] == 0 then
      current[i] = INVARIANT
    end
  end
  j.variances[decl] = current
  return current
end

--- Nil where the arguments `held` of a use of `decl` are below the arguments `other` of another, each as the declaration
--- uses its parameter: unused, either way, read out, below, passed in, above, both, the same type.
function Variance.args_below(j: Relation.Judge, decl: Types.Decl, held: {Type}, other: {Type}, why: boolean): Relation.Refusal?
  local uses = Variance.of(j, decl)
  for i, x in ipairs(held) do
    local y = other[i]
    if y ~= nil and x ~= y and x.tag ~= "invalid" and y.tag ~= "invalid" then
      local use = uses[i] or INVARIANT
      local r: Relation.Refusal? = nil
      local step: Relation.StepKind = "argument"
      if use == COVARIANT then
        r = rel(j, x, y, why)
      elseif use == CONTRAVARIANT then
        r, step = rel(j, y, x, why), "argument_in"
      elseif use == INVARIANT then
        r = leaf(j, why, "invariant_generic", x, y)
      end
      if r ~= nil then
        return through(why, step, i, r)
      end
    end
  end
  return nil
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

--- Whether the function `a` is below the function `b` with trailing parameters dropped.
local function known_below(j: Relation.Judge, a: Type, b: Type): boolean
  if a.tag ~= "fn" or #a.tparams > 0 then
    return false
  end
  local targets: {Type} = { b }
  if b.tag == "union" then
    targets = b.members
  end
  for _, m in ipairs(targets) do
    if m.tag == "fn" and #m.tparams == 0 and parameters_below(j, a, m, false, true) == nil and
        returns_below(j, a, m, false) == nil then
      return true
    end
  end
  return false
end

--- Whether `a` is below `b` for a function `a` whose own parameter list is known (a function literal or a declared function
--- that is never assigned): it may take fewer trailing parameters than the function type `b`, or a member of the union `b`,
--- passes, and only at this top level. A function-typed variable, field, parameter or return has the type it was declared,
--- which may leave out parameters the value takes, so it never drops one: `function(x?: integer)` is below `function()`,
--- and that below `function(x: string)` would otherwise put a string in `x`.
function Relation.subtype_known(self: Relation.Judge, a: Type, b: Type): boolean
  owned(self, a)
  owned(self, b)
  return rel(self, a, b, false) == nil or known_below(self, a, b)
end

--- Nil where [`Relation.subtype_known`] holds, else why not (the reason of the strict relation).
function Relation.refuse_known(self: Relation.Judge, a: Type, b: Type): Relation.Refusal?
  owned(self, a)
  owned(self, b)
  local r = self:refuse(a, b)
  if r ~= nil and known_below(self, a, b) then
    return nil
  end
  return r
end

function Relation.field_pairs(self: Relation.Judge, pattern: Named, actual: Named): {Type}?
  owned(self, pattern)
  owned(self, actual)
  return field_pairs(self, pattern, actual)
end

function Relation.instantiate(store: Store, t: Type, args: {Type}): Type?
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

function Relation.specialize(store: Store, f: Fn, args: {Type}): Fn?
  for _, a in ipairs(args) do
    if a.owner ~= store.owner then
      error("relation: a type of another store", 2)
    end
  end
  return specialize_within(store, f, args)
end

function Relation.binder(decl: Types.Decl): {Types.TParam}
  local out: mut {Types.TParam} = {}
  local body = decl.body
  if body == nil then
    error("relation: " .. decl.name .. " is not defined", 0)
  end
  for i, tp in ipairs(body.tparams) do
    for _, bound in ipairs(tp.bounds or {}) do
      if bound.owner ~= decl.owner then
        error("relation: a type of another store", 2)
      end
    end
    out[i] = { bounds = tp.bounds }
  end
  return out
end

function Relation.trace(r: Relation.Refusal): string
  local parts: mut {string} = {}
  for _, step in ipairs(r.path) do
    local index = step.index
    parts[#parts + 1] = if index ~= nil then step.kind .. " " .. tostring(index) else step.kind end
  end
  local where = #parts > 0 and table.concat(parts, " > ") or "here" -- checked: and_ternary
  return r.code .. " at " .. where .. ": " .. Types.display(r.sub) .. " is not below " .. Types.display(r.super)
end

--- The Judge that [`Relation.new`] makes.
local class Made is Relation.Judge
  function subtype(self, a: Type, b: Type): boolean
    owned(self, a)
    owned(self, b)
    return rel(self, a, b, false) == nil
  end

  function refuse(self, a: Type, b: Type): Relation.Refusal?
    owned(self, a)
    owned(self, b)
    self.explained = {} -- checked: field_fixed
    local r = rel(self, a, b, true)
    self.explained = {} -- checked: field_fixed
    return r
  end

  function accepts(self, argument: Type, param: Type): boolean
    owned(self, argument)
    owned(self, param)
    return param.tag == "any" or rel(self, argument, param, false) == nil
  end

  function refuse_argument(self, argument: Type, param: Type): Relation.Refusal?
    if param.tag == "any" then
      owned(self, argument)
      owned(self, param)
      return nil
    end
    return self:refuse(argument, param)
  end

  function listed(self, n: Named): Relation.Listing
    owned(self, n)
    local closure = closure_of(self, n)
    local copied: mut {Type} = {}
    for i, listed in ipairs(closure.list) do
      copied[i] = listed
    end
    return { types = copied, complete = closure.complete }
  end

  function enter(self, tparams: {Types.TParam})
    local copied: mut {Types.TParam} = {}
    for i, tp in ipairs(tparams) do
      for _, bound in ipairs(tp.bounds or {}) do
        owned(self, bound)
        -- The bound is read as it is, with no variable of a binder outside it to shift.
        if not Types.builtin_bound(bound) and (not ((bound.tag == "named")) or bound.decl.kind ~= "interface" or
            #bound.args > 0) then
          error("relation: a bound is an interface used with no arguments, `Ordered`, `Numeric`, `Key` or `Some`, not " ..
              Types.display(bound), 2)
        end
      end
      copied[i] = tp
    end
    self.scopes[#self.scopes + 1] = { tparams = copied, memo = {} }
  end

  function leave(self)
    if #self.scopes == 0 then
      error("relation: leave without enter", 2)
    end
    self.scopes[#self.scopes] = nil
  end
end

function Relation.new(store: Store): Relation.Judge
  local judge: Made = {
    store = store, closed = {}, free = {}, scopes = {}, closures = {}, variances = {}, sets = {}, explained = {},
    none = { code = "mismatch", path = {}, sub = store.invalid, super = store.invalid },
    nil_type = store:atom("nil"),
  }
  return judge
end

return Relation
