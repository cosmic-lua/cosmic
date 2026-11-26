--- The checks of the tree over its build: every requirement a test module declares promised by a CI leg, zig run
--- only where guarded, sealed programs launched alone, and the projection built afresh.

local type tree_standing = require("build.tree")
local build_paths = require("build.paths")
local Fs = require("cosmic.fs")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local GrammarMode = require("build.grammar_mode")
local host_names = require("build.host_names")
local importer = require("build.importer")
local refusals = require("build.refusals")
local shared_compiles = require("build.shared_compiles")
local work = require("build.work")
local writer = require("build.writer")
local String = require("cosmic.string")
local _ = require("build.reads.all")
local tree_common = require("build.tree_checks.common")
local build_schema = require("build.schema")
local type Build = build_schema.Build

local lookup_in = tree_common.lookup_in

local record tree_build
end

--- The requirements each test module of the tree declares
--- ([`Test.policy`]'s `requires`), by the module's path, as the working
--- database `build` (`build.db`) holds them: the projection has no
--- declarations.
--- @param build the working database
--- @return the names a module declares, for each that declares any
function tree_build.requirements(build: Sqlite.Handle): {string:{string}}?, string
  local rows, trouble = build:rows(
    "SELECT i.path, t.value FROM test_inputs t JOIN inputs i ON i.source_hash = t.source_hash " ..
      "WHERE t.field = 'requires' ORDER BY i.path, t.ordinal")
  if rows == nil then return nil, "reading the declared requirements: " .. tostring(trouble) end
  local out: mut {string:mut {string}} = {}
  for _, row in ipairs(rows) do
    local names = out[row:text(1)] or {}
    out[row:text(1)] = names
    local second = row:text(2)
    names[#names + 1] = second
  end
  return out, ""
end

--- The test modules granted the zig cache (`caches = { "zig" }`) that do not require `pinned_zig`, one finding each,
--- as the working database `build` holds their declarations. The cache is granted to start the pinned zig, as a
--- check of the core's C does: where zig is not installed (a seeded boot) such a module fails each test on a start
--- of bin/zig its worker cannot make, where the requirement skips it, naming the fix.
--- @param build the working database
--- @return the findings, or nil and why the declarations cannot be read
function tree_build.unguarded_zig(build: Sqlite.Handle): {string}?, string
  local rows, trouble = build:rows(
    "SELECT DISTINCT i.path FROM test_inputs t JOIN inputs i ON i.source_hash = t.source_hash " ..
      "WHERE t.field = 'caches' AND t.value = 'zig' AND NOT EXISTS (SELECT 1 FROM test_inputs r " ..
      "WHERE r.source_hash = t.source_hash AND r.field = 'requires' AND r.value = 'pinned_zig') ORDER BY i.path")
  if rows == nil then return nil, "reading the declared caches: " .. tostring(trouble) end
  local out: mut {string} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = row:text(1) .. " is granted the zig cache and does not require pinned_zig: add " ..
      "requires = { \"pinned_zig\" } to its Test.policy, so it skips where zig is not installed"
  end
  return out, ""
end

--- The test modules that run a program the portable launcher starts, or
--- open the store, or require a portable host, by the module's path:
--- the ones whose key holds the launcher, as the working database `build`
--- (`build.db`) holds their declarations. Every other worker runs
--- sealed ([`build.test_key`]'s `seals`).
--- @param build the working database
--- @return the module paths, as a set
function tree_build.unsealed(build: Sqlite.Handle): {string:boolean}?, string
  local rows, trouble = build:rows(
    "SELECT DISTINCT i.path FROM test_inputs t JOIN inputs i ON i.source_hash = t.source_hash " ..
      "WHERE t.field IN ('tool', 'store') OR (t.field = 'requires' AND t.value = 'portable')")
  if rows == nil then return nil, "reading the unsealed modules: " .. tostring(trouble) end
  local out: mut {string:boolean} = {}
  for _, row in ipairs(rows) do out[row:text(1)] = true end
  return out, ""
end

--- The sealed test modules that name the portable launcher's contract
--- -- `COSMIC_PORTABLE_*` or the `--artifact` argument -- though their
--- worker never sees it, each with the reason it is no reader of it.
--- Every other one is a finding of [`sealed_launch`].
local launcher_allowed: mut {string: string} = {}
launcher_allowed["build.caches_test"] = "names COSMIC_PORTABLE_CACHE as a key of the " ..
  "environment it hands a pure function of the cache variables"
launcher_allowed["build.c.rules_test"] = "names COSMIC_PORTABLE_CACHE in the environment it hands " ..
  "c.own_caches, a pure function, and reads none from its own process"
launcher_allowed["build.declared_key_test"] = "names COSMIC_PORTABLE_CACHE as a variable of the " ..
  "environment a spec it keys holds, and reads none from its own process"
launcher_allowed["build.launcher_test"] = "renders the launcher's text with build.launcher and runs " ..
  "it in a child of its own, with COSMIC_PORTABLE_TEST_KERNEL named in the " ..
  "child's environment"
launcher_allowed["build.test_sandbox_test"] = "names COSMIC_PORTABLE_CACHE in the environments " ..
  "it hands the sandbox's pure functions, and reads none from its own process"
launcher_allowed["build.test_worker_test"] = "hands the worker's pure start function a made-up " ..
  "launcher start (\"--artifact\", COSMIC_PORTABLE_*_FD) and reads none from its own process"
launcher_allowed["cosmic.test_cosmic_test"] = "replaces Proc.relaunch with a made-up launcher " ..
  "start and holds Test.cosmic's reading of it, not this process's"
launcher_allowed["build.tree_checks.tree_checks_test"] = "plants the names in the fixture sources of the check's " ..
  "own test"
launcher_allowed["build.workflows_test"] = "reads COSMIC_PORTABLE_CACHE in the text of a workflow " ..
  "step, not from its own process"

--- Each module of `db` that is a test of the tree, runs sealed (`unsealed`
--- does not hold it) and names the portable launcher's contract in code
--- -- `COSMIC_PORTABLE_*`, or the `"--artifact"` argument -- and no
--- reason in `excused` (by default the tree's own), then each module
--- `excused` names that does not.
---
--- ci/cosmic_ci/orchestration.tl's `suite_verdicts` lets the portable
--- suite stand on the native suite's verdicts, which is sound while the
--- key of a worker that can see the artifact holds the launcher
--- ([`build.declared_key`]'s `launcher_identity`) and one that cannot
--- (a sealed worker) holds the core in its place. A test that reads
--- the launcher's contract must therefore be keyed by the launcher: it
--- declares `tool` or `store`, or `requires = { "portable" }`, else it
--- would pass under the native build and stand in the portable suite
--- without the artifact it is about (or, run only on the portable
--- build, skip in both). A call to Proc.relaunch is no finding: a
--- sealed worker's description is the sealed start's, the same
--- under either artifact.
--- @param db the tree's projection
--- @param unsealed the modules whose workers run unsealed ([`unsealed`])
--- @param excused the modules that may, with the reason of each
function tree_build.sealed_launch(db: Build, unsealed: {string:boolean},
                                  excused?: {string: string}): {string}
  local rows, trouble = db:rows(
    "SELECT path, CAST(inflate(source) AS TEXT) FROM modules WHERE path GLOB '*_test' ORDER BY path")
  if rows == nil then return { "reading the modules' sources: " .. tostring(trouble) } end
  local allowed_here = excused or launcher_allowed
  local out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  for _, row in ipairs(rows) do
    local named = false
    for line in String.lines(row:text(2)) do
      if line:find("^%s*%-%-") == nil and
          (line:find("COSMIC_PORTABLE_", 1, true) ~= nil or line:find('"--artifact', 1, true) ~= nil) then
        named = true
        break
      end
    end
    if named and unsealed[row:text(1)] ~= true then
      seen[row:text(1)] = true
      if allowed_here[row:text(1)] == nil then
        out[#out + 1] = row:text(1) .. " names the portable launcher's contract, but its worker runs " ..
          "sealed and never sees the launcher: declare `tool` or `store`, or " ..
          "`requires = { \"portable\" }`, or excuse it in build/tree_checks/build.tl's `launcher_allowed`"
      end
    end
  end
  local stale: mut {string} = {}
  for name in pairs(allowed_here) do
    if seen[name] ~= true then
      stale[#stale + 1] = name .. " is excused in build/tree_checks/build.tl's `launcher_allowed`, but " ..
        "no longer names the portable launcher's contract in a sealed test -- remove it"
    end
  end
  table.sort(stale)
  for _, line in ipairs(stale) do out[#out + 1] = line end
  return out
end

--- What ci/cosmic_ci/capabilities.json holds.
local record Capabilities
  legs: {string:{string}}
end

local CAPABILITIES <const>: Shape.Typed<Capabilities> = Shape.record_of("Capabilities")

--- The requirements each CI leg promises, as ci/cosmic_ci/capabilities.json
--- under `root` lists them. ci is a tree of its own, whose modules the
--- tree cannot require: the file is JSON, read alone.
--- @param root the tree's root
--- @return the names a leg promises, by the leg's name
function tree_build.legs(root: string): {string:{string}}?, string
  local path = root .. "/ci/cosmic_ci/capabilities.json"
  local text, read_trouble = Fs.read(path)
  if text == nil then return nil, tostring(read_trouble) end
  local capabilities, shape_trouble = Shape.decode_into(text, CAPABILITIES.spec)
  if capabilities == nil then return nil, path .. ": " .. shape_trouble end
  return capabilities.legs, ""
end

-- TODO: hold the requirements ci/'s own tests and fixtures declare to the
-- same check: it reads the root tree's declarations alone, and ci/ is a
-- tree of its own whose `fix --check` cannot read the leg list's tree.
--- What the CI legs' promises ([`legs`]) and the tree's declared
--- requirements ([`requirements`]) say against each other, one line a
--- finding: a name a leg promises that the table of
--- [`build.host_names`] refuses, and a module requiring a name no leg
--- promises, which would be n/a or skipped on every leg and run nowhere
--- in CI, with no held run to fail for it. An `os:` name is no finding.
--- @param declared the requirements each test module declares
--- @param legs the names each CI leg promises
--- @return the findings, none when every declared name is promised
function tree_build.promises(declared: {string:{string}}, legs: {string:{string}}): {string}
  local out: mut {string} = {}
  local leg_names: mut {string} = {}
  for leg in pairs(legs) do leg_names[#leg_names + 1] = leg end
  table.sort(leg_names)
  local all: mut {string} = {}
  for _, leg in ipairs(leg_names) do
    for _, name in ipairs(lookup_in(legs, leg)) do
      local spec, why = host_names.parse(name)
      if spec == nil then
        out[#out + 1] = string.format("leg %s promises %q, which is refused: %s", leg, name, why)
      else
        all[#all + 1] = name
      end
    end
  end
  local modules: mut {string} = {}
  for module in pairs(declared) do modules[#modules + 1] = module end
  table.sort(modules)
  for _, module in ipairs(modules) do
    for _, name in ipairs(lookup_in(declared, module)) do
      -- Every system `os:` takes has a leg, where it is present. No leg
      -- promises one: the release cosmic some legs run refuses a name it
      -- does not know in COSMIC_TEST_PROMISES.
      local spec, _ = host_names.parse(name)
      local os_name = spec ~= nil and spec.base == "os"
      if not os_name and not host_names.promised(all, name) then
        out[#out + 1] = string.format("%s requires %s, which no CI leg promises " ..
            "(ci/cosmic_ci/capabilities.json): it would be n/a or skipped on every leg and run " ..
            "nowhere, with no held run to fail for it", module, name)
      end
    end
  end
  return out
end

--- Whether `path`, relative to the tree's root, is a source of the
--- public standard library: `cosmic/` outside `cosmic/internal/`. A
--- note [`build.fix.near`] makes on one fails the whole tree's check: the
--- standard library as it stands earns no note against itself, so a
--- note on a file is about what that file adds.
function tree_build.standard(path: string): boolean
  while path:sub(1, 2) == "./" do path = path:sub(3) end
  return path:sub(1, 7) == "cosmic/" and path:sub(1, 16) ~= "cosmic/internal/"
end

--- Builds the tree at `root`, cosmic's own, into its projection,
--- `cosmic.db`, as `cosmic test` does before any test reads it, and
--- opens it. `cosmic fix` rebuilds the tool it runs as when that is
--- stale, but not the projection, which holds what the tool does not
--- carry (its tests and examples among it). A module the build refuses
--- is a failure: the checks would read a projection without it.
---
--- The tree is compiled with the new checker, as `cosmic test` compiles it.
function tree_build.projection(root: string, standing: tree_standing.Standing): Build?, string
  local handle, open_trouble = work.open(root, nil, "fix")
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, standing)
  if staged == nil then
    local _, _ = work.close(handle)
    return nil, stage_trouble
  end
  local result, compile_trouble = importer.compile(handle,
    GrammarMode.tool(Store.meta("compiler") or ""), false, shared_compiles.for_build())
  if result == nil then
    local _, _ = work.close(handle)
    return nil, compile_trouble
  end
  local refused = result.refused
  if #refused > 0 then
    local _, _ = work.close(handle)
    return nil, "the tree does not build:\n" .. refusals.text(refused, result.refusal_roots or {})
  end
  local path = build_paths.resolve(root).projection
  local written, write_trouble = writer.write_result(handle, path, result)
  local closed, close_trouble = work.close(handle)
  if not written then
    return nil, write_trouble
  end
  if not closed then
    return nil, close_trouble
  end
  local answered, answer_why = Sqlite.open(path, { schema = build_schema.Build })
  if not answered then return nil, tostring(answer_why) end
  return answered, ""
end

return tree_build
