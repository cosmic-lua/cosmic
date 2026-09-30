--- Proves format detection, the uniform entry walk over both tar and
--- zip, and extraction's path-escape refusals and permission bits.
--- Fixtures are built with this tree's own [`Tar.writer`]/[`Zip.writer`],
--- since the point here is [`cosmic.archive`] itself, not another
--- interop check -- `tar_test.tl` and `zip_test.tl` already cover
--- reading what other tools wrote.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")
local Archive = require("cosmic.archive")

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

--- The entries of `reader`, by path, and closes it.
local function walked(reader: Archive.Reader): {string:Archive.Entry}
  local by: {string:Archive.Entry} = {}
  while true do
    local e, why = reader:next()
    if e == nil then
      assert(why == "", why)
      break
    end
    by[e.path] = e
  end
  assert(reader:close())
  return by
end

local function test_open_stream_reads_a_plain_tar_from_a_stream_one_byte_at_a_time(tmp: string)
  local path = tmp .. "/a.tar"
  make_tar(path)
  local bytes = assert(Fs.read(path))
  -- A source that answers a byte per read splits the peek across reads.
  local at = 1
  local source: Stream.Reader = {}
  source.read = function(_self: Stream.Reader, _max?: integer): string | nil, string
    if at > #bytes then return nil, "" end
    at = at + 1
    return bytes:sub(at - 1, at - 1), ""
  end
  source.close = function(_self: Stream.Reader): boolean, string return true, "" end
  local by = walked((assert(Archive.open_stream(source))))
  assert(by["adir/short.txt"].size == 11)
  assert(by["adir/link"].linkpath == "short.txt")
end

local function test_open_stream_reads_gzip_xz_and_bzip2_tars()
  for _, b64 in ipairs({ TAR_GZ_B64, TAR_XZ_B64, TAR_BZ2_B64 }) do
    local bytes = assert(Codec.unbase64(b64))
    local by = walked((assert(Archive.open_stream(Stream.from_string(bytes)))))
    local n = 0
    for _ in pairs(by) do n = n + 1 end
    assert(n > 0)
  end
end

local function test_open_stream_refuses_a_zip_and_an_unrecognized_stream(tmp: string)
  local path = tmp .. "/a.zip"
  make_zip(path)
  local r, why = Archive.open_stream(Stream.from_string((assert(Fs.read(path)))))
  assert(r == nil and why:find("zip", 1, true) ~= nil, why)
  r, why = Archive.open_stream(Stream.from_string("just some text"))
  assert(r == nil and why:find("not a recognized archive format", 1, true) ~= nil, why)
  r, why = Archive.open_stream(Stream.from_string(""))
  assert(r == nil and why:find("not a recognized archive format", 1, true) ~= nil, why)
end

local function test_open_stream_fails_on_a_truncated_gzip_stream()
  local bytes = assert(Codec.unbase64(TAR_GZ_B64))
  local r = assert(Archive.open_stream(Stream.from_string(bytes:sub(1, #bytes - 30))))
  local failed = false
  while true do
    local e, why = r:next()
    if e == nil then
      failed = why ~= ""
      break
    end
  end
  assert(failed, "a truncated stream passed as complete")
end

--- A gzip whose deflate body is a block with no codes at all, which
--- the decompressor once read as literal zeros without end: `next`
--- spun at the tar's end, draining them. It answers an error at once.
local function test_a_gzip_block_with_no_codes_fails_next_rather_than_spinning(tmp: string)
  local bytes = "\31\139\8\0\0\0\0\0\0\255\237\211" .. string.rep("\0", 12)
  local path = tmp .. "/nocodes.tar.gz"
  assert(Fs.write(path, bytes))
  local readers: {Archive.Reader} = {
    assert(Archive.open(path)),
    (assert(Archive.open_stream(Stream.from_string(bytes)))),
  }
  for i, r in ipairs(readers) do
    local e, why = r:next()
    assert(e == nil and why:find("corrupt compressed data", 1, true) ~= nil, i .. ": " .. why)
    r:close()
  end
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
  local written = assert(Archive.extract(archive, dest, { strip_prefix = "adir/" }))
  table.sort(written)
  assert(#written == 1, table.concat(written, ","))
  assert(Fs.read(dest .. "/short.txt") == "hello there")
end

local function test_extract_strips_leading_path_components(tmp: string)
  local archive = tmp .. "/a.tar"
  make_tar(archive)
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(archive, dest, { strip_components = 1 }))
  table.sort(written)
  -- "adir/" itself strips to nothing and is not written as a directory
  -- of its own; its contents still land at the extraction root.
  assert(#written == 2, table.concat(written, ","))
  assert(Fs.read(dest .. "/short.txt") == "hello there")
  assert(Fs.read(dest .. "/tool") == "#!/bin/sh\necho hi\n")
end

--- A whole number held as a float strips as the integer does; any other
--- number is refused before anything is written.
local function test_extract_strips_by_a_whole_float(tmp: string)
  local archive = tmp .. "/a.tar"
  make_tar(archive)
  local float = assert(load("return ...")) as function(number): integer
  local written = assert(Archive.extract(archive, tmp .. "/out", { strip_components = float(1.0) }))
  assert(#written == 2, table.concat(written, ","))
  assert(Fs.read(tmp .. "/out/tool") == "#!/bin/sh\necho hi\n")
  local refusals: {{integer, string}} = { { float(1.5), "whole number" }, { -1, "negative" } }
  for _, refusal in ipairs(refusals) do
    local count, says = refusal[1], refusal[2]
    local ok, why = pcall(Archive.extract, archive, tmp .. "/bad", { strip_components = count })
    assert(not ok and tostring(why):find(says, 1, true) ~= nil, tostring(why))
    assert(Fs.exists(tmp .. "/bad") == false)
  end
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
  assert(Fs.write(path, (assert(Codec.unbase64(TAR_GZ_B64)))))
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(path, dest))
  table.sort(written)
  assert(#written == 3, table.concat(written, ","))
  assert(Fs.read(dest .. "/src/short.txt") == "hello there")
end

local function test_extract_an_xz_compressed_tar_made_by_system_tar(tmp: string)
  local path = tmp .. "/a.tar.xz"
  assert(Fs.write(path, (assert(Codec.unbase64(TAR_XZ_B64)))))
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(path, dest))
  table.sort(written)
  assert(#written == 3, table.concat(written, ","))
  assert(Fs.read(dest .. "/src/short.txt") == "hello there")
end

local function test_extract_a_bzip2_compressed_tar_made_by_system_tar(tmp: string)
  local path = tmp .. "/a.tar.bz2"
  assert(Fs.write(path, (assert(Codec.unbase64(TAR_BZ2_B64)))))
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(path, dest))
  table.sort(written)
  assert(#written == 3, table.concat(written, ","))
  assert(Fs.read(dest .. "/src/short.txt") == "hello there")
end

--- A tar at `path` built by `build`, for the extraction cases below.
local function tar_of(path: string, build: function(Tar.Writer))
  local tw = Tar.writer((assert(Stream.create(path))))
  build(tw)
  assert(tw:close())
end

local function test_extract_refuses_a_symlink_chain_that_climbs_out(tmp: string)
  -- a -> . and a/a2 -> .. : a/a2 lexically stays inside, but a/a2
  -- really is dest/.. once `a` is a link, so a/a2/pwned would land
  -- beside dest
  local archive = tmp .. "/chain.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_symlink("a", "."))
    assert(tw:add_symlink("a/a2", ".."))
    assert(tw:add_file("a/a2/pwned", "escaped\n"))
  end)
  local dest = tmp .. "/work/dest"
  local written, trouble = Archive.extract(archive, dest, { links = "create" })
  assert(written == nil and trouble:find("through a symlink", 1, true) ~= nil, trouble)
  assert(Fs.exists(tmp .. "/work/pwned") == false)
  assert(Fs.exists(tmp .. "/work/a2") == false)
end

local function test_extract_refuses_a_symlink_placed_inside_another_symlink(tmp: string)
  -- the same chain without the file: making a/a2 would need writing
  -- inside the link `a`
  local archive = tmp .. "/chain.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_symlink("a", "."))
    assert(tw:add_symlink("a/a2", ".."))
  end)
  local dest = tmp .. "/work/dest"
  local written, trouble = Archive.extract(archive, dest, { links = "create" })
  assert(written == nil and trouble:find("through a symlink", 1, true) ~= nil, trouble)
  assert(Fs.exists(tmp .. "/work/dest/a2") == false)
end

local function test_extract_refuses_a_directory_entry_later_replaced_by_a_symlink(tmp: string)
  local archive = tmp .. "/swap.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_dir("d"))
    assert(tw:add_symlink("d", "."))
    assert(tw:add_file("d/pwned", "escaped\n"))
  end)
  local dest = tmp .. "/work/dest"
  local written, trouble = Archive.extract(archive, dest, { links = "create" })
  assert(written == nil and trouble:find("through a symlink", 1, true) ~= nil, trouble)
  assert(Fs.exists(tmp .. "/work/pwned") == false)
end

local function test_extract_lets_a_later_entry_replace_a_pending_symlink(tmp: string)
  local archive = tmp .. "/dup.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_symlink("x", "."))
    assert(tw:add_file("x", "a regular file after all"))
  end)
  local dest = tmp .. "/out"
  assert(Archive.extract(archive, dest, { links = "create" }))
  assert(Fs.read(dest .. "/x") == "a regular file after all")
  assert(Fs.readlink(dest .. "/x") == nil)
end

local function test_extract_refuses_a_link_target_that_walks_through_another_link(tmp: string)
  -- l -> . is fine; m -> l/.. reads as "inside" lexically, but `l` is
  -- a link to dest itself, so l/.. is dest's parent
  local archive = tmp .. "/through.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_symlink("l", "."))
    assert(tw:add_symlink("m", "l/.."))
  end)
  local dest = tmp .. "/out"
  local written, trouble = Archive.extract(archive, dest, { links = "create" })
  assert(written == nil and trouble:find("runs through another symlink", 1, true) ~= nil, trouble)
end

local function test_extract_refuses_a_link_target_through_a_missing_directory(tmp: string)
  -- x -> b/.. with no `b`: on a case-insensitive filesystem the link
  -- B -> . answers for `b`, and x becomes dest's parent
  local archive = tmp .. "/case.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_symlink("x", "b/.."))
    assert(tw:add_symlink("B", "."))
  end)
  local written, trouble = Archive.extract(archive, tmp .. "/out", { links = "create" })
  assert(written == nil and trouble:find("runs through another symlink or a missing directory", 1,
    true) ~= nil, trouble)
  assert(Fs.readlink(tmp .. "/out/x") == nil)
end

local function test_extract_creates_links_through_real_directories(tmp: string)
  local archive = tmp .. "/libs.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_file("lib/libfoo.so.1", "elf"))
    assert(tw:add_symlink("lib/libfoo.so", "libfoo.so.1"))
    assert(tw:add_file("lib/x", "tool"))
    assert(tw:add_symlink("bin/x", "../lib/x"))
    assert(tw:add_symlink("bin/y", "../lib/../lib/x"))
  end)
  local dest = tmp .. "/out"
  assert(Archive.extract(archive, dest, { links = "create" }))
  assert(Fs.read(dest .. "/lib/libfoo.so") == "elf")
  assert(Fs.read(dest .. "/bin/x") == "tool")
  assert(Fs.read(dest .. "/bin/y") == "tool")
end

local function test_extract_refuses_to_write_through_a_symlink_already_in_dest(tmp: string)
  local archive = tmp .. "/a.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_file("sub/f", "x"))
  end)
  local dest = tmp .. "/out"
  assert(Fs.mkdirs(dest))
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  assert(Fs.symlink(tmp .. "/elsewhere", dest .. "/sub"))
  local written, trouble = Archive.extract(archive, dest)
  assert(written == nil and trouble:find("through a symlink", 1, true) ~= nil, trouble)
  assert(Fs.exists(tmp .. "/elsewhere/f") == false)
end

--- A pax header naming `key` with a value holding a NUL, then a
--- ustar entry of `typeflag` it applies to.
local function nul_pax_tar(key: string, typeflag: string, name: string): string
  local c = Stream.collect()
  local tw = Tar.writer(c)
  if typeflag == "2" then
    assert(tw:add_symlink(name, "placeholder"))
  else
    assert(tw:add_file(name, ""))
  end
  assert(tw:close())
  local ustar = c:result()
  local rec = " " .. key .. "=..\0/x\n"
  rec = tostring(#rec + 2) .. rec
  local c2 = Stream.collect()
  local tw2 = Tar.writer(c2)
  -- borrow a real header block for the pax entry, then retype it
  assert(tw2:add_file("PaxHeaders/p", rec))
  assert(tw2:close())
  local pax = c2:result():sub(1, 1024)
  local block = pax:sub(1, 156) .. "x" .. pax:sub(158, 512)
  local sum = 256
  for i = 1, 148 do sum = sum + block:byte(i) end
  for i = 157, 512 do sum = sum + block:byte(i) end
  block = block:sub(1, 148) .. string.format("%06o", sum) .. "\0 " .. block:sub(157)
  return block .. pax:sub(513, 1024) .. ustar
end

local function test_extract_refuses_a_nul_byte_in_a_pax_link_target(tmp: string)
  local archive = tmp .. "/nul.tar"
  assert(Fs.write(archive, nul_pax_tar("linkpath", "2", "l")))
  local written, trouble = Archive.extract(archive, tmp .. "/out", { links = "create" })
  assert(written == nil and trouble:find("NUL", 1, true) ~= nil, trouble)
end

local function test_extract_refuses_a_nul_byte_in_a_pax_path(tmp: string)
  local archive = tmp .. "/nul.tar"
  assert(Fs.write(archive, nul_pax_tar("path", "0", "f")))
  local written, trouble = Archive.extract(archive, tmp .. "/out")
  assert(written == nil and trouble:find("NUL", 1, true) ~= nil, trouble)
end

local function test_extract_never_commits_a_file_that_fails_its_crc(tmp: string)
  local c = Stream.collect()
  local zw = Zip.writer(c)
  assert(zw:add_file("f.txt", "hello", { method = "store" }))
  assert(zw:close())
  local raw = c:result()
  local at = assert(raw:find("hello", 1, true))
  local archive = tmp .. "/bad.zip"
  assert(Fs.write(archive, raw:sub(1, at - 1) .. "jello" .. raw:sub(at + 5)))
  local dest = tmp .. "/out"
  assert(Fs.mkdirs(dest))
  assert(Fs.write(dest .. "/f.txt", "ORIGINAL"))
  local written, trouble = Archive.extract(archive, dest)
  assert(written == nil and trouble:find("crc32", 1, true) ~= nil, trouble)
  assert(Fs.read(dest .. "/f.txt") == "ORIGINAL")
  local left = assert(Fs.list(dest))
  assert(#left == 1, table.concat(left, ","))
end

local function test_extract_fails_on_a_truncated_compressed_tar(tmp: string)
  local Compress = require("cosmic.compress")
  local c = Stream.collect()
  local gz = Stream.transform_writer(c, (assert(Compress.deflater("gzip"))))
  local tw = Tar.writer(gz)
  assert(tw:add_file("f.txt", "complete"))
  assert(tw:close())
  local whole = c:result()
  local archive = tmp .. "/trunc.tar.gz"
  -- drop the gzip trailer: every tar block is still there
  assert(Fs.write(archive, whole:sub(1, #whole - 8)))
  local written, trouble = Archive.extract(archive, tmp .. "/out")
  assert(written == nil and trouble:find("truncated", 1, true) ~= nil, trouble)
  local listed, ltrouble = Archive.list(archive)
  assert(listed == nil and ltrouble ~= "")
  -- the whole one is fine
  assert(Fs.write(archive, whole))
  assert(Archive.extract(archive, tmp .. "/out2"))
end

local function test_extract_fails_on_a_hardlink_unless_asked_to_skip(tmp: string)
  local archive = tmp .. "/hard.tar"
  local c = Stream.collect()
  local tw = Tar.writer(c)
  assert(tw:add_file("f", "x"))
  assert(tw:add_symlink("h", "f"))
  assert(tw:close())
  -- retype the symlink as a hard link (typeflag 1)
  local raw = c:result()
  local block = raw:sub(1025, 1536)
  block = block:sub(1, 156) .. "1" .. block:sub(158)
  local sum = 256
  for i = 1, 148 do sum = sum + block:byte(i) end
  for i = 157, 512 do sum = sum + block:byte(i) end
  block = block:sub(1, 148) .. string.format("%06o", sum) .. "\0 " .. block:sub(157)
  assert(Fs.write(archive, raw:sub(1, 1024) .. block .. raw:sub(1537)))
  local written, trouble = Archive.extract(archive, tmp .. "/out")
  assert(written == nil and trouble:find("h: unsupported entry kind 'hardlink'", 1, true) ~= nil,
    trouble)
  local skipped = assert(Archive.extract(archive, tmp .. "/out2", { unsupported = "skip" }))
  assert(#skipped == 1 and skipped[1] == "f", table.concat(skipped, ","))
end

local function test_extract_restores_mtimes_unless_told_not_to(tmp: string)
  local archive = tmp .. "/t.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_dir("d", { mtime = 1000000000 }))
    assert(tw:add_file("d/f", "x", { mtime = 1200000000 }))
  end)
  local dest = tmp .. "/out"
  assert(Archive.extract(archive, dest))
  assert((assert(Fs.stat(dest .. "/d/f"))).mtime == 1200000000)
  assert((assert(Fs.stat(dest .. "/d"))).mtime == 1000000000)
  local dest2 = tmp .. "/out2"
  assert(Archive.extract(archive, dest2, { mtimes = false }))
  assert((assert(Fs.stat(dest2 .. "/d/f"))).mtime ~= 1200000000)
end

--- An archived time past 2262, when nanoseconds since the epoch no
--- longer fit in an integer, is restored as it is (2300-01-01 here):
--- the file carries what setting that time gives any file on this
--- filesystem, which is 2300 itself where it counts seconds (ext4) and
--- its own last time where it counts nanoseconds (APFS).
local function test_extract_restores_an_mtime_past_2262(tmp: string)
  local probe = tmp .. "/probe"
  assert(Fs.write(probe, "p"))
  assert(Fs.set_mtime(probe, 10413792000))
  local want = assert(Fs.stat(probe))
  local archive = tmp .. "/t.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_file("far", "x", { mtime = 10413792000 }))
  end)
  local dest = tmp .. "/out"
  assert(Archive.extract(archive, dest))
  local far = assert(Fs.stat(dest .. "/far"))
  assert(far.mtime == want.mtime and far.mtime_ns == want.mtime_ns,
    far.mtime .. "." .. far.mtime_ns .. " ~= " .. want.mtime .. "." .. want.mtime_ns)
end

local function test_extract_stops_at_max_bytes_and_max_entries(tmp: string)
  local archive = tmp .. "/t.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_file("a", string.rep("a", 600)))
    assert(tw:add_file("b", string.rep("b", 600)))
  end)
  local written, trouble = Archive.extract(archive, tmp .. "/o1", { max_bytes = 1000 })
  assert(written == nil and trouble:find("more than 1000 bytes", 1, true) ~= nil, trouble)
  assert(Fs.exists(tmp .. "/o1/b") == false)
  written, trouble = Archive.extract(archive, tmp .. "/o2", { max_entries = 1 })
  assert(written == nil and trouble:find("more than 1 entry", 1, true) ~= nil, trouble)
  assert(Archive.extract(archive, tmp .. "/o3", { max_bytes = 1200, max_entries = 2 }))
  -- A limit with no byte past it to count still extracts everything.
  assert(Archive.extract(archive, tmp .. "/o4", { max_bytes = math.maxinteger }))
  assert(Fs.read(tmp .. "/o4/b") == string.rep("b", 600))
  -- A negative limit is a mistake, not a failure to report.
  assert(not pcall(Archive.extract, archive, tmp .. "/o5", { max_bytes = -1 }))
  assert(not pcall(Archive.extract, archive, tmp .. "/o6", { max_entries = -1 }))
end

local function test_extract_strip_matches_whole_components_only(tmp: string)
  local archive = tmp .. "/t.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_file("a/x", "in a"))
    assert(tw:add_file("abc/x", "in abc"))
  end)
  for _, prefix in ipairs({ "a", "a/" }) do
    local dest = tmp .. "/out-" .. tostring(#prefix)
    local written = assert(Archive.extract(archive, dest, { strip_prefix = prefix }))
    assert(#written == 1 and written[1] == "x", prefix .. ": " .. table.concat(written, ","))
    assert(Fs.read(dest .. "/x") == "in a")
  end
end

--- Both strips at once: the prefix is matched first, then the count
--- drops components from what is left.
local function test_extract_strips_a_prefix_then_components(tmp: string)
  local archive = tmp .. "/t.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_file("pkg/v1/src/x", "in src"))
    assert(tw:add_file("other/v1/src/y", "elsewhere"))
    assert(tw:add_file("pkg/v1", "too short"))
  end)
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(archive, dest,
    { strip_prefix = "pkg", strip_components = 1 }))
  assert(#written == 1 and written[1] == "src/x", table.concat(written, ","))
  assert(Fs.read(dest .. "/src/x") == "in src")
end

local function test_extract_creates_a_zip_symlink_as_a_symlink(tmp: string)
  local ZIP_B64 = "UEsDBAoAAAAAADItN13z+cmLFAAAABQAAAANABwAc3JjL3Nob3J0LnR4dFVUCQADkGazapBms2p1eAsAAQQAAAAABAAAAABzaG9ydCBmaWxlIGNvbnRlbnRzClBLAwQKAAAAAAAyLTddI9j0uAkAAAAJAAAADgAcAHNyYy9hZGlyL2FsaW5rVVQJAAOQZrNqkGazanV4CwABBAAAAAAEAAAAAHNob3J0LnR4dFBLAwQUAAAACAA4LTdd0RXq2CAAAACZCAAACwAcAHNyYy9iaWcudHh0VVQJAAOcZrNqn2azanV4CwABBAAAAAAEAAAAAEtJTctJLElVyE1VSBlljjJHmaPMUeYoc5Q5yhxIJhcAUEsDBAoAAAAAADgtN13z+cmLFAAAABQAAAAUABwAc3JjL3Nob3J0X3N0b3JlZC50eHRVVAkAA5xms2qfZrNqdXgLAAEEAAAAAAQAAAAAc2hvcnQgZmlsZSBjb250ZW50cwpQSwECHgMKAAAAAAAyLTdd8/nJixQAAAAUAAAADQAYAAAAAAABAAAApIEAAAAAc3JjL3Nob3J0LnR4dFVUBQADkGazanV4CwABBAAAAAAEAAAAAFBLAQIeAwoAAAAAADItN10j2PS4CQAAAAkAAAAOABgAAAAAAAAAAAD/oVsAAABzcmMvYWRpci9hbGlua1VUBQADkGazanV4CwABBAAAAAAEAAAAAFBLAQIeAxQAAAAIADgtN13RFerYIAAAAJkIAAALABgAAAAAAAEAAACkgawAAABzcmMvYmlnLnR4dFVUBQADnGazanV4CwABBAAAAAAEAAAAAFBLAQIeAwoAAAAAADgtN13z+cmLFAAAABQAAAAUABgAAAAAAAAAAACkgREBAABzcmMvc2hvcnRfc3RvcmVkLnR4dFVUBQADnGazanV4CwABBAAAAAAEAAAAAFBLBQYAAAAABAAEAFIBAABzAQAAAAA="
  local archive = tmp .. "/sys.zip"
  assert(Fs.write(archive, (assert(Codec.unbase64(ZIP_B64)))))
  local entries = assert(Archive.list(archive))
  local kinds: {string:string} = {}
  for _, e in ipairs(entries) do kinds[e.path] = e.kind end
  assert(kinds["src/adir/alink"] == "symlink")
  local dest = tmp .. "/out"
  assert(Archive.extract(archive, dest, { links = "create" }))
  assert(Fs.readlink(dest .. "/src/adir/alink") == "short.txt")
  -- skipped by default, like a tar symlink, rather than written as a file
  local dest2 = tmp .. "/out2"
  assert(Archive.extract(archive, dest2))
  assert(Fs.exists(dest2 .. "/src/adir/alink") == false)
end

local function test_listed_entries_refuse_to_open_rather_than_read_a_closed_file(tmp: string)
  for _, name in ipairs({ "a.tar", "a.zip" }) do
    local path = tmp .. "/" .. name
    if name == "a.tar" then make_tar(path) else make_zip(path) end
    local entries = assert(Archive.list(path))
    for _, e in ipairs(entries) do
      local body, trouble = e:open()
      assert(body == nil and trouble ~= "", name .. ": " .. e.path)
    end
  end
end

local function test_extract_refuses_a_write_under_a_checked_directory_once_a_symlink_replaces_it(
    tmp: string)
  local archive = tmp .. "/swap2.tar"
  tar_of(archive, function(tw: Tar.Writer)
    assert(tw:add_dir("d"))
    assert(tw:add_file("d/first", "fine\n"))
    assert(tw:add_symlink("d", "."))
    assert(tw:add_file("d/second", "escaped\n"))
  end)
  local dest = tmp .. "/work/dest"
  local written, trouble = Archive.extract(archive, dest, { links = "create" })
  assert(written == nil and trouble:find("through a symlink", 1, true) ~= nil, trouble)
  assert(Fs.exists(tmp .. "/work/second") == false)
end

local function test_extract_walks_a_zip_and_a_tar_to_the_same_tree(tmp: string)
  local t = tmp .. "/same.tar"
  local z = tmp .. "/same.zip"
  local tw = Tar.writer((assert(Stream.create(t))))
  local zw = Zip.writer((assert(Stream.create(z))))
  for i = 1, 300 do
    local p = "d" .. tostring(i % 7) .. "/./f" .. tostring(i)
    assert(tw:add_file(p, "body " .. tostring(i)))
    assert(zw:add_file(p, "body " .. tostring(i)))
  end
  assert(tw:close())
  assert(zw:close())
  local from_tar = assert(Archive.extract(t, tmp .. "/t"))
  local from_zip = assert(Archive.extract(z, tmp .. "/z"))
  assert(#from_tar == 300 and #from_zip == 300)
  for i = 1, 300 do
    local want = "d" .. tostring(i % 7) .. "/f" .. tostring(i)
    assert(from_tar[i] == want and from_zip[i] == want, from_tar[i])
    assert(Fs.read(tmp .. "/t/" .. want) == "body " .. tostring(i))
    assert(Fs.read(tmp .. "/z/" .. want) == "body " .. tostring(i))
  end
end

local function test_extract_reader_unpacks_a_stream_as_extract_unpacks_the_file(tmp: string)
  local path = tmp .. "/a.tar"
  make_tar(path)
  local want = assert(Archive.extract(path, tmp .. "/file", { links = "create" }))
  local reader = assert(Archive.open_stream(Stream.from_string((assert(Fs.read(path))))))
  local got = assert(Archive.extract_reader(reader, tmp .. "/stream", { links = "create" }))
  assert(table.concat(got, ",") == table.concat(want, ","), table.concat(got, ","))
  assert(Fs.read(tmp .. "/stream/adir/short.txt") == "hello there")
  assert(Fs.readlink(tmp .. "/stream/adir/link") == "short.txt")
  assert(Fs.read(tmp .. "/stream/bin/tool") == "#!/bin/sh\necho hi\n")
end

local function test_extract_reader_closes_the_reader_when_it_refuses(tmp: string)
  local sink = Stream.collect()
  local tw = Tar.writer(sink)
  assert(tw:add_file("ok", "1"))
  assert(tw:add_file("../out", "2"))
  assert(tw:close())
  local inner = assert(Archive.open_stream(Stream.from_string(sink:result())))
  local closes = 0
  local counting: Archive.Reader = {
    next = function(_self: Archive.Reader): Archive.Entry | nil, string return inner:next() end,
    close = function(_self: Archive.Reader): boolean, string
      closes = closes + 1
      return inner:close()
    end,
  }
  local written, why = Archive.extract_reader(counting, tmp .. "/dest")
  assert(written == nil and why:find("unsafe entry path", 1, true), why)
  assert(closes == 1, "closed " .. closes .. " times")
  assert(not pcall(Archive.extract_reader, counting, tmp .. "/dest", { max_bytes = -1 }))
end

local function test_extract_resolve_in_lets_a_link_target_pass_through_the_real_destination(tmp: string)
  local sink = Stream.collect()
  local tw = Tar.writer(sink)
  assert(tw:add_symlink("via", "held/inner"))
  assert(tw:close())
  local bytes = sink:result()
  -- Staged apart, `held` is nowhere: refused, unless the real
  -- destination it will be moved into holds it.
  local function unpack(stage: string, opts: Archive.ExtractOptions): {string} | nil, string
    return Archive.extract_reader((assert(Archive.open_stream(Stream.from_string(bytes)))), stage,
      opts)
  end
  local written, why = unpack(tmp .. "/s1", { links = "create" })
  assert(written == nil and why:find("missing directory", 1, true), why)
  assert(Fs.mkdirs(tmp .. "/real/held"))
  assert(unpack(tmp .. "/s2", { links = "create", resolve_in = tmp .. "/real" }))
  assert(Fs.readlink(tmp .. "/s2/via") == "held/inner")
  -- A link the real destination holds in that place is no directory.
  assert(Fs.symlink(".", tmp .. "/real2held"))
  assert(Fs.mkdirs(tmp .. "/real2"))
  assert(Fs.symlink(".", tmp .. "/real2/held"))
  written, why = unpack(tmp .. "/s3", { links = "create", resolve_in = tmp .. "/real2" })
  assert(written == nil and why:find("missing directory", 1, true), why)
end

--- A bad option is blamed on the caller's line, through either entry.
local function test_extract_argument_errors_name_the_callers_line(tmp: string)
  local _, first = pcall(function(): boolean
    Archive.extract(tmp .. "/none", tmp .. "/o1", { max_bytes = -1 })
    return true
  end)
  local _, second = pcall(function(): boolean
    Archive.extract_reader({} as Archive.Reader, tmp .. "/o2", { strip_components = -1 })
    return true
  end)
  for _, why in ipairs({ tostring(first), tostring(second) }) do
    assert(why:find("archive_test:%d+: archive: "), why)
  end
end
