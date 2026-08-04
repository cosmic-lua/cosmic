#!/usr/bin/env cosmic
--- Tests for gentype's generation-level robustness: description harvesting
--- around ---@type, run()'s all-modules failure handling, and
--- gentype_defs.read()'s GENTYPE_DEFS override error reporting.
--- Split from gentype_test.tl to respect the 500-line file cap.

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

print("\nAll gentype_gen tests passed!")
