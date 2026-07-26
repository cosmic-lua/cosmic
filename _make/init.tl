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
local graph = require("_make.graph")
local types = require("_make.types")

local type File = types.File
local type Issue = types.Issue
local type Kind = types.Kind
local type Project = types.Project

--- Verbs that run today.
local IMPLEMENTED < const >: {string} = {
  "build", "check", "clean", "fetch", "fmt", "test",
}

--- Verbs the design defines and later slices land, in the order they
--- appear in the design's own tables. Naming them costs one line each
--- and turns a typo-shaped failure into a schedule answer.
local PLANNED < const >: {string} = {
  "run", "regen",
  "ci", "coverage", "enforce", "reproducible", "offline",
}

--- Verbs lowered onto the graph, and the make target each builds.
---
--- `check` is deliberately absent: it runs in process, so the one verb
--- that tells you whether a project is even coherent needs no make
--- binary at all. `clean` is absent for the opposite reason — removing
--- `o/` through a graph whose rules live in `o/` is a knot with no
--- payoff.
local TARGETS < const >: {string: string} = {
  build = "build",
  fmt = "fmt",
  test = "test",
}

--- Which files each graph verb acts on, and the make variable a
--- selection overrides. A command-line assignment beats the one in
--- `o/project.mk`, so selection needs no rules of its own: everything
--- downstream is derived from these lists.
local record Selection
  kinds: {Kind}
  suffix: string
  variable: string
end

--- The formattable kinds, as the sorted list a Selection wants.
--- @return {Kind} The kinds, in a stable order
local function fmt_kinds(): {Kind}
  local out: {Kind} = {}
  for k in pairs(types.fmt_kinds) do
    out[#out + 1] = k as Kind -- cast: the table is keyed by Kind
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
  test = {kinds = {"test"}, suffix = "", variable = "tests"},
}

--- Usage, printed for a bare `--make` and after an unknown verb.
--- @return string The usage text, without a trailing newline
local function usage(): string
  return "usage: cosmic --make <verb> [paths…]\n" ..
  "make: verbs: " .. table.concat(IMPLEMENTED, ", ") .. "\n" ..
  "make: planned: " .. table.concat(PLANNED, ", ")
end

--- Is this verb one the design defines but this slice does not ship?
--- @param verb string The verb requested
--- @return boolean True when the verb is planned
local function is_planned(verb: string): boolean
  for _, v in ipairs(PLANNED) do
    if v == verb then
      return true
    end
  end
  return false
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
    -- An empty suffix means "no suffix filter". Guarding it explicitly
    -- because `("x"):sub(-0)` is `sub(0)` -- the whole string, not the
    -- empty tail -- so the comparison would silently match nothing.
    if sel.suffix == "" or f.path:sub(-#sel.suffix) == sel.suffix then
      out[#out + 1] = f
    end
  end
  return out
end

--- Run a verb that is lowered onto the graph.
---
--- Validation runs first here too, and not only for symmetry with
--- `check`: a filename carrying whitespace would be split across two
--- arguments of a recipe line, so a project the validator rejects is
--- one whose paths must not reach make at all.
--- @param verb string A key of TARGETS
--- @param proj Project The scanned project
--- @param paths {string} Selection paths
--- @param cosmic string Absolute path to this binary, resolved before chdir
--- @return integer Exit code
local function run_graph(verb: string, proj: Project, paths: {string},
    cosmic: string): integer
  local issues = validate.validate(proj)
  if #issues > 0 then
    io.stderr:write(validate.format_issues(issues) .. "\n")
    return verdict(verb, false, #issues .. " validation " ..
      (#issues == 1 and "error" or "errors"))
  end

  local sel = SELECTS[verb]
  local picked, serr = project.select(candidates(proj, sel), paths, proj.root)
  if not picked then
    io.stderr:write((serr or "make: no such selection") .. "\n")
    return verdict(verb, false, "bad selection")
  end
  local files = picked as {File} -- cast: record union after the guard

  local overrides: {string} = {}
  if #paths > 0 then
    overrides[1] = sel.variable .. "=" ..
    table.concat(project.paths_of(files), " ")
  end

  local code, gerr = graph.run(proj, TARGETS[verb], overrides, cosmic)
  if gerr and gerr ~= "" then
    io.stderr:write(gerr .. "\n")
    return verdict(verb, false, "make")
  end
  local noun = #files == 1 and " file" or " files"
  local detail = #files .. noun

  -- The artifacts, once the tree they are assembled from exists. A
  -- SELECTED build compiles part of the tree, so it cannot produce a
  -- whole artifact — it stops at the compile, which is what the
  -- verdict then reports.
  if verb == "build" and code == 0 and #paths == 0 then
    -- Generation is a phase over the project, before any staging: the
    -- ROOT payload is staged into every binary, so its generator must
    -- run once and before the first of them.
    local gok, generr = artifact.generate(proj, cosmic)
    if not gok then
      io.stderr:write((generr or "make: payload generation failed") .. "\n")
      return verdict(verb, false, detail .. ", generate failed")
    end
    local built = 0
    for _, b in ipairs(proj.binaries) do
      local out, aerr = artifact.build(proj, b, cosmic)
      if not out then
        io.stderr:write((aerr or "make: cannot build the artifact") .. "\n")
        return verdict(verb, false, detail .. ", " .. b.name .. " failed")
      end
      io.write("make: " .. (out as string) .. "\n") -- cast: scalar narrowing after the guard
      built = built + 1
    end
    if built > 0 then
      detail = detail .. ", " .. built ..
      (built == 1 and " binary" or " binaries")
    end
  end
  return verdict(verb, code == 0, detail)
end

--- `clean` — remove the build directory, in process. Driving this
--- through the graph would mean reading rules out of the directory
--- being deleted.
--- @return integer Exit code
local function run_clean(): integer
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

--- Run one `--make` invocation.
--- @param argv {string} The verb followed by selection paths
--- @return integer Exit code
local function run(argv: {string}): integer
  local verb = argv[1]
  if not verb or verb == "" then
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

  -- `fetch` is the one verb that skips validation below, and can:
  -- it reads pins and nothing else, so a project whose sources do not
  -- yet type-check can still resolve its dependencies -- which is the
  -- order a cold checkout needs.
  if verb ~= "check" and verb ~= "clean" and verb ~= "fetch"
  and TARGETS[verb] == nil then
    if is_planned(verb) then
      io.stderr:write("make: '" .. verb ..
        "' is planned but not implemented yet\nmake: verbs: " ..
        table.concat(IMPLEMENTED, ", ") .. "\n")
    else
      io.stderr:write("make: unknown verb '" .. verb .. "'\n" ..
        usage() .. "\n")
    end
    return 1
  end

  local proj, err = open_project(verb)
  if not proj then
    io.stderr:write((err or "make: failed") .. "\n")
    return verdict(verb, false, "no project")
  end
  local p = proj as Project -- cast: record union after the guard
  if verb == "check" then
    return check.run(p, paths)
  end
  if verb == "clean" then
    return run_clean()
  end
  -- The one verb with a network. It needs no compiled tree and no make
  -- binary: a pin's scope is the pin file itself.
  if verb == "fetch" then
    return fetch.run(p, paths)
  end
  return run_graph(verb, p, paths, self)
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
  IMPLEMENTED = IMPLEMENTED,
  PLANNED = PLANNED,
  usage = usage,
  run = run,
  scan = project.scan,
  validate = validate.validate,
}

return M
