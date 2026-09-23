--- Proves the zip reader and writer against each other, and against a
--- fixture made once, ahead of time, by the system `zip` -- a mix of
--- stored and deflated entries and a symlink -- embedded as base64 so
--- this file has no binary bytes of its own and no test spawns an
--- external program.

local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Zip = require("cosmic.zip")

local B64_ALPHABET <const> = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64_index(): {string:integer}
  local map: {string:integer} = {}
  for i = 1, #B64_ALPHABET do
    map[B64_ALPHABET:sub(i, i)] = i - 1
  end
  return map
end

local B64_INDEX <const> = b64_index()

local function base64_decode(data: string): string
  local out: {string} = {}
  local bits = 0
  local nbits = 0
  for i = 1, #data do
    local c = data:sub(i, i)
    local v = B64_INDEX[c]
    if v ~= nil then
      bits = (bits << 6) | v
      nbits = nbits + 6
      if nbits >= 8 then
        nbits = nbits - 8
        out[#out + 1] = string.char((bits >> nbits) & 0xFF)
      end
    end
  end
  return table.concat(out)
end

local ZIP_B64 <const> =
  "UEsDBAoAAAAAADItN13z+cmLFAAAABQAAAANABwAc3JjL3Nob3J0LnR4dFVUCQADkGazapBms2p1eAsAAQQAAAAABAAAAABzaG9ydCBmaWxlIGNvbnRlbnRzClBLAwQKAAAAAAAyLTddI9j0uAkAAAAJAAAADgAcAHNyYy9hZGlyL2FsaW5rVVQJAAOQZrNqkGazanV4CwABBAAAAAAEAAAAAHNob3J0LnR4dFBLAwQUAAAACAA4LTdd0RXq2CAAAACZCAAACwAcAHNyYy9iaWcudHh0VVQJAAOcZrNqn2azanV4CwABBAAAAAAEAAAAAEtJTctJLElVyE1VSBlljjJHmaPMUeYoc5Q5yhxIJhcAUEsDBAoAAAAAADgtN13z+cmLFAAAABQAAAAUABwAc3JjL3Nob3J0X3N0b3JlZC50eHRVVAkAA5xms2qfZrNqdXgLAAEEAAAAAAQAAAAAc2hvcnQgZmlsZSBjb250ZW50cwpQSwECHgMKAAAAAAAyLTdd8/nJixQAAAAUAAAADQAYAAAAAAABAAAApIEAAAAAc3JjL3Nob3J0LnR4dFVUBQADkGazanV4CwABBAAAAAAEAAAAAFBLAQIeAwoAAAAAADItN10j2PS4CQAAAAkAAAAOABgAAAAAAAAAAAD/oVsAAABzcmMvYWRpci9hbGlua1VUBQADkGazanV4CwABBAAAAAAEAAAAAFBLAQIeAxQAAAAIADgtN13RFerYIAAAAJkIAAALABgAAAAAAAEAAACkgawAAABzcmMvYmlnLnR4dFVUBQADnGazanV4CwABBAAAAAAEAAAAAFBLAQIeAwoAAAAAADgtN13z+cmLFAAAABQAAAAUABgAAAAAAAAAAACkgREBAABzcmMvc2hvcnRfc3RvcmVkLnR4dFVUBQADnGazanV4CwABBAAAAAAEAAAAAFBLBQYAAAAABAAEAFIBAABzAQAAAAA="

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
  local entries = r:entries()
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
  local entry = by_path(r:entries(), "f")
  -- 1980-01-01T00:00:00Z
  assert(entry.mtime == 315532800, tostring(entry.mtime))
end

local function test_mode_bits_round_trip_through_external_attributes()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("exe", "x", { method = "store", mode = 0x1ff }))
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  local entry = by_path(r:entries(), "exe")
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
  local entry = by_path(r:entries(), "f")
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
  local entry = by_path(r:entries(), "f")
  assert(Stream.read_all((assert(entry:open()))) == "on disk")
  assert(r:close())
end

local function test_list_reads_entries_without_keeping_the_file_open(tmp: string)
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("a", "1", { method = "store" }))
  assert(w:add_file("b", "2", { method = "store" }))
  assert(w:close())
  local path = tmp .. "/archive.zip"
  assert(Fs.write(path, c:result()))
  local entries = assert(Zip.list(path))
  assert(#entries == 2)
end

local function test_writer_and_reader_roundtrip_a_deflated_file()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("f", "hello there, deflated", { method = "deflate" }))
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  local entry = by_path(r:entries(), "f")
  assert(entry.method == 8, tostring(entry.method))
  local body = assert(Stream.read_all((assert(entry:open()))))
  assert(body == "hello there, deflated")
end

local function test_a_system_made_deflated_entry_reads_back()
  local raw = base64_decode(ZIP_B64)
  local r = assert(Zip.open_string(raw))
  local entry = by_path(r:entries(), "src/big.txt")
  assert(entry.method == 8)
  local data = assert(Stream.read_all((assert(entry:open()))))
  assert(#data == entry.size)
  assert(data:find("deflate me", 1, true) ~= nil)
end

local function test_a_system_made_zip_fixture_lists_its_stored_entries()
  local raw = base64_decode(ZIP_B64)
  local r = assert(Zip.open_string(raw))
  local entries = r:entries()
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
  local entries = r:entries()
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
  local entries = r:entries()
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

local function test_a_forged_end_record_inside_the_comment_is_not_taken_for_the_real_one()
  local raw = three_entry_zip()
  local fake = "PK\5\6" .. le16(0) .. le16(0) .. le16(0) .. le16(0) .. le32(0) .. le32(0) ..
    le16(0)
  local forged = raw:sub(1, #raw - 2) .. le16(#fake) .. fake
  local r = assert(Zip.open_string(forged))
  assert(#r:entries() == 3)
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

local function test_an_entry_body_larger_than_its_recorded_size_fails_at_once()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("f", "hello world", { method = "store" }))
  assert(w:close())
  local raw = c:result()
  local cd = assert(raw:find("PK\1\2", 1, true))
  local lying = patch(raw, cd + 24, le32(5))
  local r = assert(Zip.open_string(lying))
  local body = assert(by_path(r:entries(), "f"):open())
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
  local entries = assert(Zip.list(path))
  local body, trouble = entries[1]:open()
  assert(body == nil and trouble:find("closed", 1, true) ~= nil, trouble)
end

local function test_a_unix_symlink_entry_is_reported_as_a_symlink()
  local r = assert(Zip.open_string(base64_decode(ZIP_B64)))
  local link = by_path(r:entries(), "src/adir/alink")
  assert(link.kind == "symlink" and link.linkpath == "short.txt", link.kind)
  assert(by_path(r:entries(), "src/short.txt").linkpath == "")
end

local function test_mtimes_past_2107_clamp_to_the_last_dos_time()
  local c = Stream.collect()
  local w = Zip.writer(c)
  assert(w:add_file("y2200", "x", { mtime = 7258118400 }))
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  local mtime = by_path(r:entries(), "y2200").mtime
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
