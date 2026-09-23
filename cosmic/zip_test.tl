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
  local w = Zip.writer(c as Stream.Writer)
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
  local w = Zip.writer(c as Stream.Writer, { deterministic = true })
  assert(w:add_file("f", "x", { method = "store", mtime = 1700000000 }))
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  local entry = by_path(r:entries(), "f")
  -- 1980-01-01T00:00:00Z
  assert(entry.mtime == 315532800, tostring(entry.mtime))
end

local function test_mode_bits_round_trip_through_external_attributes()
  local c = Stream.collect()
  local w = Zip.writer(c as Stream.Writer)
  assert(w:add_file("exe", "x", { method = "store", mode = 0x1ff }))
  assert(w:close())
  local r = assert(Zip.open_string(c:result()))
  local entry = by_path(r:entries(), "exe")
  assert(entry.mode == 0x1ff, string.format("%o", entry.mode))
end

local function test_a_corrupt_body_fails_its_crc_check()
  local c = Stream.collect()
  local w = Zip.writer(c as Stream.Writer)
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
  local w = Zip.writer(c as Stream.Writer)
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
  local w = Zip.writer(c as Stream.Writer)
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
  local w = Zip.writer(c as Stream.Writer)
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
