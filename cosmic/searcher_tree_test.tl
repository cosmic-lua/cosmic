--- In-project resolution, at the unit level.
---
--- `_make/resolution_test.tl` proves the behaviour end to end through
--- real fixture projects; this proves the pieces the end-to-end test
--- cannot reach without arranging a build for each of them — a
--- malformed manifest, an unreadable one, a module in no layer at all.
---
--- `install_manifest` mutates this process's `package.searchers`, so every
--- assertion below calls the searcher FUNCTION directly and only the
--- one install test touches the real chain.
---
--- The asserts go through `loader_of` rather than `x is function`: the
--- formatter miscounts a type-position `function` as a block opener and
--- cascades the indentation of everything after it to end of file. It
--- is self-consistent, so `--check fmt` passes on the damage. Filed
--- separately with this file's first draft as the reproducer.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local searcher = require("cosmic.searcher")

local tmp = os.getenv("TEST_TMPDIR") or "/tmp"

--- What a searcher returns on a hit: the chunk require would call.
local type Loader = function(): any

--- The loader a searcher returned, or nil when it missed.
---
--- A searcher's contract is "a function on a hit, a string on a miss",
--- so this is the whole discrimination — and having it in one place is
--- what lets every test below read as one line.
--- Callers bind the searcher's first return before passing it here: a
--- searcher returns TWO values (the loader and the filename), and a
--- multi-return call spreads into the argument list it sits in.
--- @param got any A searcher's first return
--- @return Loader|nil The loader, or nil when it was a miss
local function loader_of(got: any): Loader | nil
  if type(got) ~= "function" then
    return nil
  end
  return got as Loader -- cast: a searcher's hit IS its loader
end

--- A project root with a manifest, returning both paths.
--- @param name string A directory name unique to the caller
--- @param lines {string} Manifest lines
--- @return string The root
--- @return string The manifest path
local function manifest(name: string, lines: {string}): string, string
  local root = fs.join(tmp, "st-" .. name)
  assert(fs.make_dirs(root))
  local path = fs.join(root, "m")
  assert(fs.write(path, table.concat(lines, "\n") .. "\n"))
  return root, path
end

-- The tree searcher VALUE is installed, never exported (#1001). Reach
-- it by installing a minimal bootstrap manifest once and taking what
-- landed at index 2; the cached value then also proves identity across
-- repeat installs.
local tree_fn: function(string): (any, any) = nil

local function installed_tree(): function(string): (any, any)
  if not tree_fn then
    local p = fs.join(tmp, "st-bootstrap.manifest")
    check.must(fs.write(p, "root " .. tmp .. "\n"))
    assert(searcher.install_manifest(p))
    -- cast: package.searchers entries are untyped
    tree_fn = package.searchers[2] as function(string): (any, any)
  end
  return tree_fn
end

local function tree(name: string): any, any
  return installed_tree()(name)
end

-- A manifest with no root is not a manifest: the searcher would have no
-- tree to fall back to, and installing it would put a searcher in the
-- chain that can only ever miss.
local function test_a_manifest_without_a_root_is_refused()
  local _, path = manifest("noroot", {"mod a /x/a.lua"})
  assert(searcher.install_manifest(path) == false,
    "a manifest with no root line must be refused")
end
test_a_manifest_without_a_root_is_refused()

-- A missing manifest is a MISS, not an error: a child with no manifest
-- is an ordinary cosmic, and that is the case every hand-run script is.
local function test_a_missing_manifest_is_a_miss()
  assert(searcher.install_manifest(fs.join(tmp, "st-nothing", "m")) == false,
    "a missing manifest must not throw")
end
test_a_missing_manifest_is_a_miss()

-- A module in no layer at all is a MISS rather than a throw: a
-- searcher that cannot help must RETURN a string so require can
-- aggregate every searcher's message into one report.
local function test_the_searcher_misses_without_a_manifest()
  local got = tree("nothing.at.all")
  assert(got is string, "a miss must be a string, got: " .. type(got))
  assert(got:find("nothing.at.all", 1, true),
    "the miss must name the module: " .. tostring(got))
end
test_the_searcher_misses_without_a_manifest()

-- The install itself: it lands at index 2, ahead of the default file
-- searcher, because beating `/zip` is the entire point. Appended, it
-- would resolve nothing the binary already carries — which is the
-- failure the whole mechanism exists to fix.
--
-- This process may itself already be running under a --modules
-- manifest (this repo's own build resolving its own tree), so the
-- delta is checked as "at most one", not "exactly one" -- and
-- idempotence (the same guarantee install() has) is checked directly
-- via a second call that must not grow the chain further.
local function test_install_lands_ahead_of_the_file_searcher()
  local root, path = manifest("install", {"root " .. tmp, "build o"})
  assert(fs.is_dir(root))
  local before = #package.searchers
  assert(searcher.install_manifest(path), "a well-formed manifest installs")
  assert(#package.searchers - before <= 1, "at most one searcher is added")
  assert(package.searchers[2] == installed_tree(),
    "it must sit at index 2, ahead of the default file searcher")

  local after_first = #package.searchers
  assert(searcher.install_manifest(path), "a repeat install still succeeds")
  assert(#package.searchers == after_first,
    "a repeat install_manifest must not add a second copy of the searcher")
end
test_install_lands_ahead_of_the_file_searcher()

-- Now that a manifest is installed, the layers. A closure entry is
-- loaded from the file the graph built, verbatim.
local function test_the_closure_layer_loads_the_built_file()
  local root = fs.join(tmp, "st-layers")
  assert(fs.make_dirs(fs.join(root, "o", "pkg")))
  assert(fs.write(fs.join(root, "o", "pkg", "db.lua"), 'return "BUILT"\n'))
  local path = fs.join(root, "m")
  assert(fs.write(path, "root " .. root .. "\nbuild o\nmod pkg.db "
      .. fs.join(root, "o", "pkg", "db.lua") .. "\n"))
  assert(searcher.install_manifest(path), "the manifest installs")
  local got = tree("pkg.db")
  local loader = check.must(loader_of(got))
  assert(loader() == "BUILT", "a closure entry must load the built file")
end
test_the_closure_layer_loads_the_built_file()

-- The build-directory layer: an import no closure names, but that the
-- graph built anyway. This is what keeps the dispatcher's own modules
-- from being strict-compiled once per spawned child.
local function test_the_build_layer_covers_what_no_closure_names()
  local root = fs.join(tmp, "st-layers")
  assert(fs.write(fs.join(root, "o", "pkg", "other.lua"), 'return "UNNAMED"\n'))
  local got = tree("pkg.other")
  local loader = check.must(loader_of(got))
  assert(loader() == "UNNAMED", "must resolve from the build directory")
end
test_the_build_layer_covers_what_no_closure_names()

-- An `init.lua` is its package, the same way `init.tl` is.
local function test_an_init_is_its_package()
  local root = fs.join(tmp, "st-layers")
  assert(fs.make_dirs(fs.join(root, "o", "deep")))
  assert(fs.write(fs.join(root, "o", "deep", "init.lua"), 'return "INIT"\n'))
  local got = tree("deep")
  local loader = check.must(loader_of(got))
  assert(loader() == "INIT", "an init resolves as its package")
end
test_an_init_is_its_package()

-- The source layer, strict-compiled. This is the one that covers a
-- COMPUTED require -- invisible to the import scanner, so no closure
-- names it and the graph may never have built it.
local function test_the_source_layer_compiles_from_the_tree()
  local root = fs.join(tmp, "st-layers")
  assert(fs.write(fs.join(root, "fresh.tl"),
      'local x: string = "SOURCE"\nreturn x\n'))
  local got = tree("fresh")
  local loader = check.must(loader_of(got))
  assert(loader() == "SOURCE", "must compile from the tree's source")
end
test_the_source_layer_compiles_from_the_tree()

-- Strict means TYPE ERRORS fail the require. That is what keeps a
-- tree-first resolution from being a downgrade from the binary's
-- already-checked bytes.
local function test_a_type_error_fails_the_require()
  local root = fs.join(tmp, "st-layers")
  assert(fs.write(fs.join(root, "broken.tl"), 'local x: number = "no"\n'))
  local ok, err = pcall(tree, "broken")
  assert(not ok, "a type error must fail the require")
  assert(tostring(err):find("broken.tl", 1, true), "got: " .. tostring(err))
end
test_a_type_error_fails_the_require()

-- Strict does NOT mean werror. `--check types` is the style gate; a
-- shadowed or unused local must not become a runtime failure of
-- whatever happened to require the file first.
local function test_a_warning_does_not_fail_the_require()
  local root = fs.join(tmp, "st-layers")
  assert(fs.write(fs.join(root, "warned.tl"),
      'local unused: string = "u"\nreturn "WARNED"\n'))
  local got = tree("warned")
  local loader = check.must(loader_of(got))
  assert(loader() == "WARNED", "a warning must not fail the require")
end
test_a_warning_does_not_fail_the_require()

-- And a module in no layer at all misses, naming itself, so require's
-- aggregate report says the right thing.
local function test_a_module_in_no_layer_misses()
  local got = tree("no.such.module")
  assert(got is string, "a miss must be a string, got: " .. type(got))
  assert(got:find("no.such.module", 1, true),
    "got: " .. tostring(got))
end
test_a_module_in_no_layer_misses()

-- A closure entry that names a file which is not there is an ERROR, not
-- a miss: the manifest is the graph's own statement about what it
-- built, so a broken one is the build being wrong rather than this
-- module being absent, and falling through to `/zip` would answer with
-- the stale copy this whole mechanism exists to stop answering with.
local function test_a_broken_closure_entry_is_loud()
  local root = fs.join(tmp, "st-broken")
  assert(fs.make_dirs(root))
  local path = fs.join(root, "m")
  assert(fs.write(path, "root " .. root .. "\nbuild o\nmod gone "
      .. fs.join(root, "o", "gone.lua") .. "\n"))
  assert(searcher.install_manifest(path))
  local ok, err = pcall(tree, "gone")
  assert(not ok, "a closure entry that is not there must be loud")
  assert(tostring(err):find("gone", 1, true), "got: " .. tostring(err))
end
test_a_broken_closure_entry_is_loud()

-- compile_tree's re-entrancy guard (`compiling`) must clear even when
-- the compiler itself THROWS instead of returning nil, err: left up,
-- it sticks true and every later tree resolution fails with "compiler
-- bootstrap in progress" instead of that one file's own error.
local function test_compiling_guard_clears_after_a_throw()
  local root = fs.join(tmp, "st-throw")
  assert(fs.make_dirs(root))
  assert(fs.write(fs.join(root, "boom.tl"), "return 1\n"))
  local path = fs.join(root, "m")
  assert(fs.write(path, "root " .. root .. "\nbuild o\n"))
  assert(searcher.install_manifest(path))

  local teal = require("cosmic.teal")
  local original = teal.compile_cached
  teal.compile_cached = function(_input_path: string, _opts?: {string: boolean}): string | nil, string
    error("boom: injected compiler failure", 0)
  end
  local ok, err = pcall(tree, "boom")
  teal.compile_cached = original
  assert(not ok, "a throwing compile_cached must still fail the require")
  assert(tostring(err):find("boom", 1, true), "got: " .. tostring(err))

  -- If the guard stuck, this resolves to "compiler bootstrap in
  -- progress" instead of the file's own content.
  assert(fs.write(fs.join(root, "after.tl"), 'return "OK"\n'))
  local got = tree("after")
  local loader = check.must(loader_of(got))
  assert(loader() == "OK", "resolution after a throw must still work")
end
test_compiling_guard_clears_after_a_throw()

-- The argv scan is the channel's other half, and its rule is where the
-- scan stops: at the first non-flag, which is where getopt stops too.
-- Past that point a `--modules` is the SCRIPT's own.
local function test_install_argv_manifest_stops_at_the_first_positional()
  local _, path = manifest("argv", {"root " .. tmp, "build o"})
  assert(searcher.install_argv_manifest({"--modules", path}),
    "the engine's own flag, ahead of everything, installs")
  assert(searcher.install_argv_manifest({"script.tl", "--modules", path}) == false,
    "a script's own --modules must not redirect the dispatcher")
  assert(searcher.install_argv_manifest({"--verbose"}) == false,
    "no flag, nothing to install")
  local named_ok, named_err = searcher.install_argv_manifest({"--modules"})
  assert(named_ok == false and named_err ~= nil,
    "a flag with no argument is a failure that says why (#1001)")
end
test_install_argv_manifest_stops_at_the_first_positional()

print("all searcher tree tests passed")
