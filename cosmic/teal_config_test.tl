#!/usr/bin/env cosmic
-- tlconfig.lua (editor/LSP tooling) and the Makefile's INCLUDE_DIRS both
-- mirror the checker options compiled into cosmic.teal; this test replaces
-- the old "keep the two in sync by hand" comment with enforcement. The
-- test's Makefile target grants r:tlconfig.lua and r:Makefile — the repo
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
  -- searches (defaults or the Makefile's extra dirs), so the LSP and
  -- cosmic --check types resolve the same types.
  local cfg_dirs = cfg.include_dir as {string} -- cast: from any
  local blessed: {string: boolean} = {}
  for _, d in ipairs(teal.get_default_include_dirs()) do
    blessed[d] = true
  end
  for _, d in ipairs(teal.MAKEFILE_INCLUDE_DIRS) do
    blessed[d] = true
  end
  for _, d in ipairs(cfg_dirs) do
    assert(blessed[d],
      "tlconfig include_dir '" .. d
      .. "' is not in cosmic.teal's default or Makefile include dirs")
  end

  -- And the editor must cover everything the checker sees locally: every
  -- repo-relative dir the build/checker searches (Makefile extras plus
  -- non-/zip defaults) must appear in tlconfig, or the LSP resolves less
  -- than --check types does.
  local editor: {string: boolean} = {}
  for _, d in ipairs(cfg_dirs) do
    editor[d] = true
  end
  for _, d in ipairs(teal.MAKEFILE_INCLUDE_DIRS) do
    assert(editor[d],
      "Makefile include dir '" .. d .. "' is missing from tlconfig.lua")
  end
  for _, d in ipairs(teal.get_default_include_dirs()) do
    if d ~= "/zip" and d:sub(1, 5) ~= "/zip/" then
      assert(editor[d],
        "checker default include dir '" .. d
        .. "' is missing from tlconfig.lua")
    end
  end
end
test_tlconfig_matches_teal_defaults()

-- The Makefile's INCLUDE_DIRS default must equal the mirror compiled into
-- cosmic.teal — the build and the library must agree on what extra dirs
-- the checker searches, or --check types behaves differently under
-- bin/make than standalone.
local function test_makefile_include_dirs_match_mirror()
  local content = check.must(fs.read("Makefile"), "Makefile should be readable")
  local line = content:match("\nINCLUDE_DIRS %?= ([^\n]*)")
  assert(line, "Makefile should declare 'INCLUDE_DIRS ?= ...'")
  local dirs: {string} = {}
  for d in line:gmatch("%S+") do
    dirs[#dirs + 1] = d
  end
  assert(#dirs == #teal.MAKEFILE_INCLUDE_DIRS,
    "Makefile INCLUDE_DIRS has " .. #dirs .. " entries, cosmic.teal mirror has "
    .. #teal.MAKEFILE_INCLUDE_DIRS)
  for i, d in ipairs(teal.MAKEFILE_INCLUDE_DIRS) do
    assert(dirs[i] == d,
      "Makefile INCLUDE_DIRS[" .. i .. "] is '" .. tostring(dirs[i])
      .. "', cosmic.teal mirror says '" .. d .. "'")
  end
end
test_makefile_include_dirs_match_mirror()
