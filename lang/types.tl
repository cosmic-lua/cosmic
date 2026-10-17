--- The type store of the new checker
--- ([`doc/plans/new-checker-types.md`], "the forms" and "how a type is
--- identified"): the forms a type takes, a [`Store`] that interns them so that
--- equal types are one object and equality is `==`, the normal form of a union,
--- the spelling of a type in the grammar's own words (what an error prints), and
--- the canonical text a type crosses processes as.
---
--- **Forms.** An [`Atom`] is `integer`, `number`, `string`, `boolean`, `true`,
--- `false`, `nil`, `never`, `any` or `invalid`; the others are a [`Named`] type
--- (a declaration and its arguments), an [`Array`] `{T}` or `mut {T}`, a [`Map`]
--- `{K: V}` or `mut {K: V}`, a [`Union`] (which also holds `T?`), a function
--- ([`Fn`]) and a type variable ([`Var`]). A type is immutable. The one field a
--- reader may see change is `digest`, which [`Types.digest`] fills once.
---
--- **Identity.** A structural form is interned by its parts, so a store holds
--- one `{integer}`. A named type is its declaration's path and its arguments: a
--- [`Decl`] is made by [`Store.declare`] and given a body by [`Store.define`],
--- and a type never unfolds the body, so a record that mentions itself is a
--- type like any other. A type belongs to the store that made it, and a
--- constructor refuses a part from another store.
---
--- **Checks.** What the store can tell where a type is made it refuses by raising: a named type
--- with other than its declaration's count of arguments (a use made before the count is known is
--- checked when [`Store.define`] gives it), a variable that names a type parameter its binder lacks
--- (checked where a function type or a declaration holds it), a bound that is not an interface
--- used with no arguments, a declaration that lists itself directly or through the declarations
--- it lists, and a type that nests past [`Types.max_depth`]. The rest of "declarations" in the
--- plan (agreement, tags, keys, dense arrays, distinct names) is for [`lang.declarations`], which
--- lowers the syntax tree's declarations and refuses with an error rather than raising, and
--- makes `invalid` of a type that nests too deep.
---
--- **Union normal form.** [`Store.union`] flattens nested unions, drops `never`
--- and duplicates, keeps `nil` as a flag beside the other members, and lets `any`
--- absorb the rest (`invalid` absorbs `any`). Three pairs collapse: `integer`
--- into `number`, an enum into `string`, and `true` with `false` into
--- `boolean`. A union of one member is that member, and a union of no member
--- and a nil flag is `nil`. The members are in the order of their [`Types.digest`],
--- which depends on structure alone, so the order is the same in every store.
--- No other subsumption is searched for.
---
--- **A declaration as a value.** The name of a record, class or userdata record used as a value
--- (`Circle.make()`, `require("m")`) is the table of its functions, and no instance of it: a
--- [`Named`] with `value` set, written `(val ...)` in the text. It is a type of its own, below only
--- itself, so `local c: Circle = Circle` is refused.
---
--- **Type variables.** A variable is `(depth, index)`: `index` is the position
--- in a binder's list of type parameters, and `depth` counts the binders between
--- the variable and its own, 0 for the nearest. Only a function type with type
--- parameters or a declaration with them is a binder. Two spellings of one
--- generic signature are one type, and a closed one is the same type wherever
--- it stands. `open` says how many binders outside a type it reaches.
---
--- **Functions.** A function type holds no parameter names: they are in the syntax tree, and
--- a signature is the same type whatever its parameters were called. Its returns are a set
--- of alternatives, kept without repeats and in digest order. A narrowing declaration is an
--- alternative with `narrows`, and the only one, since the grammar makes it the whole return
--- list. Display names a parameter `p<position>` where a spelling needs a name: an
--- omittable parameter and the one a narrowing declaration names.
---
--- **Text.** [`Types.encode`] writes a type as canonical text, an S-expression that names
--- a declaration by its path, and [`Store.decode`] reads it into any store, in normal form
--- whatever the text was. Equal types have equal text, so the text can be hashed or compared:
---
---     (array (ref "cosmic.stream" "Stream.Reader"))   {Stream.Reader}
---     (val "cosmic.stream" "Stream")                  the declaration Stream used as a value
---     (mmap string (union (ref "sys" "Fd") nil))      mut {string: Fd?}
---     (fn (tp (ref "m" "Ordered")) ((var 0 0)) (rets ((var 0 0))))
---                                                     function<T is Ordered>(T): T
---     (fn (tp) () (rets (true string) (false any)))
---                                         function(): (true, string) | (false, any)
---
--- A declaration has text of its own ([`Types.encode_declaration`]). A decoder that meets a
--- path its store lacks asks the [`Loader`] the store was made with for it, and takes the answer
--- only if it is that path's. Text is UTF-8, and a decoder refuses what is not, text that nests
--- past 1000 types (across the declarations a loader answers) and a declaration that has no
--- body. A refused decode leaves the store as it was, and says why in a message that begins
--- `types:`.

-- TODO: replace each `where` clause with the single-member enum tag the plan's tagged unions
-- use, and read the types by their forms, once ci/cosmic-driver.pin names a release whose
-- checker discriminates a union of records by a tag (lang/ast.tl has the same gap): the fork
-- discriminates only by a `where` clause.
local Hash = require("cosmic.hash")
local Lexer = require("lang.lexer")

local record Types
  --- A form of type. The first ten are the atoms.
  enum Tag
    "integer"
    "number"
    "string"
    "boolean"
    "true"
    "false"
    "nil"
    "never"
    "any"
    "invalid"
    "named"
    "array"
    "map"
    "union"
    "fn"
    "var"
  end

  --- What a declaration declares.
  enum DeclKind
    "record"
    "class"
    "interface"
    "enum"
    "userdata"
  end

  --- What every type holds.
  interface Base
    tag: Tag
    --- Whether it is an atom. [`Atom`] is told from the other forms by it, since a `where` clause
    --- may read `self` once.
    atom: boolean
    --- Its position among the types of its store, from 1, in the order they were made.
    --- Store-local: nothing outside the store keeps one.
    id: integer
    --- The store it belongs to.
    owner: integer
    --- Filled by [`Types.digest`]; "" until then.
    digest: string
    --- How many binders outside this type its variables reach: 0 where it is closed.
    open: integer
    --- Whether a view of it differs from it: it holds a `mut` collection that a view reaches
    --- through collections and unions, and not through a named type or a function.
    has_mut: boolean
    --- How many types its text has, a type that is held twice counted twice, saturating at
    --- 2^40: a type that shares its parts has far more text than it has types.
    weight: integer
    --- How deeply it nests, 1 for an atom. A store refuses a type that nests past 1000.
    height: integer
  end

  --- `integer`, `number`, `string`, `boolean`, `true`, `false`, `nil`, `never`, `any` or
  --- `invalid` (what a type that failed to lower becomes). The tag is the name.
  record Atom is Base
    where self.atom
  end

  --- A use of a declaration and its type arguments, or the declaration itself as a value.
  record Named is Base
    where self.tag == "named"
    decl: Decl
    args: {Type}
    --- Whether it is the declaration used as a value (`Circle` in `Circle.make()`): the table of its
    --- functions, which is no instance of it and has no interface listed. A declaration and its
    --- value are two types.
    value: boolean
  end

  --- `{T}`, or `mut {T}` where `mut`.
  record Array is Base
    where self.tag == "array"
    element: Type
    mut: boolean
  end

  --- `{K: V}`, or `mut {K: V}` where `mut`.
  record Map is Base
    where self.tag == "map"
    key: Type
    value: Type
    mut: boolean
  end

  --- Two or more types, or one and `nil`. `members` are never `nil`, `never`, `any` or a
  --- union, hold at least one type, and are in digest order; `nilable` is the `nil`.
  record Union is Base
    where self.tag == "union"
    members: {Type}
    nilable: boolean
  end

  --- A type variable ([`Types`] has the numbering).
  record Var is Base
    where self.tag == "var"
    depth: integer
    index: integer
  end

  --- A type parameter of a function type or a declaration, and its bound, one interface.
  record TParam
    bound?: Type
  end

  --- A parameter. `type` is as the checker reads it inside: where `omittable` (`name?: T`) it is
  --- `T?`.
  record Param
    type: Type
    omittable?: boolean
  end

  --- A narrowing declaration `v is T` or `asserts v is T`, which is a function's whole return
  --- list.
  record Narrows
    --- The position of the parameter, from 1.
    param: integer
    to: Type
    asserts: boolean
  end

  --- One value list a function may answer: `items`, then any number of `tail`. A narrowing
  --- declaration has `narrows` and no `tail`; it is the function's only alternative, and its `items`
  --- are the one `boolean` of an `is` and none for an `asserts`, which the store fills in.
  record Alt
    items: {Type}
    tail?: Type
    narrows?: Narrows
  end

  --- The parts [`Store.fn`] builds a function type from.
  record FnSpec
    tparams?: {TParam}
    params?: {Param}
    --- The type of the rest parameter `...: T`.
    rest?: Type
    --- The alternatives. Absent, the function answers nothing: one empty alternative. Empty,
    --- it never returns: the type `function(): never`.
    rets?: {Alt}
  end

  --- A function type. `rets` is a set of alternatives: no repeats, in digest order, none with a
  --- `never` in it.
  record Fn is Base
    where self.tag == "fn"
    tparams: {TParam}
    params: {Param}
    rest?: Type
    rets: {Alt}
  end

  type Type = Atom | Named | Array | Map | Union | Var | Fn

  --- A field of a declaration; `omittable` is `name?: T`, whose `type` is `T?`.
  record Field
    name: string
    type: Type
    mut?: boolean
    omittable?: boolean
  end

  --- A method of a class or a userdata record: a function whose first parameter is the
  --- declaring type.
  record Method
    name: string
    type: Type
  end

  --- A type parameter of a declaration.
  record DeclParam
    name: string
    bound?: Type
  end

  --- What a declaration holds besides its path: the type parameters, the types it lists after
  --- `is` (named types), ordered fields, the array part of `record Node is {Node}`, methods,
  --- or an enum's values.
  record Body
    tparams: {DeclParam}
    supers: {Type}
    fields: {Field}
    array?: Type
    methods: {Method}
    values: {string}
  end

  --- A declaration: a path and, once defined, a body. Its identity is the path.
  record Decl
    kind: DeclKind
    --- The module's name.
    module: string
    --- The names the declaration is nested under, then its own.
    names: {string}
    --- `names` joined by ".".
    name: string
    owner: integer
    --- The path as the text spells it.
    text: string
    --- How many type arguments a use takes, once the declaration or its maker says.
    arity?: integer
    body?: Body
  end

  --- Gives the text of the declaration at a path ([`Types.encode_declaration`]), or nil where
  --- there is none. What a loader makes in the store while a decode that is then refused is
  --- gone with it: a type or declaration it kept is dead, and the store refuses it.
  type Loader = function(module: string, name: string): string | nil

  --- What a decode did to the store apart from the types and declarations it made, to take back
  --- if it fails: it gave `decl` a body and an `arity`, added a use to the uses `pending` holds at
  --- `key`, or took `list` from `pending` at `key`.
  enum UndoKind
    "decl"
    "use"
    "pending"
  end

  record Undo
    what: UndoKind
    decl?: Decl
    arity?: integer
    key?: string
    list?: {Named}
  end

  --- The types of one check. It is not re-entrant, and its types are valid in it alone.
  record Store
    -- The fields down to `depth` are the store's own.
    owner: integer
    count: integer
    --- Every type, by id.
    types: {Type}
    interned: {string: Type}
    declared: {string: Decl}
    list: {Decl}
    atoms: {string: Type}
    loader: Loader | nil
    --- The uses of a declaration whose type parameters are not known yet, by its path, which
    --- `define` checks.
    pending: {string: {Named}}
    --- What a decode has given a declaration, to take back if it fails.
    journal: {Undo}
    --- The declarations being decoded, by path, and in order.
    building: {string: boolean}
    building_order: {string}
    --- How deeply decoding is nested, across the declarations a loader answers, and how many
    --- decodes are open.
    depth: integer
    transactions: integer

    integer: Type
    number: Type
    string: Type
    boolean: Type
    never: Type
    any: Type
    invalid: Type

    --- The atom of this name: `integer`, `number`, `string`, `boolean`, `true`, `false`, `nil`,
    --- `never`, `any` or `invalid`.
    atom: function(Store, name: Tag): Type
    --- `{T}`, or `mut {T}` where `mut`.
    array: function(Store, element: Type, mutable?: boolean): Type
    --- `{K: V}`, or `mut {K: V}` where `mut`.
    map: function(Store, key: Type, value: Type, mutable?: boolean): Type
    --- The union of `members` in normal form.
    union: function(Store, members: {Type}): Type
    --- `t | nil`.
    optional: function(Store, t: Type): Type
    --- `t` without its `nil`: `never` for `nil`, the other members of a union that has one.
    non_nil: function(Store, t: Type): Type
    --- The variable at `depth` and `index`. It is checked against its binder when a function
    --- type or a declaration holds it: a variable in no binder has none to check against.
    var: function(Store, depth: integer, index: integer): Type
    --- The use of `decl` with `args`, or the declaration itself as a value where `value`.
    named: function(Store, decl: Decl, args?: {Type}, value?: boolean): Type
    --- The function type of `spec`.
    fn: function(Store, spec: FnSpec): Type
    --- The declaration at a path, made if it is new. A use of it takes `arity` type arguments
    --- once that is known: from here or from `define`. Raises where the path has another kind or
    --- arity, where the module or a name is not UTF-8, or where the name is a primitive type's.
    declare: function(Store, kind: DeclKind, module: string, names: {string}, arity?: integer): Decl
    --- Gives `decl` its body. Raises where it has one, or the body does not suit its kind, holds a
    --- variable that no binder of it binds, or has a bound that is not an interface, or a use of
    --- the declaration with another count of arguments than its parameters, or lists the declaration
    --- itself, directly or through the declarations it lists.
    define: function(Store, decl: Decl, body: Body): Decl
    --- The declaration at a path, or nil.
    find: function(Store, module: string, name: string): Decl | nil
    --- Every declaration, in the order they were declared.
    declarations: function(Store): {Decl}
    --- How many types the store holds.
    size: function(Store): integer
    --- The type canonical text `text` spells, or nil and why (a message that begins `types:`).
    --- It is in normal form whatever the text was. A refusal leaves the store as it was.
    decode: function(Store, text: string): Type | nil, string
    --- The declaration text `text` spells, declared and defined here, or nil and why. A
    --- declaration the store holds is returned if the text has its body, and refused if not.
    --- A refusal leaves the store as it was.
    decode_declaration: function(Store, text: string): Decl | nil, string
  end

  --- The store of a check. `loader` is asked for a declaration that decoding meets and the
  --- store lacks.
  new: function(loader?: Loader): Store

  --- How deeply a type may nest in a store and in text being decoded: the innermost type counts
  --- as one. A constructor raises for a type that would nest deeper.
  max_depth: integer

  --- The types `t` is made of, in the order its text writes them: the arguments of a named type,
  --- the element, key and value of a collection, the members of a union, and for a function the
  --- bounds, parameters, rest, and each alternative's items, tail and narrowing type. A variable
  --- and an atom have none. The list may be the type's own: it is not changed.
  parts: function(t: Type): {Type}

  --- The declaration that lists `decl` among the declarations `supers` and what those list, or
  --- nil: `decl` itself where one of `supers` is `decl`. A declaration with no body lists
  --- nothing, so a cycle shows when its last declaration is defined. [`Store.define`] raises for
  --- a body whose `supers` have one.
  listing_cycle: function(decl: Decl, supers: {Type}): Decl | nil

  --- The type in the grammar's own spelling, as an error prints it. `binders` names the
  --- type parameters a free variable stands for, outermost first.
  display: function(t: Type, binders?: {{string}}): string

  --- The canonical text of the type. Raises for a type of more than 100,000 types of text: a
  --- type that shares its parts has the text of the tree it unfolds to.
  encode: function(t: Type): string

  --- The canonical text of a defined declaration. Raises as [`Types.encode`] does.
  encode_declaration: function(decl: Decl): string

  --- A hex string that depends on the structure of the type alone, in every store: the first 32
  --- hex digits of the SHA-256 of its canonical text with each part written as its own digest
  --- (a Merkle hash, so a type held many times costs once). Union members are in its order.
  digest: function(t: Type): string
end

local type Atom = Types.Atom
local type Named = Types.Named
local type Array = Types.Array
local type Map = Types.Map
local type Union = Types.Union
local type Var = Types.Var
local type Fn = Types.Fn
local type Type = Types.Type
local type Store = Types.Store
local type Decl = Types.Decl
local type Alt = Types.Alt
local type Param = Types.Param
local type TParam = Types.TParam
local type Body = Types.Body
local type DeclParam = Types.DeclParam
local type Tag = Types.Tag
local type FnSpec = Types.FnSpec
local type Loader = Types.Loader

local ATOMS <const>: {Tag} = {
  "integer", "number", "string", "boolean", "true", "false", "nil", "never", "any", "invalid",
}

local DECL_KINDS <const>: {string: Types.DeclKind} = {
  record = "record", class = "class", interface = "interface", enum = "enum", userdata = "userdata",
}

--- The most a type may nest, in a store and in text being decoded, whose innermost type counts
--- as one. It bounds every recursion over a type, so that no type or text exhausts the stack.
local MAX_DEPTH <const> = 1000

Types.max_depth = MAX_DEPTH

--- The most types of text [`Types.encode`] writes.
local TEXT_LIMIT <const> = 100000

--- The most a weight counts.
local WEIGHT_CAP <const> = 1 << 40

--- The types of text display writes before it ends the rest with `...`.
local DISPLAY_BUDGET <const> = 5000

--- The names of the primitive types, which no declaration takes.
local PRIMITIVE_NAMES <const>: {string: boolean} = {
  integer = true, number = true, string = true, boolean = true, ["true"] = true, ["false"] = true,
  ["nil"] = true, never = true, any = true, invalid = true, thread = true,
}

--- The hex digits of a digest that are kept.
local DIGEST_LENGTH <const> = 32

local counter = { stores = 0 }

-- Text -----------------------------------------------------------------------

--- A string in quotes, with a backslash and three digits for every byte that could end it or is not
--- printable ASCII, so that the text is ASCII whatever bytes the string holds.
local function quote(s: string): string
  local escaped = s:gsub('[%c"\\\127-\255]', function(c: string): string
    return string.format("\\%03d", c:byte())
  end)
  return '"' .. escaped .. '"'
end

--- The text of an alternative, its parts written by `sub`.
local function render_alt(alt: Alt, sub: function(Type): string): string
  local narrows = alt.narrows
  if narrows ~= nil then
    return "((" .. (narrows.asserts and "asserts " or "is ") .. narrows.param .. " " .. sub(narrows.to) .. "))"
  end
  local parts: {string} = {}
  for _, item in ipairs(alt.items) do
    parts[#parts + 1] = sub(item)
  end
  local tail = alt.tail
  if tail ~= nil then
    parts[#parts + 1] = "(... " .. sub(tail) .. ")"
  end
  return "(" .. table.concat(parts, " ") .. ")"
end

--- The text of one type with the text of each part it holds written by `sub`: the canonical
--- text when `sub` is the text itself, the key of the store's table when it is the part's id, and
--- what a digest hashes when it is the part's digest.
local function render(t: Type, sub: function(Type): string): string
  if t is Atom then
    return t.tag
  elseif t is Named then
    local parts: {string} = { t.value and "(val " or "(ref ", t.decl.text }
    for _, a in ipairs(t.args) do
      parts[#parts + 1] = " " .. sub(a)
    end
    parts[#parts + 1] = ")"
    return table.concat(parts)
  elseif t is Array then
    return "(" .. (t.mut and "marray " or "array ") .. sub(t.element) .. ")"
  elseif t is Map then
    return "(" .. (t.mut and "mmap " or "map ") .. sub(t.key) .. " " .. sub(t.value) .. ")"
  elseif t is Union then
    local parts: {string} = { "(union" }
    for _, m in ipairs(t.members) do
      parts[#parts + 1] = " " .. sub(m)
    end
    if t.nilable then
      parts[#parts + 1] = " nil"
    end
    parts[#parts + 1] = ")"
    return table.concat(parts)
  elseif t is Var then
    return "(var " .. t.depth .. " " .. t.index .. ")"
  elseif not (t is Fn) then
    return ""
  end
  local f: Fn = t
  local parts: {string} = { "(fn (tp" }
  for _, tp in ipairs(f.tparams) do
    local bound = tp.bound
    parts[#parts + 1] = " " .. (bound ~= nil and sub(bound) or "_")
  end
  parts[#parts + 1] = ") ("
  local params: {string} = {}
  for _, p in ipairs(f.params) do
    params[#params + 1] = p.omittable and "(opt " .. sub(p.type) .. ")" or sub(p.type)
  end
  local rest = f.rest
  if rest ~= nil then
    params[#params + 1] = "(rest " .. sub(rest) .. ")"
  end
  parts[#parts + 1] = table.concat(params, " ")
  parts[#parts + 1] = ") (rets"
  for _, alt in ipairs(f.rets) do
    parts[#parts + 1] = " " .. render_alt(alt, sub)
  end
  parts[#parts + 1] = "))"
  return table.concat(parts)
end

local function parts_of(t: Type): {Type}
  local parts: {Type} = {}
  if t is Named then
    parts = t.args
  elseif t is Array then
    parts = { t.element }
  elseif t is Map then
    parts = { t.key, t.value }
  elseif t is Union then
    parts = t.members
  elseif t is Fn then
    for _, tp in ipairs(t.tparams) do
      local bound = tp.bound
      if bound ~= nil then
        parts[#parts + 1] = bound
      end
    end
    for _, p in ipairs(t.params) do
      parts[#parts + 1] = p.type
    end
    local rest = t.rest
    if rest ~= nil then
      parts[#parts + 1] = rest
    end
    for _, alt in ipairs(t.rets) do
      for _, item in ipairs(alt.items) do
        parts[#parts + 1] = item
      end
      local tail = alt.tail
      if tail ~= nil then
        parts[#parts + 1] = tail
      end
      local narrows = alt.narrows
      if narrows ~= nil then
        parts[#parts + 1] = narrows.to
      end
    end
  end
  return parts
end

function Types.parts(t: Type): {Type}
  return parts_of(t)
end

local function id_text(t: Type): string
  return tostring(t.id)
end

local function digest_text(t: Type): string
  local cached = t.digest
  if cached ~= "" then
    return cached
  end
  local d = Hash.hex_sha256(render(t, digest_text)):sub(1, DIGEST_LENGTH)
  t.digest = d
  return d
end

local function encode_text(t: Type): string
  return render(t, encode_text)
end

--- The text of `t`, which is refused where it would be too large.
local function written(t: Type): string
  -- TODO: write a part that a type holds many times once, with a name, so that the text of a
  -- type that shares its parts is as large as the type, once a declaration in the tree has text
  -- past the limit: until then the limit stands in (doc/plans/new-checker-types.md, "rows").
  if t.weight > TEXT_LIMIT then
    error("types: the text of " .. Types.display(t) .. " is too large, " .. t.weight .. " types", 3)
  end
  return render(t, encode_text)
end

Types.digest = digest_text
Types.encode = written

-- Display ----------------------------------------------------------------------

--- What display carries down a type: the names of the type parameters in scope, outermost
--- binder first.
local record Names
  binders: {{string}}
  --- How many more types display writes; past it the rest is `...`.
  budget: integer
  --- The root of the display, and the names of the declarations in it, which a type parameter
  --- does not take. Found when the first type parameter is named.
  root: Type
  taken: {string: boolean} | nil
end

local NAME_LETTERS <const> = "TUVWXYZABCDEFGHIJKLMNOPQRS"

--- The names of the declarations in `root`.
local function declared_names(root: Type): {string: boolean}
  local taken: {string: boolean} = {}
  local seen: {integer: boolean} = {}
  local stack: {Type} = { root }
  while #stack > 0 do
    local t = stack[#stack]
    stack[#stack] = nil
    if not seen[t.id] then
      seen[t.id] = true
      if t is Named then
        -- The first name of a dotted one is what the text writes first.
        taken[t.decl.names[1]] = true
      end
      for _, part in ipairs(parts_of(t)) do
        stack[#stack + 1] = part
      end
    end
  end
  return taken
end

--- The name display gives the type parameter at `index` of the binder that has `level` binders
--- outside it: a letter, with `_` and the level after it from the second binder on, and `_` after
--- that while a declaration in the type has the name (or its first name), so that a type variable
--- is never taken for a type. The letters have no `_`, so no two variables get one name.
local function parameter_name(names: Names, level: integer, index: integer): string
  local name = "P" .. index .. (level == 0 and "" or "_" .. level)
  if index < #NAME_LETTERS then
    local letter = NAME_LETTERS:sub(index + 1, index + 1)
    name = level == 0 and letter or letter .. "_" .. level
  end
  local taken: {string: boolean} = names.taken or declared_names(names.root)
  names.taken = taken
  while taken[name] do
    name = name .. "_"
  end
  return name
end

--- How an atom or a form is told from another when a union is written: atoms in the order
--- the plan lists them, then named types, collections, variables and functions.
local ATOM_RANK <const>: {string: integer} = {
  integer = 1, number = 2, string = 3, boolean = 4, ["true"] = 5, ["false"] = 6, ["nil"] = 7,
  never = 8, any = 9, invalid = 10,
}

local function rank(t: Type): integer
  if t is Atom then
    return ATOM_RANK[t.tag]
  elseif t is Named then
    return 20
  elseif t is Array or t is Map then
    return 30
  elseif t is Var then
    return 40
  end
  return 50
end

local show: function(t: Type, names: Names, parenthesized: boolean): string

--- `t` written before a comma: a function type is parenthesized, or the types after it would be
--- taken for its returns. `last` says that nothing follows it in the list.
local function show_element(t: Type, names: Names, last: boolean): string
  return show(t, names, not last and t is Fn)
end

--- The types written in order, as `show` writes them in a list of type arguments.
local function show_list(types: {Type}, names: Names): {string}
  local out: {string} = {}
  for i, t in ipairs(types) do
    out[i] = show_element(t, names, i == #types)
  end
  return out
end

local record Ranked
  rank: integer
  text: string
end

--- The members of a union written as a union is, without its `nil`, in the order that reads best
--- and that depends on the types alone.
local function show_members(u: Union, names: Names): string
  local items: {Ranked} = {}
  for i, m in ipairs(u.members) do
    items[i] = { rank = rank(m), text = show(m, names, true) }
  end
  table.sort(items, function(a: Ranked, b: Ranked): boolean
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    return a.text < b.text
  end)
  local out: {string} = {}
  for i, item in ipairs(items) do
    out[i] = item.text
  end
  return table.concat(out, " | ")
end

--- A type written as an optional parameter `name?: T` has it: `T` without its `nil`.
local function show_without_nil(t: Type, names: Names, last: boolean): string
  if t is Union then
    local u: Union = t
    if u.nilable then
      if #u.members == 1 then
        return show_element(u.members[1], names, last)
      end
      return show_members(u, names)
    end
  end
  return show_element(t, names, last)
end

--- A return item, written so that a function type among a list's items does not take the rest
--- of the list as its own returns.
local function show_item(t: Type, names: Names): string
  if t is Fn then
    return "(" .. show(t, names, false) .. ")"
  end
  return show(t, names, false)
end

local function show_alt(alt: Alt, names: Names): string
  local narrows = alt.narrows
  if narrows ~= nil then
    return (narrows.asserts and "asserts " or "") .. "p" .. narrows.param .. " is " .. show(narrows.to, names, false)
  end
  local parts: {string} = {}
  for _, item in ipairs(alt.items) do
    parts[#parts + 1] = show_item(item, names)
  end
  local tail = alt.tail
  if tail ~= nil then
    parts[#parts + 1] = show_item(tail, names) .. "..."
  end
  return table.concat(parts, ", ")
end

--- The order the alternatives of a function are written in: by the ranks of their items, so
--- that `(true, R)` comes before `(false, E)`, and then by their text.
local function alt_order(alt: Alt, text: string): string
  local ranks: {string} = {}
  for i, item in ipairs(alt.items) do
    ranks[i] = string.format("%02d", rank(item))
  end
  return table.concat(ranks) .. "|" .. text
end

local record Ordered
  text: string
  order: string
end

--- The returns of a function type, with their `: `, or "" where it answers nothing.
local function show_rets(f: Fn, names: Names): string
  local alts: {Ordered} = {}
  for _, alt in ipairs(f.rets) do
    local text = show_alt(alt, names)
    alts[#alts + 1] = { text = text, order = alt_order(alt, text) }
  end
  if #alts == 0 then
    return ": never"
  end
  if #alts == 1 then
    local text = alts[1].text
    -- A list that begins with a parenthesis and goes on would be read as a parenthesized list
    -- that has ended. So would a union of function types, whose members would be read as
    -- parenthesized lists joined by `|`.
    local alt = f.rets[1]
    local only = alt.items[1]
    local union_of_functions = only ~= nil and only is Union and not only.nilable
    if text:sub(1, 1) == "(" and (#alt.items > 1 or alt.tail ~= nil or union_of_functions) then
      text = "(" .. text .. ")"
    end
    return text == "" and "" or ": " .. text
  end
  table.sort(alts, function(a: Ordered, b: Ordered): boolean
    return a.order < b.order
  end)
  -- TODO: spell an alternative that is empty or ends in `T...` among several, once the grammar's
  -- `plist` takes `()` and `(A, T...)` (doc/plans/new-checker-grammar.md, "types"): the text
  -- below parses to a syntax error until then.
  local out: {string} = {}
  for i, alt in ipairs(alts) do
    out[i] = "(" .. alt.text .. ")"
  end
  return ": " .. table.concat(out, " | ")
end

local function show_fn(f: Fn, names: Names): string
  local generic = #f.tparams > 0
  local header = "function"
  if generic then
    local own: {string} = {}
    for i = 1, #f.tparams do
      own[i] = parameter_name(names, #names.binders, i - 1)
    end
    names.binders[#names.binders + 1] = own
    local declared: {string} = {}
    for i, tp in ipairs(f.tparams) do
      local bound = tp.bound
      declared[i] = own[i] .. (bound ~= nil and " is " .. show(bound, names, false) or "")
    end
    header = header .. "<" .. table.concat(declared, ", ") .. ">"
  end
  -- A parameter the type must name is written `p<position>`: an optional one, and one a
  -- narrowing return names.
  local named: {integer: boolean} = {}
  for _, alt in ipairs(f.rets) do
    local narrows = alt.narrows
    if narrows ~= nil then
      named[narrows.param] = true
    end
  end
  local params: {string} = {}
  local rest = f.rest
  for i, p in ipairs(f.params) do
    local last = rest == nil and i == #f.params
    if p.omittable then
      params[i] = "p" .. i .. "?: " .. show_without_nil(p.type, names, last)
    elseif named[i] then
      params[i] = "p" .. i .. ": " .. show_element(p.type, names, last)
    else
      params[i] = show_element(p.type, names, last)
    end
  end
  if rest ~= nil then
    params[#params + 1] = "...: " .. show(rest, names, false)
  end
  local text = header .. "(" .. table.concat(params, ", ") .. ")" .. show_rets(f, names)
  if generic then
    names.binders[#names.binders] = nil
  end
  return text
end

--- `t` in the grammar's spelling. `parenthesized` is true where a union or a function type would
--- take the text beside it for its own: as a member of a union and under `?`.
show = function(t: Type, names: Names, parenthesized: boolean): string
  names.budget = names.budget - 1
  if names.budget < 0 then
    return "..."
  end
  if t is Atom then
    return t.tag
  elseif t is Named then
    -- TODO: write the module before the name where two types in scope share it, once the
    -- checker's errors say what is in scope (doc/plans/new-checker-types.md, "errors").
    local text = t.decl.name
    if #t.args > 0 then
      text = text .. "<" .. table.concat(show_list(t.args, names), ", ") .. ">"
    end
    if t.value then
      text = text .. " (declaration)"
    end
    return text
  elseif t is Array then
    return (t.mut and "mut " or "") .. "{" .. show(t.element, names, false) .. "}"
  elseif t is Map then
    -- A function type as a key is parenthesized: its returns would take the `:` for their own.
    local key = t.key
    return (t.mut and "mut " or "") .. "{" .. show(key, names, key is Fn) .. ": " .. show(t.value, names, false) .. "}"
  elseif t is Union then
    local u: Union = t
    if u.nilable then
      if #u.members == 1 then
        return show(u.members[1], names, true) .. "?"
      end
      return "(" .. show_members(u, names) .. ")?"
    end
    local text = show_members(u, names)
    return parenthesized and "(" .. text .. ")" or text
  elseif t is Var then
    local binder = names.binders[#names.binders - t.depth]
    local name = binder ~= nil and binder[t.index + 1] or nil
    return name or "?" .. t.depth .. "." .. t.index
  elseif t is Fn then
    local text = show_fn(t, names)
    return parenthesized and "(" .. text .. ")" or text
  end
  return ""
end

function Types.display(t: Type, binders?: {{string}}): string
  local names: Names = { binders = {}, budget = DISPLAY_BUDGET, root = t }
  for i, b in ipairs(binders or {}) do
    names.binders[i] = b
  end
  return show(t, names, false)
end

-- The store -------------------------------------------------------------------

local function owned(store: Store, t: Type)
  if t.owner ~= store.owner then
    error("types: a type of another store, or one that a refused decode took back", 3)
  end
end

--- Sets the flags of `t` from the types it is made of: how many binders outside it its variables
--- reach, whether a view of it differs, how many types its text has and how deeply it nests.
local function measure(t: Type)
  local open, changes, weight, height = 0, false, 1, 0
  for _, part in ipairs(parts_of(t)) do
    open = math.max(open, part.open)
    changes = changes or part.has_mut
    weight = math.min(WEIGHT_CAP, weight + part.weight)
    height = math.max(height, part.height)
  end
  if t is Var then
    open = t.depth + 1
  elseif t is Array then
    changes = changes or t.mut
  elseif t is Map then
    changes = changes or t.mut
  elseif t is Fn then
    -- The function's own variables are bound by it.
    open = #t.tparams > 0 and math.max(0, open - 1) or open
  end
  -- A view does not reach through a named type or a function.
  t.open = open
  t.has_mut = changes and not (t is Named or t is Fn)
  t.weight = weight
  t.height = height + 1
end

--- The one type of a store with the parts of `candidate`: `candidate` itself, numbered, if it is
--- new.
local function intern(store: Store, candidate: Type): Type
  local key = render(candidate, id_text)
  local found = store.interned[key]
  if found ~= nil then
    return found
  end
  measure(candidate)
  if candidate.height > MAX_DEPTH then
    -- [`lang.declarations`] makes `invalid` of a type that would nest this deep before it asks.
    error("types: a type nested deeper than " .. MAX_DEPTH, 3)
  end
  store.count = store.count + 1
  candidate.id = store.count
  store.types[store.count] = candidate
  store.interned[key] = candidate
  return candidate
end

local function atom_of(store: Store, name: Tag): Type
  local found = store.atoms[name]
  if found == nil then
    error("types: no atom named " .. tostring(name), 2)
  end
  return found
end

local record Gathered
  members: {Type}
  seen: {integer: boolean}
  nilable: boolean
  any: boolean
  invalid: boolean
end

--- Adds `m`, or the members of the union it is, to what a union gathers.
local function gather(g: Gathered, m: Type)
  if m is Union then
    for _, inner in ipairs(m.members) do
      gather(g, inner)
    end
    if m.nilable then
      g.nilable = true
    end
  elseif m is Atom and (m.tag == "nil" or m.tag == "any" or m.tag == "invalid" or m.tag == "never") then
    local tag = m.tag
    if tag == "nil" then
      g.nilable = true
    elseif tag == "any" then
      g.any = true
    elseif tag == "invalid" then
      g.invalid = true
    end
  elseif not g.seen[m.id] then
    g.seen[m.id] = true
    g.members[#g.members + 1] = m
  end
end

local function by_digest(a: Type, b: Type): boolean
  return digest_text(a) < digest_text(b)
end

local function union_of(store: Store, members: {Type}): Type
  local g: Gathered = { members = {}, seen = {}, nilable = false, any = false, invalid = false }
  for _, m in ipairs(members) do
    owned(store, m)
    gather(g, m)
  end
  if g.invalid then
    return store.invalid
  end
  if g.any then
    return store.any
  end
  local seen = g.seen
  local yes, no = store.atoms["true"], store.atoms["false"]
  if seen[yes.id] and seen[no.id] and not seen[store.boolean.id] then
    seen[store.boolean.id] = true
    g.members[#g.members + 1] = store.boolean
  end
  local has_number, has_string, has_boolean = seen[store.number.id], seen[store.string.id], seen[store.boolean.id]
  local kept: {Type} = {}
  for _, m in ipairs(g.members) do
    local covered = false
    if has_number and m.id == store.integer.id then
      covered = true
    elseif has_boolean and (m.id == yes.id or m.id == no.id) then
      covered = true
    elseif has_string and m is Named then
      covered = m.decl.kind == "enum"
    end
    if not covered then
      kept[#kept + 1] = m
    end
  end
  if #kept == 0 then
    return g.nilable and store.atoms["nil"] or store.never
  end
  if #kept == 1 and not g.nilable then
    return kept[1]
  end
  table.sort(kept, by_digest)
  local union: Union = {
    tag = "union", atom = false, id = 0, owner = store.owner, digest = "", open = 0, has_mut = false,
    weight = 1, height = 1,
    members = kept, nilable = g.nilable,
  }
  return intern(store, union)
end

--- The key of a path in the store's tables: the length of the module before the module, so that
--- no module and name make the key of another pair.
local function path_key(module: string, name: string): string
  return #module .. ":" .. module .. name
end

--- Why a variable that `t` holds at `level` binders inside it, which is bound by the binder of
--- `count` parameters just outside, has no parameter, or "". `seen` holds what was visited.
local function unbound(t: Type, level: integer, count: integer, seen: {string: boolean}): string
  if t.open <= level then
    return ""
  end
  local mark = t.id .. ":" .. level
  if seen[mark] then
    return ""
  end
  seen[mark] = true
  if t is Var then
    if t.depth == level and t.index >= count then
      return "the variable " .. t.depth .. " " .. t.index .. " names a type parameter its binder lacks, which has " .. count
    end
    return ""
  end
  local inside = level + ((t is Fn and #t.tparams > 0) and 1 or 0)
  for _, part in ipairs(parts_of(t)) do
    local why = unbound(part, inside, count, seen)
    if why ~= "" then
      return why
    end
  end
  return ""
end

--- Raises where `t` is not what a type parameter is bounded by: a named interface used with no
--- arguments.
local function bound_ok(store: Store, bound: Type)
  owned(store, bound)
  if not (bound is Named) or bound.decl.kind ~= "interface" or #bound.args > 0 then
    error("types: a type parameter is bounded by an interface and no arguments, not " .. Types.display(bound), 3)
  end
end

Types.Store.atom = function(self: Store, name: Tag): Type
  return atom_of(self, name)
end

Types.Store.array = function(self: Store, element: Type, mutable?: boolean): Type
  owned(self, element)
  local array: Array = {
    tag = "array", atom = false, id = 0, owner = self.owner, digest = "", open = 0, has_mut = false,
    weight = 1, height = 1,
    element = element, mut = mutable or false,
  }
  return intern(self, array)
end

Types.Store.map = function(self: Store, key: Type, value: Type, mutable?: boolean): Type
  owned(self, key)
  owned(self, value)
  local map: Map = {
    tag = "map", atom = false, id = 0, owner = self.owner, digest = "", open = 0, has_mut = false,
    weight = 1, height = 1,
    key = key, value = value, mut = mutable or false,
  }
  return intern(self, map)
end

Types.Store.union = function(self: Store, members: {Type}): Type
  return union_of(self, members)
end

Types.Store.optional = function(self: Store, t: Type): Type
  owned(self, t)
  if t is Union and t.nilable then
    return t
  end
  return union_of(self, { t, self.atoms["nil"] })
end

Types.Store.non_nil = function(self: Store, t: Type): Type
  owned(self, t)
  if t is Atom and t.tag == "nil" then
    return self.never
  elseif t is Union and t.nilable then
    return union_of(self, t.members)
  end
  return t
end

Types.Store.var = function(self: Store, depth: integer, index: integer): Type
  if math.type(depth) ~= "integer" or math.type(index) ~= "integer" or depth < 0 or index < 0 then
    error("types: a variable has a depth and an index of 0 or more", 2)
  end
  local var: Var = {
    tag = "var", atom = false, id = 0, owner = self.owner, digest = "", open = 0, has_mut = false,
    weight = 1, height = 1,
    depth = depth, index = index,
  }
  return intern(self, var)
end

Types.Store.named = function(self: Store, decl: Decl, args?: {Type}, value?: boolean): Type
  if decl.owner ~= self.owner then
    error("types: a declaration of another store", 2)
  end
  local copied: {Type} = {}
  for i, a in ipairs(args or {}) do
    owned(self, a)
    copied[i] = a
  end
  local arity = decl.arity
  if arity ~= nil and arity ~= #copied then
    error("types: " .. decl.name .. " takes " .. arity .. " type arguments, not " .. #copied, 2)
  end
  local named: Named = {
    tag = "named", atom = false, id = 0, owner = self.owner, digest = "", open = 0, has_mut = false,
    weight = 1, height = 1,
    decl = decl, args = copied, value = value or false,
  }
  local made = intern(self, named)
  if arity == nil and made == named then
    -- Checked when the declaration says how many it takes.
    local key = path_key(decl.module, decl.name)
    local uses = self.pending[key] or {}
    uses[#uses + 1] = named
    self.pending[key] = uses
    if self.transactions > 0 then
      self.journal[#self.journal + 1] = { what = "use", key = key }
    end
  end
  return made
end

--- The alternative as the store keeps it, or nil where it has a `never` in it and is no list.
local function normal_alt(store: Store, alt: Alt): Alt | nil
  local narrows = alt.narrows
  if narrows ~= nil then
    owned(store, narrows.to)
    if narrows.param < 1 then
      error("types: a narrowing declaration names a parameter from 1", 3)
    end
    local items: {Type} = {}
    if not narrows.asserts then
      items[1] = store.boolean
    end
    return { items = items, narrows = { param = narrows.param, to = narrows.to, asserts = narrows.asserts } }
  end
  local items: {Type} = {}
  for i, item in ipairs(alt.items) do
    owned(store, item)
    if item.tag == "never" then
      return nil
    end
    items[i] = item
  end
  local tail = alt.tail
  if tail ~= nil then
    owned(store, tail)
    if tail.tag == "never" then
      tail = nil
    end
  end
  return { items = items, tail = tail }
end

local record Keyed
  text: string
  alt: Alt
end

Types.Store.fn = function(self: Store, spec: FnSpec): Type
  local tparams: {TParam} = {}
  for i, tp in ipairs(spec.tparams or {}) do
    local bound = tp.bound
    if bound ~= nil then
      bound_ok(self, bound)
    end
    tparams[i] = { bound = bound }
  end
  local params: {Param} = {}
  for i, p in ipairs(spec.params or {}) do
    owned(self, p.type)
    local omittable = p.omittable or false
    params[i] = { type = omittable and self:optional(p.type) or p.type, omittable = omittable }
  end
  local rest = spec.rest
  if rest ~= nil then
    owned(self, rest)
  end
  local keyed: {Keyed} = {}
  local given: {Alt} = spec.rets or { { items = {} } }
  for _, alt in ipairs(given) do
    local narrows = alt.narrows
    if narrows ~= nil and #given > 1 then
      error("types: a narrowing declaration is the whole return list", 2)
    end
    if narrows ~= nil and narrows.param > #params then
      error("types: a narrowing declaration names parameter " .. narrows.param .. " of " .. #params, 2)
    end
    local normal = normal_alt(self, alt)
    if normal ~= nil then
      keyed[#keyed + 1] = { text = render_alt(normal, digest_text), alt = normal }
    end
  end
  table.sort(keyed, function(a: Keyed, b: Keyed): boolean
    return a.text < b.text
  end)
  local rets: {Alt} = {}
  local previous = ""
  for _, entry in ipairs(keyed) do
    if #rets == 0 or entry.text ~= previous then
      rets[#rets + 1] = entry.alt
      previous = entry.text
    end
  end
  local f: Fn = {
    tag = "fn", atom = false, id = 0, owner = self.owner, digest = "", open = 0, has_mut = false,
    weight = 1, height = 1,
    tparams = tparams, params = params, rest = rest, rets = rets,
  }
  if #tparams > 0 then
    -- Its own variables, which may be anywhere in it, name a parameter it has.
    local seen: {string: boolean} = {}
    for _, part in ipairs(parts_of(f)) do
      local why = unbound(part, 0, #tparams, seen)
      if why ~= "" then
        error("types: " .. why, 2)
      end
    end
  end
  return intern(self, f)
end

Types.Store.size = function(self: Store): integer
  return self.count
end

-- Declarations ------------------------------------------------------------------

--- Whether `s` is a name as the lexer reads one.
local function is_name(s: string): boolean
  return s:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

--- Whether `s` can name a declaration or a type parameter: a name the lexer does not reserve.
local function is_binding_name(s: string): boolean
  return is_name(s) and not Lexer.reserved[s]
end

local function declaration_name(module: string, names: {string}): string
  if module == "" or utf8.len(module) == nil then
    error("types: a declaration is in a module whose name is UTF-8 and not empty", 3)
  end
  if #names == 0 then
    error("types: a declaration has a name", 3)
  end
  if #names == 1 and PRIMITIVE_NAMES[names[1]] then
    error("types: " .. names[1] .. " is a primitive type, which no declaration takes", 3)
  end
  for _, n in ipairs(names) do
    if not is_binding_name(n) then
      error("types: a declaration's name is a name the lexer reads and does not reserve, not " .. string.format("%q", n), 3)
    end
  end
  return table.concat(names, ".")
end

--- Notes what `decl` is before a decode changes it, so that a failed decode can take it back.
local function note(store: Store, decl: Decl)
  if store.transactions > 0 then
    store.journal[#store.journal + 1] = { what = "decl", decl = decl, arity = decl.arity }
  end
end

--- Records on `decl` how many type arguments a use takes.
local function set_arity(store: Store, decl: Decl, arity: integer)
  local held = decl.arity
  if held == arity then
    return
  end
  if held ~= nil then
    error("types: " .. decl.name .. " takes " .. held .. " type arguments, not " .. arity, 3)
  end
  for _, use in ipairs(store.pending[path_key(decl.module, decl.name)] or {}) do
    if #use.args ~= arity then
      error("types: " .. decl.name .. " takes " .. arity .. " type arguments, not " .. #use.args, 3)
    end
  end
  note(store, decl)
  decl.arity = arity
end

Types.Store.declare = function(self: Store, kind: Types.DeclKind, module: string, names: {string}, arity?: integer): Decl
  if arity ~= nil and (math.type(arity) ~= "integer" or arity < 0) then
    error("types: a declaration takes a count of type arguments of 0 or more", 2)
  end
  local name = declaration_name(module, names)
  local key = path_key(module, name)
  local found = self.declared[key]
  if found ~= nil then
    if found.kind ~= kind then
      error("types: " .. module .. " " .. name .. " is declared as a " .. found.kind .. ", not a " .. kind, 2)
    end
    if arity ~= nil then
      set_arity(self, found, arity)
    end
    return found
  end
  local copied: {string} = {}
  for i, n in ipairs(names) do
    copied[i] = n
  end
  local decl: Decl = {
    kind = kind, module = module, names = copied, name = name, owner = self.owner,
    text = quote(module) .. " " .. quote(name), arity = arity,
  }
  self.declared[key] = decl
  self.list[#self.list + 1] = decl
  return decl
end

Types.Store.find = function(self: Store, module: string, name: string): Decl | nil
  return self.declared[path_key(module, name)]
end

Types.Store.declarations = function(self: Store): {Decl}
  local out: {Decl} = {}
  for i, d in ipairs(self.list) do
    out[i] = d
  end
  return out
end

function Types.listing_cycle(decl: Decl, supers: {Type}): Decl | nil
  local seen: {Decl: boolean} = {}
  local stack: {Decl} = {}
  for _, super in ipairs(supers) do
    if super is Named then
      stack[#stack + 1] = super.decl
    end
  end
  while #stack > 0 do
    local d = stack[#stack]
    stack[#stack] = nil
    if d == decl then
      return decl
    end
    local body = d.body
    if not seen[d] and body ~= nil then
      seen[d] = true
      for _, super in ipairs(body.supers) do
        if super is Named then
          if super.decl == decl then
            return d
          end
          stack[#stack + 1] = super.decl
        end
      end
    end
  end
  return nil
end

--- `body` as the store keeps it: copied, with an omittable field typed `T?`. Raises where it does
--- not suit `decl`, or lists `decl` itself.
local function normal_body(store: Store, decl: Decl, body: Body): Body
  local is_enum = decl.kind == "enum"
  if is_enum and (#body.tparams > 0 or #body.supers > 0 or #body.fields > 0 or #body.methods > 0 or
      body.array ~= nil) then
    error("types: an enum holds values and nothing else", 3)
  end
  if not is_enum and #body.values > 0 then
    error("types: only an enum holds values", 3)
  end
  local made: Body = { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} }
  local roots: {Type} = {}
  for i, tp in ipairs(body.tparams) do
    local bound = tp.bound
    if bound ~= nil then
      bound_ok(store, bound)
      roots[#roots + 1] = bound
    end
    if not is_binding_name(tp.name) then
      error("types: a type parameter's name is a name the lexer reads and does not reserve, not " ..
          string.format("%q", tp.name), 3)
    end
    made.tparams[i] = { name = tp.name, bound = bound }
  end
  for i, super in ipairs(body.supers) do
    owned(store, super)
    if super.tag ~= "named" then
      error("types: a declaration lists named types after `is`", 3)
    end
    made.supers[i] = super
    roots[#roots + 1] = super
  end
  local through = Types.listing_cycle(decl, made.supers)
  if through ~= nil then
    error("types: " .. decl.name .. " lists itself" ..
        (through ~= decl and ", through " .. through.name or ""), 3)
  end
  for i, field in ipairs(body.fields) do
    owned(store, field.type)
    local omittable = field.omittable or false
    local t = omittable and store:optional(field.type) or field.type
    made.fields[i] = { name = field.name, type = t, mut = field.mut or false, omittable = omittable }
    roots[#roots + 1] = t
  end
  local array = body.array
  if array ~= nil then
    owned(store, array)
    made.array = array
    roots[#roots + 1] = array
  end
  for i, method in ipairs(body.methods) do
    owned(store, method.type)
    if method.type.tag ~= "fn" then
      error("types: a method is a function", 3)
    end
    if not is_name(method.name) then
      error("types: a method's name is a name the lexer reads, not " .. string.format("%q", method.name), 3)
    end
    made.methods[i] = { name = method.name, type = method.type }
    roots[#roots + 1] = method.type
  end
  local seen: {string: boolean} = {}
  for i, v in ipairs(body.values) do
    if seen[v] then
      error("types: the enum " .. decl.name .. " lists " .. v .. " twice", 3)
    end
    seen[v] = true
    made.values[i] = v
  end
  -- The only binder a variable of the body may name is the declaration's own.
  local checked: {string: boolean} = {}
  for _, root in ipairs(roots) do
    if root.open > 1 then
      error("types: " .. Types.display(root) .. " in " .. decl.name .. " names a variable of no binder", 3)
    end
    local why = unbound(root, 0, #made.tparams, checked)
    if why ~= "" then
      error("types: " .. why .. " in " .. decl.name, 3)
    end
  end
  return made
end

--- Gives `decl`, which has no body, the `body`, after checking the uses made of the declaration
--- before it knew its parameters.
local function give_body(store: Store, decl: Decl, body: Body)
  local held = decl.arity
  if held ~= nil and held ~= #body.tparams then
    error("types: " .. decl.name .. " takes " .. held .. " type arguments, not " .. #body.tparams, 3)
  end
  local key = path_key(decl.module, decl.name)
  for _, use in ipairs(store.pending[key] or {}) do
    if #use.args ~= #body.tparams then
      error("types: " .. decl.name .. " takes " .. #body.tparams .. " type arguments, not " .. #use.args, 3)
    end
  end
  local settled = store.pending[key]
  if settled ~= nil then
    store.pending[key] = nil
    if store.transactions > 0 then
      store.journal[#store.journal + 1] = { what = "pending", key = key, list = settled }
    end
  end
  note(store, decl)
  decl.arity = #body.tparams
  decl.body = body
end

Types.Store.define = function(self: Store, decl: Decl, body: Body): Decl
  if decl.owner ~= self.owner then
    error("types: a declaration of another store", 2)
  end
  if decl.body ~= nil then
    error("types: " .. decl.name .. " has a body already", 2)
  end
  give_body(self, decl, normal_body(self, decl, body))
  return decl
end

-- Declaration text -----------------------------------------------------------------

--- `(opt T)` for an omittable slot (a parameter or a field), or `T`.
local function slot_text(type_: Type, omittable: boolean | nil): string
  if omittable then
    return "(opt " .. written(type_) .. ")"
  end
  return written(type_)
end

--- The text of `decl` with the body `body`.
local function declaration_text(decl: Decl, body: Body): string
  local parts: {string} = { "(decl ", decl.kind, " ", decl.text }
  parts[#parts + 1] = " (tparams"
  for _, tp in ipairs(body.tparams) do
    local bound = tp.bound
    parts[#parts + 1] = " (tparam " .. quote(tp.name) .. (bound ~= nil and " " .. written(bound) or "") .. ")"
  end
  parts[#parts + 1] = ") (supers"
  for _, super in ipairs(body.supers) do
    parts[#parts + 1] = " " .. written(super)
  end
  parts[#parts + 1] = ") (fields"
  for _, field in ipairs(body.fields) do
    parts[#parts + 1] = " (field " .. quote(field.name) .. (field.mut and " mut " or " ") ..
      slot_text(field.type, field.omittable) .. ")"
  end
  parts[#parts + 1] = ") (elements"
  local array = body.array
  if array ~= nil then
    parts[#parts + 1] = " " .. written(array)
  end
  parts[#parts + 1] = ") (methods"
  for _, method in ipairs(body.methods) do
    parts[#parts + 1] = " (method " .. quote(method.name) .. " " .. written(method.type) .. ")"
  end
  parts[#parts + 1] = ") (values"
  for _, v in ipairs(body.values) do
    parts[#parts + 1] = " " .. quote(v)
  end
  parts[#parts + 1] = "))"
  return table.concat(parts)
end

function Types.encode_declaration(decl: Decl): string
  local body = decl.body
  if body == nil then
    error("types: " .. decl.name .. " has no body", 2)
  end
  return declaration_text(decl, body)
end

-- Decoding ---------------------------------------------------------------------------

local record Reader
  text: string
  at: integer
  store: Store
end

local function fail(r: Reader, message: string)
  error("types: " .. message .. " (at byte " .. r.at .. ")", 0)
end

local function skip(r: Reader)
  r.at = r.text:find("%S", r.at) or #r.text + 1
end

--- What comes next: "(", ")", a quote, "a" for an atom or "" at the end.
local function peek(r: Reader): string
  skip(r)
  local c = r.text:sub(r.at, r.at)
  if c == "(" or c == ")" or c == '"' or c == "" then
    return c
  end
  return "a"
end

local function open(r: Reader)
  if peek(r) ~= "(" then
    fail(r, "a ( was expected")
  end
  r.at = r.at + 1
end

local function close(r: Reader)
  if peek(r) ~= ")" then
    fail(r, "a ) was expected")
  end
  r.at = r.at + 1
end

local function atom(r: Reader): string
  skip(r)
  local word = r.text:match("^[%w_%.]+", r.at)
  if word == nil then
    fail(r, "a word was expected")
  end
  r.at = r.at + #word
  return word
end

local function integer(r: Reader): integer
  local word = atom(r)
  local n = word:match("^%d+$") ~= nil and #word < 10 and math.tointeger(tonumber(word)) or nil
  if n == nil then
    fail(r, "a number was expected, not " .. word)
  end
  return n
end

local function string_of(r: Reader): string
  if peek(r) ~= '"' then
    fail(r, "a string was expected")
  end
  local text = r.text
  local out: {string} = {}
  local from = r.at + 1
  while true do
    local stop = text:find('["\\]', from)
    if stop == nil then
      fail(r, "a string is never closed")
    end
    out[#out + 1] = text:sub(from, stop - 1)
    if text:sub(stop, stop) == '"' then
      r.at = stop + 1
      return table.concat(out)
    end
    local digits = text:match("^%d%d%d", stop + 1)
    local byte = digits ~= nil and math.tointeger(tonumber(digits)) or nil
    if byte == nil or byte > 255 then
      fail(r, "a string has a bad escape")
    end
    out[#out + 1] = string.char(byte)
    from = stop + 4
  end
end

--- The word after the `(` that is next, or "" where the next is not a `(`, without reading it.
local function head(r: Reader): string
  skip(r)
  return r.text:match("^%(%s*([%w_%.]+)", r.at) or ""
end

local function expect(r: Reader, word: string)
  open(r)
  local found = atom(r)
  if found ~= word then
    fail(r, "(" .. word .. " was expected, not (" .. found)
  end
end

local read_type: function(r: Reader): Type
local read_declaration: function(store: Store, text: string, module: string | nil, name: string | nil): Decl

--- One more level of nesting, which fails where there are too many.
local function descend(r: Reader)
  local store = r.store
  store.depth = store.depth + 1
  if store.depth > MAX_DEPTH then
    fail(r, "text nests deeper than " .. MAX_DEPTH)
  end
end

--- The declaration at a path: the store's, or the loader's.
local function resolve(r: Reader, module: string, name: string): Decl
  local store = r.store
  local found = store:find(module, name)
  if found ~= nil then
    -- One that is not being read has a body: a bodiless one was declared and never defined.
    if found.body == nil and not store.building[path_key(module, name)] then
      fail(r, "the declaration " .. module .. " " .. name .. " has no body")
    end
    return found
  end
  local loader = store.loader
  if loader ~= nil then
    local text = loader(module, name)
    if text ~= nil then
      return read_declaration(store, text, module, name)
    end
  end
  return fail(r, "there is no declaration " .. module .. " " .. name)
end

--- A parameter or field type, which `(opt T)` marks omittable.
local function read_slot(r: Reader): Type, boolean
  if head(r) == "opt" then
    expect(r, "opt")
    local t = read_type(r)
    close(r)
    return t, true
  end
  return read_type(r), false
end

local function read_types(r: Reader): {Type}
  local out: {Type} = {}
  while peek(r) ~= ")" do
    out[#out + 1] = read_type(r)
  end
  return out
end

local function read_alt(r: Reader): Alt
  open(r)
  local items: {Type} = {}
  local tail: Type | nil
  local narrows: Types.Narrows | nil
  while peek(r) ~= ")" do
    local word = head(r)
    if word == "..." then
      expect(r, "...")
      tail = read_type(r)
      close(r)
    elseif word == "is" or word == "asserts" then
      expect(r, word)
      local param = integer(r)
      narrows = { param = param, to = read_type(r), asserts = word == "asserts" }
      close(r)
    else
      items[#items + 1] = read_type(r)
    end
  end
  close(r)
  return { items = items, tail = tail, narrows = narrows }
end

local function read_fn(r: Reader): Type
  expect(r, "tp")
  local tparams: {TParam} = {}
  while peek(r) ~= ")" do
    skip(r)
    if r.text:match("^_%f[^%w_%.]", r.at) ~= nil then
      atom(r)
      tparams[#tparams + 1] = {}
    else
      tparams[#tparams + 1] = { bound = read_type(r) }
    end
  end
  close(r)
  open(r)
  local params: {Param} = {}
  local rest: Type | nil
  while peek(r) ~= ")" do
    if head(r) == "rest" then
      expect(r, "rest")
      rest = read_type(r)
      close(r)
    else
      local t, omittable = read_slot(r)
      params[#params + 1] = { type = t, omittable = omittable }
    end
  end
  close(r)
  expect(r, "rets")
  local rets: {Alt} = {}
  while peek(r) ~= ")" do
    rets[#rets + 1] = read_alt(r)
  end
  close(r)
  return r.store:fn({ tparams = tparams, params = params, rest = rest, rets = rets })
end

read_type = function(r: Reader): Type
  descend(r)
  local store = r.store
  local result: Type = store.invalid
  local c = peek(r)
  if c == "a" then
    local word = atom(r)
    local found = store.atoms[word]
    if found == nil then
      fail(r, "there is no type " .. word)
    end
    result = found
  elseif c == "(" then
    open(r)
    local word = atom(r)
    if word == "array" or word == "marray" then
      result = store:array(read_type(r), word == "marray")
    elseif word == "map" or word == "mmap" then
      local key = read_type(r)
      result = store:map(key, read_type(r), word == "mmap")
    elseif word == "union" then
      result = store:union(read_types(r))
    elseif word == "ref" or word == "val" then
      local module = string_of(r)
      local name = string_of(r)
      local decl = resolve(r, module, name)
      result = store:named(decl, read_types(r), word == "val")
    elseif word == "var" then
      local depth = integer(r)
      result = store:var(depth, integer(r))
    elseif word == "fn" then
      result = read_fn(r)
    else
      fail(r, "there is no form " .. word)
    end
    close(r)
  else
    fail(r, "a type was expected")
  end
  store.depth = store.depth - 1
  return result
end

local function read_field_names(name: string): {string}
  local names: {string} = {}
  for part in (name .. "."):gmatch("([^.]*)%.") do
    names[#names + 1] = part
  end
  return names
end

--- Fails unless `r`'s text is UTF-8, which the text of every module and name is.
local function check_utf8(r: Reader)
  if utf8.len(r.text) == nil then
    fail(r, "text is not UTF-8")
  end
end

--- The body of a declaration `r` reads, whose `(decl`, kind, path and `(tparams` are read.
local function read_body(r: Reader, decl: Decl): Body
  local store = r.store
  local body: Body = { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} }
  while peek(r) ~= ")" do
    expect(r, "tparam")
    local param: DeclParam = { name = string_of(r) }
    if peek(r) ~= ")" then
      param.bound = read_type(r)
    end
    close(r)
    body.tparams[#body.tparams + 1] = param
  end
  close(r)
  -- Known before anything else in the body, which may use the declaration.
  store:declare(decl.kind, decl.module, decl.names, #body.tparams)
  expect(r, "supers")
  body.supers = read_types(r)
  close(r)
  expect(r, "fields")
  while peek(r) ~= ")" do
    expect(r, "field")
    local field_name = string_of(r)
    local mutable = false
    skip(r)
    if r.text:match("^mut%f[^%w_%.]", r.at) ~= nil then
      atom(r)
      mutable = true
    end
    local t, omittable = read_slot(r)
    close(r)
    body.fields[#body.fields + 1] = { name = field_name, type = t, mut = mutable, omittable = omittable }
  end
  close(r)
  expect(r, "elements")
  if peek(r) ~= ")" then
    body.array = read_type(r)
  end
  close(r)
  expect(r, "methods")
  while peek(r) ~= ")" do
    expect(r, "method")
    local method_name = string_of(r)
    body.methods[#body.methods + 1] = { name = method_name, type = read_type(r) }
    close(r)
  end
  close(r)
  expect(r, "values")
  while peek(r) ~= ")" do
    body.values[#body.values + 1] = string_of(r)
  end
  close(r)
  return body
end

--- Reads the declaration `text` spells, which has the path `module` and `name` where they are
--- given, and defines it, or checks that the store defines it so.
read_declaration = function(store: Store, text: string, module: string | nil, name: string | nil): Decl
  local r: Reader = { text = text, at = 1, store = store }
  check_utf8(r)
  descend(r)
  expect(r, "decl")
  local kind = atom(r)
  local decl_kind = DECL_KINDS[kind]
  if decl_kind == nil then
    fail(r, "there is no declaration kind " .. kind)
    return store:declare("record", "m", { "x" })
  end
  local path_module = string_of(r)
  local path_name = string_of(r)
  if (module ~= nil and module ~= path_module) or (name ~= nil and name ~= path_name) then
    fail(r, "the declaration " .. path_module .. " " .. path_name .. " answers for " .. tostring(module) .. " " .. tostring(name))
  end
  local decl = store:declare(decl_kind, path_module, read_field_names(path_name))
  local key = path_key(path_module, path_name)
  local first = not store.building[key]
  if first then
    store.building[key] = true
    store.building_order[#store.building_order + 1] = key
  end
  expect(r, "tparams")
  local body = read_body(r, decl)
  close(r)
  skip(r)
  if r.at <= #text then
    fail(r, "text follows the declaration")
  end
  local made = normal_body(store, decl, body)
  local held = decl.body
  if held ~= nil then
    if declaration_text(decl, made) ~= declaration_text(decl, held) then
      fail(r, "the text differs from the declaration " .. decl.name .. " the store holds")
    end
  else
    give_body(store, decl, made)
  end
  if first then
    store.building[key] = nil
    store.building_order[#store.building_order] = nil
  end
  store.depth = store.depth - 1
  return decl
end

--- What a decode starts from, to return to if it fails.
local record Mark
  count: integer
  decls: integer
  journal: integer
  building: integer
  depth: integer
end

--- Takes back what the decode that began at `mark` added to `store`.
local function roll_back(store: Store, mark: Mark)
  for i = #store.journal, mark.journal + 1, -1 do
    local undo = store.journal[i]
    local decl = undo.decl
    local key = undo.key
    if undo.what == "decl" and decl ~= nil then
      decl.body = nil
      decl.arity = undo.arity
    elseif undo.what == "use" and key ~= nil then
      local uses = store.pending[key]
      if uses ~= nil then
        uses[#uses] = nil
        if #uses == 0 then
          store.pending[key] = nil
        end
      end
    elseif undo.what == "pending" and key ~= nil then
      store.pending[key] = undo.list
    end
    store.journal[i] = nil
  end
  -- What is taken back is dead: a loader that kept a type or a declaration made in a refused
  -- decode finds the store refusing it, and not the type that next takes its id.
  for i = #store.list, mark.decls + 1, -1 do
    local decl = store.list[i]
    store.declared[path_key(decl.module, decl.name)] = nil
    decl.owner = 0
    store.list[i] = nil
  end
  for id = store.count, mark.count + 1, -1 do
    local t = store.types[id]
    store.interned[render(t, id_text)] = nil
    t.owner = 0
    store.types[id] = nil
  end
  store.count = mark.count
  for i = #store.building_order, mark.building + 1, -1 do
    store.building[store.building_order[i]] = nil
    store.building_order[i] = nil
  end
  store.depth = mark.depth
end

--- Runs `work`, which raises to refuse, and answers "" or the refusal, which begins `types:`; a
--- refusal leaves the store as it was.
local function attempt(store: Store, work: function()): string
  local mark: Mark = {
    count = store.count, decls = #store.list, journal = #store.journal, building = #store.building_order,
    depth = store.depth,
  }
  store.transactions = store.transactions + 1
  local ok, why = pcall(function()
    work()
  end)
  store.transactions = store.transactions - 1
  if ok then
    if store.transactions == 0 then
      store.journal = {}
    end
    return ""
  end
  roll_back(store, mark)
  local message = tostring(why)
  local at = message:find("types: ", 1, true)
  if at == nil then
    return "types: " .. message
  end
  return message:sub(at)
end

Types.Store.decode = function(self: Store, text: string): Type | nil, string
  local r: Reader = { text = text, at = 1, store = self }
  local read: {Type} = {}
  local why = attempt(self, function()
    check_utf8(r)
    read[1] = read_type(r)
    skip(r)
    if r.at <= #text then
      fail(r, "text follows the type")
    end
  end)
  if why == "" then
    return read[1], ""
  end
  return nil, why
end

Types.Store.decode_declaration = function(self: Store, text: string): Decl | nil, string
  local read: {Decl} = {}
  local why = attempt(self, function()
    read[1] = read_declaration(self, text, nil, nil)
  end)
  if why == "" then
    return read[1], ""
  end
  return nil, why
end

-- The store ---------------------------------------------------------------------------

local store_mt: metatable<Store> = { __index = Types.Store }

function Types.new(loader?: Loader): Store
  counter.stores = counter.stores + 1
  local atoms: {string: Type} = {}
  local interned: {string: Type} = {}
  local types: {Type} = {}
  for i, name in ipairs(ATOMS) do
    local made: Atom = {
      tag = name, atom = true, id = i, owner = counter.stores, digest = "", open = 0, has_mut = false,
      weight = 1, height = 1,
    }
    atoms[name] = made
    interned[name] = made
    types[i] = made
  end
  local store: Store = setmetatable({
    owner = counter.stores, count = #ATOMS, types = types, interned = interned, declared = {}, list = {},
    atoms = atoms, loader = loader, pending = {}, journal = {}, building = {}, building_order = {}, depth = 0,
    transactions = 0,
    integer = atoms["integer"], number = atoms["number"], string = atoms["string"], boolean = atoms["boolean"],
    never = atoms["never"], any = atoms["any"], invalid = atoms["invalid"],
  }, store_mt)
  return store
end

return Types
