#!/usr/bin/env cosmic
-- Type position: which tokens on a line are a TYPE rather than code.
--
-- Split from init_test.tl on the same seam as `format/types.tl` — the
-- module these exercise. Every one of them is a place the carried
-- "the previous line left a type open" bit was dropped, and each
-- failure has the same shape: the rest of the file indents into a body
-- no `end` ever closes.
--
-- They are regression tests in the strict sense. A formatter's output
-- is idempotent, so the gate re-blesses its own damage on every run —
-- which is how two files came to ship mis-indented with `--make fmt`
-- reporting PASS. Nothing here is caught by the gate; only by these.

local fmt = require("cosmic.format")

local function assert_format(input: string, expected: string, msg: string,
    filename?: string)
  filename = filename or "test.tl"
  local result = fmt.format(input, filename)
  assert(result.ok, msg .. ": format failed: " ..
    (result.errors and #result.errors > 0
      and result.errors[1].message or "unknown error"))
  if result.code ~= expected then
    error(msg .. ":\n  expected:\n" .. expected .. "\n  got:\n" ..
      (result.code or ""))
  end
end

-- A cast whose function TYPE lands on the next line: the `as` is the
-- last token of one line and `function(` opens the next. A per-line
-- scan sees only a bare `function` at line start and reads it as a
-- definition, indenting the rest of the file into a body no `end`
-- closes -- so the rules carry one bit across the break.
local function test_type_continued_after_a_line_break()
  local src = "local function f(): integer\n" ..
  "  local g = print as\n" ..
  "  function(files: {string}, names: {string: string}): string | nil\n" ..
  "  local body = g({\"a\"}, {})\n" ..
  "  return #body\n" ..
  "end\n" ..
  "return f\n"
  assert_format(src, src, "a function type continued after `as`", "test.tl")
end
test_type_continued_after_a_line_break()

-- The same break after a `:` -- a record field or a return type whose
-- function type wraps. Same one bit, the other token that opens type
-- position.
local function test_type_continued_after_a_colon()
  local src = "local record R\n" ..
  "  run:\n" ..
  "  function(a: string): integer\n" ..
  "  n: integer\n" ..
  "end\n" ..
  "return R\n"
  assert_format(src, src, "a function type continued after `:`", "test.tl")
end
test_type_continued_after_a_colon()

print("All format tests passed!")

-- `?` marks an optional record field as a SUFFIX (`name?: string`) and
-- an optional argument type as a PREFIX inside a function type. The
-- second is what generated `.d.tl` declarations are full of, and
-- rewriting those to `,? string` corrupts them -- a formatter bug that
-- only shows up where a `.d.tl` is actually format-checked.
local function test_optional_argument_types_keep_their_space()
  local src = "local record R\n" ..
  "  init_env: function(? boolean, ? string, ? {string}): any, string\n" ..
  "end\n" ..
  "return R\n"
  assert_format(src, src, "optional argument types keep the separator space",
    "test.tl")
end
test_optional_argument_types_keep_their_space()

-- `record` is a legal table KEY, and reading it as a type declaration
-- opens a block that never closes -- so every following line indents
-- one level deeper, to the end of the file. The damage is idempotent,
-- which is why the gate passed on it: the `-c` vocabulary's `test` verb
-- was renamed to `record`, and two files silently acquired an extra
-- level from that line down while `--make fmt` reported PASS.
--
-- `enum` and `interface` are the same shape. A real declaration
-- (`record Name`, or the word alone) still opens its block.
local function test_type_keywords_as_table_keys_do_not_open_blocks()
  for _, kw in ipairs({"record", "enum", "interface"}) do
    local src = "local t = {\n" ..
    "  " .. kw .. " = {a = 1},\n" ..
    "  after = 2,\n" ..
    "}\n" ..
    "return t\n"
    assert_format(src, src, kw .. " as a table key is a key", "test.tl")

    local colon = "local record R\n" ..
    "  " .. kw .. ": integer\n" ..
    "  after: integer\n" ..
    "end\n" ..
    "return R\n"
    assert_format(colon, colon, kw .. " as a field name is a name", "test.tl")
  end

  -- And the declaration it could be confused with still opens a block.
  local decl = "local record Outer\n" ..
  "  record Inner\n" ..
  "    a: integer\n" ..
  "  end\n" ..
  "end\n" ..
  "return Outer\n"
  assert_format(decl, decl, "a real declaration still indents", "test.tl")
end
test_type_keywords_as_table_keys_do_not_open_blocks()

-- A wrapped function TYPE leaves its `(` open, and the matching `)`
-- lands on the next line. That `)` belonged to nobody: the marking
-- pass never saw it (different line) and the second pass counted it as
-- an ordinary closer, so the line dedented with no matching indent and
-- every line after it sat one level too shallow, to end of file.
--
-- `cosmic/format/rules.tl`'s own module record is the file that did
-- this. A formatter bug ships its own blessing: the output is
-- idempotent, so the gate passes on the damage every run.
local function test_a_wrapped_function_type_does_not_dedent()
  local src = "local record R\n" ..
  "  wrapped: function(a: integer,\n" ..
  "  b: integer): integer\n" ..
  "  after: integer\n" ..
  "end\n" ..
  "return R\n"
  assert_format(src, src, "a field after a wrapped type keeps its level",
    "test.tl")

  -- A wrapped DEFINITION is the other half, and the property that
  -- matters is the same one: whatever the continuation line is
  -- indented to, the code after the construct comes back to its own
  -- level. Asserted on the levels rather than on an expected string,
  -- because the continuation's depth is a style this test has no
  -- business freezing.
  local nested = "local t = {\n" ..
  "  f = function(a: integer,\n" ..
  "  b: integer): integer\n" ..
  "  return a + b\n" ..
  "  end,\n" ..
  "  after = 1,\n" ..
  "}\n" ..
  "return t\n"
  local out = fmt.format(nested, "test.tl").code
  assert(out:find("\n  after = 1,\n", 1, true),
    "the sibling after a wrapped definition is back at one level: " .. out)
  assert(out:find("\n}\n", 1, true),
    "and the table closes at column 0: " .. out)
  assert(out:find("\nreturn t\n", 1, true),
    "and the file continues at column 0: " .. out)
  local again = fmt.format(out, "test.tl").code
  assert(again == out, "and formatting is idempotent: " .. again)
end
test_a_wrapped_function_type_does_not_dedent()

-- A comment decides nothing about type position. Dropping the carried
-- bit at a comment made the `function` on the next line read as a
-- definition, indenting a phantom body under any comment that fell
-- between `as`/`:` and its type.
local function test_a_comment_carries_type_position_through()
  local src = "local record R\n" ..
  "  f:\n" ..
  "  -- what it does\n" ..
  "  function(a: integer): integer\n" ..
  "  after: integer\n" ..
  "end\n" ..
  "return R\n"
  assert_format(src, src, "a comment between `:` and its type carries it",
    "test.tl")
end
test_a_comment_carries_type_position_through()

print("all format type-position tests passed")
