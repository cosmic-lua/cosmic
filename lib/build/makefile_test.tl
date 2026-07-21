#!/usr/bin/env cosmic
-- Test the actual repo Makefile using pre-generated make outputs

local check = require("cosmic.check")
local fs = require("cosmic.fs")

local TEST_DIR = os.getenv("TEST_DIR")

local record MakeOutput
  output: string
  exit_code: number
end

local function read_make_output(filename: string): MakeOutput
  local filepath = fs.join(TEST_DIR, filename)
  local text = check.must(fs.read(filepath), "failed to read " .. filepath)

  local exit_code = text:match("exit:(%d+)%s*$")
  assert(exit_code, "missing exit code in " .. filepath)

  local output = text:gsub("exit:%d+%s*$", "")
  return {
    output = output,
    exit_code = tonumber(exit_code),
  }
end

-- test: make -n files succeeds (validates syntax and prerequisites)
local function test_dry_run_succeeds()
  local result = read_make_output("dry-run.out")
  assert(result.exit_code == 0,
    "expected make -n files to succeed, got code: " .. tostring(result.exit_code) ..
    "\noutput: " .. result.output:sub(1, 500))
end
test_dry_run_succeeds()

-- test: make -p prints database with expected content
local function test_print_database()
  local result = read_make_output("database.out")
  assert(result.output:match("modules"), "expected 'modules' variable in database output")
  assert(result.output:match("%.PHONY"), "expected .PHONY in database output")
  assert(result.output:match("platform"), "expected 'platform' variable in database output")
end
test_print_database()

-- test: only= filters test targets but never artifact source lists (#608).
-- A filter matching nothing must leave the doc-index inputs complete —
-- a filtered doc_index_srcs regenerates o/docs/.index.lua from a subset
-- and the broken index gets embedded in the binary.
local function test_only_filter_exempts_artifact_sources()
  local result = read_make_output("only-database.out")
  local out = result.output

  local doc_srcs = out:match("\ndoc_index_srcs := ([^\n]*)")
  assert(doc_srcs, "expected doc_index_srcs in filtered database output")
  assert(doc_srcs:find("lib/cosmic/json.tl", 1, true),
    "doc_index_srcs should keep module sources under only=")
  assert(doc_srcs:find("lib/cosmic/env_example.tl", 1, true),
    "doc_index_srcs should keep example sources under only=")
  assert(doc_srcs:find("lib/types/cosmo/unix.d.tl", 1, true),
    "doc_index_srcs should keep .d.tl sources under only=")

  local module_srcs = out:match("\nall_module_srcs := ([^\n]*)")
  assert(module_srcs, "expected all_module_srcs in filtered database output")
  assert(module_srcs:find("lib/cosmic/json.tl", 1, true),
    "all_module_srcs (docs inputs) should be exempt from only=")

  -- the filter itself must still work: test lists empty out
  local tests = out:match("\nall_tests := ([^\n]*)")
  assert(tests, "expected all_tests in filtered database output")
  assert(not tests:find("_test.tl", 1, true),
    "all_tests should be empty under a non-matching only=, got: " ..
    tests:sub(1, 200))
end
test_only_filter_exempts_artifact_sources()

-- test: ci grading catches a stage that fails after writing a clean
-- summary (#714). The ci-launder.out fixture runs the ci harness over
-- ci-selftest-launder, whose recipe tees a passing summary and then
-- exits 1 — the per-stage exit marker, not the summary text, must
-- decide the verdict.
local function test_ci_grading_catches_exit_after_clean_summary()
  local result = read_make_output("ci-launder.out")
  local tail = result.output:sub(-500)
  assert(result.exit_code ~= 0,
    "expected ci to fail when a stage exits nonzero after a clean summary" ..
    "\noutput: " .. tail)
  assert(result.output:find("ci: FAIL", 1, true),
    "expected a ci: FAIL verdict line\noutput: " .. tail)
  assert(result.output:find("ci-selftest-launder (exit)", 1, true),
    "expected the failure recorded as an exit failure\noutput: " .. tail)
end
test_ci_grading_catches_exit_after_clean_summary()

-- test: the environment clamp holds under a hostile caller env (#731).
-- The env-clamp.out fixture runs a nested make with a non-C locale, a
-- non-UTC timezone, and a poisoned PATH head; the probe recipe echoes
-- what it actually sees. Recipes must get the pinned values and the
-- deliberately constructed PATH, never the caller's ambient ones.
local function test_env_clamp_holds_under_hostile_env()
  local result = read_make_output("env-clamp.out")
  assert(result.exit_code == 0,
    "expected env-probe to succeed under a hostile env, got code: " ..
    tostring(result.exit_code) .. "\noutput: " .. result.output:sub(1, 500))
  assert(result.output:match("\nLC_ALL=C\n") or result.output:match("^LC_ALL=C\n"),
    "expected recipes to see LC_ALL=C\noutput: " .. result.output:sub(1, 500))
  assert(result.output:match("\nTZ=UTC\n"),
    "expected recipes to see TZ=UTC\noutput: " .. result.output:sub(1, 500))
  local path = result.output:match("\nPATH=([^\n]*)")
  assert(path, "expected a PATH= line in probe output")
  assert(not path:find("/hostile/bin", 1, true),
    "caller's PATH leaked into recipes: " .. path)
  assert(path:find("/o/bootstrap:", 1, true) and path:find("/o/bin:", 1, true),
    "expected the deliberate o/bootstrap and o/bin entries, got: " .. path)
end
test_env_clamp_holds_under_hostile_env()

-- test: the lint stage is guarded against a silently-empty file list
-- (#719). Outside a git checkout `git ls-files` fails silently and
-- lint would green-light zero checks; the summary recipe must carry
-- the loud guard, and the tracked-file machinery must exist. The
-- database dump includes both variable definitions and recipe text.
local function test_lint_guard_present()
  local result = read_make_output("database.out")
  local out = result.output
  assert(out:find("not a git checkout", 1, true),
    "lint summary recipe should fail loudly on an empty git ls-files")
  assert(out:match("\nlint_present := "),
    "expected lint_present (wildcard-filtered tracked files) in database")
  assert(out:match("\nlint_deleted := "),
    "expected lint_deleted (tracked-but-missing files) in database")
end
test_lint_guard_present()

-- test: in-tree compiles pin type resolution to an absolute, tree-only
-- search path (#744). tl.search_module walks its path with io.open and
-- treats any failure — ENOENT, but also a transient EMFILE/ENFILE under
-- the offline lane's parallel sandbox — as "file absent", falling through
-- to the next entry. Its default path also carries the bootstrap's OWN
-- embedded, older copy of this tree under /zip, so a transient miss on a
-- tree source resolved cosmic.* to that stale copy (a cosmic.check
-- predating check.must → "invalid key 'must'"). The compile recipe must
-- set TL_PATH (which overrides tl.path outright) to tree-only roots: no
-- /zip fallback, so a miss fails honestly instead of resolving stale, and
-- CURDIR-anchored so a mis-rooted recipe still resolves.
local function test_compile_pins_tree_only_tl_path()
  local out = read_make_output("database.out").output
  -- the recipe must wire type resolution to the tree-only path
  assert(out:find('export TL_PATH="$(tree_tl_path)"', 1, true),
    "expected the compile recipe to export TL_PATH=$(tree_tl_path)")
  -- and the resolved value must be absolute, tree-only, no /zip fallback
  local tl_path = out:match("\ntree_tl_path := ([^\n]*)")
  assert(tl_path, "expected tree_tl_path definition in database output")
  assert(tl_path:find("/lib/?.lua", 1, true),
    "tree_tl_path should search the tree's lib/ absolutely, got: " .. tl_path)
  assert(tl_path:find("/lib/types/?.lua", 1, true),
    "tree_tl_path should search lib/types absolutely, got: " .. tl_path)
  assert(not tl_path:find("/zip", 1, true),
    "tree_tl_path must not fall back to the bootstrap's embedded /zip source, got: " .. tl_path)
  for entry in tl_path:gmatch("[^;]+") do
    assert(entry:sub(1, 1) == "/",
      "tree_tl_path entries must be absolute (CURDIR-anchored), got: " .. entry)
  end
end
test_compile_pins_tree_only_tl_path()
