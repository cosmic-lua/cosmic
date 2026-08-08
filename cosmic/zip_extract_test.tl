#!/usr/bin/env cosmic
--- Tests for cosmic.zip extract(): safe extraction to a directory,
--- zip-slip rejection, and size limits. Split from zip_test.tl to keep
--- both under the file-length limit.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local str = require("cosmic.string")
local zip = require("cosmic.zip")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local function zip_path(name: string): string
  return fs.join(TEST_TMPDIR, name)
end

-- extract(): safe extraction to a directory

local function test_extract_basic()
  local p = zip_path("extract_basic.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("top.txt", "top content"))
  assert(w:add("sub/dir/nested.txt", "nested content"))
  assert(w:add("run.sh", "#!/bin/sh\n", {mode = tonumber("755", 8)}))
  w:close()

  local r = check.must(zip.open(p))
  local dest = zip_path("extract_basic_out")
  local ok, err = zip.extract(r, dest)
  r:close()
  assert(ok, "extract should succeed: " .. tostring(err))

  assert(fs.read(fs.join(dest, "top.txt")) == "top content", "top.txt should round-trip")
  assert(fs.read(fs.join(dest, "sub/dir/nested.txt")) == "nested content", "nested file should round-trip")
  local st = check.must(fs.stat(fs.join(dest, "run.sh")), "run.sh should exist")
  local mode = st:mode() & tonumber("777", 8)
  assert(mode == tonumber("755", 8), "mode from the archive should apply, got " .. string.format("%o", mode))
end
test_extract_basic()

-- Craft an archive with a traversal entry. cosmic's own zip writer refuses
-- ".." names, so write a same-length placeholder name and byte-patch it
-- (no offsets change, so the zip stays valid): "XX/escaped.txt" ->
-- "../escaped.txt".
local function crafted_archive(patch_to: string): string
  local safe = zip_path("crafted_" .. patch_to:gsub("%W", "_") .. ".zip")
  local w = check.must(zip.open(safe, {mode = "write"}))
  assert(w:add("good.txt", "innocent"))
  assert(w:add("XX/escaped.txt", "pwned"))
  w:close()
  local raw = check.must(fs.read(safe))
  assert(#patch_to == #"XX/escaped.txt", "patch must preserve name length")
  local patched = str.replace(raw, "XX/escaped.txt", patch_to)
  return patched
end

local function test_extract_rejects_traversal()
  local data = crafted_archive("../escaped.txt")
  local r = check.must(zip.open_string(data))
  local dest = zip_path("traversal_out")
  local ok, err = zip.extract(r, dest)
  r:close()

  assert(not ok, "extract should reject a ../ entry")
  assert(err and err:match("unsafe path"), "expected unsafe path error, got: " .. tostring(err))
  -- Nothing may be written: not the escaping file, and not the innocent
  -- entry either (validation runs before any writes).
  assert(not fs.is_present(fs.join(TEST_TMPDIR, "escaped.txt")), "escaping file must not be written")
  assert(not fs.is_present(dest), "destination must stay untouched on rejection")
end
test_extract_rejects_traversal()

local function test_extract_rejects_absolute()
  local data = crafted_archive("/e/escaped.txt")
  local r = check.must(zip.open_string(data))
  local dest = zip_path("absolute_out")
  local ok, err = zip.extract(r, dest)
  r:close()

  assert(not ok, "extract should reject an absolute entry")
  assert(err and err:match("unsafe path"), "expected unsafe path error, got: " .. tostring(err))
  assert(not fs.is_present(dest), "destination must stay untouched on rejection")
end
test_extract_rejects_absolute()

local function test_extract_rejects_backslash_traversal()
  local data = crafted_archive("..\\escaped.txt")
  local r = check.must(zip.open_string(data))
  local dest = zip_path("backslash_out")
  local ok, err = zip.extract(r, dest)
  r:close()

  assert(not ok, "extract should reject a ..\\ entry")
  assert(err and err:match("unsafe path"), "expected unsafe path error, got: " .. tostring(err))
end
test_extract_rejects_backslash_traversal()

-- A control character in a member name does not escape the destination,
-- and is refused anyway: the name travels onward into line-oriented
-- records -- `--make fetch`'s unpack manifest is one line per product --
-- where an embedded newline records one file as two names that do not
-- exist, so every later fetch decides the pin needs repair. Forever,
-- silently. `cosmic.tar` and `cosmic.embed` refuse the same class at
-- the same point; the three guards protect one operation.
local function test_extract_rejects_control_characters()
  local data = crafted_archive("\nX/escaped.txt")
  local r = check.must(zip.open_string(data))
  local dest = zip_path("control_out")
  local ok, err = zip.extract(r, dest)
  r:close()

  assert(not ok, "extract should reject a name with a control character")
  assert(err and err:match("unsafe path"),
    "expected unsafe path error, got: " .. tostring(err))
end
test_extract_rejects_control_characters()

local function test_extract_max_file_size()
  local p = zip_path("extract_size.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("small.txt", "ok"))
  assert(w:add("big.txt", string.rep("x", 4096)))
  w:close()

  local r = check.must(zip.open(p))
  local dest = zip_path("size_out")
  local ok, err = zip.extract(r, dest, {max_file_size_bytes = 1024})
  r:close()

  assert(not ok, "extract should reject oversized entries")
  assert(err and err:match("max_file_size_bytes"), "expected size error, got: " .. tostring(err))
  assert(not fs.is_present(fs.join(dest, "small.txt")), "no partial output on size rejection")
end
test_extract_max_file_size()

local function test_extract_from_path()
  local p = zip_path("extract_path.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("via_path.txt", "by path"))
  w:close()

  local dest = zip_path("extract_path_out")
  local ok, err = zip.extract(p, dest)
  assert(ok, "extract from a path should succeed: " .. tostring(err))
  assert(fs.read(fs.join(dest, "via_path.txt")) == "by path",
    "path-form extract should round-trip content")

  local bad_ok, bad_err = zip.extract(zip_path("no_such.zip"), dest)
  assert(not bad_ok, "extract from a missing path should fail")
  assert(bad_err and bad_err:find("cannot open", 1, true),
    "error should say the open failed, got: " .. tostring(bad_err))
end
test_extract_from_path()
