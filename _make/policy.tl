--- The policy verbs: `coverage` and `ci`.
---
--- Orchestration over the graph, never graph rules. `coverage` runs the
--- test lane with collection on and then gates the result against a
--- committed floor; `ci` is a fixed order of other verbs.
---
--- Both are gated by MATERIAL rather than by configuration: a project
--- with no tests has no coverage stage, one with no committed baseline
--- gets no ratchet, and neither is an error. Zero configuration, and a
--- fresh project does not fail on a stage that had nothing to do.

local baseline = require("_tool.coverage.baseline")
local fs = require("cosmic.fs")
local project = require("_make.project")
local selection = require("_make.select")
local stage = require("_make.stage")
local types = require("_make.types")
local vcs = require("_make.vcs")

local type Kind = types.Kind
local type Move = baseline.Move
local type Project = types.Project
local type Verb = types.Verb

--- The committed coverage floor, by convention.
---
--- Dot-prefixed, in the same grammar as `.cosmicignore` and `.version`:
--- data the build reads, never a module, never shipped. Its absence is
--- the answer to "should there be a ratchet", so a project opts in by
--- committing one and nothing has to be configured either way.
---
--- Namespaced, because a bare `.coverage` at a project root is already
--- taken: coverage.py writes its binary data file there, and cosmic
--- targets polyglot repos. Two tools with one filename means one of
--- them silently overwrites a floor with a SQLite database, and the
--- ratchet's failure mode for an unreadable floor is to report every
--- row as new.
local BASELINE < const > = ".cosmic-coverage"

--- Where a coverage run's data lands.
local COVERAGE_DIR < const > = ".coverage"

--- The `COSMIC_COVERAGE_ENV` value that marks THIS machine as the
--- environment `.cosmic-coverage` is recorded in.
local RECORDING_ENV_VALUE < const > = "1"

--- Whether this run is happening in the environment the committed floor
--- is measured in: CI's `ci` lane (`.github/workflows/pr.yml`) — a
--- digest-pinned `buildpack-deps:noble` container, run `--privileged`,
--- built and gated as the non-root `builder` user, network-fenced to
--- loopback after `fetch`. Coverage is environment-sensitive
--- (`cosmic/coverage/SENSITIVITY.md`): root vs. non-root, Landlock,
--- Linux namespaces, a real tty, a free port, and even which compiler
--- built the binary under test all move rows, sometimes by 2x. A
--- rewrite from any OTHER machine bakes that machine's local ceiling
--- into the shared floor instead of the recording environment's — the
--- `ci` lane sets `COSMIC_COVERAGE_ENV=1` for itself; nowhere else
--- should.
--- @return boolean
local function is_recording_env(): boolean
  return os.getenv("COSMIC_COVERAGE_ENV") == RECORDING_ENV_VALUE
end

--- Whether a project has any file of the given kinds — the "material"
--- test every stage of `ci` is gated by.
--- @param proj Project The scanned project
--- @param kinds {Kind} The kinds that count as material
--- @return boolean True when at least one file matches
local function has(proj: Project, kinds: {Kind}): boolean
  return #project.of_kind(proj, kinds) > 0
end

--- `coverage` — the test lane again, with collection, then the ratchet.
---
--- The ratchet is in process rather than a recipe line because it is a
--- POLICY: it reads a committed floor, compares, and decides. A recipe
--- would have to name the baseline path, the report directory and the
--- source directories in the constant rules, which is three project
--- facts in a file that is supposed to have none.
--- @param v Verb The coverage verb
--- @param proj Project The scanned project
--- @param paths {string} Selection paths naming tests
--- @param cosmic string Absolute path to this binary
--- @return integer Exit code
local function run_coverage(v: Verb, proj: Project, paths: {string},
    cosmic: string): integer
  local ok, detail = stage.graph_stage(v, proj, paths, cosmic)
  if not ok then
    return stage.verdict(v.name, false, detail)
  end
  if not fs.is_file(BASELINE) then
    io.write("coverage: no " .. BASELINE ..
      "; write one with `--make coverage --baseline` to start a ratchet\n")
    return stage.verdict(v.name, true, detail)
  end
  -- A narrowed run is partial data, and partial data reads as a huge
  -- decline against a whole-project floor. The gate skips rather than
  -- fails, so selecting a few tests cannot report a regression it did
  -- not measure.
  local only = #paths > 0 and "selection" or ""
  local report: {string} = {fs.join(project.BUILD_DIR, COVERAGE_DIR)}
  for _, dir in ipairs(project.source_dirs(proj)) do
    report[#report + 1] = dir
  end
  local code = baseline.gate(BASELINE, only, report)
  return stage.verdict(v.name, code == 0, detail)
end

--- Turn `baseline.moved`'s rows into printable narration, one line per
--- row, labeled by direction — a raise is "RAISES", a drop is "LOWERS"
--- — plus how many of each `write_baseline`'s closing summary counts.
---
--- Split out of `write_baseline` so the labeling can be asserted
--- directly against synthetic rows, with no coverage run or filesystem
--- involved: `baseline.moved` used to be `baseline.lowered`, which
--- named every moved row without saying which direction it moved, and
--- this call site printed "LOWERS" on every one of them regardless —
--- a raise read as a decline in the one place an operator running
--- `--baseline` actually sees the output.
--- @param moves {Move} What `baseline.moved(floor, fresh)` found
--- @return {string} One "coverage: baseline RAISES/LOWERS …" line per row
--- @return integer How many of those rows raised
--- @return integer How many lowered
local function narrate_moves(moves: {Move}): {string}, integer, integer
  local lines: {string} = {}
  local raised_count = 0
  local lowered_count = 0
  for _, row in ipairs(moves) do
    if row.raised then
      lines[#lines + 1] = "coverage: baseline RAISES " .. row.message
      raised_count = raised_count + 1
    else
      lines[#lines + 1] = "coverage: baseline LOWERS " .. row.message
      lowered_count = lowered_count + 1
    end
  end
  return lines, raised_count, lowered_count
end

--- The line an operator reads after every successful `--baseline`
--- write, closing the per-row narration `narrate_moves` printed above
--- it. A rewrite raises and lowers rows alike, so the summary names
--- the one thing that can refuse it — `corpus_guard`'s breadth check,
--- which fires only when more than half the committed rows would drop
--- at once — and says where the rows that check cannot vouch for are
--- read: an environment-sensitive row this machine cannot measure
--- lowers straight through, and only a human reading the diff against
--- `cosmic/coverage/SENSITIVITY.md` catches it.
--- @param lowered_count integer How many rows the rewrite lowered
--- @param raised_count integer How many it raised
--- @return string The newline-terminated summary line
local function wrote_summary(lowered_count: integer, raised_count: integer): string
  return "coverage: wrote " .. BASELINE .. " (" .. lowered_count
  .. " row(s) lowered, " .. raised_count .. " raised; corpus_guard"
  .. " refuses only a rewrite dropping more than half the rows —"
  .. " check any environment-sensitive row against"
  .. " cosmic/coverage/SENSITIVITY.md)\n"
end

--- `coverage --baseline` — rewrite the committed floor from a run.
---
--- Refuses outside the recording environment (see `is_recording_env`):
--- run this on an ordinary developer machine and the committed floor
--- moves by whatever that machine's sandbox, identity and compiler
--- happen to measure, unrelated to the change at hand — 173 rows on one
--- reported run, none of them touched by the branch. The row a real
--- change earns is still yours to write: hand-edit its `covered`/`total`
--- pair in `.cosmic-coverage` directly, the same file this would have
--- rewritten wholesale.
--- @param proj Project The scanned project
--- @return integer Exit code
local function write_baseline(proj: Project): integer
  if not is_recording_env() then
    io.stderr:write(
      "coverage --baseline REFUSED: this machine is not the " ..
      ".cosmic-coverage recording environment (CI's `ci` lane — see " ..
      "AGENTS.md's coverage paragraph and cosmic/coverage/SENSITIVITY.md). " ..
      "A rewrite here would bake THIS machine's sandbox/identity/compiler " ..
      "ceiling into the shared floor instead of the recording " ..
      "environment's. To move the one row your change actually affects, " ..
      "hand-edit its covered/total pair in .cosmic-coverage. A new " ..
      "file's row is printed by a plain `--make coverage`; paste it.\n")
    return stage.verdict("coverage", false, "not the recording environment")
  end
  local report: {string} = {fs.join(project.BUILD_DIR, COVERAGE_DIR)}
  for _, dir in ipairs(project.source_dirs(proj)) do
    report[#report + 1] = dir
  end
  -- The baseline being replaced is an INPUT to its own rewrite only for
  -- `corpus_guard`: `render` writes the fresh measurement verbatim, so a
  -- row this run measures higher than the floor raises and one it
  -- measures lower lowers, exactly like any other edit to a committed
  -- file. What the previous floor still guards against is breadth — a
  -- rewrite that would lower more than half the committed rows at once
  -- refuses outright, the signature of a partial or stale run rather
  -- than a real decline — and every row that moved, in either
  -- direction, is narrated below.
  local previous = fs.read(BASELINE)
  local floor = previous is string and previous or nil
  local text, err = baseline.text_for(report, floor)
  if not text then
    io.stderr:write((err or "coverage: no data") .. "\n")
    return stage.verdict("coverage", false, "no data")
  end
  local fresh = text
  local raised_count = 0
  local lowered_count = 0
  if floor then
    local lines: {string}
    lines, raised_count, lowered_count = narrate_moves(baseline.moved(floor, fresh))
    for _, line in ipairs(lines) do
      io.write(line .. "\n")
    end
  end
  local wok, werr = fs.write(BASELINE, fresh)
  if not wok then
    io.stderr:write((werr or "cannot write " .. BASELINE) .. "\n")
    return stage.verdict("coverage", false, BASELINE)
  end
  io.write(wrote_summary(lowered_count, raised_count))
  return stage.verdict("coverage", true, BASELINE)
end

--- `fmt --fix` — rewrite every selected source that is not already
--- formatted, in process.
---
--- Not through the graph: a `.fmt.got` records a VERDICT about a file,
--- and rewriting the file makes that verdict about something that no
--- longer exists. The formatter is in this binary, the file set is the
--- model's, and the answer is the same one `--fix` gives for one file.
--- @param proj Project The scanned project
--- @param paths {string} Selection paths
--- @return integer Exit code
local function fix(proj: Project, paths: {string}): integer
  local picked, serr = selection.files(
    stage.candidates(proj, stage.SELECTS.fmt), paths, proj.root)
  if not picked then
    io.stderr:write((serr or "make: nothing to do under") .. "\n")
    return stage.verdict("fmt", false, "selection")
  end
  local fmt = require("cosmic.format")
  local fixed = 0
  for _, f in ipairs(picked) do
    local result = fmt.format_file(f.path)
    if not result.ok then
      io.stderr:write(fmt.format_issues(result.errors) .. "\n")
      return stage.verdict("fmt", false, f.path)
    end
    local code = result.code
    if code == nil then
      -- ok without code would be a formatter bug; refuse rather than cast.
      io.stderr:write("fmt: no output for " .. f.path .. "\n")
      return stage.verdict("fmt", false, f.path)
    end
    if fs.read(f.path) ~= code then
      local ok, werr = fs.write(f.path, code)
      if not ok then
        io.stderr:write((werr or "cannot write " .. f.path) .. "\n")
        return stage.verdict("fmt", false, f.path)
      end
      io.write("fmt: rewrote " .. f.path .. "\n")
      fixed = fixed + 1
    end
  end
  return stage.verdict("fmt", true, fixed .. " rewritten")
end

--- One stage of `ci`: a verb name, and the material that earns it.
local record Stage
  verb: string
  --- Kinds a project must have at least one of. Empty means always.
  needs: {Kind}
end

--- The gate, in order.
---
--- A list of verb NAMES, which is the point of the registry being data:
--- `ci` reimplements nothing, so a stage cannot drift from the verb it
--- claims to run. There is no separate model stage: validating the
--- project is what `check` opens with, so `ci` gets it by listing
--- `check`.
---
--- No separate `test` stage: `coverage` runs the identical test recipe
--- with collection on, and its ratchet summary passes or fails exactly
--- the way a plain test run would, so a failing test still fails `ci`
--- through `coverage`. Running the suite twice — once plain, once
--- instrumented — bought `ci` nothing but wall-clock: measured, 157s
--- summed for the plain lane against 351s for the instrumented one,
--- pure duplication inside the gate. `--make test` standalone is
--- untouched — it is still the fast, uninstrumented developer loop —
--- this only drops the plain lane's second run inside `ci`.
local STAGES < const >: {Stage} = {
  {verb = "fmt", needs = {}},
  {verb = "check", needs = {}},
  {verb = "example", needs = {"example"}},
  {verb = "lint", needs = {}},
  {verb = "coverage", needs = {"test"}},
}

--- Look up a verb the registry is known to define.
---
--- The registry (`_make/init.tl`) is literal data: every name a caller
--- passes here names a row it defines, so a lookup miss is an
--- impossible state, not a runtime failure worth a nilable return.
--- @param by_name function Registry lookup, passed in to avoid a cycle
--- @param name string The verb name, a row the registry defines
--- @return Verb
local function must_verb(by_name: function(string): Verb | nil,
    name: string): Verb
  local v = by_name(name)
  assert(v, "make: no verb " .. name) -- assert: the registry is literal data in _make/init.tl and every name passed here is a row it defines
  return v
end

--- `ci` — every stage, in order, each gated by material.
---
--- Runs to the END rather than stopping at the first failure: a gate
--- that reports one problem per run costs a round trip per problem, and
--- the stages are independent by construction.
--- @param by_name function Registry lookup, passed in to avoid a cycle
--- @param proj Project The scanned project
--- @param _paths {string} Unused: `_make.law` refuses a selection here
--- @param cosmic string Absolute path to this binary
--- @return integer Exit code
local function run_ci(by_name: function(string): Verb | nil, proj: Project,
    _paths: {string}, cosmic: string): integer
  local failed: {string} = {}
  local ran = 0
  for _, s in ipairs(STAGES) do
    local v = by_name(s.verb)
    if not (v is Verb) then
      io.stderr:write("make: ci names a verb that does not exist: " ..
        s.verb .. "\n")
      return stage.verdict("ci", false, s.verb)
    end
    if #s.needs > 0 and not has(proj, s.needs) then
      io.write("ci: " .. s.verb .. " skipped (nothing to do)\n")
    else
      ran = ran + 1
      local code = v.run and v.run(proj, {}, cosmic)
      or stage.run_graph(v, proj, {}, cosmic)
      if code ~= 0 then
        failed[#failed + 1] = s.verb
      end
    end
  end
  -- Second-to-last line, the same slot the coverage ratchet's `declined:`
  -- line uses (_tool/coverage/baseline.tl): it must survive a truncated
  -- view, on both the pass and the fail path.
  local base_sha = vcs.diverged()
  if base_sha then
    io.write(vcs.notice(vcs.BASE_REF, base_sha) .. "\n")
  end
  if #failed > 0 then
    return stage.verdict("ci", false, table.concat(failed, " "))
  end
  return stage.verdict("ci", true, ran .. " stages")
end

local record PolicyModule
  BASELINE: string
  COVERAGE_DIR: string
  RECORDING_ENV_VALUE: string
  STAGES: {Stage}
  has: function(proj: Project, kinds: {Kind}): boolean
  is_recording_env: function(): boolean
  run_coverage: function(v: Verb, proj: Project, paths: {string}, cosmic: string): integer
  narrate_moves: function(moves: {Move}): {string}, integer, integer
  wrote_summary: function(lowered_count: integer, raised_count: integer): string
  fix: function(proj: Project, paths: {string}): integer
  write_baseline: function(proj: Project): integer
  run_ci: function(by_name: function(string): Verb | nil, proj: Project, _paths: {string}, cosmic: string): integer
  must_verb: function(by_name: function(string): Verb | nil, name: string): Verb
end

local M: PolicyModule = {
  BASELINE = BASELINE,
  COVERAGE_DIR = COVERAGE_DIR,
  RECORDING_ENV_VALUE = RECORDING_ENV_VALUE,
  STAGES = STAGES,
  has = has,
  is_recording_env = is_recording_env,
  run_coverage = run_coverage,
  narrate_moves = narrate_moves,
  wrote_summary = wrote_summary,
  fix = fix,
  write_baseline = write_baseline,
  run_ci = run_ci,
  must_verb = must_verb,
}

return M
