#!/usr/bin/env cosmic
-- Unit tests for _make.patch: the carried-patch reader and applier.
-- The end-to-end path (fetch applies, repair re-applies) is exercised
-- by the tree itself — the 3p/tl/tl_patch/ set rides every build — so
-- what lives here is the contract: sorted order, exact-once anchors,
-- idempotent application, one entry namespace per pin, loud refusals.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local patch = require("_make.patch")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function write(path: string, text: string)
  assert(fs.make_dirs(fs.dirname(path)))
  assert(fs.write(path, text))
end

local function test_paths_of_pin_names_the_sibling_file()
  local dir = check.must(fs.temp_dir(fs.join(tmpdir, "ofpin-XXXXXX")))
  local pin_path = fs.join(dir, "x_pin.tl")
  write(pin_path, "return {}\n")
  assert(patch.paths_of_pin(pin_path) == nil, "no patch means nil")
  assert(patch.paths_of_pin(fs.join(dir, "notapin.tl")) == nil,
    "a non-pin path carries no patch")
  local patch_path = fs.join(dir, "x_patch.tl")
  write(patch_path, "return {}\n")
  local paths = check.must(patch.paths_of_pin(pin_path))
  assert(#paths == 1 and paths[1] == patch_path,
    "the single-file layout resolves exactly as before")
end

local function test_paths_of_pin_resolves_a_directory()
  local dir = check.must(fs.temp_dir(fs.join(tmpdir, "ofdir-XXXXXX")))
  local pin_path = fs.join(dir, "x_pin.tl")
  write(pin_path, "return {}\n")
  write(fs.join(dir, "x_patch", "b.tl"), "return {}\n")
  write(fs.join(dir, "x_patch", "a.tl"), "return {}\n")
  local paths = check.must(patch.paths_of_pin(pin_path))
  assert(#paths == 2, "both entry files are found")
  assert(paths[1]:find("a.tl", 1, true) and paths[2]:find("b.tl", 1, true),
    "files come back sorted by name")
end

local function test_paths_of_pin_refuses_ambiguity_and_emptiness()
  local dir = check.must(fs.temp_dir(fs.join(tmpdir, "ofboth-XXXXXX")))
  local pin_path = fs.join(dir, "x_pin.tl")
  write(pin_path, "return {}\n")
  write(fs.join(dir, "x_patch.tl"), "return {}\n")
  write(fs.join(dir, "x_patch", "a.tl"), "return {}\n")
  local both, berr = patch.paths_of_pin(pin_path)
  assert(both == nil and berr:find("keep exactly one", 1, true),
    "file and directory together are refused: " .. tostring(berr))

  local dir2 = check.must(fs.temp_dir(fs.join(tmpdir, "ofempty-XXXXXX")))
  local pin2 = fs.join(dir2, "y_pin.tl")
  write(pin2, "return {}\n")
  assert(fs.make_dirs(fs.join(dir2, "y_patch")))
  local none, nerr = patch.paths_of_pin(pin2)
  assert(none == nil and nerr:find("one to delete", 1, true),
    "an empty patch directory is refused: " .. tostring(nerr))
end

local function test_read_all_merges_one_namespace()
  local dir = check.must(fs.temp_dir(fs.join(tmpdir, "readall-XXXXXX")))
  local a = fs.join(dir, "a.tl")
  local b = fs.join(dir, "b.tl")
  write(a, [[
return {
  ["z-late"] = {file = "f", find = "x", replace = "y", note = "n"},
}
]])
  write(b, [[
return {
  ["a-early"] = {file = "f", find = "p", replace = "q", note = "n"},
}
]])
  local edits = check.must(patch.read_all({a, b}))
  assert(#edits == 2, "entries from both files are merged")
  assert(edits[1].name == "a-early" and edits[2].name == "z-late",
    "the merged set is in sorted-name order across files")

  write(b, [[
return {
  ["z-late"] = {file = "f", find = "p", replace = "q", note = "n"},
}
]])
  local dup, derr = patch.read_all({a, b})
  assert(dup == nil and derr:find("one namespace", 1, true)
    and derr:find("a.tl", 1, true) and derr:find("b.tl", 1, true),
    "a duplicate entry name names both files: " .. tostring(derr))
end

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
