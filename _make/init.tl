--- `cosmic --make <verb> [paths…]` — cosmic's build system.
---
--- `--make` builds a project. It is not a wrapper around `--embed` and
--- it does not emit a Makefile for someone else to run: it drives the
--- build itself, with the engine it ships.
---
--- This file is the registry: what verbs there are, and what each one
--- does around the graph. The model is project.tl, the validator
--- validate.tl, root discovery root.tl, and the lowering itself
--- stage.tl. Verbs the design names but this binary does not implement
--- are listed too rather than hidden, so a run that asks for one gets
--- told where it stands instead of "unknown option".

local cenv = require("cosmic.env")
local fs = require("cosmic.fs")
local root = require("_make.root")
local binsel = require("_make.binaries")
local converge = require("_make.converge")
local help = require("_make.help")
local law = require("_make.law")
local project = require("_make.project")
local runverb = require("_make.runverb")
local artifact = require("_make.artifact")
local check = require("_make.check")
local clean = require("_make.clean")
local docs = require("_make.docs")
local fetch = require("_make.fetch")
local generate = require("_make.generate")
local graph = require("_make.graph")
local policy = require("_make.policy")
local stage = require("_make.stage")
local types = require("_make.types")
local validate = require("_make.validate")

local type Binary = types.Binary
local type Issue = types.Issue
local type Project = types.Project
local type Verb = types.Verb

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

--- Forward declaration: `build`'s row needs its runner, and its runner
--- needs the registry to find its own row.
local by_name: function(name: string): Verb | nil

--- Whether `coverage` should rewrite the committed floor rather than
--- gate against it. Set by the argv scan in `run` below, read by the
--- registry row: a verb's runner takes the project and its paths, and
--- threading one flag through every signature to reach one row is the
--- worse trade.
local baseline_wanted = false

--- Whether `fmt` should REWRITE rather than report. Same shape as
--- `--baseline` above and the same reason: it is not a selection and
--- not a verb of its own, it is what to do with what the verb finds.
local fix_wanted = false

--- Generate the payloads and pack the named binaries.
---
--- The step after the graph, shared by `build` (whose product it is)
--- and `test` (which needs the binaries to exist before a test can
--- spawn one).
--- @param proj Project The scanned project
--- @param binaries {Binary} The artifacts to pack
--- @param cosmic string Absolute path to this binary
--- @param announce boolean Whether to print each artifact's path
--- @return boolean Whether every artifact was packed
--- @return string Detail for the verdict line, or the failure
local function assemble(proj: Project, binaries: {Binary}, cosmic: string,
    announce: boolean): boolean, string
  -- Generation is a phase over the project, before any staging: the
  -- ROOT payload is staged into every binary, so its generator must
  -- run once and before the first of them.
  local gok, generr = generate.generate(proj, cosmic)
  if not gok then
    io.stderr:write((generr or "make: payload generation failed") .. "\n")
    return false, "generate failed"
  end
  local built = 0
  for _, b in ipairs(binaries) do
    local out, aerr = artifact.build(proj, b, cosmic)
    if not out then
      io.stderr:write((aerr or "make: cannot build the artifact") .. "\n")
      return false, b.name .. " failed"
    end
    if announce then
      io.write("make: " .. (out as string) .. "\n") -- cast: scalar narrowing after the guard
    end
    built = built + 1
  end
  if built == 0 then
    return true, ""
  end
  return true, built .. (built == 1 and " binary" or " binaries")
end

--- `build` — compile the tree, then assemble the selected artifacts.
---
--- The step after the graph is genuinely build's own, so it lives in
--- build's runner rather than as a condition inside the shared graph
--- path. The whole tree compiles either way: a selected build must
--- stage exactly what a full one would, so narrowing the compile is the
--- one thing selection may not do here.
--- @param proj Project The scanned project
--- @param paths {string} Selection paths naming binaries
--- @param cosmic string Absolute path to this binary
--- @return integer Exit code
local function run_build(proj: Project, paths: {string},
    cosmic: string): integer
  local wanted, werr = binsel.select(proj, paths)
  if not wanted then
    io.stderr:write(werr .. "\n")
    return stage.verdict("build", false, "bad selection")
  end
  local binaries = wanted as {Binary} -- cast: record union after the guard
  local v = by_name("build") as Verb -- cast: the registry defines it
  local ok, detail = stage.graph_stage(v, proj, {}, cosmic)
  if not ok then
    return stage.verdict("build", false, detail)
  end
  local aok, adetail = assemble(proj, binaries, cosmic, true)
  if not aok then
    return stage.verdict("build", false, detail .. ", " .. adetail)
  end
  if adetail ~= "" then
    detail = detail .. ", " .. adetail
  end
  return stage.verdict("build", true, detail)
end

--- `test` and `example` — the binaries first, then the targets that
--- run against them.
---
--- Assembling before testing is not `test` doing `build`'s job: it is
--- the staging step the design already assigns to `test` ("build the
--- stage, run `*_test.tl` fenced against it") extended to the one part
--- of the stage a test cannot produce for itself. A project with no
--- binaries pays nothing for it.
--- @param v Verb The test verb
--- @param proj Project The scanned project
--- @param paths {string} Selection paths naming tests
--- @param cosmic string Absolute path to this binary
--- @return integer Exit code
--- Put the project's binaries where a test can find them.
---
--- Every lane that RUNS the project's own code needs this, not just
--- `test`: a test spawning the binary under test fails identically in
--- the coverage lane, and failing there only is the worst shape — the
--- gate reports a stage red for a reason that has nothing to do with
--- what the stage measures.
--- @param proj Project The scanned project
--- @param cosmic string Absolute path to this binary
--- @return boolean True when the stage is ready
--- @return string The error message
local function prepare_stage(proj: Project, cosmic: string): boolean, string
  if #proj.binaries == 0 then
    return true, ""
  end
  local b = by_name("build") as Verb -- cast: the registry defines it
  local ok, detail = stage.graph_stage(b, proj, {}, cosmic)
  if not ok then
    return false, detail
  end
  local aok, adetail = assemble(proj, proj.binaries, cosmic, false)
  if not aok then
    return false, adetail
  end
  stage.binaries_on_path(proj)
  return true, ""
end

local function run_against_stage(v: Verb, proj: Project, paths: {string},
    cosmic: string): integer
  local ok, detail = prepare_stage(proj, cosmic)
  if not ok then
    return stage.verdict(v.name, false, detail)
  end
  return stage.run_graph(v, proj, paths, cosmic)
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
  {name = "build", target = "build", select = stage.SELECTS.build, run = run_build},
  -- `check` generates first, like every other verb that touches the
  -- graph -- it just does not lower onto make, so it has to say so
  -- itself. The checker resolves `cosmo.*` through what
  -- `_types/types_gen.tl` writes: without this, `--make check` on a
  -- cold tree fails on unresolvable `cosmo.*`, and after a pin bump it
  -- checks against the types the last run left.
  {name = "check", run = function(proj: Project, paths: {string},
        cosmic: string): integer
      local ok, err = generate.sources(proj, cosmic)
      if not ok then
        io.stderr:write((err or "make: source generation failed") .. "\n")
        return stage.verdict("check", false, "generate failed")
      end
      return check.run(proj, paths)
    end},
  {name = "clean", run = clean.run},
  {name = "fetch", run = function(proj: Project, paths: {string},
        _cosmic: string): integer
      return fetch.run(proj, paths)
    end},
  {name = "fmt", target = "fmt", select = stage.SELECTS.fmt,
    run = function(proj: Project, paths: {string}, cosmic: string): integer
      if fix_wanted then
        return policy.fix(proj, paths)
      end
      -- cast: the registry defines it
      return stage.run_graph(by_name("fmt") as Verb, proj, paths, cosmic)
    end},
  {name = "test", target = "test", select = stage.SELECTS.test,
    run = function(proj: Project, paths: {string}, cosmic: string): integer
      -- cast: the registry defines it
      return run_against_stage(by_name("test") as Verb, proj, paths, cosmic)
    end},
  -- `run` takes a PATH, never a binary name -- see _make.runverb.
  {name = "run", passthrough = true,
    run = function(proj: Project, paths: {string}, cosmic: string): integer
      return runverb.run(proj, paths[1], cosmic, prepare_stage)
    end},
  -- `docs` renders the API to markdown. Its file set comes from the
  -- model, so a directory added to the project is documented without
  -- anyone remembering to say so.
  {name = "docs", run = function(proj: Project, paths: {string},
        _cosmic: string): integer
      local n, err = docs.render(proj, paths)
      if err ~= "" then
        return stage.verdict("docs", false, err)
      end
      return stage.verdict("docs", true, n .. " pages")
    end},
  -- `example` is `test`'s sibling everywhere else in the model -- a
  -- first-class kind with the same scope semantics, a gate this repo
  -- runs today -- and the verb set was the one place the symmetry
  -- broke. `lint` is the other half of that gate (the 500-line cap,
  -- the cast ratchet, both already public in `cosmic.style`), and it
  -- gets a verb rather than folding into `check` because its file set
  -- is the whole tree, not the compiled closure. Naming them is what
  -- lets `ci` below be a list of verb names: its pipeline is
  -- fmt -> check -> test -> example -> lint -> coverage, and every one
  -- of those six is a verb in this registry.
  {name = "example", target = "example", select = stage.SELECTS.example,
    run = function(proj: Project, paths: {string}, cosmic: string): integer
      -- cast: the registry defines it
      return run_against_stage(by_name("example") as Verb, proj, paths, cosmic)
    end},
  -- `test`'s third sibling. It runs against the stage for the same
  -- reason `test` and `example` do: a benchmark measures the project's
  -- own code, and often the binary the project builds.
  {name = "benchmark", target = "benchmark", select = stage.SELECTS.benchmark,
    run = function(proj: Project, paths: {string}, cosmic: string): integer
      -- cast: the registry defines it
      return run_against_stage(by_name("benchmark") as Verb, proj, paths, cosmic)
    end},
  {name = "lint", target = "lint", select = stage.SELECTS.lint},
  {name = "ci", run = function(proj: Project, paths: {string},
        cosmic: string): integer
      return policy.run_ci(by_name, proj, paths, cosmic)
    end},
  {name = "coverage", target = "coverage", select = stage.SELECTS.coverage,
    run = function(proj: Project, paths: {string}, cosmic: string): integer
      local v = by_name("coverage") as Verb -- cast: the registry defines it
      local ready, perr = prepare_stage(proj, cosmic)
      if not ready then
        return stage.verdict("coverage", false, perr)
      end
      if baseline_wanted then
        local code = run_against_stage(v, proj, paths, cosmic)
        if code ~= 0 then
          return code
        end
        return policy.write_baseline(proj)
      end
      return policy.run_coverage(v, proj, paths, cosmic)
    end},
  {name = "enforce", planned = true},
  {name = "reproducible", planned = true},
  {name = "offline", planned = true},
}

local INDEX < const >: {string: Verb} = {}
help.bind(VERBS)

for _, v in ipairs(VERBS) do
  INDEX[v.name] = v
end

by_name = function(name: string): Verb | nil
  return INDEX[name]
end

--- Run one `--make` invocation.
--- @param argv {string} The verb followed by selection paths
--- @return integer Exit code
local function run(argv: {string}): integer
  local name = argv[1]
  if not name or name == "" then
    io.stderr:write(help.usage() .. "\n")
    return 1
  end

  -- Asked for, so it answers on stdout and succeeds. It is documented
  -- in two places as the way to list the verbs, and it reached the
  -- reader only as the unknown-verb error's incidental output: the
  -- right text, on stderr, under exit 1. It also answers before
  -- open_project, because "what are the verbs" is the question you have
  -- when you are not yet standing in a project.
  if name == "help" then
    io.write(help.usage() .. "\n")
    return 0
  end

  -- One flag, on one verb. `--baseline` is not a selection and not a
  -- verb of its own: rewriting the floor needs the run that produced
  -- the data, so it is the same verb saying what to do with the result.
  --
  -- Everything else beginning with `-` is REFUSED rather than treated
  -- as a path. Selection space had no bottom: `--make fmt --fix` (a
  -- spelling the design's own verb table promises) died as
  -- `nothing to do under: --fix`, and so did `--help`, `--only=x`, and
  -- every flag a later version might add. Reserving the namespace now
  -- is the same durability move the planned-verb rows already make for
  -- the verb namespace.
  local paths: {string} = {}
  baseline_wanted = false
  fix_wanted = false
  -- A passthrough verb's argv is its own; the split is its rule, over
  -- in _make.runverb.
  local passthrough = (INDEX[name] ~= nil and INDEX[name].passthrough) or false
  if passthrough then
    local target, terr = runverb.split(argv, 2)
    if target == nil then
      io.stderr:write(terr .. "\n")
      return stage.verdict(name, false, "no target")
    end
    paths[1] = target as string -- cast: nil ruled out by the guard above
  end
  for i = 2, (passthrough and 1 or #argv) do
    if argv[i] == "--baseline" then
      baseline_wanted = true
    elseif argv[i] == "--fix" then
      fix_wanted = true
    elseif argv[i]:sub(1, 1) == "-" and argv[i] ~= "-" then
      io.stderr:write("make: unknown flag '" .. argv[i] .. "' for " ..
        name .. "\n")
      return stage.verdict(name, false, "unknown flag")
    else
      paths[#paths + 1] = argv[i]
    end
  end
  if fix_wanted and name ~= "fmt" then
    io.stderr:write("make: --fix belongs to `fmt`, not '" .. name .. "'\n")
    return stage.verdict(name, false, "--fix")
  end
  if baseline_wanted and name ~= "coverage" then
    io.stderr:write("make: --baseline belongs to `coverage`, not '" ..
      name .. "'\n")
    return stage.verdict(name, false, "--baseline")
  end
  -- A rewrite from a narrowed run is a floor built from partial data:
  -- every unselected file measures zero and its row craters. The gate
  -- path already skips a narrowed run rather than failing it, for the
  -- same reason; this is the writing half of that decision.
  if baseline_wanted and #paths > 0 then
    io.stderr:write("make: --baseline rewrites the whole floor; " ..
      "it takes no paths\n")
    return stage.verdict(name, false, "--baseline takes no paths")
  end

  -- Resolve this binary BEFORE anything chdirs: a relative `./cosmic`
  -- resolved after chdir would point inside the project, not at itself.
  -- (root.resolve_self also covers a PATH-invoked bare argv0.)
  local self = root.resolve_self(arg[-1] or "cosmic")
  if not self then return stage.verdict(name, false, "cannot resolve cosmic") end
  -- Same rule, same place: `COSMIC_MAKE` is resolved by find_make,
  -- which runs after `open_project` has chdir'd, so a relative value
  -- resolved against the PROJECT ROOT rather than the directory the
  -- user typed it in. It worked only when the two happened to be the
  -- same, which is why every test passing absolute paths missed it.
  local named = os.getenv(graph.MAKE_ENV)
  if named and named ~= "" then
    cenv.set(graph.MAKE_ENV, fs.abspath(named), true)
  end

  -- Both refusals end in a verdict, like every other outcome. The
  -- verdict line is documented as the record that survives a truncated
  -- log, and "survives truncation" is worth least when the run did
  -- something surprising: a bare exit 1 with the explanation scrolled
  -- away is the case a last line is for.
  local v = by_name(name)
  if not (v is Verb) then
    io.stderr:write("make: unknown verb '" .. name .. "'\n" .. help.usage() .. "\n")
    return stage.verdict(name, false, "unknown verb")
  end
  if v.planned then
    io.stderr:write("make: '" .. name ..
      "' is planned but not implemented yet\nmake: verbs: " ..
      table.concat(help.names(false), ", ") .. "\n")
    return stage.verdict(name, false, "planned, not implemented")
  end

  local proj, err = open_project(name)
  if not proj then
    io.stderr:write((err or "make: failed") .. "\n")
    return stage.verdict(name, false, "no project")
  end
  local p = proj as Project -- cast: record union after the guard

  -- The selection, resolved against the model BEFORE anything is built.
  -- `_make.law` states it for every verb at once; running it here is
  -- what makes a typo cost a walk instead of a rebuild, because
  -- converge is the next line.
  local sok, serr = law.resolve(v, p, paths)
  if not sok then
    io.stderr:write(serr .. "\n")
    return stage.verdict(name, false, "bad selection")
  end

  -- A gate's result is a statement about the toolchain that produced
  -- it, so in a project that BUILDS the toolchain the gate builds it
  -- first and re-execs into what it built. `build` and `clean` are
  -- excluded because they are how you get there; `fetch` because it is
  -- the only verb with a network and nothing about it is a gate.
  if converge.GATES[name] then
    local ok, cerr, why = converge.to_the_tree(p, argv, self)
    if not ok then
      io.stderr:write((cerr or "make: cannot converge") .. "\n")
      -- The DETAIL names which refusal, because the verdict line is the
      -- record that survives a truncated log: "not a fixpoint" means
      -- the build oscillates, and reporting it for an ordinary type
      -- error records a diagnosis nobody made.
      return stage.verdict(name, false, why or "converge failed")
    end
  end

  if v.run then
    return v.run(p, paths, self)
  end
  return stage.run_graph(v, p, paths, self)
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
  IMPLEMENTED = help.names(false),
  PLANNED = help.names(true),
  usage = help.usage,
  run = run,
  scan = project.scan,
  validate = validate.validate,
}

return M
