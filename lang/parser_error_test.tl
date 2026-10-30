--- The refusals of the new checker's parser ([`lang.parser`]): each code with
--- a source that raises it, the place of the token at fault and the fix, and
--- how the parser goes on past an error, so that one run reports several.
--- The trees the constructs make are in [`lang.parser_test`]. Every source
--- here is also held to [`lang.parser_cover`].
local Ast = require("lang.ast")
local Cover = require("lang.parser_cover")
local Dump = require("lang.ast_dump")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")

local record Case
  code: string
  source: string
  --- The place of the first error.
  y: integer
  x: integer
  --- A part of its message, and of its fix.
  says: string
  fix: string
  --- How many errors there are, when not one.
  count?: integer
  decl?: boolean
end

local function parse(source: string, dialect: Ast.Dialect): Parser.Parsed
  local parsed = Parser.parse(Lexer.lex(source, "t.tl"), "t.tl", dialect)
  local ok, why = Cover.check(source, parsed)
  assert(ok, why .. " in " .. source)
  return parsed
end

local CASES <const>: {Case} = {
  { code = "reserved_word", source = "local match = 1", y = 1, x = 7, says = "`match` is a reserved word", fix = "`matched`" },
  { code = "nil_union", source = "local x: T | nil", y = 1, x = 14, says = "`T | nil`", fix = "write `T?`" },
  { code = "nil_union", source = "local x: nil | A | B", y = 1, x = 10, says = "`nil | A | B`", fix = "write `(A | B)?`" },
  { code = "method_in_record", source = "local record R\n  function m(self) end\nend", y = 2, x = 3,
    says = "a record holds fields only", fix = "write `class` in place of `record`" },
  { code = "method_in_record", source = "function R:m() end", y = 1, x = 1,
    says = "`function R:m` is not in the grammar", fix = "inside its class as `function m(self, ...)`" },
  { code = "method_in_record", source = "local interface I\n  function m(self) end\nend", y = 2, x = 3,
    says = "an interface holds fields only", fix = "`name: function(self: I, ...): T`" },
  { code = "continue_outside_loop", source = "continue", y = 1, x = 1, says = "outside a loop", fix = "`while`, `for` or `repeat`" },
  { code = "continue_outside_loop", source = "while x do\n  local function g() continue end\nend", y = 2, x = 22,
    says = "outside a loop", fix = "of the same function" },
  { code = "break_outside_loop", source = "break", y = 1, x = 1, says = "outside a loop", fix = "`while`, `for` or `repeat`" },
  { code = "continue_skips_local", source = "repeat\n  if c then continue end\n  local y = 1\nuntil y", y = 3, x = 3,
    says = "`y` is declared after the `continue` on line 2", fix = "`until` reads `y`: declare it before the `repeat`" },
  { code = "continue_skips_local", source = "repeat\n  if c then continue end\n  local y = 1\nuntil done", y = 3, x = 3,
    says = "Lua cannot jump into the scope of a local of a `repeat` body", fix = "wrap the code from `local y` to the end of the body in `do ... end`" },
  { code = "unclosed", source = "if x then\n  foo()", y = 2, x = 8,
    says = "to close the `if` on line 1, found the end of the file", fix = "where the `if` on line 1 ends" },
  { code = "unclosed", source = "local function f()\n  if x then\n    foo()\n  end", y = 4, x = 6,
    says = "to close the function `f` on line 1", fix = "where the function `f` on line 1 ends" },
  { code = "unclosed", source = "local x = (1 + 2", y = 1, x = 17, says = "`)` to close the parenthesis on line 1", fix = "delete its `(`" },
  { code = "unclosed", source = "local t = { a = 1", y = 1, x = 18, says = "`}` to close the table on line 1", fix = "delete its `{`" },
  { code = "unclosed", source = "local x = f(1, 2", y = 1, x = 17, says = "`)` to close the call on line 1", fix = "where the call on line 1 ends" },
  { code = "unclosed", source = "repeat\n  x = 1\nend", y = 3, x = 1, count = 1, says = "`until` to close the `repeat` on line 1, found `end`", fix = "write `until`" },
  { code = "expected_token", source = "local a = t:m\n(1)", y = 2, x = 1, says = "expected the arguments of the call `:m`",
    fix = "write the call's arguments in parentheses" },
  { code = "expected_token", source = "if x\n  y()\nend", y = 2, x = 3, says = "expected `then`", fix = "if cond then ... end" },
  { code = "expected_name", source = "local x = y.\nlocal z = 1", y = 2, x = 1, says = "after `.`, found `local`", fix = "`[\"name\"]`" },
  { code = "expected_name", source = "local a = t.end", y = 1, x = 13, says = "found `end`", fix = "`[\"name\"]`" },
  { code = "expected_name", source = "local a = t:then()", y = 1, x = 13, says = "after `:`, found `then`", fix = "`[\"name\"]`" },
  { code = "trailing_comma", source = "local f = function(a: integer,) end", y = 1, x = 30, says = "list of parameters", fix = "delete the `,`" },
  { code = "trailing_comma", source = "local x: function(a: integer,)", y = 1, x = 29, says = "list of parameters", fix = "delete the `,`" },
  { code = "trailing_comma", source = "match f() do\n  | (true,) then g()\nend", y = 2, x = 10, says = "list of patterns", fix = "delete the `,`" },
  { code = "arm_on_same_line", source = "match f() do\n  | (true, v) then local x = v | (false, e) then error(e)\nend", y = 2, x = 32,
    says = "begins on the line of the arm before it", fix = "start each arm on its own line" },
  { code = "unreachable_arm", source = "match f() do\n  | (v) then g(v)\n  | (true, e) then error(e)\nend", y = 3, x = 5,
    says = "can never run", fix = "move the arm that matches every value" },
  { code = "unreachable_arm", source = "match f() do\n  | () then g()\n  | (false, e) then error(e)\nend", y = 3, x = 5,
    says = "can never run", fix = "move the arm that matches every value" },
  { code = "duplicate_binding", source = "match f() do\n  | (true, a, a) then g(a)\nend", y = 2, x = 15,
    says = "`a` is bound twice", fix = "`_` for one the arm does not use" },
  { code = "reserved_method", source = "local a = t:goto()", y = 1, x = 13, says = "`goto` is a reserved word in Lua 5.5",
    fix = "`obj[\"goto\"](obj, ...)`" },
  { code = "reserved_method", source = "t:global(1)", y = 1, x = 3, says = "`global` is a reserved word in Lua 5.5",
    fix = "`obj[\"global\"](obj, ...)`" },
  { code = "suffix_needs_parens", source = "local a = {}.z", y = 1, x = 13, says = "`{}` takes no `.` suffix", fix = "write `({})`" },
  { code = "nested_in_interface", source = "local interface I\n  record R\n    a: integer\n  end\nend", y = 2, x = 3,
    says = "cannot declare a `record` inside it", fix = "before the interface" },
  { code = "old_type_declaration", source = "local type X = record\n  a: integer\nend", y = 1, x = 16,
    says = "`type X = record` is not in the grammar", fix = "write `local record X ... end`" },
  { code = "narrowing_return", source = "local record R\n  f: function(v: any): v is T, integer\nend", y = 2, x = 24,
    says = "stands with others", fix = "write the narrowing alone" },
  { code = "method_path", source = "local class C\n  function C:bump(self) end\nend", y = 2, x = 12,
    says = "`C:bump` names its class", fix = "drop `C:` and write `self`" },
  { code = "unclosed", source = "local record R\n  a: integer\nlocal z = 1", y = 3, x = 1,
    says = "to close the `record R` on line 1, found `local`", fix = "delete its `record`" },
  { code = "label_or_goto", source = "for i = 1, 3 do goto continue end", y = 1, x = 17, says = "`goto continue`", fix = "write `continue`" },
  { code = "expected_name", source = "local 1", y = 1, x = 7, says = "expected a name for a local, found `1`", fix = "letters, digits and `_`" },
  { code = "expected_name", source = "local x = a.", y = 1, x = 13, says = "expected a field name after `.`", fix = "`[\"name\"]`" },
  { code = "expected_expression", source = "local x = ", y = 1, x = 11, says = "expected an expression, found the end of the file", fix = "write a value" },
  { code = "expected_type", source = "local x: ", y = 1, x = 10, says = "expected a type", fix = "`function(x: T): U`" },
  { code = "unexpected_token", source = "= 1", y = 1, x = 1, says = "unexpected `=` where a statement begins", fix = "begin the statement with one" },
  { code = "unexpected_token", source = "end", y = 1, x = 1, says = "unexpected `end`", fix = "or add what it ends" },
  { code = "unexpected_token", source = "local x: A<B>>", y = 1, x = 13, says = "`>>` closes one list", fix = "once for each `<` that is open" },
  { code = "not_a_statement", source = "x.y", y = 1, x = 1, says = "`x.y` is not a statement", fix = "call it, assign it" },
  { code = "bad_target", source = "f() = 1", y = 1, x = 1, says = "`f()` cannot be assigned to", fix = "a field `t.k` or an index `t[k]`" },
  { code = "statement_after_return", source = "return 1\nx = 2", y = 2, x = 1, says = "follows the `return` on line 1", fix = "write `do return end`" },
  { code = "chained_optional", source = "local x: T??", y = 1, x = 12, says = "`??`", fix = "write a single `?`" },
  { code = "chained_is", source = "local y = a is B is C", y = 1, x = 18, says = "`is` does not chain", fix = "`a is B and a is C`" },
  { code = "is_union", source = "local y = a is B | C", y = 1, x = 18, says = "`is` takes one type", fix = "`x is A or x is B`" },
  { code = "bare_function", source = "function f() end", y = 1, x = 1, says = "`function f(...)` declares a global", fix = "write `local function f(...)`" },
  { code = "bare_declaration", source = "record R\nend", y = 1, x = 1, says = "`record R` declares a type that nothing scopes", fix = "write `local record R`" },
  { code = "function_path", source = "function a.b.c() end", y = 1, x = 1, says = "more than one dot", fix = "`a.b.c = function(...) ... end`" },
  { code = "computed_require", source = "local m = require(name)", y = 1, x = 19, says = "`require(name)` names its module by an expression",
    fix = "write the module's name as a string: `require(\"cosmic.fs\")`" },
  { code = "computed_require", source = "local ok = pcall(require, \"a\" .. b)", y = 1, x = 27,
    says = "`pcall(require, \"a\" .. b)` names its module by an expression", fix = "`pcall(require, \"cosmic.fs\")`" },
  { code = "require_value", source = "local r = require\nlocal m = r(\"x\")", y = 1, x = 11, says = "`require` is read as a value here",
    fix = "call it: `require(\"cosmic.fs\")`" },
  { code = "require_value", source = "local m = (require)(\"x\")", y = 1, x = 12, says = "`require` is read as a value here",
    fix = "call it: `require(\"cosmic.fs\")`" },
  { code = "require_value", source = "local f: function(string): any = require", y = 1, x = 34, says = "`require` is read as a value here",
    fix = "call it: `require(\"cosmic.fs\")`" },
  { code = "require_value", source = "local ok = pcall((require), \"x\")", y = 1, x = 19, says = "`require` is read as a value here",
    fix = "call it: `require(\"cosmic.fs\")`" },
  { code = "require_value", source = "local ok = xpcall(require, print, \"x\")", y = 1, x = 19, says = "`require` is read as a value here",
    fix = "call it: `require(\"cosmic.fs\")`" },
  { code = "global_in_program", source = "global x = 1", y = 1, x = 1, says = "`global` declares a global", fix = "write `local`" },
  { code = "userdata_in_program", source = "local record R\n  userdata\nend", y = 2, x = 3, says = "`userdata` marks a record of a declaration file", fix = "`.d.tl` file" },
  { code = "userdata_in_program", source = "local interface I\n  userdata\nend", y = 2, x = 3, decl = true,
    says = "`userdata` marks a record", fix = "`.d.tl` file" },
  { code = "duplicate_field", source = "local record R\n  a: integer\n  a: string\nend", y = 3, x = 3,
    says = "the field `a` is declared twice", fix = "overloads, which repeat a function-typed field, are declared in a declaration file" },
  { code = "duplicate_field", source = "local record R\n  a: function()\n  a: string\nend", y = 3, x = 3, decl = true,
    says = "the field `a` is declared twice", fix = "give both a function type to declare overloads" },
  { code = "body_in_declaration", source = "local class C\n  function m(self) end\nend", y = 2, x = 3, decl = true,
    says = "no function bodies", fix = "`name: function(x: T): U`" },
  { code = "statement_in_declaration", source = "x = 1", y = 1, x = 1, decl = true, says = "a declaration file holds declarations", fix = "end with `return Name`" },
  { code = "mut_needs_collection", source = "local x: mut A", y = 1, x = 14, says = "`mut` applies to an array or a map type", fix = "`mut {T}` or `mut {K: V}`" },
  { code = "string_call", source = "local x = f\"s\"", y = 1, x = 12, says = "a string in place of its arguments", fix = "`f(\"s\")`" },
  { code = "variadic_type", source = "local x: function(T...)", y = 1, x = 20, says = "`T...` is not in the grammar", fix = "`...: T`" },
  { code = "optional_type", source = "local x: function(? T)", y = 1, x = 19, says = "`? T` is not in the grammar", fix = "write `name?: T`" },
  { code = "tuple_type", source = "local x: {A, B}", y = 1, x = 12, says = "a tuple type `{A, B}`", fix = "`{A | B}` for an array of either" },
  { code = "string_literal_type", source = "local x: \"a\"", y = 1, x = 10, says = "string-literal types are not in the grammar", fix = "declare an `enum`" },
  { code = "bare_function_type", source = "local x: function", y = 1, x = 18, says = "a bare `function` is not a type", fix = "write the signature: `function(x: T): U`" },
  { code = "metamethod", source = "local record R\n  metamethod __close: function(R)\nend", y = 2, x = 3,
    says = "`metamethod` is not in the grammar", fix = "write the field without it" },
  { code = "several_supers", source = "local record R is A, B\nend", y = 1, x = 20, says = "a record implements one interface", fix = "write one interface after `is`" },
  { code = "generic_function_literal", source = "local x = function<T>(a: T) end", y = 1, x = 19,
    says = "a function literal takes no type parameters", fix = "`local function f<T>(...)`" },
  { code = "bad_attribute", source = "local d <foo> = 1", y = 1, x = 10, says = "`<foo>` is not an attribute", fix = "`<const>`" },
  { code = "if_needs_else", source = "local x = if a then b end", y = 1, x = 23, says = "an `if` expression has no `else`", fix = "write `else <value>`" },
  { code = "match_needs_call", source = "match x do\n  | (true, v) then\nend", y = 1, x = 7, says = "`match` takes a call, found `x`", fix = "`match f(x) do" },
  { code = "close_repeated", source = "local a <close>, b <close> = nil, nil", y = 1, x = 18, says = "`b` is a second `<close>` local", fix = "statement of its own" },
  { code = "close_repeated", source = "local a, b <close>, c <close> = nil, nil, nil", y = 1, x = 21, says = "`c` is a second `<close>` local", fix = "statement of its own" },
  { code = "method_needs_self", source = "local class C\n  function m(a) end\nend", y = 2, x = 13, says = "first parameter of a method is `self`", fix = "`function m(self, ...)`" },
  { code = "too_deep", source = "local x = " .. ("("):rep(250) .. "1", y = 1, x = 210, says = "more than 200 levels of nesting", fix = "move an inner block into a function" },
  { code = "label_or_goto", source = "goto done", y = 1, x = 1, says = "`goto done` is not in the grammar", fix = "write `continue`" },
  { code = "label_or_goto", source = "goto = 1", y = 1, x = 1, says = "`goto` is not in the grammar", fix = "write `continue`" },
}

local function first_error(case: Case): Parser.Error
  local parsed = parse(case.source, if case.decl then "decl" else "tl" end)
  local e = parsed.errors[1]
  assert(e ~= nil, "no error for " .. case.source)
  assert(#parsed.errors == (case.count or 1), tostring(#parsed.errors) .. " errors for " .. case.source .. ", the first " .. e.code .. ": " .. e.msg)
  return e
end

local function test_each_refusal_has_its_code_its_place_and_its_fix()
  for _, case in ipairs(CASES) do
    local e = first_error(case)
    local what = case.code .. " for " .. case.source
    assert(tostring(e.code) == case.code, what .. ": got " .. e.code .. ": " .. e.msg)
    assert(e.y == case.y and e.x == case.x, what .. ": at " .. tostring(e.y) .. ":" .. tostring(e.x) .. ", not " .. tostring(case.y) .. ":" .. tostring(case.x))
    assert(e.msg:find(case.says, 1, true), what .. ": message " .. e.msg)
    assert(e.fix:find(case.fix, 1, true), what .. ": fix " .. e.fix)
    assert(e.filename == "t.tl")
  end
end

local function test_every_code_of_the_parser_has_a_case()
  local covered: mut {string: boolean} = {}
  for _, case in ipairs(CASES) do
    covered[case.code] = true
  end
  local lexer: mut {string: boolean} = {}
  for _, code in ipairs(Lexer.codes) do
    lexer[code] = true
  end
  for _, code in ipairs(Parser.codes) do
    assert(covered[code] or lexer[code], "no case for " .. code)
  end
end

local function test_the_parser_goes_on_past_an_error_to_the_next_statement()
  local parsed = parse("local x = = 1\nlocal y = 2\nlocal z: T | nil\nlocal w = 3", "tl")
  local codes: mut {string} = {}
  for i, e in ipairs(parsed.errors) do
    codes[i] = e.code
  end
  assert(table.concat(codes, " ") == "expected_expression nil_union", table.concat(codes, " "))
  local parts: mut {string} = {}
  for i, stat in ipairs(parsed.chunk.body.stats) do
    parts[i] = Dump.dump(stat)
  end
  assert(table.concat(parts, " ") ==
      "(Local \"local\" [(Binding \"x\")] _ [(Error)]) (Error) (Local \"local\" [(Binding \"y\")] _ [(Integer 2)]) " ..
      "(Local \"local\" [(Binding \"z\")] [(TypeUnion [(TypeName [\"T\"]) (TypeNil)])]) (Local \"local\" [(Binding \"w\")] _ [(Integer 3)])",
    table.concat(parts, " "))
end

--- The codes of the errors of `source`, space apart, and its statements as text.
local function outcome(source: string): string, string
  local parsed = parse(source, "tl")
  local codes: mut {string} = {}
  for i, e in ipairs(parsed.errors) do
    codes[i] = e.code
  end
  local parts: mut {string} = {}
  for i, stat in ipairs(parsed.chunk.body.stats) do
    parts[i] = Dump.dump(stat)
  end
  return table.concat(codes, " "), table.concat(parts, " ")
end

local function test_a_missing_end_names_the_construct_it_closes_and_its_line()
  local parsed = parse("local function f()\n  while x do\n    y()\n  end\n", "tl")
  local e = parsed.errors[1]
  assert(e ~= nil and #parsed.errors == 1 and e.code == "unclosed")
  assert(e.msg:find("function `f` on line 1", 1, true), e.msg)
  assert(e.y == 5 and e.x == 1, "at the end of the file")
end

local function test_a_missing_colon_in_a_field_still_reads_its_type()
  local codes, trees = outcome("local record R\n  a: integer\n  b integer\n  c: string\nend\nlocal x = 1")
  assert(codes == "expected_token", codes)
  assert(trees:find("(FieldDecl (Binding \"b\") _ _ (TypeName [\"integer\"]))", 1, true), trees)
  assert(trees:find("(FieldDecl (Binding \"c\")", 1, true) and trees:find("(Local \"local\" [(Binding \"x\")]", 1, true), trees)
end

local function test_a_missing_closer_leaves_the_next_statement_alone()
  local codes, trees = outcome("foo(1,\nlocal y = 2")
  assert(codes == "expected_expression", codes)
  assert(trees == "(CallStat (Call (Name \"foo\") [(Integer 1) (Error)])) (Local \"local\" [(Binding \"y\")] _ [(Integer 2)])", trees)
end

local function test_junk_is_skipped_to_the_next_statement_as_one_error()
  local codes, trees = outcome("while x do\n  ) ) )\n  y = 1\nend\nlocal v = 1")
  assert(codes == "unexpected_token", codes)
  assert(trees:find("(Block [(Error) (Assign [(Name \"y\")] [(Integer 1)])])", 1, true), trees)
end

local function test_the_errors_of_the_lexer_and_the_parser_come_in_source_order_and_a_lexical_error_is_reported_once()
  local source = "local a = @\nlocal b = 'c\nlocal c = 3 +\nlocal d = 4"
  local parsed = parse(source, "tl")
  local codes: mut {string} = {}
  for i, e in ipairs(parsed.errors) do
    codes[i] = e.code
  end
  assert(table.concat(codes, " ") == "stray_byte unterminated_string expected_expression", table.concat(codes, " "))
  local expected = parsed.chunk.body.stats[4]
  assert(expected ~= nil and expected.kind == "Local", "the statement after the errors is intact")
end

local function test_input_nested_past_the_limit_is_refused_not_overflowed()
  local depth = 300
  local sources: {string} = {
    "local x = " .. ("("):rep(depth) .. "1" .. (")"):rep(depth),
    ("do "):rep(depth) .. ("end "):rep(depth),
    "local x: " .. ("{"):rep(depth) .. "A" .. ("}"):rep(depth),
    "local x = " .. ("- "):rep(depth) .. "1",
    "local x = a" .. (" .. a"):rep(depth),
    "local x = " .. ("f("):rep(depth) .. (")"):rep(depth),
    "local x = " .. ("{"):rep(depth) .. ("}"):rep(depth),
    ("if a then "):rep(depth) .. ("end "):rep(depth),
  }
  for i, source in ipairs(sources) do
    local parsed = parse(source, "tl")
    local first = parsed.errors[1]
    assert(first ~= nil and first.code == "too_deep", "source " .. tostring(i) .. " is refused")
    assert(#parsed.errors == 1, "source " .. tostring(i) .. ": " .. tostring(#parsed.errors) .. " errors, the rest is not reported")
  end
  local ok = parse("local x = " .. ("("):rep(150) .. "1" .. (")"):rep(150), "tl")
  assert(#ok.errors == 0, "150 levels are fine")
end

local function test_a_declaration_file_holds_only_what_the_draft_lists()
  local good: {string} = {
    "local x = require(\"m\")\nlocal type t = require(\"n\")\nlocal record R\nend\nreturn R",
    "global assert <const> = Library.assert\nglobal record io\nend\ndo\n  local enum E \"a\" end\nend",
  }
  for _, source in ipairs(good) do
    assert(#parse(source, "decl").errors == 0, source)
  end
  local bad: {string} = {
    "local x = 1", "local x, y = require(\"m\")", "local x: T = require(\"m\")", "return 1", "return a, b",
    "do\n  return R\nend", "x = 1", "f()", "if x then end",
  }
  for _, source in ipairs(bad) do
    local e = parse(source, "decl").errors[1]
    assert(e ~= nil and e.code == "statement_in_declaration", "refused: " .. source)
  end
  assert(#parse("local x = 1\nreturn x", "tl").errors == 0, "a program may")
  local body = parse("global f <const> = function() end", "decl")
  local refusal = body.errors[1]
  assert(refusal ~= nil and refusal.code == "body_in_declaration", "no body in a declaration file")
end
