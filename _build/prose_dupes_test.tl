#!/usr/bin/env cosmic
--- reads: _build
--- reads: _cli
--- reads: _docs
--- reads: _eval
--- reads: _fuzz
--- reads: _make
--- reads: _perf
--- reads: _tool
--- reads: _types
--- reads: cmd
--- reads: cosmic
--- reads: docs
--- reads: skills
--- reads: sys
--- reads: README.md
--- reads: AGENTS.md
-- The prose-duplicate gate: the tree holds no two identical doc-comment
-- blocks or markdown paragraphs in the scanned trees, and the scanner's
-- judgments -- the floor, the `reads:`/`ref:` exclusion, the testdata
-- exclusion, fence skipping, and tag/name-blind matching -- are pinned
-- on fixture roots.

local prose_dupes = require("_build.prose_dupes")
local check = require("cosmic.check")
local fs = require("cosmic.fs")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- A fixture project root holding one file per entry in `files`, under
-- one tree directory (mirrors a real scanned tree like "_make" or
-- "docs").
local function fixture(name: string, tree: string,
    files: {string: string}): string
  local root = fs.join(TEST_TMPDIR, name)
  check.must(fs.make_dirs(fs.join(root, tree)))
  for rel, text in pairs(files) do
    check.must(fs.write(fs.join(root, tree, rel), text))
  end
  return root
end

-- A doc-comment block well over the 12-token floor.
local DOC_A = [[
--- This helper trims leading and trailing whitespace from an ordinary
--- string, treating tabs and newlines the same as plain spaces here.
local function trim_thing(s: string): string
  return s
end
]]

-- A markdown paragraph well over the floor, framed by blank lines so
-- it stands alone.
local PARAGRAPH_A = [[
Intro line.

This paragraph describes a shared behavior in enough sentences to
clear the twelve token floor easily for this fixture test case here.

Trailing line.
]]

-- Under the floor: a one-line summary, deliberately exempt.
local SMALL_DOC = [[
--- Close the handle.
local function close_thing(h: any)
end
]]

-- The `reads:` declared-input header convention, long enough to clear
-- the floor on its own but excluded by the rule regardless.
local READS_HEADER = [[
#!/usr/bin/env cosmic
--- reads: _build
--- reads: _cli
--- reads: _docs
--- reads: _eval
--- reads: _fuzz
--- reads: _make
--- reads: _perf
--- reads: _tool
local x = 1
]]

-- A fenced code block repeated verbatim: code, not prose, so it is
-- gated by _build/snippets_test.tl instead of this one.
local FENCED_GUIDE = [[
Intro line.

```lua
local greeting = "hello there, this is a fenced code block example"
print(greeting)
```

Trailing line.
]]

local function test_true_duplicate_fails_naming_both_sites()
  local root = fixture("prose-doc-true", "_make",
    {["a.tl"] = DOC_A, ["b.tl"] = DOC_A})
  local found = prose_dupes.scan(root)
  check.equal(#found, 1, "one duplicate group")
  assert(found[1]:find("_make/a.tl:1", 1, true), found[1])
  assert(found[1]:find("_make/b.tl:1", 1, true), found[1])
  assert(found[1]:find("identical prose", 1, true), found[1])
end

local function test_duplicated_markdown_paragraph_fails()
  local root = fixture("prose-md-true", "docs",
    {["a.md"] = PARAGRAPH_A, ["b.md"] = PARAGRAPH_A})
  check.equal(#prose_dupes.scan(root), 1,
    "a paragraph copied into a second guide is a duplicate")
end

local function test_units_under_the_floor_pass()
  local root = fixture("prose-doc-small", "_make",
    {["a.tl"] = SMALL_DOC, ["b.tl"] = SMALL_DOC})
  check.equal(#prose_dupes.scan(root), 0,
    "a one-line summary under the floor is legitimately shared")
end

local function test_shared_reads_header_passes()
  local root = fixture("prose-reads", "_make",
    {["a_test.tl"] = READS_HEADER, ["b_test.tl"] = READS_HEADER})
  check.equal(#prose_dupes.scan(root), 0,
    "the declared-input header convention is excluded by rule")
end

local function test_fenced_block_repeated_in_two_guides_passes()
  local root = fixture("prose-fence", "docs",
    {["a.md"] = FENCED_GUIDE, ["b.md"] = FENCED_GUIDE})
  check.equal(#prose_dupes.scan(root), 0,
    "fenced code is gated by _build/snippets_test.tl, not this one")
end

-- The shared sentences below are built from one string, never repeated
-- literally in this file's own source -- otherwise this test file
-- would fail test_the_tree_holds_no_duplicates against itself.
local SHARED_TRIM_DOC = "--- Trim surrounding whitespace from the given"
.. " text before returning\n--- it, collapsing interior tab and newline"
.. " runs into single spaces.\n"

local function test_tag_only_difference_does_not_separate_two_blocks()
  local doc_a = SHARED_TRIM_DOC
  .. "--- @param s string The text to trim\n"
  .. "local function trim_a(s: string): string\n  return s\nend\n"
  local doc_b = SHARED_TRIM_DOC
  .. "--- @param text string The text to trim\n"
  .. "local function trim_b(text: string): string\n  return text\nend\n"
  local root = fixture("prose-tag-only", "_make",
    {["a.tl"] = doc_a, ["b.tl"] = doc_b})
  check.equal(#prose_dupes.scan(root), 1,
    "a renamed @param does not keep two otherwise identical blocks apart")
end

local function test_the_tree_holds_no_duplicates()
  local found = prose_dupes.scan(".")
  assert(#found == 0, "duplicated prose in the tree:\n"
    .. table.concat(found, "\n"))
end

print("all prose-duplicate tests passed")
