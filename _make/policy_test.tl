#!/usr/bin/env cosmic
-- Tests for _make.policy: the two verbs that orchestrate other verbs.
--
-- `ci` takes its registry lookup as an argument, which is what makes it
-- testable without a make binary: a stub registry answers for every
-- stage, so the ORDER, the material gating and the failure reporting
-- are asserted directly rather than inferred from a real run.

local baseline = require("_tool.coverage.baseline")
local check = require("cosmic.check")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local policy = require("_make.policy")
local types = require("_make.types")

local type Kind = types.Kind
local type Project = types.Project
local type Verb = types.Verb

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- A project holding one file of each named kind.
local function project_of(kinds: {Kind}): Project
  local files: {types.File} = {}
  for i, k in ipairs(kinds) do
    files[#files + 1] = {path = "f" .. i .. ".tl", kind = k}
  end
  return {root = "/p", binaries = {}, files = files}
end

--- A stub registry: each verb records that it ran and returns the code
--- the caller asked for.
local record Stub
  lookup: function(name: string): Verb | nil
  --- The names that ran, in order.
  ran: {string}
end

--- @param codes {string: integer} Exit code per verb name, default 0
--- @return Stub The lookup and the record of what it ran
local function registry(codes: {string: integer}): Stub
  local ran: {string} = {}
  return {
    ran = ran,
    lookup = function(name: string): Verb | nil
      return {
        name = name,
        run = function(_p: Project, _paths: {string}, _c: string): integer
          ran[#ran + 1] = name
          return codes[name] or 0
        end,
      }
    end,
  }
end

-- The gate is a fixed order of verb NAMES. If a stage could reimplement
-- what its verb does, the two would drift; this is the assertion that
-- keeps `ci` a list.
local function test_stage_order_is_the_documented_pipeline()
  local names: {string} = {}
  for _, s in ipairs(policy.STAGES) do
    names[#names + 1] = s.verb
  end
  assert(table.concat(names, " ") == "fmt check example lint coverage",
    "got: " .. table.concat(names, " "))
end

-- Every stage is gated by MATERIAL: a project with no tests has no test
-- stage and no coverage stage, and that is a PASS, not an error. A
-- fresh project must not fail on a stage that had nothing to do.
local function test_stages_without_material_are_skipped()
  local stub = registry({})
  local code = policy.run_ci(stub.lookup, project_of({"module"}), {}, "cosmic")
  assert(code == 0, "a project with no tests still passes, got " .. code)
  assert(table.concat(stub.ran, " ") == "fmt check lint",
    "only the unconditional stages run, got: " .. table.concat(stub.ran, " "))
end

-- And with material, every stage runs.
local function test_material_earns_the_stage()
  local stub = registry({})
  local code = policy.run_ci(stub.lookup, project_of({"module", "test", "example"}),
    {}, "cosmic")
  assert(code == 0, "got " .. code)
  assert(table.concat(stub.ran, " ") == "fmt check example lint coverage",
    "got: " .. table.concat(stub.ran, " "))
end

-- A failing stage does not stop the run: a gate that reports one
-- problem per run costs a round trip per problem, and the stages are
-- independent by construction. Every failure is named in the verdict.
local function test_ci_runs_every_stage_and_names_each_failure()
  local stub = registry({check = 1, lint = 1})
  local code = policy.run_ci(stub.lookup, project_of({"module"}), {}, "cosmic")
  assert(code == 1, "a failing stage fails the gate, got " .. code)
  assert(table.concat(stub.ran, " ") == "fmt check lint",
    "a failure must not stop the run, got: " .. table.concat(stub.ran, " "))
end

-- The material test itself, since every stage's gating rests on it.
local function test_has_material()
  local proj = project_of({"module", "test"})
  assert(policy.has(proj, {"test"}), "this project has a test")
  assert(not policy.has(proj, {"example"}), "and no example")
  assert(policy.has(proj, {"example", "test"}), "either kind counts")
end

-- The ratchet is opt-in by committing a floor. Without one, coverage
-- still runs and still passes -- the absence IS the answer to "should
-- there be a ratchet", so nothing has to be configured either way.
local function test_the_baseline_is_a_convention()
  assert(policy.BASELINE == ".cosmic-coverage",
    "the floor is a dot-file at the root, got: " .. policy.BASELINE)
  local dir = fs.join(tmpdir, "policy-nobaseline")
  check.must(fs.make_dirs(dir))
  local cwd = check.must(fs.cwd())
  check.must(fs.set_cwd(dir))
  local absent = not fs.is_file(policy.BASELINE)
  check.must(fs.set_cwd(cwd))
  assert(absent, "the fixture must not have a floor")
end

--- A baseline text literal from `{path, covered, total}` rows, the same
--- shape `_tool/coverage/baseline_test.tl`'s `fixture` builds.
--- @param rows {{string, integer, integer}} path, covered, total triples
--- @return string A `return { ["path"] = {covered = C, total = T}, ... }` literal
local function baseline_fixture(rows: {{string, integer, integer}}): string
  local parts: {string} = {}
  for _, row in ipairs(rows) do
    parts[#parts + 1] = string.format("  [%s] = {covered = %d, total = %d},",
      string.format("%q", row[1]), row[2], row[3])
  end
  return "return {\n" .. table.concat(parts, "\n") .. "\n}\n"
end

-- The bug this guards: `write_baseline` used to hand every row
-- `baseline.lowered` named to this narration unconditionally labeled
-- "LOWERS", so a row that raised printed as though it had declined. A
-- real `--baseline` regen showed exactly that: a raise from 69.0% to
-- 81.2% printed "coverage: baseline LOWERS ...". A mixed rewrite here
-- -- one row raised, one lowered, one untouched -- must label and
-- count each direction correctly.
local function test_narrate_moves_labels_each_direction()
  local before = baseline_fixture({
      {"raised.tl", 5, 10}, {"lowered.tl", 9, 10}, {"same.tl", 10, 10},
    })
  local after = baseline_fixture({
      {"raised.tl", 9, 10}, {"lowered.tl", 3, 10}, {"same.tl", 10, 10},
    })
  local moves = baseline.moved(before, after)
  local lines, raised_count, lowered_count = policy.narrate_moves(moves)

  assert(#lines == 2, "same.tl did not move, want 2 lines, got " ..
    #lines .. ": " .. table.concat(lines, "; "))
  assert(raised_count == 1, "got raised_count=" .. raised_count)
  assert(lowered_count == 1, "got lowered_count=" .. lowered_count)

  local raise_line: string
  local drop_line: string
  for _, line in ipairs(lines) do
    if line:find("raised.tl", 1, true) then raise_line = line end
    if line:find("lowered.tl", 1, true) then drop_line = line end
  end
  assert(raise_line, "no line for raised.tl in: " .. table.concat(lines, "; "))
  assert(drop_line, "no line for lowered.tl in: " .. table.concat(lines, "; "))
  assert(raise_line:find("coverage: baseline RAISES", 1, true),
    "a raise must be labeled RAISES, not LOWERS: " .. raise_line)
  assert(not raise_line:find("LOWERS", 1, true),
    "a raise must never be labeled LOWERS: " .. raise_line)
  assert(drop_line:find("coverage: baseline LOWERS", 1, true),
    "a decline must be labeled LOWERS: " .. drop_line)
  assert(not drop_line:find("RAISES", 1, true),
    "a decline must never be labeled RAISES: " .. drop_line)
end

-- No moves, no lines, no counts -- the untouched-baseline case
-- `write_baseline` hits every time nothing moved.
local function test_narrate_moves_is_empty_for_no_movement()
  local text = baseline_fixture({{"stable.tl", 7, 10}})
  local lines, raised_count, lowered_count =
  policy.narrate_moves(baseline.moved(text, text))
  assert(#lines == 0, "got: " .. table.concat(lines, "; "))
  assert(raised_count == 0 and lowered_count == 0,
    "want 0/0, got raised=" .. raised_count .. " lowered=" .. lowered_count)
end

-- The closing summary is the one line every `--baseline` run ends on,
-- and it is what an operator believes about the rewrite. A floor moves
-- in BOTH directions on a rewrite -- the counts in this very line say
-- so -- and the only refusal is `corpus_guard`'s breadth check, so the
-- line must name that check and send an environment-sensitive row to
-- SENSITIVITY.md, never claim a raise needs a hand.
local function test_wrote_summary_describes_the_breadth_check()
  local line = policy.wrote_summary(2, 1)
  assert(line == "coverage: wrote " .. policy.BASELINE .. " (2 row(s) lowered,"
    .. " 1 raised; corpus_guard refuses only a rewrite dropping more than"
    .. " half the rows — check any environment-sensitive row against"
    .. " cosmic/coverage/SENSITIVITY.md)\n", "got: " .. line)
  assert(not line:find("by hand", 1, true),
    "a raise happens on its own; the summary must not say it needs a hand: " .. line)
  assert(not line:find("only moves up", 1, true),
    "a floor lowers on a rewrite too; the one-way clamp is gone: " .. line)
end

--- A project root `write_baseline` can run against, built the way a
--- real `--baseline` finds one: five three-line modules under `lib/`,
--- one `.cov` under `o/.coverage` measuring them, and a committed floor
--- the run moves in both directions -- `lib/raised.tl` up (1/3 -> 3/3),
--- `lib/lowered_a.tl` and `lib/lowered_b.tl` down (3/3 -> 1/3 and
--- 2/3 -> 1/3), the two `same_*` rows untouched. Two drops of five rows
--- stays under `corpus_guard`'s half, so the rewrite proceeds.
--- @param name string Subdirectory of TEST_TMPDIR to build it in
--- @return string The fixture root
--- @return Project The scanned project, its modules all under `lib/`
local function write_baseline_fixture(name: string): string, Project
  local root = fs.join(tmpdir, name)
  check.must(fs.remove_all(root))
  check.must(fs.make_dirs(fs.join(root, "lib")))
  check.must(fs.make_dirs(fs.join(root, "o", ".coverage")))
  local files: {types.File} = {}
  local hits: {string} = {}
  -- Module stem and how many of its three lines this run covers.
  local run: {{string, integer}} = {
    {"raised", 3}, {"lowered_a", 1}, {"lowered_b", 1}, {"same_a", 2}, {"same_b", 3},
  }
  for _, m in ipairs(run) do
    local path = "lib/" .. m[1] .. ".tl"
    check.must(fs.write(fs.join(root, path),
        "local x = 1\nlocal y = 2\nreturn x + y\n"))
    files[#files + 1] = {path = path, kind = "module"}
    local lines: {string} = {}
    for line = 1, m[2] do
      lines[#lines + 1] = "[" .. line .. "]=1"
    end
    hits[#hits + 1] = '["@' .. path .. '"]={' .. table.concat(lines, ",") .. "}"
  end
  check.must(fs.write(fs.join(root, "o/.coverage/run.cov"),
      "return {version=1,hits={" .. table.concat(hits, ",") .. "}}"))
  check.must(fs.write(fs.join(root, policy.BASELINE), baseline_fixture({
          {"lib/raised.tl", 1, 3}, {"lib/lowered_a.tl", 3, 3},
          {"lib/lowered_b.tl", 2, 3}, {"lib/same_a.tl", 2, 3}, {"lib/same_b.tl", 3, 3},
        })))
  return root, {root = root, binaries = {}, files = files}
end

--- The current value of `COSMIC_COVERAGE_ENV`, to hand to
--- `restore_coverage_env` once a test that flips it is done -- so the
--- marker cannot leak into a later test.
--- @return string | nil The value before a test changes it
local function save_coverage_env(): string | nil
  return env.get("COSMIC_COVERAGE_ENV")
end

--- Restore `COSMIC_COVERAGE_ENV` to what `save_coverage_env` saw.
--- @param saved string | nil The saved value; nil means it was unset
local function restore_coverage_env(saved: string | nil)
  if saved then
    assert(env.set("COSMIC_COVERAGE_ENV", saved, true))
  else
    assert(env.unset("COSMIC_COVERAGE_ENV"))
  end
end

-- The recording-environment marker itself: unset (or anything but the
-- exact recording value) reads as "not the recording environment", the
-- exact value reads as "is".
local function test_is_recording_env_reads_the_marker()
  local saved = save_coverage_env()
  assert(env.unset("COSMIC_COVERAGE_ENV"))
  assert(not policy.is_recording_env(), "unset must not be the recording env")
  assert(env.set("COSMIC_COVERAGE_ENV", "0", true))
  assert(not policy.is_recording_env(), "'0' must not be the recording env")
  assert(env.set("COSMIC_COVERAGE_ENV", policy.RECORDING_ENV_VALUE, true))
  assert(policy.is_recording_env(), "the exact marker value must be the recording env")
  restore_coverage_env(saved)
end

-- The guard this item adds: outside the recording environment,
-- `write_baseline` refuses rather than rewriting the floor with
-- whatever THIS machine measured -- the bug report's 173 unrelated
-- rows. The floor on disk must be untouched, the exit code nonzero, and
-- the refusal must name the escape hatches (hand-edit one row; set
-- COSMIC_COVERAGE_ENV from the recording environment) rather than just
-- failing silently.
local function test_write_baseline_refuses_outside_recording_env()
  local root, proj = write_baseline_fixture("policy-write-baseline-refused")
  local before = check.must(fs.read(fs.join(root, policy.BASELINE)))
  local cwd = check.must(fs.cwd())
  check.must(fs.set_cwd(root))
  local captured = fs.join(root, "stderr.txt")
  local real_stderr = io.stderr
  io.stderr = assert(io.open(captured, "w"))
  local saved = save_coverage_env()
  assert(env.unset("COSMIC_COVERAGE_ENV"))
  local code = policy.write_baseline(proj)
  restore_coverage_env(saved)
  io.stderr:close()
  io.stderr = real_stderr
  check.must(fs.set_cwd(cwd))
  local printed = check.must(fs.read(captured))

  assert(code ~= 0, "a refusal must be a nonzero exit code")
  assert(printed:find("COSMIC_COVERAGE_ENV", 1, true),
    "the refusal must name the escape hatch: " .. printed)
  assert(printed:find("hand-edit", 1, true),
    "the refusal must point at hand-editing the one row: " .. printed)
  local after = check.must(fs.read(fs.join(root, policy.BASELINE)))
  assert(after == before, "a refused rewrite must not touch " .. policy.BASELINE)
end

-- The two seams above are positional integers -- `narrate_moves`
-- returns (lines, raised, lowered) and `wrote_summary` takes (lowered,
-- raised) -- so the checker cannot tell a swap at either call site from
-- the right order, and the unit tests, which feed each seam known
-- inputs, stay green while a real run prints inverted counts. This is
-- the run: floor on disk, `.cov` on disk, `write_baseline` itself, with
-- one row raised and two lowered, counts chosen unequal so a swap at
-- either seam reads "1 row(s) lowered, 2 raised" and fails here. Runs
-- as the recording environment (`save_coverage_env` /
-- `restore_coverage_env`) -- outside it `write_baseline` now refuses
-- before ever reaching this code, covered by
-- `test_write_baseline_refuses_outside_recording_env` above.
local function test_write_baseline_prints_each_move_and_unequal_counts()
  local root, proj = write_baseline_fixture("policy-write-baseline")
  local captured = fs.join(root, "stdout.txt")
  local cwd = check.must(fs.cwd())
  check.must(fs.set_cwd(root))
  local out, oerr = io.open(captured, "w")
  assert(out, oerr)
  io.output(out)
  local saved = save_coverage_env()
  assert(env.set("COSMIC_COVERAGE_ENV", policy.RECORDING_ENV_VALUE, true))
  local code = policy.write_baseline(proj)
  restore_coverage_env(saved)
  io.output(io.stdout)
  out:close()
  check.must(fs.set_cwd(cwd))
  local printed = check.must(fs.read(captured))
  assert(code == 0, "the rewrite must succeed, got " .. code .. ":\n" .. printed)

  local raises: {string} = {}
  local lowers: {string} = {}
  for line in printed:gmatch("[^\n]+") do
    local raised = line:match("^coverage: baseline RAISES (.*)$")
    if raised then raises[#raises + 1] = raised end
    local lowered = line:match("^coverage: baseline LOWERS (.*)$")
    if lowered then lowers[#lowers + 1] = lowered end
  end
  assert(table.concat(raises, "; ") == "lib/raised.tl 33.3% -> 100.0% (1/3 -> 3/3)",
    "exactly the one raised row, labeled RAISES, got: " ..
    table.concat(raises, "; ") .. "\n" .. printed)
  assert(table.concat(lowers, "; ") ==
    "lib/lowered_a.tl 100.0% -> 33.3% (3/3 -> 1/3); " ..
    "lib/lowered_b.tl 66.7% -> 33.3% (2/3 -> 1/3)",
    "exactly the two lowered rows, labeled LOWERS, got: " ..
    table.concat(lowers, "; ") .. "\n" .. printed)
  assert(not printed:find("same_", 1, true),
    "an unmoved row must not be narrated:\n" .. printed)
  assert(printed:find("coverage: wrote " .. policy.BASELINE ..
      " (2 row(s) lowered, 1 raised;", 1, true),
    "the summary must count 2 lowered then 1 raised, in that order:\n" .. printed)

  local floor = check.must(baseline.parse(
      check.must(fs.read(fs.join(root, policy.BASELINE)))))
  local row = floor.rows["lib/raised.tl"]
  assert(row and row.covered == 3 and row.total == 3,
    "the floor must hold what this run measured, got " ..
    (row and (row.covered .. "/" .. row.total) or "missing"))
end

print("all policy tests passed")
