#!/usr/bin/env cosmic
-- Tests for the generated half of a unit's output: the payload
-- generator `build` runs, the runtime it names, and the default argv
-- that makes a bare base bootable.
--
-- These three are one story. A binary's output directory holds
-- `embed/` (what the artifact carries) beside `base` (what it carries
-- it on), and the generator owns both. Without `base` the only runtime
-- available is the cosmic running the build, and stripping it leaves
-- its bytes behind — so cosmic-built-by-cosmic grew every generation
-- instead of converging. Without the derived `.args`, swapping to a
-- bare `lua` base produced an artifact that booted as the Lua
-- interpreter.

local artifact = require("_make.artifact")
local cenv = require("cosmic.env")
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local mk = require("_make")
local project = require("_make.project")
local spawn = require("cosmic.child")
local types = require("_make.types")

local type Binary = types.Binary
local type Project = types.Project

local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local make_bin = fs.abspath(os.getenv("COSMIC_MAKE") or "o/cosmo-make")
if not fs.isfile(make_bin) then
  print("skip: no make binary at " .. make_bin)
  return
end

--- Build a fixture tree, returning its absolute root.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "generate-" .. name)
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

--- The binary named `name`.
local function binary_of(proj: Project, name: string): Binary
  for _, b in ipairs(proj.binaries) do
    if b.name == name then
      return b
    end
  end
  error("no binary named " .. name)
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

-- A generator whose output a binary embeds is IN that binary's build
-- closure, so `build` runs it -- rather than leaving it to a verb
-- someone can forget, which is the stale-output failure the whole
-- model exists to prevent.
local function test_build_runs_the_units_generator()
  local root = fixture("runs", {
      ["cmd/tool/main.tl"] = "print('tool')\n",
      ["cmd/tool/embed.gen.tl"] = [[
local fs = require("cosmic.fs")
local out = arg[1]
assert(fs.makedirs(fs.join(out, "embed")))
assert(fs.write(fs.join(out, "embed/generated.txt"), "made by the generator\n"))
]],
    })
  local code, out = make(root, "build")
  assert(code == 0, "build should succeed: " .. out)
  assert(out:find("generate cmd/tool/embed.gen.tl", 1, true),
    "build announces the generator it ran: " .. out)

  local produced = fs.join(root, "o/cmd/tool/embed/generated.txt")
  assert(fs.isfile(produced), "the generator wrote into its unit's output dir")

  local proj = scan(root)
  local staged: {string: boolean} = {}
  for _, s in ipairs(artifact.plan(proj, binary_of(proj, "tool"))) do
    staged[s.stored] = true
  end
  assert(staged["generated.txt"],
    "and what it wrote stages at the artifact root")
end
test_build_runs_the_units_generator()

-- A unit that produced `o/<unit>/base` names the runtime its artifact
-- is built on. Everything else falls back to the cosmic running the
-- build, which is the right answer for a project that pins nothing.
local function test_base_is_the_units_own_when_it_declares_one()
  local root = fixture("base", {
      ["cmd/tool/main.tl"] = "print('tool')\n",
      ["cmd/lean/main.tl"] = "print('lean')\n",
    })
  assert(fs.makedirs(fs.join(root, "o/cmd/tool")))
  assert(fs.write(fs.join(root, "o/cmd/tool/base"), "not really a runtime\n"))

  local proj = scan(root)
  assert(artifact.base_of(proj, binary_of(proj, "tool"), cosmic) ==
    "o/cmd/tool/base",
    "a declared base wins, so the artifact does not depend on its builder")
  assert(artifact.base_of(proj, binary_of(proj, "lean"), cosmic) == cosmic,
    "and a unit that declares none is built on the running cosmic")
end
test_base_is_the_units_own_when_it_declares_one()

-- `.args` is derived, not declared: the entry is always /zip/main.lua
-- in this layout, so what the APE's default argv names is a fact about
-- the layout. A project that puts its own in the payload outranks it.
local function test_default_argv_is_derived()
  local root = fixture("args", {["main.tl"] = "print('x')\n"})
  local proj = scan(root)
  local b = binary_of(proj, "generate-args")
  for _, s in ipairs(artifact.plan(proj, b)) do
    if s.stored == ".args" then
      assert(s.content == "/zip/main.lua\n...\n",
        "the default argv runs the entry and passes the rest through")
      assert(s.source == "", "and is content, not a file to copy")
    end
  end

  local override = fixture("args-override", {
      ["main.tl"] = "print('x')\n",
      ["embed/.args"] = "/zip/other.lua\n",
    })
  local oproj = scan(override)
  local seen = 0
  for _, s in ipairs(artifact.plan(oproj, binary_of(oproj, "generate-args-override"))) do
    if s.stored == ".args" then
      seen = seen + 1
      assert(s.content == nil, "a payload .args is the project's file, not the default")
    end
  end
  assert(seen == 1, "and there is exactly one, never both")
end
test_default_argv_is_derived()

-- The same thing through the module API, which is the other calling
-- convention and the only one this process can see: a build spawned as
-- a subprocess exercises the generator hook without the coverage lane
-- ever watching it run.
local function test_in_process_build_runs_the_generator()
  local root = fixture("inproc", {
      ["cmd/tool/main.tl"] = "print('tool')\n",
      ["cmd/tool/embed.gen.tl"] = [[
local fs = require("cosmic.fs")
local out = arg[1]
assert(fs.makedirs(fs.join(out, "embed")))
assert(fs.write(fs.join(out, "embed/note.txt"), "from the generator\n"))
]],
      ["cmd/lean/main.tl"] = "print('lean')\n",
    })
  local cwd = check.must(fs.getcwd())
  cenv.set("COSMIC_MAKE_ROOT", root)
  cenv.set("COSMIC_MAKE", make_bin)
  local code = mk.run({"build"})
  cenv.unset("COSMIC_MAKE_ROOT")
  cenv.unset("COSMIC_MAKE")
  assert(fs.chdir(cwd))
  assert(code == 0, "in-process build should succeed")
  assert(fs.isfile(fs.join(root, "o/cmd/tool/embed/note.txt")),
    "build ran the unit's generator")
  assert(fs.isfile(fs.join(root, "o/bin/tool")), "and still produced the binary")
  assert(fs.isfile(fs.join(root, "o/bin/lean")),
    "a sibling with no generator builds unchanged")
end
test_in_process_build_runs_the_generator()

print("all generate tests passed")
