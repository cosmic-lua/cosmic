--- The processor features a key holds (`declared_key.dispatched`) are
--- those the C the build compiles chooses code by: every file of the
--- core and the vendored libraries -- as their patches leave them --
--- that asks what the processor can do is named here with the features
--- it reads, and each of those is keyed for its machine. A vendor
--- refetch that brings a new site fails here, naming its file, until
--- its features are keyed (in `dispatched` and
--- .github/scripts/host-features.sh alike) and it is named below.
---
--- What glibc's libm chooses for the checked core on a glibc host
--- (`fma`, `avx2`, `fma4`) is in the host's library, not the tree, so
--- no grep finds it: `host_identity`'s comment is its record, and
--- `LIBC` below holds `dispatched` to it.
local Fs = require("cosmic.fs")
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
--- cpuid instruction and its wrappers, the auxiliary vector's hardware
--- capabilities, the compilers' own dispatch, Apple's and Windows'
--- queries, and the AVX state register.
local NEEDLES <const> = { "cpuid", "getauxval", "AT_HWCAP", "HWCAP_", "elf_aux_info",
  "__builtin_cpu_supports", "__builtin_cpu_init", "ifunc", "target_clones",
  "sysctlbyname", "IsProcessorFeaturePresent", "xgetbv" }

local AESNI <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/aesni.c"
local AESCE <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/aesce.c"
local SHA256 <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/sha256.c"
local SHA512 <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/sha512.c"

--- Every file a needle is found in, and the features it reads, by
--- machine: none for one that only configures a site, or asks what is
--- no feature.
local SITES <const>: {string:{string:{string}}} = {
  -- mbedtls's AES-NI: cpuid leaf 1, ECX bits 25 and 1.
  [AESNI] = { x86_64 = { "aes", "pclmulqdq" } },
  -- mbedtls's AES instructions: HWCAP_ASIMD and HWCAP_AES, and it runs
  -- pmull, which the kernel lists with aes.
  [AESCE] = { aarch64 = { "asimd", "aes", "pmull" } },
  -- mbedtls's SHA-2 instructions, compiled out: no
  -- MBEDTLS_SHA*_USE_* is set (`test_the_sha_instructions_are_compiled_out`).
  [SHA256] = {},
  [SHA512] = {},
  -- xz's CRC32 and CRC64 by carry-less multiply: cpuid leaf 1, ECX
  -- bits 1, 9 and 19.
  ["vendor/xz/src/liblzma/check/crc_x86_clmul.h"] = { x86_64 = { "pclmulqdq", "ssse3",
    "sse4_1" } },
  -- xz's CRC32: HWCAP_CRC32.
  ["vendor/xz/src/liblzma/check/crc32_arm64.h"] = { aarch64 = { "crc32" } },
  -- Whether xz compiles crc32_arm64.h's check in, and the configuration
  -- that says it may: neither reads a feature.
  ["vendor/xz/src/liblzma/check/crc_common.h"] = {},
  ["core/xz_config/config.h"] = {},
  -- The processor count on Apple (sysctlbyname("hw.ncpu")): no feature.
  ["vendor/sqlite/sqlite3.c"] = {},
}

--- What glibc's libm reads for the checked core, which no grep of the
--- tree finds (the module's comment).
local LIBC <const>: {string:{string}} = { x86_64 = { "avx2", "fma", "fma4" } }

--- Each file under the trees build.zig compiles C from that holds a
--- needle, as a path of the tree.
local function sites(): {string:boolean}
  local found: {string:boolean} = {}
  local function scan(path: string)
    local text = assert(Fs.read(path))
    for _, needle in ipairs(NEEDLES) do
      if text:find(needle, 1, true) ~= nil then
        found[path] = true
        return
      end
    end
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
  for path in pairs(found) do
    assert(SITES[path] ~= nil, path .. " asks what the processor can do: key the features it " ..
      "reads in build/declared_key.tl's `dispatched` and .github/scripts/host-features.sh, " ..
      "and name it in SITES")
  end
  for path in pairs(SITES) do
    assert(found[path], path .. " no longer asks what the processor can do: drop it from SITES")
  end
end

local function test_every_feature_a_site_reads_is_keyed()
  local want: {string:{string:boolean}} = {}
  local function add(machine: string, flags: {string})
    want[machine] = want[machine] or {}
    for _, flag in ipairs(flags) do want[machine][flag] = true end
  end
  for _, machines in pairs(SITES) do
    for machine, flags in pairs(machines) do add(machine, flags) end
  end
  for machine, flags in pairs(LIBC) do add(machine, flags) end
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
  for _, machine in ipairs({ "x86_64", "aarch64" }) do
    assert(want[machine] ~= nil, machine .. " is audited but has no site")
  end
end

--- mbedtls's SHA-2 instruction paths are compiled only for a
--- MBEDTLS_SHA*_USE_* definition, which neither the configuration the
--- build names nor build.zig makes.
local function test_the_sha_instructions_are_compiled_out()
  for _, path in ipairs({ "core/mbedtls_cosmic_config.h", "build.zig" }) do
    local text = assert(Fs.read(path))
    assert(text:find("MBEDTLS_SHA%d+_USE_") == nil, path .. " enables a SHA-2 instruction path")
  end
  for _, path in ipairs({ SHA256, SHA512 }) do
    local text = assert(Fs.read(path))
    assert(text:find("MBEDTLS_SHA%d+_USE_") ~= nil, path .. " gates its instructions otherwise")
  end
end
