--- `build/vendor.tl` over archives built here -- tar and zip -- and
--- over a plain file for the single-file PIN: what the tree holds
--- afterward, and what it refuses.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")
local sys = require("cosmic.sys")
local Vendor = require("build.vendor")

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

--- A tar archive at `path` holding `files`, each with `modes[path]` or
--- the default mode.
local function write_tar(path: string, files: {string:string}, modes?: {string:integer})
  local w = assert(Stream.create(path))
  local tw = Tar.writer(w)
  for entry_path, data in pairs(files) do
    local mode = modes ~= nil and modes[entry_path] or nil
    assert(tw:add_file(entry_path, data, { mode = mode }))
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
local function run(dir: string, pin: string, files: {string:string},
                   modes?: {string:integer}): integer
  write_all(dir .. "/tree", { ["PIN"] = pin, ["old/gone.c"] = "stale" })
  local archive = dir .. "/archive.tar"
  write_tar(archive, files, modes)
  return Vendor.main({ [1] = dir .. "/tree", [2] = archive })
end

--- Nothing but the tree itself is left beside it: no scratch directory.
local function only_the_tree(dir: string)
  local names = assert(Fs.list(dir))
  for _, name in ipairs(names) do
    assert(name:find("vendor", 1, true) == nil, "a scratch directory was left: " .. name)
  end
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
  only_the_tree(dir)
end

local function test_a_leading_dot_slash_is_not_part_of_a_path(dir: string)
  assert(run(dir, "strip pkg/\nkeep src/*.c\n", {
    ["./pkg/src/one.c"] = "one",
  }) == 0)
  assert(Fs.read(dir .. "/tree/src/one.c") == "one")
end

local function test_permission_bits_survive(dir: string)
  assert(run(dir, "strip pkg/\nkeep bin/*\n", {
    ["pkg/bin/tool"] = "#!/bin/sh\n",
  }, { ["pkg/bin/tool"] = 0x1ed }) == 0)
  local st = assert(sys.stat(dir .. "/tree/bin/tool"))
  assert(st.mode & 0x1ff == 0x1ed, "the executable bit was dropped")
end

local function test_an_escaping_entry_refuses_the_whole_archive(dir: string)
  assert(run(dir, "keep *.c\n", {
    ["a.c"] = "a",
    ["../escaped.c"] = "out",
  }) == 1)
  assert(not Fs.exists(dir .. "/escaped.c"))
  assert(Fs.read(dir .. "/tree/old/gone.c") == "stale", "the tree changed")
  only_the_tree(dir)
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
  assert(Vendor.main({ [1] = dir .. "/tree", [2] = archive }) == 0)
  assert(Fs.read(dir .. "/tree/src/one.c") == "one")
  assert(not Fs.exists(dir .. "/tree/doc"))
end

local function test_a_single_file_pin_vendors_the_download_as_its_file(dir: string)
  write_all(dir .. "/tree", {
    ["PIN"] = "url https://example.com/certs/upstream-name.pem\nfile cacert.pem\nkeep cacert.pem\n",
    ["old/gone.c"] = "stale",
  })
  local download = dir .. "/upstream-name.pem"
  assert(Fs.write(download, "cert bytes"))
  assert(Vendor.main({ [1] = dir .. "/tree", [2] = download }) == 0)
  assert(Fs.read(dir .. "/tree/cacert.pem") == "cert bytes")
  assert(not Fs.exists(dir .. "/tree/old"), "the stale tree was not pruned")
end

local function test_a_single_file_pin_whose_keep_misses_its_file_is_refused(dir: string)
  write_all(dir .. "/tree", { ["PIN"] = "file cacert.pem\nkeep other.pem\n" })
  local download = dir .. "/cacert.pem"
  assert(Fs.write(download, "cert bytes"))
  assert(Vendor.main({ [1] = dir .. "/tree", [2] = download }) == 1)
  assert(not Fs.exists(dir .. "/tree/cacert.pem"))
end

--- The regression: an archive `cosmic.archive` cannot read, under a PIN
--- that names no `file`, used to be vendored as one blob, ignoring
--- every keep, and exit 0.
local function test_an_unreadable_archive_without_a_file_line_is_an_error(dir: string)
  write_all(dir .. "/tree", {
    ["PIN"] = "url https://example.com/pkg.tar.gz\nkeep src/*.c\n",
    ["src/kept.c"] = "the tree as it was",
  })
  local download = dir .. "/pkg.tar.gz"
  assert(Fs.write(download, "not an archive at all"))
  assert(Vendor.main({ [1] = dir .. "/tree", [2] = download }) == 1)
  assert(Fs.read(dir .. "/tree/src/kept.c") == "the tree as it was")
  assert(not Fs.exists(dir .. "/tree/pkg.tar.gz"))
end

local function test_read_pin_takes_the_first_word_and_the_first_line()
  local pin = (Vendor.read_pin(
    "url https://example.com/a.tar  \r\nsha256 abc123\r\nsha256 def456\n" ..
    "keep a/*.c \r\nkeep b.h\n"))
  assert(pin.url == "https://example.com/a.tar")
  assert(pin.sha256 == "abc123")
  assert(#pin.keep == 2 and pin.keep[1] == "a/*.c" and pin.keep[2] == "b.h")
end

local function test_is_direct_rewrite_needs_a_slash_in_the_first_argument()
  assert(Vendor.is_direct_rewrite({ [1] = "vendor/curl", [2] = "/tmp/curl.tar.gz" }))
  assert(not Vendor.is_direct_rewrite({ [1] = "curl" }))
  assert(not Vendor.is_direct_rewrite({ [1] = "curl", [2] = "mbedtls" }))
  assert(not Vendor.is_direct_rewrite({}))
end

local function test_all_names_lists_every_tree_with_a_pin(dir: string)
  assert(Fs.mkdirs(dir .. "/vendor/alpha"))
  assert(Fs.write(dir .. "/vendor/alpha/PIN", "url https://example.com/a\n"))
  assert(Fs.mkdirs(dir .. "/vendor/beta"))
  assert(Fs.write(dir .. "/vendor/beta/PIN", "url https://example.com/b\n"))
  assert(Fs.mkdirs(dir .. "/vendor/not-vendored")) -- no PIN file
  local names = assert(Vendor.all_names(dir))
  assert(#names == 2)
  assert(names[1] == "alpha" and names[2] == "beta")
end

local function test_repo_root_from_the_scripts_own_path(dir: string)
  assert(Fs.mkdirs(dir .. "/repo/build"))
  assert(Fs.write(dir .. "/repo/build/vendor.tl", "-- stand-in"))
  local root = assert(Vendor.repo_root(dir .. "/repo/build/vendor.tl"))
  assert(root == assert(Fs.absolute(dir .. "/repo")))
end

local function test_matches_compares_sha256_case_insensitively(dir: string)
  local path = dir .. "/data"
  assert(Fs.write(path, "hello"))
  local digest = Hash.hex_sha256("hello")
  assert(Vendor.matches(path, digest))
  assert(Vendor.matches(path, digest:upper()))
  assert(not Vendor.matches(path, (digest:gsub("^.", "0"))))
  assert(not Vendor.matches(dir .. "/nothing-here", digest))
end

--- A verified cached download is reused: the url is one no fetch
--- could reach, so success proves the network was never touched.
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
  local fetched = assert(Vendor.fetch("https://example.invalid/thing-1.tar", cached, digest))
  assert(fetched == cached)

  local tree = dir .. "/vendor/thing"
  assert(Fs.mkdirs(tree))
  assert(Fs.write(tree .. "/PIN", "strip thing-1/\nkeep src/*.c\n"))
  assert(Vendor.main({ [1] = tree, [2] = fetched }) == 0)
  assert(Fs.read(tree .. "/src/one.c") == "one")
  assert(not Fs.exists(tree .. "/doc"))
end

local function test_a_word_like_an_option_is_refused_not_read_as_a_name(dir: string)
  -- A script path under a repository, so the run gets as far as the
  -- names: without the refusal it looks for vendor/--dry-run/PIN there
  -- and fails with 1.
  assert(Fs.mkdirs(dir .. "/repo/build"))
  assert(Fs.write(dir .. "/repo/build/vendor.tl", ""))
  assert(Vendor.main({ [0] = dir .. "/repo/build/vendor.tl", [1] = "--dry-run" }) == 2)
end
