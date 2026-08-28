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

local function test_package_path_does_not_override_an_embedded_module()
  local NAME = "cosmic.string"
  local dir = check.must(fs.temp_dir(fs.join(tmpdir, "shadow-XXXXXX")))
  local shadow = fs.join(dir, "cosmic", "string.lua")
  write(shadow, 'return {SCRATCH_MARKER = "shadow"}\n')
  local saved_module = package.loaded[NAME]
  local saved_path = package.path
  package.path = fs.join(dir, "?.lua") .. ";" .. package.path
  local named = package.searchpath(NAME, package.path)
  package.loaded[NAME] = nil
  local got = require(NAME)
  package.loaded[NAME] = saved_module
  package.path = saved_path
  assert(named == shadow,
    "package.path names the shadow first: " .. tostring(named))
  if not (got is {string: any}) then
    error("cosmic.string did not load as a table") -- throws: a test refusal
  end
  assert(got["SCRATCH_MARKER"] == nil,
    "require ignored package.path and loaded the embedded module")
end

local FIXTURE_MODULE < const > = "_make_patch_probe_fixture"

-- A pin carrying one applied entry: `m.lua` holds
-- `return {v = "patched"}`, which the entry reverses to `"stock"`.
local function probe_fixture(): string, string
  local dir = check.must(fs.temp_dir(fs.join(tmpdir, "reverse-XXXXXX")))
  local pin = fs.join(dir, "x_pin.tl")
  write(pin, "return {}\n")
  write(fs.join(dir, "x_patch.tl"), [==[
return {
  ["swap-v"] = {
    file = "m.lua",
    find = [=====[return {v = "stock"}]=====],
    replace = [=====[return {v = "patched"}]=====],
    note = "fixture",
  },
}
]==])
  write(fs.join(dir, "m.lua"), 'return {v = "stock"}\n')
  local edits = check.must(patch.read_all(check.must(patch.paths_of_pin(pin))))
  assert(patch.apply(dir, edits))
  return dir, pin
end

local function test_reverse_loads_the_reversed_copy()
  local dir, pin = probe_fixture()
  local patched = check.must(fs.read(fs.join(dir, "m.lua")))
  assert(patched:find("patched", 1, true), "the fixture starts patched")
  local raw, err = patch.reverse({
      pin = pin,
      dir = dir,
      entries = {"swap-v"},
      file = "m.lua",
      module_name = FIXTURE_MODULE,
    })
  if not (raw is {string: any}) then
    error("reverse: " .. tostring(err)) -- throws: a test refusal
  end
  assert(raw["v"] == "stock", "the loaded copy is the unpatched text")
  assert(package.loaded[FIXTURE_MODULE] == raw,
    "reverse installs the module it returns")
  assert(check.must(fs.read(fs.join(dir, "m.lua"))) == patched,
    "reverse copies: the unpack directory keeps its patched bytes")
  package.loaded[FIXTURE_MODULE] = nil
end

local function test_reverse_refuses_unknown_and_mismatched_entries()
  local dir, pin = probe_fixture()
  local empty, eerr = patch.reverse({
      pin = pin, dir = dir, entries = {}, file = "m.lua",
      module_name = FIXTURE_MODULE,
    })
  assert(empty == nil and eerr:find("at least one entry", 1, true),
    "an empty entry list is refused: " .. tostring(eerr))

  local unknown, uerr = patch.reverse({
      pin = pin, dir = dir, entries = {"no-such-entry"}, file = "m.lua",
      module_name = FIXTURE_MODULE,
    })
  assert(unknown == nil and uerr:find("no-such-entry", 1, true)
    and uerr:find("not declared by", 1, true),
    "an undeclared entry name is refused: " .. tostring(uerr))

  local wrong, werr = patch.reverse({
      pin = pin, dir = dir, entries = {"swap-v"}, file = "other.lua",
      module_name = FIXTURE_MODULE,
    })
  assert(wrong == nil and werr:find("swap-v", 1, true)
    and werr:find("targets m.lua", 1, true),
    "an entry targeting another file is refused: " .. tostring(werr))
  assert(package.loaded[FIXTURE_MODULE] == nil, "a refusal installs nothing")
end

local function test_reverse_flips_the_checker_on_the_real_pin()
  local teal = require("cosmic.teal")
  local src = [==[
local record R
  x: integer
end
local function f(r: R | nil): integer
  if not r then
    return 0
  end
  return r.x
end
return f
]==]
  local shipped = teal.check(src, {chunk_name = "snippet.tl"})
  assert(#shipped.errors == 0,
    "the carried entry narrows `not r`: " .. tostring(#shipped.errors) ..
    " error(s)")

  local saved = package.loaded["tl"]
  local raw, rerr = patch.reverse({
      pin = "3p/tl/tl_pin.tl",
      dir = "o/3p/tl",
      entries = {"narrow-truthiness"},
      file = "tl.lua",
      module_name = "tl",
    })
  local messages: {string} = {}
  if raw ~= nil then
    for _, issue in ipairs(teal.check(src, {chunk_name = "snippet.tl"}).errors) do
      messages[#messages + 1] = issue.message
    end
  end
  package.loaded["tl"] = saved
  assert(raw ~= nil, "reverse: " .. tostring(rerr))
  assert(#messages >= 1, "the reversed checker refuses the index")
  local joined = table.concat(messages, "\n")
  assert(joined:find("cannot index key", 1, true),
    "the reversed error names the failed index: " .. joined)
end
