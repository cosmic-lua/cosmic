--- Proves the zip reader and writer against each other, and against a
--- fixture made once, ahead of time, by the system `zip` -- a mix of
--- stored and deflated entries and a symlink -- embedded as base64 so
--- this file has no binary bytes of its own and no test spawns an
--- external program.

local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")
local Zip = require("cosmic.zip")

local ZIP_B64 <const> =
  "UEsDBAoAAAAAADItN13z+cmLFAAAABQAAAANABwAc3JjL3Nob3J0LnR4dFVUCQADkGazapBms2p1eAsAAQQAAAAABAAAAABzaG9ydCBmaWxlIGNvbnRlbnRzClBLAwQKAAAAAAAyLTddI9j0uAkAAAAJAAAADgAcAHNyYy9hZGlyL2FsaW5rVVQJAAOQZrNqkGazanV4CwABBAAAAAAEAAAAAHNob3J0LnR4dFBLAwQUAAAACAA4LTdd0RXq2CAAAACZCAAACwAcAHNyYy9iaWcudHh0VVQJAAOcZrNqn2azanV4CwABBAAAAAAEAAAAAEtJTctJLElVyE1VSBlljjJHmaPMUeYoc5Q5yhxIJhcAUEsDBAoAAAAAADgtN13z+cmLFAAAABQAAAAUABwAc3JjL3Nob3J0X3N0b3JlZC50eHRVVAkAA5xms2qfZrNqdXgLAAEEAAAAAAQAAAAAc2hvcnQgZmlsZSBjb250ZW50cwpQSwECHgMKAAAAAAAyLTdd8/nJixQAAAAUAAAADQAYAAAAAAABAAAApIEAAAAAc3JjL3Nob3J0LnR4dFVUBQADkGazanV4CwABBAAAAAAEAAAAAFBLAQIeAwoAAAAAADItN10j2PS4CQAAAAkAAAAOABgAAAAAAAAAAAD/oVsAAABzcmMvYWRpci9hbGlua1VUBQADkGazanV4CwABBAAAAAAEAAAAAFBLAQIeAxQAAAAIADgtN13RFerYIAAAAJkIAAALABgAAAAAAAEAAACkgawAAABzcmMvYmlnLnR4dFVUBQADnGazanV4CwABBAAAAAAEAAAAAFBLAQIeAwoAAAAAADgtN13z+cmLFAAAABQAAAAUABgAAAAAAAAAAACkgREBAABzcmMvc2hvcnRfc3RvcmVkLnR4dFVUBQADnGazanV4CwABBAAAAAAEAAAAAFBLBQYAAAAABAAEAFIBAABzAQAAAAA="

--- Every entry of `r`, which has no reason to fail here.
local function entries_of(r: Zip.Reader): {Zip.Entry}
  return (assert(r:entries()))
end

local function by_path(entries: {Zip.Entry}, path: string): Zip.Entry
  for _, e in ipairs(entries) do
    if e.path == path then return e end
  end
  error("no such entry: " .. path, 2)
end

local function test_writer_and_reader_roundtrip_stored_files_and_dirs()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_dir("adir", { mode = 0x1c0 }))
  assert(w:add_file("adir/short.txt", "hello there", { method = "store" }))
  assert(w:close())

  local r = assert(Zip.open_string(c:result()))
  local entries = assert(r:entries())
  assert(#entries == 2, tostring(#entries))
  local dir = by_path(entries, "adir/")
  assert(dir.kind == "dir")
  local file = by_path(entries, "adir/short.txt")
  assert(file.kind == "file" and file.method == 0 and file.size == 11)
  local body = assert(Stream.read_all((assert(file:open()))))
  assert(body == "hello there")
end

local function test_deterministic_mode_uses_the_1980_epoch()
  local c = Stream.collect()
  local w = Zip.writer(c, { deterministic = true })
  assert(w:add_file("f", "x", { method = "store", mtime = 1700000000 }))
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  local entry = by_path(entries_of(r), "f")
  -- 1980-01-01T00:00:00Z
  assert(entry.mtime == 315532800, tostring(entry.mtime))
end

--- A method outside Zip.Method reaches add_file only past the checker
--- (a cast, or plain Lua); the writer refuses it rather than guessing.
local function test_an_unknown_method_is_refused()
  local w = Zip.writer(Stream.collect(), { deterministic = true })
  local ok, trouble = w:add_file("f", "x", { method = "zstd" as Zip.Method })
  assert(not ok and trouble == "zip: unknown method 'zstd'", trouble)
end

local function test_mode_bits_round_trip_through_external_attributes()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("exe", "x", { method = "store", mode = 0x1ff }))
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  local entry = by_path(entries_of(r), "exe")
  assert(entry.mode == 0x1ff, string.format("%o", entry.mode))
end

local function test_a_corrupt_body_fails_its_crc_check()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("f", "hello", { method = "store" }))
  assert(w:close())
  local raw = c:result()
  -- flip a byte inside the stored payload, which sits right after the
  -- local header and its 1-byte name
  local at = raw:find("hello", 1, true)
  local corrupt = raw:sub(1, at - 1) .. "x" .. raw:sub(at + 1)
  local r = assert(Zip.open_string(corrupt))
  local entry = by_path(entries_of(r), "f")
  local reader = assert(entry:open())
  local data, trouble = Stream.read_all(reader)
  assert(data == nil and trouble:find("crc32", 1, true) ~= nil, trouble)
end

local function test_a_stream_without_an_eocd_is_refused()
  local r, trouble = Zip.open_string("not a zip file at all")
  assert(r == nil and trouble:find("end of central directory", 1, true) ~= nil, trouble)
end

local function test_open_reads_a_zip_from_a_path(tmp: string)
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("f", "on disk", { method = "store" }))
  assert(w:close())
  local path = tmp .. "/archive.zip"
  assert(Fs.write(path, c:result()))
  local r = assert(Zip.open(path))
  local entry = by_path(entries_of(r), "f")
  assert(Stream.read_all((assert(entry:open()))) == "on disk")
  assert(r:close())
end

local function test_writer_and_reader_roundtrip_a_deflated_file()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("f", "hello there, deflated", { method = "deflate" }))
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  local entry = by_path(entries_of(r), "f")
  assert(entry.method == 8, tostring(entry.method))
  local body = assert(Stream.read_all((assert(entry:open()))))
  assert(body == "hello there, deflated")
end

local function test_a_system_made_deflated_entry_reads_back()
  local raw = assert(Codec.unbase64(ZIP_B64))
  local r = assert(Zip.open_string(raw))
  local entry = by_path(entries_of(r), "src/big.txt")
  assert(entry.method == 8)
  local data = assert(Stream.read_all((assert(entry:open()))))
  assert(#data == entry.size)
  assert(data:find("deflate me", 1, true) ~= nil)
end

local function test_a_system_made_zip_fixture_lists_its_stored_entries()
  local raw = assert(Codec.unbase64(ZIP_B64))
  local r = assert(Zip.open_string(raw))
  local entries = assert(r:entries())
  assert(#entries == 4, tostring(#entries))
  local short = by_path(entries, "src/short.txt")
  assert(short.method == 0)
  assert(Stream.read_all((assert(short:open()))) == "short file contents\n")
  local link = by_path(entries, "src/adir/alink")
  assert(link.method == 0)
  assert(Stream.read_all((assert(link:open()))) == "short.txt")
  local stored = by_path(entries, "src/short_stored.txt")
  assert(Stream.read_all((assert(stored:open()))) == "short file contents\n")
end

local function le16(n: integer): string
  return string.char(n & 0xFF, (n >> 8) & 0xFF)
end

local function le32(n: integer): string
  return le16(n & 0xFFFF) .. le16((n >> 16) & 0xFFFF)
end

local function le64(n: integer): string
  return le32(n & 0xFFFFFFFF) .. le32((n >> 32) & 0xFFFFFFFF)
end

local function rd32(s: string, at: integer): integer
  return s:byte(at) | (s:byte(at + 1) << 8) | (s:byte(at + 2) << 16) | (s:byte(at + 3) << 24)
end

local function patch(s: string, at: integer, bytes: string): string
  return s:sub(1, at - 1) .. bytes .. s:sub(at + #bytes)
end

--- Three small stored entries, and the 1-based position of the end of
--- central directory record in them.
local function three_entry_zip(): string, integer
  local c = Stream.collect()
  local w = Zip.writer(c)
  for i = 0, 2 do assert(w:add_file("f" .. tostring(i), "data" .. tostring(i), { method = "store" })) end
  assert(w:close())
  local raw = c:result()
  local eocd = assert(raw:find("PK\5\6", 1, true))
  return raw, eocd
end

local function test_more_than_65535_entries_round_trip_through_zip64()
  local c = Stream.collect()
  local w = Zip.writer(c, { deterministic = true })
  local n = 70000
  for i = 1, n do assert(w:add_file("f" .. tostring(i), "", { method = "store" })) end
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  local entries = assert(r:entries())
  assert(#entries == n, tostring(#entries))
  assert(entries[n].path == "f" .. tostring(n))
end

local function test_local_header_offsets_past_4_gib_go_in_zip64_extra_fields(tmp: string)
  local sys = require("cosmic.sys")
  local base = 5 << 30
  local c = Stream.collect()
  local w = Zip.writer(c, { offset = base })
  assert(w:add_file("a", "first body", { method = "store" }))
  assert(w:add_file("b", string.rep("deflate me ", 50)))
  assert(w:close())
  local raw = c:result()
  -- every central header points past 4 GiB, so each says 0xFFFFFFFF
  -- and carries the real offset in a zip64 extra field
  local cd = assert(raw:find("PK\1\2", 1, true))
  assert(rd32(raw, cd + 42) == 0xFFFFFFFF)
  assert(raw:find("\1\0\8\0" .. le64(base), cd, true) ~= nil)
  assert(raw:find("PK\6\6", 1, true) ~= nil, "no zip64 end record")
  -- and a file holding the zip past 5 GiB of (sparse) leading bytes
  -- reads back through them
  local path = tmp .. "/far.zip"
  local fd = assert(Fs.open_write(path))
  assert(sys.lseek(fd, base, sys.SEEK_SET) == base)
  assert(Fs.put(fd, raw))
  assert(Fs.close(fd))
  local r = assert(Zip.open(path))
  local entries = assert(r:entries())
  assert(#entries == 2)
  assert(Stream.read_all((assert(by_path(entries, "a"):open()))) == "first body")
  assert(Stream.read_all((assert(by_path(entries, "b"):open()))) == string.rep("deflate me ", 50))
  assert(r:close())
end

local function test_a_central_directory_outside_the_file_is_refused()
  local raw, eocd = three_entry_zip()
  local moved = patch(raw, eocd + 16, le32(100000000))
  local r, trouble = Zip.open_string(moved)
  assert(r == nil and trouble:find("outside", 1, true) ~= nil, trouble)
end

local function test_a_shortened_central_directory_is_refused()
  local raw, eocd = three_entry_zip()
  local size = rd32(raw, eocd + 12)
  local r, trouble = Zip.open_string(patch(raw, eocd + 12, le32(size - 10)))
  assert(r == nil and trouble ~= "", "a short central directory was accepted")
end

local function test_an_entry_count_disagreeing_with_the_central_directory_is_refused()
  local raw, eocd = three_entry_zip()
  local r, trouble = Zip.open_string(patch(raw, eocd + 8, le16(2) .. le16(2)))
  assert(r == nil and trouble:find("holds 3 entries", 1, true) ~= nil, trouble)
end

local function test_a_huge_zip64_central_directory_size_is_refused()
  local raw, eocd = three_entry_zip()
  local cd_offset = rd32(raw, eocd + 16)
  local body = raw:sub(1, eocd - 1)
  local z64 = #body
  local forged = body ..
    "PK\6\6" .. le64(44) .. le16(45) .. le16(45) .. le32(0) .. le32(0) ..
    le64(3) .. le64(3) .. le64(1 << 40) .. le64(cd_offset) ..
    "PK\6\7" .. le32(0) .. le64(z64) .. le32(1) ..
    "PK\5\6" .. le16(0) .. le16(0) .. le16(0xFFFF) .. le16(0xFFFF) ..
    le32(0xFFFFFFFF) .. le32(0xFFFFFFFF) .. le16(0)
  local r, trouble = Zip.open_string(forged)
  assert(r == nil and trouble:find("outside", 1, true) ~= nil, trouble)
end

local function test_a_zip64_size_past_2_63_is_refused_at_open()
  -- One empty stored entry whose central header puts the sentinel in
  -- one of its three 32-bit fields, and whose zip64 field holds 2^63
  -- for it: no value a Lua integer can hold, so it would read back
  -- negative -- a size listed below zero, or an offset that pread
  -- counts from the end of the archive.
  local lfh = "PK\3\4" .. le16(20) .. le16(0) .. le16(0) .. le16(0) .. le16(0) .. le32(0) ..
    le32(0) .. le32(0) .. le16(1) .. le16(0) .. "a"
  local extra = le16(1) .. le16(8) .. le64(1 << 63)
  for _, which in ipairs({ "usize", "csize", "offset" }) do
    local csize = which == "csize" and 0xFFFFFFFF or 0
    local usize = which == "usize" and 0xFFFFFFFF or 0
    local offset = which == "offset" and 0xFFFFFFFF or 0
    local cdfh = "PK\1\2" .. le16(20) .. le16(20) .. le16(0) .. le16(0) .. le16(0) .. le16(0) ..
      le32(0) .. le32(csize) .. le32(usize) .. le16(1) .. le16(#extra) .. le16(0) .. le16(0) ..
      le16(0) .. le32(0) .. le32(offset) .. "a" .. extra
    local eocd = "PK\5\6" .. le16(0) .. le16(0) .. le16(1) .. le16(1) .. le32(#cdfh) ..
      le32(#lfh) .. le16(0)
    local r, trouble = Zip.open_string(lfh .. cdfh .. eocd)
    assert(r == nil and trouble:find("zip64", 1, true) ~= nil, which .. ": " .. tostring(trouble))
  end
end

local function test_an_entry_past_the_end_of_the_archive_is_refused_at_open(tmp: string)
  -- One empty stored entry whose central header puts its local header,
  -- or its compressed body, into the central directory or past the
  -- archive's end: in the header's own 32-bit fields, or in a zip64
  -- field (an offset just short of 2^63, which pread refuses as a bare
  -- "Invalid argument").
  local lfh = "PK\3\4" .. le16(20) .. le16(0) .. le16(0) .. le16(0) .. le16(0) .. le32(0) ..
    le32(0) .. le32(0) .. le16(1) .. le16(0) .. "a"
  local cases: {{string, integer, integer, integer}} = {
    { "offset into the central directory", 0, #lfh, -1 },
    { "32-bit offset", 0, 0xFFFFFFFE, -1 },
    { "32-bit csize", 1000, 0, -1 },
    { "zip64 offset", 0, 0xFFFFFFFF, math.maxinteger - 10 },
    { "zip64 csize", 0xFFFFFFFF, 0, 1 << 40 },
  }
  for i, case in ipairs(cases) do
    local which, csize, offset, wide = case[1], case[2], case[3], case[4]
    local extra = wide >= 0 and le16(1) .. le16(8) .. le64(wide) or ""
    local cdfh = "PK\1\2" .. le16(20) .. le16(20) .. le16(0) .. le16(0) .. le16(0) .. le16(0) ..
      le32(0) .. le32(csize) .. le32(0) .. le16(1) .. le16(#extra) .. le16(0) .. le16(0) ..
      le16(0) .. le32(0) .. le32(offset) .. "a" .. extra
    local eocd = "PK\5\6" .. le16(0) .. le16(0) .. le16(1) .. le16(1) .. le32(#cdfh) ..
      le32(#lfh) .. le16(0)
    local raw = lfh .. cdfh .. eocd
    local r, trouble = Zip.open_string(raw)
    assert(r == nil and trouble:find("runs past", 1, true) ~= nil,
      which .. ": " .. tostring(trouble))
    local path = tmp .. "/past" .. tostring(i) .. ".zip"
    assert(Fs.write(path, raw))
    r, trouble = Zip.open(path)
    assert(r == nil and trouble:find("runs past", 1, true) ~= nil,
      which .. " (path): " .. tostring(trouble))
  end
end

local function test_a_forged_end_record_inside_the_comment_is_not_taken_for_the_real_one()
  local raw = three_entry_zip()
  local fake = "PK\5\6" .. le16(0) .. le16(0) .. le16(0) .. le16(0) .. le32(0) .. le32(0) ..
    le16(0)
  local forged = raw:sub(1, #raw - 2) .. le16(#fake) .. fake
  local r = assert(Zip.open_string(forged))
  assert(#assert(r:entries()) == 3)
end

local function test_a_nul_byte_in_an_entry_name_is_refused()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("aXb", "x", { method = "store" }))
  assert(w:close())
  local raw = c:result():gsub("aXb", "a\0b")
  local r, trouble = Zip.open_string(raw)
  assert(r == nil and trouble:find("NUL", 1, true) ~= nil, trouble)
  local ok, wtrouble = Zip.writer(Stream.collect()):add_file("a\0b", "x")
  assert(not ok and wtrouble:find("NUL", 1, true) ~= nil, wtrouble)
end

-- Found by zip_fuzz_test.tl: a trailing `/` marks a directory, so a
-- file written under one read back as a directory.
local function test_a_file_path_ending_in_a_slash_is_refused()
  local w = Zip.writer(Stream.collect())
  local ok, trouble = w:add_file("a/", "x")
  assert(not ok and trouble:find("ends in /", 1, true) ~= nil, trouble)
  assert(w:add_file("a", "x"))
  assert(w:close())
end

local function test_an_entry_body_larger_than_its_recorded_size_fails_at_once()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("f", "hello world", { method = "store" }))
  assert(w:close())
  local raw = c:result()
  local cd = assert(raw:find("PK\1\2", 1, true))
  local lying = patch(raw, cd + 24, le32(5))
  local r = assert(Zip.open_string(lying))
  local body = assert(by_path(entries_of(r), "f"):open())
  local data, trouble = Stream.read_all(body)
  assert(data == nil and trouble:find("larger than its recorded size", 1, true) ~= nil, trouble)
end

local function test_entries_of_a_closed_reader_cannot_be_opened(tmp: string)
  local path = tmp .. "/a.zip"
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("f", "body", { method = "store" }))
  assert(w:close())
  assert(Fs.write(path, c:result()))
  local r = assert(Zip.open(path))
  local entries = assert(r:entries())
  assert(r:close())
  local body, trouble = entries[1]:open()
  assert(body == nil and trouble:find("closed", 1, true) ~= nil, trouble)
end

local function test_a_unix_symlink_entry_is_reported_as_a_symlink()
  local r = assert(Zip.open_string((assert(Codec.unbase64(ZIP_B64)))))
  local link = by_path(entries_of(r), "src/adir/alink")
  assert(link.kind == "symlink" and link.linkpath == "short.txt", link.kind)
  assert(by_path(entries_of(r), "src/short.txt").linkpath == "")
end

local function test_mtimes_past_2107_clamp_to_the_last_dos_time()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("y2200", "x", { mtime = 7258118400 }))
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  local mtime = by_path(entries_of(r), "y2200").mtime
  assert(mtime == 4354819198, tostring(mtime)) -- 2107-12-31 23:59:58
end

local function test_a_failed_write_aborts_the_zip_and_a_closed_writer_refuses_more(tmp: string)
  local w = Zip.writer(Stream.collect())
  assert(w:close())
  assert(w:close())
  local ok, trouble = w:add_file("late", "x")
  assert(not ok and trouble:find("closed", 1, true) ~= nil, trouble)
  local path = tmp .. "/out.zip"
  local zw = Zip.writer((assert(Stream.create(path))))
  assert(zw:add_file("f", "x"))
  assert(zw:abort())
  assert(Fs.exists(path) == false)
  local left = assert(Fs.list(tmp))
  assert(#left == 0, table.concat(left, ","))
end

local function test_next_walks_a_central_directory_many_windows_long()
  local c = Stream.collect()
  local w = Zip.writer(c, { deterministic = true })
  local n = 3000
  local prefix = string.rep("p", 40) .. "/"
  for i = 1, n do
    assert(w:add_file(prefix .. tostring(i), "body " .. tostring(i), { method = "store" }))
  end
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  local listed = assert(r:entries())
  assert(#listed == n)
  local count = 0
  while true do
    local e, trouble = r:next()
    if e == nil then
      assert(trouble == "", trouble)
      break
    end
    count = count + 1
    assert(e.path == prefix .. tostring(count), e.path)
    assert(e.path == listed[count].path)
    if count % 997 == 0 then
      assert(Stream.read_all((assert(e:open()))) == "body " .. tostring(count))
    end
  end
  assert(count == n, tostring(count))
end

--- A one-entry stored zip made by hand, whose local header carries an
--- extra field of `extra_len` bytes that the central directory's does
--- not.
local function zip_with_local_extra(name: string, body: string, extra_len: integer): string
  local crc = Compress.crc32(body)
  local extra = extra_len > 0 and (le16(0xCAFE) .. le16(extra_len - 4) ..
    string.rep("x", extra_len - 4)) or ""
  local lfh = "PK\3\4" .. le16(20) .. le16(0) .. le16(0) .. le16(0) .. le16(0x21) ..
    le32(crc) .. le32(#body) .. le32(#body) .. le16(#name) .. le16(#extra) .. name .. extra
  local cd = "PK\1\2" .. le16((3 << 8) | 20) .. le16(20) .. le16(0) .. le16(0) .. le16(0) ..
    le16(0x21) .. le32(crc) .. le32(#body) .. le32(#body) .. le16(#name) .. le16(0) ..
    le16(0) .. le16(0) .. le16(0) .. le32(0x81a40000) .. le32(0) .. name
  local cd_offset = #lfh + #body
  return lfh .. body .. cd .. "PK\5\6" .. le16(0) .. le16(0) .. le16(1) .. le16(1) ..
    le32(#cd) .. le32(cd_offset) .. le16(0)
end

local function test_bodies_read_back_whatever_the_local_extra_field_and_size()
  for _, extra_len in ipairs({ 0, 40, 300, 5000 }) do
    for _, size in ipairs({ 0, 1, 100, 70000 }) do
      local body = string.rep("z", size)
      local r = assert(Zip.open_string(zip_with_local_extra("f", body, extra_len)))
      local got = assert(r:next())
      local data, trouble = Stream.read_all((assert(got:open())))
      assert(data == body, tostring(extra_len) .. "/" .. tostring(size) .. ": " .. trouble)
    end
  end
end

local function test_next_reports_a_symlink_target()
  local r = assert(Zip.open_string((assert(Codec.unbase64(ZIP_B64)))))
  local found = false
  while true do
    local e = r:next()
    if e == nil then break end
    if e.path == "src/adir/alink" then
      assert(e.kind == "symlink" and e.linkpath == "short.txt", e.linkpath)
      found = true
    end
  end
  assert(found)
end

--- A Reader over `rounds` copies of `chunk`, that calls `each(n)` before
--- its n-th read.
local function repeating(chunk: string, rounds: integer, each?: function(integer)): Stream.Reader
  local n = 0
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, _max?: integer): string | nil, string
    if n >= rounds then return nil, "" end
    n = n + 1
    if each ~= nil then each(n) end
    return chunk, ""
  end
  r.close = function(_self: Stream.Reader): boolean, string return true, "" end
  return r
end

local function test_a_streamed_body_round_trips_through_the_reader()
  local chunk = "streamed body, "
  local whole = string.rep(chunk, 5000)
  for _, method in ipairs({ "deflate", "store" } as {Zip.Method}) do
    local c = Stream.collect()
    local w = Zip.writer(c)
    assert(w:add_file("a", repeating(chunk, 5000), { method = method }))
    assert(w:add_file("empty", Stream.from_string(""), { method = method, size = 0 }))
    assert(w:add_file("plain", "after a stream", { method = method }))
    assert(w:add_file("sized", Stream.from_string(whole), { method = method, size = #whole }))
    assert(w:close())
    local r = assert(Zip.open_string(c:result()))
    local entries = assert(r:entries())
    assert(#entries == 4)
    assert(Stream.read_all((assert(by_path(entries, "a"):open()))) == whole, method)
    assert(Stream.read_all((assert(by_path(entries, "empty"):open()))) == "", method)
    assert(Stream.read_all((assert(by_path(entries, "plain"):open()))) == "after a stream", method)
    assert(Stream.read_all((assert(by_path(entries, "sized"):open()))) == whole, method)
    local a = by_path(entries, "a")
    assert(a.size == #whole and a.crc32 == Compress.crc32(whole))
    assert(a.method == (method == "store" and 0 or 8))
    if method == "deflate" then assert(a.compressed_size < #whole // 10) end
  end
end

local function test_a_streamed_entry_carries_a_data_descriptor_after_its_body()
  local body = string.rep("descriptor ", 300)
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("d.txt", Stream.from_string(body), { method = "store" }))
  assert(w:add_file("s.txt", "string", { method = "store" }))
  assert(w:close())
  local bytes = c:result()
  -- The local header: bit 3 set, and no CRC or sizes.
  assert(bytes:sub(1, 4) == "PK\3\4")
  assert(rd32(bytes, 7) & 0xFFFF == 8, "general-purpose bit 3")
  assert(rd32(bytes, 15) == 0 and rd32(bytes, 19) == 0 and rd32(bytes, 23) == 0)
  -- The descriptor follows the body and repeats what the central
  -- directory records.
  local at = 31 + #"d.txt" + #body
  assert(bytes:sub(at, at + 3) == "PK\7\8", "data descriptor signature")
  assert(rd32(bytes, at + 4) == Compress.crc32(body))
  assert(rd32(bytes, at + 8) == #body and rd32(bytes, at + 12) == #body)
  local r = assert(Zip.open_string(bytes))
  local entry = by_path(entries_of(r), "d.txt")
  assert(entry.crc32 == rd32(bytes, at + 4) and entry.compressed_size == #body)
  -- A string body keeps its local header sizes and no descriptor.
  local s = by_path(entries_of(r), "s.txt")
  assert(rd32(bytes, s.offset + 7) & 0xFFFF == 0)
  assert(rd32(bytes, s.offset + 19) == 6)
end

--- Everything written to it, kept as a list of pieces; `close` and
--- `abort` are noted.
local function recording(): Stream.Writer, {string}
  local pieces: {string} = {}
  local w: Stream.Writer = {}
  w.write = function(_self: Stream.Writer, data: string): boolean, string
    pieces[#pieces + 1] = data
    return true, ""
  end
  w.close = function(_self: Stream.Writer): boolean, string return true, "" end
  w.abort = function(_self: Stream.Writer): boolean, string return true, "" end
  return w, pieces
end

local function test_a_streamed_size_of_2_gib_or_more_announces_zip64_up_front()
  local sink, pieces = recording()
  local w = Zip.writer(sink)
  -- The body is far shorter than it says, which fails the write, but
  -- only after the local header has gone out.
  local ok, trouble = w:add_file("big", Stream.from_string("short"),
    { method = "store", size = 1 << 32 })
  assert(not ok and trouble:find("not 4294967296", 1, true), trouble)
  local header = pieces[1]
  assert(header:sub(1, 4) == "PK\3\4")
  assert(rd32(header, 5) & 0xFFFF == 45, "version needed")
  assert(header:sub(-20, -17) == le16(1) .. le16(16), "a zip64 extra field of two sizes")
  -- With the field there, the header's own sizes are the sentinel.
  assert(rd32(header, 19) == 0xFFFFFFFF and rd32(header, 23) == 0xFFFFFFFF)
  assert(not w:close())
end

local function test_a_streamed_size_that_is_wrong_fails_the_write()
  for _, size in ipairs({ 4, 6 }) do
    local w = Zip.writer(Stream.collect())
    local ok, trouble = w:add_file("f", Stream.from_string("12345"), { size = size })
    assert(not ok and trouble:find("body is 5 bytes", 1, true), trouble)
    assert(not w:add_file("g", "x"))
    assert(not w:close())
  end
end

--- A size that no body could have is a mistake in the call, not a failure
--- of the write: it raises, and the writer stays usable.
local function test_a_streamed_size_below_zero_or_no_integer_raises()
  local w = Zip.writer(Stream.collect())
  for _, size in ipairs({ -1, 1.5 } as {number}) do
    local ok, why: boolean, any = pcall(function()
      local _, _ = w:add_file("f", Stream.from_string("abc"), { size = size as integer })
    end)
    assert(not ok and tostring(why):find("zip: opts.size must be an integer of at least 0", 1, true),
      tostring(why))
    assert(tostring(why):find("zip_test", 1, true), "blames the caller: " .. tostring(why))
  end
  -- Whatever the body, and before any other refusal of the call.
  for _, call in ipairs({
    function() local _, _ = w:add_file("f", "abc", { size = -1 }) end,
    function() local _, _ = w:add_file("dir/", "abc", { size = -1 }) end,
  } as {function()}) do
    local ok, why: boolean, any = pcall(call)
    assert(not ok and tostring(why):find("zip: opts.size must be an integer of at least 0", 1, true),
      tostring(why))
  end
  assert(w:add_file("g", "x"))
  assert(w:close())
end

local function test_a_failing_body_fails_and_aborts_the_writer()
  local w = Zip.writer(Stream.collect())
  local bad: Stream.Reader = {}
  bad.read = function(_self: Stream.Reader, _max?: integer): string | nil, string
    return nil, "disk on fire"
  end
  bad.close = function(_self: Stream.Reader): boolean, string return true, "" end
  local ok, trouble = w:add_file("f", bad)
  assert(not ok and trouble == "zip: add_file: disk on fire", trouble)
  ok, trouble = w:add_file("g", "x")
  assert(not ok and trouble == "zip: add_file: disk on fire", trouble)
end

local function test_a_streamed_body_takes_bounded_memory()
  local block = {} as {integer}
  for i = 1, 65536 do block[i] = (i * 131 + (i >> 8) + (i >> 3) * 7) & 255 end
  local pieces: {string} = {}
  for first = 1, #block, 4096 do
    pieces[#pieces + 1] = string.char(table.unpack(block, first, first + 4095))
  end
  local chunk = table.concat(pieces)
  local rounds = 48 -- 3 MiB through each method
  local warm = 6
  for _, method in ipairs({ "deflate", "store" } as {Zip.Method}) do
    local written = 0
    local sink: Stream.Writer = {}
    sink.write = function(_self: Stream.Writer, data: string): boolean, string
      written = written + #data
      return true, ""
    end
    sink.close = function(_self: Stream.Writer): boolean, string return true, "" end
    sink.abort = function(_self: Stream.Writer): boolean, string return true, "" end
    collectgarbage()
    collectgarbage()
    local base = collectgarbage("count")
    local early, late = 0.0, 0.0
    local body = repeating(chunk, rounds, function(n: integer)
      collectgarbage()
      local grown = collectgarbage("count") - base
      if n <= warm then early = math.max(early, grown) else late = math.max(late, grown) end
    end)
    local w = Zip.writer(sink)
    assert(w:add_file("big", body, { method = method }))
    assert(w:close())
    assert(written > 0 and (method == "deflate" or written > #chunk * rounds), method)
    assert(early < 512 and late < early + 128,
      ("%s grew %.0f KiB, then %.0f KiB, over %d KiB of input"):format(
        method, early, late, #chunk * rounds // 1024))
  end
end

local function test_a_symlink_round_trips_with_its_target_mode_and_time()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("a.txt", "hello"))
  assert(w:add_symlink("link", "a.txt", { mtime = 1700000000 }))
  assert(w:add_symlink("deep/link", "../a.txt", { mode = 0x1ed }))
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  local entries = entries_of(r)
  local link = by_path(entries, "link")
  assert(link.kind == "symlink" and link.linkpath == "a.txt", link.kind)
  assert(link.mode == 0x1ff and link.size == 5 and link.method == 0 and link.mtime == 1700000000)
  assert(by_path(entries, "deep/link").mode == 0x1ed)
  assert(by_path(entries, "deep/link").linkpath == "../a.txt")
  assert(by_path(entries, "a.txt").kind == "file" and by_path(entries, "a.txt").linkpath == "")
  -- `next` says the same of each entry.
  local seen: {string:string} = {}
  while true do
    local entry = r:next()
    if entry == nil then break end
    seen[entry.path] = entry.kind .. ":" .. entry.linkpath
  end
  assert(seen.link == "symlink:a.txt" and seen["a.txt"] == "file:")
end

local function test_a_symlink_a_reader_would_refuse_is_refused_when_added()
  local w = Zip.writer(Stream.collect())
  local ok, trouble = w:add_symlink("l", string.rep("t", 4097))
  assert(not ok and trouble:find("4097-byte target", 1, true) ~= nil, trouble)
  ok, trouble = w:add_symlink("l", "a\0b")
  assert(not ok and trouble:find("NUL", 1, true) ~= nil, trouble)
  ok, trouble = w:add_symlink("dir/", "x")
  assert(not ok and trouble:find("ends in /", 1, true) ~= nil, trouble)
  -- Each refusal is of an argument, not a failed write: the longest
  -- target a reader takes is still written, and the archive opens.
  assert(w:add_symlink("l", string.rep("t", 4096)))
  assert(w:close())
end

--- The Unix time of a UTC calendar moment.
local function unix(year: integer, month: integer, day: integer, hour: integer, minute: integer,
    second: integer): integer
  local ns = assert(Time.from_civil({
    year = year, month = month, day = day, hour = hour, minute = minute, second = second,
    ns = 0,
  }))
  return ns // 1000000000
end

--- A DOS date and time are only bits: those spelling no calendar day or
--- clock reading are clamped to the nearest there is, not carried over
--- into the next month or day.
local function test_a_dos_date_no_calendar_has_is_clamped()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("f", "x", { method = "store", mtime = 1700000000 }))
  assert(w:close())
  local raw = c:result()
  local header = (assert(raw:find("PK\1\2", 1, true)))
  local function mtime_of(year: integer, month: integer, day: integer, hour: integer,
      minute: integer, second: integer): integer
    local date = ((year - 1980) << 9) | (month << 5) | day
    local clock = (hour << 11) | (minute << 5) | (second // 2)
    local r = assert(Zip.open_string(patch(raw, header + 12, le16(clock) .. le16(date))))
    return entries_of(r)[1].mtime
  end
  assert(mtime_of(2021, 2, 31, 10, 20, 30) == unix(2021, 2, 28, 10, 20, 30))
  assert(mtime_of(2020, 2, 30, 10, 20, 30) == unix(2020, 2, 29, 10, 20, 30))
  assert(mtime_of(2021, 4, 31, 10, 20, 30) == unix(2021, 4, 30, 10, 20, 30))
  assert(mtime_of(2021, 13, 1, 10, 20, 30) == unix(2021, 12, 1, 10, 20, 30))
  assert(mtime_of(2021, 0, 0, 10, 20, 30) == unix(2021, 1, 1, 10, 20, 30))
  assert(mtime_of(2021, 6, 15, 30, 63, 62) == unix(2021, 6, 15, 23, 59, 59))
  -- A date that is real is read as it is, including the last day of a
  -- month and a leap day.
  assert(mtime_of(2020, 2, 29, 0, 0, 0) == unix(2020, 2, 29, 0, 0, 0))
  assert(mtime_of(2107, 12, 31, 23, 59, 58) == 4354819198)
end

local function test_an_mtime_survives_the_dos_round_trip_to_two_seconds()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("a", "x", { mtime = 1700000001 }))
  assert(w:add_file("b", "x", { mtime = 315532800 }))
  assert(w:add_file("c", "x", { mtime = 315532799 }))
  assert(w:add_file("d", "x", { mtime = -5 }))
  assert(w:add_file("e", "x", { mtime = math.maxinteger }))
  assert(w:close())
  local entries = entries_of((assert(Zip.open_string(c:result()))))
  assert(by_path(entries, "a").mtime == 1700000000)
  assert(by_path(entries, "b").mtime == 315532800)
  assert(by_path(entries, "c").mtime == 315532800 and by_path(entries, "d").mtime == 315532800)
  assert(by_path(entries, "e").mtime == 4354819198)
end

local function test_entries_of_a_reader_closed_first_fail_as_next_does()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("f", "body"))
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  assert(r:close())
  local entries, trouble = r:entries()
  assert(entries == nil and trouble:find("closed", 1, true) ~= nil, trouble)
  local entry, next_trouble = r:next()
  assert(entry == nil and next_trouble:find("closed", 1, true) ~= nil, next_trouble)
  local again, again_trouble = r:entries()
  assert(again == nil and again_trouble == trouble, "a failed listing is not kept")
end

--- A failing Writer's own words are what the writer answers, as they
--- are; a failing body Reader's are told what the writer was doing.
local function test_a_failing_underlying_writer_is_answered_as_it_said_it()
  local full: Stream.Writer = {}
  full.write = function(_self: Stream.Writer, _data: string): boolean, string
    return false, "disk full"
  end
  full.close = function(_self: Stream.Writer): boolean, string return true, "" end
  full.abort = full.close
  local w = Zip.writer(full)
  local ok, trouble = w:add_file("f", Stream.from_string(string.rep("x", 100000)), { size = 100000 })
  assert(not ok and trouble == "disk full", trouble)
  ok, trouble = w:close()
  assert(not ok and trouble == "disk full", trouble)
end
