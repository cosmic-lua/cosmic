#!/usr/bin/env cosmic
-- tlconfig.lua (editor/LSP tooling) mirrors the checker options compiled
-- into cosmic.teal; this test replaces the old "keep the two in sync by
-- hand" comment with enforcement. The test's Makefile target grants
-- r:tlconfig.lua — the repo root is outside the default test unveil.

local teal = require("cosmic.teal")

local function test_tlconfig_matches_teal_defaults()
  local chunk, err = loadfile("tlconfig.lua")
  assert(chunk, "tlconfig.lua should load: " .. tostring(err))
  local cfg = chunk() as {string: any}
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
  -- searches, so the LSP and cosmic --check-types resolve the same types.
  local defaults: {string: boolean} = {}
  for _, d in ipairs(teal.get_default_include_dirs()) do
    defaults[d] = true
  end
  for _, d in ipairs(cfg.include_dir as {string}) do
    assert(defaults[d],
      "tlconfig include_dir '" .. d
      .. "' is not in cosmic.teal's default include dirs")
  end
end
test_tlconfig_matches_teal_defaults()
