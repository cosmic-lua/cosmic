#!/usr/bin/env cosmic
--- Tests for gentype's ---@alias handling (Teal enum / type alias emission).
--- Split from gentype_test.tl to respect the 500-line file cap.

local gentype = require("types.gentype")

-- A module-prefixed `---@alias` whose right-hand side is a union of string
-- literals renders as a real Teal enum, is re-exported on the module record,
-- and references to it collapse to the bare enum name. A scalar alias renders
-- as a transparent `type` alias. Bare (unprefixed) legacy aliases like uint32
-- stay hardcoded conversions and must not be emitted.
local function test_alias_enum_and_scalar()
  local source = [==[
zip = {}

---@alias uint32 integer Unsigned 32-bit integer

--- Archive open modes.
---@alias zip.OpenMode "r"|"w"|"a"

--- Kernel-reported errno group.
---@alias zip.Errno integer

--- Opens an archive.
---@param path string
---@param mode? zip.OpenMode Open mode
---@return boolean ok
function zip.open(path, mode) end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "zip"))
  assert(dtl:match("local enum OpenMode\n  \"r\"\n  \"w\"\n  \"a\"\nend"),
    "literal-union alias should render as a Teal enum:\n" .. dtl)
  assert(dtl:match("--- Archive open modes%.\nlocal enum OpenMode"),
    "alias description should precede the enum:\n" .. dtl)
  assert(dtl:match("local type Errno = number"),
    "scalar alias should render as a transparent type alias:\n" .. dtl)
  assert(dtl:match("  type OpenMode = OpenMode"),
    "enum should be re-exported on the module record:\n" .. dtl)
  assert(dtl:match("open: function%(path: string, mode%?: OpenMode%)"),
    "module-local alias reference should collapse to the bare name:\n" .. dtl)
  assert(not dtl:match("uint32"),
    "bare legacy aliases must not be emitted:\n" .. dtl)
  print("test_alias_enum_and_scalar: PASS")
end
test_alias_enum_and_scalar()

print("\nAll tests passed!")
