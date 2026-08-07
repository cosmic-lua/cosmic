--- Driving make from the project model.
---
--- Two files land in `o/` and make reads both. `o/cosmic.mk` is
--- CONSTANT — it ships in the binary and is byte-identical for every
--- project, so this module copies it out rather than composing it.
--- `o/project.mk` is generated and holds **only variable assignments**:
--- discovery and validation stay in Teal, where an error can name a
--- path, and codegen shrinks to "emit a list of variables". No rule is
--- ever generated, which is also why this repo's makefile ratchets can
--- collapse from "scan generated recipe text" to "one file that does
--- not change".
---
--- Both are written only when their bytes change, so re-running a verb
--- does not invalidate the graph it just built.

local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local deps = require("_make.deps")
local imports = require("_make.imports")
local project = require("_make.project")
local stamp = require("_make.stamp")
local testrun = require("_make.testrun")
local types = require("_make.types")

local type Kind = types.Kind
local type Project = types.Project

--- Where the constant rules live inside the binary.
local RULES_ZIP < const > = "/zip/cosmic.mk"

--- Where the graph engine lives inside the binary. Amends D13: make
--- ships in the release, because a user with one binary in a bare
--- sandbox has nothing to find and nothing to fetch with.
local MAKE_ZIP < const > = "/zip/make"

--- Environment override naming the make binary.
local MAKE_ENV < const > = "COSMIC_MAKE"

--- Environment override for the job count.
local JOBS_ENV < const > = "COSMIC_JOBS"

--- Kinds whose `.tl` sources compile into `$(O)`.
--- The kinds whose files are compiled into `o/`.
---
--- Two callers ask: the facts writer below (which lists them for the
--- compile rules) and `source_dirs` (which a coverage report scans for
--- files no test ever loaded).
local compiled_kinds < const >: {Kind: boolean} = {
  module = true,
  entry = true,
  test = true,
  example = true,
  benchmark = true,
  gen = true,
}

--- Kinds whose targets RUN against the compiled tree, so each needs the
--- BUILT closure of what it imports: built before it, and the whole of
--- what its fence may read.
local runs_against_the_stage < const >: {Kind: boolean} = {
  test = true,
  example = true,
  benchmark = true,
}

--- The distinct directories holding compiled sources, sorted.
---
--- What a coverage report needs to see a module NO test loaded: the
--- collected data names only files that ran, so a module with no test
--- at all is invisible without a directory to scan.
--- @param proj Project The scanned project
--- @return {string} Directory paths relative to the root
local function source_dirs(proj: Project): {string}
  local seen: {string: boolean} = {}
  local out: {string} = {}
  for _, f in ipairs(proj.files) do
    if compiled_kinds[f.kind] then
      local dir = fs.dirname(f.path)
      if dir == "" then
        dir = "."
      end
      if not seen[dir] then
        seen[dir] = true
        out[#out + 1] = dir
      end
    end
  end
  table.sort(out)
  return out
end

--- Write `path` only when the bytes differ, so a no-op run does not
--- touch an mtime the graph schedules on.
--- @param path string Destination
--- @param content string Desired contents
--- @return boolean, string Success, or false plus the error
local function write_if_changed(path: string, content: string): boolean, string
  if fs.read(path) == content then
    return true
  end
  local ok, err = fs.make_dirs(fs.dirname(path))
  if not ok then
    return false, "make: cannot create " .. fs.dirname(path) .. ": " ..
    (err or "unknown error")
  end
  local wok, werr = fs.write(path, content)
  if not wok then
    return false, "make: cannot write " .. path .. ": " ..
    (werr or "unknown error")
  end
  return true
end

--- Render one `name := a b c` line, sorted so the file is a function of
--- the tree and nothing else.
--- @param name string Variable name
--- @param values {string} Values
--- @return string The assignment line
local function assign(name: string, values: {string}): string
  local sorted: {string} = {}
  for _, v in ipairs(values) do
    sorted[#sorted + 1] = v
  end
  table.sort(sorted)
  return name .. " := " .. table.concat(sorted, " ")
end

--- The facts file: what the walk found, as make variables.
---
--- Nothing here is a rule, and nothing here is a path cosmic invented —
--- every value is a file that exists, spelled relative to the root.
--- @param proj Project The scanned project
--- @param cosmic string Absolute path to the cosmic binary
--- @return string | nil The contents of o/project.mk
--- @return string The refusal when a reads declaration is stale
local function project_mk(proj: Project, cosmic: string): string | nil, string
  local tl_sources: {string} = {}
  local lua_sources: {string} = {}
  local fmt_sources: {string} = {}
  local tests: {string} = {}
  local examples: {string} = {}
  local benchmarks: {string} = {}
  local assets: {string} = {}
  -- `lint`'s set: the widest one here, because lint reads bytes -- a
  -- `.md`, a `.mk` and a `.yml` are all in scope -- and the model has
  -- already excluded `o/` and whatever `.cosmicignore` names. Not
  -- `testdata`, whose files are deliberately wrong on purpose; the
  -- kinds are enumerated once, in stage.tl's selection table.
  local lint_sources: {string} = {}

  for _, f in ipairs(proj.files) do
    if types.lint_kinds[f.kind] then
      lint_sources[#lint_sources + 1] = f.path
    end
    local is_tl = f.path:sub(-3) == ".tl"
    -- By KIND, not by suffix. Taking every `.tl` swept in the two kinds
    -- whose whole job is to stay out of the model: a `testdata/`
    -- fixture (deliberately broken source is the point) and `embed/`
    -- payload (verbatim vendored sources -- cosmic ships its own that
    -- way). Full `fmt` then gated files a selected `fmt` did not,
    -- because selection consults kinds and this did not.
    if is_tl and types.fmt_kinds[f.kind] then
      fmt_sources[#fmt_sources + 1] = f.path
    end
    if compiled_kinds[f.kind] then
      if is_tl then
        tl_sources[#tl_sources + 1] = f.path
      else
        lua_sources[#lua_sources + 1] = f.path
      end
    end
    if f.kind == "test" then
      tests[#tests + 1] = f.path
    elseif f.kind == "example" then
      examples[#examples + 1] = f.path
    elseif f.kind == "benchmark" then
      benchmarks[#benchmarks + 1] = f.path
    elseif f.kind == "asset" then
      assets[#assets + 1] = f.path
    end
  end

  -- Import closures, per file. This is the whole reason the facts are
  -- computed in Teal — a makefile cannot follow a require() edge — and
  -- each closure serves the graph and the fence with one answer.
  --
  -- Two flavours, and the distinction is not cosmetic. A COMPILE needs
  -- SOURCE paths, because a strict compile type-checks against the
  -- modules it imports and the checker resolves those to `.tl` through
  -- the include path: without them, changing a module's contract left
  -- its importers un-recompiled and the incremental build shipped code
  -- a clean build rejects. A TEST needs BUILT paths, because it runs
  -- against compiled Lua.
  local dep_lines: {string} = {}
  local by_import = deps.index(proj)
  for _, f in ipairs(proj.files) do
    -- The make-variable stem is the path with its EXTENSION removed,
    -- because that is the stem the pattern rules produce: a target
    -- `o/x_test.lua.test.got` matching `$(O)/%.lua.test.got` has stem
    -- `x_test`. Stripping only `.tl` named the `.lua` twin's variable
    -- `deps_x_test.lua`, which no rule ever expands -- so a `.lua` test
    -- got an EMPTY closure: never rebuilt when an import changed, and
    -- fenced away from the modules it requires.
    local stem = (f.path:gsub("%.tl$", ""):gsub("%.lua$", ""))
    if compiled_kinds[f.kind] and f.path:sub(-3) == ".tl" then
      dep_lines[#dep_lines + 1] = assign("srcdeps_" .. stem,
        deps.source_paths(deps.closure(proj, f, by_import)))
    end
    -- Examples and benchmarks get the same closure as tests, and for
    -- the same reason: each RUNS against the compiled tree, so what it
    -- imports must be built before it and is exactly what its fence may
    -- read. The model already says so — a rule cannot ask for a closure
    -- nobody emitted, and `cosmic.mk` asks for all three.
    if runs_against_the_stage[f.kind] then
      -- Declared reads (`--- reads: <path>`) join the closure: one
      -- declaration is prerequisite, content key, and fence grant.
      local built = deps.built_paths(deps.closure(proj, f, by_import))
      local extra, rerr = imports.reads_of_file(proj.root, f.path)
      if not extra then
        return nil, "make: " .. (rerr or "bad reads declaration")
      end
      -- cast: narrowing does not survive the early-exit guard above
      for _, r in ipairs(extra as {string}) do
        built[#built + 1] = r
      end
      dep_lines[#dep_lines + 1] = assign("deps_" .. stem, built)
    end
  end
  table.sort(dep_lines)

  local lines: {string} = {
    "# Generated by cosmic --make. Variables only — the rules are the",
    "# constant o/cosmic.mk. Do not edit; do not commit (o/ is output).",
    "COSMIC := " .. cosmic,
    -- No COSMIC_DEP any more: the rules name per-tool stamp files
    -- (`o/.stamp/<tool>`, written by materialize below) instead of the
    -- binary, so a result is as fresh as its tool without every edit
    -- invalidating the whole graph — _make/stamp.tl and d17 have the
    -- rationale and the traded edge.
    "O := " .. project.BUILD_DIR,
    "project := " .. fs.basename(proj.root),
    assign("tl_sources", tl_sources),
    assign("lua_sources", lua_sources),
    assign("fmt_sources", fmt_sources),
    assign("tests", tests),
    assign("examples", examples),
    assign("benchmarks", benchmarks),
    assign("assets", assets),
    assign("lint_sources", lint_sources),
    assign("coverage_dirs", source_dirs(proj)),
    -- The runner tests exec, and its prerequisite: _make/testrun.tl.
    testrun.mk_facts(proj),
  }
  for _, l in ipairs(dep_lines) do
    lines[#lines + 1] = l
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Materialize both makefiles under `o/`.
--- @param proj Project The scanned project
--- @param cosmic string Absolute path to the cosmic binary
--- @return string|nil Path to the rules file, or nil on failure
--- @return string The error message when materializing failed
local function materialize(proj: Project, cosmic: string): string | nil, string
  local rules = fs.read(RULES_ZIP)
  if not rules then
    return nil, "make: the rules file is missing from this binary (" ..
    RULES_ZIP .. ")"
  end
  local out = fs.join(project.BUILD_DIR, "cosmic.mk")
  local ok, err = write_if_changed(out, rules)
  if not ok then
    return nil, err
  end
  local mk, mkerr = project_mk(proj, cosmic)
  if not mk then return nil, mkerr end
  ok, err = write_if_changed(fs.join(project.BUILD_DIR, "project.mk"),
    mk as string) -- cast: scalar narrowing after the guard
  if not ok then
    return nil, err
  end
  -- The stamps are prerequisites the rules name, so they must exist --
  -- with an honest mtime -- before make reads a rule. Same
  -- write-if-changed contract as both makefiles, for the same reason.
  ok, err = stamp.write_all(proj, cosmic)
  if not ok then
    return nil, err
  end
  return out
end

--- Extract the embedded make to `o/make`.
---
--- The engine ships inside the binary, so a project needs nothing
--- installed: extraction is a copy out of this executable's own zip,
--- and it happens once. Written through a temp file and renamed, so a
--- concurrent build cannot exec a half-written engine.
--- @param to string Destination path
--- @return boolean, string Success, or false plus the reason
local function extract_make(to: string): boolean, string
  local bytes = fs.read(MAKE_ZIP)
  if not bytes then
    return false, "make: this cosmic carries no engine at " .. MAKE_ZIP
  end
  local ok, merr = fs.make_dirs(fs.dirname(to))
  if not ok then
    return false, "make: cannot create " .. fs.dirname(to) .. ": " ..
    (merr or "unknown error")
  end
  -- Per-process temp name. A fixed one defeats the whole point of
  -- temp+rename: two concurrent `--make` runs in a fresh tree both
  -- extract, and one can rename while the other is mid-write, briefly
  -- installing a truncated engine that then fails every later build
  -- with no pointer back at the race.
  local tmp = to .. ".tmp." .. tostring(proc.getpid())
  local wok, werr = fs.write(tmp, bytes, tonumber("755", 8) as integer) -- cast: octal is integral
  if not wok then
    return false, "make: cannot write " .. tmp .. ": " .. (werr or "unknown error")
  end
  -- write's mode only applies on create, so set it unconditionally: an
  -- engine that is not executable is the one failure mode that reads as
  -- "no make binary" rather than as a permissions problem.
  local _ok, _err = fs.chmod(tmp, tonumber("755", 8) as integer) -- cast: octal is integral
  local rok, rerr = fs.rename(tmp, to)
  if not rok then
    local _ok, _err = fs.unlink(tmp)
    -- Losing the race is not a failure: the winner installed the same
    -- embedded bytes this process was about to.
    if fs.is_file(to) then
      return true
    end
    return false, "make: cannot install " .. to .. ": " .. (rerr or "unknown error")
  end
  return true
end

--- Find the make binary.
---
--- `COSMIC_MAKE` names it; otherwise the copy under `o/`, extracted from
--- this binary on first use. PATH is never searched: a build that picks
--- up whatever make the host happens to have is a build whose engine is
--- not pinned, and with the engine embedded there is nothing to find.
--- @return string|nil The make binary, or nil with the refusal
--- @return string The error message
local function find_make(): string | nil, string
  local named = os.getenv(MAKE_ENV)
  if named and named ~= "" then
    local abs = fs.abspath(named)
    if not fs.is_file(abs) then
      return nil, "make: " .. MAKE_ENV .. " names no such file: " .. named
    end
    return abs
  end
  local extracted = fs.abspath(fs.join(project.BUILD_DIR, "make"))
  if fs.is_file(extracted) then
    return extracted
  end
  local ok, err = extract_make(extracted)
  if not ok then
    return nil, (err or "make: no engine") ..
    "\nmake: name one instead: " .. MAKE_ENV .. "=/path/to/make" ..
    " cosmic --make build"
  end
  return extracted
end

--- How many jobs to run. Everything is parallel by default, which is
--- defensible only because isolation is structural rather than
--- conventional.
--- @return string The `-j<n>` flag
local function jobs_flag(): string
  local named = os.getenv(JOBS_ENV)
  if named and named:match("^%d+$") then
    return "-j" .. named
  end
  local n = sys.nproc()
  return "-j" .. tostring(n or 4)
end

--- Build the graph for one target.
---
--- Returns make's own exit code. Output streams as it runs (`inherit`),
--- so a long build reports progress instead of arriving all at once.
--- Selection travels as command-line variable assignments, which beat
--- the ones in `o/project.mk`. Everything downstream is derived from
--- those lists, so narrowing a run needs no rules of its own — and the
--- rules file stays constant, which is the property the whole design
--- rests on.
--- The cosmic path is passed in, never derived here: `--make` has
--- already chdir'd to the project root by this point, so resolving a
--- relative `arg[-1]` now would produce a path inside the project. The
--- downstream layout the design recommends is `./cosmic --make ci` from
--- a committed binary, which is exactly the case that would break.
--- @param proj Project The scanned project
--- @param target string The make target to build
--- @param overrides {string} `name=value` assignments, one argv each
--- @param cosmic string Absolute path to the cosmic binary
--- @return integer Exit code
--- @return string An error message when make could not be started
--- This process's environment with make's own variables removed.
--- @return {string} The environment, as NAME=VALUE entries
local function clean_env(): {string}
  return env.list({drop = {
        "MAKEFLAGS", "MAKELEVEL", "MFLAGS", "MAKE_TERMOUT", "MAKE_TERMERR",
      }})
end

local function run(proj: Project, target: string, overrides: {string},
    cosmic: string, extra?: {string}): integer, string
  local rules, merr = materialize(proj, cosmic)
  if not rules then
    return 1, merr or "make: could not write the build files"
  end
  local mk, ferr = find_make()
  if not mk then
    return 1, ferr or "make: no make binary"
  end
  -- No builtin rules or variables: the vocabulary is closed, and a
  -- builtin pattern firing on a .lua or .tl would run a step nobody
  -- wrote.
  -- `-s` because the TOOL owns the progress voice: a recipe line here
  -- is argv, ~400 characters of driver path, sources, include dir and
  -- import closure, with the one fact a reader wants buried mid-line.
  -- The driver prints `<verb> <what it writes>` instead.
  local argv: {string} = {
    mk as string, -- cast: scalar narrowing after the guard
    "--no-builtin-rules",
    "--no-builtin-variables",
    "-s",
    "-f", rules as string, -- cast: scalar narrowing after the guard
    jobs_flag(),
  }
  for _, o in ipairs(overrides or {}) do
    argv[#argv + 1] = o
  end
  argv[#argv + 1] = target
  for _, g in ipairs(extra or {}) do -- extra goals build in the same run
    argv[#argv + 1] = g
  end
  -- MAKEFLAGS is cleared, and MAKELEVEL with it. A selection is passed
  -- as a command-line variable assignment, and GNU make propagates
  -- those to sub-makes -- so a `--make test <one-test>` whose test runs
  -- `--make test` in a fixture handed the inner make the OUTER run's
  -- target list, and it stopped with "no rule to make target" naming a
  -- file in a project it had never heard of. A nested `--make` is a
  -- different project's build, not a recursive step of this one.
  local h, serr = child.start(argv, {
      cwd = proj.root,
      stdout = "inherit",
      stderr = "inherit",
      env = clean_env(),
    })
  if not (h is child.Handle) then
    return 1, "make: cannot start " .. (mk as string) .. ": " .. -- cast: scalar narrowing after the guard
    (serr or "unknown error")
  end
  -- cast: Teal's narrowing does not survive the early-exit guard above
  local res, werr = (h as child.Handle):wait()
  if not (res is child.Result) then
    return 1, "make: " .. (werr or "unknown error")
  end
  if res.signal then
    return 1, "make: killed by signal " .. tostring(res.signal)
  end
  return res.code or 1
end

local record GraphModule
  MAKE_ENV: string
  MAKE_ZIP: string
  extract_make: function(to: string): boolean, string
  JOBS_ENV: string
  RULES_ZIP: string
  project_mk: function(proj: Project, cosmic: string): string | nil, string
  materialize: function(proj: Project, cosmic: string): string | nil, string
  find_make: function(): string | nil, string
  jobs_flag: function(): string
  run: function(proj: Project, target: string, overrides: {string}, cosmic: string, extra?: {string}): integer, string
  source_dirs: function(proj: Project): {string}
end

local M: GraphModule = {
  MAKE_ENV = MAKE_ENV,
  MAKE_ZIP = MAKE_ZIP,
  extract_make = extract_make,
  JOBS_ENV = JOBS_ENV,
  RULES_ZIP = RULES_ZIP,
  project_mk = project_mk,
  materialize = materialize,
  find_make = find_make,
  jobs_flag = jobs_flag,
  run = run,
  source_dirs = source_dirs,
}

return M
