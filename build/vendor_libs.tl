--- The host's release vendor libraries from a bundle a prerelease
--- publishes, in place of compiling them: about 100 s of compile time of
--- a cold boot on a four-core host.
---
---     cosmic --standalone build/vendor_libs.tl ready <root> <manifest>
---     cosmic --standalone build/vendor_libs.tl key <root> <manifest>
---     cosmic --standalone build/vendor_libs.tl pack <root> <manifest> <libs> <out> <url base>
---
--- `<manifest>` is the patched vendor trees' manifest [`build/patch.tl`]
--- prints, which [`bin/zig`] writes and names to zig with `-Dpatched=`.
---
--- `ready` prints the directory holding the host's archives, where
--- bin/vendor-libs.pin names a bundle for this tree's vendor inputs and
--- the host's target, and the bundle is fetched and held to the pin's
--- sha256. It prints nothing where there is no such bundle, or where it
--- cannot be had: then zig compiles the libraries, as it would with no
--- bundle at all. It says why on stderr, and exits 0 either way.
---
--- `key` prints the key of this tree's vendor inputs. `pack` writes one
--- bundle per target directory of `<libs>` (the build directory's
--- `vendor-libs/`, which `bin/zig build vendor-libs` installs) into
--- `<out>`, and prints the pin that names them under `<url base>`.
---
--- A bundle stands for the tree's own compile where every input of the
--- libraries' compiles is the same ([`VendorLibs.key`]): the patched
--- vendor trees, each named by its contents in the manifest; every file
--- under core/ but its own C and Teal (the configuration headers the
--- libraries read, and core/simd_base64.cpp, which simdutf's compiles);
--- patch/zig-lib/, which changes zig's library; build.zig, which holds
--- the flags; build.zig.zon; and bin/zig.pin, the compiler. A tree that
--- differs in any of them compiles the libraries, as it did before.
---
--- Like [`build/zig.tl`], which runs it, this runs standalone, against
--- the running binary's own standard library, so it requires `cosmic.*`
--- modules only. COSMIC_VENDOR_LIBS=0 turns it off. build/zig.tl does
--- not run it under a zig or a zig library the caller names (COSMIC_ZIG,
--- ZIG_LIB_DIR), whose objects are not the pinned zig's.
local Archive = require("cosmic.archive")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Stream = require("cosmic.stream")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

local record VendorLibs
  --- A bundle the pin names: its target, URL and sha256.
  record Bundle
    target: string
    url: string
    sha256: string
  end
  --- bin/vendor-libs.pin: the key of the vendor inputs its bundles were
  --- built from, and one bundle per target.
  record Pin
    key: string
    bundles: {string:Bundle}
  end
  --- The libraries in each bundle, in the order the core links them
  --- (build.zig's `vendor_library_names`, which build/vendor_libs_test.tl
  --- holds this to).
  libraries: {string}
  --- The patched trees the libraries are compiled from.
  trees: {string}
  --- The release targets, by `uname` (build.zig's `targets`).
  records: string
  fetched: function(Bundle, string): string?, string
end

VendorLibs.libraries = { "sqlite", "sqlite-ext", "yyjson", "simdutf", "expat", "lua", "miniz", "sha1dc",
  "nanopb", "monocypher", "bzip2", "xz", "zstd", "mbedtls", "cares", "curl" }

VendorLibs.trees = { "bzip2", "cares", "curl", "expat", "lua", "mbedtls", "miniz", "monocypher", "nanopb",
  "sha1dc", "simdutf", "sqlite", "sqlite-ext", "xz", "yyjson", "zstd" }

VendorLibs.records = "x86_64-linux-musl\tLinux\tx86_64\n" ..
  "aarch64-linux-musl\tLinux\taarch64\n" ..
  "aarch64-macos\tDarwin\tarm64\n"

local pin_path <const> = "bin/vendor-libs.pin"

local function say(text: string)
  local _, _ = Fs.put(Fs.stderr, "vendor libs: " .. text .. "\n")
end

--- The release target of this host, or nil.
local function host_target(): string?
  local name, _ = sys.uname()
  if name == nil then return nil end
  for line in VendorLibs.records:gmatch("[^\n]+") do
    local target, os, arch = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
    if os == name.sysname and arch == name.machine then return target end
  end
  return nil
end

--- Whether `path`, relative to the tree, is an input of the libraries'
--- compiles under core/: anything but the core's own C and Teal.
local function core_input(path: string): boolean
  return not (String.ends_with(path, ".c") or String.ends_with(path, ".tl") or String.ends_with(path, ".lua") or
    String.ends_with(path, ".zig"))
end

--- The key of `root`'s vendor inputs, the patched trees as `manifest`
--- (build/patch.tl's output) names them: a sha256 over one line per
--- input, sorted. Nil and why where an input cannot be read.
function VendorLibs.key(root: string, manifest: string): string?, string
  local lines: mut {string} = {}
  local named: mut {string:string} = {}
  for name, dir in manifest:gmatch("([^\t\n]+)\t([^\n]+)") do
    named[name] = dir:match("([^/]+)$") or dir
  end
  for _, tree in ipairs(VendorLibs.trees) do
    local dir = named[tree]
    if dir == nil then return nil, "the manifest names no patched " .. tree end
    lines[#lines + 1] = "tree " .. dir
  end
  local files: mut {string} = { "build.zig", "build.zig.zon", "bin/zig.pin" }
  for _, under in ipairs({ "core", "patch/zig-lib" }) do
    local walked, trouble = Fs.walk(root .. "/" .. under)
    if walked == nil then return nil, under .. ": " .. tostring(trouble) end
    for _, path in ipairs(walked) do
      if under ~= "core" or core_input(path) then files[#files + 1] = under .. "/" .. path end
    end
  end
  for _, path in ipairs(files) do
    local bytes, trouble = Fs.read(root .. "/" .. path)
    if bytes == nil then return nil, path .. ": " .. tostring(trouble) end
    lines[#lines + 1] = "file " .. path .. " " .. Hash.hex_sha256(bytes)
  end
  table.sort(lines)
  return Hash.hex_sha256(table.concat(lines, "\n") .. "\n"), ""
end

--- bin/vendor-libs.pin's text, read: a `key <sha256>` line, then a
--- `<target> <url> <sha256>` line per bundle. Nil and why where it is
--- any other shape.
function VendorLibs.read_pin(text: string): VendorLibs.Pin?, string
  local key: string? = nil
  local bundles: mut {string:VendorLibs.Bundle} = {}
  for line in text:gmatch("[^\n]+") do
    local given = line:match("^key ([0-9a-f]+)$")
    if given ~= nil and #given == 64 and key == nil then
      key = given
    else
      local target, url, sha256 = line:match("^(%S+) (https://%S+) ([0-9a-f]+)$")
      if target == nil or url == nil or sha256 == nil or #sha256 ~= 64 or bundles[target] ~= nil then
        return nil, pin_path .. ": a line is not `key <sha256>` or `<target> <https url> <sha256>`: " .. line
      end
      bundles[target] = { target = target, url = url, sha256 = sha256 }
    end
  end
  if key == nil then return nil, pin_path .. ": no key line" end
  return { key = key, bundles = bundles }, ""
end

--- The archive names a bundle holds.
local function archive_names(): {string}
  local names: mut {string} = {}
  for _, library in ipairs(VendorLibs.libraries) do
    names[#names + 1] = "libcosmic-" .. library .. ".a"
  end
  return names
end

--- Whether `dir` holds every archive of `bundle_path`, byte for byte:
--- each file's sha256 is held to its entry's.
local function holds(dir: string, bundle_path: string): boolean
  local reader, _ = Archive.open(bundle_path)
  if reader == nil then return false end
  local digests: mut {string:string} = {}
  while true do
    local entry, _ = reader:next()
    if entry == nil then
      local _, _ = reader:close()
      return false
    end
    if entry == false then break end
    local body, _ = entry:open()
    local bytes: string? = nil
    if body ~= nil then
      local read, _ = Stream.read_all(body)
      bytes = read
    end
    if bytes == nil then
      local _, _ = reader:close()
      return false
    end
    digests[entry.path] = Hash.hex_sha256(bytes)
  end
  local _, _ = reader:close()
  for _, name in ipairs(archive_names()) do
    local held, _ = Hash.hex_file("sha256", dir .. "/" .. name)
    if held == nil or digests[name] == nil or held ~= digests[name] then return false end
  end
  return true
end

--- The directory of `bundle`'s archives under `cache`, fetched, held to
--- its sha256 and unpacked where it is not there yet. Nil and why where
--- it cannot be had.
function VendorLibs.fetched(bundle: VendorLibs.Bundle, cache: string): string?, string
  local path = cache .. "/" .. bundle.sha256 .. ".tar.zst"
  local held, _ = Hash.hex_file("sha256", path)
  if held ~= bundle.sha256 then
    local _, _ = Fs.remove(path)
    say("fetching " .. bundle.url)
    local ok, trouble = Http.download(bundle.url, path, { timeout_ns = 120 * 1000000000,
      digests = { sha256 = bundle.sha256 } })
    if not ok then return nil, bundle.url .. ": " .. tostring(trouble) end
  end
  local dir = cache .. "/" .. bundle.sha256
  -- The bundle is held to the pin each time, and what was unpacked from
  -- it to the bundle's entries; it is unpacked again where it differs.
  if holds(dir, path) then return dir, "" end
  -- Unpacked beside `dir`, on its file system, so the rename is atomic;
  -- a boot that dies here leaves the scratch directory to the next
  -- one's sweep.
  local scratch <close>, scratch_trouble = Fs.scratch(cache)
  if scratch == nil then return nil, cache .. ": " .. tostring(scratch_trouble) end
  local unpacked = scratch.path .. "/libs"
  local written, extract_trouble = Archive.extract(path, unpacked)
  if written == nil then return nil, path .. ": " .. tostring(extract_trouble) end
  if not holds(unpacked, path) then
    return nil, path .. ": the bundle does not hold every library"
  end
  -- Another boot sharing the cache may have put it there meanwhile, and
  -- its zig may be reading it: a directory that holds is kept.
  if holds(dir, path) then return dir, "" end
  local _, _ = Fs.remove_tree(dir)
  local moved, move_trouble = Fs.rename(unpacked, dir)
  if not moved then
    if holds(dir, path) then return dir, "" end
    return nil, tostring(move_trouble)
  end
  return dir, ""
end

--- The directory of the host's prebuilt archives for `root`, or nil and
--- why there is none.
function VendorLibs.ready(root: string, manifest: string): string?, string
  if Env.get("COSMIC_VENDOR_LIBS") == "0" then return nil, "" end
  local text, _ = Fs.read(root .. "/" .. pin_path)
  if text == nil then return nil, "" end
  local pin, pin_trouble = VendorLibs.read_pin(text)
  if pin == nil then return nil, pin_trouble end
  local target = host_target()
  if target == nil then return nil, "this host is no release target" end
  local bundle = pin.bundles[target]
  if bundle == nil then return nil, pin_path .. " names no bundle for " .. target end
  local manifest_text, manifest_trouble = Fs.read(manifest)
  if manifest_text == nil then return nil, manifest .. ": " .. tostring(manifest_trouble) end
  local key, key_trouble = VendorLibs.key(root, manifest_text)
  if key == nil then return nil, key_trouble end
  if key ~= pin.key then return nil, "" end
  local cache, cache_trouble = Fs.cache_dir("vendor-libs")
  if cache == nil then return nil, tostring(cache_trouble) end
  return VendorLibs.fetched(bundle, cache)
end

--- Writes a bundle for each target directory of `libs` into `out`, and
--- returns the pin naming them under `base`.
function VendorLibs.pack(root: string, manifest: string, libs: string, out: string, base: string): string?, string
  local key, key_trouble = VendorLibs.key(root, manifest)
  if key == nil then return nil, key_trouble end
  local found, list_trouble = Fs.list(libs)
  if found == nil then return nil, libs .. ": " .. tostring(list_trouble) end
  -- Exactly the release targets: a stray directory from another build
  -- would be published under this tree's key.
  local targets: mut {string} = {}
  for line in VendorLibs.records:gmatch("[^\n]+") do
    targets[#targets + 1] = line:match("^[^\t]+")!
  end
  table.sort(targets)
  local listed: mut {string} = {}
  for _, name in ipairs(found) do listed[#listed + 1] = name end
  table.sort(listed)
  if table.concat(listed, " ") ~= table.concat(targets, " ") then
    return nil, libs .. " holds " .. table.concat(listed, ", ") .. ", not the release targets " ..
      table.concat(targets, ", ")
  end
  local made, make_trouble = Fs.mkdirs(out)
  if not made then return nil, tostring(make_trouble) end
  local lines: mut {string} = { "key " .. key }
  for _, target in ipairs(targets) do
    local name = "vendor-libs-" .. target .. ".tar.zst"
    local path = out .. "/" .. name
    local writer, trouble = Archive.create(path, { deterministic = true })
    if writer == nil then return nil, tostring(trouble) end
    for _, archive in ipairs(archive_names()) do
      local bytes, read_trouble = Fs.read(libs .. "/" .. target .. "/" .. archive)
      if bytes == nil then
        local _, _ = writer:abort()
        return nil, target .. "/" .. archive .. ": " .. tostring(read_trouble)
      end
      local added, add_trouble = writer:add_file(archive, bytes)
      if not added then
        local _, _ = writer:abort()
        return nil, tostring(add_trouble)
      end
    end
    local closed, close_trouble = writer:close()
    if not closed then return nil, tostring(close_trouble) end
    lines[#lines + 1] = target .. " " .. base .. "/" .. name .. " " .. assert(Hash.hex_file("sha256", path))
  end
  return table.concat(lines, "\n") .. "\n", ""
end

function VendorLibs.main(argv: {string}): integer
  local verb = argv[1]
  if verb == "ready" and #argv == 3 then
    local dir, why = VendorLibs.ready(argv[2]!, argv[3]!)
    if dir ~= nil then
      local _, _ = Fs.put(Fs.stdout, dir .. "\n")
    elseif why ~= "" then
      say(why .. "; compiling them")
    end
    return 0
  end
  if (verb == "key" and #argv == 3) or (verb == "pack" and #argv == 6) then
    local manifest, trouble = Fs.read(argv[3]!)
    if manifest == nil then
      say(argv[3]! .. ": " .. tostring(trouble))
      return 1
    end
    local text: string?
    local why: string
    if verb == "key" then
      text, why = VendorLibs.key(argv[2]!, manifest)
      if text ~= nil then text = text .. "\n" end
    else
      text, why = VendorLibs.pack(argv[2]!, manifest, argv[4]!, argv[5]!, argv[6]!)
    end
    if text == nil then
      say(why)
      return 1
    end
    local _, _ = Fs.put(Fs.stdout, text)
    return 0
  end
  say("usage: build/vendor_libs.tl ready <root> <manifest> | key <root> <manifest> | " ..
      "pack <root> <manifest> <libs> <out> <url base>")
  return 2
end

return VendorLibs
