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
local Compress = require("cosmic.compress")
local Archive = require("cosmic.archive")

local compress_dyn: {string:any} = Compress as {string:any}

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

local function test_extract_creates_a_safe_symlink_once_fs_symlink_exists(tmp: string)
  local fs_dyn: {string:any} = Fs as {string:any}
  if fs_dyn.symlink == nil then return end
  local archive = tmp .. "/a.tar"
  make_tar(archive)
  local dest = tmp .. "/out"
  local written = assert(Archive.extract(archive, dest, { links = "create" }))
  local found = false
  for _, rel in ipairs(written) do
    if rel == "adir/link" then found = true end
  end
  assert(found)
end

local function test_a_compressed_tar_whose_decoder_is_missing_names_it(tmp: string)
  if compress_dyn.inflater ~= nil then return end
  local path = tmp .. "/a.tar.gz"
  assert(Fs.write(path, "\31\139" .. string.rep("\0", 30)))
  local r, trouble = Archive.open(path)
  assert(r == nil and trouble:find("gzip support requires cosmic.compress.inflater", 1, true) ~= nil,
    trouble)
end
