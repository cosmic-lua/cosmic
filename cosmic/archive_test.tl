--- Proves format detection, the uniform entry walk over both tar and
--- zip, and extraction's path-escape refusals and permission bits.
--- Fixtures are built with this tree's own `Tar.writer`/`Zip.writer`,
--- since the point here is `cosmic.archive` itself, not another
--- interop check -- `tar_test.tl` and `zip_test.tl` already cover
--- reading what other tools wrote.

local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")
local Archive = require("cosmic.archive")

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

--- `tar -cf a.tar src` (a directory holding src/short.txt and the
--- symlink src/adir/alink -> short.txt), then gzip/xz/bzip2 -c.
local TAR_GZ_B64 <const> =
  "H4sICDBss2oAA2EudGFyAO3V0QrCIBiGYS/FKyh16q5n1GCjkaAGXX7bDoIGFTuwUb3PiYqCv3yoKR72ojA1qp2b29GynfvaGWe998p5obSqvBHSlS5sckm5iVKKGEJ+te7d/JdKY/6pCzHv8rXU+aaAvbXP89fVIn8zDoRUhep58Of5d+0wBJm7NrZbl4INTPe/Ofax5Cew/v3XldK8/59wz78Z+vOpzB5z/nW9In9rdC2kKf0xTf48fwAAAAAAAAAAAADAb7gBw+SVgAAoAAA="

local TAR_XZ_B64 <const> =
  "/Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4Cf/ALRdADmciIYQ5JSzSsi80f5CS2Mz1B2NDlCga8DZbb93I37BWWvMTbmf7QGoFp8jKOHhdLipWR/C76M30KCW71uapGjA/XCYBA6qOA77bNygKo4HKw2ATQ/wFkCDaKWVRIgGH2eHfxoC5QfvkUJ81yTZ7ZDFUU/49FBz6H2UMewyMRqRzv8Ci3fb8f/0MeZw40GVioKYeHI/X5kJT484FpxP9ajNSxfcYNbm3ueaV6PKpejl8jfYAAAiL5Q/NnCwYQAB0AGAUAAAyXnubbHEZ/sCAAAAAARZWg=="

local TAR_BZ2_B64 <const> =
  "QlpoOTFBWSZTWftqLH0AAPT7hcqAAEBAAf+AGIRubZ5AAACAAhAIMADNphKKAABoAAACVTT1MgAGgAAAKqalPNDVG1G1AzU9NTanqPKcBmsKrFONp8mSgiNPggJSyiluAckAYE4xZRQYkEiolBUalRrg8M5RFkwl0yyyoDkigrmCAL0deBq2rRoSoPotGICxQgMcGrSsmUvqLy62tESPmWJiZo0f1ez81bXaV7RQUZiZYvLeRqTYfG/HNuTOEHm8gy9Pk3uKAQPxdyRThQkPtqLH0A=="

local function make_tar(path: string)
  local w = assert(Stream.create(path))
  local tw = Tar.writer(w)
  assert(tw:add_dir("adir"))
  assert(tw:add_file("adir/short.txt", "hello there"))
  assert(tw:add_file("bin/tool", "#!/bin/sh\necho hi\n", { mode = 0x1ed }))
  assert(tw:add_symlink("adir/link", "short.txt"))
  assert(tw:close())
end

local function make_zip(path: string)
  local w = assert(Stream.create(path))
  local zw = Zip.writer(w)
  assert(zw:add_dir("adir"))
  assert(zw:add_file("adir/short.txt", "hello there", { method = "store" }))
  assert(zw:close())
end

local function test_open_detects_a_plain_tar_by_its_ustar_magic(tmp: string)
  local path = tmp .. "/a.tar"
  make_tar(path)
  local entries = assert(Archive.list(path))
  local by: {string:Archive.Entry} = {}
  for _, e in ipairs(entries) do by[e.path] = e end
  assert(by["adir/"].kind == "dir")
  assert(by["adir/short.txt"].kind == "file" and by["adir/short.txt"].size == 11)
  assert(by["adir/link"].kind == "symlink" and by["adir/link"].linkpath == "short.txt")
end

local function test_open_detects_a_zip_by_its_local_header_signature(tmp: string)
  local path = tmp .. "/a.zip"
  make_zip(path)
  local entries = assert(Archive.list(path))
  local by: {string:Archive.Entry} = {}
  for _, e in ipairs(entries) do by[e.path] = e end
  assert(by["adir/"].kind == "dir")
  assert(by["adir/short.txt"].kind == "file" and by["adir/short.txt"].size == 11)
end

local function test_open_refuses_an_unrecognized_file(tmp: string)
  local path = tmp .. "/plain.txt"
  assert(Fs.write(path, "just some text, not an archive"))
  local r, trouble = Archive.open(path)
  assert(r == nil and trouble:find("not a recognized archive format", 1, true) ~= nil, trouble)
end

local function test_extract_writes_files_and_directories_and_keeps_the_mode(tmp: string)
  local archive = tmp .. "/a.tar"
  make_tar(archive)
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(archive, dest))
  table.sort(written)
  assert(#written == 3, table.concat(written, ","))
  assert(Fs.read(dest .. "/adir/short.txt") == "hello there")
  assert(Fs.is_dir(dest .. "/adir") == true)
  local st = assert(Fs.stat(dest .. "/bin/tool"))
  assert(st.mode & 0x49 ~= 0, string.format("%o", st.mode)) -- some execute bit set
  -- a symlink is skipped by default
  assert(Fs.exists(dest .. "/adir/link") == false)
end

local function test_extract_strips_a_string_prefix(tmp: string)
  local archive = tmp .. "/a.tar"
  make_tar(archive)
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(archive, dest, { strip = "adir/" }))
  table.sort(written)
  assert(#written == 1, table.concat(written, ","))
  assert(Fs.read(dest .. "/short.txt") == "hello there")
end

local function test_extract_strips_leading_path_components(tmp: string)
  local archive = tmp .. "/a.tar"
  make_tar(archive)
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(archive, dest, { strip = 1 }))
  table.sort(written)
  -- "adir/" itself strips to nothing and is not written as a directory
  -- of its own; its contents still land at the extraction root.
  assert(#written == 2, table.concat(written, ","))
  assert(Fs.read(dest .. "/short.txt") == "hello there")
  assert(Fs.read(dest .. "/tool") == "#!/bin/sh\necho hi\n")
end

local function test_extract_applies_a_filter(tmp: string)
  local archive = tmp .. "/a.tar"
  make_tar(archive)
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(archive, dest, {
    filter = function(rel: string): boolean return rel:find("^bin/", 1) ~= nil end,
  }))
  assert(#written == 1 and written[1] == "bin/tool", table.concat(written, ","))
  assert(Fs.exists(dest .. "/adir") == false)
end

local function test_extract_refuses_an_absolute_entry_path(tmp: string)
  local archive = tmp .. "/evil.tar"
  local w = assert(Stream.create(archive))
  local tw = Tar.writer(w)
  assert(tw:add_file("/etc/passwd", "pwned"))
  assert(tw:close())
  local dest = tmp .. "/out"
  local written, trouble = Archive.extract(archive, dest)
  assert(written == nil and trouble:find("unsafe entry path", 1, true) ~= nil, trouble)
end

local function test_extract_refuses_a_dotdot_entry_path(tmp: string)
  local archive = tmp .. "/evil.tar"
  local w = assert(Stream.create(archive))
  local tw = Tar.writer(w)
  assert(tw:add_file("../escaped.txt", "pwned"))
  assert(tw:close())
  local dest = tmp .. "/out"
  local written, trouble = Archive.extract(archive, dest)
  assert(written == nil and trouble:find("unsafe entry path", 1, true) ~= nil, trouble)
  assert(Fs.exists(tmp .. "/escaped.txt") == false)
end

local function test_extract_refuses_a_backslash_dotdot_entry_path(tmp: string)
  local archive = tmp .. "/evil.tar"
  local w = assert(Stream.create(archive))
  local tw = Tar.writer(w)
  assert(tw:add_file("adir\\..\\..\\escaped.txt", "pwned"))
  assert(tw:close())
  local dest = tmp .. "/out"
  local written, trouble = Archive.extract(archive, dest)
  assert(written == nil and trouble:find("unsafe entry path", 1, true) ~= nil, trouble)
end

local function test_extract_refuses_a_drive_letter_entry_path(tmp: string)
  local archive = tmp .. "/evil.tar"
  local w = assert(Stream.create(archive))
  local tw = Tar.writer(w)
  assert(tw:add_file("C:evil.txt", "pwned"))
  assert(tw:close())
  local dest = tmp .. "/out"
  local written, trouble = Archive.extract(archive, dest)
  assert(written == nil and trouble:find("unsafe entry path", 1, true) ~= nil, trouble)
end

local function test_extract_skips_symlinks_by_default_without_erroring(tmp: string)
  local archive = tmp .. "/a.tar"
  make_tar(archive)
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(archive, dest, { links = "skip" }))
  for _, rel in ipairs(written) do
    assert(rel ~= "adir/link")
  end
end

local function test_extract_refuses_a_symlink_escaping_the_destination(tmp: string)
  local archive = tmp .. "/evil_link.tar"
  local w = assert(Stream.create(archive))
  local tw = Tar.writer(w)
  assert(tw:add_symlink("adir/link", "../../../../etc/passwd"))
  assert(tw:close())
  local dest = tmp .. "/out"
  local written, trouble = Archive.extract(archive, dest, { links = "create" })
  assert(written == nil and trouble:find("escaping the destination", 1, true) ~= nil, trouble)
end

local function test_extract_refuses_a_backslash_symlink_target(tmp: string)
  local archive = tmp .. "/evil_link.tar"
  local w = assert(Stream.create(archive))
  local tw = Tar.writer(w)
  assert(tw:add_symlink("adir/link", "..\\..\\..\\..\\etc\\passwd"))
  assert(tw:close())
  local dest = tmp .. "/out"
  local written, trouble = Archive.extract(archive, dest, { links = "create" })
  assert(written == nil and trouble:find("escaping the destination", 1, true) ~= nil, trouble)
end

local function test_extract_creates_a_safe_symlink(tmp: string)
  local archive = tmp .. "/a.tar"
  make_tar(archive)
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(archive, dest, { links = "create" }))
  local found = false
  for _, rel in ipairs(written) do
    if rel == "adir/link" then found = true end
  end
  assert(found)
  local target = assert(Fs.readlink(dest .. "/adir/link"))
  assert(target == "short.txt", target)
end

local function test_extract_a_gzip_compressed_tar_made_by_system_tar(tmp: string)
  local path = tmp .. "/a.tar.gz"
  assert(Fs.write(path, base64_decode(TAR_GZ_B64)))
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(path, dest))
  table.sort(written)
  assert(#written == 3, table.concat(written, ","))
  assert(Fs.read(dest .. "/src/short.txt") == "hello there")
end

local function test_extract_an_xz_compressed_tar_made_by_system_tar(tmp: string)
  local path = tmp .. "/a.tar.xz"
  assert(Fs.write(path, base64_decode(TAR_XZ_B64)))
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(path, dest))
  table.sort(written)
  assert(#written == 3, table.concat(written, ","))
  assert(Fs.read(dest .. "/src/short.txt") == "hello there")
end

local function test_extract_a_bzip2_compressed_tar_made_by_system_tar(tmp: string)
  local path = tmp .. "/a.tar.bz2"
  assert(Fs.write(path, base64_decode(TAR_BZ2_B64)))
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(path, dest))
  table.sort(written)
  assert(#written == 3, table.concat(written, ","))
  assert(Fs.read(dest .. "/src/short.txt") == "hello there")
end
