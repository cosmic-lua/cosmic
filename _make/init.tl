--- `cosmic --make <verb> [paths…]` — cosmic's build system.
---
--- Not a wrapper around `--embed`, and no longer a Makefile generator:
--- the flag used to scan a directory and emit a Makefile that was
--- useless without a host make, produced build files rather than
--- builds, and modelled a project as a flat list of `.tl` files. That
--- generator is gone. Two grammars for one flag would have been worse
--- than one rewrite of the guides.
---
--- What is here today is the project model (project.tl), the validator
--- (validate.tl), root discovery (root.tl), and one verb: `check`.
--- The remaining verbs are named below rather than hidden, so a run
--- that asks for one gets told where it stands instead of "unknown
--- option".

local cenv = require("cosmic.env")
local fs = require("cosmic.fs")
local root = require("_make.root")
local project = require("_make.project")
local validate = require("_make.validate")
local artifact = require("_make.artifact")
local check = require("_make.check")
local fetch = require("_make.fetch")
local generate = require("_make.generate")
local graph = require("_make.graph")
local types = require("_make.types")

local type File = types.File
local type Issue = types.Issue
local type Kind = types.Kind
local type Project = types.Project

--- Which files a graph verb acts on, and the make variable a
--- selection overrides. A command-line assignment beats the one in
--- `o/project.mk`, so selection needs no rules of its own: everything
--- downstream is derived from these lists.
local record Selection
  kinds: {Kind}
  --- Suffix a candidate's path must end with, or nil for no filter.
  ---
  --- nil rather than "": the empty string spelled "unfiltered" only by
  --- convention, and the natural comparison for it -- `path:sub(-#"")`
  --- -- is `sub(-0)`, which is `sub(0)`, which is the WHOLE string. So
  --- the obvious code silently matched nothing and the guard against it
  --- lived in a comment. The type says it now.
  suffix: string | nil
  variable: string
end

--- The formattable kinds, as the sorted list a Selection wants.
--- @return {Kind} The kinds, in a stable order
local function fmt_kinds(): {Kind}
  local out: {Kind} = {}
  for k in pairs(types.fmt_kinds) do
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
    kinds = {"module", "entry", "test", "example", "gen"},
    suffix = ".tl",
    variable = "tl_sources",
  },
  -- Derived from the one definition in types, so a selected `fmt` and
  -- the facts writer's `fmt_sources` cannot disagree about what is
  -- formattable (they did: full fmt gated testdata and payload).
  fmt = {
    kinds = fmt_kinds(),
    suffix = ".tl",
    variable = "fmt_sources",
  },
  -- No suffix filter: the `test` KIND already means "a test file",
  -- and a `.lua` test is one. Filtering on `.tl` here would list a Lua
  -- project's tests in the facts and then quietly drop them from a
  -- selected run.
  test = {kinds = {"test"}, variable = "tests"},
}

--- One verb: everything the dispatcher, the usage text and the
--- planned-verb stub need to know about it, in one row.
---
--- Adding a verb used to mean editing two lists, up to two maps and an
--- if-chain in `run`, with which mechanism a verb belonged to
--- discoverable only by reading the dispatch. Seven more verbs are
--- planned and most are POLICY verbs (orchestration, not graph
--- targets), so on that shape each would have become another branch.
--- The registry is also the data structure `ci` needs: a fixed order of
--- stages is a list of verb names only if verbs are values.
local record Verb
  --- The name typed on the command line.
  name: string
  --- Defined by the design, not shipped by this slice.
  planned: boolean
  --- The make target this verb lowers onto, when it is a graph verb.
  target: string | nil
  --- What paths select, for a graph verb.
  select: Selection | nil
  --- The in-process implementation, for a verb that is not lowered
  --- onto the graph. Exactly one of `target` and `run` is set.
  run: function(proj: Project, paths: {string}, cosmic: string): integer
end

--- Discover the root, announce it, and scan the project.
---
--- The banner is unconditional and goes to stdout: "which tree did that
--- just build" is the question every wrong-directory bug starts with,
--- and it costs one line to answer up front.
--- @param verb string The verb being run, for the discovery message
--- @return Project|nil The scanned project, or nil on failure
--- @return string The error message when discovery or the scan failed
local function open_project(verb: string): Project | nil, string
  local dir, derr = root.discover(verb)
  if not dir then
    return nil, derr or "make: cannot determine the project root"
  end
  local abs = dir as string -- cast: scalar narrowing after the guard
  io.write("make: root=" .. abs .. "\n")
  -- chdir so every path a verb prints, and every path it hands the
  -- checker, is relative to the root the banner just named.
  local ok, cerr = fs.chdir(abs)
  if not ok then
    return nil, "make: cannot enter " .. abs .. ": " .. (cerr or "unknown error")
  end
  local proj, serr = project.scan(abs)
  if not proj then
    return nil, serr or "make: cannot scan the project"
  end
  return proj
end

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
end --- Lower a verb onto the graph and report what it did.
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

--- A graph verb with nothing to do after the graph: `fmt` and `test`.
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

--- Forward declaration: `build`'s row needs its runner, and its runner
--- needs the registry to find its own row.
local by_name: function(name: string): Verb | nil

--- `build` — compile the tree, then assemble the artifacts.
---
--- The step after the graph is genuinely build's own, so it lives in
--- build's runner rather than as a condition inside the shared graph
--- path. A SELECTED build compiles part of the tree, so it cannot
--- produce a whole artifact: it stops at the compile, which is what the
--- verdict then reports.
--- @param proj Project The scanned project
--- @param paths {string} Selection paths
--- @param cosmic string Absolute path to this binary
--- @return integer Exit code
local function run_build(proj: Project, paths: {string},
    cosmic: string): integer
  local v = by_name("build") as Verb -- cast: the registry defines it
  local ok, detail = graph_stage(v, proj, paths, cosmic)
  if not ok or #paths > 0 then
    return verdict("build", ok, detail)
  end
  -- Generation is a phase over the project, before any staging: the
  -- ROOT payload is staged into every binary, so its generator must
  -- run once and before the first of them.
  local gok, generr = generate.generate(proj, cosmic)
  if not gok then
    io.stderr:write((generr or "make: payload generation failed") .. "\n")
    return verdict("build", false, detail .. ", generate failed")
  end
  local built = 0
  for _, b in ipairs(proj.binaries) do
    local out, aerr = artifact.build(proj, b, cosmic)
    if not out then
      io.stderr:write((aerr or "make: cannot build the artifact") .. "\n")
      return verdict("build", false, detail .. ", " .. b.name .. " failed")
    end
    io.write("make: " .. (out as string) .. "\n") -- cast: scalar narrowing after the guard
    built = built + 1
  end
  if built > 0 then
    detail = detail .. ", " .. built ..
    (built == 1 and " binary" or " binaries")
  end
  return verdict("build", true, detail)
end

--- `clean` — remove the build directory, in process. Driving this
--- through the graph would mean reading rules out of the directory
--- being deleted.
--- @param _proj Project Unused: clean is about the output, not the model
--- @param _paths {string} Unused: clean takes no selection
--- @param _cosmic string Unused: clean needs no make binary
--- @return integer Exit code
local function run_clean(_proj: Project, _paths: {string},
    _cosmic: string): integer
  if not fs.exists(project.BUILD_DIR) then
    return verdict("clean", true, "nothing to remove")
  end
  local ok, err = fs.rmrf(project.BUILD_DIR)
  if not ok then
    io.stderr:write("make: cannot remove " .. project.BUILD_DIR .. ": " ..
      (err or "unknown error") .. "\n")
    return verdict("clean", false, "")
  end
  return verdict("clean", true, project.BUILD_DIR)
end

--- Every verb, in the order the design's own tables list them.
---
--- `check` has a `run` rather than a target deliberately: it works in
--- process, so the one verb that tells you whether a project is even
--- coherent needs no make binary at all. `clean` is in process for the
--- opposite reason -- removing `o/` through a graph whose rules live in
--- `o/` is a knot with no payoff. And `fetch` is the one verb that
--- skips validation, which it can: it reads pins and nothing else, so a
--- project whose sources do not yet type-check can still resolve its
--- dependencies, which is the order a cold checkout needs.
---
--- A planned row costs one line and turns a typo-shaped failure into a
--- schedule answer.
local VERBS < const >: {Verb} = {
  {name = "build", target = "build", select = SELECTS.build, run = run_build},
  {name = "check", run = function(proj: Project, paths: {string},
        _cosmic: string): integer
      return check.run(proj, paths)
    end},
  {name = "clean", run = run_clean},
  {name = "fetch", run = function(proj: Project, paths: {string},
        _cosmic: string): integer
      return fetch.run(proj, paths)
    end},
  {name = "fmt", target = "fmt", select = SELECTS.fmt},
  {name = "test", target = "test", select = SELECTS.test},
  {name = "run", planned = true},
  {name = "regen", planned = true},
  {name = "ci", planned = true},
  {name = "coverage", planned = true},
  {name = "enforce", planned = true},
  {name = "reproducible", planned = true},
  {name = "offline", planned = true},
}

local INDEX < const >: {string: Verb} = {}
for _, v in ipairs(VERBS) do
  INDEX[v.name] = v
end

by_name = function(name: string): Verb | nil
  return INDEX[name]
end

--- The verb names of one disposition, in registry order.
--- @param planned boolean Whether to list the planned verbs
--- @return {string} The names
local function names(planned: boolean): {string}
  local out: {string} = {}
  for _, v in ipairs(VERBS) do
    if (v.planned or false) == planned then
      out[#out + 1] = v.name
    end
  end
  return out
end

--- Usage, printed for a bare `--make` and after an unknown verb.
--- @return string The usage text, without a trailing newline
local function usage(): string
  return "usage: cosmic --make <verb> [paths…]\n" ..
  "make: verbs: " .. table.concat(names(false), ", ") .. "\n" ..
  "make: planned: " .. table.concat(names(true), ", ")
end

--- Run one `--make` invocation.
--- @param argv {string} The verb followed by selection paths
--- @return integer Exit code
local function run(argv: {string}): integer
  local name = argv[1]
  if not name or name == "" then
    io.stderr:write(usage() .. "\n")
    return 1
  end

  local paths: {string} = {}
  for i = 2, #argv do
    paths[#paths + 1] = argv[i]
  end

  -- Resolve this binary BEFORE anything chdirs: `--make` enters the
  -- project root, and a relative `./cosmic` resolved after that points
  -- at a path inside the project that does not exist.
  local self = fs.abspath(arg[-1] or "cosmic")
  -- Same rule, same place: `COSMIC_MAKE` is resolved by find_make,
  -- which runs after `open_project` has chdir'd, so a relative value
  -- resolved against the PROJECT ROOT rather than the directory the
  -- user typed it in. It worked only when the two happened to be the
  -- same, which is why every test passing absolute paths missed it.
  local named = os.getenv(graph.MAKE_ENV)
  if named and named ~= "" then
    cenv.set(graph.MAKE_ENV, fs.abspath(named), true)
  end

  local v = by_name(name)
  if not (v is Verb) then
    io.stderr:write("make: unknown verb '" .. name .. "'\n" .. usage() .. "\n")
    return 1
  end
  if v.planned then
    io.stderr:write("make: '" .. name ..
      "' is planned but not implemented yet\nmake: verbs: " ..
      table.concat(names(false), ", ") .. "\n")
    return 1
  end

  local proj, err = open_project(name)
  if not proj then
    io.stderr:write((err or "make: failed") .. "\n")
    return verdict(name, false, "no project")
  end
  local p = proj as Project -- cast: record union after the guard
  if v.run then
    return v.run(p, paths, self)
  end
  return run_graph(v, p, paths, self)
end

local record MakeModule
  IMPLEMENTED: {string}
  PLANNED: {string}
  usage: function(): string
  run: function(argv: {string}): integer
  scan: function(root: string): Project | nil, string
  validate: function(proj: Project): {Issue}
end

local M: MakeModule = {
  IMPLEMENTED = names(false),
  PLANNED = names(true),
  usage = usage,
  run = run,
  scan = project.scan,
  validate = validate.validate,
}

return M
