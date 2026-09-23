--- `build/vendor.tl` over archives built here -- tar and zip -- and
--- over a plain file for the non-archive, single-file PIN: what the
--- tree holds afterward, and what it refuses.
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")
local vendor = require("build.vendor")

local function write_all(root: string, files: {string:string})
  assert(Fs.mkdirs(root))
  for path, data in pairs(files) do
    local dir = path:match("^(.*)/[^/]+$")
    if dir ~= nil then
      assert(Fs.mkdirs(root .. "/" .. dir))
    end
    assert(Fs.write(root .. "/" .. path, data))
  end
end

--- A tar archive at `path` holding `files`.
local function write_tar(path: string, files: {string:string})
  local w = assert(Stream.create(path))
  local tw = Tar.writer(w)
  for entry_path, data in pairs(files) do
    assert(tw:add_file(entry_path, data))
  end
  assert(tw:close())
end

--- A zip archive at `path` holding `files`.
local function write_zip(path: string, files: {string:string})
  local w = assert(Stream.create(path))
  local zw = Zip.writer(w)
  for entry_path, data in pairs(files) do
    assert(zw:add_file(entry_path, data, { method = "store" }))
  end
  assert(zw:close())
end

--- A tree holding PIN and a stale file, and a tar archive holding
--- `files`; returns what `vendor.tl` exited with.
local function run(dir: string, pin: string, files: {string:string}): integer
  write_all(dir .. "/tree", { ["PIN"] = pin, ["old/gone.c"] = "stale" })
  local archive = dir .. "/archive.tar"
  write_tar(archive, files)
  return vendor({ [1] = dir .. "/tree", [2] = archive })
end

local function test_a_tree_keeps_what_the_pin_names(dir: string)
  local status = run(dir,
    "version 1\nstrip pkg-1/\nkeep src/*.c\nkeep include/**\ndrop src/main.c\n", {
      ["pkg-1/src/one.c"] = "one",
      ["pkg-1/src/main.c"] = "a program's own main",
      ["pkg-1/src/deep/two.c"] = "not one segment down",
      ["pkg-1/include/a/b.h"] = "header",
      ["pkg-1/doc/manual.html"] = "prose",
      ["other/src/three.c"] = "outside the prefix",
    })
  assert(status == 0)
  local tree = dir .. "/tree"
  assert(Fs.read(tree .. "/src/one.c") == "one")
  assert(Fs.read(tree .. "/include/a/b.h") == "header")
  assert(not Fs.exists(tree .. "/src/main.c"))
  assert(not Fs.exists(tree .. "/src/deep"))
  assert(not Fs.exists(tree .. "/doc"))
  assert(not Fs.exists(tree .. "/old"), "the stale tree was not pruned")
  assert(Fs.read(tree .. "/PIN") ~= nil)
end

local function test_a_keep_that_matches_nothing_changes_nothing(dir: string)
  assert(run(dir, "keep missing.c\n", { ["a.c"] = "a" }) == 1)
  assert(Fs.read(dir .. "/tree/old/gone.c") == "stale")
  assert(not Fs.exists(dir .. "/tree/a.c"))
end

local function test_a_pin_with_no_keep_at_all_is_refused(dir: string)
  assert(run(dir, "version 1\n", { ["a.c"] = "a" }) == 1)
  assert(Fs.read(dir .. "/tree/old/gone.c") == "stale")
end

local function test_keeps_from_a_zip_archive_too(dir: string)
  write_all(dir .. "/tree", { ["PIN"] = "strip pkg/\nkeep src/*.c\n" })
  local archive = dir .. "/archive.zip"
  write_zip(archive, {
    ["pkg/src/one.c"] = "one",
    ["pkg/doc/readme.txt"] = "prose",
  })
  local status = vendor({ [1] = dir .. "/tree", [2] = archive })
  assert(status == 0)
  assert(Fs.read(dir .. "/tree/src/one.c") == "one")
  assert(not Fs.exists(dir .. "/tree/doc"))
end

local function test_a_non_archive_file_is_vendored_by_its_url_basename(dir: string)
  write_all(dir .. "/tree",
    { ["PIN"] = "url https://example.com/certs/cacert.pem\n", ["old/gone.c"] = "stale" })
  local archive = dir .. "/cacert.pem"
  assert(Fs.write(archive, "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n"))
  local status = vendor({ [1] = dir .. "/tree", [2] = archive })
  assert(status == 0)
  assert(Fs.read(dir .. "/tree/cacert.pem") ==
    "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n")
  assert(not Fs.exists(dir .. "/tree/old"), "the stale tree was not pruned")
end

local function test_a_non_archive_file_honors_an_explicit_file_name(dir: string)
  write_all(dir .. "/tree",
    { ["PIN"] = "url https://example.com/certs/upstream-name.pem\nfile cacert.pem\n" })
  local archive = dir .. "/upstream-name.pem"
  assert(Fs.write(archive, "cert bytes"))
  local status = vendor({ [1] = dir .. "/tree", [2] = archive })
  assert(status == 0)
  assert(Fs.read(dir .. "/tree/cacert.pem") == "cert bytes")
end

local function test_a_non_archive_file_with_strip_and_no_archive_format_is_refused(dir: string)
  write_all(dir .. "/tree", { ["PIN"] = "strip x/\nkeep *.pem\n" })
  local archive = dir .. "/cacert.pem"
  assert(Fs.write(archive, "not an archive"))
  local status = vendor({ [1] = dir .. "/tree", [2] = archive })
  assert(status == 1)
end
