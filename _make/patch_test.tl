#!/usr/bin/env cosmic
-- Unit tests for _make.patch: the carried-patch reader and applier.
-- The end-to-end path (fetch applies, repair re-applies) is exercised
-- by the tree itself — 3p/tl/tl_patch.tl rides every build — so what
-- lives here is the contract: sorted order, exact-once anchors,
-- idempotent application, loud refusals.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local patch = require("_make.patch")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function write(path: string, text: string)
  assert(fs.make_dirs(fs.dirname(path)))
  assert(fs.write(path, text))
end

local function test_of_pin_names_the_sibling()
  local dir = check.must(fs.temp_dir(fs.join(tmpdir, "ofpin-XXXXXX")))
  local pin_path = fs.join(dir, "x_pin.tl")
  write(pin_path, "return {}\n")
  assert(patch.of_pin(pin_path) == nil, "no patch file means nil")
  assert(patch.of_pin(fs.join(dir, "notapin.tl")) == nil,
    "a non-pin path carries no patch")
  local patch_path = fs.join(dir, "x_patch.tl")
  write(patch_path, "return {}\n")
  assert(patch.of_pin(pin_path) == patch_path, "the sibling patch is found")
end
test_of_pin_names_the_sibling()

local function test_read_sorts_and_validates()
  local dir = check.must(fs.temp_dir(fs.join(tmpdir, "read-XXXXXX")))
  local p = fs.join(dir, "y_patch.tl")
  write(p, [[
return {
  ["b-second"] = {file = "f", find = "x", replace = "y", note = "n2"},
  ["a-first"] = {file = "f", find = "p", replace = "q", note = "n1"},
}
]])
  local edits = check.must(patch.read(p))
  assert(#edits == 2, "two edits")
  assert(edits[1].name == "a-first" and edits[2].name == "b-second",
    "edits come out in sorted-name order")
  assert(edits[1].find == "p" and edits[1].replace == "q")

  write(p, "return {}\n")
  local none, err = patch.read(p)
  assert(none == nil and err:find("no edits", 1, true),
    "an empty patch is refused: " .. tostring(err))

  write(p, [[
return {
  ["missing-note"] = {file = "f", find = "x", replace = "y"},
}
]])
  local bad, berr = patch.read(p)
  assert(bad == nil and berr:find("needs file, find, replace, note", 1, true),
    "a missing field is named: " .. tostring(berr))
end
test_read_sorts_and_validates()

local function test_apply_exact_once_and_idempotent()
  local dir = check.must(fs.temp_dir(fs.join(tmpdir, "apply-XXXXXX")))
  write(fs.join(dir, "t.lua"), "local a = 1\nlocal b = 2\nlocal a = 1\n")
  local twice: {patch.Edit} = {
    {name = "e", file = "t.lua", find = "local a = 1", replace = "local a = 9",
      note = "test"},
  }
  local ok, err = patch.apply(dir, twice)
  assert(not ok and err:find("2 time(s)", 1, true),
    "a twice-occurring anchor is refused: " .. tostring(err))

  local once: {patch.Edit} = {
    {name = "e", file = "t.lua", find = "local b = 2", replace = "local b = 7",
      note = "test"},
  }
  assert(patch.apply(dir, once))
  local text = check.must(fs.read(fs.join(dir, "t.lua")))
  assert(text:find("local b = 7", 1, true), "the edit landed")
  assert(patch.applied(dir, once), "applied() sees the replacement")
  assert(patch.apply(dir, once), "re-applying is a no-op, not a failure")
  assert(check.must(fs.read(fs.join(dir, "t.lua"))) == text,
    "idempotent: the bytes did not move")

  local absent: {patch.Edit} = {
    {name = "gone", file = "t.lua", find = "nowhere at all",
      replace = "still nowhere", note = "test"},
  }
  local aok, aerr = patch.apply(dir, absent)
  assert(not aok and aerr:find("0 time(s)", 1, true),
    "a missing anchor is refused: " .. tostring(aerr))
  assert(not patch.applied(dir, absent), "applied() is false for it")
end
test_apply_exact_once_and_idempotent()
