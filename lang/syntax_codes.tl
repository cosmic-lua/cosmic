--- The rule behind each code of the lexer ([`lang.lexer`]), the parser ([`lang.parser`]), the scope builder
--- ([`lang.scopes`]) and the generator ([`lang.codegen`]), as [`lang.check_codes`] holds it for the checker's: the rule
--- the code stands for, why the language holds it, and the fix with the placeholders `<...>` the error fills from the
--- program. `cosmic docs <code>` and the error read alike ([`build.error_catalog`]).
---
--- A code of the parser's list that the lexer also reports (`semicolon`) has one row, under the stage that finds it first.
local record SyntaxCodes
  --- The stage whose error it is.
  enum Stage
    "lexer"
    "parser"
    "scopes"
    "generator"
  end

  --- The rule behind a code.
  record Row
    code: string
    stage: Stage
    --- The rule, named for what it holds.
    rule: string
    --- Why the language holds it.
    why: string
    --- What the fix says, with the placeholders `<...>` the error fills from the program.
    fix: string
  end

  --- The rule behind each code of the four stages, the lexer's first, then the parser's, the scope builder's and the
  --- generator's, each in the order of its module's list of codes.
  catalog: {Row}

  --- The row of `code`, or nil.
  row: function(code: string): Row?
end

local GRAMMAR <const> = "the syntactic grammar"
local LEFT_OUT <const> = "what the grammar leaves out"
local LEXICAL <const> = "the lexical grammar"
local NAMESPACE <const> = "one namespace, a space per binding"

SyntaxCodes.catalog = {
  -- the lexer
  {
    code = "label_or_goto", stage = "lexer", rule = LEFT_OUT,
    why = "a label and a `goto` have no form but the `continue` that replaces `goto continue`",
    fix = "delete the label, and write `continue` where a `goto <label>` skipped the rest of a pass of a loop; restructure " ..
      "any other jump with an `if` around the code to skip, or move the code into a function and `return` from it",
  },
  {
    code = "semicolon", stage = "lexer", rule = LEFT_OUT,
    why = "a statement needs no terminator and the fields of a table are separated by `,`, so a `;` is a second spelling " ..
      "of what is already written",
    fix = "delete the `;`: a statement needs no terminator and the fields of a table are separated by `,`",
  },
  {
    code = "long_comment", stage = "lexer", rule = LEFT_OUT,
    why = "a long comment `--[[ ... ]]` has no form: a comment is a line comment",
    fix = "write each line of the comment after its own `--`",
  },
  {
    code = "unterminated_long_comment", stage = "lexer", rule = LEXICAL,
    why = "a long comment without its closing bracket runs to the end of the file and hides every statement after it",
    fix = "close the comment with the bracket that opened it, or write it as line comments",
  },
  {
    code = "digit_separator", stage = "lexer", rule = LEFT_OUT,
    why = "a `_` between digits is another spelling of the same number, which Lua does not read",
    fix = "write the number without `_`: `<digits>`",
  },
  {
    code = "hex_float", stage = "lexer", rule = LEFT_OUT,
    why = "a hexadecimal float is a number whose value a reader cannot see, and the language has no use for it",
    fix = "write the value in decimal: `<value>`",
  },
  {
    code = "malformed_number", stage = "lexer", rule = LEXICAL,
    why = "Lua reads the numeral as one token and cannot convert it, so it has no value",
    fix = "write a decimal or hexadecimal numeral Lua can convert, with no letters after its digits",
  },
  {
    code = "unterminated_string", stage = "lexer", rule = LEXICAL,
    why = "a short string ends on its line, so a quote left out takes the rest of the line into the string",
    fix = "close the string with the quote it opened with, or write a long string `[[...]]` for text across lines",
  },
  {
    code = "unterminated_long_string", stage = "lexer", rule = LEXICAL,
    why = "a long string without its closing bracket runs to the end of the file and hides every statement after it",
    fix = "close the string with the bracket that opened it",
  },
  {
    code = "bad_escape", stage = "lexer", rule = GRAMMAR,
    why = "a backslash that is no escape of a short string is a mistake in the program, found where it is written",
    fix = "write one of the escapes (`\\n`, `\\t`, `\\\\`, `\\\"`, `\\'`, `\\xXX`, `\\ddd`, `\\u{XXX}`, `\\z`), or double the " ..
      "backslash to write one",
  },
  {
    code = "stray_byte", stage = "lexer", rule = LEXICAL,
    why = "a byte that begins no token is no part of the language, so the rest of the line cannot be read",
    fix = "delete it, or write it inside a string",
  },
  -- the parser
  {
    code = "reserved_word", stage = "parser", rule = GRAMMAR,
    why = "a reserved word begins a statement or an expression, so a name that is one could not be told from the grammar",
    fix = "rename <what>, for example `<name>_`; the word stays legal as a field name: `t.<word>`, `s:<word>(x)`",
  },
  {
    code = "nil_union", stage = "parser", rule = LEFT_OUT,
    why = "a type that may be nil is written `T?`, one spelling, so `T | nil` is not a second",
    fix = "write `<type>?`",
  },
  {
    code = "method_in_record", stage = "parser", rule = LEFT_OUT,
    why = "a method is declared in a class, with `function name(self, ...)`, and a record or interface declares it as a " ..
      "field whose function names its receiver",
    fix = "write `class` in place of `record` and declare the method inside it as `function <method>(self, ...)`, or declare " ..
      "it as a field: `<method>: function(self: <type>, ...): <result>`",
  },
  {
    code = "continue_outside_loop", stage = "parser", rule = GRAMMAR,
    why = "`continue` skips the rest of a pass of the loop around it, and outside a loop of its own function there is none",
    fix = "move it into the body of a `while`, `for` or `repeat` of the same function; to leave a function write `return`",
  },
  {
    code = "break_outside_loop", stage = "parser", rule = GRAMMAR,
    why = "`break` leaves the loop around it, and outside a loop of its own function there is none",
    fix = "move it into the body of a `while`, `for` or `repeat`, or `return` to leave a function",
  },
  {
    code = "continue_skips_local", stage = "parser", rule = GRAMMAR,
    why = "Lua cannot jump into the scope of a local, and the `until` of a `repeat` is inside the scope of the locals of its " ..
      "body, so a `continue` that skips a local the `until` reads has no place to go",
    fix = "wrap the code from `local <name>` to the end of the body in `do ... end`, or declare <name> before the `repeat`",
  },
  {
    code = "unclosed", stage = "parser", rule = GRAMMAR,
    why = "a closer is missing, so the program ends inside a construct",
    fix = "write `<closer>` where the <construct> on line <n> ends, or delete its `<opener>`",
  },
  {
    code = "expected_token", stage = "parser", rule = GRAMMAR,
    why = "a token the grammar needs is missing or in the wrong place, so the rest of the statement is not read",
    fix = "write the token the message names (`then`, `do`, `end`, `)`, `,`) just before the token found, or delete the token found if it belongs to no statement here",
  },
  {
    code = "expected_name", stage = "parser", rule = GRAMMAR,
    why = "the program has no name where the grammar needs one",
    fix = "write a name: letters, digits and `_`, not beginning with a digit, and not a reserved word",
  },
  {
    code = "expected_expression", stage = "parser", rule = GRAMMAR,
    why = "the program has no expression where the grammar needs one",
    fix = "write a value: a name, a number, a string, `nil`, `true`, `false`, a table `{ ... }`, a call, or " ..
      "`function(...) ... end`",
  },
  {
    code = "expected_type", stage = "parser", rule = GRAMMAR,
    why = "the program has no type where the grammar needs one",
    fix = "write a type: a name like `string` or `Reader`, `{T}`, `{K: V}`, `function(x: T): U`, `nil`, `true` or `false`",
  },
  {
    code = "unexpected_token", stage = "parser", rule = GRAMMAR,
    why = "a token no statement begins with is a mistake of the program",
    fix = "delete it, or write the statement it belongs to",
  },
  {
    code = "not_a_statement", stage = "parser", rule = GRAMMAR,
    why = "an expression that is no call is no statement, and an assignment to what is no place assigns nothing",
    fix = "call it, assign it (`local x = ...`), or delete it",
  },
  {
    code = "bad_target", stage = "parser", rule = GRAMMAR,
    why = "an assignment to what is no place assigns nothing",
    fix = "assign to a name, a field `t.k` or an index `t[k]`",
  },
  {
    code = "statement_after_return", stage = "parser", rule = GRAMMAR,
    why = "a statement after `return` never runs, and a `return` that has no statement to end is a mistake of the program",
    fix = "move the `return` to the end of the block, or write `do return end` to leave early",
  },
  {
    code = "chained_optional", stage = "parser", rule = LEFT_OUT,
    why = "`T?` already admits nil, so a second `?` says nothing",
    fix = "write a single `?`",
  },
  {
    code = "chained_is", stage = "parser", rule = GRAMMAR,
    why = "`a is B` is a boolean, so `a is B is C` tests a boolean and not `a`",
    fix = "test each apart: `a is B and a is C`",
  },
  {
    code = "is_union", stage = "parser", rule = GRAMMAR,
    why = "`is` tests one type, and a union or an optional is several at once",
    fix = "test each type apart: `x is A or x is B`; for a value that may be nil write `x ~= nil and x is A`",
  },
  {
    code = "bare_function", stage = "parser", rule = LEFT_OUT,
    why = "`function f()` and `record R` with no `local` declare a global, which a program does not: a declaration file does",
    fix = "write `local function <name>(...)`; a program's globals are the ones a declaration file declares",
  },
  {
    code = "bare_declaration", stage = "parser", rule = LEFT_OUT,
    why = "`record R` with no `local` declares a type that nothing scopes, which a program does not: a declaration file does",
    fix = "write `local <kind> <name>`; a declaration file writes `global`",
  },
  {
    code = "function_path", stage = "parser", rule = LEFT_OUT,
    why = "`function a.b.c()` with a path longer than a record and a name has no form: a function is declared on a record " ..
      "or class, or is local",
    fix = "assign the function to the field: `<path> = function(...) ... end`",
  },
  {
    code = "global_in_program", stage = "parser", rule = LEFT_OUT,
    why = "`global` declares a name for every module, which only a declaration file may do",
    fix = "write `local`; a program's globals are exactly the ones a declaration file (`.d.tl`) declares",
  },
  {
    code = "userdata_in_program", stage = "parser", rule = LEFT_OUT,
    why = "`userdata` declares a value made by C, which only a declaration file may do",
    fix = "delete it; a program's types are tables, and a userdata type is declared in a `.d.tl` file",
  },
  {
    code = "duplicate_field", stage = "parser", rule = GRAMMAR,
    why = "a field declared twice outside the overloads of a declaration file leaves one of them unreachable",
    fix = "delete one, or give both a function type to declare overloads in a declaration file",
  },
  {
    code = "body_in_declaration", stage = "parser", rule = GRAMMAR,
    why = "a declaration file declares types and values and has no code to run",
    fix = "declare the function's type: `<name>: function(x: T): U`",
  },
  {
    code = "statement_in_declaration", stage = "parser", rule = GRAMMAR,
    why = "a declaration file declares types and values and has no code to run",
    fix = "declare types and values: `local record R ... end`, `global f <const> = ...`, `local x = require(\"m\")`, and end " ..
      "with `return Name`",
  },
  {
    code = "mut_needs_collection", stage = "parser", rule = LEFT_OUT,
    why = "`mut` marks a collection the callee may change, and no other type has elements to change",
    fix = "write `mut {T}` or `mut {K: V}`; a field that is reassigned is `mut <name>: T`",
  },
  {
    code = "string_call", stage = "parser", rule = LEFT_OUT,
    why = "`f 'x'` and `f [[x]]` have no form: a call has parentheses",
    fix = "put the string in parentheses: `<callee>(<string>)`",
  },
  {
    code = "variadic_type", stage = "parser", rule = LEFT_OUT,
    why = "a rest parameter is written `...: T`, one spelling, so `T...` is not a second",
    fix = "write the rest parameter `...: <type>`",
  },
  {
    code = "optional_type", stage = "parser", rule = LEFT_OUT,
    why = "a parameter is made omittable by its name, `name?: T`, one spelling, so `? T` is not a second",
    fix = "write `<name>?: <type>`, naming the parameter",
  },
  {
    code = "tuple_type", stage = "parser", rule = LEFT_OUT,
    why = "a tuple type has no form: a function answers values or a record answers a record",
    fix = "write a record with a field for each position, or `{A | B}` for an array of either",
  },
  {
    code = "string_literal_type", stage = "parser", rule = LEFT_OUT,
    why = "a string literal as a type has no form: the strings a value may be are an enum",
    fix = "declare an `enum` of the strings and use its name as the type",
  },
  {
    code = "bare_function_type", stage = "parser", rule = LEFT_OUT,
    why = "`function` alone says nothing of its parameters or results, so a caller could not be checked",
    fix = "write the signature: `function(x: T): U`, and `function()` for a function with no parameters",
  },
  {
    code = "metamethod", stage = "parser", rule = LEFT_OUT,
    why = "a metamethod is a field of the record or a method of the class that has it, and needs no word of its own",
    fix = "write the field without `metamethod`: `<name>: function(self: T)`, or a method `function <name>(self)` of a class",
  },
  {
    code = "several_supers", stage = "parser", rule = LEFT_OUT,
    why = "a type implements one interface, and an interface that extends several is itself an interface",
    fix = "write one interface after `is`; a new interface that extends both can be implemented instead",
  },
  {
    code = "generic_function_literal", stage = "parser", rule = LEFT_OUT,
    why = "a type parameter on a function literal has no form: the generic function is a declaration, and its literal takes " ..
      "the types of the declaration",
    fix = "declare a generic function with `local function <name><T>(...)`, or write the literal without `<T>`",
  },
  {
    code = "bad_attribute", stage = "parser", rule = LEFT_OUT,
    why = "an attribute other than `<const>` and `<close>` (`<total>`) has no form in the new grammar, so the program is " ..
      "not one",
    fix = "write `<const>` for a local that is not reassigned or `<close>` for one that is closed at the end of its block",
  },
  {
    code = "if_needs_else", stage = "parser", rule = GRAMMAR,
    why = "an `if` that gives a value gives one on every path, so it has an `else`",
    fix = "write `else <value>` before `end`; to run statements on a condition, write an `if` statement",
  },
  {
    code = "close_repeated", stage = "parser", rule = GRAMMAR,
    why = "a declaration of several locals holds at most one `<close>`, as Lua 5.4 reads it: the Lua written for two would not load",
    fix = "declare each `<close>` local in a statement of its own",
  },
  {
    code = "match_needs_call", stage = "parser", rule = GRAMMAR,
    why = "a `match` selects among the lists of values a call may answer, so what it takes is a call",
    fix = "call a function that returns a union of value lists: `match f(x) do | (true, v) then ... end`; to branch on a " ..
      "value write an `if`",
  },
  {
    code = "method_needs_self", stage = "parser", rule = GRAMMAR,
    why = "a method of a class takes its receiver as `self`, without a type, so a caller reads it as `obj:name()`",
    fix = "write `function <name>(self, ...)`",
  },
  {
    code = "method_path", stage = "parser", rule = GRAMMAR,
    why = "a method is named by its own name inside its class, and the class is the one it is written in",
    fix = "write `function <method>(self, ...)`: drop `<owner>.` and write `self` as the first parameter",
  },
  {
    code = "trailing_comma", stage = "parser", rule = GRAMMAR,
    why = "a comma separates two items, so one with nothing after it is a mistake",
    fix = "delete the `,` before the closer",
  },
  {
    code = "arm_on_same_line", stage = "parser", rule = GRAMMAR,
    why = "an arm of a `match` begins its line, so that the arms read as a column",
    fix = "start each arm on its own line",
  },
  {
    code = "unreachable_arm", stage = "parser", rule = GRAMMAR,
    why = "an arm after one that matches every value never runs",
    fix = "delete the arm, or move the arm that matches every value (`| (a, b) then`, with no `true` or `false`) to the end",
  },
  {
    code = "duplicate_binding", stage = "parser", rule = GRAMMAR,
    why = "a name bound twice in one arm names two values, and the second hides the first",
    fix = "give each value of the pattern a name of its own, or `_` for one the arm does not use",
  },
  {
    code = "reserved_method", stage = "parser", rule = GRAMMAR,
    why = "Lua 5.5 reserves the word, so `obj:<word>()` is not read as a call",
    fix = "call it as a field of the object: `obj[\"<word>\"](obj, ...)`, or rename the method",
  },
  {
    code = "suffix_needs_parens", stage = "parser", rule = GRAMMAR,
    why = "only a name or a parenthesized expression takes a call, an index or a field, as in Lua",
    fix = "write `(<expression>)` and then the suffix",
  },
  {
    code = "nested_in_interface", stage = "parser", rule = GRAMMAR,
    why = "an interface holds fields only, so a type declared inside it would have no owner but a list of fields",
    fix = "declare the type before the interface, and name it in the type of a field",
  },
  {
    code = "old_type_declaration", stage = "parser", rule = LEFT_OUT,
    why = "a record, interface, class or enum is declared with its own word, one spelling, so `type X = record` is not a second",
    fix = "write `<scope> <kind> <name> ... end`",
  },
  {
    code = "narrowing_return", stage = "parser", rule = GRAMMAR,
    why = "a function that narrows its argument returns the narrowing and nothing else, so a caller reads one test",
    fix = "write the narrowing alone, `v is T` or `asserts v is T`, and return the other values by another function",
  },
  {
    code = "too_deep", stage = "parser", rule = GRAMMAR,
    why = "blocks, expressions and types nest to a depth the readers of a program (and the parser's own stack) can follow",
    fix = "split the code: name an inner expression with a `local`, or move an inner block into a function",
  },
  {
    code = "computed_require", stage = "parser", rule = LEFT_OUT,
    why = "the build reads a module's dependencies from the literal names handed to `require` and to `pcall(require, ...)`, " ..
      "so a name computed at run time is a module that no key, closure or sealed program holds",
    fix = "write the name as a string literal, `require(\"<module>\")` or `pcall(require, \"<module>\")`; to choose between " ..
      "modules, require each by its literal name and pick from a table",
  },
  {
    code = "require_value", stage = "parser", rule = LEFT_OUT,
    why = "`require` is a special form of the build, read where it is called directly or handed to `pcall` as its first " ..
      "argument, so a `require` kept in a variable, in parentheses or in another call's arguments is a load the build cannot see",
    fix = "call it by name, `require(\"<module>\")`, or write `pcall(require, \"<module>\")`; to choose between modules, " ..
      "require each by its literal name and pick from a table",
  },
  -- the scope builder
  {
    code = "unknown_variable", stage = "scopes", rule = "globals are what a declaration file declares",
    why = "a name that no binding and no declared global holds reads nil at run time, so the typo is found where it is " ..
      "written",
    fix = "declare it with `local <name> = ...` above this use, or require its module with `local <name> = " ..
      "require(\"...\")`; a program has no globals except the ones a declaration file declares",
  },
  {
    code = "unknown_type", stage = "scopes", rule = "types may be declared later in a signature or a type",
    why = "a type name that no binding, declared global or primitive holds names no type",
    fix = "declare it above with `local record <name> ... end`, `local enum <name> ... end` or `local type <name> = ...`, or " ..
      "import it with `local type <name> = require(\"...\")`",
  },
  {
    code = "shadows", stage = "scopes", rule = "a name is declared once where it is visible",
    why = "a declaration whose name is visible hides the earlier one, and a reader takes the first for the second",
    fix = "rename the new <name>; the old one, declared at <place>, stays visible under its own name",
  },
  {
    code = "const_assigned", stage = "scopes", rule = "read-only",
    why = "an assignment to a `<const>` or `<close>` variable or a loop's control variable is refused by Lua 5.5, and the " ..
      "checker says why before the compiler does",
    fix = "declare <name> without `<const>` if it changes, or assign a new local",
  },
  {
    code = "not_a_value", stage = "scopes", rule = NAMESPACE,
    why = "a type used as a value is the table of its functions, which the program cannot use as a value of the type",
    fix = "write <name> where a type goes (`x: <name>`) and a variable or a literal where a value goes",
  },
  {
    code = "not_a_type", stage = "scopes", rule = NAMESPACE,
    why = "a parameter, a loop variable, a function or a local that holds no module names no type",
    fix = "declare the type instead of the variable: `local type <name> = <module>.<type>`",
  },
  {
    code = "unknown_parameter", stage = "scopes", rule = NAMESPACE,
    why = "a narrowing return tells callers what to assume of one of the function's parameters, so it names one",
    fix = "write the name of a parameter before `is`: `v is T` or `asserts v is T` for a parameter `v`",
  },
  {
    code = "env_reserved", stage = "scopes", rule = NAMESPACE,
    why = "`_ENV` is the environment of Lua's own globals, which a program does not have, so a program neither declares " ..
      "nor assigns it",
    fix = "name it something other than `_ENV`: a program has no environment table to replace, so it never needs the name",
  },
  {
    code = "primitive_type_name", stage = "scopes", rule = NAMESPACE,
    why = "a primitive type name is never a binding, so a type declared with one would be unreachable",
    fix = "rename the <kind>, for example to `<Name>`: in a type, `<name>` always means the primitive",
  },
  -- the generator
  {
    code = "class_nested_refused", stage = "generator", rule = "what the generator writes",
    why = "a `class` has a table of its own at run time, which a class declared inside another type would have no place for",
    fix = "declare the class at the top level of the file, and name it in the type of the field that holds it",
  },
}

function SyntaxCodes.row(code: string): SyntaxCodes.Row?
  for _, r in ipairs(SyntaxCodes.catalog) do
    if r.code == code then
      return r
    end
  end
  return nil
end

return SyntaxCodes
