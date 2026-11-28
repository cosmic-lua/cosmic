--- What build/vendor_libs.tl keys, packs and reads: the libraries and
--- trees it names are build.zig's, its key moves with what the libraries
--- are compiled from and with nothing else, and the bundles it packs are
--- the same bytes each time.

local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Test = require("cosmic.test")
local VendorLibs = require("build.vendor_libs")

Test.policy{ grants = { { path = "build.zig", letters = "r" } } }

--- The text of build.zig's `vendorLibraries`, the function that compiles
--- the libraries.
local function vendor_libraries_source(): string
  local source = assert(Fs.read("build.zig"))
  local from = assert(source:find("\nfn vendorLibraries(", 1, true))
  local to = assert(source:find("\n}\n", from, true))
  return source:sub(from, to)
end

--- The libraries are build.zig's `vendor_library_names`, in its order,
--- which build.zig holds `vendorLibraries` to.
local function test_the_libraries_are_build_zigs()
  local source = assert(Fs.read("build.zig"))
  local from = assert(source:find("const vendor_library_names = ", 1, true))
  local to = assert(source:find("};", from, true))
  local names: mut {string} = {}
  for name in source:sub(from, to):gmatch('"([^"]+)"') do names[#names + 1] = name end
  assert(table.concat(names, " ") == table.concat(VendorLibs.libraries, " "), table.concat(names, " "))
end

--- Each patched tree `vendorLibraries` compiles from is one the key names.
local function test_the_trees_are_those_the_libraries_compile_from()
  local named: mut {string:boolean} = {}
  for _, tree in ipairs(VendorLibs.trees) do named[tree] = true end
  local count = 0
  for field in vendor_libraries_source():gmatch("sources%.([%w_]+)") do
    if field ~= "own" and field ~= "config" then
      count = count + 1
      local tree = field:gsub("_", "-")
      assert(named[tree] == true, "vendorLibraries compiles from " .. tree .. ", which the key does not name")
    end
  end
  assert(count >= #VendorLibs.trees, tostring(count))
end

--- A file of the tree's own that `vendorLibraries` compiles is one the key
--- reads: none is the core's own C, Teal or Zig, which the key leaves out.
local function test_the_own_files_the_libraries_compile_are_keyed()
  local count = 0
  for path in vendor_libraries_source():gmatch('own%.file%("([^"]+)"%)') do
    count = count + 1
    assert(path:sub(1, 5) == "core/", path)
    for _, suffix in ipairs({ ".c", ".tl", ".lua", ".zig" }) do
      assert(path:sub(-#suffix) ~= suffix, path .. " is compiled into a library but not keyed")
    end
  end
  assert(count >= 1, "vendorLibraries compiles none of the tree's own files")
end

--- A tree with each of the key's inputs, and its manifest.
local function tree(tmp: string): string, string
  local root = tmp .. "/tree"
  for _, dir in ipairs({ "/bin", "/core", "/patch/zig-lib/std" }) do
    assert(Fs.mkdirs(root .. dir))
  end
  assert(Fs.write(root .. "/build.zig", "build"))
  assert(Fs.write(root .. "/build.zig.zon", "zon"))
  assert(Fs.write(root .. "/bin/zig.pin", "zig"))
  assert(Fs.write(root .. "/core/config.h", "#define A 1\n"))
  assert(Fs.write(root .. "/core/main.c", "int main(void) { return 0; }\n"))
  assert(Fs.write(root .. "/core/boot.tl", "return {}\n"))
  assert(Fs.write(root .. "/patch/zig-lib/std/x.zig.patch", "patch"))
  local lines: mut {string} = {}
  for _, name in ipairs(VendorLibs.trees) do
    lines[#lines + 1] = name .. "\t/cache/" .. name .. "-aaaa\n"
  end
  return root, table.concat(lines)
end

--- The key moves with a configuration header, a patched tree, build.zig
--- and the zig library's patches, and stands across an edit of the core's
--- own C or Teal, which the libraries are not compiled from.
local function test_the_key_moves_with_the_libraries_inputs_only(tmp: string)
  local root, manifest = tree(tmp)
  local key = assert(VendorLibs.key(root, manifest))
  assert(#key == 64, key)
  assert(Fs.write(root .. "/core/main.c", "int main(void) { return 1; }\n"))
  assert(Fs.write(root .. "/core/boot.tl", "return { 1 }\n"))
  assert(VendorLibs.key(root, manifest) == key, "an edit of the core's own C moved the key")
  local function moves(what: string)
    local moved = assert(VendorLibs.key(root, manifest))
    assert(moved ~= key, what .. " did not move the key")
    key = moved
  end
  assert(Fs.write(root .. "/core/config.h", "#define A 2\n"))
  moves("a configuration header")
  manifest = manifest:gsub("zstd%-aaaa", "zstd-bbbb")
  moves("a patched tree")
  assert(Fs.write(root .. "/build.zig", "build 2"))
  moves("build.zig")
  assert(Fs.write(root .. "/patch/zig-lib/std/x.zig.patch", "patch 2"))
  moves("a zig library patch")
  local missing, why = VendorLibs.key(root, (manifest:gsub("curl\t[^\n]*\n", "")))
  assert(missing == nil and why == "the manifest names no patched curl", why)
end

--- A pin is a key line and a line per bundle; any other line is refused.
local function test_a_pin_reads_a_key_and_its_bundles()
  local sha = string.rep("a", 64)
  local pin = assert(VendorLibs.read_pin("key " .. sha .. "\n" ..
      "x86_64-linux-musl https://example.com/v-x.tar.zst " .. string.rep("b", 64) .. "\n"))
  assert(pin.key == sha)
  local bundle = assert(pin.bundles["x86_64-linux-musl"])
  assert(bundle.url == "https://example.com/v-x.tar.zst" and bundle.sha256 == string.rep("b", 64))
  for _, text in ipairs({
      "x86_64-linux-musl https://example.com/v " .. sha .. "\n",
      "key " .. sha .. "\nx86_64-linux-musl http://example.com/v " .. sha .. "\n",
      "key " .. sha .. "\nx86_64-linux-musl https://example.com/v abc\n",
      "key abc\n",
  }) do
    local refused, why = VendorLibs.read_pin(text)
    assert(refused == nil and why ~= "", text)
  end
end

--- Packing writes one bundle a target, the same bytes each time, and a
--- pin that names each by its sha256 under the base.
local function test_packing_writes_the_same_bundles_each_time(tmp: string)
  local root, manifest = tree(tmp)
  local libs = tmp .. "/libs"
  for line in VendorLibs.records:gmatch("[^\n]+") do
    local target = assert(line:match("^([^\t]+)"))
    assert(Fs.mkdirs(libs .. "/" .. target))
    for _, library in ipairs(VendorLibs.libraries) do
      assert(Fs.write(libs .. "/" .. target .. "/libcosmic-" .. library .. ".a", target .. " " .. library))
    end
  end
  local texts: mut {string} = {}
  for i = 1, 2 do
    local out = tmp .. "/out" .. tostring(i)
    assert(Fs.mkdirs(out))
    local text = assert(VendorLibs.pack(root, manifest, libs, out, "https://example.com/r"))
    local pin = assert(VendorLibs.read_pin(text))
    assert(pin.key == assert(VendorLibs.key(root, manifest)))
    for target, bundle in pairs(pin.bundles) do
      local name = "vendor-libs-" .. target .. ".tar.zst"
      assert(bundle.url == "https://example.com/r/" .. name, bundle.url)
      assert(bundle.sha256 == assert(Hash.hex_file("sha256", out .. "/" .. name)), target)
    end
    texts[i] = text
  end
  assert(texts[1] == texts[2], "two packs of the same archives differ")
end

--- Packing refuses a libraries directory that holds anything but the
--- release targets, which a stale build directory would.
local function test_packing_refuses_a_stray_target(tmp: string)
  local root, manifest = tree(tmp)
  local libs = tmp .. "/libs"
  for line in VendorLibs.records:gmatch("[^\n]+") do
    assert(Fs.mkdirs(libs .. "/" .. assert(line:match("^([^\t]+)"))))
  end
  assert(Fs.mkdirs(libs .. "/riscv64-linux-musl"))
  local text, why = VendorLibs.pack(root, manifest, libs, tmp .. "/out", "https://example.com/r")
  assert(text == nil and why:find("riscv64-linux-musl", 1, true) ~= nil, why)
end

--- A bundle in the cache is unpacked once; an unpacked directory that
--- holds is kept as it is (a boot's zig may be reading it), and one whose
--- bytes differ from the bundle's, even at the same sizes, is unpacked again.
local function test_the_cache_keeps_what_holds_and_mends_what_does_not(tmp: string)
  local root, manifest = tree(tmp)
  local libs = tmp .. "/libs"
  for line in VendorLibs.records:gmatch("[^\n]+") do
    local target = assert(line:match("^([^\t]+)"))
    assert(Fs.mkdirs(libs .. "/" .. target))
    for _, library in ipairs(VendorLibs.libraries) do
      assert(Fs.write(libs .. "/" .. target .. "/libcosmic-" .. library .. ".a", target .. " " .. library))
    end
  end
  local text = assert(VendorLibs.pack(root, manifest, libs, tmp .. "/out", "https://example.invalid/r"))
  local pin = assert(VendorLibs.read_pin(text))
  local bundle = assert(pin.bundles["x86_64-linux-musl"])
  local cache = tmp .. "/cache"
  assert(Fs.mkdirs(cache))
  assert(Fs.write(cache .. "/" .. bundle.sha256 .. ".tar.zst",
    assert(Fs.read(tmp .. "/out/vendor-libs-x86_64-linux-musl.tar.zst"))))
  local dir = assert(VendorLibs.fetched(bundle, cache))
  local archive = dir .. "/libcosmic-sqlite.a"
  assert(assert(Fs.read(archive)) == "x86_64-linux-musl sqlite")
  local first = assert(Fs.stat(archive))
  assert(VendorLibs.fetched(bundle, cache) == dir)
  assert(assert(Fs.stat(archive)).ino == first.ino, "a directory that holds was unpacked again")
  local same_size = ("x"):rep(#"x86_64-linux-musl sqlite")
  assert(Fs.write(archive, same_size))
  assert(VendorLibs.fetched(bundle, cache) == dir)
  assert(assert(Fs.read(archive)) == "x86_64-linux-musl sqlite", "bytes that differ were kept")
end

--- Packing writes the pin beside the bundles, and names them under the
--- release of the key where no base is given.
local function test_packing_names_the_release_of_the_key(tmp: string)
  local root, manifest = tree(tmp)
  local libs = tmp .. "/libs"
  for line in VendorLibs.records:gmatch("[^\n]+") do
    local target = assert(line:match("^([^\t]+)"))
    assert(Fs.mkdirs(libs .. "/" .. target))
    for _, library in ipairs(VendorLibs.libraries) do
      assert(Fs.write(libs .. "/" .. target .. "/libcosmic-" .. library .. ".a", target .. " " .. library))
    end
  end
  local text = assert(VendorLibs.pack(root, manifest, libs, tmp .. "/out"))
  assert(assert(Fs.read(tmp .. "/out/vendor-libs.pin")) == text)
  local key = assert(VendorLibs.key(root, manifest))
  local base = VendorLibs.base(key)
  assert(base == "https://github.com/cosmic-lua/cosmic/releases/download/vendor-libs-" .. key, base)
  for target, bundle in pairs(assert(VendorLibs.read_pin(text)).bundles) do
    assert(bundle.url == base .. "/vendor-libs-" .. target .. ".tar.zst", bundle.url)
  end
end

--- `pin` writes bin/vendor-libs.pin from the release of the tree's key
--- once each bundle it names holds, and writes nothing where no release
--- holds the key, where its pin names another key, or where a bundle's
--- bytes are not its sha256's.
local function test_pinning_takes_the_release_of_the_key_once_it_holds(tmp: string)
  local root, manifest = tree(tmp)
  local libs = tmp .. "/libs"
  for line in VendorLibs.records:gmatch("[^\n]+") do
    local target = assert(line:match("^([^\t]+)"))
    assert(Fs.mkdirs(libs .. "/" .. target))
    for _, library in ipairs(VendorLibs.libraries) do
      assert(Fs.write(libs .. "/" .. target .. "/libcosmic-" .. library .. ".a", target .. " " .. library))
    end
  end
  local base = "https://example.invalid/release"
  local release = tmp .. "/release"
  local text = assert(VendorLibs.pack(root, manifest, libs, release, base))
  local function download(url: string, path: string, options: Http.DownloadOptions): (true) | (nil, Failure)
    local name = url:match("^https://example%.invalid/release/(.+)$")
    if name == nil then return nil, Failure.new(url .. ": no such release") end
    local bytes, _ = Fs.read(release .. "/" .. name)
    if bytes == nil then return nil, Failure.new(url .. ": HTTP 404") end
    local want = options.digests and options.digests["sha256"]
    if want ~= nil and Hash.hex_sha256(bytes) ~= want then
      return nil, Failure.new(url .. ": sha256 differs")
    end
    assert(Fs.write(path, bytes))
    return true
  end
  local function pinned(cache: string, from: string): string?, string
    local called, written, why = pcall(VendorLibs.pin, root, manifest, cache, from, download)
    if not called then return nil, tostring(written) end
    return written, why
  end
  local missing, missing_why = pinned(tmp .. "/cache0", "https://example.invalid/none")
  local written, why = pinned(tmp .. "/cache1", base)
  local wrong_key = text:gsub("^key %x+", "key " .. string.rep("c", 64))
  assert(Fs.write(release .. "/vendor-libs.pin", wrong_key))
  local stale, stale_why = pinned(tmp .. "/cache2", base)
  assert(Fs.write(release .. "/vendor-libs.pin", text))
  assert(Fs.write(release .. "/vendor-libs-aarch64-macos.tar.zst", "other bytes"))
  local broken, broken_why = pinned(tmp .. "/cache3", base)
  assert(missing == nil and missing_why:find("no release holds the bundles of key", 1, true) ~= nil, missing_why)
  assert(written == text, why)
  assert(assert(Fs.read(root .. "/bin/vendor-libs.pin")) == text)
  assert(stale == nil and stale_why:find("names key " .. string.rep("c", 64), 1, true) ~= nil, stale_why)
  assert(broken == nil and broken_why:find("aarch64-macos", 1, true) ~= nil, broken_why)
end
