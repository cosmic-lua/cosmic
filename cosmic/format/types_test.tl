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
-- two files shipped mis-indented with `--make fmt` reporting PASS.
-- Nothing here is caught by the gate; only by these.

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

-- A wrap longer than two lines, which is where carrying a BIT instead
-- of a depth failed: the middle line opens and closes nothing, so a
-- per-line bracket count reads 0 and drops the carry. The `)` line then
-- dedents as if it closed a code bracket and takes `n: integer` with it
-- -- idempotently, so `--make fmt` blesses the damage on every run.
--
-- `n: integer` after the wrap is the whole point of the case. Without a
-- field there, the `math.max(0, ...)` indent clamp lands `end` at 0 by
-- coincidence and the file formats correctly while the bug is live;
-- `cosmic/child/io.tl` shipped exactly that way.
local function test_a_type_wrapped_over_three_lines()
  local src = "local record R\n" ..
  "  f: function(a: string,\n" ..
  "  b: string,\n" ..
  "  c: string): integer\n" ..
  "  n: integer\n" ..
  "end\n" ..
  "return R\n"
  assert_format(src, src, "a function type wrapped over three lines", "test.tl")
end
test_a_type_wrapped_over_three_lines()

-- The depth is a count, not a flag: four lines, a nested `{string:
-- {string}}` inside the wrap, and a comment on a middle line (which
-- decides nothing and must pass both carried facts through untouched).
local function test_a_deeper_wrap_keeps_its_depth()
  local src = "local record R\n" ..
  "  f: function(a: {string: {string}},\n" ..
  "  -- the middle line neither opens nor closes\n" ..
  "  b: string,\n" ..
  "  c: string): integer\n" ..
  "  n: integer\n" ..
  "end\n" ..
  "return R\n"
  assert_format(src, src, "a four-line wrap with a nested map", "test.tl")
end
test_a_deeper_wrap_keeps_its_depth()

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

-- A parenthesized union. `mark_function_type` cannot reach this shape:
-- it marks from a `function` whose NEXT token is `(`, and here the `(`
-- comes first, so the backward scan hits an unmatched `(` and calls the
-- `function` a definition -- one phantom level from that line to the
-- end of the file.
--
-- The group is marked whole rather than the keyword alone. Marks are
-- skipped for indent accounting on both sides, so marking `function`
-- and leaving its brackets bare banks the same level the false opener
-- did: the `(` counts as an opener and the marked `)` never pays it
-- back.
local function test_a_parenthesized_union_opens_no_block()
  local src = "local record R\n" ..
  "  f: function(a: integer): integer\n" ..
  "end\n" ..
  "local g = (nil as any) as (function | nil)\n" ..
  "local h = 1\n" ..
  "return R, g, h\n"
  assert_format(src, src, "a parenthesized union after `as`", "test.tl")

  -- The same group in the other type position, and one with its own
  -- brackets inside, so the scan has to match rather than stop at the
  -- first `)`.
  local colon = "local x: (function | nil) = nil\n" ..
  "local y: (function(a: integer): integer | nil) = nil\n" ..
  "local z = 1\n" ..
  "return x, y, z\n"
  assert_format(colon, colon, "a parenthesized union after `:`", "test.tl")
end
test_a_parenthesized_union_opens_no_block()

-- `as` lexes as an identifier -- Teal keeps it usable as a name -- so
-- the "no space before `(` in a call" rule claimed it and wrote
-- `x as(T | nil)`. Legal, and wrong about what the code is: `as` is an
-- operator, and the parens are a type, not an argument list.
local function test_as_keeps_its_space_before_a_parenthesized_type()
  local src = "local f = (nil as any) as (function | nil)\n" ..
  "return f\n"
  assert_format(src, src, "`as (` is not a call", "test.tl")

  -- The rule it must not have broken: a real call still binds tight.
  local call = "local n = tostring(1)\n" ..
  "return n\n"
  assert_format(call, call, "a call keeps no space before its `(`",
    "test.tl")
end
test_as_keeps_its_space_before_a_parenthesized_type()

-- `function` in type position after the `is` operator. The backward
-- scan knew `:` and `as` put what follows in type position, but not
-- `is` -- so `x is function` read as a definition, consumed the real
-- `end`s, and every construct after it indented one level deeper, to
-- the end of the file. The damage compounds per occurrence, and the
-- gate passes on it: the output is idempotent, so `--check fmt`
-- re-blesses its own block model every run.
local function test_is_function_is_a_type_not_a_definition()
  local src = "local function f(): any\n" ..
  "  return 1\n" ..
  "end\n" ..
  "local x = f()\n" ..
  "assert(x is function, \"a function\")\n" ..
  "local y = 1\n" ..
  "print(y)\n" ..
  "return y\n"
  assert_format(src, src, "`is function` opens no block", "test.tl")

  -- The cascade is one level PER occurrence, so two adjacent lines
  -- must leave the level untouched twice.
  local twice = "local x = 1 as any\n" ..
  "assert(x is function, \"one\")\n" ..
  "assert(x is function, \"two\")\n" ..
  "return x\n"
  assert_format(twice, twice, "two `is function` lines bank no levels",
    "test.tl")
end
test_is_function_is_a_type_not_a_definition()

-- A bare `function` type is the whole type by itself. Marking past the
-- keyword claims the enclosing call's own tokens: its `)` is marked
-- away as type while its `(` was counted as an opener, which banks the
-- same phantom level a false block opener does.
local function test_a_bare_function_type_claims_nothing_after_it()
  local src = "local x = 1 as any\n" ..
  "assert((x as function) == x, \"still x\")\n" ..
  "local y = 1\n" ..
  "return y\n"
  assert_format(src, src, "`as function` inside a call claims only itself",
    "test.tl")
end
test_a_bare_function_type_claims_nothing_after_it()

-- A GENERIC function type that wraps: `function<T>(a,` puts `<`, not
-- `(`, after the keyword. Calling that a bare type stops the marking
-- before the `(`, so the open bracket never joins the carried depth
-- and the continuation line reads its own `function` as a definition.
-- `cosmic/fs/walk.tl`'s walk_tree is the shape in the tree.
local function test_a_generic_function_type_still_carries_its_wrap()
  local src = "local walk: function<T>(string,\n" ..
  "function(string, T): boolean, T): boolean\n" ..
  "local n = 1\n" ..
  "return walk, n\n"
  assert_format(src, src, "a wrapped generic function type carries",
    "test.tl")
end
test_a_generic_function_type_still_carries_its_wrap()

-- The workaround shape from the issue this pins: a named
-- `function(): T` alias, discriminated with `type()` and cast. It must
-- stay format-clean alongside the direct `is function` it replaced.
local function test_a_function_type_alias_still_opens_no_block()
  local src = "local type Loader = function(): any\n" ..
  "local function loader_of(got: any): Loader | nil\n" ..
  "  if type(got) ~= \"function\" then\n" ..
  "    return nil\n" ..
  "  end\n" ..
  "  return got as Loader\n" ..
  "end\n" ..
  "return loader_of\n"
  assert_format(src, src, "a `function(): T` alias opens no block", "test.tl")
end
test_a_function_type_alias_still_opens_no_block()

print("all format type-position tests passed")
