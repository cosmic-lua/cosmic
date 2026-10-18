--- The lowering of the new checker's declarations and annotations
--- ([`doc/plans/new-checker-types.md`], "declarations" and "the order the pieces land in"):
--- every type declaration of a module (record, class, interface, enum, userdata and alias) and every
--- type written in it (`local x: T`, a parameter, a return, an `is` test, a field) becomes a type of a
--- [`lang.types`] store, once [`lang.scopes`] has resolved the names.
---
--- A [`Declarations.Program`] holds the store, the judge of [`lang.relation`] and what every module
--- lowered into them. [`Declarations.Program.lower`] lowers one module: it declares its declarations
--- ([`Types.Store.declare`], the arity from the syntax, so a use may come before the declaration),
--- walks the tree lowering each annotation with the type parameters in scope, gives each declaration
--- its body ([`Types.Store.define`]), and then runs the checks that need every body. A module that
--- imports types (`local type Stream = require("cosmic.stream")`) finds them in the program: lower
--- the module that declares them first, or give the program a `provider` that declares a module
--- on demand ([`Declarations.Program.provider`]).
---
--- **What it refuses**, each with an error that has a code, the place, what is wrong and a fix in the
--- program's own names ([`Declarations.catalog`] holds the rule behind each code):
---
--- - agreement: a type that lists an interface has every field of it and of every interface it
---   extends, of exactly the interface's type (the receiver, the first parameter that is the
---   interface itself, is the implementing type's own) and `mut` and omittable where the interface
---   is: `interface_disagrees`. What it lists is an interface, and no declaration lists itself, even
---   through the declarations it lists: `super_not_interface`, `super_cycle`, `listing_too_large`.
--- - tags: a union with two records or more is legal only if each has one shared fixed field typed
---   by a single-member enum, and no two have the same value: `untagged_union`.
--- - dense arrays: `{T?}`, `{K: V?}` and an instance that makes one (`List<string?>` for `record
---   List<T>` that holds a `{T}`): `array_of_optional`.
--- - keys: a map's key is `integer`, `string`, `boolean`, an enum or a record, class, interface or
---   userdata, never `number` (`float_key`), `any`, an optional or a union (`key_type`).
--- - distinct names: a field or a method of the name another has, apart from the overloads of a
---   declaration file, and an enum value written twice: `repeated_field`, `repeated_value`. A class
---   holds its fields, its methods and its functions (`function C.m(...)`) in one namespace, since the
---   table of its methods is the metatable of its values.
--- - optional fields: a field that may be nil is a plain value of one type, never a metamethod (`optional_metamethod`)
---   and never a generic function (`optional_generic`).
--- - classes: a method named for a metamethod, other than `__close` (which takes the value alone) and
---   `__tostring` (which also answers a `string`), and a function of a class with such a name:
---   `class_metamethod`, `metamethod_signature`.
--- - the form of a type: the count of type arguments (`type_arguments`), a type that nests deeper
---   than a store allows (`type_too_deep`), an alias that reaches itself (`alias_cycle`), a bound that
---   is no interface (`bound_not_interface`), return lists that no position of `true` and `false` tells apart
---   (`lists_overlap`), a type argument that does not list the interface its parameter is bounded by
---   (`bound_not_met`), a declaration that names the type parameter of
---   the one around it (`outer_type_parameter`), a name that a module or a record does not
---   declare (`member_missing`), a parameter of a method with no type (`param_untyped`) and
---   `thread` (`thread_type`).
---
--- A type that fails to lower is `invalid`, which relates to everything, so a mistake is reported
--- once where it is made. The lowering never raises: what a store refuses that none of these rules
--- caught is `store_refused`, which a property test holds to never happening.
---
--- **Statics.** The functions a module gives a record, class or userdata record with `function R.m(...)`
--- ([`Declarations.Program.statics`]) are members of the declaration used as a value, a type of its own
--- ([`Types.Named`]'s `value`), and of no value of the declaration.
---
--- **Declarations** are paths in the store: the module's name and the names the declaration is nested
--- under. One that is not at the top of its module (in a function's body) is in the module `<name>@<id>`
--- of its node, so that two of one name never meet, and no other module can name it. A repeated top-level
--- name is in such a module too, after the first.
---
--- **Aliases** create no type: a use is the type the alias names, its arguments put in. They are
--- lowered where first used, so one may be declared after its use; a use from another module needs
--- that module lowered.
---
--- **Checks** that read the bodies of other declarations (agreement, tags, instances) wait until every
--- declaration they read is defined, so that a module whose imports cycle is checked once the last of
--- them is lowered.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Relation = require("lang.relation")
local Scopes = require("lang.scopes")
local Types = require("lang.types")

local type Type = Types.Type
local type Named = Types.Named
local type Store = Types.Store
local type Decl = Types.Decl

local record Declarations
  --- What an error is, so that a reader does not parse its `msg`.
  enum Code
    -- a type that lists an interface and does not have a field of it as it declares it
    "interface_disagrees"
    -- a type after `is` that is not an interface
    "super_not_interface"
    -- a declaration that lists itself, directly or through what it lists
    "super_cycle"
    -- a declaration whose listings are more than the judge follows, or nest too deep
    "listing_too_large"
    -- a union of records without a shared single-valued enum field
    "untagged_union"
    -- `{T?}`, `{K: V?}` or an instance that makes one
    "array_of_optional"
    -- a map keyed by `number`
    "float_key"
    -- a map keyed by a type that is no key
    "key_type"
    -- a field or method named twice
    "repeated_field"
    -- an enum value written twice
    "repeated_value"
    -- a count of type arguments that the declaration does not take
    "type_arguments"
    -- a type that nests deeper than a store allows
    "type_too_deep"
    -- an alias that names itself
    "alias_cycle"
    -- a type parameter bounded by what is no interface
    "bound_not_interface"
    -- two return lists that no position of `true` and `false` tells apart
    "lists_overlap"
    -- a type argument that does not list the interface its parameter is bounded by
    "bound_not_met"
    -- a declaration that names a type parameter of the code around it
    "outer_type_parameter"
    -- a type that a module, a record or the declared globals do not have
    "member_missing"
    -- a parameter of a method with no type
    "param_untyped"
    -- a `__close` that takes more than the value, or a `__tostring` that does not answer a string
    "metamethod_signature"
    -- a method or function of a class named for a metamethod other than `__close` and `__tostring`
    "class_metamethod"
    -- a field named for a metamethod that may be nil
    "optional_metamethod"
    -- a field that may be nil and holds a generic function
    "optional_generic"
    -- `thread`
    "thread_type"
    -- a refusal of the store that no rule above foresaw
    "store_refused"
  end

  --- An error: the scope builder's, with the types it is about.
  record Error
    filename: string
    code: Code
    --- What is wrong, in one line.
    msg: string
    --- How to put it right, written against the program's own names.
    fix: string
    y: integer
    x: integer
    offset: integer
    length: integer
    --- The second place the error involves: the first of two names, the declaration of an alias
    --- that names itself.
    other?: Scopes.Place
    --- The types it is about, as the program spells them (`string?`, never `string | nil`).
    types: {string}
  end

  --- The rule behind a code, which `cosmic docs <code>` and the error read alike.
  record Row
    code: Code
    --- The rule, named as the plan names it.
    rule: string
    --- Why the language holds it.
    why: string
    --- What the fix says, with the placeholders `<...>` the error fills from the program.
    fix: string
  end

  --- What a name of a declaration stands for.
  record Entry
    --- The store's declaration, for a record, class, interface, enum or userdata.
    decl?: Decl
    --- An alias, which makes no declaration.
    alias?: AliasInfo
    --- The module the declaration is in, and the names it is nested under, then its own.
    module: string
    names: {string}
  end

  --- An alias `type K<T> = ...`.
  record AliasInfo
    name: string
    module: string
    names: {string}
    --- How many type parameters it takes.
    count: integer
    --- The type it names, the parameters being the variables of one binder, once lowered.
    type?: Type
    tparams: {Types.DeclParam}
    --- "declared": no one lowered it yet, "lowering": it is being lowered, "done", or
    --- "unavailable": it was declared by a module not yet lowered.
    state: string
    --- What its uses must meet ([`Declarations.Program.lower`] computes it when asked).
    requires?: Requires
    node: Ast.TypeAlias | nil
  end

  --- Which type parameters of a declaration or alias have to be dense (not optional) or keys, which are
  --- made optional (`X?`, or the type of a `name?:` field), and which pass themselves on to the parameter of
  --- another declaration.
  record Requires
    dense: {boolean}
    key: {boolean}
    optional: {boolean}
    flows: {Flow}
  end

  record Flow
    --- The declaration that gets the variable `from` of this one as its argument `into`.
    to: Decl
    from: integer
    into: integer
  end

  --- A module to lower.
  record Input
    --- The module's name: the path without `.tl`, `.d.tl` or `/init`, its slashes as dots.
    module: string
    filename: string
    chunk: Ast.Chunk
    scoped: Scopes.Scoped
    dialect: Ast.Dialect
  end

  --- What lowering a module made.
  record Lowered
    module: string
    --- The errors of the module, in source order. Checks that waited for another module are added
    --- by [`Declarations.Program.errors`] when they run.
    errors: {Error}
    --- The declaration of each record, class, interface and enum, by the id of its node.
    decls: {integer: Decl}
    --- The type of each type node, of each parameter's type node, and of each method (its
    --- function type), by id. A node that failed to lower is `invalid`.
    types: {integer: Type}
    --- The type of each alias's name, by the id of its node: what the alias names with its own
    --- variables.
    aliases: {integer: Type}
    --- What the module returns, if it returns a declaration.
    export?: Entry
    --- The declaration or alias each binding that names one stands for, by the id of the binding
    --- ([`Scopes.Var.id`]): what a name used as a value ([`Fs.read`]) stands for.
    entries: {integer: Entry}
  end

  --- A module as the program knows it.
  record Module
    name: string
    export?: Entry
    --- The type of what the module returns when that is no declaration but its type is written: a function with
    --- written parameters (a `local function` or a literal), or a local declared with a type.
    value?: Type
    --- Whether [`Declarations.Program.lower`] ran for it.
    lowered: boolean
    errors: {Error}
  end

  --- A check that waits for the declarations it reads: it answers whether it ran.
  record Waiting
    module: string
    run: function(): boolean
  end

  --- Declares a module the program lacks, with [`Declarations.Program.declare`], and answers whether it did.
  type Provider = function(Program, module: string): boolean

  --- The store and what every module lowered into it.
  record Program
    store: Store
    judge: Relation.Judge
    modules: {string: Module}
    --- The entries of declarations by module and names, and the declared globals by name.
    entries: {string: Entry}
    globals: {string: Entry}
    waiting: {Waiting}
    --- Modules whose types are not written in the program (the bindings of C): a type name of one is
    --- `invalid` and no error.
    --
    -- TODO: declare the generated bindings ([`cosmic.sys`], [`cosmic.internal.process`],
    -- [`cosmic.internal.socket`]) as files of the tree, once the checker reads them from declaration files, and drop this.
    external: {string: boolean}
    --- Asked for a module that a type name imports and the program lacks.
    provider: Provider | nil
    requires: {Decl: Requires}
    --- The types of the values a declaration file declares as globals (`global print <const> = Lib.print`,
    --- `global arg: {string}`), by name: one type, or the overloads of a function in the order they are declared.
    values: {string: {Type}}
    --- The functions its `function R.m(...)` statements gave a declaration, by name: members of the declaration used
    --- as a value (`R.m(...)`), the table of its functions, and of no instance of it ([`Types.Named`]'s `value`).
    --
    -- TODO: write the statics into the row of the declaration, once the rows of the new checker are written: a
    -- module that imports it reads them from the program until then.
    statics: {Decl: {string: Types.Field}}

    --- Makes `name` another name of the module `module`, which the program knows.
    alias: function(Program, name: string, module: string)
    --- Declares the declarations of `input` without lowering their bodies: enough for a module that
    --- imports them to name them. Declares the same again as the same.
    declare: function(Program, input: Input)
    --- Lowers `input`, declaring it first.
    lower: function(Program, input: Input): Lowered
    --- The errors of a module so far, with those of checks that waited.
    errors: function(Program, module: string): {Error}
    --- How many checks still wait for a declaration that no module has defined.
    unsettled: function(Program): integer
    --- The names this program's declaration files declare as globals, as the scope builder wants them.
    scope_globals: function(Program): {string: Scopes.Global}
  end

  --- A program for a new store, or for `store`.
  new: function(store?: Store): Program

  --- The module a file is: its path without `.tl`, `.d.tl` or a trailing `/init`, with dots for slashes.
  module_of: function(path: string): string

  --- Every [`Code`], in the order the enum lists them.
  codes: {Code}

  --- The rule behind each code, in the order of `codes`.
  catalog: {Row}
end

Declarations.codes = {
  "interface_disagrees", "super_not_interface", "super_cycle", "listing_too_large", "untagged_union",
  "array_of_optional", "float_key", "key_type", "repeated_field", "repeated_value", "type_arguments",
  "type_too_deep", "alias_cycle", "bound_not_interface", "lists_overlap", "bound_not_met", "outer_type_parameter", "member_missing",
  "param_untyped", "metamethod_signature", "class_metamethod", "optional_metamethod", "optional_generic", "thread_type",
  "store_refused",
}

Declarations.catalog = {
  {
    code = "interface_disagrees", rule = "interface agreement",
    why = "a type conforms to an interface only by listing it with `is`, and the listing is checked once, where " ..
      "the type is declared: so each field of the interface has to be there, of exactly the interface's type " ..
      "(the receiver of a function field is the implementing type) and `mut` exactly where the interface is, " ..
      "or a value of the type could not stand for the interface",
    fix = "declare <field> in <type> as <interface> declares it: <type of the field>",
  },
  {
    code = "super_not_interface", rule = "only an interface is listed",
    why = "the relation takes a type below a named type of another declaration only if that is an interface it " ..
      "lists, so a record, class or enum after `is` could never be used as what it names",
    fix = "list an interface here, or declare <name> as an interface",
  },
  {
    code = "super_cycle", rule = "a declaration does not list itself",
    why = "the interfaces a type lists are the ones its listings list in turn, so a declaration that lists itself, " ..
      "even through others, has no end to its list",
    fix = "remove <name> from what <declaration> lists",
  },
  {
    code = "listing_too_large", rule = "the listings of a declaration are bounded",
    why = "the interfaces a declaration lists are found by following each listing with its arguments put in, and " ..
      "a ladder of listings with different arguments grows without a limit the judge could follow",
    fix = "list fewer interfaces, or interfaces whose own listings take the same arguments",
  },
  {
    code = "untagged_union", rule = "tagged unions",
    why = "a record is erased, so a union of records is told apart by a field of a type each member has to " ..
      "itself: a fixed field of a single-member enum, with a value no other member has",
    fix = "give <members> a fixed field of an enum of one value each, the same name in all",
  },
  {
    code = "array_of_optional", rule = "arrays are dense",
    why = "`#`, `ipairs` and `table.insert` are defined on a sequence, and a hole makes each unreliable; a map " ..
      "does not name nil as a value either, since `m[k] = nil` deletes the key",
    fix = "use `{integer: T}` for sparse data, or remove the `?` and keep the missing element out of the array",
  },
  {
    code = "float_key", rule = "numeric keys are integers",
    why = "a float key faults on NaN and `1.0` folds to `1`, so a key read back is not the key written",
    fix = "key by `integer`, and convert a float with `math.tointeger` or `math.floor`",
  },
  {
    code = "key_type", rule = "what a map is keyed by",
    why = "a key is an `integer`, a `string`, a `boolean`, an enum or a record, class, interface or userdata by " ..
      "identity: a union or an optional has more than one way to be equal, and `any` and a function none the " ..
      "program can name",
    fix = "key by one of those types, or by an enum that names the keys",
  },
  {
    code = "repeated_field", rule = "distinct names",
    why = "a record's fields and a class's fields and methods are one namespace, since an absent field would read " ..
      "as the method of its name; only a declaration file repeats a function-typed field, as an overload",
    fix = "rename or remove one of them",
  },
  {
    code = "repeated_value", rule = "distinct names",
    why = "an enum is the set of its values, so a value written twice is one value",
    fix = "remove the second <value>",
  },
  {
    code = "type_arguments", rule = "type arguments",
    why = "a declaration takes the type parameters it declares, no more and no fewer, and a type with no " ..
      "parameters, a primitive and a type parameter take none",
    fix = "write <name> with <count> type arguments",
  },
  {
    code = "type_too_deep", rule = "types are bounded",
    why = "every recursion over a type is bounded by how deeply a type nests, so a type that nests deeper than " ..
      "1000 types, through the aliases it names, is refused",
    fix = "name a part of the type with a record, so that it does not nest",
  },
  {
    code = "alias_cycle", rule = "an alias names a type",
    why = "an alias creates no type, its use is what it names, so one that reaches itself with no declaration " ..
      "between names nothing",
    fix = "declare a record for the part that reaches itself",
  },
  {
    code = "bound_not_interface", rule = "a constraint is one interface",
    why = "a type parameter ranges over all types unless it has a bound, and a bound is one interface used with " ..
      "no arguments, which the operations of the body are checked against",
    fix = "bound <parameter> by an interface with no type parameters, or leave it unbounded",
  },
  {
    code = "lists_overlap", rule = "multiple returns are a matched call",
    why = "a call that answers one of several lists of values is taken apart by `match`, which tells the lists apart by " ..
      "a position that is `true` in one and `false` in the other; lists that no position tells apart would be " ..
      "told apart by nothing",
    fix = "make a position `true` in one list and `false` in the other, as `(true, R) | (false, E)` does",
  },
  {
    code = "bound_not_met", rule = "a constraint is one interface",
    why = "a type argument takes the place of a type parameter that the body treats as the interface it is bounded by, " ..
      "and a type conforms to an interface only by listing it, so an argument that does not list it breaks the body",
    fix = "list the interface in the declaration of <type> (`is <interface>`), or pass a type that does",
  },
  {
    code = "outer_type_parameter", rule = "a declaration is closed over its own parameters",
    why = "a record, class, interface or alias is one declaration of a module whatever code it stands in, so its " ..
      "body can name its own type parameters and no other",
    fix = "give <declaration> a type parameter of its own and pass <parameter> to it",
  },
  {
    code = "member_missing", rule = "a type is declared",
    why = "a name that a module, a record or the declared globals do not declare names no type",
    fix = "declare <name> in <where>, or import the module that does",
  },
  {
    code = "param_untyped", rule = "annotated parameters",
    why = "the signature of a method is part of its class and crosses modules as a row, so it never depends " ..
      "on a body",
    fix = "write the type: <parameter>: <type>",
  },
  {
    code = "metamethod_signature", rule = "compiler-written classes",
    why = "Lua runs `__close` with the value at the end of its block and `tostring` calls `__tostring` with the " ..
      "value and takes a string, so a class that writes either with other parameters, or a `__tostring` that " ..
      "answers another type, breaks at the call",
    fix = "write `function __close(self)` and `function __tostring(self): string`",
  },
  {
    code = "class_metamethod", rule = "dispatch only through declared types",
    why = "the table of a class's methods is the metatable of its values, so a method or function of a name that " ..
      "begins with two underscores is read by Lua as a metamethod: a class has `__close` and `__tostring` and no other, " ..
      "since no other runs code the program can see; a field of such a name is refused too, since a value that lacks it " ..
      "reads the table for it",
    fix = "rename <name>, and call it as a method (`v:name(...)`)",
  },
  {
    code = "optional_metamethod", rule = "an optional field is a plain value",
    why = "Lua reads a metamethod from the table that has it, so a field named for one that may be nil is a function " ..
      "that may be missing where Lua calls it, and the fork refused it (\"a metamethod cannot be optional\")",
    fix = "make <field> a field the literal always gives, or rename it: a name that begins with two underscores is " ..
      "a metamethod's",
  },
  {
    code = "optional_generic", rule = "an optional field is a plain value",
    why = "the fork refused a field that may be nil and holds a generic function, and the owner's decision keeps it " ..
      "refused (doc/plans/strict-teal.md, \"an optional field is a plain value\"): the checker narrows and calls a " ..
      "local or a parameter of such a type, so this is a choice and no hole, and it holds for a type parameter that an " ..
      "instance fills with a generic function as well",
    fix = "make <field> a field the literal always gives, or write the function type with its type arguments fixed",
  },
  {
    code = "thread_type", rule = "coroutines are typed",
    why = "a raw coroutine has no type of its own once `Coroutine<Y, R, S>` types what it yields and returns",
    fix = "write a `Coroutine<Y, R, S>`",
  },
  {
    code = "store_refused", rule = "the store's own checks",
    why = "the store checks what it can tell where a type or a declaration is made, and the lowering " ..
      "foresees each; an error of this code is a mistake of the lowering",
    fix = "report the program",
  },
}

-- Helpers -----------------------------------------------------------------------------

local function base_of(node: Ast.Node): Ast.Base
  return node
end

local function quoted(name: string): string
  return "`" .. name .. "`"
end

--- Whether `t` is `nil` or has the nil flag.
local function nilable(t: Type): boolean
  return t.tag == "nil" or (t is Types.Union and t.nilable)
end

local MAX_DEPTH <const> = Types.max_depth

--- How deeply alias lowering nests before it is called too deep.
local MAX_ALIAS_NESTING <const> = 200

local PRIMITIVES <const>: {string: Types.Tag} = {
  integer = "integer", number = "number", string = "string", boolean = "boolean", any = "any", never = "never",
}

local DECL_KINDS <const>: {string: Types.DeclKind} = {
  Record = "record", Interface = "interface", Class = "class", Enum = "enum",
}

local KIND_WORDS <const>: {Types.DeclKind: string} = {
  record = "record", class = "class", interface = "interface", enum = "enum", userdata = "userdata record",
}

--- The key of a declaration in the program's tables.
local function entry_key(module: string, names: {string}): string
  return module .. "\0" .. table.concat(names, ".")
end

function Declarations.module_of(path: string): string
  local stem = path:gsub("%.d%.tl$", ""):gsub("%.tl$", ""):gsub("/init$", "")
  return (stem:gsub("/+", "."))
end

--- The names of the type parameters of `list`.
local function parameter_names(list: {Ast.TypeParam}): {string}
  local out: {string} = {}
  for i, p in ipairs(list) do
    out[i] = p.name.name
  end
  return out
end

-- The state of one run -------------------------------------------------------------------

--- The type parameters in scope at one point: one binder, or the start of a declaration.
local record Frame
  --- Whether a declaration's body starts here: a variable of a binder outside it cannot be named.
  barrier: boolean
  count: integer
  --- The index from 0 of each type parameter, by the id of its binding.
  ids: {integer: integer}
  names: {string}
end

--- A declaration whose body is being gathered.
local record Build
  node: Ast.Node
  decl: Decl
  self_type: Type
  tparams: {Types.DeclParam}
  supers: {Type}
  fields: {Types.Field}
  methods: {Types.Method}
  array: Type | nil
  --- The node that first gave each name, and whether every one that gave it may be repeated as an
  --- overload of a declaration file.
  first_of: {string: Ast.Node}
  overloads: {string: boolean}
end

--- A union written in the module, to check once every record it holds is defined.
local record UnionSite
  node: Ast.Node
  type: Types.Union
  names: {{string}}
end

--- A use of a declaration or alias with type arguments.
local record Use
  node: Ast.Node
  decl: Decl | nil
  alias: AliasInfo | nil
  args: {Type}
  names: {{string}}
end

local type AliasInfo = Declarations.AliasInfo
local type Entry = Declarations.Entry
local type Requires = Declarations.Requires
local type Error = Declarations.Error
local type Program = Declarations.Program
local type Module = Declarations.Module

--- What one `lower` or `declare` holds.
local record Ctx
  program: Program
  store: Store
  input: Declarations.Input
  module: string
  filename: string
  tokens: {Lexer.Token}
  scoped: Scopes.Scoped
  decl_file: boolean
  info: Module
  frames: {Frame}
  --- The entry of each declaration node, and of each binding that names one.
  entry_of: {integer: Entry}
  by_binding: {integer: Entry}
  --- The ids of the type names that name a declared global.
  global_uses: {integer: boolean} | nil
  types: {integer: Type}
  decls: {integer: Decl}
  aliases: {integer: Type}
  errors: {Error}
  unions: {UnionSite}
  uses: {Use}
  tainted: {integer: boolean}
  alias_depth: integer
  kids: {Ast.Node}
  lowering: boolean
  --- The checks that wait for every declaration of the module to be defined.
  checks: {function(): boolean}
  --- The `function R.m` statements of the module's top level, by the declaration `R` names, and the ids of
  --- those whose signature was lowered with the declaration.
  statics: {Decl: {Ast.Function}}
  static_done: {integer: boolean}
end

local lower_type: function(ctx: Ctx, t: Ast.Type): Type

-- Errors ---------------------------------------------------------------------------------

--- Reports an error placed on the tokens `first` to `last`.
local function report(ctx: Ctx, code: Declarations.Code, first: integer, last: integer, msg: string, fix: string,
                      shown?: {string}, other?: Scopes.Place)
  local tokens = ctx.tokens
  local a = tokens[first]
  local b = tokens[math.max(first, last)]
  ctx.errors[#ctx.errors + 1] = {
    filename = ctx.filename, code = code, msg = msg, fix = fix, y = a.y, x = a.x, offset = a.offset,
    length = math.max(0, b.offset + b.length - a.offset), other = other, types = shown or {},
  }
end

local function report_at(ctx: Ctx, code: Declarations.Code, node: Ast.Node, msg: string, fix: string,
                         shown?: {string}, other?: Scopes.Place)
  local b = base_of(node)
  report(ctx, code, b.first, b.last, msg, fix, shown, other)
end

local function place_of(ctx: Ctx, node: Ast.Node): Scopes.Place
  local t = ctx.tokens[base_of(node).first]
  return { y = t.y, x = t.x, offset = t.offset, length = t.length }
end

-- Binders -------------------------------------------------------------------------------

--- The names of the type parameters of the binders in `frames`, outermost first, for [`Types.display`].
local function binder_names(frames: {Frame}): {{string}}
  local out: {{string}} = {}
  for _, f in ipairs(frames) do
    if f.count > 0 then
      out[#out + 1] = f.names
    end
  end
  return out
end

local function show(ctx: Ctx, t: Type): string
  return Types.display(t, binder_names(ctx.frames))
end

local function push_frame(ctx: Ctx, barrier: boolean, params: {Ast.TypeParam})
  local ids: {integer: integer} = {}
  for i, p in ipairs(params) do
    ids[p.name.id] = i - 1
  end
  ctx.frames[#ctx.frames + 1] = { barrier = barrier, count = #params, ids = ids, names = parameter_names(params) }
end

local function pop_frame(ctx: Ctx)
  ctx.frames[#ctx.frames] = nil
end

--- The variable the type parameter bound at `id` is here, and whether it is out of reach: a
--- binder past the start of the declaration being lowered.
local function parameter_type(ctx: Ctx, id: integer): Type | nil, boolean
  local depth = 0
  local blocked = false
  for i = #ctx.frames, 1, -1 do
    local f = ctx.frames[i]
    local index = f.ids[id]
    if index ~= nil then
      if blocked then
        return nil, true
      end
      return ctx.store:var(depth, index), false
    end
    if f.count > 0 then
      depth = depth + 1
    end
    if f.barrier then
      blocked = true
    end
  end
  return nil, false
end

--- The variables of the binder of `count` parameters at depth 0, as the arguments of a use of
--- the declaration inside its own body.
local function identity(store: Store, count: integer): {Type}
  local out: {Type} = {}
  for i = 1, count do
    out[i] = store:var(0, i - 1)
  end
  return out
end

-- The shape of a type ------------------------------------------------------------------

--- The tallest of `list`.
local function tallest(list: {Type}): integer
  local h = 0
  for _, t in ipairs(list) do
    if t.height > h then
      h = t.height
    end
  end
  return h
end

--- Whether `t` mentions `invalid`, which stands for a mistake already reported.
local function tainted(ctx: Ctx, t: Type): boolean
  local held = ctx.tainted[t.id]
  if held ~= nil then
    return held
  end
  local found = t.tag == "invalid"
  if not found then
    for _, part in ipairs(Types.parts(t)) do
      if tainted(ctx, part) then
        found = true
        break
      end
    end
  end
  ctx.tainted[t.id] = found
  return found
end

--- Runs `build`, which makes a type, and answers `invalid` and an error for the refusal of a store:
--- a type that nests too deep, or another.
local function attempt(ctx: Ctx, node: Ast.Node, build: function(): Type): Type
  local box: {Type} = {}
  local ok, why = pcall(function()
    box[1] = build()
  end)
  if ok then
    return box[1]
  end
  local text = tostring(why)
  if text:find("nested deeper than", 1, true) ~= nil then
    report_at(ctx, "type_too_deep", node, "this type nests more than " .. MAX_DEPTH .. " types deep, through the aliases it names",
      "name a part of it with a record or an interface, which a type does not unfold")
  else
    report_at(ctx, "store_refused", node, "the type store refused this type: " .. text, "report the program")
  end
  return ctx.store.invalid
end

--- Whether a map keyed by `k` is legal: nil, or the code and a word for what `k` is.
local function key_refusal(k: Type): Declarations.Code | nil
  if k.tag == "invalid" or k is Types.Var then
    return nil
  elseif k.tag == "integer" or k.tag == "string" or k.tag == "boolean" then
    return nil
  elseif k.tag == "number" then
    return "float_key"
  elseif k is Named then
    local kind = k.decl.kind
    if kind == "record" or kind == "class" or kind == "interface" or kind == "userdata" or kind == "enum" then
      return nil
    end
  end
  return "key_type"
end

--- What a key is, for a message.
local function key_word(k: Type, names: {{string}}): string
  if k is Types.Union and k.nilable then
    return "an optional"
  elseif k is Types.Union then
    return "a union"
  elseif k is Types.Array or k is Types.Map then
    return "a collection, which has no identity the language can name"
  elseif k is Types.Fn then
    return "a function"
  end
  return quoted(Types.display(k, names))
end

--- The count of type arguments of a use, said as the declaration takes them.
local function argument_count(n: integer): string
  return n == 1 and "1 type argument" or n .. " type arguments"
end

-- Names ---------------------------------------------------------------------------------

--- The type parameters of an entry's declaration or alias, as `<A, B>`, or "" for none.
local function parameter_list(e: Entry, count: integer): string
  if count == 0 then
    return ""
  end
  local names: {string} = {}
  local decl = e.decl
  local body = decl ~= nil and decl.body or nil
  local alias = e.alias
  for i = 1, count do
    local held = body ~= nil and body.tparams[i] or nil
    local from_alias = alias ~= nil and alias.tparams[i] or nil
    names[i] = held ~= nil and held.name or from_alias ~= nil and from_alias.name or (count == 1 and "T" or "T" .. i)
  end
  return "<" .. table.concat(names, ", ") .. ">"
end

local function dotted(e: Entry): string
  return table.concat(e.names, ".")
end

local function rest_of(path: {string}): {string}
  local out: {string} = {}
  for i = 2, #path do
    out[#out + 1] = path[i]
  end
  return out
end

--- The entry `rest` names under `base`, reporting the module or record that does not declare it.
local function follow(ctx: Ctx, t: Ast.TypeName, base: Entry, rest: {string}): Entry | nil
  if #rest == 0 then
    return base
  end
  local names: {string} = {}
  for i, n in ipairs(base.names) do
    names[i] = n
  end
  for _, n in ipairs(rest) do
    names[#names + 1] = n
  end
  local found = ctx.program.entries[entry_key(base.module, names)]
  if found == nil then
    local what = table.concat(rest, ".")
    local owner = dotted(base)
    local owner_decl = base.decl
    local body = owner_decl ~= nil and owner_decl.body or nil
    local field = false
    if body ~= nil and #rest == 1 then
      for _, f in ipairs(body.fields) do
        field = field or f.name == what
      end
    end
    report_at(ctx, "member_missing", t, quoted(owner) .. " declares no type " .. quoted(what) ..
        (field and ", only a field of that name" or ""),
      (field and "write `type " .. what .. " = ...` inside " .. quoted(owner) .. ": a field is not a type" or
        "declare " .. quoted(what) .. " inside " .. quoted(owner) .. ", or name a type it does declare"))
  end
  return found
end

--- The module `module` as the program knows it, asking its provider for it.
local function known_module(ctx: Ctx, module: string): Module | nil
  local program = ctx.program
  local info = program.modules[module]
  if info == nil then
    local provider = program.provider
    if provider ~= nil and provider(program, module) then
      info = program.modules[module]
    end
  end
  return info
end

--- The entry a type name refers to: a declaration of this module, of one it imports, or a declared
--- global; nil with an error where the module or record has no such type, and with none where the scope
--- builder has already said the name is no type.
local function resolve_entry(ctx: Ctx, t: Ast.TypeName): Entry | nil
  local path = t.path
  local head = path[1]
  local rest = rest_of(path)
  local vid = ctx.scoped.resolved[t.id]
  if vid ~= nil then
    local v = ctx.scoped.vars[vid]
    if v == nil then
      return nil
    end
    local base = ctx.by_binding[v.id]
    if base ~= nil then
      return follow(ctx, t, base, rest)
    end
    if v.module ~= "" then
      if ctx.program.external[v.module] then
        return nil
      end
      local info = known_module(ctx, v.module)
      if info == nil then
        report_at(ctx, "member_missing", t, "the module " .. quoted(v.module) .. " that " .. quoted(head) ..
            " imports is not known to the checker",
          "import a module of the project: its declarations are what a type of it names")
        return nil
      end
      local export = info.export
      if export == nil then
        report_at(ctx, "member_missing", t, "the module " .. quoted(v.module) .. " returns no declaration, so " ..
            quoted(table.concat(path, ".")) .. " names no type",
          "return a record, class, interface or enum from " .. quoted(v.module) .. " (`return Name`), or import a module that does")
        return nil
      end
      return follow(ctx, t, export, rest)
    end
    return nil
  end
  local declared = ctx.program.globals[head]
  if declared ~= nil then
    return follow(ctx, t, declared, rest)
  end
  if ctx.scoped.globals[head] ~= nil then
    report_at(ctx, "member_missing", t, "no declaration file declares the type " .. quoted(head),
      "declare " .. quoted(head) .. " with `global` in a declaration file")
  end
  return nil
end

-- Aliases -----------------------------------------------------------------------------------

local lower_bound: function(ctx: Ctx, p: Ast.TypeParam): Type | nil

--- Lowers the alias, which names a type with its own type parameters as the one binder.
local function lower_alias(ctx: Ctx, alias: AliasInfo)
  local node = alias.node
  if node == nil then
    alias.state = "unavailable"
    return
  end
  alias.state = "lowering"
  local saved = ctx.frames
  ctx.frames = {}
  push_frame(ctx, true, node.typeparams)
  ctx.alias_depth = ctx.alias_depth + 1
  local params: {Types.DeclParam} = {}
  for i, p in ipairs(node.typeparams) do
    params[i] = { name = p.name.name, bound = lower_bound(ctx, p) }
  end
  local body: Type
  if ctx.alias_depth > MAX_ALIAS_NESTING then
    report_at(ctx, "type_too_deep", node, "the alias " .. quoted(alias.name) .. " names a chain of more than " ..
        MAX_ALIAS_NESTING .. " aliases", "name a part of the chain with a record, which a type does not unfold")
    body = ctx.store.invalid
  else
    body = lower_type(ctx, node.type)
  end
  ctx.alias_depth = ctx.alias_depth - 1
  ctx.frames = saved
  alias.type = body
  alias.tparams = params
  alias.state = "done"
  ctx.aliases[node.id] = body
end

--- The alias with its body lowered, if this module can lower it; any other state is left as it is.
local function ensure_alias(ctx: Ctx, alias: AliasInfo)
  local own = alias.module == ctx.module or alias.module:sub(1, #ctx.module + 1) == ctx.module .. "@"
  if alias.state == "declared" and own and alias.node ~= nil and ctx.lowering then
    lower_alias(ctx, alias)
  end
end

-- Uses ---------------------------------------------------------------------------------------

--- `T` of a declaration [`lower_name`] met with its arguments lowered.
local function lower_arguments(ctx: Ctx, t: Ast.TypeName): {Type}
  local args: {Type} = {}
  for i, a in ipairs(t.args) do
    args[i] = lower_type(ctx, a)
  end
  return args
end

local function wrong_count(ctx: Ctx, t: Ast.TypeName, e: Entry, expected: integer)
  local name = quoted(table.concat(t.path, "."))
  local given = #t.args
  local fix: string
  if expected == 0 then
    fix = "remove the type arguments: " .. name .. " takes none"
  else
    fix = "write " .. quoted(table.concat(t.path, ".") .. parameter_list(e, expected)) .. ", with a type for each parameter"
  end
  report_at(ctx, "type_arguments", t, name .. " takes " .. (expected == 0 and "no type arguments" or argument_count(expected)) ..
      ", not " .. given, fix)
end

--- The type a name that resolved to `e` is, with the arguments of `t`.
local function use_entry(ctx: Ctx, t: Ast.TypeName, e: Entry): Type
  local store = ctx.store
  local decl = e.decl
  if decl ~= nil then
    local arity = decl.arity
    if arity ~= nil and arity ~= #t.args then
      wrong_count(ctx, t, e, arity)
      return store.invalid
    end
    local args = lower_arguments(ctx, t)
    local made: Type
    if tallest(args) >= MAX_DEPTH - 1 then
      made = attempt(ctx, t, function(): Type
        return store:named(decl, args)
      end)
    else
      made = store:named(decl, args)
    end
    if #args > 0 and made.tag ~= "invalid" then
      ctx.uses[#ctx.uses + 1] = { node = t, decl = decl, args = args, names = binder_names(ctx.frames) }
    end
    return made
  end
  local alias = e.alias
  if alias == nil then
    return store.invalid
  end
  ensure_alias(ctx, alias)
  local state = alias.state
  if state == "lowering" then
    report_at(ctx, "alias_cycle", t, "the alias " .. quoted(alias.name) .. " names itself, with no declaration between",
      "declare a record for the part of " .. quoted(alias.name) .. " that reaches itself: a record is a name, not an expansion")
    return store.invalid
  elseif state ~= "done" then
    report_at(ctx, "member_missing", t, "the alias " .. quoted(alias.name) .. " of the module " .. quoted(alias.module) ..
        " is not lowered yet, so it names no type here",
      "lower " .. quoted(alias.module) .. " before this module, or declare " .. quoted(alias.name) .. " as a record")
    return store.invalid
  end
  local body = alias.type
  if body == nil then
    return store.invalid
  end
  if alias.count ~= #t.args then
    wrong_count(ctx, t, e, alias.count)
    return store.invalid
  end
  if alias.count == 0 then
    return body
  end
  local args = lower_arguments(ctx, t)
  local made = Relation.instantiate(store, body, args)
  if made == nil then
    report_at(ctx, "type_too_deep", t, quoted(table.concat(t.path, ".")) .. " with these arguments nests more than " ..
        MAX_DEPTH .. " types deep", "name a part of the arguments with a record, which a type does not unfold")
    return store.invalid
  end
  ctx.uses[#ctx.uses + 1] = { node = t, alias = alias, args = args, names = binder_names(ctx.frames) }
  return made
end

--- The type a name is.
local function lower_name(ctx: Ctx, t: Ast.TypeName): Type
  local store = ctx.store
  local path = t.path
  local head = path[1]
  if head == nil then
    return store.invalid
  end
  local primitive = #path == 1 and PRIMITIVES[head] or nil
  if primitive ~= nil then
    if #t.args > 0 then
      report_at(ctx, "type_arguments", t, quoted(head) .. " takes no type arguments, not " .. #t.args,
        "remove the type arguments: " .. quoted(head) .. " is a primitive type")
      return store.invalid
    end
    return store:atom(primitive)
  end
  -- TODO: drop `thread` here and from the primitives of lang/scopes.tl once the `debug` functions that take a thread
  -- (`debug.traceback`, `debug.getinfo`) are declared over `Coroutine<Y, R, S>` or dropped: the typed `coroutine` library
  -- no longer names it.
  if #path == 1 and head == "thread" then
    report_at(ctx, "thread_type", t, "`thread` is no type: a coroutine is a `Coroutine<Y, R, S>`",
      "write `Coroutine<Y, R, S>` with the type it yields, returns and is sent")
    return store.invalid
  end
  local vid = ctx.scoped.resolved[t.id]
  local v = vid ~= nil and ctx.scoped.vars[vid] or nil
  if v ~= nil and v.kind == "typeparam" then
    if #path > 1 or #t.args > 0 then
      report_at(ctx, "type_arguments", t, "the type parameter " .. quoted(head) .. " takes no type arguments and has no members",
        "write " .. quoted(head) .. " alone")
      return store.invalid
    end
    local var, blocked = parameter_type(ctx, v.id)
    if blocked then
      report_at(ctx, "outer_type_parameter", t, quoted(head) .. " is a type parameter of the code around this declaration, " ..
          "which a declaration cannot name",
        "give the declaration a type parameter of its own and pass " .. quoted(head) .. " to it")
      return store.invalid
    end
    if var == nil then
      -- The binder is not among the frames: an alias is lowered on its own, with its own parameters only.
      report_at(ctx, "outer_type_parameter", t, quoted(head) .. " is a type parameter of the code around this declaration, " ..
          "which a declaration cannot name",
        "give the declaration a type parameter of its own and pass " .. quoted(head) .. " to it")
      return store.invalid
    end
    return var
  end
  local e = resolve_entry(ctx, t)
  if e == nil then
    return store.invalid
  end
  return use_entry(ctx, t, e)
end

--- The bound of a type parameter: the one interface its constraint names, with no arguments.
lower_bound = function(ctx: Ctx, p: Ast.TypeParam): Type | nil
  local constraint = p.constraint
  if constraint == nil then
    return nil
  end
  local t = lower_name(ctx, constraint)
  ctx.types[constraint.id] = t
  if t is Named and t.decl.kind == "interface" and #t.args == 0 then
    return t
  end
  if t.tag ~= "invalid" then
    report_at(ctx, "bound_not_interface", constraint, quoted(p.name.name) .. " is bounded by " .. quoted(show(ctx, t)) ..
        ", which is not an interface used with no type arguments",
      "bound " .. quoted(p.name.name) .. " by an interface that takes no type parameters, or write no bound")
  end
  return nil
end

-- Types -------------------------------------------------------------------------------------

--- The positions of the parameters that a narrowing return may name.
local function names_positions(names: {string}): {string: integer}
  local out: {string: integer} = {}
  for i, n in ipairs(names) do
    if n ~= "" then
      out[n] = i
    end
  end
  return out
end

--- Whether the lists `a` and `b` have `true` in one and `false` in the other at a position, which tells them apart.
local function told_apart(a: Types.Alt, b: Types.Alt): boolean
  for i = 1, math.min(#a.items, #b.items) do
    local x, y = a.items[i].tag, b.items[i].tag
    if (x == "true" and y == "false") or (x == "false" and y == "true") then
      return true
    end
  end
  return false
end

--- The alternatives of a return list, or nil where a narrowing return names a parameter that is
--- not there (the scope builder said so).
local function lower_rets(ctx: Ctx, rets: Ast.Rets, positions: {string: integer}): {Types.Alt} | nil
  local alts: {Types.Alt} = {}
  for _, list in ipairs(rets.lists) do
    local alt: Types.Alt = { items = {} }
    for i, item in ipairs(list) do
      if item is Ast.Narrows then
        local position = positions[item.param]
        local to = lower_type(ctx, item.type)
        if position == nil then
          return nil
        end
        alt.narrows = { param = position, to = to, asserts = item.asserts }
      elseif rets.variadic and i == #list then
        alt.tail = lower_type(ctx, item)
      else
        alt.items[#alt.items + 1] = lower_type(ctx, item)
      end
    end
    alts[#alts + 1] = alt
  end
  for i = 1, #alts do
    for j = i + 1, #alts do
      if not told_apart(alts[i], alts[j]) then
        local shown: {string} = {}
        for _, each in ipairs({ alts[i], alts[j] }) do
          local items: {string} = {}
          for k, t in ipairs(each.items) do
            items[k] = show(ctx, t)
          end
          local tail = each.tail
          if tail ~= nil then
            items[#items + 1] = show(ctx, tail) .. "..."
          end
          shown[#shown + 1] = "(" .. table.concat(items, ", ") .. ")"
        end
        report_at(ctx, "lists_overlap", rets, "the return lists " .. quoted(shown[1]) .. " and " .. quoted(shown[2]) ..
            " are told apart by no position that is `true` in one and `false` in the other",
          "make one position `true` in one list and `false` in the other (`(true, R) | (false, E)`), so that a `match` can " ..
            "tell which list a call answered", { shown[1], shown[2] })
        break
      end
    end
  end
  return alts
end

--- A function type written `function<T>(a: A, ...: R): X`.
local function lower_function(ctx: Ctx, t: Ast.TypeFunction): Type
  push_frame(ctx, false, t.typeparams)
  local tparams: {Types.TParam} = {}
  for i, p in ipairs(t.typeparams) do
    tparams[i] = { bound = lower_bound(ctx, p) }
  end
  local params: {Types.Param} = {}
  local names: {string} = {}
  local rest: Type | nil
  for _, p in ipairs(t.params) do
    local lowered = lower_type(ctx, p.type)
    if p.variadic then
      rest = lowered
    else
      params[#params + 1] = { type = lowered, omittable = p.optional }
      names[#params] = p.name or ""
    end
  end
  local alts: {Types.Alt} | nil
  local failed = false
  local declared = t.rets
  if declared ~= nil then
    alts = lower_rets(ctx, declared, names_positions(names))
    failed = alts == nil
  end
  pop_frame(ctx)
  if failed then
    return ctx.store.invalid
  end
  local store = ctx.store
  return attempt(ctx, t, function(): Type
    return store:fn({ tparams = tparams, params = params, rest = rest, rets = alts })
  end)
end

--- A collection `{T}` or `{K: V}`, `mut` where `mutable`: refused where the elements are optional or the key
--- is no key.
local function lower_collection(ctx: Ctx, t: Ast.Type, mutable: boolean): Type
  local store = ctx.store
  if t is Ast.TypeArray then
    local element = lower_type(ctx, t.element)
    if nilable(element) then
      report_at(ctx, "array_of_optional", t, "the elements of " .. quoted(Types.display(store:array(element, mutable), binder_names(ctx.frames))) ..
          " may be nil, and an array is dense",
        "use a map `{integer: " .. show(ctx, store:non_nil(element)) .. "}` for sparse data, or write `{" ..
          show(ctx, store:non_nil(element)) .. "}` and keep the missing elements out", { show(ctx, element) })
      return store.invalid
    end
    if element.height >= MAX_DEPTH then
      return attempt(ctx, t, function(): Type
        return store:array(element, mutable)
      end)
    end
    return store:array(element, mutable)
  elseif t is Ast.TypeMap then
    local key = lower_type(ctx, t.key)
    local value = lower_type(ctx, t.value)
    local refusal = key_refusal(key)
    if refusal == "float_key" then
      report_at(ctx, "float_key", t.key, "a map is keyed by `integer`, not `number`: a float key faults on NaN and `1.0` is the key `1`",
        "key by `integer`, and convert a float with `math.tointeger(n)` or `math.floor(n)`", { show(ctx, key) })
      return store.invalid
    elseif refusal ~= nil then
      report_at(ctx, "key_type", t.key, "a map is not keyed by " .. key_word(key, binder_names(ctx.frames)),
        "key by `integer`, `string`, `boolean`, an enum, or a record, class, interface or userdata; to key by several types, " ..
          "declare an enum or a record", { show(ctx, key) })
      return store.invalid
    end
    if nilable(value) then
      report_at(ctx, "array_of_optional", t.value, "the values of " .. quoted(Types.display(store:map(key, value, mutable), binder_names(ctx.frames))) ..
          " may be nil, and `m[k] = nil` deletes the key",
        "write `{" .. show(ctx, key) .. ": " .. show(ctx, store:non_nil(value)) ..
          "}`: a missing key already answers nil to a read", { show(ctx, value) })
      return store.invalid
    end
    if math.max(key.height, value.height) >= MAX_DEPTH then
      return attempt(ctx, t, function(): Type
        return store:map(key, value, mutable)
      end)
    end
    return store:map(key, value, mutable)
  end
  return store.invalid
end

lower_type = function(ctx: Ctx, t: Ast.Type): Type
  local store = ctx.store
  local kind = base_of(t).kind
  local out: Type
  if kind == "TypeName" and t is Ast.TypeName then
    out = lower_name(ctx, t)
  elseif kind == "TypeBool" and t is Ast.TypeBool then
    out = store:atom(t.value and "true" or "false")
  elseif kind == "TypeNil" then
    out = store:atom("nil")
  elseif kind == "TypeArray" or kind == "TypeMap" then
    out = lower_collection(ctx, t, false)
  elseif kind == "TypeMut" and t is Ast.TypeMut then
    out = lower_collection(ctx, t.inner, true)
    ctx.types[t.inner.id] = out
  elseif kind == "TypeUnion" and t is Ast.TypeUnion then
    local members: {Type} = {}
    for i, m in ipairs(t.members) do
      members[i] = lower_type(ctx, m)
    end
    if tallest(members) >= MAX_DEPTH then
      out = attempt(ctx, t, function(): Type
        return store:union(members)
      end)
    else
      out = store:union(members)
    end
    if out is Types.Union then
      ctx.unions[#ctx.unions + 1] = { node = t, type = out, names = binder_names(ctx.frames) }
    end
  elseif kind == "TypeOptional" and t is Ast.TypeOptional then
    local inner = lower_type(ctx, t.inner)
    if inner.height >= MAX_DEPTH then
      out = attempt(ctx, t, function(): Type
        return store:optional(inner)
      end)
    else
      out = store:optional(inner)
    end
  elseif kind == "TypeFunction" and t is Ast.TypeFunction then
    out = lower_function(ctx, t)
  else
    out = store.invalid
  end
  ctx.types[t.id] = out
  return out
end

-- Declaring ----------------------------------------------------------------------------------

--- Where a declaration stands while the tree is walked for them.
local record Place
  --- The names the declarations around are nested under, and the module they are in.
  names: {string}
  module: string
  --- Whether a declaration here is one of the module's own (not in the body of a function).
  top: boolean
end

local TRANSPARENT <const>: {string: boolean} = { Chunk = true, Block = true }

--- Kinds the walks do not enter: the types (lowered where they are written) and the parts of them.
local SKIP <const>: {string: boolean} = {
  TypeName = true, TypeBool = true, TypeNil = true, TypeError = true, TypeArray = true, TypeMap = true,
  TypeUnion = true, TypeOptional = true, TypeMut = true, TypeFunction = true, PType = true, Narrows = true,
  TypeParam = true, Rets = true, Binding = true, EnumValue = true, Param = true,
}

local DECLARATIONS <const>: {string: boolean} = {
  Record = true, Interface = true, Class = true, Enum = true, Alias = true, Import = true,
}

local function members_of(node: Ast.Node): {Ast.Member}
  if node is Ast.Record or node is Ast.Interface or node is Ast.Class then
    return node.members
  end
  return {}
end

local function name_of(node: Ast.Node): Ast.Binding | nil
  if node is Ast.Record or node is Ast.Interface or node is Ast.Class or node is Ast.Enum or
      node is Ast.TypeAlias or node is Ast.Import then
    return node.name
  end
  return nil
end

local function scope_of(node: Ast.Node): Ast.Scope | nil
  if node is Ast.Record or node is Ast.Interface or node is Ast.Class or node is Ast.Enum or
      node is Ast.TypeAlias or node is Ast.Import then
    return node.scope
  end
  return nil
end

local function typeparams_of(node: Ast.Node): {Ast.TypeParam}
  if node is Ast.Record or node is Ast.Interface or node is Ast.Class or node is Ast.TypeAlias then
    return node.typeparams
  end
  return {}
end

--- The kind of declaration a node makes: a record with a `userdata` member is a userdata record.
local function decl_kind(node: Ast.Node): Types.DeclKind | nil
  local kind = base_of(node).kind
  if kind == "Record" then
    for _, m in ipairs(members_of(node)) do
      if base_of(m).kind == "Userdata" then
        return "userdata"
      end
    end
    return "record"
  end
  return DECL_KINDS[kind]
end

--- Makes the entry of the declaration `node` standing at `place`, declares it in the store, and answers
--- the place its members stand at, or nil where it could not be declared.
local function declare_one(ctx: Ctx, node: Ast.Node, place: Place, seen: {string: boolean}): Place | nil
  local program = ctx.program
  local binding = name_of(node)
  if binding == nil or binding.name == "" then
    return nil
  end
  local name = binding.name
  local module = place.module
  local names: {string} = {}
  for i, n in ipairs(place.names) do
    names[i] = n
  end
  names[#names + 1] = name
  -- The library record of a primitive (`global record string`) is a value only, for `string.format` and `s:upper()`:
  -- the type `string` stays the primitive, so the record is declared as `std.string`.
  if ctx.decl_file and #place.names == 0 and Scopes.primitives[name] then
    names = { "std", name }
  end
  local top = place.top
  if #place.names == 0 then
    module = ctx.module
    if not place.top then
      module = ctx.module .. "@" .. base_of(node).id
    elseif seen[entry_key(module, names)] then
      module = ctx.module .. "@" .. base_of(node).id
      top = false
    end
  end
  local key = entry_key(module, names)
  seen[key] = true
  local entry: Entry = { module = module, names = names }
  local kind = decl_kind(node)
  if kind ~= nil then
    local arity = #typeparams_of(node)
    local made: {Decl} = {}
    local ok = pcall(function()
      made[1] = ctx.store:declare(kind, module, names, arity)
    end)
    if not ok then
      -- The scope builder has said that a primitive's name is no name for a type.
      if ctx.lowering and not Scopes.primitives[name] then
        report_at(ctx, "store_refused", node, "the type store refused the declaration " .. quoted(name), "report the program")
      end
      return nil
    end
    entry.decl = made[1]
    ctx.decls[base_of(node).id] = made[1]
  elseif node is Ast.TypeAlias then
    local count = #node.typeparams
    local alias: AliasInfo = {
      name = name, module = module, names = names, count = count, tparams = {},
      state = ctx.lowering and "declared" or "unavailable", node = ctx.lowering and node or nil,
    }
    entry.alias = alias
  else
    -- An import is read through the variable that holds the module.
    return nil
  end
  program.entries[key] = entry
  ctx.entry_of[base_of(node).id] = entry
  ctx.by_binding[binding.id] = entry
  if scope_of(node) == "global" and place.top and #place.names == 0 and top then
    program.globals[name] = entry
  end
  return { names = names, module = module, top = top }
end

--- Declares every declaration of the module: at the top, in members, and in function bodies.
local function declare_all(ctx: Ctx)
  local seen: {string: boolean} = {}
  local nodes: {Ast.Node} = { ctx.input.chunk }
  local places: {Place} = { { names = {}, module = ctx.module, top = true } }
  local top = 1
  local kids = ctx.kids
  local held = { count = 0 }
  local function collect(child: Ast.Node)
    held.count = held.count + 1
    kids[held.count] = child
  end
  while top > 0 do
    local node, place = nodes[top], places[top]
    nodes[top], places[top] = nil, nil
    top = top - 1
    local kind = base_of(node).kind
    if DECLARATIONS[kind] then
      local inside = declare_one(ctx, node, place, seen)
      if inside ~= nil then
        local members = members_of(node)
        for i = #members, 1, -1 do
          local m = members[i]
          local mkind = base_of(m).kind
          if DECLARATIONS[mkind] then
            top = top + 1
            nodes[top], places[top] = m, inside
          elseif mkind == "Method" and m is Ast.Method then
            top = top + 1
            nodes[top], places[top] = m.body, { names = {}, module = "", top = false }
          end
        end
      end
    elseif not SKIP[kind] then
      local transparent = TRANSPARENT[kind] or (kind == "Do" and ctx.decl_file)
      local below: Place = place
      if not transparent then
        below = { names = {}, module = "", top = false }
      end
      held.count = 0
      Ast.children(node, collect)
      for i = held.count, 1, -1 do
        top = top + 1
        nodes[top], places[top] = kids[i], below
      end
    end
  end
end

--- What the module returns, when it is a declaration: `return Name` last in the chunk, where `Name` is
--- a declaration or a top-level `local Name: Declaration = ...`.
local function find_export(ctx: Ctx): Entry | nil
  local stats = ctx.input.chunk.body.stats
  local last = stats[#stats]
  if last == nil or not (last is Ast.Return) or #last.values ~= 1 then
    return nil
  end
  local value = last.values[1]
  if not (value is Ast.Name) or value.binding == nil then
    return nil
  end
  local held = ctx.by_binding[value.binding]
  if held ~= nil then
    return held
  end
  for _, stat in ipairs(stats) do
    if stat is Ast.Local and #stat.bindings == 1 and stat.bindings[1].id == value.binding then
      local annotation = stat.types[1]
      if annotation ~= nil and annotation is Ast.TypeName then
        local vid = ctx.scoped.resolved[annotation.id]
        local v = vid ~= nil and ctx.scoped.vars[vid] or nil
        local base = v ~= nil and ctx.by_binding[v.id] or nil
        if base == nil and v ~= nil and v.module ~= "" and not ctx.program.external[v.module] then
          -- A type of an imported module: `local x: Mod.Type = ... return x`.
          local imported = known_module(ctx, v.module)
          base = imported ~= nil and imported.export or nil
        end
        if base ~= nil then
          local names: {string} = {}
          for i, n in ipairs(base.names) do
            names[i] = n
          end
          for i = 2, #annotation.path do
            names[#names + 1] = annotation.path[i]
          end
          return ctx.program.entries[entry_key(base.module, names)]
        end
      end
    end
  end
  return nil
end

--- The type of what the module returns when no declaration describes it and the type is written: the signature of
--- a function the module returns, or the annotation of a local it returns. Run once the tree is lowered.
local function find_value(ctx: Ctx): Type | nil
  local stats = ctx.input.chunk.body.stats
  local last = stats[#stats]
  if last == nil or not (last is Ast.Return) or #last.values ~= 1 then
    return nil
  end
  local value = last.values[1]
  if value is Ast.FunctionLit then
    return ctx.types[value.fn.id]
  elseif not (value is Ast.Name) or value.binding == nil then
    return nil
  end
  for _, stat in ipairs(stats) do
    if stat is Ast.LocalFunction and stat.name.id == value.binding then
      return ctx.types[stat.fn.id]
    elseif stat is Ast.Local and #stat.bindings == 1 and stat.bindings[1].id == value.binding then
      local annotation = stat.types[1]
      return annotation ~= nil and ctx.types[annotation.id] or nil
    end
  end
  return nil
end

-- Declarations' bodies ----------------------------------------------------------------------

--- Lowers the types of a function's parameters and returns, and records its type when every parameter has one.
local function lower_fn(ctx: Ctx, fn: Ast.Fn, tparams: {Types.TParam})
  local store = ctx.store
  local params: {Types.Param} = {}
  local names: {string} = {}
  local rest: Type | nil
  local typed = true
  for _, p in ipairs(fn.params) do
    local given = p.type
    local lowered: Type = store.invalid
    if given ~= nil then
      lowered = lower_type(ctx, given)
    else
      typed = false
    end
    if p.variadic then
      rest = lowered
    else
      params[#params + 1] = { type = lowered, omittable = p.optional }
      local binding = p.name
      names[#params] = binding ~= nil and binding.name or ""
    end
  end
  local alts: {Types.Alt} | nil
  local declared = fn.rets
  if declared ~= nil then
    alts = lower_rets(ctx, declared, names_positions(names))
    if alts == nil then
      typed = false
    end
  end
  if typed then
    ctx.types[fn.id] = attempt(ctx, fn, function(): Type
      return store:fn({ tparams = tparams, params = params, rest = rest, rets = alts })
    end)
  end
end

--- Claims `name` for the member `node` of the declaration being built: answers whether it is new, or an
--- overload of a declaration file; reports it where it repeats one.
local function claim(ctx: Ctx, build: Build, node: Ast.Node, binding: Ast.Binding, overload: boolean): boolean
  local name = binding.name
  local held = build.overloads[name]
  if held == nil then
    build.overloads[name] = overload
    build.first_of[name] = node
    return true
  end
  if held and overload then
    return true
  end
  local first = build.first_of[name]
  local what = ctx.decl_file and "; only a function-typed field of a declaration file may be repeated, as an overload" or ""
  report_at(ctx, "repeated_field", binding, quoted(name) .. " is declared twice in " .. quoted(build.decl.name) .. what,
    "rename or remove one of them" .. (ctx.decl_file and ", or write both as fixed function-typed fields" or
      ": the fields and methods of a record or class share one namespace"), nil,
    first ~= nil and place_of(ctx, first) or nil)
  return false
end

--- Whether `name` is one a metatable gives a meaning to: two underscores begin it.
local function metamethod_name(name: string): boolean
  return name:sub(1, 2) == "__"
end

--- Holds the method `m` of a class, of function type `made`, to what its name means when it is `__close` (it
--- takes the value alone) or `__tostring` (it also answers a `string`), and refuses a name of any other metamethod.
local function check_metamethod(ctx: Ctx, build: Build, m: Ast.Method, made: Type)
  local name = m.name.name
  local class = quoted(build.decl.name)
  if name ~= "__close" and name ~= "__tostring" then
    if metamethod_name(name) then
      report_at(ctx, "class_metamethod", m.name, "the method " .. quoted(name) .. " of " .. class .. " would be read " ..
          "by Lua as a metamethod of its values, and a class has `__close` and `__tostring` and no other",
        "rename " .. quoted(name) .. " and call it as a method (`v:" .. name:gsub("^_+", "") .. "(...)`)")
    end
    return
  end
  if not (made is Types.Fn) then
    return
  end
  if #made.params ~= 1 or made.rest ~= nil then
    report_at(ctx, "metamethod_signature", m.name, "the method " .. quoted(name) .. " of " .. class .. " takes more than " ..
        "the value, and Lua calls it with the value alone",
      "write `function " .. name .. "(self)" .. (name == "__tostring" and ": string" or "") .. "`")
  elseif name == "__tostring" then
    local alt = made.rets[1]
    if #made.rets ~= 1 or alt.tail ~= nil or #alt.items ~= 1 or alt.items[1] ~= ctx.store.string then
      report_at(ctx, "metamethod_signature", m.name, "the method `__tostring` of " .. class .. " does not answer a " ..
          "`string`, which `tostring` needs",
        "write `function __tostring(self): string`")
    end
  end
end

--- The method `m` of a class: its function type, the class its first parameter.
--
-- TODO: refuse `any` outside a parameter in an annotation ("what `any` may do" in doc/plans/new-checker-types.md),
-- once the checker for expressions lands: it is checked with the types the bodies are checked with.
local function lower_method(ctx: Ctx, build: Build, m: Ast.Method)
  local store = ctx.store
  local params: {Types.Param} = {}
  local names: {string} = {}
  local rest: Type | nil
  for i, p in ipairs(m.params) do
    local binding = p.name
    local pname = binding ~= nil and binding.name or ""
    if i == 1 then
      params[1] = { type = build.self_type }
      names[1] = pname
    else
      local given = p.type
      local lowered: Type = store.invalid
      if given ~= nil then
        lowered = lower_type(ctx, given)
      else
        report_at(ctx, "param_untyped", p, "the parameter " .. quoted(pname) .. " of the method " .. quoted(m.name.name) ..
            " has no type, and a method's signature is part of its class",
          "write the type: `" .. pname .. ": T`")
      end
      if p.variadic then
        rest = lowered
      else
        params[#params + 1] = { type = lowered, omittable = p.optional }
        names[#params] = pname
      end
    end
  end
  local alts: {Types.Alt} | nil
  local declared = m.rets
  if declared ~= nil then
    alts = lower_rets(ctx, declared, names_positions(names))
    if alts == nil then
      ctx.types[m.id] = store.invalid
      return
    end
  end
  local made = attempt(ctx, m, function(): Type
    return store:fn({ params = params, rest = rest, rets = alts })
  end)
  ctx.types[m.id] = made
  check_metamethod(ctx, build, m, made)
  if claim(ctx, build, m, m.name, false) then
    build.methods[#build.methods + 1] = { name = m.name.name, type = made }
  end
end

--- Whether `t` is a generic function type, or a union that has one.
local function generic_function(t: Type): boolean
  if t is Types.Fn then
    return #t.tparams > 0
  end
  if t.tag == "union" then
    for _, member in ipairs(Types.parts(t)) do
      if generic_function(member) then
        return true
      end
    end
  end
  return false
end

--- The field `m` of a record, interface or class.
local function lower_field(ctx: Ctx, build: Build, m: Ast.FieldDecl)
  local ft = lower_type(ctx, m.type)
  -- A field that may be nil is a plain value of one type: `name?: T`, or a type that has `nil` in it.
  --
  -- TODO: take an optional generic function field, if the owner lifts the decision (doc/plans/strict-teal.md, "an
  -- optional field is a plain value"): the checker narrows and calls a generic function held in a local or a
  -- parameter, so the rule exists and the refusal is a choice.
  if m.omittable or nilable(ft) then
    -- A class refuses every such name already (`class_metamethod`), and one mistake is one error.
    if build.decl.kind ~= "class" and metamethod_name(m.name.name) then
      report_at(ctx, "optional_metamethod", m.name, "the field " .. quoted(m.name.name) .. " of " ..
          quoted(build.decl.name) .. " is named for a metamethod and may be nil, so Lua may find it missing where it " ..
          "calls it",
        "make " .. quoted(m.name.name) .. " a field the literal always gives, or rename it")
    end
    if generic_function(ft) then
      report_at(ctx, "optional_generic", m.name, "the field " .. quoted(m.name.name) .. " of " ..
          quoted(build.decl.name) .. " may be nil and holds a generic function, which the checker has no rule to " ..
          "narrow and call",
        "make " .. quoted(m.name.name) .. " a field the literal always gives, or write the function type with its " ..
          "type arguments fixed")
    end
  end
  -- A value reads the table of its class for a field it lacks, and that table holds the metamethods.
  if build.decl.kind == "class" and metamethod_name(m.name.name) then
    report_at(ctx, "class_metamethod", m.name, "the field " .. quoted(m.name.name) .. " of " .. quoted(build.decl.name) ..
        " is a name Lua reads as a metamethod, and a value that lacks it would read the class's table for it",
      "rename " .. quoted(m.name.name) .. ": a class has no name that begins with two underscores")
  end
  local overload = ctx.decl_file and ft is Types.Fn and not m.mut and not m.omittable
  if not claim(ctx, build, m, m.name, overload) then
    return
  end
  -- A function of a userdata record that names the record first is a method of it.
  if build.decl.kind == "userdata" and ft is Types.Fn and not m.mut and not m.omittable and
      ft.params[1] ~= nil and ft.params[1].type == build.self_type then
    build.methods[#build.methods + 1] = { name = m.name.name, type = ft }
    return
  end
  build.fields[#build.fields + 1] = { name = m.name.name, type = ft, mut = m.mut, omittable = m.omittable }
end

-- Static functions ---------------------------------------------------------------------

--- Lowers the signature of the statement `function R.m(...)`, which stands outside the declaration `R`: its
--- type parameters are the one binder, and no type parameter of the code around it is in scope. Answers its
--- function type, or `invalid` where a parameter has no type.
local function lower_static(ctx: Ctx, f: Ast.Function): Type
  local saved = ctx.frames
  ctx.frames = {}
  push_frame(ctx, false, f.typeparams)
  local tparams: {Types.TParam} = {}
  for i, p in ipairs(f.typeparams) do
    tparams[i] = { bound = lower_bound(ctx, p) }
  end
  lower_fn(ctx, f.fn, tparams)
  ctx.frames = saved
  ctx.static_done[f.id] = true
  return ctx.types[f.fn.id] or ctx.store.invalid
end

--- Finds the statements `function R.m(...)` at the top of the module whose `R` is a record, class or userdata
--- record of the module, for [`enter_declaration`] to give `R` the field `m`.
local function collect_statics(ctx: Ctx)
  for _, stat in ipairs(ctx.input.chunk.body.stats) do
    if stat is Ast.Function and #stat.path == 2 then
      local binding = stat.path[1].binding
      local entry = binding ~= nil and ctx.by_binding[binding] or nil
      local decl = entry ~= nil and entry.decl or nil
      if decl ~= nil and (decl.kind == "record" or decl.kind == "class" or decl.kind == "userdata") then
        local list = ctx.statics[decl] or {}
        list[#list + 1] = stat
        ctx.statics[decl] = list
      end
    end
  end
end

--- Lists the supers of a declaration: interfaces, none that lists the declaration.
local function lower_supers(ctx: Ctx, build: Build, supers: {Ast.TypeName})
  for _, s in ipairs(supers) do
    local t = lower_name(ctx, s)
    ctx.types[s.id] = t
    if t is Named and t.decl.kind == "interface" then
      local through = Types.listing_cycle(build.decl, { t })
      if through == nil then
        build.supers[#build.supers + 1] = t
      elseif through == build.decl then
        report_at(ctx, "super_cycle", s, quoted(build.decl.name) .. " lists itself",
          "remove " .. quoted(show(ctx, t)) .. " from what " .. quoted(build.decl.name) ..
            " lists: a declaration lists the interfaces it implements or extends, never itself")
      else
        local via = through == t.decl and "" or " through " .. quoted(through.name)
        report_at(ctx, "super_cycle", s, quoted(build.decl.name) .. " lists " .. quoted(show(ctx, t)) ..
            ", which lists " .. quoted(build.decl.name) .. via,
          "remove " .. quoted(show(ctx, t)) .. " from what " .. quoted(build.decl.name) .. " lists, or remove " ..
            quoted(build.decl.name) .. " from what " .. quoted(through.name) .. " lists")
      end
    elseif t.tag ~= "invalid" then
      local what = t is Named and KIND_WORDS[t.decl.kind] or "type"
      report_at(ctx, "super_not_interface", s, quoted(build.decl.name) .. " lists " .. quoted(show(ctx, t)) ..
          ", which is " .. (what == "interface" and "an " or "a ") .. what .. ", and only an interface can follow `is`",
        "list an interface here" .. (t is Named and ", or declare " .. quoted(t.decl.name) .. " as an interface" or ""),
        { show(ctx, t) })
    end
  end
end

--- Gives the declaration its body, and queues the checks that read other bodies.
local queue_checks: function(ctx: Ctx, build: Build, names: {{string}})

local function finish_build(ctx: Ctx, build: Build, frames_names: {{string}})
  local store = ctx.store
  local body: Types.Body = {
    tparams = build.tparams, supers = build.supers, fields = build.fields, array = build.array,
    methods = build.methods, values = {},
  }
  local ok, why = pcall(function()
    store:define(build.decl, body)
  end)
  if not ok then
    report_at(ctx, "store_refused", build.node, "the type store refused the declaration " .. quoted(build.decl.name) .. ": " ..
        tostring(why), "report the program")
    local bare: Types.Body = { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} }
    for i, p in ipairs(build.tparams) do
      bare.tparams[i] = { name = p.name }
    end
    local _ = pcall(function()
      store:define(build.decl, bare)
    end)
    return
  end
  queue_checks(ctx, build, frames_names)
end

--- Lowers a record, interface or class: its type parameters, what it lists, its fields and methods. Answers
--- the nodes to walk next: the declarations nested in it and the bodies of its methods.
local function enter_declaration(ctx: Ctx, node: Ast.Node): {Ast.Node}
  local entry = ctx.entry_of[base_of(node).id]
  local decl = entry ~= nil and entry.decl or nil
  if decl == nil then
    return {}
  end
  local store = ctx.store
  local params = typeparams_of(node)
  push_frame(ctx, true, params)
  local build: Build = {
    node = node, decl = decl, self_type = store:named(decl, identity(store, #params)), tparams = {},
    supers = {}, fields = {}, methods = {}, first_of = {}, overloads = {},
  }
  for i, p in ipairs(params) do
    build.tparams[i] = { name = p.name.name, bound = lower_bound(ctx, p) }
  end
  local kind = base_of(node).kind
  local supers: {Ast.TypeName} = {}
  if node is Ast.Record or node is Ast.Interface or node is Ast.Class then
    supers = node.supers
  end
  lower_supers(ctx, build, supers)
  if node is Ast.Record then
    local array = node.array
    if array ~= nil then
      local part = lower_type(ctx, array)
      if part is Types.Array then
        build.array = part.element
      end
    end
  end
  local kids: {Ast.Node} = {}
  for _, m in ipairs(members_of(node)) do
    local mkind = base_of(m).kind
    if mkind == "FieldDecl" and m is Ast.FieldDecl then
      lower_field(ctx, build, m)
    elseif mkind == "Method" and m is Ast.Method then
      lower_method(ctx, build, m)
      kids[#kids + 1] = m.body
    elseif DECLARATIONS[mkind] then
      kids[#kids + 1] = m
    end
  end
  -- A function statement `function R.m(...)` gives the declaration used as a value the fixed field `m` unless `R`
  -- declares one: that field is then what the statement implements. An instance of `R` has no such field.
  for _, f in ipairs(ctx.statics[decl] or {}) do
    local name = f.path[2].text
    if decl.kind == "class" and metamethod_name(name) then
      report_at(ctx, "class_metamethod", f, "the function " .. quoted(decl.name .. "." .. name) .. " is a name Lua reads as a " ..
          "metamethod of the values of " .. quoted(decl.name) .. ", and `__close` and `__tostring` are written as methods",
        "rename " .. quoted(name) .. ", or write it as a method inside the class")
    elseif decl.kind == "class" and build.overloads[name] ~= nil then
      report_at(ctx, "repeated_field", f, quoted(name) .. " is declared twice in " .. quoted(decl.name) .. ": a function " ..
          quoted(decl.name .. "." .. name) .. " and a field or method of its values",
        "rename the function or the member: a class's fields, methods and functions share one namespace, since the " ..
          "table of its methods holds them all", nil, place_of(ctx, build.first_of[name]))
    elseif build.overloads[name] == nil then
      build.overloads[name] = false
      build.first_of[name] = f
      local named = ctx.program.statics[decl] or {}
      named[name] = { name = name, type = lower_static(ctx, f), mut = false, omittable = false }
      ctx.program.statics[decl] = named
    end
  end
  if kind == "Interface" or kind == "Record" or kind == "Class" then
    finish_build(ctx, build, binder_names(ctx.frames))
  end
  return kids
end

--- Lowers an enum.
local function enter_enum(ctx: Ctx, node: Ast.Enum)
  local entry = ctx.entry_of[node.id]
  local decl = entry ~= nil and entry.decl or nil
  if decl == nil then
    return
  end
  local values: {string} = {}
  local first: {string: Ast.Node} = {}
  for _, v in ipairs(node.values) do
    local held = first[v.value]
    if held ~= nil then
      report_at(ctx, "repeated_value", v, "the value " .. quoted(v.value) .. " is written twice in the enum " .. quoted(decl.name),
        "remove the second " .. quoted(v.value) .. ": an enum is the set of its values", nil, place_of(ctx, held))
    else
      first[v.value] = v
      values[#values + 1] = v.value
    end
  end
  local body: Types.Body = { tparams = {}, supers = {}, fields = {}, methods = {}, values = values }
  local ok, why = pcall(function()
    ctx.store:define(decl, body)
  end)
  if not ok then
    report_at(ctx, "store_refused", node, "the type store refused the enum " .. quoted(decl.name) .. ": " .. tostring(why),
      "report the program")
  end
end

-- Checks that read other bodies -----------------------------------------------------------

--- `f` with its first parameter `receiver`.
local function with_receiver(store: Store, f: Types.Fn, receiver: Type): Type
  local params: {Types.Param} = {}
  for i, p in ipairs(f.params) do
    params[i] = { type = i == 1 and receiver or p.type, omittable = p.omittable }
  end
  local rets: {Types.Alt} = {}
  for i, alt in ipairs(f.rets) do
    local narrows = alt.narrows
    rets[i] = {
      items = alt.items, tail = alt.tail,
      narrows = narrows ~= nil and { param = narrows.param, to = narrows.to, asserts = narrows.asserts } or nil,
    }
  end
  return store:fn({ tparams = f.tparams, params = params, rest = f.rest, rets = rets })
end

--- A field or method of a body that supplies what an interface declares under `name`.
local record Supply
  type: Type
  mut: boolean
  omittable: boolean
  method: boolean
end

local function supplies(body: Types.Body, name: string): {Supply}
  local out: {Supply} = {}
  for _, f in ipairs(body.fields) do
    if f.name == name then
      out[#out + 1] = { type = f.type, mut = f.mut or false, omittable = f.omittable or false, method = false }
    end
  end
  for _, m in ipairs(body.methods) do
    if m.name == name then
      out[#out + 1] = { type = m.type, mut = false, omittable = false, method = true }
    end
  end
  return out
end

--- Whether the program's judge raised because a declaration it reads has no body yet.
local function undefined_message(why: any): boolean
  return tostring(why):find("relation: .* is not defined") ~= nil
end

--- Agreement of a declaration with the interfaces it lists. Answers false where a declaration it reads is
--- not defined yet.
local function check_listing(ctx: Ctx, build: Build, names: {{string}}): boolean
  local program = ctx.program
  local store = ctx.store
  local decl = build.decl
  local defined = decl.body
  if defined == nil then
    return true
  end
  local body: Types.Body = defined
  local self_type = build.self_type
  if not (self_type is Named) then
    return true
  end
  local box: {Relation.Listing} = {}
  local ok, why = pcall(function()
    box[1] = program.judge:listed(self_type)
  end)
  if not ok then
    if undefined_message(why) then
      return false
    end
    error(why, 0)
  end
  local listing = box[1]
  local node = build.node
  local binding = name_of(node)
  local first = binding ~= nil and base_of(binding).first or base_of(node).first
  local last = binding ~= nil and base_of(binding).last or first
  if not listing.complete then
    report(ctx, "listing_too_large", first, last, quoted(decl.name) .. " lists more interfaces, through the ones it lists, " ..
        "than the checker follows, or one that would nest more than " .. MAX_DEPTH .. " types deep",
      "list fewer interfaces, or interfaces whose own listings are the same for every argument")
  end
  local is_class = decl.kind == "class"
  local function display(t: Type): string
    return Types.display(t, names)
  end
  for _, x in ipairs(listing.types) do
    local xbody = x is Named and x.decl.body or nil
    if x is Named and xbody ~= nil then
      for _, f in ipairs(xbody.fields) do
        local expected: Type = f.type
        local instance: Type | nil = expected
        if #x.args > 0 then
          instance = Relation.instantiate(store, f.type, x.args)
        end
        if instance ~= nil then
          expected = instance
          -- An omittable function field is `function(...)?`: the receiver is the function's.
          local optional = expected is Types.Union and expected.nilable
          local callable: Type = optional and store:non_nil(expected) or expected
          if callable is Types.Fn and #callable.params > 0 and #callable.tparams == 0 and callable.params[1].type == x then
            local replaced = with_receiver(store, callable, self_type)
            expected = optional and store:optional(replaced) or replaced
          end
          local found = supplies(body, f.name)
          local at = build.first_of[f.name]
          local where = at ~= nil and at or node
          local satisfied = false
          for _, s in ipairs(found) do
            local same = s.type == expected or tainted(ctx, s.type) or tainted(ctx, expected)
            if same and s.mut == (f.mut or false) and s.omittable == (f.omittable or false) then
              satisfied = true
              break
            end
          end
          if not satisfied then
            local xname = quoted(display(x))
            local mine = quoted(decl.name .. "." .. f.name)
            local s = found[1]
            if s == nil then
              if decl.kind ~= "interface" then
                local shown_type: Type = expected
                if f.omittable then
                  shown_type = store:non_nil(expected)
                end
                report(ctx, "interface_disagrees", first, last, quoted(decl.name) .. " lists " .. xname ..
                    " but has no " .. (is_class and "field or method " or "field ") .. quoted(f.name),
                  "declare " .. (f.mut and "`mut " or "`") .. f.name .. (f.omittable and "?" or "") ..
                    (tainted(ctx, shown_type) and "" or ": " .. display(shown_type)) .. "` in " .. quoted(decl.name) ..
                    ", as " .. xname .. " declares it" ..
                    (is_class and expected is Types.Fn and not f.mut and " (or write the method `function " .. f.name .. "(self, ...)` of that type)" or ""),
                  tainted(ctx, expected) and {} or { display(expected) })
              end
            elseif not (s.type == expected or tainted(ctx, s.type) or tainted(ctx, expected)) then
              report_at(ctx, "interface_disagrees", where, mine .. " is " .. quoted(display(s.type)) .. ", but " ..
                  xname .. " declares it as " .. quoted(display(expected)),
                "change " .. mine .. " to " .. quoted(display(expected)) ..
                  ": a type that lists an interface declares each of its fields with exactly the interface's type",
                { display(s.type), display(expected) })
            elseif s.mut ~= (f.mut or false) then
              report_at(ctx, "interface_disagrees", where, mine .. " is " .. (s.mut and "mut" or "fixed") .. ", but " ..
                  xname .. " declares it " .. (f.mut and "`mut`" or "fixed"),
                f.mut and "declare `mut " .. f.name .. "` in " .. quoted(decl.name) .. ", as " .. xname .. " does" or
                  "remove `mut` from " .. mine .. ", as " .. xname .. " declares it fixed")
            else
              report_at(ctx, "interface_disagrees", where, mine .. " is " .. (s.omittable and "omittable" or "required") ..
                  ", but " .. xname .. " declares it " .. (f.omittable and "omittable (`" .. f.name .. "?:`)" or "required"),
                f.omittable and "write `" .. f.name .. "?:` in " .. quoted(decl.name) .. ", as " .. xname .. " does" or
                  "remove the `?` after " .. quoted(f.name) .. " in " .. quoted(decl.name) .. ", as " .. xname .. " declares it required")
            end
          end
        end
      end
    end
  end
  return true
end

queue_checks = function(ctx: Ctx, build: Build, names: {{string}})
  if #build.supers == 0 then
    return
  end
  ctx.checks[#ctx.checks + 1] = function(): boolean
    return check_listing(ctx, build, names)
  end
end

-- Tags --------------------------------------------------------------------------------------

--- The single value of the enum a tag field has, or nil and whether the enum is not defined yet.
local function tag_value(field: Types.Field): string | nil, boolean
  local t = field.type
  if field.mut or field.omittable or not (t is Named) or t.decl.kind ~= "enum" then
    return nil, false
  end
  local body = t.decl.body
  if body == nil then
    return nil, true
  end
  if #body.values ~= 1 then
    return nil, false
  end
  return body.values[1], false
end

--- The field of `body` of this name, the first.
local function field_named(body: Types.Body, name: string): Types.Field | nil
  for _, f in ipairs(body.fields) do
    if f.name == name then
      return f
    end
  end
  return nil
end

--- Checks that the records of a union have a tag. Answers false where a body is not defined yet.
local function check_union(ctx: Ctx, site: UnionSite): boolean
  local records: {Named} = {}
  for _, m in ipairs(site.type.members) do
    if m is Named and m.decl.kind == "record" then
      records[#records + 1] = m
    end
  end
  if #records < 2 then
    return true
  end
  for _, r in ipairs(records) do
    if r.decl.body == nil then
      return false
    end
  end
  local first_body = records[1].decl.body
  if first_body == nil then
    return true
  end
  -- A name every record has as a tag, and the way the best one fails.
  local failure = ""
  local blamed = ""
  local shared = false
  for _, candidate in ipairs(first_body.fields) do
    local values: {string: Named} = {}
    local good = true
    local why = ""
    local everywhere = true
    for _, r in ipairs(records) do
      local body = r.decl.body
      if body == nil or field_named(body, candidate.name) == nil then
        everywhere = false
      end
    end
    shared = shared or everywhere
    for _, r in ipairs(records) do
      local body = r.decl.body
      local f = body ~= nil and field_named(body, candidate.name) or nil
      if f == nil then
        good = false
        why = quoted(r.decl.name) .. " has no field " .. quoted(candidate.name)
        break
      end
      local value, waiting = tag_value(f)
      if waiting then
        return false
      end
      if value == nil then
        good = false
        why = quoted(r.decl.name .. "." .. candidate.name) .. " is not a fixed field of an enum with one value"
        break
      end
      local other = values[value]
      if other ~= nil then
        good = false
        why = "both " .. quoted(other.decl.name) .. " and " .. quoted(r.decl.name) .. " have " ..
          quoted(candidate.name) .. " = " .. string.format("%q", value)
        break
      end
      values[value] = r
    end
    if good then
      return true
    end
    if failure == "" or candidate.name == "kind" or candidate.name == "type" or candidate.name == "tag" then
      failure = why
      blamed = candidate.name
    end
  end
  for _, r in ipairs(records) do
    if tainted(ctx, r) then
      return true
    end
  end
  local listed: {string} = {}
  for i, r in ipairs(records) do
    listed[i] = quoted(r.decl.name)
  end
  local shown = Types.display(site.type, site.names)
  local reason = failure ~= "" and shared and "; the closest, " .. quoted(blamed) .. ", fails because " .. failure or
    "; they share no field"
  report_at(ctx, "untagged_union", site.node, "the union " .. quoted(shown) .. " holds " .. #records ..
      " records that have no tag" .. reason,
    "give " .. table.concat(listed, ", ") .. " a fixed field of the same name whose type is an enum of one value each, " ..
      "different in each, so that `x.kind == \"...\"` tells them apart",
    { shown })
  return true
end

-- Instances ---------------------------------------------------------------------------------

--- What the parameters of a declaration or alias must be: every place a type parameter is the element of
--- an array, the value or key of a map, or an argument another declaration needs of its own.
local function scan_requires(roots: {Type}): Requires
  local req: Requires = { dense = {}, key = {}, optional = {}, flows = {} }
  local seen: {string: boolean} = {}
  local walk: function(t: Type, level: integer)
  walk = function(t: Type, level: integer)
    if t.open <= level then
      return
    end
    local mark = t.id .. ":" .. level
    if seen[mark] then
      return
    end
    seen[mark] = true
    if t is Types.Array then
      local e = t.element
      if e is Types.Var and e.depth == level then
        req.dense[e.index + 1] = true
      end
      walk(e, level)
    elseif t is Types.Map then
      local k, v = t.key, t.value
      if k is Types.Var and k.depth == level then
        req.key[k.index + 1] = true
      end
      if v is Types.Var and v.depth == level then
        req.dense[v.index + 1] = true
      end
      walk(k, level)
      walk(v, level)
    elseif t is Named then
      for i, a in ipairs(t.args) do
        if a is Types.Var and a.depth == level then
          req.flows[#req.flows + 1] = { to = t.decl, from = a.index, into = i - 1 }
        end
        walk(a, level)
      end
    elseif t is Types.Union then
      for _, m in ipairs(t.members) do
        if t.nilable and m is Types.Var and m.depth == level then
          req.optional[m.index + 1] = true
        end
        walk(m, level)
      end
    elseif t is Types.Fn then
      local inner = level + (#t.tparams > 0 and 1 or 0)
      for _, part in ipairs(Types.parts(t)) do
        walk(part, inner)
      end
    end
  end
  for _, root in ipairs(roots) do
    walk(root, 0)
  end
  return req
end

--- What the parameters of `decl` must be, or nil where it has no body yet.
local function requires_of(program: Program, decl: Decl): Requires | nil
  local held = program.requires[decl]
  if held ~= nil then
    return held
  end
  local body = decl.body
  if body == nil then
    return nil
  end
  local roots: {Type} = {}
  for _, f in ipairs(body.fields) do
    roots[#roots + 1] = f.type
  end
  for _, m in ipairs(body.methods) do
    roots[#roots + 1] = m.type
  end
  for _, s in ipairs(body.supers) do
    roots[#roots + 1] = s
  end
  local made = scan_requires(roots)
  local part = body.array
  if part ~= nil and part is Types.Var and part.depth == 0 then
    made.dense[part.index + 1] = true
  end
  if part ~= nil then
    local extra = scan_requires({ part })
    for i, flow in ipairs(extra.flows) do
      made.flows[#made.flows + 1] = flow
      local _ = i
    end
  end
  program.requires[decl] = made
  return made
end

--- Whether parameter `index` (from 0) of what `req` describes must be dense (`kind` "dense"), a key ("key") or is
--- made optional ("optional"), or nil where a declaration it passes the parameter to has no body yet.
local function must(program: Program, req: Requires, index: integer, kind: string,
                    seen: {Decl: {string: boolean}}): boolean | nil
  local direct = req.key
  if kind == "dense" then
    direct = req.dense
  elseif kind == "optional" then
    direct = req.optional
  end
  if direct[index + 1] then
    return true
  end
  for _, flow in ipairs(req.flows) do
    if flow.from == index then
      local marks = seen[flow.to]
      if marks == nil then
        marks = {}
        seen[flow.to] = marks
      end
      local mark = flow.into .. kind
      if not marks[mark] then
        marks[mark] = true
        local theirs = requires_of(program, flow.to)
        if theirs == nil then
          return nil
        end
        local r = must(program, theirs, flow.into, kind, seen)
        if r == nil or r then
          return r
        end
      end
    end
  end
  return false
end

--- Whether `argument` is below the interface `bound`, or nil where a declaration either names has no body yet.
local function bound_met(ctx: Ctx, argument: Type, bound: Type): boolean | nil
  local answer: {boolean} = {}
  local ok, why = pcall(function()
    answer[1] = ctx.program.judge:subtype(argument, bound)
  end)
  if ok then
    return answer[1]
  end
  if tostring(why):find("is not defined", 1, true) == nil then
    error(why, 0)
  end
  return nil
end

--- Checks the arguments of a use against what the parameters must be.
local function check_use(ctx: Ctx, use: Use): boolean
  local program = ctx.program
  local req: Requires | nil
  local name = ""
  local alias = use.alias
  local decl = use.decl
  if alias ~= nil then
    local body = alias.type
    if body == nil then
      return true
    end
    req = alias.requires
    if req == nil then
      req = scan_requires({ body })
      alias.requires = req
    end
    name = alias.name
  elseif decl ~= nil then
    req = requires_of(program, decl)
    name = decl.name
  end
  if req == nil then
    return false
  end
  local params: {Types.DeclParam} = {}
  local decl_body = decl ~= nil and decl.body or nil
  if alias ~= nil then
    params = alias.tparams
  elseif decl_body ~= nil then
    params = decl_body.tparams
  end
  for i, argument in ipairs(use.args) do
    if not tainted(ctx, argument) then
      local param = params[i]
      local bound = param ~= nil and param.bound or nil
      -- A variable of the code around stays unchecked until it is instantiated.
      if bound ~= nil and argument.open == 0 then
        local met = bound_met(ctx, argument, bound)
        if met == nil then
          return false
        elseif not met then
          local shown = Types.display(argument, use.names)
          report_at(ctx, "bound_not_met", use.node, quoted(name) .. " bounds its type parameter " .. i .. " by " ..
              quoted(Types.display(bound, use.names)) .. ", and " .. quoted(shown) .. " does not list it",
            "list the interface in the declaration of " .. quoted(shown) .. " (`is " .. Types.display(bound, use.names) ..
              "`), or pass a type that does", { shown })
        end
      end
      local dense = must(program, req, i - 1, "dense", {})
      if dense == nil then
        return false
      end
      if dense and nilable(argument) then
        local shown = Types.display(argument, use.names)
        report_at(ctx, "array_of_optional", use.node, quoted(name) .. " holds its type parameter " .. i ..
            " in an array or as the value of a map, so " .. quoted(shown) .. " would make elements that may be nil",
          "pass " .. quoted(Types.display(ctx.store:non_nil(argument), use.names)) .. ", which is not optional; an array is dense, " ..
            "and a map's missing key already answers nil", { shown })
      end
      local key = must(program, req, i - 1, "key", {})
      if key == nil then
        return false
      end
      local optional = must(program, req, i - 1, "optional", {})
      if optional == nil then
        return false
      end
      if optional == true and generic_function(argument) then
        local shown = Types.display(argument, use.names)
        report_at(ctx, "optional_generic", use.node, quoted(name) .. " makes its type parameter " .. tostring(i) ..
            " optional, so " .. quoted(shown) .. " would be a generic function that may be nil",
          "pass a function type with its type arguments fixed, or make the field the declaration holds it in required",
          { shown })
      end
      if key and key_refusal(argument) ~= nil then
        local shown = Types.display(argument, use.names)
        local code = key_refusal(argument) or "key_type"
        report_at(ctx, code, use.node, quoted(name) .. " keys a map by its type parameter " .. i .. ", so " ..
            quoted(shown) .. " would make a map keyed by " .. (code == "float_key" and "a float" or key_word(argument, use.names)),
          code == "float_key" and "pass `integer`, and convert a float with `math.tointeger(n)` or `math.floor(n)`" or
            "pass `integer`, `string`, `boolean`, an enum, or a record, class, interface or userdata", { shown })
      end
    end
  end
  return true
end

-- The walk ------------------------------------------------------------------------------------

--- The types of the globals a `global` statement of a declaration file declares: the annotation of a binding, or
--- the fields of a record that its value names (`global print <const> = Lib.print`), one for each overload.
local function declare_values(ctx: Ctx, node: Ast.Local)
  for i, b in ipairs(node.bindings) do
    local annotation = node.types[i]
    local value = node.values[i]
    local found: {Type} = {}
    if annotation ~= nil then
      found[1] = ctx.types[annotation.id] or ctx.store.invalid
    elseif value ~= nil and value is Ast.Field then
      local head = value.object
      local binding = head is Ast.Name and head.binding or nil
      local entry = binding ~= nil and ctx.by_binding[binding] or nil
      local decl = entry ~= nil and entry.decl or nil
      local body = decl ~= nil and decl.body or nil
      for _, f in ipairs(body ~= nil and body.fields or {}) do
        if f.name == value.name then
          found[#found + 1] = f.type
        end
      end
    end
    if #found > 0 then
      ctx.program.values[b.name] = found
    end
  end
end

--- What a node does when the walk reaches it: the nodes to walk next (nil for all its children), and whether
--- a frame of type parameters it pushed is popped when the walk leaves it.
local function enter(ctx: Ctx, node: Ast.Node): {Ast.Node} | nil, boolean
  local kind = base_of(node).kind
  if SKIP[kind] then
    return {}, false
  end
  if kind == "Local" and node is Ast.Local then
    for _, t in ipairs(node.types) do
      local _ = lower_type(ctx, t)
    end
    if ctx.decl_file and node.scope == "global" then
      declare_values(ctx, node)
    end
    return nil, false
  elseif (kind == "IsTest" and node is Ast.IsTest) or (kind == "Cast" and node is Ast.Cast) then
    local _ = lower_type(ctx, node.type)
    return nil, false
  elseif (kind == "LocalFunction" and node is Ast.LocalFunction) or (kind == "Function" and node is Ast.Function) then
    local params = node.typeparams
    push_frame(ctx, false, params)
    if not ctx.static_done[node.id] then
      local tparams: {Types.TParam} = {}
      for i, p in ipairs(params) do
        tparams[i] = { bound = lower_bound(ctx, p) }
      end
      lower_fn(ctx, node.fn, tparams)
    end
    return { node.fn.body }, true
  elseif kind == "FunctionLit" and node is Ast.FunctionLit then
    lower_fn(ctx, node.fn, {})
    return { node.fn.body }, false
  elseif kind == "Record" or kind == "Interface" or kind == "Class" then
    return enter_declaration(ctx, node), true
  elseif kind == "Enum" and node is Ast.Enum then
    enter_enum(ctx, node)
    return {}, false
  elseif kind == "Alias" and node is Ast.TypeAlias then
    local entry = ctx.entry_of[node.id]
    local alias = entry ~= nil and entry.alias or nil
    if alias ~= nil then
      ensure_alias(ctx, alias)
    end
    return {}, false
  elseif kind == "Import" then
    return {}, false
  end
  return nil, false
end

--- Lowers every annotation and declaration of the module.
local function walk(ctx: Ctx)
  local nodes: {Ast.Node} = { ctx.input.chunk }
  local leaves: {boolean} = { false }
  local top = 1
  local kids = ctx.kids
  local held = { count = 0 }
  local function collect(child: Ast.Node)
    held.count = held.count + 1
    kids[held.count] = child
  end
  while top > 0 do
    local node, leaving = nodes[top], leaves[top]
    nodes[top], leaves[top] = nil, nil
    top = top - 1
    if leaving then
      pop_frame(ctx)
    else
      local given, framed = enter(ctx, node)
      if framed then
        top = top + 1
        nodes[top], leaves[top] = node, true
      end
      if given ~= nil then
        for i = #given, 1, -1 do
          top = top + 1
          nodes[top], leaves[top] = given[i], false
        end
      else
        held.count = 0
        Ast.children(node, collect)
        for i = held.count, 1, -1 do
          top = top + 1
          nodes[top], leaves[top] = kids[i], false
        end
      end
    end
  end
  ctx.kids = {}
end

-- The program ---------------------------------------------------------------------------------

local program_mt: metatable<Program> = { __index = Declarations.Program }

function Declarations.new(store?: Store): Program
  local s = store or Types.new()
  local program: Program = setmetatable({
    store = s, judge = Relation.new(s), modules = {}, entries = {}, globals = {}, waiting = {}, requires = {}, external = {}, values = {}, statics = {},
  }, program_mt)
  return program
end

local function new_ctx(program: Program, input: Declarations.Input, lowering: boolean): Ctx
  local info = program.modules[input.module]
  if info == nil then
    info = { name = input.module, lowered = false, errors = {} }
    program.modules[input.module] = info
  end
  return {
    program = program, store = program.store, input = input, module = input.module, filename = input.filename,
    tokens = input.chunk.tokens, scoped = input.scoped, decl_file = input.dialect == "decl", info = info,
    frames = {}, entry_of = {}, by_binding = {}, types = {}, decls = {}, aliases = {}, errors = info.errors,
    unions = {}, uses = {}, tainted = {}, alias_depth = 0, kids = {}, lowering = lowering, checks = {},
    statics = {}, static_done = {},
  }
end

--- The errors in source order, copied.
local function in_order(errors: {Error}): {Error}
  local keyed: {{Error | integer}} = {}
  local out: {Error} = {}
  for i, e in ipairs(errors) do
    out[i] = e
  end
  local position: {Error: integer} = {}
  for i, e in ipairs(out) do
    position[e] = i
  end
  table.sort(out, function(a: Error, b: Error): boolean
    if a.offset ~= b.offset then
      return a.offset < b.offset
    end
    return position[a] < position[b]
  end)
  local _ = keyed
  return out
end

--- Runs the checks that were waiting for a declaration, until none more can run.
local function retry_waiting(program: Program)
  local progress = true
  while progress do
    progress = false
    local kept: {Declarations.Waiting} = {}
    for _, w in ipairs(program.waiting) do
      if w.run() then
        progress = true
      else
        kept[#kept + 1] = w
      end
    end
    program.waiting = kept
  end
end

Declarations.Program.declare = function(self: Program, input: Declarations.Input)
  local ctx = new_ctx(self, input, false)
  declare_all(ctx)
  local info = ctx.info
  info.export = find_export(ctx)
  ctx.kids = {}
end

Declarations.Program.lower = function(self: Program, input: Declarations.Input): Declarations.Lowered
  local existing = self.modules[input.module]
  if existing ~= nil and existing.lowered then
    error("declarations: the module " .. input.module .. " was lowered already", 2)
  end
  local ctx = new_ctx(self, input, true)
  declare_all(ctx)
  ctx.info.export = find_export(ctx)
  collect_statics(ctx)
  walk(ctx)
  if ctx.info.export == nil then
    ctx.info.value = find_value(ctx)
  end
  for _, site in ipairs(ctx.unions) do
    ctx.checks[#ctx.checks + 1] = function(): boolean
      return check_union(ctx, site)
    end
  end
  for _, use in ipairs(ctx.uses) do
    ctx.checks[#ctx.checks + 1] = function(): boolean
      return check_use(ctx, use)
    end
  end
  ctx.info.lowered = true
  for _, check in ipairs(ctx.checks) do
    if not check() then
      self.waiting[#self.waiting + 1] = { module = ctx.module, run = check }
    end
  end
  ctx.checks = {}
  retry_waiting(self)
  return {
    module = ctx.module, errors = in_order(ctx.errors), decls = ctx.decls, types = ctx.types, aliases = ctx.aliases,
    export = ctx.info.export, entries = ctx.by_binding,
  }
end

Declarations.Program.alias = function(self: Program, name: string, module: string)
  local info = self.modules[module]
  if info ~= nil and self.modules[name] == nil then
    self.modules[name] = info
  end
end

Declarations.Program.errors = function(self: Program, module: string): {Error}
  local info = self.modules[module]
  if info == nil then
    return {}
  end
  return in_order(info.errors)
end

Declarations.Program.unsettled = function(self: Program): integer
  return #self.waiting
end

Declarations.Program.scope_globals = function(self: Program): {string: Scopes.Global}
  local out: {string: Scopes.Global} = {}
  for name, entry in pairs(self.globals) do
    local decl = entry.decl
    local both = decl ~= nil and (decl.kind == "record" or decl.kind == "class" or decl.kind == "userdata")
    out[name] = { space = both and "both" or "type", const = false }
  end
  return out
end

return Declarations
