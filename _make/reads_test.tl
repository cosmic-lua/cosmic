#!/usr/bin/env cosmic
-- Tests for the `@reads` channel: the scan, the expansion, and the
-- refusal.
--
-- The failure this closes is silent in both directions, which is why
-- each half is asserted on its own. A declaration the scanner MISSES
-- leaves a ratchet re-running only in a fresh tree -- green, stale,
-- indistinguishable from a pass. A declaration that expands to too
-- LITTLE is the same failure one step later, and the deletion case is
-- the one that needs the directory: every surviving file is untouched
-- when a sibling disappears.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local project = require("_make.project")
local reads = require("_make.reads")
local types = require("_make.types")

local type Issue = types.Issue
local type Project = types.Project

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Build a fixture tree, returning its absolute root.
local function tree(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "reads-" .. name)
  fs.rmrf(root)
  assert(fs.makedirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.makedirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  return root
end

--- The same, scanned into a project.
local function fixture(name: string, files: {string: string}): Project
  local proj = check.must(project.scan(tree(name, files)))
  return proj
end

--- A scan's result as one comparable string.
local function scanned(src: string): string
  return table.concat(reads.scan(src), " ")
end

-- A declaration is a comment line and nothing else. Both comment
-- spellings, any indentation, and the whole rest of the line is the
-- pattern -- so a trailing note cannot be read as part of a path.
local function test_scan_finds_declarations()
  assert(scanned("-- @reads docs/*.md\n") == "docs/*.md", "plain comment")
  assert(scanned("--- @reads a.txt\n") == "a.txt", "doc comment")
  assert(scanned("  --@reads a.txt\n") == "a.txt", "indented, no space")
  assert(scanned("-- @reads a.txt\n-- @reads b/*.yml\n") == "a.txt b/*.yml",
    "one per line, in file order")
end
test_scan_finds_declarations()

-- And nothing else is one. The line-anchored scan is the whole rule:
-- code that merely mentions the marker declares nothing, or every
-- test of this file would declare what it is testing.
local function test_scan_ignores_everything_else()
  assert(scanned('local s = "-- @reads a.txt"\n') == "",
    "a marker inside code is not a declaration")
  assert(scanned("-- @readsa.txt\n") == "", "the marker is a whole word")
  assert(scanned("-- @reads a.txt trailing prose\n") == "",
    "a declaration is the whole line, so an ambiguous one is refused")
  assert(scanned("-- @reads\n") == "", "a marker with no path names nothing")
end
test_scan_ignores_everything_else()

-- Expansion names the files AND the directories a glob read. The
-- directory is what makes a deletion visible: remove `b.md` and every
-- other prerequisite has the mtime it always had.
local function test_expand_lists_matches_and_their_directory()
  local root = tree("expand", {
      ["docs/a.md"] = "a\n",
      ["docs/b.md"] = "b\n",
      ["docs/notes.txt"] = "n\n",
      ["top.md"] = "t\n",
    })
  assert(table.concat(reads.expand(root, "docs/*.md"), " ") ==
    "docs docs/a.md docs/b.md",
    "a glob names its matches and the directory they came from: " ..
    table.concat(reads.expand(root, "docs/*.md"), " "))
  assert(table.concat(reads.expand(root, "docs/a.md"), " ") == "docs/a.md",
    "an exact path is one file, and its directory is not an input")
  assert(table.concat(reads.expand(root, "top.md"), " ") == "top.md",
    "a root-level file has no directory to add")
  assert(#reads.expand(root, "docs/*.yml") == 0, "a glob may match nothing")
end
test_expand_lists_matches_and_their_directory()

-- A declaration that matches nothing is refused. It is worse than no
-- declaration: it reads as though the staleness hole is closed.
local function test_a_declaration_that_names_nothing_is_refused()
  local proj = fixture("dangling", {
      ["main.tl"] = "print('x')\n",
      ["a_test.tl"] = "-- @reads docs/*.md\nassert(true)\n",
    })
  local issues: {Issue} = {}
  reads.check(proj, issues)
  assert(#issues == 1, "expected one issue, got " .. #issues)
  assert(issues[1].path == "a_test.tl", "got: " .. issues[1].path)
  assert(issues[1].message:find("matches no file", 1, true),
    "the message must say what is wrong: " .. issues[1].message)
end
test_a_declaration_that_names_nothing_is_refused()

-- And one that leaves the tree, for the reason the whole model has:
-- a project's inputs are inside the project.
local function test_a_declaration_outside_the_project_is_refused()
  local proj = fixture("escaping", {
      ["main.tl"] = "print('x')\n",
      ["a_test.tl"] = "-- @reads ../elsewhere/*.md\nassert(true)\n",
      ["b_test.tl"] = "-- @reads /etc/hosts\nassert(true)\n",
    })
  local issues: {Issue} = {}
  reads.check(proj, issues)
  assert(#issues == 2, "both spellings are refused, got " .. #issues)
  for _, issue in ipairs(issues) do
    assert(issue.message:find("leaves the project", 1, true),
      "got: " .. issue.message)
  end
end
test_a_declaration_outside_the_project_is_refused()

-- A declaration that names files is clean, and an asset carrying the
-- marker is not a declaration at all: only the kinds whose sources are
-- scanned declare anything, or a fixture's contents would speak for
-- the project holding it.
local function test_a_matching_declaration_is_clean()
  local proj = fixture("clean", {
      ["main.tl"] = "print('x')\n",
      ["docs/a.md"] = "a\n",
      ["a_test.tl"] = "-- @reads docs/*.md\nassert(true)\n",
      ["notes.md"] = "-- @reads nothing/at/all.md\n",
    })
  local issues: {Issue} = {}
  reads.check(proj, issues)
  assert(#issues == 0, "expected no issues, got " ..
    (#issues > 0 and issues[1].message or ""))
end
test_a_matching_declaration_is_clean()

-- The memo's lifetime is one model build, the same as the import
-- scanner's: within a build the tree is a snapshot, across builds it
-- may have changed.
local function test_forget_drops_the_memo()
  local root = tree("memo", {["a_test.tl"] = "-- @reads x.md\n"})
  local path = fs.join(root, "a_test.tl")
  assert(#reads.of_file(path) == 1, "the first read scans")
  assert(fs.write(path, "-- @reads y.md\n-- @reads z.md\n"))
  assert(#reads.of_file(path) == 1, "within a build the answer is memoized")
  reads.forget()
  assert(#reads.of_file(path) == 2, "after forget the file is read again")
end
test_forget_drops_the_memo()

print("all reads tests passed")
