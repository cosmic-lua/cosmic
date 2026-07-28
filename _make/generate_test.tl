#!/usr/bin/env cosmic
-- Tests for the generated half of a unit's output: the payload
-- generator `build` runs, the runtime it names, and the default argv
-- that makes a bare base bootable.
--
-- These three are one story. A binary's output directory holds
-- `embed/` (what the artifact carries) beside `base` (what it carries
-- it on), and the generator owns both. Without `base` the only runtime
-- available is the cosmic running the build, and stripping that leaves
-- its bytes behind — so cosmic-built-by-cosmic grows every generation
-- instead of converging. Without the derived `.args`, a bare `lua`
-- base yields an artifact that boots as the Lua interpreter.

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

-- The engine, by the same rule the code uses: COSMIC_MAKE names it,
-- else the copy `--make` extracts from its own binary.
local make_bin = fs.abspath(os.getenv("COSMIC_MAKE")
  or "o/make")
if not check.needs("the make engine at " .. make_bin, fs.isfile(make_bin)) then
  os.exit(check.EXIT_SKIP)
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
  -- A directory is not a project until it says so. Fixtures that
  -- declare a root themselves keep theirs; the rest get the marker
  -- that means "yes, this one" so the fixture tests what it is about.
  if not fs.isfile(fs.join(root, "main.tl"))
  and not fs.isfile(fs.join(root, "main.lua"))
  and not fs.isfile(fs.join(root, ".cosmicignore")) then
    assert(fs.write(fs.join(root, ".cosmicignore"), ""))
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

--- Whether `o/3p/**` holds everything the generator reads.
---
--- It used to also COPY, from an `o/staged/**` tree the Makefile
--- pipeline wrote. Nothing writes that tree now, so the copy could
--- only ever be skipped, and what is left is the question it was
--- guarding: has this tree fetched?
--- @param repo string The project root
--- @return boolean True when every pinned input is in place
local function seed_pins(repo: string): boolean
  local want: {{string, string, string}} = {
    {"tl", "tl.lua", "o/3p/tl/tl.lua"},
    {"cosmos", "make", "o/3p/cosmos/make"},
    -- Every base the generator names, not just the default one: seeding
    -- a subset only moves the failure to the next missing line.
    {"cosmos", "lua", "o/3p/cosmos/lua"},
    {"cosmos", "lua-debug", "o/3p/cosmos/lua-debug"},
  }
  for _, w in ipairs(want) do
    if not fs.isfile(fs.join(repo, w[3])) then
      return false
    end
  end
  return true
end

-- A generator whose output a binary embeds is IN that binary's build
-- closure, so `build` runs it -- rather than leaving it to a verb
-- someone can forget, which is the stale-output failure the whole
-- model exists to prevent.
local function test_build_runs_the_units_generator()
  local root = fixture("runs", {
      ["cmd/tool/main.tl"] = "print('tool')\n",
      ["cmd/tool/embed_gen.tl"] = [[
local fs = require("cosmic.fs")
local out = arg[1]
assert(fs.makedirs(fs.join(out, "embed")))
assert(fs.write(fs.join(out, "embed/generated.txt"), "made by the generator\n"))
]],
    })
  local code, out = make(root, "build")
  assert(code == 0, "build should succeed: " .. out)
  assert(out:find("generate cmd/tool/embed_gen.tl", 1, true),
    "build announces the generator it ran: " .. out)

  local produced = fs.join(root,
    "o/cmd/tool/embed_gen/embed/generated.txt")
  assert(fs.isfile(produced),
    "the generator wrote into the directory it owns")

  local proj = scan(root)
  local staged: {string: boolean} = {}
  for _, s in ipairs(artifact.plan(proj, binary_of(proj, "tool"))) do
    staged[s.stored] = true
  end
  assert(staged["generated.txt"],
    "and what it wrote stages at the artifact root")
end
test_build_runs_the_units_generator()

-- A unit that produced `o/<unit>/embed_gen/base` names the runtime
-- its artifact is built on. Everything else falls back to the cosmic
-- running the build, which is right for a project that pins nothing.
local function test_base_is_the_units_own_when_it_declares_one()
  local root = fixture("base", {
      ["cmd/tool/main.tl"] = "print('tool')\n",
      ["cmd/lean/main.tl"] = "print('lean')\n",
    })
  assert(fs.makedirs(fs.join(root, "o/cmd/tool/embed_gen")))
  assert(fs.write(fs.join(root, "o/cmd/tool/embed_gen/base"),
      "not really a runtime\n"))

  local proj = scan(root)
  assert(artifact.base_of(proj, binary_of(proj, "tool"), cosmic) ==
    "o/cmd/tool/embed_gen/base",
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

-- The ROOT generator is every binary's, the way root `embed/` is: its
-- output is staged into all of them. Hung off each binary's own build
-- it ran only while the ROOT binary was being built, so a project with
-- only `cmd/` binaries never ran it at all -- and one with both staged
-- whatever the last run left, depending on which name sorted first.
local function test_the_root_generator_runs_for_cmd_binaries()
  local root = fixture("rootgen", {
      ["embed_gen.tl"] = [[
local fs = require("cosmic.fs")
local out = arg[1]
assert(fs.makedirs(fs.join(out, "embed")))
assert(fs.write(fs.join(out, "embed/shared.txt"), "from the root generator\n"))
]],
      -- Only cmd binaries: no root main.tl at all, which is the shape
      -- that never ran the generator.
      ["cmd/alpha/main.tl"] = "print('alpha')\n",
      ["cmd/zeta/main.tl"] = "print('zeta')\n",
    })
  local code, out = make(root, "build")
  assert(code == 0, "build should succeed: " .. out)
  assert(fs.isfile(fs.join(root, "o/embed_gen/embed/shared.txt")),
    "the root generator ran even with no root binary: " .. out)

  local proj = scan(root)
  for _, name in ipairs({"alpha", "zeta"}) do
    local staged: {string: boolean} = {}
    for _, s in ipairs(artifact.plan(proj, binary_of(proj, name))) do
      staged[s.stored] = true
    end
    assert(staged["shared.txt"],
      name .. " stages the root generator's output")
  end
end
test_the_root_generator_runs_for_cmd_binaries()

-- The same thing through the module API, which is the other calling
-- convention and the only one this process can see: a build spawned as
-- a subprocess exercises the generator hook without the coverage lane
-- ever watching it run.
local function test_in_process_build_runs_the_generator()
  -- The generator imports a project MODULE, so the in-process path
  -- runs the mini-graph too: compile the closure, write the manifest,
  -- hand it over. A generator that imports only `cosmic.*` has an empty
  -- closure and skips all of it, which is what this fixture used to be.
  local root = fixture("inproc", {
      ["note.tl"] = "local record N\n  text: function(): string\nend\n"
      .. 'local n: N = {text = function(): string return "from the generator" end}\n'
      .. "return n\n",
      -- A `.lua` module in the closure too, with the `.d.tl` beside it
      -- that lets a `.tl` import it strictly. The graph COPIES this one
      -- rather than compiling it, so the mini-graph has to as well.
      ["mark.lua"] = 'return {tag = function() return "!" end}\n',
      ["mark.d.tl"] = "local record M\n  tag: function(): string\nend\n"
      .. "return M\n",
      ["cmd/tool/main.tl"] = "print('tool')\n",
      ["cmd/tool/embed_gen.tl"] = [[
local fs = require("cosmic.fs")
local note = require("note")
local mark = require("mark")
local out = arg[1]
assert(fs.makedirs(fs.join(out, "embed")))
assert(fs.write(fs.join(out, "embed/note.txt"), note.text() .. mark.tag() .. "\n"))
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
  local note = fs.join(root, "o/cmd/tool/embed_gen/embed/note.txt")
  assert(fs.isfile(note), "build ran the unit's generator")
  assert(check.must(fs.read(note)):find("from the generator!", 1, true),
    "and the generator resolved BOTH its imports from the tree")
  assert(fs.isfile(fs.join(root, "o/mark.lua")),
    "the mini-graph copies a `.lua` closure member rather than skipping it")
  -- Again, with everything already built: the mini-graph's freshness
  -- check is what keeps a no-op verb from paying one subprocess compile
  -- per closure member, so it needs a run where nothing has moved.
  cenv.set("COSMIC_MAKE_ROOT", root)
  cenv.set("COSMIC_MAKE", make_bin)
  local again = mk.run({"build"})
  cenv.unset("COSMIC_MAKE_ROOT")
  cenv.unset("COSMIC_MAKE")
  assert(fs.chdir(cwd))
  assert(again == 0, "a second in-process build should succeed")
  assert(fs.isfile(fs.join(root, "o/bin/tool")), "and still produced the binary")
  assert(fs.isfile(fs.join(root, "o/bin/lean")),
    "a sibling with no generator builds unchanged")
end
test_in_process_build_runs_the_generator()

-- Two kinds can name one path inside the artifact, and `stage` writes
-- both -- so which bytes shipped came down to `table.sort`'s behaviour
-- on equal keys. Refusing names both origins instead.
local function test_stored_path_collisions_are_refused()
  local root = fixture("collide", {
      ["main.tl"] = "print('x')\n",
      ["pkg/db.tl"] = "return {}\n",
      ["embed/pkg/db.lua"] = "return {}\n",
    })
  local proj = scan(root)
  local out, err = artifact.build(proj,
    binary_of(proj, "generate-collide"), cosmic)
  assert(not out, "a colliding plan must not build")
  assert((err as string):find("pkg/db.lua", 1, true), -- cast: scalar narrowing
    "the message names the stored path, got: " .. tostring(err))
  assert((err as string):find("embed/pkg/db.lua", 1, true), -- cast: scalar narrowing
    "and both origins, got: " .. tostring(err))
end
test_stored_path_collisions_are_refused()

-- The real payload generator, against the real tree. The synthetic
-- fixtures above exercise the MECHANISM; this asserts the contract
-- cosmic's own binary depends on -- which is the hazard that bit twice
-- twice already (a pack that lost tl.lua and the type tree, and one that lost
-- every compiled _cli/** and _make/** module; both times the binary
-- built, booted, and failed only when something first required the
-- missing piece).
local function test_the_real_payload_generator()
  local repo = fs.abspath(".")
  local gen = fs.join(repo, "cmd/cosmic/embed_gen.tl")
  if not check.needs("the cosmic tree (cmd/cosmic/embed_gen.tl)",
    fs.isfile(gen)) then
    os.exit(check.EXIT_SKIP)
  end
  -- The generator reads its pinned inputs from `o/3p/**`, which only
  -- `--make fetch` writes. CI fetches before it gates, so this runs
  -- there; a cold checkout skips rather than failing.
  if not check.needs("fetched pins", seed_pins(repo)) then
    os.exit(check.EXIT_SKIP)
  end
  local out = fs.join(tmpdir, "real-payload")
  fs.rmrf(out)
  assert(fs.makedirs(out))
  local h = check.must(spawn.spawn({cosmic, gen, out},
      {cwd = repo, env = {"PATH=" .. (os.getenv("PATH") or ""), "NO_COLOR=1"}}))
  local r = check.must(h:wait())
  assert(r.code == 0, "the generator should succeed: " ..
    (r.stderr or "") .. (r.stdout or ""))

  -- Every entry of the contract, named. An addition is loud because it
  -- has to be added here too.
  for _, want in ipairs({
      "base",
      "embed/tl.lua",
      "embed/make",
      "embed/.types/cosmo.d.tl",
      "embed/.docs/index.lua",
      "embed/cosmic/_version.lua",
      "embed/.tl/cosmic/fs/init.tl",
      "embed/.tl/_make/artifact.tl",
    }) do
    assert(fs.isfile(fs.join(out, want)), "payload is missing " .. want)
  end
end
test_the_real_payload_generator()

-- A generator's helpers come from the TREE, even when the BINARY ships
-- a module by that name.
--
-- The collision is the whole test. A generator used to resolve its own
-- imports out of the running binary, so a helper the artifact also
-- embedded was a generation behind -- and a fixture module with a name
-- cosmic does not ship can only ever come from the tree, before the fix
-- as much as after. An earlier version of this test used `helper`,
-- which is exactly that shape: it passed against a pre-change binary,
-- so it proved nothing about the thing it was named for.
--
-- `_make/imports` collides with a module the artifact carries. Verified
-- both ways by hand: a pre-change binary answers ZIP here, this one
-- answers TREE.
--
-- `.lua` on both sides, and that is not incidental. The artifact ships
-- `.tl/**` beside its compiled modules, so a `.tl` generator importing
-- a colliding name resolves the TYPE from the binary too and fails to
-- compile before it can run. That is the same shadowing one layer up,
-- and it is why the runtime question needs a file with no types.
local function test_a_generator_reads_its_helpers_from_the_tree()
  local root = fixture("shadow", {
      ["_make/imports.lua"] = 'return {mark = function() return "TREE" end}\n',
      ["thing_gen.lua"] = 'local imports = require("_make.imports")\n'
      .. 'local fs = require("cosmic.fs")\n'
      .. "local ok, mark = pcall(function() return imports.mark() end)\n"
      .. 'fs.write(fs.join(arg[1], "out.txt"), (ok and mark) or "ZIP")\n',
    })
  -- A fixture project does not claim the `cosmic` namespace, so it does
  -- not converge: this is ONE pass, and a second could not hide a stale
  -- first one.
  local h = check.must(spawn.spawn({cosmic, "--make", "build"},
      {cwd = root, env = {"PATH=" .. (os.getenv("PATH") or ""),
          "HOME=" .. root, "TMPDIR=" .. tmpdir, "NO_COLOR=1"}}))
  local r = check.must(h:wait())
  assert(r.code == 0, "the fixture must build: " ..
    (r.stdout or "") .. (r.stderr or ""))
  local got = check.must(fs.read(fs.join(root, "o/thing_gen/out.txt")))
  assert(got == "TREE",
    "a generator's helper must come from the tree, not the binary; got: "
    .. got)
end
test_a_generator_reads_its_helpers_from_the_tree()

-- A `.lua` module in a generator's closure survives a COLD build.
--
-- `.lua` sources are first-class and the graph COPIES them; the
-- mini-graph assumed every closure member compiles from a `.tl`, so it
-- skipped one -- and then named it in the manifest anyway. On a cold
-- tree the generator's require hit the closure layer, found nothing at
-- that path, and failed loudly. A valid project broken on its first
-- build and only its first.
--
-- The generator is `.lua` too, and that is a constraint rather than a
-- preference: a strict compile of a `.tl` importing an untyped `.lua`
-- fails with "no type information for required module", which is the
-- graph's own pre-existing rule and not what this is about.
local function test_a_lua_module_in_a_generators_closure()
  local root = fixture("luaclosure", {
      ["helper.lua"] = 'return {mark = function() return "COPIED" end}\n',
      ["thing_gen.lua"] = 'local helper = require("helper")\n'
      .. 'local fs = require("cosmic.fs")\n'
      .. 'fs.write(fs.join(arg[1], "out.txt"), helper.mark())\n',
    })
  -- COLD: nothing built yet, which is the only state that showed it.
  fs.rmrf(fs.join(root, "o"))
  local h = check.must(spawn.spawn({cosmic, "--make", "build"},
      {cwd = root, env = {"PATH=" .. (os.getenv("PATH") or ""),
          "HOME=" .. root, "TMPDIR=" .. tmpdir, "NO_COLOR=1"}}))
  local r = check.must(h:wait())
  assert(r.code == 0, "a .lua module in the closure must build cold: " ..
    (r.stdout or "") .. (r.stderr or ""))
  local made = check.must(fs.read(fs.join(root, "o/thing_gen/out.txt")))
  assert(made == "COPIED", "and the generator must load it, got: " .. made)
  -- The manifest names it, and the mini-graph produced what it names.
  local mf = check.must(fs.read(fs.join(root, "o/thing_gen.modules")))
  assert(mf:find("mod helper ", 1, true), "the manifest names it: " .. mf)
  assert(fs.isfile(fs.join(root, "o/helper.lua")),
    "and the mini-graph copied it, rather than naming a file it skipped")
end
test_a_lua_module_in_a_generators_closure()

print("all generate tests passed")
