#!/usr/bin/env cosmic
-- Tests for the mini-graph: the closure compile a generator gets before
-- it runs, and the argv it is handed as a result -- resolving a
-- generator's helpers from the TREE rather than the running binary,
-- copying (not skipping) a `.lua` closure member, and preferring the
-- seed dir over `/zip/.types` on the include path.

local build = require("_cli.build")
local cenv = require("cosmic.env")
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local mk = require("_make")
local seed = require("_make.seed")
local child = require("cosmic.child")

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

-- A generator's helpers come from the TREE, even when the BINARY ships
-- a module by that name. `_make/imports` collides with a module the
-- artifact carries on purpose: a fixture module cosmic does not ship
-- (`helper`) could pass against either resolution and prove nothing;
-- `.lua` on both sides so a `.tl` generator importing the colliding
-- name cannot resolve the TYPE from the binary and fail to compile
-- before it runs, which is the same shadowing one layer up.
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
  local h = check.must(child.start({cosmic, "--make", "build"},
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

-- A `.lua` module in a generator's closure survives a COLD build.
-- `.lua` sources are first-class and the graph COPIES them; assuming
-- every closure member compiles from a `.tl` would skip this one and
-- still name it in the manifest, so a cold `require` hits the closure
-- layer, finds nothing, and fails loudly on the first build only. The
-- generator is `.lua` too: a `.tl` one importing an untyped `.lua`
-- fails to strict-compile, which is a different, pre-existing rule.
local function test_a_lua_module_in_a_generators_closure()
  local root = fixture("luaclosure", {
      ["helper.lua"] = 'return {mark = function() return "COPIED" end}\n',
      ["thing_gen.lua"] = 'local helper = require("helper")\n'
      .. 'local fs = require("cosmic.fs")\n'
      .. 'fs.write(fs.join(arg[1], "out.txt"), helper.mark())\n',
    })
  -- COLD: nothing built yet, which is the only state that showed it.
  assert(fs.remove_all(fs.join(root, "o")))
  local h = check.must(child.start({cosmic, "--make", "build"},
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
  assert(fs.is_file(fs.join(root, "o/helper.lua")),
    "and the mini-graph copied it, rather than naming a file it skipped")
end

-- The seed dir wins over `/zip/.types` on ANY generator's closure, not
-- only `_types/types_gen.tl`'s own.
local function test_closure_compile_includes_the_seed_dir_when_present()
  local root = fixture("seedinclude", {
      ["helper.tl"] = "return {}\n",
      ["thing_gen.lua"] = 'require("helper")\n',
    })
  assert(fs.make_dirs(fs.join(root, seed.SEED_DIR)))
  local captured: {{string}} = {}
  local original = build.dispatch
  build.dispatch = function(verb: string, args: {string}): integer
    if verb == "compile" then captured[#captured + 1] = args end
    return original(verb, args)
  end
  local code = build_in(root)
  build.dispatch = original
  assert(code == 0, "a build with the seed dir present should still pass")
  local found = false
  for _, args in ipairs(captured) do
    for i, a in ipairs(args) do
      if a == "--include-dir" and args[i + 1] == seed.SEED_DIR then
        found = true
      end
    end
  end
  assert(found, "a closure compile should have been handed the seed dir")
end

print("all closure tests passed")
