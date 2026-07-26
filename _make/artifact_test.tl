#!/usr/bin/env cosmic
-- Tests for the artifact: a tree becomes an executable.
--
-- The layout half is asserted against the model directly (it is a pure
-- function of the project). Everything else has to be a real artifact,
-- run: whether the floor is enough to boot on, whether the toolchain is
-- really gone, and whether two builds of one tree agree byte-for-byte
-- are all questions only the produced file can answer.

local check = require("cosmic.check")
local cenv = require("cosmic.env")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local artifact = require("_make.artifact")
local mk = require("_make")
local project = require("_make.project")
local spawn = require("cosmic.child")
local types = require("_make.types")
local zip = require("cosmic.zip")

local type Binary = types.Binary
local type Project = types.Project

local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local make_bin = fs.abspath(os.getenv("COSMIC_MAKE") or "o/cosmo-make")
if not fs.isfile(make_bin) then
  print("skip: no make binary at " .. make_bin)
  os.exit(2)
end

--- Build a fixture tree, returning its absolute root.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "artifact-" .. name)
  fs.rmrf(root)
  assert(fs.makedirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.makedirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  return root
end

--- Scan a fixture into the model.
local function scan(root: string): Project
  local proj = check.must(project.scan(root))
  return proj
end

--- `cosmic --make …` inside dir, with the engine named.
local function make(dir: string, ...: string): integer, string
  local argv: {string} = {cosmic, "--make"}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "COSMIC_MAKE=" .. make_bin,
    "TMPDIR=" .. tmpdir,
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
  }
  local h = check.must(spawn.spawn(argv, {cwd = dir, env = env}))
  local r = check.must(h:wait())
  return r.code or 128, (r.stdout or "") .. (r.stderr or "")
end

--- Run a built artifact and return its exit code and combined output.
---
--- The environment is named, not inherited, and that is load-bearing:
--- this repo's own test lanes export a LUA_PATH pointing at
--- `lib/` and `o/lib/`, which the artifact's package.path then searches
--- BEFORE the zip's own. Inheriting it meant every "does the artifact
--- carry X" assertion here could be answered by the checkout instead of
--- by the binary — `require('cosmic.json')` resolving to
--- `o/cosmic/json.lua` rather than to the floor. An artifact test
--- that reads the tree that built it is not testing the artifact.
local function run_artifact(path: string): integer, string
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
  }
  local h = check.must(spawn.spawn({fs.abspath(path)}, {env = env}))
  local r = check.must(h:wait())
  return r.code or 128, (r.stdout or "") .. (r.stderr or "")
end

--- The binary named `name`.
local function binary_of(proj: Project, name: string): Binary
  for _, b in ipairs(proj.binaries) do
    if b.name == name then
      return b
    end
  end
  error("no binary named " .. name)
end

--- Every stored path in a binary's staging plan.
local function stored_paths(proj: Project, b: Binary): {string: boolean}
  local out: {string: boolean} = {}
  for _, s in ipairs(artifact.plan(proj, b)) do
    out[s.stored] = true
  end
  return out
end

-- The layout rule, whole: a module lands at its import path, an asset
-- at its relative path, the entry at main.lua (which embed then moves
-- behind its wrapper). The zip root IS the module root, so "path
-- relative to the root = import path" holds inside the artifact too.
local function test_layout_is_derived()
  local root = fixture("layout", {
      ["main.tl"] = "print('x')\n",
      ["config.tl"] = "return {}\n",
      ["db/init.tl"] = "return {}\n",
      ["db/query.tl"] = "return {}\n",
      ["_internal/util.tl"] = "return {}\n",
      ["schema.sql"] = "x\n",
      ["assets/logo.txt"] = "x\n",
      ["db/query_test.tl"] = "return {}\n",
      ["db/testdata/fixture.json"] = "{}\n",
      ["types/lpeg.d.tl"] = "local record l end\nreturn l\n",
    })
  local proj = scan(root)
  local stored = stored_paths(proj, binary_of(proj, "artifact-layout"))

  assert(stored["main.lua"], "the entry lands at main.lua")
  assert(stored["config.lua"], "a root module lands at its import path")
  assert(stored["db.lua"], "db/init.tl is the module `db`, so db.lua")
  assert(stored["db/query.lua"], "/ in the import path stays a directory")
  assert(stored["_internal/util.lua"], "internal modules ship; they are private to imports, not to the artifact")
  assert(stored["schema.sql"], "an asset lands at its relative path")
  assert(stored["assets/logo.txt"], "…including a nested one")

  -- What must NOT be there, each for its own reason.
  assert(not stored["db/query_test.lua"], "tests are not shipped")
  assert(not stored["db/testdata/fixture.json"],
    "testdata exists solely to stay out of artifacts")
  assert(not stored["types/lpeg.d.lua"], ".d.tl is type-only")
  assert(not stored["types/lpeg.d.tl"], ".d.tl is type-only")
end
test_layout_is_derived()

-- A cmd/ directory is a unit: its scope is the root packages plus its
-- own subtree, and nothing from a sibling. That is the same boundary
-- the validator refuses imports across, which is why both derive from
-- the same owner rule.
local function test_cmd_scope_is_its_own_subtree()
  local root = fixture("multi", {
      ["shared/http.tl"] = "return {}\n",
      ["_internal/log.tl"] = "return {}\n",
      ["cmd/fetchit/main.tl"] = "print('f')\n",
      ["cmd/servit/main.tl"] = "print('s')\n",
      ["cmd/servit/routes.tl"] = "return {}\n",
    })
  local proj = scan(root)
  local servit = stored_paths(proj, binary_of(proj, "servit"))
  assert(servit["main.lua"], "its own entry is the artifact's main")
  assert(servit["cmd/servit/routes.lua"], "its own package ships")
  assert(servit["shared/http.lua"], "root packages ship into every binary")
  assert(servit["_internal/log.lua"], "…including internal ones")
  assert(not servit["cmd/fetchit/main.lua"],
    "a sibling cmd is not in scope")

  local fetchit = stored_paths(proj, binary_of(proj, "fetchit"))
  assert(fetchit["main.lua"], "each cmd builds its own artifact")
  assert(not fetchit["cmd/servit/routes.lua"], "…from its own subtree only")
end
test_cmd_scope_is_its_own_subtree()

-- A root binary alongside cmd/ binaries ships the root packages and
-- none of the cmd trees.
local function test_root_binary_excludes_cmd()
  local root = fixture("both", {
      ["main.tl"] = "print('root')\n",
      ["lib/x.tl"] = "return {}\n",
      ["cmd/tool/main.tl"] = "print('tool')\n",
    })
  local proj = scan(root)
  local stored = stored_paths(proj, binary_of(proj, "artifact-both"))
  assert(stored["main.lua"] and stored["lib/x.lua"], "root packages ship")
  assert(not stored["cmd/tool/main.lua"], "a cmd tree is not the root binary's")
end
test_root_binary_excludes_cmd()

-- The artifact runs, and the floor is enough to run ON: the standard
-- library survives stripping, which is what makes the floor a floor.
local function test_artifact_runs_on_the_floor()
  local root = fixture("runs", {
      ["main.tl"] = "local json = require('cosmic.json')\n" ..
      "local greet = require('greet')\n" ..
      "print(json.encode({said = greet.hello()}))\n",
      ["greet.tl"] = "local record G\n  hello: function(): string\nend\n" ..
      "local M: G = {hello = function(): string return 'hi' end}\nreturn M\n",
    })
  local code, out = make(root, "build")
  assert(code == 0, "build should succeed: " .. out)
  local bin = fs.join(root, "o/bin/artifact-runs")
  assert(fs.isfile(bin), "expected " .. bin)
  local rc, ran = run_artifact(bin)
  assert(rc == 0, "the artifact should run, got " .. rc .. ": " .. ran)
  assert(ran:find('{"said":"hi"}', 1, true),
    "it should use its own module AND the stdlib, got: " .. ran)
end
test_artifact_runs_on_the_floor()

-- Stripping is not optional, and it is a POSITIVE floor: what a base
-- carried that is not on the list is gone, including entries a future
-- base might add. The toolchain is the point -- an artifact is a
-- program, not a copy of the thing that built it.
local function test_stripped_to_the_floor()
  local root = fixture("stripped", {
      ["main.tl"] = "print('tl:', (pcall(require, 'tl')))\n" ..
      "print('teal:', (pcall(require, 'cosmic.teal')))\n" ..
      "print('json:', (pcall(require, 'cosmic.json')))\n",
    })
  local code, out = make(root, "build")
  assert(code == 0, "build should succeed: " .. out)
  local bin = fs.join(root, "o/bin/artifact-stripped")

  local rc, ran = run_artifact(bin)
  assert(rc == 0, "the artifact should run: " .. ran)
  assert(ran:find("tl:\tfalse", 1, true), "the Teal compiler must be gone: " .. ran)
  assert(ran:find("teal:\tfalse", 1, true), "…and its wrapper: " .. ran)
  assert(ran:find("json:\ttrue", 1, true), "the stdlib must survive: " .. ran)

  -- And it is gone from the archive, not merely unreachable: nothing
  -- outside the floor is extractable either.
  local reader = check.must(zip.reader(bin))
  local bytes: {string: integer} = {}
  for _, e in ipairs(reader:list()) do
    local top = e.name:match("^(%.lua/[^/]+)") or e.name:match("^([^/]+)")
    bytes[top] = (bytes[top] or 0) + e.size
  end
  reader:close()
  assert((bytes["cosmic"] or 0) > 0, "the compiled stdlib is the floor")
  assert((bytes["usr"] or 0) > 0, "TLS roots and zoneinfo are the floor")
  for _, gone in ipairs({".tl", ".docs", "skills", "sys", "tl.lua",
      ".types", ".lua/definitions.lua", "cosmic.mk", "make"}) do
    assert((bytes[gone] or 0) == 0,
      gone .. " must not survive stripping, got " .. tostring(bytes[gone]))
  end
end
test_stripped_to_the_floor()

-- The provider exemption, end to end. A project that defines the whole
-- `cosmic` namespace SUPERSEDES the base's rather than shadowing it:
-- the validator lets the files exist, and the strip drops the base's
-- copy so exactly one standard library ships. Keeping both would leave
-- package.path deciding which one each require() gets, silently,
-- because both load fine.
--
-- The fixture has to supply cosmic.searcher because the embed
-- wrapper itself requires it -- claiming the namespace is all-or-
-- nothing at runtime too, which is the obligation cosmic's own tree
-- meets by being the real thing.
local function test_provided_namespace_supersedes_the_floor()
  local root = fixture("provides", {
      ["main.tl"] = "print('mine:', require('cosmic.mine').tag)\n" ..
      "print('json:', (pcall(require, 'cosmic.json')))\n",
      ["cosmic/init.tl"] = "return {}\n",
      ["cosmic/mine.tl"] = "local record M\n  tag: string\nend\n" ..
      "local m: M = {tag = 'ours'}\nreturn m\n",
      ["cosmic/searcher.tl"] = "local record S\n  install: function()\nend\n" ..
      "local s: S = {install = function() end}\nreturn s\n",
    })
  local code, out = make(root, "build")
  assert(code == 0, "a project may provide cosmic/**: " .. out)
  local bin = fs.join(root, "o/bin/artifact-provides")

  -- Since 3d the two live in ONE namespace -- `cosmic/` in the zip for
  -- the project and for the base alike -- so "did the base's copy go"
  -- cannot be asked by prefix. It is asked by naming a module only the
  -- BASE has: cosmic/json.lua is present in every unstripped artifact
  -- and must be absent here, while the project's own entry stays.
  local reader = check.must(zip.reader(bin))
  local own, base_leftover = false, false
  for _, e in ipairs(reader:list()) do
    if e.name == "cosmic/mine.lua" then
      own = true
    end
    if e.name == "cosmic/json.lua" or e.name == "cosmic/fs/init.lua" then
      base_leftover = true
    end
  end
  reader:close()
  assert(own, "the project's own cosmic/** ships")
  assert(not base_leftover,
    "the base's stdlib must not ride along under the same names")

  local rc, ran = run_artifact(bin)
  assert(rc == 0, "the artifact should run: " .. ran)
  assert(ran:find("mine:\tours", 1, true), "its own module answers: " .. ran)
  assert(ran:find("json:\tfalse", 1, true),
    "…and the superseded base library is really gone: " .. ran)
end
test_provided_namespace_supersedes_the_floor()

-- Two builds of one tree, in different directories, agree byte for
-- byte. Zip entries otherwise carry the staging file's mtime -- build
-- time rather than source state -- so this is the assertion that keeps
-- SOURCE_DATE_EPOCH plumbed.
local function test_reproducible()
  local files: {string: string} = {
    ["main.tl"] = "print('same')\n",
    ["pkg/a.tl"] = "return {}\n",
    ["data.txt"] = "bytes\n",
  }
  local one = fixture("repro-one/app", files)
  local two = fixture("repro-two/app", files)
  assert(make(one, "build") == 0, "first build")
  assert(make(two, "build") == 0, "second build")
  local a = check.must(fs.read(fs.join(one, "o/bin/app")))
  local b = check.must(fs.read(fs.join(two, "o/bin/app")))
  assert(hash.sha256(a) == hash.sha256(b),
    "two builds of one tree must agree byte for byte")
end
test_reproducible()

-- A selected build compiles part of the tree, so it stops at the
-- compile: half a tree cannot make a whole artifact, and quietly
-- producing one from stale objects is the failure this avoids.
local function test_selection_does_not_produce_an_artifact()
  local root = fixture("selected", {
      ["main.tl"] = "print('x')\n",
      ["pkg/a.tl"] = "return {}\n",
    })
  local code, out = make(root, "build", "pkg")
  assert(code == 0, "a selected build should succeed: " .. out)
  assert(not out:find("binary", 1, true),
    "a selected build must not claim an artifact, got: " .. out)
  assert(not fs.exists(fs.join(root, "o/bin/artifact-selected")),
    "…and must not produce one")
end
test_selection_does_not_produce_an_artifact()

-- In process, for coverage and because it is the other calling
-- convention: the same build through the module API.
local function test_in_process_build()
  local root = fixture("inproc", {
      ["main.tl"] = "print('x')\n",
      ["cmd/tool/main.tl"] = "print('tool')\n",
    })
  local cwd = check.must(fs.getcwd())
  cenv.set("COSMIC_MAKE_ROOT", root)
  cenv.set("COSMIC_MAKE", make_bin)
  local code = mk.run({"build"})
  cenv.unset("COSMIC_MAKE_ROOT")
  cenv.unset("COSMIC_MAKE")
  assert(fs.chdir(cwd))
  assert(code == 0, "in-process build should succeed")
  assert(fs.isfile(fs.join(root, "o/bin/artifact-inproc")), "root binary")
  assert(fs.isfile(fs.join(root, "o/bin/tool")), "cmd binary")
end
test_in_process_build()

print("all artifact tests passed")

-- `embed/` is how a project puts a file where the one layout rule
-- cannot: its CONTENTS map to the artifact root, so the checker's
-- declarations, an engine's rules file, or a compiler shipped beside
-- the modules all land where the code that reads them looks.
local function test_payload_maps_to_the_artifact_root()
  local root = fixture("payload", {
      ["main.tl"] = "print('x')\n",
      ["embed/tl.lua"] = "return {}\n",
      ["embed/.types/cosmo.d.tl"] = "local record c end\nreturn c\n",
      ["embed/.tl/cosmic/fs.tl"] = "return {}\n",
      ["embed/cosmic.mk"] = "all:\n",
    })
  local proj = scan(root)
  local stored = stored_paths(proj, binary_of(proj, "artifact-payload"))

  assert(stored["tl.lua"], "payload lands at its path inside embed/, not under embed/")
  assert(not stored["embed/tl.lua"], "and never at its tree path")
  assert(stored[".types/cosmo.d.tl"], "a dot-directory of payload keeps its shape")
  assert(stored[".tl/cosmic/fs.tl"],
    "a .tl under embed/ ships as a file; it is not compiled to .lua")
  assert(not stored["embed/cosmic.lua"], "nor treated as a module")
  assert(stored["cosmic.mk"], "an engine's rules file lands where the engine reads it")
end
test_payload_maps_to_the_artifact_root()

-- Payload is scoped to its unit, which is the same rule the artifact
-- already applies to `cmd/<name>/**`: one binary carries a toolchain
-- and its sibling stays lean, with nothing new enforcing it.
local function test_payload_is_scoped_to_its_binary()
  local root = fixture("payload-scope", {
      ["cmd/tool/main.tl"] = "print('tool')\n",
      ["cmd/tool/embed/tl.lua"] = "return {}\n",
      ["cmd/tool/embed/.types/cosmo.d.tl"] = "local record c end\nreturn c\n",
      ["cmd/lean/main.tl"] = "print('lean')\n",
      ["embed/shared.txt"] = "x\n",
    })
  local proj = scan(root)

  local tool = stored_paths(proj, binary_of(proj, "tool"))
  assert(tool["tl.lua"], "a binary's own payload lands at the artifact root")
  assert(tool[".types/cosmo.d.tl"], "including its dot-directories")
  assert(tool["shared.txt"], "root payload is shared, like a root package")

  local lean = stored_paths(proj, binary_of(proj, "lean"))
  assert(not lean["tl.lua"], "a sibling's payload is invisible")
  assert(not lean[".types/cosmo.d.tl"], "all of it")
  assert(lean["shared.txt"], "but root payload still reaches every binary")
end
test_payload_is_scoped_to_its_binary()
