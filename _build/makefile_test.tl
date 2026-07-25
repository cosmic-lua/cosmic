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

-- test: only= filters check TARGETS but never artifact source lists
-- (#608, #777). A filter matching nothing must leave every input to a
-- shipped artifact complete: a filtered doc_index_srcs regenerates
-- o/docs/.index.lua from a subset and the broken index gets embedded,
-- and a filtered cosmic_lua/cosmic_tl packs a TRUNCATED STDLIB into the
-- binary — silently, since a subset build still succeeds.
--
-- Since #777 the filter is applied inside the target-list derivations
-- rather than to the source lists, so completeness holds by
-- construction. These assertions are what makes that falsifiable: they
-- fail if a filter-only call migrates back up into a source list.
local function assert_complete(out: string, var: string, needle: string)
  local value = out:match("\n" .. var .. " := ([^\n]*)")
  assert(value, "expected " .. var .. " in filtered database output")
  assert(value:find(needle, 1, true),
    var .. " must stay complete under only= (missing " .. needle ..
    "), got: " .. value:sub(1, 200))
end

local function test_only_filter_exempts_artifact_sources()
  local out = read_make_output("only-database.out").output

  -- doc index inputs (#608, the original break)
  assert_complete(out, "doc_index_srcs", "cosmic/json.tl")
  assert_complete(out, "doc_index_srcs", "cosmic/env_example.tl")
  assert_complete(out, "doc_index_srcs", "_types/cosmo/unix.d.tl")
  assert_complete(out, "doc_index_lua", "json.lua")

  -- published docs inputs
  assert_complete(out, "all_tl", "cosmic/json.tl")

  -- THE BINARY'S PACK INPUTS (#777): the gap the #608 fix left open.
  -- pack_copies is recursive, so it renders unexpanded; these are the
  -- two lists it expands, and they are what decides the embedded stdlib.
  assert_complete(out, "cosmic_tl", "cosmic/json.tl")
  assert_complete(out, "cosmic_lua", "json.lua")

  -- fetch/stage inputs: a cold parallel build that loses these falls
  -- back to the bootstrap's embedded stdlib (the #666/#608 axis)
  assert_complete(out, "stdlib_lua", "json.lua")

  -- and the filter itself must still work: the check TARGET lists empty
  -- out even though their source lists stayed whole
  local tested = out:match("\nall_tested := ([^\n]*)")
  assert(tested, "expected all_tested in filtered database output")
  assert(not tested:find("_test.tl", 1, true),
    "all_tested should be empty under a non-matching only=, got: " ..
    tested:sub(1, 200))
  local sources = out:match("\nall_tests := ([^\n]*)")
  assert(sources and sources:find("_test.tl", 1, true),
    "all_tests (the SOURCE list) should stay complete under only=")
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

-- test: .ENV strips undeclared variables (#756 item 5). The same
-- fixture sends CANARY=evil through the nested make; the clamped probe
-- must never see it, while its declared LC_ALL still flows through.
local function test_env_allowlist_strips_canary()
  local out = read_make_output("env-clamp.out").output
  assert(out:find("CANARY=unset", 1, true),
    "expected the .ENV-clamped probe to report CANARY=unset\noutput: " ..
    out:sub(1, 500))
  assert(not out:find("CANARY=evil", 1, true),
    "hostile CANARY leaked into an .ENV-clamped recipe\noutput: " ..
    out:sub(1, 500))
  assert(out:find("CLAMPED_LC_ALL=C", 1, true),
    "declared LC_ALL should still reach the clamped probe\noutput: " ..
    out:sub(1, 500))
end
test_env_allowlist_strips_canary()

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
  -- the compile family must wire type resolution to the tree-only path:
  -- the o/%.lua pattern's target-specific export shows in the database
  -- as a target block whose variable line carries the raw reference
  local pinned = false
  for value in out:gmatch("o/%%%.lua :\n[^\n]*\n# TL_PATH := ([^\n]*)") do
    pinned = value == "$$(tree_tl_path)"
  end
  assert(pinned,
    "expected the o/%.lua family to export TL_PATH=$(tree_tl_path)")
  -- and the resolved value must be absolute, tree-only, no /zip fallback
  local tl_path = out:match("\ntree_tl_path := ([^\n]*)")
  assert(tl_path, "expected tree_tl_path definition in database output")
  -- The tree's module root is the repo root since 3b, so "absolute and
  -- tree-anchored" is now asserted against CURDIR itself rather than
  -- against the `lib/` directory that used to sit under it.
  local root = check.must(fs.getcwd())
  assert(tl_path:find(root .. "/?.lua", 1, true),
    "tree_tl_path should search the tree root absolutely, got: " .. tl_path)
  assert(tl_path:find("/_types/?.lua", 1, true),
    "tree_tl_path should search _types absolutely, got: " .. tl_path)
  assert(not tl_path:find("/zip", 1, true),
    "tree_tl_path must not fall back to the bootstrap's embedded /zip source, got: " .. tl_path)
  for entry in tl_path:gmatch("[^;]+") do
    assert(entry:sub(1, 1) == "/",
      "tree_tl_path entries must be absolute (CURDIR-anchored), got: " .. entry)
  end
end
test_compile_pins_tree_only_tl_path()

-- The lint file list must include untracked-but-not-ignored files.
--
-- lint is the only gate whose file list comes from git rather than from
-- a wildcard: teal/format/test enumerate via $(wildcard ...) in each
-- cook.mk and so see a file the moment it exists, but lint asks git.
-- With a bare `git ls-files` that meant a brand-new file was linted
-- ZERO times locally -- `bin/make lint` reported green on a file it had
-- never opened -- and first failed in CI, where the checkout has it
-- tracked. --others is what closes that; --exclude-standard is what
-- keeps o/ and other ignored build output out of the list.
--
-- Asserted against the makefile source because both flags vanish from
-- make's database: lint_files is `:=`, so the database records the
-- expanded file list, not the command that produced it.
local function test_lint_lists_untracked_files()
  local src = check.must(fs.read("mk/check.mk"), "failed to read mk/check.mk")
  local cmd = src:match("lint_files%s*:=[^\n]*\n?[^\n]*")
  assert(cmd, "mk/check.mk should define lint_files from git ls-files")
  assert(cmd:find("ls%-files"), "lint_files should come from git ls-files")
  assert(cmd:find("%-%-others"),
    "lint_files must pass --others or new files go unlinted until staged")
  assert(cmd:find("%-%-exclude%-standard"),
    "lint_files must pass --exclude-standard so ignored build output "
    .. "stays out of the lint set")
end
test_lint_lists_untracked_files()

-- Both check gates must terminate the outer option parse with `--`
-- before the child command (#801).
--
-- `cosmic --test <out> <cmd...>` hands <cmd...> to a child, but the
-- OUTER getopt parses the whole argv first, so a child command that
-- begins with flags loses them: the child runs argument-less, drops
-- into the REPL, exits 0, and --test records a pass for a check that
-- never ran. Every teal and format .got was a 0 for exactly this
-- reason, on every file, indefinitely.
--
-- lint (mk/check.mk) already had its `--`; the test rules have no
-- inner flags to lose. These two are the ones that were wrong, so
-- they are the ones pinned here.
local function test_check_gates_terminate_the_outer_parse()
  local src = check.must(fs.read("mk/check.mk"), "failed to read mk/check.mk")
  for _, gate in ipairs({"check%-types", "check%-format"}) do
    local recipe = src:match("[^\n]*%-%-test[^\n]*" .. gate .. "[^\n]*")
    assert(recipe,
      "expected a --test recipe invoking --" .. gate:gsub("%%", ""))
    -- non-greedy to a standalone `--`: the out path is $(basename $@),
    -- which itself contains a space, so a %S+ span does not reach it
    assert(recipe:match("%-%-test.-%s%-%-%s"),
      "the " .. gate:gsub("%%", "") .. " recipe must pass `--` after the "
      .. "out path, or the child loses its flags and the gate always "
      .. "passes; got: " .. recipe)
  end
end
test_check_gates_terminate_the_outer_parse()

-- Every .tl the build knows about must be reachable by the check gates
-- (#800). teal/format enumerate through per-directory $(wildcard ...)
-- lists hand-written in each cook.mk, and make has no recursive glob --
-- $(wildcard lib/**/*.tl) returns a fraction of the tree -- so a
-- directory nobody remembers to declare is silently unchecked,
-- unformatted and untested. Not just locally: CI runs the same
-- wildcards, so nothing anywhere catches it.
--
-- Both sides come from the make database, so this needs no git call and
-- no extra sandbox grant: lint_files is git's view (#799) and
-- all_source_files is what the gates enumerate.
--
-- .d.tl is the one deliberate exclusion: those are generated
-- declarations that gentype_test asserts byte-for-byte against
-- generator output, so formatting them would fight the generator.
local function db_tl_set(db: string, name: string): {string: boolean}
  local line = db:match("\n" .. name .. " :=([^\n]*)")
  assert(line, "expected " .. name .. " in the make database")
  local set: {string: boolean} = {}
  for word in line:gmatch("%S+") do
    if word:match("%.tl$") then
      set[word] = true
    end
  end
  return set
end

local function test_every_tl_is_reachable_by_the_check_gates()
  local db = read_make_output("database.out").output
  local declared = db_tl_set(db, "all_source_files")
  local missing: {string} = {}
  for path in pairs(db_tl_set(db, "lint_files")) do
    if not path:match("%.d%.tl$") and not declared[path] then
      missing[#missing + 1] = path
    end
  end
  table.sort(missing)
  assert(#missing == 0,
    "these .tl files are in the tree but no cook.mk declares them, so "
    .. "teal/format/test never see them -- add the directory to the "
    .. "module's _srcs:\n  " .. table.concat(missing, "\n  "))
end
test_every_tl_is_reachable_by_the_check_gates()
