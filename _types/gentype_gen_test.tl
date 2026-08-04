#!/usr/bin/env cosmic
--- Tests for gentype's generation-level robustness: description harvesting
--- around ---@type, run()'s all-modules failure handling, and
--- gentype_defs.read()'s GENTYPE_DEFS override error reporting.
--- Split from gentype_test.tl to respect the 500-line file cap.

local defs = require("_types.gentype_defs")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local gentype = require("_types.gentype")

-- `---@type` is the one tag upstream also spells with a space after the
-- dashes ("--- @type integer"). The description harvester must exclude it
-- like every other tag, or the raw annotation line leaks into the rendered
-- doc comment above the constant (found above every unix.* errno constant
-- in the generated cosmo/unix.d.tl).
local function test_spaced_type_tag_does_not_leak_into_description()
  local source = [==[
unix = {
    --- @type integer
    EFOO = 1,
}
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "unix"))
  assert(not dtl:match("@type"),
    "a spaced '--- @type' annotation must not leak into the doc comment:\n" .. dtl)
  assert(dtl:match("EFOO: integer"), "the constant should still render:\n" .. dtl)
  print("test_spaced_type_tag_does_not_leak_into_description: PASS")
end
test_spaced_type_tag_does_not_leak_into_description()

-- A plain two-dash Lua comment mentioning "@type" is not a doc tag and must
-- not be able to inject a constant type (the recognized tag requires
-- exactly three dashes, optionally followed by whitespace).
local function test_two_dash_type_is_not_a_tag()
  local source = [==[
unix = {
    -- @type string
    EBAR = 2,
}
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "unix"))
  assert(dtl:match("EBAR: integer"),
    "a two-dash '-- @type' comment must not override the default integer type:\n" .. dtl)
  print("test_two_dash_type_is_not_a_tag: PASS")
end
test_two_dash_type_is_not_a_tag()

-- run() in all-modules mode must fail loudly, naming every module whose
-- parse returned nil, instead of silently omitting it from the output.
local function test_run_all_modules_fails_loudly_on_unparseable_module()
  local tmpdir = os.getenv("TEST_TMPDIR")
  local src_path = fs.join(tmpdir, "empty-definitions.lua")
  assert(fs.write(src_path, "-- no modules defined here\n"))
  assert(env.set("GENTYPE_DEFS", src_path, true))
  local result = gentype.run()
  assert(env.unset("GENTYPE_DEFS"))
  assert(not result.success,
    "run() must fail when every module fails to parse, got:\n" .. tostring(result.output))
  assert(result.error:find("Failed to parse module", 1, true),
    "error should say modules failed to parse: " .. tostring(result.error))
  for _, m in ipairs(gentype.get_modules()) do
    assert(result.error:find(m, 1, true),
      "error should name missing module '" .. m .. "': " .. tostring(result.error))
  end
  print("test_run_all_modules_fails_loudly_on_unparseable_module: PASS")
end
test_run_all_modules_fails_loudly_on_unparseable_module()

-- defs.read()'s GENTYPE_DEFS override must include the underlying fs.read
-- error, not just the path, or a permissions/typo problem is undiagnosable.
local function test_defs_read_override_error_includes_reason()
  assert(env.set("GENTYPE_DEFS", "/nonexistent/gentype-defs-test-path", true))
  local source, err = defs.read()
  assert(env.unset("GENTYPE_DEFS"))
  assert(not source, "a missing override path must fail")
  assert(err:find("/nonexistent/gentype-defs-test-path", 1, true),
    "error should name the override path: " .. tostring(err))
  assert(err:find("ENOENT", 1, true) or err:find("No such file", 1, true),
    "error should include the underlying read failure, not just the path: " .. tostring(err))
  print("test_defs_read_override_error_includes_reason: PASS")
end
test_defs_read_override_error_includes_reason()

print("\nAll gentype_gen tests passed!")
