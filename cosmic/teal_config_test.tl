#!/usr/bin/env cosmic
-- tlconfig.lua (editor/LSP tooling) and the compile rule's --include-dir both
-- mirror the checker options compiled into cosmic.teal, and this test is
-- what keeps the three in sync instead of a comment asking politely. The
-- test reads tlconfig.lua and embed/cosmic.mk — the repo
-- root is outside the default test unveil.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

local function test_tlconfig_matches_teal_defaults()
  local chunk, err = loadfile("tlconfig.lua")
  assert(chunk, "tlconfig.lua should load: " .. tostring(err))
  local cfg = chunk() as {string: any} -- cast: from any
  assert(cfg, "tlconfig.lua should return a table")

  assert(cfg.gen_target == teal.DEFAULT_GEN_TARGET,
    "tlconfig gen_target (" .. tostring(cfg.gen_target)
    .. ") must match cosmic.teal DEFAULT_GEN_TARGET ("
    .. teal.DEFAULT_GEN_TARGET .. ")")
  assert(cfg.gen_compat == teal.DEFAULT_GEN_COMPAT,
    "tlconfig gen_compat (" .. tostring(cfg.gen_compat)
    .. ") must match cosmic.teal DEFAULT_GEN_COMPAT ("
    .. teal.DEFAULT_GEN_COMPAT .. ")")

  -- Every editor include dir must be one the compiled-in checker also
  -- searches (defaults or the build's extra dirs), so the LSP and
  -- cosmic --check types resolve the same types.
  local cfg_dirs = cfg.include_dir as {string} -- cast: from any
  local blessed: {string: boolean} = {}
  for _, d in ipairs(teal.default_include_dirs()) do
    blessed[d] = true
  end
  for _, d in ipairs(teal.BUILD_INCLUDE_DIRS) do
    blessed[d] = true
  end
  for _, d in ipairs(cfg_dirs) do
    assert(blessed[d],
      "tlconfig include_dir '" .. d
      .. "' is not in cosmic.teal's default or build include dirs")
  end

  -- And the editor must cover everything the checker sees locally: every
  -- repo-relative dir the build/checker searches (the build's extras plus
  -- non-/zip defaults) must appear in tlconfig, or the LSP resolves less
  -- than --check types does.
  local editor: {string: boolean} = {}
  for _, d in ipairs(cfg_dirs) do
    editor[d] = true
  end
  for _, d in ipairs(teal.BUILD_INCLUDE_DIRS) do
    assert(editor[d],
      "build include dir '" .. d .. "' is missing from tlconfig.lua")
  end
  for _, d in ipairs(teal.default_include_dirs()) do
    if d ~= "/zip" and d:sub(1, 5) ~= "/zip/" then
      assert(editor[d],
        "checker default include dir '" .. d
        .. "' is missing from tlconfig.lua")
    end
  end
end
test_tlconfig_matches_teal_defaults()

-- The compile rule's `--include-dir` flags must equal the mirror
-- compiled into cosmic.teal — the build and the library must agree on
-- what extra dirs the checker searches, or `--check types` behaves
-- differently under a build than standalone. The rules file is where
-- that lives: it is committed, constant for every project, and what
-- `--make` hands to make.
local function test_build_include_dirs_match_mirror()
  local content = check.must(fs.read("embed/cosmic.mk"),
    "embed/cosmic.mk should be readable")
  -- Recipe lines only: make recipes are tab-indented, and the prose
  -- above the rule names the flag too.
  -- Distinct values: the per-file and batched compile recipes (#1099)
  -- both pass the same dirs, and the mirror is about VALUES, not about
  -- how many rules repeat them.
  local dirs: {string} = {}
  local seen: {string: boolean} = {}
  for line in content:gmatch("[^\n]+") do
    if line:sub(1, 1) == "\t" then
      for d in line:gmatch("%-%-include%-dir (%S+)") do
        if not seen[d] then
          seen[d] = true
          dirs[#dirs + 1] = d
        end
      end
    end
  end
  assert(#dirs > 0, "the compile rule should pass --include-dir")
  assert(#dirs == #teal.BUILD_INCLUDE_DIRS,
    "cosmic.mk passes " .. #dirs .. " include dirs, cosmic.teal mirror has "
    .. #teal.BUILD_INCLUDE_DIRS)
  for i, d in ipairs(teal.BUILD_INCLUDE_DIRS) do
    assert(dirs[i] == d,
      "cosmic.mk include dir [" .. i .. "] is '" .. tostring(dirs[i])
      .. "', cosmic.teal mirror says '" .. d .. "'")
  end
end
test_build_include_dirs_match_mirror()
