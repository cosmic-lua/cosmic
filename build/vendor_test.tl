--- `build/vendor.tl` over archives built here -- tar and zip -- and
--- over a plain file for the non-archive, single-file PIN: what the
--- tree holds afterward, and what it refuses.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")
local Fetch = require("build.fetch")
local VendorLib = require("build.vendor_lib")
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

local function test_read_pin_captures_sha256()
  local pin = assert(VendorLib.read_pin("url https://example.com/a.tar\nsha256 abc123\n"))
  assert(pin.url == "https://example.com/a.tar")
  assert(pin.sha256 == "abc123")
end

local function test_is_direct_rewrite_needs_a_slash_in_the_first_argument()
  assert(VendorLib.is_direct_rewrite({ [1] = "vendor/curl", [2] = "/tmp/curl.tar.gz" }))
  assert(not VendorLib.is_direct_rewrite({ [1] = "curl" }))
  assert(not VendorLib.is_direct_rewrite({ [1] = "curl", [2] = "mbedtls" }))
  assert(not VendorLib.is_direct_rewrite({}))
end

local function test_all_names_lists_every_tree_with_a_pin(dir: string)
  assert(Fs.mkdirs(dir .. "/vendor/alpha"))
  assert(Fs.write(dir .. "/vendor/alpha/PIN", "url https://example.com/a\n"))
  assert(Fs.mkdirs(dir .. "/vendor/beta"))
  assert(Fs.write(dir .. "/vendor/beta/PIN", "url https://example.com/b\n"))
  assert(Fs.mkdirs(dir .. "/vendor/not-vendored")) -- no PIN file
  local names = assert(VendorLib.all_names(dir))
  assert(#names == 2)
  assert(names[1] == "alpha" and names[2] == "beta")
end

local function test_repo_root_from_the_scripts_own_path(dir: string)
  assert(Fs.mkdirs(dir .. "/repo/build"))
  assert(Fs.write(dir .. "/repo/build/vendor.tl", "-- stand-in"))
  local root = assert(VendorLib.repo_root(dir .. "/repo/build/vendor.tl"))
  assert(root == assert(Fs.absolute(dir .. "/repo")))
end

--- `fetch_and_rewrite`'s own fetch step, isolated: `Fetch.file`'s cache
--- hit (the sha256 already on disk matches the PIN's) is what a
--- name-list-mode run relies on to avoid the network; this proves that
--- step end to end without depending on `$XDG_CACHE_HOME`, which a
--- unit test cannot set for just itself.
local function test_the_fetch_step_is_a_cache_hit_when_already_verified(dir: string)
  local archive = dir .. "/upstream.tar"
  write_tar(archive, {
    ["thing-1/src/one.c"] = "one",
    ["thing-1/doc/readme"] = "prose",
  })
  local data = assert(Fs.read(archive))
  local digest = Hash.hex_sha256(data)

  local cached = dir .. "/cache/thing-1.tar"
  assert(Fs.mkdirs(dir .. "/cache"))
  assert(Fs.write(cached, data))

  local fetched = assert(Fetch.file("https://example.invalid/thing-1.tar", cached, digest))
  assert(fetched == cached)

  local tree = dir .. "/vendor/thing"
  assert(Fs.mkdirs(tree))
  assert(Fs.write(tree .. "/PIN", "strip thing-1/\nkeep src/*.c\n"))
  assert(vendor({ [1] = tree, [2] = fetched }) == 0)
  assert(Fs.read(tree .. "/src/one.c") == "one")
  assert(not Fs.exists(tree .. "/doc"))
end
