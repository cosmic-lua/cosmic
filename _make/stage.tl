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
local fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local graph = require("_make.graph")
local project = require("_make.project")
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
  build = {
    kinds = {"module", "entry", "test", "example", "gen", "payload-gen"},
    suffix = ".tl",
    variable = "tl_sources",
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
  -- Derived from the one definition in types, exactly as `fmt` is: see
  -- there for what lint reads and why `testdata` is the one kind it
  -- does not.
  lint = {kinds = kinds_of(types.lint_kinds), variable = "lint_sources"},
  -- Coverage runs the same tests in a second output tree, so it selects
  -- the same files by the same rule.
  coverage = {kinds = {"test"}, variable = "tests"},
}

--- Print a verb's verdict line. Every verb ends in one, so a caller
--- that only reads the last line still knows what happened.
--- @param verb string The verb
--- @param ok boolean Whether it succeeded
--- @param detail string Parenthetical detail
--- @return integer The matching exit code
local function verdict(verb: string, ok: boolean, detail: string): integer
  io.write(verb .. (ok and ": PASS" or ": FAIL") ..
    (detail ~= "" and " (" .. detail .. ")" or "") .. "\n")
  return ok and 0 or 1
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
  local issues = validate.validate(proj)
  if #issues > 0 then
    io.stderr:write(validate.format_issues(issues) .. "\n")
    return false, #issues .. " validation " ..
    (#issues == 1 and "error" or "errors")
  end

  local sel = v.select as Selection -- cast: a graph verb always has one
  local picked, serr = project.select(candidates(proj, sel), paths, proj.root)
  if not picked then
    io.stderr:write((serr or "make: no such selection") .. "\n")
    return false, "bad selection"
  end
  local files = picked as {File} -- cast: record union after the guard

  local overrides: {string} = {}
  if #paths > 0 then
    overrides[1] = sel.variable .. "=" ..
    table.concat(project.paths_of(files), " ")
  end

  -- cast: a graph verb always has a target (see the registry)
  local code, gerr = graph.run(proj, v.target as string, overrides, cosmic)
  if gerr and gerr ~= "" then
    io.stderr:write(gerr .. "\n")
    return false, "make"
  end
  local noun = #files == 1 and " file" or " files"
  return code == 0, #files .. noun
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
  cenv.set(BIN_ENV, rel, true)
  local abs = fs.join(proj.root, rel)
  local sep = sys.host_os() == "windows" and ";" or ":"
  local path = cenv.get("PATH")
  if path == "" then
    cenv.set("PATH", abs, true)
  elseif not (sep .. path .. sep):find(sep .. abs .. sep, 1, true) then
    cenv.set("PATH", abs .. sep .. path, true)
  end
end

local record StageModule
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
