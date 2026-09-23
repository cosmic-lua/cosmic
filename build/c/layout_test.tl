--- The layout `cosmic fix` writes C back in, a case per rule, each as the
--- C it is given and the C that comes back.

local layout = require("build.c.layout")

local function laid(source: string): string
  local out, trouble = layout.rendered(source)
  assert(out ~= nil, trouble)
  return out
end

local function becomes(source: string, expected: string)
  local out = laid(source)
  assert(out == expected, "expected:\n" .. expected .. "\ngot:\n" .. out)
  assert(laid(out) == out, "laid out again, it changed")
end

local function test_a_statement_is_indented_by_its_braces()
  becomes("void f (void) {\nif (x) {\n      y();\n  }\n}\n",
    "void f (void) {\n  if (x) {\n    y();\n  }\n}\n")
end

--- An initializer's entries are indented like statements, two columns a
--- brace, as Lua's own tables of functions are; a compound literal's too.
local function test_an_initializers_entries_are_indented_by_its_braces()
  becomes("static const R r[] = {\n    {\"a\", a},\n    {\"b\", b},\n};\n",
    "static const R r[] = {\n  {\"a\", a},\n  {\"b\", b},\n};\n")
  becomes("void f (void) {\n  v = (T){\n      .a = 1,\n      .b = 2,\n  };\n}\n",
    "void f (void) {\n  v = (T){\n    .a = 1,\n    .b = 2,\n  };\n}\n")
end

--- A line that continues another keeps its columns relative to it: an
--- argument lined up under a parenthesis stays under it when the
--- statement moves.
local function test_a_continuation_moves_with_its_statement()
  becomes("void f (void) {\n    g(a,\n      b);\n}\n",
    "void f (void) {\n  g(a,\n    b);\n}\n")
  becomes("R r[] = {\n    {\"x\", \"one \"\n           \"two\"},\n};\n",
    "R r[] = {\n  {\"x\", \"one \"\n         \"two\"},\n};\n")
end

--- A definition's name is followed by a space, and its parameters stay
--- lined up under its parenthesis; parameters on a line of their own keep
--- their own indent. A call, a macro and a function pointer are not
--- definitions.
local function test_a_definition_has_a_space_before_its_parameters()
  becomes("static int f(int a,\n             int b) {\n  return g(a);\n}\n",
    "static int f (int a,\n              int b) {\n  return g(a);\n}\n")
  becomes("int *make(\n    int a, int b);\n", "int *make (\n    int a, int b);\n")
  becomes("COSMIC_SYSCALL(open, 3) {\n  return 0;\n}\n",
    "COSMIC_SYSCALL(open, 3) {\n  return 0;\n}\n")
  becomes("static void (*hook)(int);\n", "static void (*hook)(int);\n")
end

local function test_directives_comments_and_literals_are_carried_over()
  becomes("#define F(x) \\\n    ((x) + 1)\nint f (void) {\n#if A\n    return 1;\n#endif\n}\n",
    "#define F(x) \\\n    ((x) + 1)\nint f (void) {\n#if A\n  return 1;\n#endif\n}\n")
  -- A comment spanning lines moves with the line it starts on.
  becomes("void f (void) {\n    /* one\n     * two */\n    x();\n}\n",
    "void f (void) {\n  /* one\n   * two */\n  x();\n}\n")
end

local function test_whitespace_at_line_ends_and_the_end_of_the_file()
  becomes("int x;   \n\n\n\n\nint y;\n\n\n", "int x;\n\n\nint y;\n")
  becomes("int x;", "int x;\n")
end

local function test_a_case_label_and_a_ternary_are_told_apart()
  becomes("void f (void) {\n  switch (x) {\n  case 1: y = a ?\n      b : c; break;\n  }\n}\n",
    "void f (void) {\n  switch (x) {\n    case 1: y = a ?\n        b : c; break;\n  }\n}\n")
end

--- Only whitespace may change: anything else is refused.
local function test_more_than_whitespace_is_not_the_same()
  assert(layout.same("int a;\n", "int  a ;\n"))
  assert(layout.same("/* a\n   b */\n", "/* a\n b */\n"), "a comment may move")
  assert(not layout.same("int a;\n", "int b;\n"))
  assert(not layout.same("a - -b;\n", "a --b;\n"), "two tokens may not become one")
  assert(not layout.same("\"a b\";\n", "\"a  b\";\n"), "a literal is its bytes")
end
