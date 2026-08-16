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

local type Kind = types.Kind
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

--- `coverage --baseline` — rewrite the committed floor from a run.
--- @param proj Project The scanned project
--- @return integer Exit code
local function write_baseline(proj: Project): integer
  local report: {string} = {fs.join(project.BUILD_DIR, COVERAGE_DIR)}
  for _, dir in ipairs(project.source_dirs(proj)) do
    report[#report + 1] = dir
  end
  -- The baseline being replaced is an INPUT to its own rewrite: a row
  -- this run measures better keeps the floor it already had, so a
  -- rebaseline on any machine can only ever lower one.
  local previous = fs.read(BASELINE)
  local floor = previous is string and previous or nil
  local text, err = baseline.text_for(report, floor)
  if not text then
    io.stderr:write((err or "coverage: no data") .. "\n")
    return stage.verdict("coverage", false, "no data")
  end
  local fresh = text
  local moved = 0
  if floor then
    for _, row in ipairs(baseline.lowered(floor, fresh)) do
      io.write("coverage: baseline LOWERS " .. row .. "\n")
      moved = moved + 1
    end
  end
  local wok, werr = fs.write(BASELINE, fresh)
  if not wok then
    io.stderr:write((werr or "cannot write " .. BASELINE) .. "\n")
    return stage.verdict("coverage", false, BASELINE)
  end
  io.write("coverage: wrote " .. BASELINE .. " (" .. moved
    .. " row(s) lowered; a floor only moves up by hand — see "
    .. "cosmic/coverage/SENSITIVITY.md)\n")
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
  if #failed > 0 then
    return stage.verdict("ci", false, table.concat(failed, " "))
  end
  return stage.verdict("ci", true, ran .. " stages")
end

local record PolicyModule
  BASELINE: string
  COVERAGE_DIR: string
  STAGES: {Stage}
  has: function(proj: Project, kinds: {Kind}): boolean
  run_coverage: function(v: Verb, proj: Project, paths: {string}, cosmic: string): integer
  fix: function(proj: Project, paths: {string}): integer
  write_baseline: function(proj: Project): integer
  run_ci: function(by_name: function(string): Verb | nil, proj: Project, _paths: {string}, cosmic: string): integer
end

local M: PolicyModule = {
  BASELINE = BASELINE,
  COVERAGE_DIR = COVERAGE_DIR,
  STAGES = STAGES,
  has = has,
  run_coverage = run_coverage,
  fix = fix,
  write_baseline = write_baseline,
  run_ci = run_ci,
}

return M
