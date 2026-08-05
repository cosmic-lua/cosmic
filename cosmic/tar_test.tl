#!/usr/bin/env cosmic
-- Tests for the in-process tar extractor. Archives are built
-- in-process — no host tar — so the tests exercise exactly the ustar/pax
-- shapes the extractor claims to handle, plus its rejection paths.

local compress = require("cosmic.compress")
local fs = require("cosmic.fs")
local check = require("cosmic.check")
local fs_types = require("cosmic.fs.types")
local untar = require("cosmic.tar")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local BLOCK = 512

local function oct(s: string): integer
  return tonumber(s, 8) as integer -- cast: octal digits parse integral
end

local function pad(s: string, len: integer): string
  return s .. string.rep("\0", len - #s)
end

local function tar_header(name: string, mode: integer, size: integer,
    typeflag: string, linkname: string): string
  local h = pad(name, 100)
  .. pad(string.format("%07o", mode), 8)
  .. pad("0000000", 8) -- uid
  .. pad("0000000", 8) -- gid
  .. pad(string.format("%011o", size), 12)
  .. pad("00000000000", 12) -- mtime
  .. "        " -- checksum placeholder: 8 spaces while summing
  .. typeflag
  .. pad(linkname, 100)
  .. pad("ustar", 6)
  .. "00"
  h = pad(h, BLOCK)
  local sum = 0
  for i = 1, BLOCK do
    sum = sum + h:byte(i)
  end
  return h:sub(1, 148) .. string.format("%06o\0 ", sum) .. h:sub(157)
end

local function tar_entry(name: string, content: string, mode: integer,
    typeflag: string, linkname: string): string
  local out = tar_header(name, mode, #content, typeflag, linkname)
  if #content > 0 then
    local blocks = math.ceil(#content / BLOCK)
    out = out .. content .. string.rep("\0", blocks * BLOCK - #content)
  end
  return out
end

local function make_targz(path: string, parts: {string})
  local archive = table.concat(parts) .. string.rep("\0", 2 * BLOCK)
  local gz = check.must(compress.compress(archive, {format = "gzip"}))
  assert(fs.write(path, gz))
end

local function test_extract_files_dirs_modes()
  local dest = fs.join(tmpdir, "untar-basic")
  local ar = fs.join(tmpdir, "basic.tar.gz")
  make_targz(ar, {
      tar_entry("pkg/", "", oct("755"), "5", ""),
      tar_entry("pkg/tool", "#!/bin/sh\necho hi\n", oct("755"), "0", ""),
      tar_entry("pkg/doc.txt", "docs\n", oct("644"), "0", ""),
    })
  local ok, err = untar.extract(ar, dest)
  assert(ok, "extract failed: " .. tostring(err))
  assert(fs.read(fs.join(dest, "pkg/doc.txt")) == "docs\n", "doc content")
  assert(fs.read(fs.join(dest, "pkg/tool")) == "#!/bin/sh\necho hi\n", "tool content")
  local st = fs.stat(fs.join(dest, "pkg/tool"))
  assert(st, "tool should stat")
  -- exec bit survives extraction (the reason unzip/tar mattered at all)
  local mode = (st as fs_types.Stat):mode() -- cast: mixed-representation Stat
  assert(mode % 2 == 1, "tool should keep the exec bit, mode: " .. string.format("%o", mode))
end
test_extract_files_dirs_modes()

-- A pax record's length prefix counts the whole record including itself:
-- iterate to the fixpoint (the digit count can shift the total).
local function pax_record(key: string, value: string): string
  local rec = key .. "=" .. value .. "\n"
  local len = #rec
  while true do
    local total = #tostring(len) + 1 + #rec
    if total == len then break end
    len = total
  end
  local out = string.format("%d %s", len, rec)
  assert(#out == len, "pax record length must be self-consistent")
  return out
end

local function test_pax_path_override()
  local dest = fs.join(tmpdir, "untar-pax")
  local ar = fs.join(tmpdir, "pax.tar.gz")
  local long = "deeply/nested/directory/holding/a-rather-long-name.txt"
  local pax = pax_record("path", long)
  make_targz(ar, {
      tar_entry("PaxHeaders/ignored", pax, oct("644"), "x", ""),
      tar_entry("short-name", "payload\n", oct("644"), "0", ""),
    })
  local ok, err = untar.extract(ar, dest)
  assert(ok, "pax extract failed: " .. tostring(err))
  assert(fs.read(fs.join(dest, long)) == "payload\n", "pax path override should win")
  assert(not fs.stat(fs.join(dest, "short-name")), "header name must not also be written")
end
test_pax_path_override()

local function test_symlink_entry()
  local dest = fs.join(tmpdir, "untar-link")
  local ar = fs.join(tmpdir, "link.tar.gz")
  make_targz(ar, {
      tar_entry("real.txt", "target\n", oct("644"), "0", ""),
      tar_entry("alias.txt", "", oct("777"), "2", "real.txt"),
    })
  local ok, err = untar.extract(ar, dest)
  assert(ok, "symlink extract failed: " .. tostring(err))
  assert(fs.readlink(fs.join(dest, "alias.txt")) == "real.txt", "symlink target")
end
test_symlink_entry()

local function test_rejects_traversal()
  local dest = fs.join(tmpdir, "untar-evil")
  local ar = fs.join(tmpdir, "evil.tar.gz")
  make_targz(ar, {
      tar_entry("../evil.txt", "boom\n", oct("644"), "0", ""),
    })
  local ok, err = untar.extract(ar, dest)
  assert(not ok, "traversal entry must be rejected")
  assert(err and err:match("unsafe path"), "expected unsafe path error, got: " .. tostring(err))
end
test_rejects_traversal()

local function test_rejects_absolute_symlink_target()
  local dest = fs.join(tmpdir, "untar-evil-link")
  local ar = fs.join(tmpdir, "evil-link.tar.gz")
  make_targz(ar, {
      tar_entry("alias", "", oct("777"), "2", "/etc/passwd"),
    })
  local ok, err = untar.extract(ar, dest)
  assert(not ok, "absolute symlink target must be rejected")
  assert(err and err:match("unsafe symlink"), "expected unsafe symlink error, got: " .. tostring(err))
end
test_rejects_absolute_symlink_target()

local function test_rejects_bad_checksum()
  local dest = fs.join(tmpdir, "untar-badsum")
  local ar = fs.join(tmpdir, "badsum.tar.gz")
  local entry = tar_entry("ok.txt", "fine\n", oct("644"), "0", "")
  -- flip a name byte after the checksum was computed
  local corrupt = "X" .. entry:sub(2)
  make_targz(ar, {corrupt})
  local ok, err = untar.extract(ar, dest)
  assert(not ok, "corrupt header must be rejected")
  assert(err and err:match("checksum"), "expected checksum error, got: " .. tostring(err))
end
test_rejects_bad_checksum()

local function test_rejects_truncated_archive()
  local dest = fs.join(tmpdir, "untar-trunc")
  local ar = fs.join(tmpdir, "trunc.tar.gz")
  local entry = tar_entry("big.txt", string.rep("a", 600), oct("644"), "0", "")
  -- header claims 600 bytes; hand extract() only the header + 100 bytes
  local gz = check.must(compress.compress(entry:sub(1, BLOCK + 100), {format = "gzip"}))
  assert(fs.write(ar, gz))
  local ok, err = untar.extract(ar, dest)
  assert(not ok, "truncated archive must be rejected")
  assert(err and err:match("truncated"), "expected truncated error, got: " .. tostring(err))
end
test_rejects_truncated_archive()

local function test_rejects_unknown_entry_type()
  local dest = fs.join(tmpdir, "untar-hardlink")
  local ar = fs.join(tmpdir, "hardlink.tar.gz")
  make_targz(ar, {
      tar_entry("hard", "", oct("644"), "1", "other"),
    })
  local ok, err = untar.extract(ar, dest)
  assert(not ok, "hardlink entry must be rejected loudly")
  assert(err and err:match("unsupported"), "expected unsupported error, got: " .. tostring(err))
end
test_rejects_unknown_entry_type()

-- A control character in an archive-controlled name has no legitimate
-- use, and a newline in one poisons every downstream format that
-- carries the name as a line (`--make fetch`'s unpack manifest is one).
local function test_rejects_control_characters_in_names()
  local dest = fs.join(tmpdir, "untar-ctrl")
  local ar = fs.join(tmpdir, "ctrl.tar.gz")
  make_targz(ar, {
      tar_entry("a\nb.txt", "x", oct("644"), "0", ""),
    })
  local ok, err = untar.extract(ar, dest)
  assert(not ok, "a newline in a member name must be refused")
  assert(err and err:match("unsafe"), "expected an unsafe-path error, got: " .. tostring(err))

  local link = fs.join(tmpdir, "ctrl-link.tar.gz")
  make_targz(link, {
      tar_entry("l", "", oct("777"), "2", "tar\ngeted"),
    })
  local lok, lerr = untar.extract(link, fs.join(tmpdir, "untar-ctrl-link"))
  assert(not lok, "a newline in a link target must be refused")
  assert(lerr and lerr:match("unsafe"), "expected an unsafe error, got: " .. tostring(lerr))
end
test_rejects_control_characters_in_names()

-- Falling off the end without the two zero blocks was accepted as
-- success, so a truncation landing on a 512-byte boundary after
-- decompression was a silent partial extraction: every entry so far
-- written, `true` returned, nothing to say the archive was cut.
local function test_truncated_archive_is_refused()
  local dest = fs.join(tmpdir, "untar-noterm")
  local path = fs.join(tmpdir, "noterm.tar.gz")
  -- make_targz appends the terminator; this writes the same entries
  -- without one, which is what a boundary-aligned truncation leaves.
  local body = tar_entry("a.txt", "one\n", oct("644"), "0", "") ..
  tar_entry("b.txt", "two\n", oct("644"), "0", "")
  assert(fs.write(path, (check.must(compress.compress(body, {format = "gzip"})))))

  fs.remove_all(dest)
  local ok, err = untar.extract(path, dest)
  assert(not ok, "an unterminated archive must be refused")
  assert(err and err:match("no end%-of%-archive"),
    "the message names the reason, got: " .. tostring(err))
end
test_truncated_archive_is_refused()

local function test_unsafe_path()
  assert(untar.unsafe_path(""), "empty")
  assert(untar.unsafe_path("/abs"), "absolute")
  assert(untar.unsafe_path("a/../b"), "dotdot")
  -- Backslash policy is now the shared guard's (fs.unsafe_entry_name):
  -- a backslash is a SEPARATOR for the traversal check, not a blanket
  -- refusal, matching zip and embed. `a\\b` is a legal (weird) name;
  -- `..\\evil` is still traversal.
  assert(not untar.unsafe_path("a\\b"), "plain backslash name is a literal file")
  assert(untar.unsafe_path("..\\evil"), "backslash traversal")
  assert(untar.unsafe_path("a\\..\\evil"), "embedded backslash traversal")
  -- The sibling guard in cosmic.embed rejects drive letters, and these
  -- two protect the same operation: writing archive-controlled names
  -- under a dest. On POSIX `C:/evil.txt` is a literal `C:` directory;
  -- on Windows a colon component invites drive-relative and NTFS
  -- alternate-data-stream semantics.
  assert(untar.unsafe_path("C:/evil.txt"), "drive letter")
  assert(untar.unsafe_path("c:evil.txt"), "drive letter, no slash")
  assert(not untar.unsafe_path("a/b.txt"), "plain path is safe")
  assert(not untar.unsafe_path("ab:c.txt"), "a colon that is not a drive is fine")
end
test_unsafe_path()
