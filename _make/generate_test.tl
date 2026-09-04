#!/usr/bin/env cosmic
-- Tests for the generated half of a unit's output: the payload
-- generator `build` runs, the runtime it names, and the default argv
-- that makes a bare base bootable, plus the source generators (the
-- `sources` phase) that run before the graph does.
--
-- A binary's output directory holds `embed/` (what the artifact
-- carries) beside `base` (what it carries it on); without `base` the
-- only runtime available is the cosmic running the build, and stripping
-- that leaves its bytes behind — so cosmic-built-by-cosmic grows every
-- generation instead of converging. Without the derived `.args`, a bare
-- `lua` base yields an artifact that boots as the Lua interpreter.

local artifact = require("_make.artifact")
local cenv = require("cosmic.env")
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local generate = require("_make.generate")
local mk = require("_make")
local project = require("_make.project")
local seed = require("_make.seed")
local child = require("cosmic.child")
local types = require("_make.types")

local type Binary = types.Binary
local type Project = types.Project

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

-- The engine, by the same rule the code uses: COSMIC_MAKE names it,
-- else the copy `--make` extracts from its own binary.
local make_bin = fs.absolute_path(os.getenv("COSMIC_MAKE")
  or "o/make")
check.needs("the make engine at " .. make_bin, fs.is_file(make_bin))

--- Build a fixture tree, returning its absolute root.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "generate-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.make_dirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  -- A directory is not a project until it says so. Fixtures that
  -- declare a root themselves keep theirs; the rest get the marker
  -- that means "yes, this one" so the fixture tests what it is about.
  if not fs.is_file(fs.join(root, "main.tl"))
  and not fs.is_file(fs.join(root, "main.lua"))
  and not fs.is_file(fs.join(root, ".cosmicignore")) then
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
  local h = check.must(child.start(argv, {cwd = dir, env = env}))
  local r = check.must(h:wait())
  return r.code or 128, (r.stdout or "") .. (r.stderr or "")
end

--- `cosmic --make build`, in process, against a scratch project root.
local function build_in(root: string): integer
  local cwd = check.must(fs.cwd())
  assert(cenv.set("COSMIC_MAKE_ROOT", root))
  assert(cenv.set("COSMIC_MAKE", make_bin))
  local code = mk.run({"build"})
  assert(cenv.unset("COSMIC_MAKE_ROOT"))
  assert(cenv.unset("COSMIC_MAKE"))
  assert(fs.set_cwd(cwd))
  return code
end

--- Whether `o/3p/**` holds everything the generator reads — the
--- question is exactly "has this tree fetched?". A copy step from some
--- other staging tree does not belong here: a source nothing writes
--- can only ever be skipped, and a helper that copies sometimes is a
--- helper whose answer depends on which tree it ran in.
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
    if not fs.is_file(fs.join(repo, w[3])) then
      return false
    end
  end
  return true
end

-- A generator whose output a binary embeds is IN that binary's build
-- closure, so `build` runs it rather than leaving it to a verb someone
-- can forget.
local function test_build_runs_the_units_generator()
  local root = fixture("runs", {
      ["cmd/tool/main.tl"] = "print('tool')\n",
      ["cmd/tool/embed_gen.tl"] = [[
local fs = require("cosmic.fs")
local out = arg[1]
assert(fs.make_dirs(fs.join(out, "embed")))
assert(fs.write(fs.join(out, "embed/generated.txt"), "made by the generator\n"))
]],
    })
  local code, out = make(root, "build")
  assert(code == 0, "build should succeed: " .. out)
  assert(out:find("generate cmd/tool/embed_gen.tl", 1, true),
    "build announces the generator it ran: " .. out)

  local produced = fs.join(root,
    "o/cmd/tool/embed_gen/embed/generated.txt")
  assert(fs.is_file(produced),
    "the generator wrote into the directory it owns")

  local proj = scan(root)
  local staged: {string: boolean} = {}
  for _, s in ipairs(artifact.plan(proj, binary_of(proj, "tool"))) do
    staged[s.stored] = true
  end
  assert(staged["generated.txt"],
    "and what it wrote stages at the artifact root")
end

-- A unit that produced `o/<unit>/embed_gen/base` names the runtime its
-- artifact is built on; everything else falls back to the running cosmic.
local function test_base_is_the_units_own_when_it_declares_one()
  local root = fixture("base", {
      ["cmd/tool/main.tl"] = "print('tool')\n",
      ["cmd/lean/main.tl"] = "print('lean')\n",
    })
  assert(fs.make_dirs(fs.join(root, "o/cmd/tool/embed_gen")))
  assert(fs.write(fs.join(root, "o/cmd/tool/embed_gen/base"),
      "not really a runtime\n"))

  local proj = scan(root)
  -- The plain base is always the first pair `bases_of` returns (see
  -- its own doc comment), so that is the single source for "the" base
  -- a unit builds on -- there is no separate `base_of` to drift from it.
  assert(artifact.bases_of(proj, binary_of(proj, "tool"), cosmic)[1][2] ==
    "o/cmd/tool/embed_gen/base",
    "a declared base wins, so the artifact does not depend on its builder")
  assert(artifact.bases_of(proj, binary_of(proj, "lean"), cosmic)[1][2] == cosmic,
    "and a unit that declares none is built on the running cosmic")
end

-- `.args` is derived, not declared: the entry is always /zip/main.lua
-- in this layout, so a project that puts its own in the payload wins.
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

-- The ROOT generator is every binary's, the way root `embed/` is: hung
-- off each binary's own build instead, a project with only `cmd/`
-- binaries would never run it at all.
local function test_the_root_generator_runs_for_cmd_binaries()
  local root = fixture("rootgen", {
      ["embed_gen.tl"] = [[
local fs = require("cosmic.fs")
local out = arg[1]
assert(fs.make_dirs(fs.join(out, "embed")))
assert(fs.write(fs.join(out, "embed/shared.txt"), "from the root generator\n"))
]],
      -- Only cmd binaries: no root main.tl at all, which is the shape
      -- that never ran the generator.
      ["cmd/alpha/main.tl"] = "print('alpha')\n",
      ["cmd/zeta/main.tl"] = "print('zeta')\n",
    })
  local code, out = make(root, "build")
  assert(code == 0, "build should succeed: " .. out)
  assert(fs.is_file(fs.join(root, "o/embed_gen/embed/shared.txt")),
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

-- `generate_unit` asks the MODEL, not the disk: an ignored generator
-- is invisible to `proj.files` and must not run.
local function test_a_cosmicignored_generator_does_not_run()
  local root = fixture("ignored", {
      [".cosmicignore"] = "cmd/tool/embed_gen.tl\n",
      ["cmd/tool/main.tl"] = "print('tool')\n",
      ["cmd/tool/embed_gen.tl"] = [[
local fs = require("cosmic.fs")
local out = arg[1]
assert(fs.make_dirs(fs.join(out, "embed")))
assert(fs.write(fs.join(out, "embed/generated.txt"), "made by the generator\n"))
]],
    })
  local code, out = make(root, "build")
  assert(code == 0 and not out:find("generate cmd/tool/embed_gen.tl", 1, true),
    "an ignored generator must not be announced as run: " .. out)
  assert(not fs.is_present(fs.join(root, "o/cmd/tool/embed_gen")),
    "and its output directory must not exist")
end

-- The same thing through the module API, the other calling convention
-- and the only one this process's coverage lane can see run.
local function test_in_process_build_runs_the_generator()
  -- The generator imports a project MODULE, so this also runs the
  -- mini-graph (compile the closure, write the manifest, hand it
  -- over) -- a `cosmic.*`-only generator has an empty closure and
  -- would leave this test green while the mini-graph never ran.
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
assert(fs.make_dirs(fs.join(out, "embed")))
assert(fs.write(fs.join(out, "embed/note.txt"), note.text() .. mark.tag() .. "\n"))
]],
      ["cmd/lean/main.tl"] = "print('lean')\n",
    })
  local code = build_in(root)
  assert(code == 0, "in-process build should succeed")
  local note = fs.join(root, "o/cmd/tool/embed_gen/embed/note.txt")
  assert(fs.is_file(note), "build ran the unit's generator")
  assert(check.must(fs.read(note)):find("from the generator!", 1, true),
    "and the generator resolved BOTH its imports from the tree")
  assert(fs.is_file(fs.join(root, "o/mark.lua")),
    "the mini-graph copies a `.lua` closure member rather than skipping it")
  -- Again, with everything already built: the mini-graph's freshness
  -- check is what keeps a no-op verb from paying one subprocess compile
  -- per closure member, so it needs a run where nothing has moved.
  local again = build_in(root)
  assert(again == 0, "a second in-process build should succeed")
  assert(fs.is_file(fs.join(root, "o/bin/tool")), "and still produced the binary")
  assert(fs.is_file(fs.join(root, "o/bin/lean")),
    "a sibling with no generator builds unchanged")
end

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
  assert(err:find("pkg/db.lua", 1, true),
    "the message names the stored path, got: " .. tostring(err))
  assert(err:find("embed/pkg/db.lua", 1, true),
    "and both origins, got: " .. tostring(err))
end

-- The real payload generator, against the real tree. The synthetic
-- fixtures above exercise the MECHANISM; this asserts the contract
-- cosmic's own binary depends on -- lose `tl.lua`, the type tree, or a
-- compiled `_cli/**`/`_make/**` module and the binary still builds and
-- boots, failing only when something first requires the missing piece.
local function test_the_real_payload_generator()
  local repo = fs.absolute_path(".")
  local gen = fs.join(repo, "cmd/cosmic/embed_gen.tl")
  check.needs("the cosmic tree (cmd/cosmic/embed_gen.tl)",
    fs.is_file(gen))
  -- The generator reads its pinned inputs from `o/3p/**`, which only
  -- `--make fetch` writes. CI fetches before it gates, so this runs
  -- there; a cold checkout skips rather than failing.
  check.needs("fetched pins", seed_pins(repo))
  local out = fs.join(tmpdir, "real-payload")
  assert(fs.remove_all(out))
  assert(fs.make_dirs(out))
  local h = check.must(child.start({cosmic, gen, out},
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
    assert(fs.is_file(fs.join(out, want)), "payload is missing " .. want)
  end
end

-- A generator failing after the seed ran must not leave `SEED_DIR` for
-- the next invocation to trust, and must not swallow why it failed.
-- `_types/types_gen.tl` is the fixture's only generator, so it is both
-- what `should_seed` seeds (destination `SEED_DIR`) and what the real
-- run later builds (destination `TYPES_GEN_DIR`) -- branching on which
-- lets one stub succeed as the seed and fail as the generator proper.
local function test_a_failing_generator_after_seed_still_cleans_up()
  local root = fixture("seedcleanup", {
      ["_types/types_gen.tl"] = [[
local fs = require("cosmic.fs")
local out = arg[1]
if out:find("types_seed", 1, true) then
  assert(fs.make_dirs(out))
  assert(fs.write(fs.join(out, "stub.txt"), "seeded\n"))
else
  os.exit(1)
end
]],
    })
  local proj = scan(root)
  local cwd = check.must(fs.cwd())
  assert(fs.set_cwd(proj.root))
  local ok, err = generate.sources(proj, cosmic)
  assert(fs.set_cwd(cwd))
  assert(not ok, "a failing generator must fail sources()")
  assert(err ~= nil and err:find("_types/types_gen.tl", 1, true),
    "the failure message survives: " .. tostring(err))
  assert(not fs.is_present(fs.join(root, seed.SEED_DIR)),
    "SEED_DIR must not survive a generator failure after the seed ran")
end

-- A project with no `_types/types_gen.tl`, `hello` included, never seeds.
local function test_the_hello_fixture_creates_no_seed_dir()
  local root = fs.join(tmpdir, "generate-hello")
  assert(fs.remove_all(root))
  assert(fs.make_dirs(fs.dirname(root)))
  assert(fs.copy_tree(fs.join("_make/testdata", "hello"), root))
  local code = build_in(root)
  assert(code == 0, "the hello fixture should still build")
  assert(not fs.is_present(fs.join(root, seed.SEED_DIR)),
    "a project with no _types/types_gen.tl must never create the seed dir")
end

print("all generate tests passed")
