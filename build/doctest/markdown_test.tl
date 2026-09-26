--- `build.doctest.markdown` needs no compiler capsule at all -- it only
--- ever reads fence lines and an info string -- so these tests build a
--- markdown fixture as a plain string and call `parse_blocks` directly.
local markdown = require("build.doctest.markdown")

--- Joins lines the way a real doc would read, without a fixture string
--- embedding a literal ``` sequence anywhere in THIS file's own source
--- -- see build/analyzer_test.tl's `lines` for why that would matter.
local function doc(parts: {string}): string
  return table.concat(parts, "\n") .. "\n"
end

local function test_finds_a_bare_teal_block()
  local blocks, trouble = markdown.parse_blocks(doc({
    "```teal",
    'print("hi")',
    "```",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(#blocks == 1, "expected 1 block, got " .. #blocks)
  assert(blocks[1].lang == "teal")
  assert(blocks[1].content == 'print("hi")')
  assert(blocks[1].line == 1)
  assert(not blocks[1].modifiers.continue)
  assert(blocks[1].modifiers.file == nil)
  assert(blocks[1].modifiers.skip == nil)
end

local function test_reads_a_multi_line_block_and_a_following_output_block()
  local blocks, trouble = markdown.parse_blocks(doc({
    "prose before",
    "",
    "```teal",
    "local a = 1",
    "local b = 2",
    "print(a + b)",
    "```",
    "",
    "```output",
    "3",
    "```",
    "",
    "prose after",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(#blocks == 2, "expected 2 blocks, got " .. #blocks)
  assert(blocks[1].lang == "teal")
  assert(blocks[1].content == "local a = 1\nlocal b = 2\nprint(a + b)")
  assert(blocks[1].line == 3)
  assert(blocks[2].lang == "output")
  assert(blocks[2].content == "3")
  assert(blocks[2].line == 9)
end

local function test_reads_the_file_modifier()
  local blocks, trouble = markdown.parse_blocks(doc({
    "```teal file=helper.tl",
    "local record helper",
    "end",
    "return helper",
    "```",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(blocks[1].modifiers.file == "helper.tl",
    "got: " .. tostring(blocks[1].modifiers.file))
end

local function test_reads_the_skip_modifier_with_its_reason()
  local blocks, trouble = markdown.parse_blocks(doc({
    "```teal skip=network",
    'fetch("https://example.com")',
    "```",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(blocks[1].modifiers.skip == "network",
    "got: " .. tostring(blocks[1].modifiers.skip))
end

local function test_reads_the_continue_modifier()
  local blocks, trouble = markdown.parse_blocks(doc({
    "```teal continue",
    "print(a)",
    "```",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(blocks[1].modifiers.continue)
end

local function test_refuses_combining_continue_and_file()
  local blocks, trouble = markdown.parse_blocks(doc({
    "```teal continue file=x.tl",
    "print(a)",
    "```",
  }))
  assert(blocks == nil, "expected the combination to be refused")
  assert(trouble:find("cannot combine", 1, true) ~= nil, "got: " .. trouble)
end

local function test_refuses_an_unknown_tag()
  local blocks, trouble = markdown.parse_blocks(doc({
    "```sh",
    "echo hi",
    "```",
  }))
  assert(blocks == nil, "expected an unknown tag to be refused")
  assert(trouble:find("unknown fenced block tag 'sh'", 1, true) ~= nil,
    "got: " .. trouble)
end

local function test_refuses_a_modifier_on_a_text_block()
  local blocks, trouble = markdown.parse_blocks(doc({
    "```text extra",
    "prose",
    "```",
  }))
  assert(blocks == nil, "expected a modifier on a text block to be refused")
  assert(trouble:find("takes no modifiers", 1, true) ~= nil, "got: " .. trouble)
end

local function test_refuses_an_unterminated_fence()
  local blocks, trouble = markdown.parse_blocks(doc({
    "```teal",
    'print("hi")',
  }))
  assert(blocks == nil, "expected an unterminated fence to be refused")
  assert(trouble:find("never closes", 1, true) ~= nil, "got: " .. trouble)
end

local function test_ignores_prose_with_no_fence_at_all()
  local blocks, trouble = markdown.parse_blocks(doc({
    "# A title",
    "",
    "Just words, no code.",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(#blocks == 0, "expected no blocks, got " .. #blocks)
end

local function test_reads_a_bare_lua_block()
  local blocks, trouble = markdown.parse_blocks(doc({
    "```lua",
    'print("hi")',
    "```",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(blocks[1].lang == "lua")
end

local function test_finds_a_bare_tilde_teal_block()
  local blocks, trouble = markdown.parse_blocks(doc({
    "~~~teal",
    'print("hi")',
    "~~~",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(#blocks == 1, "expected 1 block, got " .. #blocks)
  assert(blocks[1].lang == "teal")
  assert(blocks[1].content == 'print("hi")')
  assert(blocks[1].line == 1)
end

local function test_reads_the_file_modifier_with_a_tilde_fence()
  local blocks, trouble = markdown.parse_blocks(doc({
    "~~~teal file=helper.tl",
    "local record helper",
    "end",
    "return helper",
    "~~~",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(blocks[1].modifiers.file == "helper.tl",
    "got: " .. tostring(blocks[1].modifiers.file))
end

local function test_reads_the_skip_modifier_with_a_tilde_fence()
  local blocks, trouble = markdown.parse_blocks(doc({
    "~~~teal skip=network",
    'fetch("https://example.com")',
    "~~~",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(blocks[1].modifiers.skip == "network",
    "got: " .. tostring(blocks[1].modifiers.skip))
end

--- A backtick fence's content passes a bare `~~~` line straight through
--- as content rather than treating it as a close: the two marker
--- styles are not interchangeable for one fence.
local function test_a_backtick_fence_is_not_closed_by_a_tilde_line()
  local blocks, trouble = markdown.parse_blocks(doc({
    "```teal",
    "~~~",
    "```",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(#blocks == 1, "expected 1 block, got " .. #blocks)
  assert(blocks[1].content == "~~~", "got: " .. blocks[1].content)
end

--- The reverse of the above, and the main reason CommonMark gives docs
--- two marker styles: a tilde fence can hold literal backtick content.
local function test_a_tilde_fence_holds_backtick_content()
  local blocks, trouble = markdown.parse_blocks(doc({
    "~~~teal",
    "-- ```",
    "print(1)",
    "~~~",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(#blocks == 1, "expected 1 block, got " .. #blocks)
  assert(blocks[1].content == "-- ```\nprint(1)", "got: " .. blocks[1].content)
end

local function test_a_long_backtick_fence_holds_a_shorter_marker()
  local blocks, trouble = markdown.parse_blocks(doc({
    "`````teal",
    "````",
    "print(1)",
    "`````",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(blocks[1].content == "````\nprint(1)", "got: " .. blocks[1].content)
end

local function test_a_long_tilde_fence_holds_a_shorter_marker_and_accepts_a_longer_close()
  local blocks, trouble = markdown.parse_blocks(doc({
    "~~~~teal",
    "~~~",
    "print(1)",
    "~~~~~~",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(blocks[1].content == "~~~\nprint(1)", "got: " .. blocks[1].content)
end

local function test_refuses_an_indented_backtick_fence()
  local blocks, trouble = markdown.parse_blocks(doc({
    "prose",
    "  ```teal",
    'print("hi")',
    "  ```",
  }))
  assert(blocks == nil, "expected an indented fence to be refused")
  assert(trouble:find("indented fences are not supported", 1, true) ~= nil,
    "got: " .. trouble)
  assert(trouble:find("line 2", 1, true) ~= nil, "got: " .. trouble)
end

local function test_refuses_an_indented_tilde_fence()
  local blocks, trouble = markdown.parse_blocks(doc({
    "prose",
    "  ~~~teal",
    'print("hi")',
    "  ~~~",
  }))
  assert(blocks == nil, "expected an indented fence to be refused")
  assert(trouble:find("indented fences are not supported", 1, true) ~= nil,
    "got: " .. trouble)
end

--- A line `<!-- inputs: ... -->` outside a fence is the doc's inputs
--- declaration, a block of its own; the same line inside a fence is the
--- fence's text, and any other comment is prose.
local function test_reads_an_inputs_line_outside_a_fence()
  local blocks, trouble = markdown.parse_blocks(doc({
    "# a guide",
    "",
    "<!--   inputs: processes = true   -->",
    "<!-- a comment -->",
    "```teal",
    "<!-- inputs: tool = true -->",
    "```",
  }))
  assert(blocks ~= nil, "parse failed: " .. tostring(trouble))
  assert(#blocks == 2, "expected 2 blocks, got " .. #blocks)
  assert(blocks[1].lang == "inputs" and blocks[1].content == "processes = true",
    blocks[1].lang .. ": " .. blocks[1].content)
  assert(blocks[1].line == 3)
  assert(blocks[2].lang == "teal" and blocks[2].content == "<!-- inputs: tool = true -->")
end
