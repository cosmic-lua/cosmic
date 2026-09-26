--- `build.doctest.generate` also needs no compiler capsule: it turns a
--- `{markdown.Block}` list into a Teal source STRING, and never asks
--- whether that string itself type-checks. These tests build blocks by
--- hand and check the generated text and the grammar errors, the same
--- split `build.doctest.markdown_test` uses for the fence-parsing half.
local markdown = require("build.doctest.markdown")
local generate = require("build.doctest.generate")

local type Block = markdown.Block
local type Modifiers = markdown.Modifiers

local function mods(continue: boolean, file: string | nil,
                    skip: string | nil): Modifiers
  return { continue = continue, file = file, skip = skip }
end

local function block(lang: string, content: string, m: Modifiers): Block
  return { lang = lang, modifiers = m, content = content, line = 1 }
end

local no_mods = mods(false, nil, nil)

local function test_a_bare_example_with_no_output_is_named_example_n()
  local blocks: {Block} = { block("teal", "local x = 1", no_mods) }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  assert(code:find("local function example_1(tmp: string)", 1, true) ~= nil,
    "got:\n" .. code)
  assert(code:find("local _ = example_1", 1, true) ~= nil, "got:\n" .. code)
  assert(code:find("local x = 1", 1, true) ~= nil, "got:\n" .. code)
end

local function test_an_example_with_output_is_named_test_n_and_asserts()
  local blocks: {Block} = {
    block("teal", 'print("hi")', no_mods),
    block("output", "hi", no_mods),
  }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  assert(code:find("local function test_1(tmp: string)", 1, true) ~= nil,
    "got:\n" .. code)
  assert(code:find("local function __doctest_capture", 1, true) ~= nil,
    "got:\n" .. code)
  assert(code:find('__doctest_want = "hi"', 1, true) ~= nil, "got:\n" .. code)
  assert(code:find("local _ = example_1", 1, true) == nil,
    "a runnable example must not also get the compile-only marker")
end

local function test_a_second_example_continues_the_shared_numbering()
  local blocks: {Block} = {
    block("teal", "local x = 1", no_mods),
    block("teal", "local y = 2", no_mods),
  }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  assert(code:find("example_1", 1, true) ~= nil, "got:\n" .. code)
  assert(code:find("example_2", 1, true) ~= nil, "got:\n" .. code)
end

local function test_continue_appends_to_the_open_example_not_a_new_one()
  local blocks: {Block} = {
    block("teal", "local x = 1", no_mods),
    block("teal", "print(x)", mods(true, nil, nil)),
  }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  assert(code:find("example_2", 1, true) == nil,
    "a continue block must not open a second example:\n" .. code)
  assert(code:find("local x = 1", 1, true) ~= nil)
  assert(code:find("print(x)", 1, true) ~= nil)
end

local function test_continue_with_nothing_open_is_refused()
  local blocks: {Block} = { block("teal", "print(a)", mods(true, nil, nil)) }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code == nil, "expected a lone continue block to be refused")
  assert(trouble:find("no open example", 1, true) ~= nil, "got: " .. trouble)
end

local function test_output_with_nothing_open_is_refused()
  local blocks: {Block} = { block("output", "hi", no_mods) }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code == nil, "expected a lone output block to be refused")
  assert(trouble:find("must immediately follow an example", 1, true) ~= nil,
    "got: " .. trouble)
end

local function test_a_skip_block_produces_a_comment_and_no_function()
  local blocks: {Block} = { block("teal", 'print("no")', mods(false, nil, "intended")) }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  assert(code:find("-- skipped: intended", 1, true) ~= nil, "got:\n" .. code)
  assert(code:find("local function", 1, true) == nil, "got:\n" .. code)
end

local function test_a_shebang_line_is_skipped_regardless_of_its_tag()
  local blocks: {Block} = { block("teal", "#!/usr/bin/env cosmic\nprint(1)", no_mods) }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  assert(code:find("-- skipped:", 1, true) ~= nil, "got:\n" .. code)
  assert(code:find("local function", 1, true) == nil, "got:\n" .. code)
end

local function test_a_shebang_inside_a_file_block_is_not_a_skip()
  local blocks: {Block} = {
    block("teal", "#!/usr/bin/env cosmic\nprint(1)", mods(false, "run.sh", nil)),
    block("teal", 'print("entry")', no_mods),
  }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  assert(code:find("-- skipped:", 1, true) == nil, "got:\n" .. code)
  assert(code:find("__doctest_write(tmp,", 1, true) ~= nil, "got:\n" .. code)
end

local function test_a_dangling_file_block_is_refused()
  local blocks: {Block} = { block("teal", "content", mods(false, "run.sh", nil)) }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code == nil, "expected a dangling file= block to be refused")
  assert(trouble:find("no entry block to attach it to", 1, true) ~= nil,
    "got: " .. trouble)
end

local function test_a_file_block_after_the_entry_still_attaches_to_it()
  local blocks: {Block} = {
    block("teal", 'print("entry")', no_mods),
    block("teal", "return 1", mods(false, "a.tl", nil)),
  }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  local at_write = code:find("__doctest_write(tmp, \"a.tl\"", 1, true)
  local at_entry = code:find('print("entry")', 1, true)
  assert(at_write ~= nil and at_entry ~= nil, "got:\n" .. code)
  assert(at_write < at_entry,
    "expected the file to still be written before the entry runs:\n" .. code)
end

local function test_a_file_block_after_the_entry_still_reaches_output()
  local blocks: {Block} = {
    block("teal", 'print("entry")', no_mods),
    block("teal", "return 1", mods(false, "a.tl", nil)),
    block("output", "entry", no_mods),
  }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  assert(code:find("local function test_1(tmp: string)", 1, true) ~= nil,
    "expected a file= block after the entry to still let 'output' attach " ..
    "to the same example:\n" .. tostring(code))
end

local function test_a_multi_file_example_writes_every_file_before_the_entry()
  local blocks: {Block} = {
    block("teal", "return 1", mods(false, "a.tl", nil)),
    block("teal", "return 2", mods(false, "b.tl", nil)),
    block("teal", 'print("entry")', no_mods),
  }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  local at_a = code:find("__doctest_write(tmp, \"a.tl\"", 1, true)
  local at_b = code:find("__doctest_write(tmp, \"b.tl\"", 1, true)
  local at_entry = code:find('print("entry")', 1, true)
  assert(at_a ~= nil and at_b ~= nil and at_entry ~= nil, "got:\n" .. code)
  assert(at_a < at_entry and at_b < at_entry,
    "expected both files written before the entry runs:\n" .. code)
end

local function test_no_example_needs_no_helpers_at_all()
  local blocks: {Block} = { block("text", "just prose", no_mods) }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  assert(code:find("require(\"cosmic.fs\")", 1, true) == nil, "got:\n" .. code)
  assert(code:find("__doctest_capture", 1, true) == nil, "got:\n" .. code)
end

--- The generated file names each example's line in the doc, which the
--- build shows in place of the generated file's own lines.
local function test_each_example_names_its_doc_line()
  local first = block("teal", "local x = 1", no_mods)
  local second = block("teal", 'print("hi")', no_mods)
  second.line = 12
  local blocks: {Block} = { first, second, block("output", "hi", no_mods) }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  assert(code:find("\n-- line example_1 1\n", 1, true) ~= nil, "got:\n" .. code)
  assert(code:find("\n-- line test_2 12\n", 1, true) ~= nil, "got:\n" .. code)
end

--- A doc's `inputs` line becomes its module's top-level declaration,
--- which the build reads as a test module's; a second is refused.
local function test_a_docs_inputs_become_its_declaration()
  local blocks: {Block} = {
    { lang = "inputs", modifiers = no_mods, content = "processes = true", line = 3 },
    block("teal", "local x = 1", no_mods),
  }
  local code, trouble = generate.from_blocks(blocks, "fixture.md")
  assert(code ~= nil, "generate failed: " .. tostring(trouble))
  assert(code:find("\nlocal _inputs = { processes = true }\n", 1, true) ~= nil, "got:\n" .. code)
  assert(code:find("local function example_1", 1, true) ~= nil, "got:\n" .. code)
  blocks[#blocks + 1] = { lang = "inputs", modifiers = no_mods, content = "tool = true", line = 9 }
  local again, again_trouble = generate.from_blocks(blocks, "fixture.md")
  assert(again == nil, "a second declaration was taken")
  assert(again_trouble == "line 9: a doc declares its inputs once; line 3 did already",
    again_trouble)
end

--- A doc's `inputs` line stands between the braces of one table
--- literal or is refused: nothing in it closes the literal early or
--- swallows its close.
local function test_a_docs_inputs_line_that_would_escape_its_literal_is_refused()
  local cases: {{string}} = {
    { "tool = true }, _x = { store = true", "closes a brace it never opened" },
    { "env = { \"A\"", "leaves a brace open" },
    { "tool = true -- }", "holds a comment" },
    { "reads = { [[a}]] }", "holds a long bracket" },
    { "reads = { \"a }", "leaves a string open" },
  }
  for _, case in ipairs(cases) do
    local blocks: {Block} = {
      { lang = "inputs", modifiers = no_mods, content = case[1], line = 4 },
      block("teal", "local x = 1", no_mods),
    }
    local code, trouble = generate.from_blocks(blocks, "fixture.md")
    assert(code == nil, case[1] .. " was spliced")
    assert(trouble == "line 4: the inputs line " .. case[2], case[1] .. ": " .. trouble)
  end
  local ok = generate.from_blocks({
    { lang = "inputs", modifiers = no_mods, content = 'env = { "}{" }, tool = true', line = 4 },
  }, "fixture.md")
  assert(ok ~= nil and ok:find('local _inputs = { env = { "}{" }, tool = true }', 1, true) ~= nil,
    tostring(ok))
end
