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
    -- a function of a declaration read as the module loads, before the statement that defines it has run
    "static_before_definition"
    -- calls and returns
    -- too few or too many arguments
    "arity"
    -- no overload takes the arguments
    "overload_none"
    -- a type parameter of a generic function that nothing at the call fixes
    "cannot_infer"
    -- a type parameter that two arguments make two types
    "infer_conflict"
    -- a type argument that lacks the interface its parameter is bounded by
    "bound_unmet"
    -- a return of the wrong number of values
    "return_arity"
    -- a return in a function that returns nothing, or never
    "return_unexpected"
    -- a call that answers nothing, used as a value
    "no_value"
    -- a call with several return lists, used as a value
    "alternatives_as_value"
    -- a list a `match` call may answer that no arm takes
    "match_missing"
    -- a `match` arm no list the call answers reaches
    "match_redundant"
    -- a `match` pattern that tests or binds what the lists do not have
    "match_pattern"
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
    -- a field or a key written twice in a literal, of any type
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
    -- flow
    -- a function that answers values, or is declared `never`, whose end is reachable
    "missing_return"
    -- a local read before every path assigns it
    "not_assigned"
    -- a statement control cannot reach
    "unreachable"
    -- a value that may be nil because an assignment dropped what a test had shown
    "narrowing_dropped"
    -- a function declared to narrow an argument whose body does not show it
    "narrows_unproved"
    -- a local assigned twice by one statement
    "assign_repeated"
    -- a generic `for` with a fourth expression after `in`, which Lua takes as the value to close
    "iterator_extra"
    -- a generic `for` that names more variables than its iterator answers values
    "iterator_variables"
    -- a literal pattern, replacement, format or key table of the string library that Lua raises on
    "pattern_malformed"
    "format_malformed"
    "pack_malformed"
    "gsub_key"
    -- `is` on a parenthesized place, which narrows nothing
    "paren_is"
    -- `type(x)` compared with a name it never answers
    "type_name"
    -- not yet checked: a form a later piece of the checker types
    -- a binding of C, or a global the declarations lack
    "unchecked_binding"
  end

  --- The call whose argument an error is about: set on an error filed for a value given to a parameter (a refusal by
  --- the parameter's type, in any code), so that a reader need not parse its message to know it is an argument's.
  record Argument
    --- The callee as the program writes it ([`Fs.read`], `f`, `obj:method`).
    callee: string
    --- The module that declares the callee where the checker knows it (the receiver's, or the module a field is read
    --- from), else "": a local or global function, or a callee whose declaration the checker did not see.
    module: string
    --- Which argument, as the message counts it: from 1, the receiver of a method call not among them.
    position: integer
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
    --- Set when the error is a value refused by a parameter of a call; nil for any other.
    argument?: Argument
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
  row: function(code: Code): Row?
end

Codes.codes = {
  "not_assignable", "nil_not_allowed", "index_may_be_nil", "view_as_mut", "invariant_mut", "record_as_map",
  "declaration_value", "any_use", "view_written", "field_fixed", "array_hole", "float_key", "field_unknown", "map_field",
  "record_index", "not_indexable", "not_callable", "overload_value", "interface_method_value", "static_before_definition", "arity", "overload_none", "cannot_infer", "infer_conflict",
  "bound_unmet", "return_arity",
  "return_unexpected", "no_value", "alternatives_as_value", "match_missing", "match_redundant", "match_pattern", "value_count", "vararg_outside", "local_untyped",
  "param_untyped",
  "condition_type", "or_mix", "and_ternary", "concat_type", "operand_type", "compare_disjoint", "generic_op",
  "cast_refused", "is_on_record", "is_disjoint", "class_scope", "close_not_closable", "setmetatable_call", "enum_member",
  "literal_missing", "literal_unknown", "literal_repeated",
  "literal_needs_type", "literal_ambiguous", "literal_shape", "arms_differ", "array_of_optional", "require_unknown",
  "export_not_declared", "missing_return", "not_assigned", "unreachable", "narrowing_dropped", "narrows_unproved",
  "assign_repeated", "iterator_extra", "iterator_variables", "pattern_malformed", "format_malformed", "pack_malformed",
  "gsub_key", "paren_is", "type_name",
  "unchecked_binding",
}

--- The text every `unchecked_*` row shares: the form is typed `invalid` and reported until its piece lands.
local WAITING <const> = "the checker types this form when it reads the declarations of the bindings of C " ..
  "(doc/plans/new-checker-types.md, \"what the checker starts from\"); until then its result is `invalid`, which " ..
  "relates to every type, so the form is reported where it stands and a silent `invalid` is never made"

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
      "program passes it for a value of the class. A module is no value of its record, so a place typed with the " ..
      "record (a field `Seatbelt: Seatbelt`, an array `{Child}`, an assignment `Headers.Csp = Csp`) does not hold the " ..
      "module: a program requires the module where it uses it",
    fix = "make a value with a literal typed as <type>, or call a function of <type> that makes one; for a module, " ..
      "require it where it is used",
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
    fix = "read a field of a record, class, interface or userdata, an element of a collection `{T}` or `{K: V}`, or a function of a string (`s:upper()`); test a union down to the member that has the field first",
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
    code = "static_before_definition", rule = "compiler-written classes",
    why = "a `function R.m(...)` statement gives the table of R its function when it runs, in the order of the module, so a " ..
      "read of `R.m` or a call `v:m(...)` of a class that runs while the module loads, above that statement, finds nil: " ..
      "so does a function that reads it when the module calls that function, or hands it to code that may, as it loads",
    fix = "move the statement above the use, or use the function in a function that runs after the module has loaded",
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
    code = "cannot_infer", rule = "generic inference is local to the call",
    why = "a type parameter is solved at the call from the arguments and the type the call is expected to answer, and " ..
      "nothing outlives it, so a parameter neither gives has no type and the call cannot be checked",
    fix = "type the result (`local v: T = <f>(...)`), or pass an argument that has the type",
  },
  {
    code = "infer_conflict", rule = "generic inference is local to the call",
    why = "a type parameter is one type at a call: the arguments in covariant positions grow it to a type all are below, " ..
      "and an invariant position (a `mut` collection, a generic's argument, a map's key) fixes it exactly, so " ..
      "arguments that have no common type, or disagree with the exact one, are refused",
    fix = "pass values of one type to <f>, or convert the argument that differs",
  },
  {
    code = "bound_unmet", rule = "generic bodies compare, pass and store",
    why = "a type parameter bounded by an interface (`T is Ordered`) takes only the types that list it, since the body " ..
      "does with a `T` only what the interface declares; a type conforms to an interface only by listing it",
    fix = "list the interface in the declaration of <type> (`is <interface>`), or pass a type that does",
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
    code = "match_missing", rule = "multiple returns are a matched call",
    why = "the arms of a `match` cover the lists the call may answer exactly, so exhaustiveness is checked in one place " ..
      "and a list left out is found where the `match` is written and not when the call answers it",
    fix = "add the arm that takes the list: `| (false, v2) then ...`",
  },
  {
    code = "match_redundant", rule = "multiple returns are a matched call",
    why = "an arm runs only for a list no arm before it takes, so an arm that selects no list, or only lists an earlier " ..
      "arm takes, can never run",
    fix = "delete the arm, or change its `true` and `false` to select a list no arm before it takes",
  },
  {
    code = "match_pattern", rule = "multiple returns are a matched call",
    why = "`true` and `false` in a pattern select the lists whose value at that position is `true` or `false`, and a name " ..
      "binds the value there, so a position the lists lack or do not tell by `true` or `false` selects nothing, and an " ..
      "arm names each value of the lists it takes",
    fix = "write one pattern for each value of the lists the arm takes, `true` or `false` only where the lists have one",
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
    why = "a field or a key is given once: a second value for it would silently replace the first, and the program would " ..
      "run with a value it never wrote",
    fix = "remove the second <field>, or give the two different keys",
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
  {
    code = "missing_return", rule = "returns are checked against the declared list",
    why = "a function answers the values its return list declares, so a path that reaches its end answers none: " ..
      "its caller would read nil where a value was declared. A function declared `never` returns on no path",
    fix = "end every path with a `return` of <list> (or `error(...)`), or declare the function without a return list",
  },
  {
    code = "not_assigned", rule = "assigned before read",
    why = "`local x: T` with no value is legal only where every path assigns it before its first read, since a read " ..
      "of it before then is nil where `T` admits none; a function made while it is unset reads it, so it is read " ..
      "where the function is made",
    fix = "assign <name> on every path before the read, give it a value where it is declared, or declare it `T?`, " ..
      "which is nil until assigned and is checked where it is used",
  },
  {
    code = "unreachable", rule = "never is the bottom type",
    why = "a path that ends (a `return`, a `break` or `continue`, a call of a `never` function, a loop with no way " ..
      "out, a place narrowed to `never`) has no successor, so a statement after it is code that cannot run and is " ..
      "most often a mistake in the jump",
    fix = "remove the statement, or move it before the jump",
  },
  {
    code = "narrowing_dropped", rule = "narrowing only what nothing else can change",
    why = "a test narrows a local until the local is assigned, and an assignment of a value that may itself be nil says " ..
      "nothing of the new value, so a value that may be nil after the assignment is read where the test no longer holds",
    fix = "test it again after the assignment, or keep the value in a new local that is not assigned and test that",
  },
  {
    code = "narrows_unproved", rule = "narrowing declarations",
    why = "a callee's declaration `v is T` or `asserts v is T` tells every caller what to assume of its argument, so " ..
      "a function in Teal that makes it returns a test of the parameter that decides `T`, and one that asserts it " ..
      "returns only where the parameter is a `T`",
    fix = "return a test that decides <type> (`return v is T`, `return v.kind == \"...\"`), or declare the function " ..
      "`boolean`",
  },
  {
    code = "assign_repeated", rule = "narrowing only what nothing else can change",
    why = "`x, x = a, b` leaves the order of the two assignments open in Lua, so the value of `x` after it, and the fact " ..
      "a test held of it, would depend on an order the program does not fix",
    fix = "assign <name> once, or in two statements in the order you mean",
  },
  {
    code = "iterator_extra", rule = "calls take the arguments the function declares",
    why = "a generic `for` calls its iterator with a state and a control value; a fourth value after `in`, whether it is a " ..
      "fourth expression or one a call answers (any number of them, when it answers `T...`), is the value Lua closes when " ..
      "the loop ends, and it raises when that value has no `__close`",
    fix = "write at most three expressions after `in`, and name the values a call answers before the loop if it answers more",
  },
  {
    code = "iterator_variables", rule = "calls take the arguments the function declares",
    why = "a generic `for` binds the values its iterator answers, so a variable past them is always nil",
    fix = "name no more variables than the iterator answers values",
  },
  {
    code = "pattern_malformed", rule = "literals of the string library are read",
    why = "Lua reads a pattern, a replacement string and a format while it runs and raises where the literal is wrong, " ..
      "so a literal that no subject or value can make right is found where it is written",
    fix = "write the pattern, replacement or format Lua reads: <what>",
  },
  {
    code = "format_malformed", rule = "literals of the string library are read",
    why = "`string.format` raises on a conversion it does not know, on flags, a width or a precision the conversion does " ..
      "not take, and on a conversion with no value to format, so the literal is held to what Lua accepts",
    fix = "write a conversion Lua reads (`%d`, `%5.2f`, `%s`, `%q`, `%x`, `%c`, `%%`), and a value for each",
  },
  {
    code = "pack_malformed", rule = "literals of the string library are read",
    why = "`string.pack`, `unpack` and `packsize` raise on an option or a size they do not know, on an alignment that is " ..
      "not a power of 2 and on a missing value, and `packsize` on an option whose size depends on the value",
    fix = "write the options Lua reads (`b B h H i<n> I<n> l L j J T f d n s<n> z c<n> x X < > = !`), and a value for each " ..
      "that takes one",
  },
  {
    code = "gsub_key", rule = "literals of the string library are read",
    why = "`gsub` looks a match up in its table by the first capture, which is a string (the whole match, or the text of " ..
      "`( ... )`) or an integer (the position of `()`), so a table keyed by the other type finds nothing",
    fix = "declare the table with the key type the pattern captures: `{string: ...}` for text, `{integer: ...}` for `()`",
  },
  {
    code = "paren_is", rule = "narrowing declarations",
    why = "`is` narrows the place it is written on, and a parenthesized name is a value, so `(x) is T` tests and narrows " ..
      "nothing: the branch that relies on it sees `x` as wide as before",
    fix = "write the test without the parentheses: `<place> is <type>`",
  },
  {
    code = "type_name", rule = "narrowing only what nothing else can change",
    why = "`type` answers one of eight names, so a test against another is always false (or true for `~=`) and the branch " ..
      "it guards never runs: `type(x) == \"int\"` is the usual slip, since `type` answers \"number\" for an integer",
    fix = "compare with a name `type` answers; `math.type(x)` tells \"integer\" from \"float\", and `x is T` tests a type",
  },
  { code = "unchecked_binding", rule = "declarations are the trust boundary", why = WAITING,
    fix = "call the library function that wraps the binding (`cosmic docs <name>` names it) in place of the raw binding; the bindings of C are typed once the checker reads them from declaration files" },
}

function Codes.row(code: Codes.Code): Codes.Row?
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
