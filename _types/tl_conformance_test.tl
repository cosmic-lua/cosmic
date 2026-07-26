#!/usr/bin/env cosmic
-- Conformance probe for the generated tl.d.tl shim (redesign 3/3).
--
-- tl.d.tl is the narrowed public tl surface cosmic ships; three of its
-- signatures drifted from tl's real API before gentl started generating
-- it  gentl verifies arity and record fields, but the
-- ERASED types (any, string) could still disagree with upstream in ways
-- extraction cannot see. This probe closes that gap with the checker
-- itself as the comparator: one probe file exercising every call shape
-- the shim declares is type-checked twice —
--
--   1. against _types/tl.d.tl (the shim), strict, and
--   2. against the staged tl source (o/tl/.staged/tl.tl), the ground
--      truth for the pinned tl version —
--
-- and both must accept it. A shim signature upstream's own types
-- reject fails check 2; a probe that drifts from the shim fails
-- check 1. On a tl version bump the probe re-validates automatically.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

local tmpdir = os.getenv("TEST_TMPDIR")

-- The probe is only ever TYPE-CHECKED, never executed, so calls with
-- side effects (loader, path writes) are safe to state here.
local PROBE < const > = [[
local tl = require("tl")

-- fields
local p: string = tl.path or ""
tl.path = p
-- warning_kinds is enum-keyed upstream ({WarningKind: boolean}) and
-- string-keyed in the shim's erasure; take it unannotated so both
-- agree on existence and shape without pinning the key type.
local wk = tl.warning_kinds

-- loader
tl.loader()

-- search_module: found filename, open FILE, tried patterns
local found, fd, tried = tl.search_module("cosmic.no_such_module", false)
local _found: string = found
local _fd = fd
local _tried: {string} = tried

-- init_env positional arities: (), (lax), (lax, gen_compat),
-- (lax, gen_compat, gen_target)
local _e1 = tl.init_env()
local _e2 = tl.init_env(true)
local _e3 = tl.init_env(true, "off")
local _e4 = tl.init_env(true, "off", "5.4")

-- new_env with the options form cosmic.teal uses
local env = tl.new_env({
    defaults = {
      feat_lax = "off",
      gen_target = "5.4",
      gen_compat = "off",
    },
  })

-- lex
local tokens, lex_errs = tl.lex("local x = 1", "probe")
local _tokens: {tl.Token} = tokens
local _lex_errs: {tl.Error} = lex_errs

-- parse_program
local ast, req_mods = tl.parse_program(tokens, {}, "probe")
local _req_mods: {string} = req_mods

-- process_string: exactly one Result; failures land in its fields.
-- Five args: upstream's types REQUIRE the 5th (_module_name); the shim
-- declares it optional for cosmic's 4-arg call sites.
local result = tl.process_string("local x = 1", false, env, "probe", "probe_mod")
local _syn: {tl.Error} = result.syntax_errors
local _typ: {tl.Error} = result.type_errors
local _warn: {tl.Error} = result.warnings

-- generate: target STRING second, nil+error on codegen failure
local code, gen_err = tl.generate(result.ast, "5.4")
local _code: string = code
local _gen_err: string = gen_err

-- keep every probe value visibly used for the strict shim check
print(wk ~= nil, ast ~= nil, _found, _fd, #_tried, _e1, _e2, _e3, _e4)
]]

local probe_path = fs.join(tmpdir, "tl_probe.tl")
assert(fs.write(probe_path, PROBE))

-- Check 1: the shim. Default include dirs put _types first, so
-- require("tl") resolves to the generated tl.d.tl. Strict; warnings
-- fail, so every probe value must be used or underscore-marked.
local function test_probe_passes_against_shim()
  local r = teal.check(probe_path)
  assert(r.ok, "probe must type-check against tl.d.tl:\n"
    .. teal.format_issues(r.errors) .. "\n" .. teal.format_issues(r.warnings))
end
test_probe_passes_against_shim()

-- Check 2: the staged tl source, the pinned ground truth. The staged
-- dir is prepended so tl resolves to tl.tl instead of the shim.
-- werror=false: tl's own 15k-line source need not satisfy cosmic's
-- warnings-as-errors policy; type ERRORS are the conformance signal.
local function test_probe_passes_against_staged_tl()
  local staged = fs.join(os.getenv("TEST_O") or "o", "tl/.staged")
  assert(fs.isfile(fs.join(staged, "tl.tl")),
    "staged tl source missing at " .. staged .. " (build 3p/tl first)")
  local r = teal.check(probe_path, {include_dirs = {staged}, werror = false})
  assert(#r.errors == 0,
    "probe must type-check against the staged tl.tl — a failure here "
    .. "means the shim declares a call shape upstream rejects:\n"
    .. teal.format_issues(r.errors))
end
test_probe_passes_against_staged_tl()

-- Completeness ratchet: every function the shim declares must appear
-- in the probe, so a member added to gentl's surface cannot ship
-- unprobed.
local function test_probe_covers_every_shim_member()
  local shim = check.must(fs.read("_types/tl.d.tl"))
  for name in shim:gmatch("\n  ([%w_]+): function") do
    assert(PROBE:find("tl%." .. name .. "%f[^%w_]"),
      "shim member 'tl." .. name .. "' is not exercised by the probe")
  end
end
test_probe_covers_every_shim_member()
