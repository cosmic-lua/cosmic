--- Correctness probes for [`build.syntax_match`]: the metavariables, what a pattern leaves unset, a capture in every
--- position the grammar has one, and the predicate of a capture.
local Ast = require("lang.ast")
local Match = require("build.syntax_match")
local Node = require("build.syntax_node")
local Test = require("cosmic.test")

Test.policy{}

local function parse_ok(source: string): Ast.Chunk
  local chunk, why = Node.parse(source, "t.tl")
  return (assert(chunk, why))
end

local function pattern_ok(source: string): Match.Pattern
  local pattern, why = Match.compile(source)
  return (assert(pattern, why))
end

--- The nodes of `source` that `pattern_source` matches, in source order.
local function hits(pattern_source: string, source: string): {Match.Hit}
  return Match.find_all(pattern_ok(pattern_source), parse_ok(source), parse_ok(source))
end

local function count(pattern_source: string, source: string): integer
  local chunk = parse_ok(source)
  return #Match.find_all(pattern_ok(pattern_source), chunk, chunk)
end

--- The text of a capture of the first match.
local function first_text(pattern_source: string, source: string, name: string): string
  local chunk = parse_ok(source)
  local found = Match.find_all(pattern_ok(pattern_source), chunk, chunk)
  assert(#found > 0, "no match of " .. pattern_source .. " in " .. source)
  local cap = found[1].caps[name]
  assert(cap ~= nil, "no capture " .. name)
  return Match.text(chunk, source, cap)
end

local function test_a_pattern_and_its_target_are_parsed_alike_so_annotations_compare_by_shape()
  for _, scope in ipairs({ "local" }) do
    for _, annotation in ipairs({ "number", "{string: {number}}", "function(number): string", "Box<string>" }) do
      local source = scope .. " value: " .. annotation .. " = make_value()"
      assert(count(source, source) == 1, "separately parsed declaration must match: " .. source)
    end
    local pattern = scope .. " value: {string: {number}} = make_value()"
    for _, annotation in ipairs({ "number", "{string: {string}}", "{number: {number}}" }) do
      assert(count(pattern, scope .. " value: " .. annotation .. " = make_value()") == 0,
        "a different annotation must not match: " .. annotation)
    end
  end
end

local function test_a_record_field_compares_its_declared_type()
  local pattern = "local record Box\n  size: number\nend"
  assert(count(pattern, "local record Box\n  size: number\nend") == 1)
  assert(count(pattern, "local record Box\n  size: string\nend") == 0)
  assert(count(pattern, "local record Box\n  size: number\n  more: string\nend") == 0, "a list has the pattern's length")
end

local function test_a_capture_in_a_value_position_binds_the_node()
  local chunk = parse_ok("print(y.z)")
  local found = Match.find_all(pattern_ok("print($X)"), chunk, chunk)
  assert(#found == 1)
  local cap = found[1].caps["_X"]
  assert(cap ~= nil and #cap.nodes == 1 and cap.first == cap.last - 2)
  local node = cap.nodes[1]
  assert((node.kind == "Field") and node.name == "z")
end

local function test_a_capture_in_the_name_of_a_field_or_a_method_binds_its_token()
  assert(first_text("mod.$F(1)", "mod.load(1)", "_F") == "load")
  assert(count("mod.$F(1)", "other.load(1)") == 0)
  assert(first_text("obj:$M($$$ARGS)", "obj:run(1, 2)", "_M") == "run")
  assert(first_text("$A.$B", "local v = x.y", "_B") == "y")
end

local function test_a_capture_name_repeated_binds_the_same_text()
  assert(count("f($X, $X)", "f(y, y)") == 1)
  assert(count("f($X, $X)", "f(y, z)") == 0)
  assert(count("f($X, $X)", "f(a.b, a.b)") == 1 and count("f($X, $X)", "f(a.b, a.c)") == 0)
end

local function test_a_rest_capture_takes_the_rest_of_a_list_none_included()
  local chunk = parse_ok("f(1, 2, 3)\nf()\ng(1)")
  local found = Match.find_all(pattern_ok("f($$$ARGS)"), chunk, chunk)
  assert(#found == 2)
  assert(#found[1].caps["___ARGS"].nodes == 3 and #found[2].caps["___ARGS"].nodes == 0)
  local some = Match.find_all(pattern_ok("f($A, $$$REST)"), chunk, chunk)
  assert(#some == 1 and #some[1].caps["___REST"].nodes == 2)
end

local function test_a_rest_capture_in_a_block_is_written_as_a_call()
  local pattern, why = Match.compile("if $C then $$$BODY end")
  assert(pattern == nil and why ~= "")
  local chunk = parse_ok("if a then print(1)\nprint(2) end")
  local found = Match.find_all(pattern_ok("if $C then $$$BODY() end"), chunk, chunk)
  assert(#found == 1 and #found[1].caps["___BODY"].nodes == 2)
end

local function test_a_table_item_rest_and_an_empty_table()
  assert(count("local t = { $$$ITEMS }", "local t = { 1, k = 2, [3] = 4 }") == 1)
  assert(count("local t = { $$$ITEMS }", "local t = {}") == 1)
  assert(count("local t = {}", "local t = { 1 }") == 0)
end

local function test_a_literal_must_match_where_a_leaf_is_compared()
  assert(count("print(1)", "print(1)") == 1)
  assert(count("print(1)", "output(1)") == 0)
  assert(count("print(1)", "print(2)") == 0)
  assert(count("print('a')", 'print("a")') == 1, "the quotes of a string do not matter, its value does")
  assert(count("print('a')", 'print("b")') == 0)
end

local function test_a_field_the_pattern_leaves_nil_is_not_consulted()
  assert(count("if $C then $$$B() end", "if a then f() end") == 1)
  assert(count("if $C then $$$B() end", "if a then f() else g() end") == 0, "an if without an else is not one with it")
  assert(count("if $C then $$$B() else $$$E() end", "if a then f() else g() end") == 1)
  assert(count("if $C then $$$B() else $$$E() end", "if a then f() end") == 0)
  assert(count("if $C then $$$B() end", "if a then f() elseif b then g() end") == 0, "a list has the pattern's length")
  assert(count("local $X = 1", "local a: integer = 1") == 0, "a list of types has the pattern's length")
  assert(count("local $X <const> = 1", "local a <const> = 1") == 1)
  assert(count("local $X = 1", "local a <const> = 1") == 1, "an attribute the pattern leaves out is not consulted")
end

local function test_a_capture_predicate_restricts_what_a_capture_binds()
  local chunk = parse_ok("test_a()\nrun()")
  local found = Match.find_all(pattern_ok("$F:^test_()"), chunk, chunk)
  assert(#found == 1 and Match.text(chunk, "test_a()\nrun()", found[1].caps["_F"]) == "test_a")
  -- a compound node has no one token to test
  assert(count("f($X:^a)", "f(a.b)") == 0 and count("f($X:^a)", "f(ab)") == 1)
end

local function test_desugar_rewrites_both_spellings_and_drops_a_predicate()
  assert(Match.desugar("f($X, $$$REST)") == "f(_X, ___REST)")
  assert(Match.desugar("os.execute(cmd)") == "os.execute(cmd)")
  assert(Match.desugar("$F:^test_()") == "_F()")
end

local function test_a_pattern_that_is_an_expression_is_read_as_a_return_value()
  local source = "local v: any = 1\nlocal a = v as integer\nlocal b = v as {string: any}"
  assert(count("$X as integer", source) == 1, "a literal type matches the type, not the cast")
  assert(count("$X as $T", source) == 2)
  assert(first_text("$X as $T", source, "_T") == "integer")
  assert(count("$X as $T:^{", source) == 1, "the predicate reads the first token of a type")
  assert(count("f($A) as Foo", "local c = f(x) as Foo") == 1 and count("f($A) as Foo", "local c = g(x) as Foo") == 0)
  local pattern, why = Match.compile("local = ")
  assert(pattern == nil and why:find("<pattern>", 1, true) ~= nil)
end

local function test_os_execute_among_other_calls_and_string_format_at_each_arity()
  assert(count("os.execute($X)", 'print("a")\nos.execute("true")\nprint("b")\n') == 1)
  assert(count("string.format($FMT, $$$REST)", table.concat({
    'local a = string.format("%d", 1)', 'local b = string.format("%s %s", "x", "y")',
    'local c = string.format("%d %d %d", 1, 2, 3)', 'print("not a format call")', "",
  }, "\n")) == 3)
  assert(count("mod.$F($$$ARGS)", "mod.foo(1, 2)\nmod.bar()\nother.foo(1)\n") == 2)
  assert(#hits("print($X)", "print(1)\nprint(2)\n") == 2)
end

local function test_a_call_pattern_matches_a_call_as_a_statement_and_inside_an_expression()
  assert(count("f($X)", "local x = f(1)\nf(2)\nreturn { f(3) }") == 3)
end

local function test_a_field_the_pattern_sets_and_the_target_lacks_is_no_match_and_no_error()
  assert(count("if $C then $$$B() else $$$E() end", "if a then f() end") == 0)
  assert(count("for $I = $A, $B, $S do $$$X() end", "for i = 1, 3 do f() end") == 0)
  assert(count("for $I = $A, $B, $S do $$$X() end", "for i = 1, 3, 2 do f() end") == 1)
  assert(count("local function $F($P): $R $$$B() end", "local function foo(a: integer) f() end") == 0)
  assert(count("local function $F($P): $R $$$B() end", "local function foo(a: integer): integer f() end") == 1)
end

local function test_a_rewrite_of_an_if_keeps_the_else_it_does_not_match()
  local rewrite = require("build.syntax_rewrite")
  local pattern = pattern_ok("if $C then $$$B() end")
  local result, why = rewrite.rewrite("if a then f() else g() end\n", "t.tl", pattern, "while $C do $$$B end")
  assert(result ~= nil and result.code == "if a then f() else g() end\n" and #result.edits == 0, tostring(why))
end
