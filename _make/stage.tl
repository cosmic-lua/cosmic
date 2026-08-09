--- Lowering a verb onto the graph.
---
--- The half of `--make` that is the same for every graph verb: which
--- files the verb acts on, how a selection narrows them, how that
--- narrowing reaches make (as a variable assignment, never as a rule),
--- and the verdict line every verb ends in.
---
--- Split out of the registry when the registry outgrew the file-length
--- cap: `init.tl` is now what verbs there ARE and what each one does
--- around the graph, and this is what "onto the graph" means.

local cenv = require("cosmic.env")
local converge = require("_make.converge")
local fs = require("cosmic.fs")
local records = require("_tool.records")
local sys = require("cosmic.sys")
local generate = require("_make.generate")
local graph = require("_make.graph")
local project = require("_make.project")
local selection = require("_make.select")
local types = require("_make.types")
local validate = require("_make.validate")

local type File = types.File
local type Kind = types.Kind
local type Project = types.Project
local type Selection = types.Selection
local type Verb = types.Verb

--- A kind set from types, as the sorted list a Selection wants.
--- @param set {Kind: boolean} The set to flatten
--- @return {Kind} The kinds, in a stable order
local function kinds_of(set: {Kind: boolean}): {Kind}
  local out: {Kind} = {}
  for k in pairs(set) do
    -- The table is DECLARED `{Kind: boolean}`, so every lookup is
    -- typed and a bare string key is refused at the call site. Teal
    -- 0.24.8 still hands `pairs` the key as `string`, so the one cast
    -- left is at that language boundary rather than standing in for a
    -- loose type.
    out[#out + 1] = k as Kind -- cast: pairs() erases an enum key type
  end
  table.sort(out)
  return out
end

local SELECTS < const >: {string: Selection} = {
  -- No `variable`: a selected build still compiles the whole tree (see
  -- `run_build`'s own comment), and `run_build` always lowers onto the
  -- graph with an empty selection, so there is no path list here to
  -- turn into an override. `--make build <binary>` narrows which
  -- binaries get STAGED, resolved separately through
  -- `binaries.select` (`_make/law.tl`'s RESOLVERS), never through this
  -- table.
  build = {
    kinds = {"module", "entry", "test", "example", "benchmark", "gen",
      "payload-gen"},
    suffix = ".tl",
  },
  -- Derived from the one definition in types, so a selected `fmt` and
  -- the facts writer's `fmt_sources` cannot disagree about what is
  -- formattable (they did: full fmt gated testdata and payload).
  fmt = {
    kinds = kinds_of(types.fmt_kinds),
    suffix = ".tl",
    variable = "fmt_sources",
  },
  -- No suffix filter: the `test` KIND already means "a test file",
  -- and a `.lua` test is one. Filtering on `.tl` here would list a Lua
  -- project's tests in the facts and then quietly drop them from a
  -- selected run.
  test = {kinds = {"test"}, variable = "tests"},
  -- `example` is `test`'s sibling everywhere else in the model, so it
  -- is one here too: same shape, same reason for no suffix filter.
  example = {kinds = {"example"}, variable = "examples"},
  -- `test`'s other sibling. No suffix filter, same reason: the KIND
  -- already means "a benchmark file", and a `.lua` one is one.
  benchmark = {kinds = {"benchmark"}, variable = "benchmarks"},
  -- Derived from the one definition in types, exactly as `fmt` is: see
  -- there for what lint reads and why `testdata` is the one kind it
  -- does not.
  lint = {kinds = kinds_of(types.lint_kinds), variable = "lint_sources"},
  -- Coverage runs the same tests in a second output tree, so it selects
  -- the same files by the same rule.
  coverage = {kinds = {"test"}, variable = "tests"},
}

--- Say what a verb did NOT check, and pass its exit code through.
---
--- `build` and `test` accept a file the formatter and the linter will
--- reject, so without this the first complaint arrives at `ci`, after
--- the work already reads as done. The note goes on the output rather
--- than in a document because that is where someone is looking when it
--- matters. Only for a verb the user typed: inside a converging gate
--- this build is a step, not a result.
--- @param verb string The verb the user asked for
--- @param code integer The exit code it produced
--- @return integer That same exit code
local function gate_note(verb: string, code: integer): integer
  if code == 0 and (verb == "build" or verb == "test")
  and cenv.get_or(converge.GEN_ENV, "0") == "0" then
    io.write("note: fmt and lint did not run here — " ..
      "`cosmic --make ci` is the whole gate\n")
  end
  return code
end

--- Print a verb's verdict line and return the exit code it means;
--- the grammar lives in `_tool.records`, which formats without
--- printing (#992) — this wrapper is the one place stdout happens.
local function verdict(verb: string, ok: boolean, detail: string): integer
  io.write(records.format_verdict(verb, ok, detail) .. "\n")
  return records.exit_code(ok)
end

--- The files a graph verb acts on, before selection.
--- @param proj Project The scanned project
--- @param sel Selection The verb's selection rule
--- @return {File} Candidate files
local function candidates(proj: Project, sel: Selection): {File}
  local out: {File} = {}
  for _, f in ipairs(project.of_kind(proj, sel.kinds)) do
    local want = sel.suffix
    if not want or f.path:sub(-#want) == want then
      out[#out + 1] = f
    end
  end
  return out
end

--- Lower a verb onto the graph and report what it did.
---
--- Validation runs first here too, and not only for symmetry with
--- `check`: a filename carrying whitespace would be split across two
--- arguments of a recipe line, so a project the validator rejects is
--- one whose paths must not reach make at all.
--- @param v Verb A verb with a target
--- @param proj Project The scanned project
--- @param paths {string} Selection paths
--- @param cosmic string Absolute path to this binary, resolved before chdir
--- @return boolean Whether the graph run succeeded
--- @return string The detail for the verdict line
local function graph_stage(v: Verb, proj: Project, paths: {string},
    cosmic: string): boolean, string
  -- Generated INPUTS first, for every graph verb and not just `build`:
  -- the compiler, the checker, the formatter and the linter all read
  -- `_types/*.d.tl`, so a verb that ran before the generator would work
  -- against whatever the last run left behind.
  local gok, generr = generate.sources(proj, cosmic)
  if not gok then
    io.stderr:write((generr or "make: source generation failed") .. "\n")
    return false, "generate failed"
  end
  local issues = validate.validate(proj)
  if #issues > 0 then
    io.stderr:write(validate.format_issues(issues) .. "\n")
    return false, #issues .. " validation " ..
    (#issues == 1 and "error" or "errors")
  end

  local sel = v.select as Selection -- cast: a graph verb always has one
  local picked, serr = selection.files(candidates(proj, sel), paths, proj.root)
  if not picked then
    io.stderr:write((serr or "make: no such selection") .. "\n")
    return false, "bad selection"
  end
  local files = picked

  local overrides: {string} = {}
  local variable = sel.variable
  if variable and #paths > 0 then
    overrides[1] = variable .. "=" ..
    table.concat(project.paths_of(files), " ")
  end

  -- The detail comes from the summary the stage just wrote, not from
  -- the size of the file list. Those are different numbers, and the
  -- verdict line is the one that survives a truncated log: `test: FAIL
  -- (7 files)` read as "seven files failed" when it meant "one of two
  -- tests failed, and seven files were selected".
  --
  -- Removed BEFORE make runs, not read as-is after: the summary recipe
  -- is one of the last things a stage's own graph does, so make dying
  -- earlier (a compile error, a killed job) leaves whatever summary the
  -- PREVIOUS run wrote sitting there with a mtime make never touched.
  -- Read as-is, that stale file reports the last run's counts under
  -- THIS run's FAIL -- `test: FAIL (0 of 42 files)` for a run that
  -- never got past `compile`. Best-effort: a first run has no summary
  -- to remove, and that is not this stage's failure to report.
  local summary = fs.join(project.BUILD_DIR,
    (v.target as string) .. "-summary.txt") -- cast: a graph verb has one
  local _ok, _err = fs.remove(summary)

  -- cast: a graph verb always has a target (see the registry)
  local code, gerr = graph.run(proj, v.target as string, overrides, cosmic)
  if gerr and gerr ~= "" then
    io.stderr:write(gerr .. "\n")
    return false, "make"
  end
  return code == 0, records.stage_detail(fs.read(summary), #files, "file")
end

--- A graph verb with nothing to do around the graph: `fmt`.
--- @param v Verb The verb being run
--- @param proj Project The scanned project
--- @param paths {string} Selection paths
--- @param cosmic string Absolute path to this binary
--- @return integer Exit code
local function run_graph(v: Verb, proj: Project, paths: {string},
    cosmic: string): integer
  local ok, detail = graph_stage(v, proj, paths, cosmic)
  return verdict(v.name, ok, detail)
end

--- The environment variable naming the directory a test's binaries are
--- in. Relative to the root, which is every test's cwd.
local BIN_ENV < const > = "TEST_BIN"

--- Put the project's own binaries where its tests can find them.
---
--- A project that builds a binary tests it by SPAWNING it — that is the
--- only way to test a CLI, and it is what every test reporting
--- `command not found` is asking for. The answer is derived rather than
--- configured: the model already says a binary lands at `o/bin/<name>`,
--- so `TEST_BIN` names that directory and the directory goes first on
--- the child's PATH. Both, because a test may want either spelling and
--- neither is more honest than the other: the variable for a test that
--- knows which binary it wants, the PATH entry for a test that spawns a
--- tool by name.
---
--- Idempotent on PATH: `test` and `example` in one `ci` run would
--- otherwise stack the same entry.
--- @param proj Project The scanned project, for its root
local function binaries_on_path(proj: Project)
  local rel = fs.join(project.BUILD_DIR, "bin")
  local _ok, _err = cenv.set(BIN_ENV, rel, true)
  local abs = fs.join(proj.root, rel)
  local sep = sys.host_os() == "windows" and ";" or ":"
  local path = cenv.get("PATH")
  if path == nil or path == "" then
    local _ok, _err = cenv.set("PATH", abs, true)
  elseif not (sep .. path .. sep):find(sep .. abs .. sep, 1, true) then
    local _ok, _err = cenv.set("PATH", abs .. sep .. path, true)
  end
end

local record StageModule
  gate_note: function(verb: string, code: integer): integer
  BIN_ENV: string
  SELECTS: {string: Selection}
  verdict: function(verb: string, ok: boolean, detail: string): integer
  candidates: function(proj: Project, sel: Selection): {File}
  graph_stage: function(v: Verb, proj: Project, paths: {string}, cosmic: string): boolean, string
  run_graph: function(v: Verb, proj: Project, paths: {string}, cosmic: string): integer
  bin_dir: function(proj: Project): string
  binaries_on_path: function(proj: Project)
end

--- Where a project's binaries land, absolute.
--- @param proj Project The scanned project
--- @return string The directory
local function bin_dir(proj: Project): string
  return fs.join(proj.root, project.BUILD_DIR, "bin")
end

local M: StageModule = {
  gate_note = gate_note,
  BIN_ENV = BIN_ENV,
  SELECTS = SELECTS,
  verdict = verdict,
  candidates = candidates,
  graph_stage = graph_stage,
  run_graph = run_graph,
  bin_dir = bin_dir,
  binaries_on_path = binaries_on_path,
}

return M
