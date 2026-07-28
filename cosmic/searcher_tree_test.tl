--- In-project resolution, at the unit level.
---
--- `_make/resolution_test.tl` proves the behaviour end to end through
--- real fixture projects; this proves the pieces the end-to-end test
--- cannot reach without arranging a build for each of them — a
--- malformed manifest, an unreadable one, a module in no layer at all.
---
--- `install_tree` mutates this process's `package.searchers`, so every
--- assertion below calls the searcher FUNCTION directly and only the
--- one install test touches the real chain.

local fs = require("cosmic.fs")
local searcher = require("cosmic.searcher")

local tmp = os.getenv("TEST_TMPDIR") or "/tmp"

--- A project root with a manifest, returning both paths.
--- @param name string A directory name unique to the caller
--- @param lines {string} Manifest lines
--- @return string The root
--- @return string The manifest path
local function manifest(name: string, lines: {string}): string, string
  local root = fs.join(tmp, "st-" .. name)
  assert(fs.makedirs(root))
  local path = fs.join(root, "m")
  assert(fs.write(path, table.concat(lines, "\n") .. "\n"))
  return root, path
end

-- A manifest with no root is not a manifest: the searcher would have no
-- tree to fall back to, and installing it would put a searcher in the
-- chain that can only ever miss.
local function test_a_manifest_without_a_root_is_refused()
  local _, path = manifest("noroot", {"mod a /x/a.lua"})
  assert(searcher.install_tree(path) == false,
    "a manifest with no root line must be refused")
end
test_a_manifest_without_a_root_is_refused()

-- A missing manifest is a MISS, not an error: a child with no manifest
-- is an ordinary cosmic, and that is the case every hand-run script is.
local function test_a_missing_manifest_is_a_miss()
  assert(searcher.install_tree(fs.join(tmp, "st-nothing", "m")) == false,
    "a missing manifest must not throw")
end
test_a_missing_manifest_is_a_miss()

-- With no manifest installed the searcher misses rather than throwing:
-- a searcher that cannot help must RETURN a string so require can
-- aggregate every searcher's message into one report.
local function test_the_searcher_misses_without_a_manifest()
  local got = searcher.tree("nothing.at.all")
  assert(got is string, "a miss must be a string, got: " .. type(got))
  assert((got as string):find("nothing.at.all", 1, true), -- cast: guarded
    "the miss must name the module: " .. tostring(got))
end
test_the_searcher_misses_without_a_manifest()

-- The install itself: it lands at index 2, ahead of the default file
-- searcher, because beating `/zip` is the entire point. Appended, it
-- would resolve nothing the binary already carries — which is the
-- failure the whole mechanism exists to fix.
local function test_install_lands_ahead_of_the_file_searcher()
  local root, path = manifest("install", {"root " .. tmp, "build o"})
  assert(fs.isdir(root))
  local before = #package.searchers
  assert(searcher.install_tree(path), "a well-formed manifest installs")
  assert(#package.searchers == before + 1, "one searcher is added")
  assert(package.searchers[2] == searcher.tree,
    "it must sit at index 2, ahead of the default file searcher")
end
test_install_lands_ahead_of_the_file_searcher()

-- Now that a manifest is installed, the layers. A closure entry is
-- loaded from the file the graph built, verbatim.
local function test_the_closure_layer_loads_the_built_file()
  local root = fs.join(tmp, "st-layers")
  assert(fs.makedirs(fs.join(root, "o", "pkg")))
  assert(fs.write(fs.join(root, "o", "pkg", "db.lua"), 'return "BUILT"\n'))
  local path = fs.join(root, "m")
  assert(fs.write(path, "root " .. root .. "\nbuild o\nmod pkg.db "
      .. fs.join(root, "o", "pkg", "db.lua") .. "\n"))
  -- install_tree is idempotent in effect but not in bookkeeping, so
  -- reach the searcher directly rather than through package.searchers.
  assert(searcher.install_tree(path), "the manifest installs")
  local loader = searcher.tree("pkg.db")
  assert(loader is function, "a closure entry must load: " .. tostring(loader))
    assert((loader as function)() == "BUILT") -- cast: guarded above
      end
      test_the_closure_layer_loads_the_built_file()

      -- The build-directory layer: an import no closure names, but that the
      -- graph built anyway. This is what keeps the dispatcher's own modules
      -- from being strict-compiled once per spawned child.
      local function test_the_build_layer_covers_what_no_closure_names()
        local root = fs.join(tmp, "st-layers")
        assert(fs.write(fs.join(root, "o", "pkg", "other.lua"), 'return "UNNAMED"\n'))
        local loader = searcher.tree("pkg.other")
        assert(loader is function, "must resolve from o/: " .. tostring(loader))
          assert((loader as function)() == "UNNAMED") -- cast: guarded above
            end
            test_the_build_layer_covers_what_no_closure_names()

            -- An `init.lua` is its package, the same way `init.tl` is.
            local function test_an_init_is_its_package()
              local root = fs.join(tmp, "st-layers")
              assert(fs.makedirs(fs.join(root, "o", "deep")))
              assert(fs.write(fs.join(root, "o", "deep", "init.lua"), 'return "INIT"\n'))
              local loader = searcher.tree("deep")
              assert(loader is function, "must resolve an init: " .. tostring(loader))
                assert((loader as function)() == "INIT") -- cast: guarded above
                  end
                  test_an_init_is_its_package()

                  -- The source layer, strict-compiled. This is the one that covers a
                  -- COMPUTED require -- invisible to the import scanner, so no closure
                  -- names it and the graph may never have built it.
                  local function test_the_source_layer_compiles_from_the_tree()
                    local root = fs.join(tmp, "st-layers")
                    assert(fs.write(fs.join(root, "fresh.tl"),
                        'local x: string = "SOURCE"\nreturn x\n'))
                    local loader = searcher.tree("fresh")
                    assert(loader is function, "must compile from source: " .. tostring(loader))
                      assert((loader as function)() == "SOURCE") -- cast: guarded above
                        end
                        test_the_source_layer_compiles_from_the_tree()

                        -- Strict means TYPE ERRORS fail the require. That is what keeps a
                        -- tree-first resolution from being a downgrade from the binary's
                        -- already-checked bytes.
                        local function test_a_type_error_fails_the_require()
                          local root = fs.join(tmp, "st-layers")
                          assert(fs.write(fs.join(root, "broken.tl"), 'local x: number = "no"\n'))
                          local ok, err = pcall(searcher.tree, "broken")
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
                          local loader = searcher.tree("warned")
                          assert(loader is function, "a warning must not fail: " .. tostring(loader))
                            assert((loader as function)() == "WARNED") -- cast: guarded above
                              end
                              test_a_warning_does_not_fail_the_require()

                              -- And a module in no layer at all misses, naming itself, so require's
                              -- aggregate report says the right thing.
                              local function test_a_module_in_no_layer_misses()
                                local got = searcher.tree("no.such.module")
                                assert(got is string, "a miss must be a string, got: " .. type(got))
                                assert((got as string):find("no.such.module", 1, true), -- cast: guarded
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
                                assert(fs.makedirs(root))
                                local path = fs.join(root, "m")
                                assert(fs.write(path, "root " .. root .. "\nbuild o\nmod gone "
                                    .. fs.join(root, "o", "gone.lua") .. "\n"))
                                assert(searcher.install_tree(path))
                                local ok, err = pcall(searcher.tree, "gone")
                                assert(not ok, "a closure entry that is not there must be loud")
                                assert(tostring(err):find("gone", 1, true), "got: " .. tostring(err))
                              end
                              test_a_broken_closure_entry_is_loud()

                              print("all searcher tree tests passed")
