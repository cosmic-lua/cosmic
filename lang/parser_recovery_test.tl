--- How the new checker's parser ([`lang.parser`]) reads the forms that are
--- nearly the grammar's and the programs that are cut short: which word is a
--- field name, which comma ends a list, what a `|` at the start of a line
--- is, what a missing `end` is blamed on, and the refusals that carry a
--- second place. The table of codes is in [`lang.parser_error_test`]. Every
--- source here is held to [`lang.parser_cover`].
local Ast = require("lang.ast")
local Cover = require("lang.parser_cover")
local Dump = require("lang.ast_dump")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")

local function parse(source: string, dialect?: Ast.Dialect): Parser.Parsed
  local parsed = Parser.parse(Lexer.lex(source, "t.tl"), "t.tl", dialect or "tl")
  local ok, why = Cover.check(source, parsed)
  assert(ok, why .. " in " .. source)
  return parsed
end

--- The codes of the errors of `parsed`, space apart.
local function codes(parsed: Parser.Parsed): string
  local out: mut {string} = {}
  for i, e in ipairs(parsed.errors) do
    out[i] = e.code
  end
  return table.concat(out, " ")
end

--- The statements of `parsed` as text.
local function tree(parsed: Parser.Parsed): string
  local out: mut {string} = {}
  for i, stat in ipairs(parsed.chunk.body.stats) do
    out[i] = Dump.dump(stat)
  end
  return table.concat(out, " ")
end

local function clean(source: string, dialect?: Ast.Dialect): string
  local parsed = parse(source, dialect)
  assert(#parsed.errors == 0, codes(parsed) .. ": " .. (parsed.errors[1] and parsed.errors[1].msg or "") .. " in " .. source)
  return tree(parsed)
end

local function the_error(source: string, code: string): Parser.Error
  local parsed = parse(source)
  assert(codes(parsed) == code, "expected " .. code .. ", found [" .. codes(parsed) .. "] in " .. source)
  return parsed.errors[1]
end

local function has(text: string, part: string, what: string)
  assert(text:find(part, 1, true), what .. ": `" .. part .. "` not in `" .. text .. "`")
end

-- field names

local function test_a_dangling_dot_does_not_take_the_next_line_for_a_field()
  local parsed = parse("local x = y.\nlocal z = 1")
  assert(codes(parsed) == "expected_name", codes(parsed))
  has(tree(parsed), "(Local \"local\" [(Binding \"z\")] _ [(Integer 1)])", "the next statement is whole")
  assert(#parsed.chunk.body.stats == 2)
end

local function test_a_lua_keyword_is_no_field_name_and_the_words_the_grammar_reserves_are()
  for _, source in ipairs({ "x = t.end", "x = t:then()", "x = t.local", "x = { end = 1 }", "t.function = 1", "x = t.nil" }) do
    local parsed = parse(source)
    assert(parsed.errors[1] ~= nil, source)
  end
  clean("x = t.match + t.continue + t.mut + t.is + t.as + t.asserts + t.userdata + t.goto + t.global")
  clean("t:match(p)\nt.goto()\nx = { match = 1, goto = 2, global = 3, as = 4 }")
  clean("local record R\n  match: integer\n  goto?: string\n  mut global: T\nend")
end

-- lists

local function test_a_trailing_comma_is_refused_in_parameters_types_and_patterns_and_a_table_may_end_in_one()
  for _, source in ipairs({
      "local f = function(a, b,) end", "local function f(a: integer,) end", "local x: function(a: integer,)",
      "local x: function(a: integer, ...: any,)", "match f() do\n  | (true, v,) then g()\nend",
  }) do
    local e = the_error(source, "trailing_comma")
    has(e.fix, "delete the `,`", source)
  end
  clean("local t = { 1, 2, }")
  local call = parse("f(a, b,)")
  assert(call.errors[1] ~= nil and call.errors[1].code == "expected_expression", "a call has a value to give")
end

local function test_a_table_item_on_the_next_line_without_a_comma_says_to_add_one()
  local parsed = parse("local t = {\n  a = 1\n  b = 2,\n  [3] = 4\n  5\n}")
  assert(codes(parsed) == "expected_token expected_token", codes(parsed))
  has(parsed.errors[1].fix, "add a `,`", "fix")
  assert(parsed.errors[1].y == 3 and parsed.errors[2].y == 5)
  has(tree(parsed), "(Table [(Named \"a\" (Integer 1)) (Named \"b\" (Integer 2)) (Keyed (Integer 3) (Integer 4)) (Positional (Integer 5))])", "all items")
end

-- a declaration or enum that is not closed

local UNCLOSED <const>: {string} = {
  "local record R\n  a: integer\nlocal z = 1",
  "local interface R\n  a: integer\nlocal function z() end",
  "local class R\n  a: integer\n  function m(self) end\nif z then end",
  "local class R\n  a: integer\nfunction R.f() end",
  "local record R\n  a: integer\nreturn R",
  "local enum R\n  \"a\"\n  \"b\"\nfor i = 1, 2 do end",
  "local enum R\n  \"a\"\n  b c d\n  \"e\"\nwhile x do end",
}

local function test_a_declaration_that_is_not_closed_ends_at_the_statement_after_it_and_is_blamed_once()
  for _, source in ipairs(UNCLOSED) do
    local parsed = parse(source)
    assert(codes(parsed) == "unclosed" or (codes(parsed) == "expected_token unclosed" and source:find(" b c d", 1, true)),
      codes(parsed) .. " for " .. source)
    local e = parsed.errors[#parsed.errors]
    has(e.msg, "R` on line", source)
    assert(e.msg:find("`record R`", 1, true) or e.msg:find("`interface R`", 1, true) or e.msg:find("`class R`", 1, true) or
        e.msg:find("`enum R`", 1, true), "names the construct, not `local`: " .. e.msg)
    assert(not e.msg:find("`local R`", 1, true))
    local other = e.other
    assert(other ~= nil and other.y == 1, "the opener's place")
    assert(#parsed.chunk.body.stats == 2, "the statement after it is a statement of the chunk: " .. source)
  end
end

local function test_a_method_of_a_class_is_not_taken_for_the_statement_after_it()
  assert(clean("local class C\n  function m(self) end\n  function n(self) return 1 end\nend"):find("(Method", 1, true))
end

-- match arms

local function test_a_bar_inside_brackets_or_before_anything_but_a_paren_continues_the_expression()
  local arms = {
    "local x = (a\n      | b)",
    "local x = {A\n      | B}",
    "f(a\n      | b)",
    "f(a\n      | (b))",
    "local t: A\n      | B",
    "local x = a\n      | b",
  }
  for _, body in ipairs(arms) do
    local source = "match f() do\n  | (true, v) then\n    " .. body .. "\n  | (false, e) then error(e)\nend"
    local stat = parse(source).chunk.body.stats[1]
    assert((stat.kind == "Match") and #stat.arms == 2, "two arms: " .. body)
    assert(codes(parse(source)) == "", "no error: " .. body)
  end
end

local function test_a_bar_and_a_paren_that_begin_a_line_in_an_arm_begin_the_next_arm()
  local parsed = parse("match f() do\n  | (true, v) then\n    local x = a\n    return x\n  | (false, e) then error(e)\nend")
  assert(codes(parsed) == "")
  local source = "match f() do\n  | (true, v) then\n    local x = a\n    | (b)\nend"
  local e = the_error(source, "expected_token")
  has(e.fix, "an expression that goes on to the next line keeps its operator at the end of the line before", "the hint")
end

local function test_a_function_literal_in_an_arm_has_the_union_of_lists_of_its_own_signature()
  local source = "match f() do\n  | (true, v) then local g = function(): (true, A)\n    | (false, B)\n    return end\n  | (false, e) then h()\nend"
  local parsed = parse(source)
  assert(codes(parsed) == "", codes(parsed))
  has(tree(parsed), "(Rets [[(TypeBool true) (TypeName [\"A\"])] [(TypeBool false) (TypeName [\"B\"])]])", "two lists")
  local stat = parsed.chunk.body.stats[1]
  assert((stat.kind == "Match") and #stat.arms == 2)
end

local function test_two_arms_on_a_line_are_refused_and_read_as_two()
  local parsed = parse("match f() do\n  | (true, v) then local x = v | (false, e) then error(e)\nend")
  assert(codes(parsed) == "arm_on_same_line", codes(parsed))
  has(parsed.errors[1].fix, "start each arm on its own line", "fix")
  local stat = parsed.chunk.body.stats[1]
  assert((stat.kind == "Match") and #stat.arms == 2, "two arms")
end

local function test_an_if_in_an_arm_that_is_not_closed_is_blamed_not_the_bar()
  local parsed = parse("match f() do\n  | (true, v) then\n    if v then\n      g()\n  | (false, e) then error(e)\nend")
  assert(codes(parsed) == "unclosed", codes(parsed))
  has(parsed.errors[1].msg, "to close the `if` on line 3", "blames the if")
  local stat = parsed.chunk.body.stats[1]
  assert((stat.kind == "Match") and #stat.arms == 2)
end

-- repeat and continue

local function test_a_local_after_a_continue_in_a_repeat_body_is_refused_whether_or_not_the_until_reads_it()
  local read = the_error("repeat\n  if c then continue end\n  local y = 1\nuntil y", "continue_skips_local")
  has(read.fix, "`until` reads `y`: declare it before the `repeat`, or before the `continue` on line 2", "read")
  local other = parse("repeat\n  if c then continue end\n  local y = 1\nuntil done").errors[1]
  has(other.fix, "wrap the code from `local y` to the end of the body in `do ... end`", "not read")
  assert(other.y == 3 and other.x == 3, "at the local")
  local at = other.other
  assert(at ~= nil and at.y == 2 and at.x == 13, "and the continue")
  local fn = the_error("repeat\n  if c then continue end\n  local function g() end\nuntil done", "continue_skips_local")
  has(fn.fix, "wrap the code", "a local function")
end

local function test_a_local_that_the_continue_does_not_jump_over_is_fine()
  clean("repeat\n  local y = 1\n  if c then continue end\nuntil y")
  clean("repeat\n  if c then continue end\n  do\n    local y = 1\n  end\nuntil done")
  clean("repeat\n  if c then continue end\nuntil done")
  clean("repeat\n  while q do\n    if c then continue end\n  end\n  local y = 1\nuntil y")
  clean("repeat\n  local function g()\n    while q do continue end\n  end\n  local y = 1\nuntil y")
end

local function test_a_function_in_the_until_that_binds_the_name_reads_its_own()
  local e = the_error("repeat\n  if c then continue end\n  local y = 1\nuntil (function(y) return y end)(2)", "continue_skips_local")
  has(e.fix, "wrap the code", "its own y, so the until does not read it")
  local inner = the_error("repeat\n  if c then continue end\n  local y = 1\nuntil (function() local y = 2 return y end)()", "continue_skips_local")
  has(inner.fix, "wrap the code", "a local of its own")
  local through = the_error("repeat\n  if c then continue end\n  local y = 1\nuntil (function() return y end)()", "continue_skips_local")
  has(through.fix, "`until` reads `y`", "a function that reads it")
end

local function test_the_until_of_a_very_long_chain_is_searched_without_a_stack_overflow()
  local chain = ("a + "):rep(120000) .. "y"
  -- The cover check recurses as deep as the chain, so this goes without it.
  local lexed = Lexer.lex("repeat\n  if c then continue end\n  local y = 1\nuntil " .. chain, "t.tl")
  local e = Parser.parse(lexed, "t.tl", "tl").errors[1]
  assert(e ~= nil and e.code == "continue_skips_local")
  has(e.fix, "`until` reads `y`", "found at the end of the chain")
end

-- nil unions

local function test_the_fix_for_a_union_with_nil_keeps_the_parentheses_the_source_has()
  local cases: {{string}} = {
    { "local x: T | nil", "write `T?`" },
    { "local x: nil | T", "write `T?`" },
    { "local x: A | B | nil", "write `(A | B)?`" },
    { "local x: (function(): integer) | nil", "write `(function(): integer)?`" },
    { "local x: T? | nil", "write `T?`" },
    { "local x: (A | B) | nil", "write `(A | B)?`" },
    { "local x: {string: T} | nil", "write `{string: T}?`" },
    { "local x: Map<A | B, C> | nil", "write `Map<A | B, C>?`" },
  }
  for _, case in ipairs(cases) do
    local e = the_error(case[1], "nil_union")
    assert(e.fix == case[2], case[1] .. ": " .. e.fix)
  end
end

-- the places an error involves

local function test_an_error_carries_the_second_place_it_involves()
  local unclosed = parse("local function f()\n  if x then\n    foo()\n").errors[2]
  local opener = unclosed.other
  assert(opener ~= nil and opener.y == 1 and opener.x == 7, "the opener of a function")
  local after = parse("return 1\nx = 2").errors[1]
  local returned = after.other
  assert(after.code == "statement_after_return" and returned ~= nil and returned.y == 1 and returned.x == 1, "the return")
  local repeated = parse("repeat\n  if c then continue end\n  local y = 1\nuntil y").errors[1]
  local continued = repeated.other
  assert(continued ~= nil and continued.y == 2, "the continue")
  assert(parse("local x = = 1").errors[1].other == nil, "most have one place")
end

-- docs

local function test_a_function_statement_has_its_doc_comment()
  local stat = parse("-- one\n--- two\nfunction R.m() end\nfunction R.n() end").chunk.body.stats[1]
  assert((stat.kind == "Function"))
  local doc = stat.doc
  assert(doc ~= nil and #doc == 2 and doc[1].text == "-- one" and doc[2].text == "--- two", "the run before the statement")
  local second = parse("-- one\nfunction R.m() end\nfunction R.n() end").chunk.body.stats[2]
  assert((second.kind == "Function") and second.doc == nil, "none for the next")
end

-- what takes a suffix

local function test_only_a_name_or_a_parenthesis_takes_a_suffix()
  local forms: {string} = { "\"abc\":upper()", "x = {}.z", "x = nil.y", "x = function() end()", "x = true:foo()", "x = ...(1)", "x = 1[2]" }
  for _, source in ipairs(forms) do
    local parsed = parse(source)
    local found = false
    for _, e in ipairs(parsed.errors) do
      found = found or (e.code == "suffix_needs_parens" and e.fix:find("(", 1, true) ~= nil)
    end
    assert(found, "refused: " .. source .. " [" .. codes(parsed) .. "]")
  end
  clean("x = (\"abc\"):upper() .. ({}).z .. (nil).y .. (function() end)() .. (...)(1)")
  clean("a.b:c(d)[e](f).g = h\nlocal t = f{ 1 }")
  local e = the_error("x = {}.z", "suffix_needs_parens")
  has(e.fix, "write `({})` and then the suffix", "fix")
end

-- declarations

local function test_a_type_declaration_in_an_interface_is_refused()
  for _, word in ipairs({ "record R end", "class R end", "enum R \"a\" end", "type R = integer" }) do
    local e = the_error("local interface I\n  " .. word .. "\nend", "nested_in_interface")
    has(e.msg, "an interface holds fields only", word)
  end
  clean("local record R\n  record Inner\n  end\n  enum Kind \"a\" end\n  type Alias = {string}\nend")
end

local function test_a_narrowing_return_is_the_whole_return_list()
  clean("local f: function(v: any): v is T")
  clean("local f: function(v: any): asserts v is T")
  for _, source in ipairs({
      "local f: function(v: any): v is T, integer", "local f: function(v: any): integer, v is T",
      "local f: function(v: any): (v is T) | (false, E)", "local f: function(v: any): v is T...",
  }) do
    the_error(source, "narrowing_return")
  end
end

local function test_a_method_is_a_member_name_like_a_field()
  the_error("local class C\n  function m(self) end\n  function m(self) end\nend", "duplicate_field")
  the_error("local class C\n  m: integer\n  function m(self) end\nend", "duplicate_field")
  the_error("local class C\n  function m(self) end\n  m: integer\nend", "duplicate_field")
  clean("local class C\n  function m(self) end\n  function n(self) end\n  x: integer\nend")
end

local function test_a_type_declared_with_the_old_word_is_read_as_the_declaration_it_means()
  local parsed = parse("local type X = record\n  a: integer\n  mut b: string\nend\nlocal y = 1")
  assert(codes(parsed) == "old_type_declaration", codes(parsed))
  has(parsed.errors[1].fix, "write `local record X ... end`", "fix")
  has(tree(parsed), "(Record \"local\" (Binding \"X\") _ _ _ [(FieldDecl (Binding \"a\") _ _ (TypeName [\"integer\"])) (FieldDecl (Binding \"b\") mut _ (TypeName [\"string\"]))])", "the record")
  for _, word in ipairs({ "interface", "enum", "class" }) do
    assert(codes(parse("local type X = " .. word .. "\nend")) == "old_type_declaration", word)
  end
  clean("local type record = {string}")
  clean("local type X = record.Y")
  clean("local type X = record?")
end

-- messages

local function test_mut_before_a_type_that_is_no_collection_still_reads_the_type()
  local parsed = parse("local x: mut integer = 1\nlocal y: string")
  assert(codes(parsed) == "mut_needs_collection", codes(parsed))
  assert(#parsed.chunk.body.stats == 2)
end

local function test_the_function_statements_that_name_a_method_say_where_it_goes()
  local a = the_error("function f.g:h() end", "method_in_record")
  has(a.msg, "`function f.g:h`", "the whole name")
  has(a.fix, "`function h(self, ...)`", "its own name")
  local b = the_error("local class C\n  function C:bump(by) end\nend", "method_path")
  has(b.fix, "drop `C:` and write `self`", "inside a class")
end

local function test_a_reserved_word_where_a_name_is_used_says_it_is_reserved_and_suggests_a_rename()
  local parsed = parse("match(p)\ncontinue(p)\nmut = 1\nuserdata.x = 1\nlocal function f(match) end\nlocal goto = 1")
  assert(codes(parsed) == "reserved_word reserved_word reserved_word reserved_word reserved_word reserved_word", codes(parsed))
  has(parsed.errors[1].fix, "`matched`", "match")
  has(parsed.errors[2].fix, "`continued`", "continue")
  has(parsed.errors[3].fix, "`mutable`", "mut")
  has(parsed.errors[5].fix, "`matched`", "a parameter")
  has(tree(parsed), "(CallStat (Call (Name \"match\") [(Name \"p\")])) (CallStat (Call (Name \"continue\") [(Name \"p\")])) (Assign [(Name \"mut\")] [(Integer 1)])", "read as the names")
  clean("local m = s:match(p)\nlocal c = t.continue(p)\nmatch f(p) do\n  | (true, v) then g(v)\nend")
end

local function test_a_stray_semicolon_does_not_swallow_the_rest_of_its_line()
  local parsed = parse("x = 1; y = 2; z = 3")
  assert(codes(parsed) == "semicolon semicolon", codes(parsed))
  assert(#parsed.chunk.body.stats == 5, "three assignments and two stray tokens")
end

local function test_two_constructs_left_open_at_the_end_of_the_file_are_both_reported()
  local parsed = parse("local function f()\n  while x do\n    g()\n")
  assert(codes(parsed) == "unclosed unclosed", codes(parsed))
  has(parsed.errors[1].msg, "`while` on line 2", "the inner one first")
  has(parsed.errors[2].msg, "function `f` on line 1", "then the outer")
end

local function test_a_missing_end_is_blamed_on_the_function_that_the_next_one_shows_is_open()
  local parsed = parse("local function f()\n  if x then\n    g()\nlocal function h()\n  return 1\nend\n")
  assert(codes(parsed) == "unclosed unclosed", codes(parsed))
  for i = 1, 2 do
    assert(parsed.errors[i].y == 4, "at the function that begins no deeper, not at the end of the file")
  end
  has(parsed.errors[1].msg, "`if` on line 2", "inner")
  has(parsed.errors[2].msg, "function `f` on line 1", "outer")
  local flush = parse("if a then\nlocal function g() end\nend")
  assert(#flush.errors == 0, "a body written without indentation is read as written")
end

local function test_a_long_expression_is_quoted_cut_in_a_message()
  local bad = parse("(" .. ("abcdefghij + "):rep(12) .. "k) == 1")
  assert(bad.errors[1] ~= nil and bad.errors[1].code == "not_a_statement")
  has(bad.errors[1].msg, "\226\128\166", "ends in an ellipsis")
  assert(#bad.errors[1].msg < 150, "short")
end

local function test_what_follows_a_construct_that_was_too_deep_is_reported_again()
  local source = "local x = " .. ("("):rep(250) .. "1" .. (")"):rep(250) .. "\nlocal z = = 1\nlocal w: T | nil"
  local parsed = parse(source)
  assert(codes(parsed) == "too_deep expected_expression nil_union", codes(parsed))
  assert(parsed.errors[2].y == 2 and parsed.errors[3].y == 3)
end

local function test_goto_is_refused_by_the_parser_in_each_place_it_stands()
  local e = the_error("for i = 1, 3 do goto continue end", "label_or_goto")
  assert(e.msg == "`goto continue` is not in the grammar" and e.fix == "write `continue`")
  local done = the_error("goto done", "label_or_goto")
  has(done.fix, "restructure any other jump", "another label")
  local bare = the_error("goto\nx = 1", "label_or_goto")
  assert(bare.msg == "`goto` is not in the grammar", "a name on the next line is not its label")
  clean("x.goto = 1\nlocal t = { goto = 2 }\nlocal record R\n  goto: boolean\nend")
  the_error("local goto = 1", "reserved_word")
end

-- a missing `end` after a `return`

local function test_a_function_missing_its_end_after_a_return_is_blamed_not_the_statement_after_the_return()
  local one = parse("local function f()\n  return 1\n\nlocal function g()\n  return 2\nend")
  assert(codes(one) == "unclosed", codes(one))
  has(one.errors[1].msg, "function `f` on line 1", "the function")
  assert(one.errors[1].y == 4, "at the function that follows")
  local two = parse("local function f()\n  if a then return 1\n\nlocal function g() end")
  assert(codes(two) == "unclosed unclosed", codes(two))
  has(two.errors[1].msg, "function `f` on line 1", "the function")
  local still = the_error("local function f()\n  return 1\n  x = 2\nend", "statement_after_return")
  has(still.fix, "do return end", "a real statement after a return")
end

local function test_code_written_flush_left_in_an_unclosed_body_is_blamed_at_the_end_of_the_file()
  local parsed = parse("local function f()\nx = 1\nlocal function g() end")
  assert(codes(parsed) == "unclosed", codes(parsed))
  has(parsed.errors[1].msg, "found the end of the file", "no indentation to go by")
  assert(parsed.errors[1].y == 3)
end

-- a table without a comma

local function test_a_string_or_table_item_on_the_next_line_without_a_comma_is_a_missing_comma_not_a_call()
  for _, items in ipairs({ "\"a\"\n  \"b\"", "{1}\n  {2}", "a\n  \"b\"", "a\n  {2}", "k = f\n  \"b\"", "[1] = {}\n  {2}" }) do
    local parsed = parse("local t = {\n  " .. items .. "\n}")
    assert(codes(parsed) == "expected_token", codes(parsed) .. " for " .. items)
    has(parsed.errors[1].fix, "add a `,`", items)
    assert(parsed.errors[1].y == 3)
  end
  assert(codes(parse("local t = { f\"x\" }")) == "string_call", "on one line it is the call it was")
  clean("local t = {\n  function()\n    f(\n      \"x\")\n  end,\n}")
end

-- arms

local function test_a_second_arm_on_the_line_of_a_call_statement_is_refused()
  local parsed = parse("match f() do\n  | (true, x) then a() | (false, y) then b()\nend")
  assert(codes(parsed) == "arm_on_same_line", codes(parsed))
  local stat = parsed.chunk.body.stats[1]
  assert((stat.kind == "Match") and #stat.arms == 2)
end

-- reserved words at the start of a statement

local function test_a_reserved_word_assigned_to_or_called_is_read_as_the_name_it_was_meant_for()
  local parsed = parse("match = 1\ncontinue = true\nmatch(a, b)\ncontinue(a)\ncontinue, match = 1, 2")
  assert(codes(parsed) == "reserved_word reserved_word reserved_word reserved_word reserved_word reserved_word", codes(parsed))
  has(parsed.errors[1].fix, "`matched`", "match")
  has(parsed.errors[2].fix, "`continued`", "continue")
  has(tree(parsed), "(Assign [(Name \"match\")] [(Integer 1)]) (Assign [(Name \"continue\")] [(Boolean true)]) " ..
      "(CallStat (Call (Name \"match\") [(Name \"a\") (Name \"b\")])) (CallStat (Call (Name \"continue\") [(Name \"a\")]))", "tree")
  assert(#parsed.chunk.body.stats == 5)
  clean("match f(a, b) do\n  | (true, x) then continue_()\nend\nfor i = 1, 2 do continue end")
end

-- what a repeat's body declares

local function test_a_class_a_record_and_an_import_after_a_continue_are_locals_in_the_lua_written_for_them()
  for _, declaration in ipairs({ "local class K\n  end", "local record K\n  end", "local type K = require(\"m\")" }) do
    local e = the_error("repeat\n  if c then continue end\n  " .. declaration .. "\nuntil z", "continue_skips_local")
    has(e.fix, "wrap the code from `local K`", declaration)
  end
  for _, declaration in ipairs({ "local enum K \"a\" end", "local type K = {string}", "local interface K\n  end" }) do
    clean("repeat\n  if c then continue end\n  " .. declaration .. "\nuntil z")
  end
end

-- small ones

local function test_small_messages()
  the_error("local f: function(): (integer, string,)", "trailing_comma")
  has(the_error("local x = s:match\"x\"", "string_call").fix, "obj:match(\"x\")", "a method call")
  has(parse("local type X = enum\nend").errors[1].msg, ": an enum is declared", "an enum")
end
