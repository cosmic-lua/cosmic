--- The codes of the new checker's expression errors ([`lang.check`]), and the rule behind each
--- ([`doc/plans/new-checker-types.md`], "errors"). An error has a [`Codes.Code`], the place at fault, what
--- is wrong in one line, and the change that fixes it written against the program's own names. A [`Codes.Row`]
--- is the rule a code stands for, which `cosmic docs <code>` and the error read alike: the rule as the plan names
--- it, why the language holds it, and the fix with the placeholders `<...>` the error fills from the program.
---
--- `float_key`, `array_of_optional` and `param_untyped` are also the codes of [`lang.declarations`], whose
--- catalog holds their rows; the others are this catalog's.
local Declarations = require("lang.declarations")
local Scopes = require("lang.scopes")

local record Codes
  --- What an error is, so that a reader does not parse its `msg`.
  enum Code
    -- the relation
    -- a value whose type is not below the type wanted
    "not_assignable"
    -- a value that may be nil where one that is not is wanted
    "nil_not_allowed"
    -- an index read used where the element is wanted
    "index_may_be_nil"
    -- a view where a `mut` collection is wanted
    "view_as_mut"
    -- two `mut` collections whose elements are two types
    "invariant_mut"
    -- a record where a map is wanted, or a map where a record is
    "record_as_map"
    -- a declaration used as a value where a value of it is wanted, or the reverse
    "declaration_value"
    -- untrusted data operated on, or a value stored as untrusted data
    "any_use"
    -- writes
    -- an index of a view assigned
    "view_written"
    -- a field that is not `mut` assigned
    "field_fixed"
    -- an index write that is not an append
    "array_hole"
    -- a number as an index or key
    "float_key"
    -- names and members
    -- a field the record lacks
    "field_unknown"
    -- `m.k` on a map
    "map_field"
    -- `r[k]` on a record with a key that names no field
    "record_index"
    -- a value that has no fields, indexed
    "not_indexable"
    -- a value that is no function, called
    "not_callable"
    -- an overloaded function used as a value
    "overload_value"
    -- a method of an interface read as a value, or called as a field
    "interface_method_value"
    -- calls and returns
    -- too few or too many arguments
    "arity"
    -- no overload takes the arguments
    "overload_none"
    -- a return of the wrong number of values
    "return_arity"
    -- a return in a function that returns nothing, or never
    "return_unexpected"
    -- a call that answers nothing, used as a value
    "no_value"
    -- a call with several return lists, used as a value
    "alternatives_as_value"
    -- more or fewer values than names or targets
    "value_count"
    -- `...` in a function that has no rest parameter
    "vararg_outside"
    -- a `local` with no type and no value
    "local_untyped"
    -- a parameter with no type where no function type gives one
    "param_untyped"
    -- operators
    -- a condition that is not a boolean or an optional
    "condition_type"
    -- `or` or `and` of a mix the language refuses
    "or_mix"
    -- `c and x or y`
    "and_ternary"
    -- `..` of what is not a string
    "concat_type"
    -- an operand an operator does not take
    "operand_type"
    -- `==` of two types that cannot be equal
    "compare_disjoint"
    -- an operator on a type variable
    "generic_op"
    -- `e as T`
    "cast_refused"
    -- `is` on a type a run-time tag cannot tell
    "is_on_record"
    -- `is` of a type the value cannot have
    "is_disjoint"
    -- a literal or an `is` of a class of another module
    "class_scope"
    -- a `<close>` local that holds neither nil nor a class that declares `__close`
    "close_not_closable"
    -- a call of `setmetatable`
    "setmetatable_call"
    -- a string literal that is not a member of the enum wanted
    "enum_member"
    -- table literals and joins
    -- a field the record needs, left out of a literal
    "literal_missing"
    -- a field the record lacks, written in a literal
    "literal_unknown"
    -- a field written twice in a literal
    "literal_repeated"
    -- a literal with no type to make it from
    "literal_needs_type"
    -- a literal that several members of a union could be
    "literal_ambiguous"
    -- items of the wrong shape for the type, or a type no literal makes
    "literal_shape"
    -- arms or elements with no common type
    "arms_differ"
    -- the elements of an array literal that may be nil
    "array_of_optional"
    -- modules
    -- a `require` of a module the project lacks
    "require_unknown"
    -- a module that returns what no declaration describes
    "export_not_declared"
    -- not yet checked: a form a later piece of the checker types
    -- a call of a generic function
    "unchecked_generic"
    -- a protected call
    "unchecked_protected"
    -- a coroutine function
    "unchecked_coroutine"
    -- a `match`
    "unchecked_match"
    -- a binding of C, or a global the declarations lack
    "unchecked_binding"
    -- a generic function inside the code of another
    "unchecked_nested"
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
    --- The second place the error involves: where a field is declared, where a name was first given.
    other?: Scopes.Place
    --- The types it is about, as the program spells them (`string?`, never `string | nil`).
    types: {string}
  end

  --- The rule behind a code.
  record Row
    code: Code
    --- The rule, named as the plan names it.
    rule: string
    --- Why the language holds it.
    why: string
    --- What the fix says, with the placeholders `<...>` the error fills from the program.
    fix: string
  end

  --- Every [`Code`], in the order the enum lists them.
  codes: {Code}

  --- The rule behind each code this module owns, in the order of `codes`. A code of
  --- [`lang.declarations`] has its row there.
  catalog: {Row}

  --- The row of `code`, from this catalog or that of [`lang.declarations`].
  row: function(code: Code): Row | nil
end

Codes.codes = {
  "not_assignable", "nil_not_allowed", "index_may_be_nil", "view_as_mut", "invariant_mut", "record_as_map",
  "declaration_value", "any_use", "view_written", "field_fixed", "array_hole", "float_key", "field_unknown", "map_field",
  "record_index", "not_indexable", "not_callable", "overload_value", "interface_method_value", "arity", "overload_none", "return_arity",
  "return_unexpected", "no_value", "alternatives_as_value", "value_count", "vararg_outside", "local_untyped",
  "param_untyped",
  "condition_type", "or_mix", "and_ternary", "concat_type", "operand_type", "compare_disjoint", "generic_op",
  "cast_refused", "is_on_record", "is_disjoint", "class_scope", "close_not_closable", "setmetatable_call", "enum_member",
  "literal_missing", "literal_unknown", "literal_repeated",
  "literal_needs_type", "literal_ambiguous", "literal_shape", "arms_differ", "array_of_optional", "require_unknown",
  "export_not_declared", "unchecked_generic", "unchecked_protected", "unchecked_coroutine", "unchecked_match",
  "unchecked_binding", "unchecked_nested",
}

--- The text every `unchecked_*` row shares: the form is typed `invalid` and reported until its piece lands.
local WAITING <const> = "the checker types this form in a later piece of its order (doc/plans/new-checker-types.md, " ..
  "\"the order the pieces land in\"); until then its result is `invalid`, which relates to every type, so the " ..
  "form is reported where it stands and a silent `invalid` is never made"

Codes.catalog = {
  {
    code = "not_assignable", rule = "the relation",
    why = "a value stands where a type is wanted only if its type is below it: nothing converts, widens or is " ..
      "assumed, so a wrong type is found where it is written and not where it fails",
    fix = "pass a <wanted>, or change the declaration to <got>; a `number` is converted with `math.tointeger(n)` or " ..
      "`math.floor(n)`",
  },
  {
    code = "nil_not_allowed", rule = "nil is its own type",
    why = "a type admits nil only as `T?` or a `name?: T` field, so a value that may be nil is no operand, argument, " ..
      "index base or callee of a type that is not",
    fix = "test it (`if <value> == nil then return nil, why end`), take it with `assert(<value>)`, or declare " ..
      "what receives it `T?`",
  },
  {
    code = "index_may_be_nil", rule = "an index read may be nil",
    why = "Lua answers nil for an index out of range, and no refinement answers the element: any other reference " ..
      "to the collection may change it between a test and the read",
    fix = "read it into a local and test it (`local row = <xs>[<i>] if row ~= nil then ... end`), or iterate with " ..
      "`for _, row in ipairs(<xs>)`",
  },
  {
    code = "view_as_mut", rule = "collections are views unless declared mutable",
    why = "a `{T}` is a read-only view, and a callee that changes a collection declares `mut`, so a view is never " ..
      "passed as `mut`",
    fix = "declare <name> `mut <type>` where it is made or received, or pass a collection made `mut`",
  },
  {
    code = "invariant_mut", rule = "one variance per type constructor",
    why = "a callee could store another element type through a `mut` collection, so `mut {T}` accepts only " ..
      "`mut {T}`",
    fix = "pass a view, or declare the callee's parameter with the element type of the argument",
  },
  {
    code = "record_as_map", rule = "records are not maps",
    why = "a record's fields have types of their own, so a record is never passed where a map is wanted, nor a map " ..
      "where a record is",
    fix = "pass a value of the declared type, or declare a `{K: V}` for the data that is keyed",
  },
  {
    code = "declaration_value", rule = "compiler-written classes",
    why = "a declaration used as a value is the table of its functions, and a record or class value is made by a " ..
      "table literal typed as it or by a function that makes one: the table of a class is its metatable, so no " ..
      "program passes it for a value of the class. A module typed with its record (`Seatbelt: Seatbelt`) is the " ..
      "same mistake the grammar cannot yet spell otherwise, and a ceiling holds it",
    fix = "make a value with a literal typed as <type>, or call a function of <type> that makes one",
  },
  {
    code = "any_use", rule = "what any may do",
    why = "`any` is untrusted data: it is passed to a parameter declared `any` and tested, and nothing is read out " ..
      "of it or stored as it",
    fix = "validate it with a [`cosmic.shape`] validator or test its tag (`type(v) == \"string\"`), and use the checked value",
  },
  {
    code = "view_written", rule = "collections are views unless declared mutable",
    why = "an index of a view is never assigned: the owner of the collection may rely on what it holds",
    fix = "declare <name> `mut <type>`",
  },
  {
    code = "field_fixed", rule = "fields are fixed unless declared mutable",
    why = "a field is given its value by the literal that makes the value and is not assigned after, unless it is " ..
      "declared `mut`, so a read of a fixed field can be narrowed",
    fix = "declare `mut <field>: <type>` in <record>, or make a new <record>",
  },
  {
    code = "array_hole", rule = "index writes append",
    why = "`t[#t + 1] = v` and `table.insert` are the writes that grow an array, so no write makes a hole and `#`, " ..
      "`ipairs` and `table.insert` stay defined on a sequence",
    fix = "append with `<t>[#<t> + 1] = <v>` or `table.insert`, remove with `table.remove`, or key a map " ..
      "`{integer: T}` for sparse data",
  },
  {
    code = "field_unknown", rule = "a record has the fields it declares",
    why = "a read of a name the record does not declare is nil at run time, so the typo is found where it is written",
    fix = "write the field the record declares (<nearest>), or declare <field> in <record>",
  },
  {
    code = "map_field", rule = "records are not maps",
    why = "a map is read by `m[k]` and its keys are values, so `m.k` names a field a map does not have",
    fix = "write `<m>[\"<k>\"]`, or declare a record for the fields",
  },
  {
    code = "record_index", rule = "records are not maps",
    why = "a record type is not an index type: `r[k]` is legal only where `k` is a literal, an enum or a union of " ..
      "them naming fields of the record",
    fix = "write the field (`<r>.<field>`), or index a `{K: V}`",
  },
  {
    code = "not_indexable", rule = "a record has the fields it declares",
    why = "only a record, a class, an interface, a userdata record, a collection or a string has fields or " ..
      "elements to read",
    fix = "index a value of one of those types",
  },
  {
    code = "not_callable", rule = "calls take functions",
    why = "a call runs the function its callee holds, which has to be a function type: a value that is not, or is " ..
      "one of several, is not called. A method called through a union of records is one function when every member " ..
      "declares it the same once the receiver is the union, and one of several otherwise",
    fix = "call a function, or narrow the value to one function type first",
  },
  {
    code = "overload_value", rule = "overloads take the first match",
    why = "overloads exist in declarations only, and the call picks the first whose parameters accept the arguments, " ..
      "so a set of overloads has no type of its own to give a variable or a parameter",
    fix = "call it where you use it, or write a function of the one overload you mean",
  },
  {
    code = "interface_method_value", rule = "compiler-written classes",
    why = "a type that lists an interface declares each method with itself as the receiver, so a method read through " ..
      "the interface is the one function of the value's own class, and calling that with another implementer would run " ..
      "one class's code on another's fields: a method of an interface is called on its receiver, `v:m(...)`",
    fix = "call it as `<value>:<method>(...)`",
  },
  {
    code = "arity", rule = "calls take the arguments the function declares",
    why = "a missing argument is nil at run time and a surplus one is dropped, so both are mistakes found at the call",
    fix = "pass <count> arguments, or declare the parameter `name?: T`",
  },
  {
    code = "overload_none", rule = "overloads take the first match",
    why = "a declaration file lists a function's overloads in order, and the call takes the first whose " ..
      "parameters accept the arguments",
    fix = "pass arguments one overload accepts (listed), in its order",
  },
  {
    code = "return_arity", rule = "returns are checked against the declared list",
    why = "a function answers the values its return list declares, so a `return` of another number of values is " ..
      "refused at the `return`",
    fix = "return <count> values, or declare the return list the function answers",
  },
  {
    code = "return_unexpected", rule = "a function with no return list returns nothing",
    why = "the signature of a function is what it declares and never depends on a body, so a value returned from " ..
      "a function that declares none is a mistake, and a function declared `never` returns nothing at all",
    fix = "declare the return list (`function f(): T`), or remove the value; a `never` function ends in `error`",
  },
  {
    code = "no_value", rule = "varargs end in nil",
    why = "a call that answers nothing has no value to give where one is wanted",
    fix = "use the call as a statement, or call a function that answers a value",
  },
  {
    code = "alternatives_as_value", rule = "multiple returns are a matched call",
    why = "a function that answers one of several value lists is told apart by `match`; used as a value it would " ..
      "answer none of them",
    fix = "match the call: `match <call> do | (true, v) then ... end`",
  },
  {
    code = "value_count", rule = "a name has a value",
    why = "a name given fewer values than it needs would be nil at run time, and a value no name takes is dropped",
    fix = "give <count> values, or remove the names or values left over",
  },
  {
    code = "vararg_outside", rule = "varargs end in nil",
    why = "`...` is the values a function takes past its parameters, so a function that declares no rest parameter " ..
      "has none to read",
    fix = "declare the rest parameter `...: T`",
  },
  {
    code = "local_untyped", rule = "assigned before read",
    why = "a local with no value has the type it is declared with, since nothing it is first assigned could give one " ..
      "without the body deciding the signature of a name",
    fix = "write its type: `local <name>: T` (`T?` if it may stay unset), or give it a value",
  },
  {
    code = "condition_type", rule = "conditions are booleans or optionals",
    why = "a condition is a boolean or a `T?` where `T` is not a boolean: any other type is always true or mixes nil " ..
      "with false, and the test it stands for is not written",
    fix = "write the test: `s ~= \"\"` for a string, `n ~= 0` for a number, `x ~= nil` or `x == true` for the rest",
  },
  {
    code = "or_mix", rule = "honest `or` and `and`",
    why = "`or` replaces false as well as nil, and `and` answers its left operand when that is false or nil, so " ..
      "the operands are both booleans or the left is a `T?` for a `T` that is not a boolean",
    fix = "write the test: `if <a> == nil then <b> else <a> end`, or make both operands booleans",
  },
  {
    code = "and_ternary", rule = "honest `or` and `and`",
    why = "`c and x or y` answers `y` when `x` is false or nil, so it is not a choice between `x` and `y`",
    fix = "use the `if` expression: `if <c> then <x> else <y> end`",
  },
  {
    code = "concat_type", rule = "no implicit conversion or hidden code",
    why = "`..` takes two strings: a number or a boolean is never made text without a call that says so",
    fix = "write `tostring(<value>)` or `string.format(\"%d\", <value>)`",
  },
  {
    code = "operand_type", rule = "no implicit conversion or hidden code",
    why = "arithmetic takes numbers, a bit operator integers, an ordered comparison two numbers or two strings, `#` a " ..
      "string or an array; no operator converts a string or an optional",
    fix = "convert the operand (`tonumber`, `math.tointeger`), or test it first",
  },
  {
    code = "compare_disjoint", rule = "the relation",
    why = "`==` of two types that share no value is never true, which finds the dead test",
    fix = "compare values of one type, or remove the test",
  },
  {
    code = "generic_op", rule = "generic bodies compare, pass and store",
    why = "a type variable ranges over every type, so an operator is defined on it only through the interface it " ..
      "is bounded by",
    fix = "bound <parameter> by an interface that declares the operation (`T is Ordered`)",
  },
  {
    code = "cast_refused", rule = "no casts",
    why = "a type changes only by a check the checker can see: `is`, a guard, a narrowing declaration or a validator",
    fix = "validate the value, test it with `is`, or delete the cast",
  },
  {
    code = "is_on_record", rule = "no casts",
    why = "`is` is a test of a run-time tag: a class is told by its metatable, and a primitive or an enum by its " ..
      "value; a record, an interface or a collection leaves nothing to test, and the contents of `any` are unchecked",
    fix = "test a tag (`x.kind == \"...\"`), declare a class, or validate the data with a [`cosmic.shape`] validator",
  },
  {
    code = "is_disjoint", rule = "no casts",
    why = "`v is T` is true when the run-time tag of `v` is that of `T`, so it narrows a value that may be a `T`: when " ..
      "no type `v` can have is below `T`, or `T` below it, the test is never true and the branch it guards never runs",
    fix = "this test is always false: remove it and the branch it guards, or test a type <value> can have",
  },
  {
    code = "class_scope", rule = "compiler-written classes",
    why = "the compiler attaches the metatable of a class to the literal that makes its value and tests it with " ..
      "`is`, and the table is a local of the module that declares the class, so a module makes and tests the values " ..
      "of its own classes and calls a function of another module's class for the rest",
    fix = "make the value, or test it, in <module> with a function of the class, and call that",
  },
  {
    code = "close_not_closable", rule = "compiler-written classes",
    why = "`<close>` calls the `__close` of the value's metatable at the end of the block and raises where there " ..
      "is none, so the local holds nil or a class that declares `__close`",
    fix = "hold a class that declares `function __close(self)` in <name>, or release the value by hand",
  },
  {
    code = "setmetatable_call", rule = "dispatch only through declared types",
    why = "the only metatables on tables a program makes are the compiler's, attached to the literal of a class, " ..
      "so the only code they run is a class's `__close` and `__tostring`",
    fix = "declare a `class` and write the value as a table literal typed as the class",
  },
  {
    code = "enum_member", rule = "enums are nominal strings",
    why = "an enum is the set of its values, so a string literal is accepted where it is a member",
    fix = "write one of <members>",
  },
  {
    code = "literal_missing", rule = "fields are fixed unless declared mutable",
    why = "a literal gives every field of its record a value, except a `?` field, since a field is not assigned after",
    fix = "add <fields> to the literal",
  },
  {
    code = "literal_unknown", rule = "a record has the fields it declares",
    why = "a literal of a record names the fields the record declares",
    fix = "write the field the record declares (<nearest>), or declare <field> in <record>",
  },
  {
    code = "literal_repeated", rule = "a record has the fields it declares",
    why = "a field is given once",
    fix = "remove the second <field>",
  },
  {
    code = "literal_needs_type", rule = "fields are fixed unless declared mutable",
    why = "a literal is a record only where checked against one, and a table with no items has nothing to make its " ..
      "type from",
    fix = "declare the type: `local <name>: mut {T} = {}`",
  },
  {
    code = "literal_ambiguous", rule = "tagged unions",
    why = "a literal checked against a union is the member its tag selects, or the one table-like member",
    fix = "give the tag field of the member, or type the literal first",
  },
  {
    code = "literal_shape", rule = "records are not maps",
    why = "a literal is a record, an array or a map by its items and the type it is checked against; an interface or " ..
      "an enum is made by a class that lists it, and positional items make no record",
    fix = "write items of the shape of <type>",
  },
  {
    code = "arms_differ", rule = "arms and elements join to a common type",
    why = "the type of `if` arms and literal elements is the type all are below, else the union would hide a " ..
      "mistake: `{1, \"a\"}` is nearly always one",
    fix = "type the result: `local <name>: <type> = ...`, or make the arms one type",
  },
  {
    code = "require_unknown", rule = "a module is declared",
    why = "a `require` of a module the project lacks has no declarations to check the uses of its value against",
    fix = "require a module of the project",
  },
  {
    code = "export_not_declared", rule = "declarations are the trust boundary",
    why = "a module returns a declaration, a name whose type is written, or a function with a written signature, " ..
      "so an interface never depends on a body",
    fix = "return a record, class, interface or enum, or a local declared with its type",
  },
  { code = "unchecked_generic", rule = "generic inference is local to the call", why = WAITING,
    fix = "none yet: the generics piece types a call of a generic function" },
  { code = "unchecked_protected", rule = "pcall and coroutines are typed", why = WAITING,
    fix = "none yet: the piece of `match` and protected calls types `pcall` and `xpcall`" },
  { code = "unchecked_coroutine", rule = "pcall and coroutines are typed", why = WAITING,
    fix = "none yet: the same piece types `coroutine.*`" },
  { code = "unchecked_match", rule = "multiple returns are a matched call", why = WAITING,
    fix = "none yet: the piece of `match` types the arms" },
  { code = "unchecked_binding", rule = "declarations are the trust boundary", why = WAITING,
    fix = "none yet: the bindings of C are typed once the checker reads them from declaration files" },
  { code = "unchecked_nested", rule = "generic bodies compare, pass and store", why = WAITING,
    fix = "none yet: the generics piece types a generic function inside another" },
}

function Codes.row(code: Codes.Code): Codes.Row | nil
  for _, r in ipairs(Codes.catalog) do
    if r.code == code then
      return r
    end
  end
  local name = tostring(code)
  for _, r in ipairs(Declarations.catalog) do
    if tostring(r.code) == name then
      return { code = code, rule = r.rule, why = r.why, fix = r.fix }
    end
  end
  return nil
end

return Codes
