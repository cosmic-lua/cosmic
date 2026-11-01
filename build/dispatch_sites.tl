--- Which lines of the core's C turn on the processor's features, as the
--- audit of build/dispatched_features_test.tl finds them, and the sites
--- that audit names. A test that runs one has an outcome that can differ
--- between hosts of other processors, so its module declares
--- `cpu_features` in its [`Test.policy`] ([`build.test`] fails it
--- otherwise, naming the function).
---
--- What counts is derived from the audit, not listed by hand. In a core
--- file that is itself a site reading a feature (core/vector.c), it is a
--- function that takes a feature's code (one compiled for it, with a
--- `target` attribute) and the lines that call through a pointer the file
--- assigns such a function to: the function that picks the code at start
--- is not, since it runs whenever the file is loaded and the code it picks
--- is run by the callers. A site file with no such function counts whole.
--- Elsewhere in the core it is each line that calls the API of a library
--- that has a site reading a feature (`api`: psa_ and mbedtls_ for
--- mbedtls, lzma_ for xz). The C of a library is not among the core's
--- functions, so a test reaches it only through a core line that calls
--- it, and the call is how this finds it. A line is what counts, not its
--- function: a function that serves several codecs (core/compress.c's
--- `stream_update`) calls xz on lines only an xz stream runs.

local c_functions = require("build.c_functions")

local record dispatch_sites
  --- A file that asks what the processor can do: the first 16 hex digits
  --- of the sha256 of the lines the audit finds in it, and the
  --- features it reads, by machine -- none for one that only configures
  --- a site, or asks what is no feature.
  record Site
    lines: string
    reads: {string:{string}}
  end
  --- Lines of one function of the core that turn on the processor: its
  --- key ([`c_functions.Span`]'s), its file, the lines, and why they do.
  record Reach
    key: string
    path: string
    lines: {integer}
    why: string
  end
  --- Every file of the core, the vendored libraries and the patches that
  --- asks what the processor can do, by path of the tree.
  mut sites: {string:Site}
  --- The prefixes of the names each library with a site that reads a
  --- feature exports, by library: the name of its directory under vendor/
  --- and patch/.
  mut api: {string:{string}}
  --- The libraries with a site that reads a feature, sorted.
  libraries: function(): {string}
  --- The lines of `spans`, the core's functions, that turn on the
  --- processor, with `sources`, each file's lines.
  reaching: function(spans: {c_functions.Span}, sources: {string:{string}}): {Reach}
  --- Why a test whose module does not declare `cpu_features` fails for
  --- running the `reaches` that `hits`, the lines of the core's C it ran,
  --- name: the functions and the fix. "" where it ran none.
  failure: function(reaches: {Reach}, hits: {string:{integer:boolean}}): string
end

--- A name a library's API begins with.
local record Prefix
  library: string
  prefix: string
end

local AESNI <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/aesni.c"
local AESCE <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/aesce.c"
local SHA256 <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/sha256.c"
local SHA512 <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/sha512.c"

local sites: {string:dispatch_sites.Site} = {
  -- mbedtls's AES-NI: cpuid leaf 1, ECX bits 25 and 1 ...
  [AESNI] = { lines = "47d2248fdd65bde3", reads = { x86_64 = { "aes", "pclmulqdq" } } },
  -- ... which aesni.h names.
  ["vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/aesni.h"] = { lines = "52e680e7c3f51daa",
    reads = {} },
  -- mbedtls's AES instructions: HWCAP_ASIMD and HWCAP_AES, and it runs
  -- pmull, which the kernel lists with aes.
  [AESCE] = { lines = "bb97ae0e43fe952e", reads = { aarch64 = { "asimd", "aes", "pmull" } } },
  -- mbedtls's Armv8 SHA-2 instructions, chosen at run time
  -- (build/dispatched_features_test.tl's `test_the_sha_instructions_are_chosen_at_run_time`): HWCAP_SHA2 and
  -- HWCAP_SHA512, and on Apple sysctl (hw.optional.armv8_2_sha512; SHA-256
  -- is assumed there).
  [SHA256] = { lines = "348fc7a6aafc5db0", reads = { aarch64 = { "sha2" } } },
  [SHA512] = { lines = "08b640331951aadd", reads = { aarch64 = { "sha512" } } },
  -- patch/mbedtls's SHA-NI SHA-256: cpuid leaf 7 EBX bit 29, with the
  -- SSSE3 and SSE4.1 bits of leaf 1 its shuffles and blends need ...
  ["patch/mbedtls/04-sha256-ni.txt"] = { lines = "a2bc2eeb6868491a",
    reads = { x86_64 = { "sha_ni", "sse4_1", "ssse3" } } },
  -- ... and the header that declares __get_cpuid_count.
  ["patch/mbedtls/03-sha256-ni-select.txt"] = { lines = "bfdef8b0c7ebba67", reads = {} },
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
  -- zstd's cpuid, and the two that call it for BMI1 and BMI2: every
  -- choice made by what it answers is under `#if DYNAMIC_BMI2`, which
  -- build.zig sets to 0, so it chooses no code.
  ["vendor/zstd/lib/common/cpu.h"] = { lines = "2a52cdfcf036b836", reads = {} },
  ["vendor/zstd/lib/common/zstd_internal.h"] = { lines = "7db2f12b59d3e0b4", reads = {} },
  ["vendor/zstd/lib/compress/zstd_compress.c"] = { lines = "e1810b0562e88cca", reads = {} },
  -- `cpu_features`, which answers what the processor has for a key
  -- (build/declared_key.tl's `features`), its declaration and its test:
  -- none chooses code by it. syscalls.c asks Apple's
  -- kern.maxfilesperproc too, for the descriptor limit a start raises
  -- to: no feature.
  ["core/syscalls.c"] = { lines = "6d6f8c1e9f60c406", reads = {} },
  ["core/syscalls.h"] = { lines = "297b223c6bbcbc65", reads = {} },
  ["core/syscalls_test.tl"] = { lines = "6c8d56b73b02f0bb", reads = {} },
  -- The int8 dot product of [`Vector.corpus`]: VNNI in its AVX-512 (256-bit
  -- forms) and AVX encodings, by cpuid leaf 7. It also asks cpuid leaf 1
  -- for OSXSAVE and xgetbv for the state the system saves, which are the
  -- system's and no feature of the processor.
  ["core/vector.c"] = { lines = "cd0767ce3aa41c0c",
    reads = { x86_64 = { "avx512f", "avx512vl", "avx512_vnni", "avx_vnni" } } },
  -- The processor count on Apple (sysctlbyname("hw.ncpu")): no feature.
  ["vendor/sqlite/sqlite3.c"] = { lines = "7b27815aae63deac", reads = {} },
}

dispatch_sites.sites = sites

dispatch_sites.api = {
  mbedtls = { "psa_", "mbedtls_" },
  xz = { "lzma_" },
}

--- The library a vendored file or a patch of one belongs to ("mbedtls"
--- for vendor/mbedtls/... and patch/mbedtls/...), or nil for any other
--- path.
local function library_of(path: string): string?
  return path:match("^vendor/([^/]+)/") or path:match("^patch/([^/]+)/")
end

--- The libraries with a site that reads a feature, sorted.
function dispatch_sites.libraries(): {string}
  local seen: mut {string:boolean} = {}
  for path, site in pairs(sites) do
    local library = library_of(path)
    if library ~= nil and next(site.reads) ~= nil then seen[library] = true end
  end
  local out: mut {string} = {}
  for library in pairs(seen) do out[#out + 1] = library end
  table.sort(out)
  return out
end

--- The files of the core that are sites reading a feature, sorted.
local function site_files(): {string}
  local out: mut {string} = {}
  for path, site in pairs(sites) do
    if path:match("^core/.*%.c$") ~= nil and next(site.reads) ~= nil then out[#out + 1] = path end
  end
  table.sort(out)
  return out
end

--- The last line of `span`, in `lines`, its file's.
local function last_of(span: c_functions.Span, lines: {string}): integer
  return math.min(math.max(span.first, (span.stop or #lines + 1) - 1), #lines)
end

--- The name `span`'s key ends in.
local function name_of(span: c_functions.Span): string
  return span.key:match(":([^:]+)$") or span.key
end

--- The lines of `span` in `lines` that match `pattern`.
local function matching(span: c_functions.Span, lines: {string}, pattern: string): {integer}
  local found: mut {integer} = {}
  for at = span.first, last_of(span, lines) do
    if (lines[at] or ""):find(pattern) ~= nil then found[#found + 1] = at end
  end
  return found
end

--- The lines of `span` in `lines`, all of them.
local function whole(span: c_functions.Span, lines: {string}): {integer}
  local found: mut {integer} = {}
  for at = span.first, last_of(span, lines) do found[#found + 1] = at end
  return found
end

--- What turns on the processor in the functions `spans` of the site file
--- `lines` (see the top of this module): functions compiled for a
--- feature, and the lines that call through a pointer assigned one.
local function in_site(spans: {c_functions.Span}, lines: {string}): {dispatch_sites.Reach}
  local out: mut {dispatch_sites.Reach} = {}
  local kernels: mut {string:boolean} = {}
  for _, span in ipairs(spans) do
    local above = (lines[span.first - 1] or "") .. (lines[span.first - 2] or "")
    if above:find("target%s*%(") ~= nil then
      kernels[name_of(span)] = true
      out[#out + 1] = { key = span.key, path = span.path, lines = whole(span, lines),
        why = "it is compiled for a processor feature" }
    end
  end
  if next(kernels) == nil then
    for _, span in ipairs(spans) do
      out[#out + 1] = { key = span.key, path = span.path, lines = whole(span, lines),
        why = "its file reads the processor's features" }
    end
    return out
  end
  local pointers: mut {string:boolean} = {}
  for name, value in table.concat(lines, "\n"):gmatch("([%a_][%w_]*)%s*=%s*([%a_][%w_]*)%s*;") do
    if kernels[value] == true then pointers[name] = true end
  end
  for _, span in ipairs(spans) do
    for pointer in pairs(pointers) do
      local at = matching(span, lines, "%f[%w_]" .. pointer .. "%s*%(")
      if #at > 0 then
        out[#out + 1] = { key = span.key, path = span.path, lines = at,
          why = "it calls the code chosen by the processor's features (" .. pointer .. ")" }
      end
    end
  end
  return out
end

function dispatch_sites.reaching(spans: {c_functions.Span},
                                 sources: {string:{string}}): {dispatch_sites.Reach}
  local sited: mut {string:boolean} = {}
  local out: mut {dispatch_sites.Reach} = {}
  for _, path in ipairs(site_files()) do
    sited[path] = true
    local lines = sources[path]
    if lines ~= nil then
      local those: mut {c_functions.Span} = {}
      for _, span in ipairs(spans) do
        if span.path == path then those[#those + 1] = span end
      end
      for _, each in ipairs(in_site(those, lines)) do out[#out + 1] = each end
    end
  end
  local prefixes: mut {Prefix} = {}
  for _, library in ipairs(dispatch_sites.libraries()) do
    for _, prefix in ipairs(dispatch_sites.api[library] or {}) do
      prefixes[#prefixes + 1] = { library = library, prefix = prefix }
    end
  end
  for _, span in ipairs(spans) do
    local lines = sources[span.path]
    if sited[span.path] ~= true and lines ~= nil then
      for _, each in ipairs(prefixes) do
        local at = matching(span, lines, "%f[%w_]" .. each.prefix)
        if #at > 0 then
          out[#out + 1] = { key = span.key, path = span.path, lines = at,
            why = "it calls " .. each.library .. ", which chooses code by the processor" }
        end
      end
    end
  end
  return out
end

function dispatch_sites.failure(reaches: {dispatch_sites.Reach}, hits: {string:{integer:boolean}}): string
  local ran: mut {string:string} = {}
  for _, each in ipairs(reaches) do
    local here = hits[each.path]
    if here ~= nil and ran[each.key] == nil then
      for _, at in ipairs(each.lines) do
        if here[at] == true then
          ran[each.key] = each.key .. ": " .. each.why .. " (line " .. tostring(at) .. ")"
          break
        end
      end
    end
  end
  local keys: mut {string} = {}
  for key in pairs(ran) do keys[#keys + 1] = key end
  if #keys == 0 then return "" end
  table.sort(keys)
  local lines: mut {string} = {}
  for _, key in ipairs(keys) do lines[#lines + 1] = "  " .. tostring(ran[key]) end
  return "the test runs C that chooses code by the processor's features, which its key does not " ..
    "hold, so its pass would stand on a host of another processor:\n" .. table.concat(lines, "\n") ..
    "\n  declare cpu_features = true in the module's Test.policy, which keys its tests by the " ..
    "processor's features (doc/testing.md, \"processor features\")"
end

return dispatch_sites
