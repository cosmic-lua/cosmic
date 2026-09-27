--- The processor features a key holds (`declared_key.dispatched`) are
--- those the C the build compiles chooses code by: every file of the
--- core, of the vendored libraries as fetched and of the patch records
--- applied to them, that asks what the processor can do is named here
--- with the features it reads and a digest of the lines that ask and
--- the dozen after each, where the bits asked for are read (`asking`),
--- and each of those features is keyed for its machine. A vendor refetch
--- or a patch that brings a new site, or a new question to a named one,
--- fails here, naming its file, until its features are keyed (in
--- `dispatched` and .github/scripts/host-features.sh alike) and it is
--- named below.
---
--- The walk does not reach zig's own lib (compiler_rt) or musl, which
--- the audit that chose `dispatched` read: a change of the zig pin is
--- unguarded here.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local declared_key = require("build.declared_key")
local Test = require("cosmic.test")

--- Every tree build.zig compiles C from: the core's own, the vendored
--- libraries' and the patches it applies to them, and build.zig itself,
--- which names them and passes the compiler's definitions.
Test.needs{ reads = { "build.zig", "core/", "patch/", "vendor/bzip2/", "vendor/cares/",
  "vendor/curl/", "vendor/lua/", "vendor/mbedtls/", "vendor/miniz/", "vendor/sqlite/",
  "vendor/xz/", "vendor/yyjson/" } }

--- The vendored libraries build.zig compiles C from, each walked whole.
local LIBRARIES <const> = { "bzip2", "cares", "curl", "lua", "mbedtls", "miniz", "sqlite",
  "xz", "yyjson" }

--- The vendored trees build.zig patches that hold no C: the Teal
--- compiler, which the core loads as Lua.
local NOT_C <const>: {string:boolean} = { tl = true }

--- What code that asks what the processor can do calls or spells: the
--- cpuid instruction and its wrappers, the compilers' own dispatch and
--- the tables behind it, the auxiliary vector's hardware capabilities
--- and arm's ID registers, Linux's /proc/cpuinfo, Apple's and Windows'
--- queries, and the AVX state register. `hwcap` is matched in any
--- case besides, and `PATTERNS` too.
local NEEDLES <const> = { "cpuid", "getauxval", "AT_HWCAP", "HWCAP_", "elf_aux_info",
  "ID_AA64", "cpuinfo", "__builtin_cpu_supports", "__builtin_cpu_init", "__cpu_model",
  "__cpu_indicator", "ifunc", "target_clones", "sysctlbyname", "hw.optional",
  "IsProcessorFeaturePresent", "xgetbv" }

--- Lua patterns a line is matched against besides: the cpuid bits
--- mbedtls's AES-NI is asked about, which aesni.h defines apart from
--- the code that asks.
local PATTERNS <const> = { "#define MBEDTLS_AESNI_%u+%s+0x%x+" }

--- How many lines after each that asks `asking` holds too, where the
--- bits asked for are read (xz's `ecx_mask`, eleven lines after its
--- cpuid).
local AFTER <const> = 12

local AESNI <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/aesni.c"
local AESCE <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/aesce.c"
local SHA256 <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/sha256.c"
local SHA512 <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/sha512.c"

--- A file that asks what the processor can do: the first 16 hex digits
--- of the sha256 of the lines `asking` finds in it, and the
--- features it reads, by machine -- none for one that only configures
--- a site, or asks what is no feature.
local record Site
  lines: string
  reads: {string:{string}}
end

local SITES <const>: {string:Site} = {
  -- mbedtls's AES-NI: cpuid leaf 1, ECX bits 25 and 1 ...
  [AESNI] = { lines = "47d2248fdd65bde3", reads = { x86_64 = { "aes", "pclmulqdq" } } },
  -- ... which aesni.h names.
  ["vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/aesni.h"] = { lines = "52e680e7c3f51daa",
    reads = {} },
  -- mbedtls's AES instructions: HWCAP_ASIMD and HWCAP_AES, and it runs
  -- pmull, which the kernel lists with aes.
  [AESCE] = { lines = "bb97ae0e43fe952e", reads = { aarch64 = { "asimd", "aes", "pmull" } } },
  -- mbedtls's SHA-2 instructions, compiled out: no
  -- MBEDTLS_SHA*_USE_* is set (`test_the_sha_instructions_are_compiled_out`).
  [SHA256] = { lines = "348fc7a6aafc5db0", reads = {} },
  [SHA512] = { lines = "08b640331951aadd", reads = {} },
  -- xz's CRC32 and CRC64 by carry-less multiply: cpuid leaf 1, ECX
  -- bits 1, 9 and 19.
  ["vendor/xz/src/liblzma/check/crc_x86_clmul.h"] = { lines = "3df82a3bd7e3826c",
    reads = { x86_64 = { "pclmulqdq", "ssse3", "sse4_1" } } },
  -- xz's CRC32: HWCAP_CRC32.
  ["vendor/xz/src/liblzma/check/crc32_arm64.h"] = { lines = "82240c4bfa8815ab",
    reads = { aarch64 = { "crc32" } } },
  -- Whether xz compiles crc32_arm64.h's check in, and the configuration
  -- that says it may: neither reads a feature.
  ["vendor/xz/src/liblzma/check/crc_common.h"] = { lines = "02b9a4dfc40599e0", reads = {} },
  ["core/xz_config/config.h"] = { lines = "6696e76730b82c2d", reads = {} },
  -- The processor count on Apple (sysctlbyname("hw.ncpu")): no feature.
  ["vendor/sqlite/sqlite3.c"] = { lines = "7b27815aae63deac", reads = {} },
}

--- The lines of `text` that hold a needle or match a pattern, and the
--- `AFTER` lines after each, in order, each once.
local function asking(text: string): {string}
  -- Most files hold none: seen whole first, not split into lines.
  local any = text:lower():find("hwcap", 1, true) ~= nil
  for _, needle in ipairs(NEEDLES) do
    if any then break end
    any = text:find(needle, 1, true) ~= nil
  end
  for _, pattern in ipairs(PATTERNS) do
    if any then break end
    any = text:find(pattern) ~= nil
  end
  if not any then return {} end
  local lines: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  local kept: {integer:boolean} = {}
  for i, line in ipairs(lines) do
    local hit = line:lower():find("hwcap", 1, true) ~= nil
    for _, needle in ipairs(NEEDLES) do
      if hit then break end
      hit = line:find(needle, 1, true) ~= nil
    end
    for _, pattern in ipairs(PATTERNS) do
      if hit then break end
      hit = line:find(pattern) ~= nil
    end
    if hit then
      for j = i, math.min(i + AFTER, #lines) do kept[j] = true end
    end
  end
  local found: {string} = {}
  for i, line in ipairs(lines) do
    if kept[i] then found[#found + 1] = line end
  end
  return found
end

--- Each file under the trees build.zig compiles C from that holds a
--- needle, as a path of the tree, with its lines that do (`asking`).
local function sites(): {string:{string}}
  local found: {string:{string}} = {}
  local function scan(path: string)
    local lines = asking((assert(Fs.read(path))))
    if #lines > 0 then found[path] = lines end
  end
  local roots: {string} = { "core", "patch" }
  for _, library in ipairs(LIBRARIES) do roots[#roots + 1] = "vendor/" .. library end
  for _, root in ipairs(roots) do
    for _, relative in ipairs((assert(Fs.walk(root)))) do scan(root .. "/" .. relative) end
  end
  scan("build.zig")
  return found
end

local function test_every_library_build_zig_compiles_is_walked()
  local source = assert(Fs.read("build.zig"))
  local walked: {string:boolean} = {}
  for _, library in ipairs(LIBRARIES) do walked[library] = true end
  local count = 0
  for library in source:gmatch('patched%(b, trees, "([%w_]+)"%)') do
    count = count + 1
    assert(walked[library] or NOT_C[library], "build.zig compiles vendor/" .. library ..
      ", which this test does not walk: add it to LIBRARIES and to Test.needs")
  end
  assert(count >= #LIBRARIES, "build.zig names " .. count .. " patched trees")
end

local function test_every_site_that_asks_the_processor_is_named()
  local found = sites()
  local problems: {string} = {}
  for path, lines in pairs(found) do
    local site = SITES[path]
    local digest = Hash.hex_sha256(table.concat(lines, "\n")):sub(1, 16)
    if site == nil then
      problems[#problems + 1] = path .. " asks what the processor can do: key the features " ..
        "it reads in build/declared_key.tl's `dispatched` and " ..
        ".github/scripts/host-features.sh, and name it in SITES (lines = \"" .. digest ..
        "\"), or name it with `reads = {}` if it reads none"
    elseif site.lines ~= digest then
      problems[#problems + 1] = path .. " asks the processor otherwise than SITES says " ..
        "(lines = \"" .. digest .. "\"): read what it asks now, key what it reads, then " ..
        "take the new digest:\n  " .. table.concat(lines, "\n  ")
    end
  end
  for path in pairs(SITES) do
    if found[path] == nil then
      problems[#problems + 1] = path .. " no longer asks what the processor can do: drop it " ..
        "from SITES"
    end
  end
  table.sort(problems)
  assert(#problems == 0, table.concat(problems, "\n"))
end

local function test_every_feature_a_site_reads_is_keyed()
  local want: {string:{string:boolean}} = {}
  local function add(machine: string, flags: {string})
    want[machine] = want[machine] or {}
    for _, flag in ipairs(flags) do want[machine][flag] = true end
  end
  for _, site in pairs(SITES) do
    for machine, flags in pairs(site.reads) do add(machine, flags) end
  end
  for machine, flags in pairs(want) do
    local keyed = declared_key.dispatched(machine)
    assert(keyed ~= nil, machine .. " has sites but no audited list")
    local have: {string:boolean} = {}
    for _, flag in ipairs(keyed) do have[flag] = true end
    for flag in pairs(flags) do
      assert(have[flag], machine .. ": " .. flag .. " is read but not keyed")
    end
    -- Nor is anything keyed that nothing reads: it would split verdicts.
    for flag in pairs(have) do
      assert(flags[flag], machine .. ": " .. flag .. " is keyed but nothing reads it")
    end
  end
  -- Nor is a machine audited that no site names: its key would hold
  -- none of its features where it held them all.
  for _, machine in ipairs(declared_key.dispatched()) do
    assert(want[machine] ~= nil, machine .. " is audited but no site names it")
  end
end

--- mbedtls's SHA-2 instruction paths are compiled only for a
--- MBEDTLS_SHA*_USE_* definition, which neither the configuration the
--- build names, build.zig nor a patch makes.
local function test_the_sha_instructions_are_compiled_out()
  local paths: {string} = { "core/mbedtls_cosmic_config.h", "build.zig" }
  for _, relative in ipairs((assert(Fs.walk("patch")))) do
    paths[#paths + 1] = "patch/" .. relative
  end
  for _, path in ipairs(paths) do
    local text = assert(Fs.read(path))
    assert(text:find("MBEDTLS_SHA%d+_USE_") == nil, path .. " enables a SHA-2 instruction path")
  end
  for _, path in ipairs({ SHA256, SHA512 }) do
    local text = assert(Fs.read(path))
    assert(text:find("MBEDTLS_SHA%d+_USE_") ~= nil, path .. " gates its instructions otherwise")
  end
end
