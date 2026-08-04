#!/usr/bin/env cosmic
--- Tests for gentype's ---@alias handling (Teal enum / type alias emission).
--- Split from gentype_test.tl to respect the 500-line file cap.

local gentype = require("_types.gentype")

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
    "literal-union alias should render Teal enum:\n" .. dtl)
  assert(dtl:match("--- Archive open modes%.\nlocal enum OpenMode"),
    "alias description should precede the enum:\n" .. dtl)
  assert(dtl:match("local type Errno = integer"),
    "scalar alias should render transparent type alias:\n" .. dtl)
  assert(dtl:match("  type OpenMode = OpenMode"),
    "enum should be re-exported on the module record:\n" .. dtl)
  assert(dtl:match("open: function%(path: string, mode%?: OpenMode%)"),
    "module-local alias reference should collapse to the bare name:\n" .. dtl)
  assert(not dtl:match("uint32"),
    "bare legacy aliases must not be emitted:\n" .. dtl)
  print("test_alias_enum_and_scalar: PASS")
end
test_alias_enum_and_scalar()

-- A `---@class mod.Name: userdata` parent renders as Teal's `userdata`
-- member, so `x is Name` compiles to a type(x) == "userdata" test.
local function test_userdata_class_marker()
  local source = [==[
zip = {}

---@class zip.Handle: userdata
---@field fd integer

--- Opens a handle.
---@return zip.Handle h
function zip.open() end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "zip"))
  assert(dtl:match("local record Handle\n  userdata\n"),
    "userdata parent should render userdata member:\n" .. dtl)
  print("test_userdata_class_marker: PASS")
end
test_userdata_class_marker()

-- A malformed ---@alias right-hand side must fail validate_module loudly,
-- the same as a malformed param/return/field/constant type — aliases were
-- not validated against the type grammar at all before, so a bad RHS
-- rendered invalid Teal silently.
local function test_malformed_alias_fails_validation()
  local source = [==[
zip = {}

---@alias zip.Bad nil,|nil

--- Opens an archive.
---@return boolean ok
function zip.open() end
]==]
  local module = gentype.parse_module(source, "zip")
  local output, err = gentype.render_module(module)
  assert(not output, "a malformed alias RHS must not render, got:\n" .. tostring(output))
  assert(err, "expected an error message")
  assert(err:find("zip.Bad", 1, true), "error must name the offending alias: " .. err)
  print("test_malformed_alias_fails_validation: PASS")
end
test_malformed_alias_fails_validation()

print("\nAll tests passed!")
