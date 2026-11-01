--- The processor features a key holds ([`declared_key.dispatched`]) are
--- those the compiled C chooses code by. Every file that asks what the
--- processor can do, in the core, the vendored libraries as fetched or
--- the patch records applied to them, is named here with the features
--- it reads. Each is named with a digest of the lines that ask and the
--- dozen after each, where the bits asked for are read (`asking`), and
--- each of those features is keyed for its machine. A vendor refetch or
--- a patch that brings a new site, or a new question to a named one,
--- fails here, naming its file, until its features are keyed (in
--- `dispatched`, [`sys.cpu_features`] and ci/cosmic_ci/host_id.tl
--- alike) and it is named below.
---
--- The walk does not reach zig's own lib (compiler_rt) or musl, which
--- the audit that chose `dispatched` read: a change of the zig pin is
--- unguarded here.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local declared_key = require("build.declared_key")
local type Coverage = require("cosmic.coverage")
local DispatchSites = require("build.dispatch_sites")
local c_functions = require("build.c_functions")
local Test = require("cosmic.test")
local String = require("cosmic.string")

--- Every tree build.zig compiles C from: the core's own, the vendored
--- libraries' and the patches it applies to them, and build.zig itself,
--- which names them and passes the compiler's definitions.
Test.policy{
  cpu_features = true,
  grants = {
    { path = "build.zig", letters = "r" },
    { path = "core/", letters = "r" },
    { path = "patch/", letters = "r" },
    { path = "vendor/bzip2/", letters = "r" },
    { path = "vendor/cares/", letters = "r" },
    { path = "vendor/curl/", letters = "r" },
    { path = "vendor/expat/", letters = "r" },
    { path = "vendor/lua/", letters = "r" },
    { path = "vendor/mbedtls/", letters = "r" },
    { path = "vendor/miniz/", letters = "r" },
    { path = "vendor/sqlite/", letters = "r" },
    { path = "vendor/sqlite-ext/", letters = "r" },
    { path = "vendor/xz/", letters = "r" },
    { path = "vendor/yyjson/", letters = "r" },
    { path = "vendor/zstd/", letters = "r" },
  },
}

--- The vendored libraries build.zig compiles C from, each walked whole.
local LIBRARIES <const> = { "bzip2", "cares", "curl", "expat", "lua", "mbedtls", "miniz",
  "sqlite", "sqlite-ext", "xz", "yyjson", "zstd" }

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

local SITES <const> = DispatchSites.sites

local SHA256 <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/sha256.c"
local SHA512 <const> = "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src/sha512.c"

--- Whether `line` holds a needle or matches a pattern.
local function asks(line: string): boolean
  if line:lower():find("hwcap", 1, true) ~= nil then return true end
  for _, needle in ipairs(NEEDLES) do
    if line:find(needle, 1, true) ~= nil then return true end
  end
  for _, pattern in ipairs(PATTERNS) do
    if line:find(pattern) ~= nil then return true end
  end
  return false
end

--- The lines of `text` that hold a needle or match a pattern (`asks`),
--- and the `AFTER` lines after each, in order, each once. The text is
--- searched whole and only the lines around each find are cut out of
--- it. A test runs under the coverage line hook, under which taking
--- every file a line at a time (SQLite's amalgamation alone is 260,000
--- lines) takes about 24 s on the checked core, past the runner's 30 on
--- a loaded host; this takes about 1 s.
local function asking(text: string): {string}
  local body = text .. "\n"
  -- Where each find starts: a line that holds one holds it there. A
  -- pattern's match may run on past its line's end, so the line each
  -- find is on is held to `asks` below.
  local starts: mut {integer} = {}
  local function every(within: string, sought: string, plain: boolean)
    local from = 1
    while true do
      local at = within:find(sought, from, plain)
      if at == nil then return end
      starts[#starts + 1] = at
      from = at + 1
    end
  end
  every(text:lower(), "hwcap", true)
  for _, needle in ipairs(NEEDLES) do every(text, needle, true) end
  for _, pattern in ipairs(PATTERNS) do every(text, pattern, false) end
  if #starts == 0 then return {} end
  table.sort(starts)
  -- Each find's line, by number, and where it starts, found from the
  -- end back (`reversed`); the lines between two finds are counted, not
  -- walked.
  local reversed = body:reverse()
  local kept: mut {integer:string} = {}
  local number, counted, held = 1, 1, 0
  for _, at in ipairs(starts) do
    local before = reversed:find("\n", #body - at + 2, true)
    local start = if before == nil then 1 else #body - before + 2 end
    if start > counted then
      local _, lines = body:sub(counted, start - 1):gsub("\n", "")
      number, counted = number + lines, start
    end
    local stop = assert(body:find("\n", start, true))
    if number ~= held and asks(body:sub(start, stop - 1)) then
      held = number
      for j = number, number + AFTER do
        if start > #body then break end
        stop = assert(body:find("\n", start, true))
        kept[j] = body:sub(start, stop - 1)
        start = stop + 1
      end
    end
  end
  local numbers: mut {integer} = {}
  for j in pairs(kept) do numbers[#numbers + 1] = j end
  table.sort(numbers)
  local found: mut {string} = {}
  for _, j in ipairs(numbers) do found[#found + 1] = kept[j] end
  return found
end

--- Each file under the trees build.zig compiles C from that holds a
--- needle, as a path of the tree, with its lines that do (`asking`).
local function sites(): {string:{string}}
  local found: mut {string:{string}} = {}
  local function scan(path: string)
    local lines = asking((assert(Fs.read(path))))
    if #lines > 0 then found[path] = lines end
  end
  local roots: mut {string} = { "core", "patch" }
  for _, library in ipairs(LIBRARIES) do roots[#roots + 1] = "vendor/" .. library end
  for _, root in ipairs(roots) do
    for _, relative in ipairs((assert(Fs.walk(root)))) do scan(root .. "/" .. relative) end
  end
  scan("build.zig")
  return found
end

--- `asking` finds the lines taking the text a line at a time would:
--- each line `asks` holds and the `AFTER` after it, each once, in order.
local function test_asking_keeps_what_a_line_at_a_time_would()
  local function by_line(text: string): {string}
    local lines: mut {string} = {}
    for line in String.lines(text) do lines[#lines + 1] = line end
    local kept: mut {integer:boolean} = {}
    for i, line in ipairs(lines) do
      if asks(line) then
        for j = i, math.min(i + AFTER, #lines) do kept[j] = true end
      end
    end
    local found: mut {string} = {}
    for i, line in ipairs(lines) do
      if kept[i] then found[#found + 1] = line end
    end
    return found
  end
  -- A pattern's match that runs past its line's end, which no line
  -- holds; a find on a window's last line, which carries it on; two on
  -- one line; a find in any case; and the last line, with and without
  -- a newline after it.
  local lines: mut {string} = { "#define MBEDTLS_AESNI_X", "0x1", "a", "cpuid" }
  for i = 1, AFTER - 1 do lines[#lines + 1] = "filler " .. tostring(i) end
  lines[#lines + 1] = "xgetbv on the window's last line"
  for i = 1, AFTER + 4 do lines[#lines + 1] = "more " .. tostring(i) end
  lines[#lines + 1] = "cpuid and cpuid, HwCaP too"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "getauxval last"
  local text = table.concat(lines, "\n")
  for _, each in ipairs({ text, text .. "\n", "", "\n\n", "cpuid" }) do
    local want, got = by_line(each), asking(each)
    assert(table.concat(got, "\n") == table.concat(want, "\n") and #got == #want,
      "asking found " .. tostring(#got) .. " lines where a line at a time finds " .. tostring(#want))
  end
  local found = asking(text)
  assert(#found > AFTER * 2 and #found < #lines, "the case keeps " .. tostring(#found) .. " lines")
  assert(found[1] == "cpuid", "the case begins with " .. tostring(found[1]))
end

local function test_every_library_build_zig_compiles_is_walked()
  local source = assert(Fs.read("build.zig"))
  local walked: mut {string:boolean} = {}
  for _, library in ipairs(LIBRARIES) do walked[library] = true end
  local count = 0
  for library in source:gmatch('patched%(b, trees, "([%w_%-]+)"%)') do
    count = count + 1
    assert(walked[library] or NOT_C[library], "build.zig compiles vendor/" .. library ..
        ", which this test does not walk: add it to LIBRARIES and to Test.policy")
  end
  assert(count >= #LIBRARIES, "build.zig names " .. tostring(count) .. " patched trees")
end

local function test_every_site_that_asks_the_processor_is_named()
  local found = sites()
  local problems: mut {string} = {}
  for path, lines in pairs(found) do
    local site = SITES[path]
    local digest = Hash.hex_sha256(table.concat(lines, "\n")):sub(1, 16)
    if site == nil then
      problems[#problems + 1] = path .. " asks what the processor can do: key the features " ..
        "it reads in build/declared_key.tl's `dispatched`, core/syscalls.c's `cpu_features` " ..
        "and ci/cosmic_ci/host_id.tl, and name it in build/dispatch_sites.tl's `sites` (lines = \"" .. digest ..
        "\"), or name it with `reads = {}` if it reads none"
    elseif site.lines ~= digest then
      problems[#problems + 1] = path .. " asks the processor otherwise than build/dispatch_sites.tl's `sites` say " ..
        "(lines = \"" .. digest .. "\"): read what it asks now, key what it reads, then " ..
        "take the new digest:\n  " .. table.concat(lines, "\n  ")
    end
  end
  for path in pairs(SITES) do
    if found[path] == nil then
      problems[#problems + 1] = path .. " no longer asks what the processor can do: drop it " ..
        "from build/dispatch_sites.tl's `sites`"
    end
  end
  table.sort(problems)
  assert(#problems == 0, table.concat(problems, "\n"))
end

local function test_every_feature_a_site_reads_is_keyed()
  local want: mut {string:{string:boolean}} = {}
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
    local have: mut {string:boolean} = {}
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

--- mbedtls's Armv8 SHA-2 instruction paths are chosen at run time
--- (`_IF_PRESENT`) by the configuration the build names, and no
--- definition makes one the only path (`_ONLY`), which a processor
--- without the instructions would fault on.
local function test_the_sha_instructions_are_chosen_at_run_time()
  local config = assert(Fs.read("core/mbedtls_cosmic_config.h"))
  for _, name in ipairs({ "MBEDTLS_SHA256_USE_ARMV8_A_CRYPTO_IF_PRESENT",
      "MBEDTLS_SHA512_USE_A64_CRYPTO_IF_PRESENT" }) do
    assert(config:find("#define " .. name .. "\n", 1, true) ~= nil, "the configuration lacks " .. name)
  end
  local paths: mut {string} = { "core/mbedtls_cosmic_config.h", "build.zig" }
  for _, relative in ipairs((assert(Fs.walk("patch")))) do
    paths[#paths + 1] = "patch/" .. relative
  end
  for _, path in ipairs(paths) do
    local text = assert(Fs.read(path))
    assert(text:find("MBEDTLS_SHA%d+_USE_[%w_]*ONLY") == nil, path .. " makes an SHA-2 instruction path the only one")
  end
  for _, path in ipairs({ SHA256, SHA512 }) do
    local text = assert(Fs.read(path))
    assert(text:find("MBEDTLS_SHA%d+_USE_") ~= nil, path .. " gates its instructions otherwise")
  end
end

--- zstd chooses its BMI2 code by the processor only under
--- DYNAMIC_BMI2, which build.zig defines as 0 for zstd's compile; the
--- sites named for zstd read nothing on that ground alone.
local function test_zstd_dispatch_is_compiled_out()
  local build = assert(Fs.read("build.zig"))
  assert(build:find('"-DDYNAMIC_BMI2=0"', 1, true) ~= nil, "build.zig no longer turns zstd's dispatch off")
  local macros = assert(Fs.read("vendor/zstd/lib/common/portability_macros.h"))
  assert(macros:find("#ifndef DYNAMIC_BMI2", 1, true) ~= nil, "zstd no longer takes DYNAMIC_BMI2 from outside")
end

--- Every library with a site that reads a feature names the prefixes of
--- the functions it exports (`api`), and its public headers declare one
--- under each: the core's calls into it, which are how a test's entry
--- into the library is found, are found by them.
local function test_every_dispatching_library_names_its_api()
  local libraries = DispatchSites.libraries()
  assert(#libraries >= 2, "the libraries with a site: " .. table.concat(libraries, ", "))
  for _, library in ipairs(libraries) do
    local prefixes = DispatchSites.api[library]
    assert(prefixes ~= nil and #prefixes > 0, library .. " has a site that reads a processor " ..
        "feature: name the prefixes of its API in build/dispatch_sites.tl's `api`")
    for _, prefix in ipairs(prefixes) do
      local found = false
      for _, relative in ipairs((assert(Fs.walk("vendor/" .. library)))) do
        if relative:match("%.h$") ~= nil then
          local text = assert(Fs.read("vendor/" .. library .. "/" .. relative))
          if text:find("%f[%w_]" .. prefix) ~= nil then
            found = true
            break
          end
        end
      end
      assert(found, "no header of vendor/" .. library .. " has a name that begins " .. prefix)
    end
  end
  for library in pairs(DispatchSites.api) do
    local listed = false
    for _, name in ipairs(libraries) do listed = listed or name == library end
    assert(listed, library .. " is named in `api` but no site of it reads a feature")
  end
end

--- The lines of the core's C that turn on the processor, by function key.
local function reached(found: {DispatchSites.Reach}): {string:DispatchSites.Reach}
  local out: mut {string:DispatchSites.Reach} = {}
  for _, each in ipairs(found) do out[each.key] = each end
  return out
end

--- The lines that turn on the processor are the calls into a dispatching
--- library, and, in a file that is a site, the code compiled for a feature
--- and the calls through the pointer it is assigned to.
local function test_the_core_lines_that_turn_on_the_processor_are_found()
  local functions: {Coverage.Function} = {
    { path = "core/vector.c", name = "kernel_generic", line = 1 },
    { path = "core/vector.c", name = "kernel_avx", line = 4 },
    { path = "core/vector.c", name = "pick", line = 7 },
    { path = "core/vector.c", name = "use", line = 10 },
    { path = "core/hash.c", name = "digest", line = 1 },
    { path = "core/hash.c", name = "plain", line = 5 },
    { path = "core/compress.c", name = "stream", line = 1 },
  }
  local sources: {string:{string}} = {
    ["core/vector.c"] = {
      "static int kernel_generic (void) {", "}",
      "__attribute__((target(\"avx2\")))",
      "static int kernel_avx (void) {", "}",
      "static int (*kernel) (void) = kernel_generic;",
      "static void pick (void) {", "  kernel = kernel_avx;", "}",
      "static void use (void) {", "  kernel();", "}",
    },
    ["core/hash.c"] = {
      "static int digest (void) {", "  return psa_hash_setup(0, 0);", "}", "",
      "static int plain (void) {", "  return helper_psa_hash(0) + my_mbedtls_x;", "}",
    },
    ["core/compress.c"] = {
      "static int stream (int op) {", "  if (op == 1) return 0;", "  return lzma_code(op);", "}",
    },
  }
  local found = reached(DispatchSites.reaching(c_functions.spans(functions, sources), sources))
  assert(found["core/hash.c:digest"] ~= nil, "a call to psa_ is a call into mbedtls")
  assert(found["core/hash.c:plain"] == nil, "a name that merely contains a prefix is no call")
  local xz = assert(found["core/compress.c:stream"], "a call to lzma_ is a call into xz")
  assert(#xz.lines == 1 and xz.lines[1] == 3, "the line of the call, not the function's")
  assert(found["core/vector.c:kernel_avx"] ~= nil, "a function compiled for a feature")
  local used = assert(found["core/vector.c:use"], "a call through the pointer it is assigned to")
  assert(#used.lines == 1 and used.lines[1] == 11)
  assert(found["core/vector.c:pick"] == nil, "the choice runs whenever the file loads")
  assert(found["core/vector.c:kernel_generic"] == nil, "the code any processor runs")
  -- The tree's own C: the kernels, and the scan that calls the one chosen, but not the function
  -- that registers the module and picks (which every open of a database enters).
  local text = assert(Fs.read("core/vector.c"))
  local own_lines: mut {string} = {}
  for line in String.lines(text) do own_lines[#own_lines + 1] = line end
  local own: {string:{string}} = { ["core/vector.c"] = own_lines }
  local own_functions: mut {Coverage.Function} = {}
  for _, name in ipairs({ "dot_i8_avx512_vnni", "dot_i8_avx_vnni", "dot_i8_generic", "cosmic_vector_functions",
      "row_key" }) do
    for at, line in ipairs(own_lines) do
      if line:match("^[%a_]") ~= nil and line:find(" " .. name .. " (", 1, true) ~= nil then
        own_functions[#own_functions + 1] = { path = "core/vector.c", name = name, line = at }
        break
      end
    end
  end
  assert(#own_functions == 5, "core/vector.c has the functions this reads")
  local real = reached(DispatchSites.reaching(c_functions.spans(own_functions, own), own))
  assert(real["core/vector.c:dot_i8_avx_vnni"] ~= nil and real["core/vector.c:dot_i8_avx512_vnni"] ~= nil)
  assert(real["core/vector.c:dot_i8_generic"] == nil)
  assert(real["core/vector.c:cosmic_vector_functions"] == nil, "the function that registers and picks")
  assert(real["core/vector.c:row_key"] ~= nil, "the scan that calls the kernel chosen")
end

--- A test whose module does not declare `cpu_features` fails for running
--- a line that calls into a dispatching library, naming the function and the
--- fix; one that runs the function's other lines, or none, does not.
local function test_a_test_that_runs_a_dispatched_line_fails_without_the_policy()
  local reaches: {DispatchSites.Reach} = {
    { key = "core/hash.c:digest", path = "core/hash.c", lines = { 2 }, why = "it calls mbedtls" },
    { key = "core/hash.c:other", path = "core/hash.c", lines = { 9 }, why = "it calls mbedtls" },
  }
  local said = DispatchSites.failure(reaches, { ["core/hash.c"] = { [1] = true, [2] = true } })
  assert(said:find("core/hash.c:digest: it calls mbedtls (line 2)", 1, true) ~= nil, said)
  assert(said:find("core/hash.c:other", 1, true) == nil, said)
  assert(said:find("declare cpu_features = true in the module's Test.policy", 1, true) ~= nil, said)
  assert(DispatchSites.failure(reaches, { ["core/hash.c"] = { [1] = true, [3] = true } }) == "")
  assert(DispatchSites.failure(reaches, { ["core/other.c"] = { [2] = true } }) == "")
  assert(DispatchSites.failure({}, { ["core/hash.c"] = { [2] = true } }) == "")
end
