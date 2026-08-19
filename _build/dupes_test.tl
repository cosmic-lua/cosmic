#!/usr/bin/env cosmic
--- reads: _make
--- reads: _cli
-- The duplicate-body gate: the tree holds no two identical top-level
-- function bodies in the scanned trees, and the scanner's judgments --
-- rename-blind matching, the one-statement difference, the size floor,
-- the test/testdata exclusions -- are pinned on fixture roots.

local dupes = require("_build.dupes")
local check = require("cosmic.check")
local fs = require("cosmic.fs")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- A fixture project root holding one _make file per entry in `files`.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(TEST_TMPDIR, name)
  check.must(fs.make_dirs(fs.join(root, "_make")))
  for rel, text in pairs(files) do
    check.must(fs.write(fs.join(root, "_make", rel), text))
  end
  return root
end

local BODY_A = [[
local function greet(name: string): string
  local prefix = "hello, "
  local suffix = "!"
  local joined = prefix .. name .. suffix
  return joined
end
]]

-- The same body with the parameter renamed -- the rename-only copy
-- the normalization exists to catch (the historical case was
-- byte-identical modulo one parameter rename; the function NAME is
-- part of the body and a differently-named function is not a copy).
local BODY_A_RENAMED = [[
local function greet(who: string): string
  local prefix = "hello, "
  local suffix = "!"
  local joined = prefix .. who .. suffix
  return joined
end
]]

-- One statement differs: not a duplicate.
local BODY_B = [[
local function greet(name: string): string
  local prefix = "goodbye, "
  local suffix = "!"
  local joined = prefix .. name .. suffix
  return joined
end
]]

-- Under the floor: a trivial forwarder, deliberately exempt.
local SMALL = [[
local function fail(msg: string): integer
  io.write(msg)
  return 1
end
]]

local function test_true_duplicate_fails_naming_both_sites()
  local root = fixture("dup-true", {["a.tl"] = BODY_A, ["b.tl"] = BODY_A})
  local found = dupes.scan(root)
  check.equal(#found, 1, "one duplicate group")
  assert(found[1]:find("_make/a.tl:1", 1, true), found[1])
  assert(found[1]:find("_make/b.tl:1", 1, true), found[1])
  assert(found[1]:find("export one and require it", 1, true), found[1])
end
test_true_duplicate_fails_naming_both_sites()

local function test_renamed_parameters_still_match()
  local root = fixture("dup-renamed",
    {["a.tl"] = BODY_A, ["b.tl"] = BODY_A_RENAMED})
  check.equal(#dupes.scan(root), 1, "rename-only copy is a duplicate")
end
test_renamed_parameters_still_match()

local function test_one_statement_difference_passes()
  local root = fixture("dup-diff", {["a.tl"] = BODY_A, ["b.tl"] = BODY_B})
  check.equal(#dupes.scan(root), 0, "a changed statement is not a copy")
end
test_one_statement_difference_passes()

local function test_bodies_under_the_floor_pass()
  local root = fixture("dup-small", {["a.tl"] = SMALL, ["b.tl"] = SMALL})
  check.equal(#dupes.scan(root), 0, "sub-floor forwarders are exempt")
end
test_bodies_under_the_floor_pass()

local function test_tests_and_testdata_are_excluded()
  local root = fixture("dup-excluded", {["a_test.tl"] = BODY_A})
  check.must(fs.make_dirs(fs.join(root, "_make", "testdata")))
  check.must(fs.write(fs.join(root, "_make", "testdata", "b.tl"), BODY_A))
  check.must(fs.write(fs.join(root, "_make", "c.tl"), BODY_A))
  check.equal(#dupes.scan(root), 0,
    "one non-test copy beside excluded copies is no duplicate")
end
test_tests_and_testdata_are_excluded()

local function test_the_tree_holds_no_duplicates()
  local found = dupes.scan(".")
  assert(#found == 0, "duplicated bodies in the tree:\n"
    .. table.concat(found, "\n"))
end
test_the_tree_holds_no_duplicates()

print("all duplicate-body tests passed")
