--- .github/scripts/host-features.sh, which names a CI leg's verdict
--- cache, and [`declared_key.host_features`] answer the same digest of
--- the same host, and it moves with what `host_identity` keys of it: a
--- cache named by it holds verdicts whose keys the host reaches.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local declared_key = require("build.declared_key")
local Test = require("cosmic.test")

--- The script, run by the system's `sh`; and where both read a macOS
--- host's system version, which no other host has.
Test.needs{
  reads = { ".github/scripts/host-features.sh" }, system = true,
  host = { "/System/Library/CoreServices/SystemVersion.plist" },
}

local SCRIPT <const> = ".github/scripts/host-features.sh"

--- What the script prints, given `args`.
local function script(args: {string}): string
  local argv = { "/bin/sh", SCRIPT }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result = assert(Child.run(argv, { stdout = "capture", stderr = "capture",
    timeout_ms = 10000 }))
  assert(result.ok, tostring(result.stderr))
  return ((result.stdout as string):gsub("%s+$", ""))
end

--- The features `text`, a /proc/cpuinfo, lists ("flags" on x86,
--- "Features" on arm), as [`sys.cpu_features`] would answer them: what
--- the key is given where the script reads that file.
local function listed(text: string): {string}
  local found: {string} = {}
  for line in text:gmatch("[^\n]+") do
    local flags = line:match("^flags%s*:%s*(.*)$") or line:match("^Features%s*:%s*(.*)$")
    for flag in (flags or ""):gmatch("%S+") do found[#found + 1] = flag end
  end
  return found
end

--- A host under `tmp` of `machine` (nil: this host's, on both sides)
--- whose /proc/cpuinfo holds `cpuinfo`, which the script reads and the
--- key is given the features of:
--- `write` replaces one of its files, and `both(what, moved)` checks
--- that the script and `host_features` name it alike and that the name
--- and `host_identity` moved from every one seen before, or neither.
local type Write = function(string, string): string
local function host(tmp: string, machine: string, cpuinfo: string):
    Write, function(string, boolean)
  local function write(name: string, text: string): string
    assert(Fs.write(tmp .. "/" .. name, text))
    return tmp .. "/" .. name
  end
  write("cpuinfo", cpuinfo)
  local sources: declared_key.HostSources = {
    packages = { write("packages", "p1") },
    system = { write("os", "o1"), write("osrelease", "6.17.0-1022-azure\n"),
      write("version", "#22-Ubuntu SMP\n") },
    machine = machine,
    status = write("status", "Uid: 1 1 1 1\n"), own_proc = true, host_id = "h", uid = 1,
  }
  local names: {string:boolean} = {}
  local identities: {string:boolean} = {}
  local function both(what: string, moved: boolean)
    -- The features the key is given are those the script reads.
    local path = tmp .. "/cpuinfo"
    sources.cpu_features = listed((Fs.read(path)) or "")
    local named = script({ path, sources.system[2], sources.system[3], machine })
    local keyed = declared_key.host_features(sources)
    assert(named == keyed, what .. ": the script names " .. named .. ", the key " .. keyed)
    assert(#named == 16, named)
    local id = declared_key.host_identity(declared_key.digests(tmp), sources)
    assert((names[named] == nil) == moved, what .. ": the name")
    assert((identities[id] == nil) == moved, what .. ": the identity")
    names[named], identities[id] = true, true
  end
  return write, both
end

--- On a machine no audit has read, every feature listed is keyed.
local function test_the_script_and_the_key_name_the_host_alike(tmp: string)
  local write, both = host(tmp, "riscv64", "processor : 0\nflags : sse avx b_2 a\n" ..
    "vmx flags : ept\nprocessor : 1\nflags\t: a avx sse b_2\n")
  both("the start", true)
  write("cpuinfo", "flags : sse a b_2 avx\n")
  both("the same features in another order", false)
  write("cpuinfo", "flags : sse a b_2 avx avx2\n")
  both("a feature more", true)
  write("osrelease", "6.17.0-1023-azure\n")
  both("another kernel", true)
  write("version", "#23-Ubuntu SMP\n")
  both("another build of it", true)
  assert(Fs.remove(tmp .. "/cpuinfo"))
  both("no features at all", true)
end

--- On x86_64, only the features a core chooses code by are keyed --
--- mbedtls's AES-NI and xz's carry-less CRCs -- so hosted runners that
--- differ in any other split neither the verdicts nor their cache, and
--- a host lacking one of them keys apart. The FMA features are not
--- among them.
local function test_an_x86_64_host_keys_only_what_a_core_dispatches_on(tmp: string)
  local base = "fpu sse sse2 ssse3 sse4_1 sse4_2 pclmulqdq aes avx fma avx2 bmi2 erms"
  local write, both = host(tmp, "x86_64", "processor : 0\nflags : " .. base .. "\n")
  both("the start", true)
  write("cpuinfo", "flags : " .. base .. " avx512f avx512bw\n")
  both("avx512 more", false)
  write("cpuinfo", "flags : " .. base .. " hypervisor md_clear\n")
  both("a hypervisor's bits more", false)
  write("cpuinfo", "flags : " .. (base:gsub(" bmi2 erms", "")) .. "\n")
  both("string features fewer", false)
  write("cpuinfo", "flags : " .. (base:gsub(" aes", "")) .. "\n")
  both("no aes", true)
  write("cpuinfo", "flags : " .. (base:gsub(" fma avx2", "")) .. "\n")
  both("no fma or avx2", false)
  write("cpuinfo", "flags : " .. base .. " fma4\n")
  both("fma4 more", false)
  write("cpuinfo", "flags : " .. (base:gsub(" pclmulqdq", "")) .. "\n")
  both("no pclmulqdq", true)
end

--- On aarch64, only the features a core chooses code by are keyed --
--- mbedtls's AES instructions and xz's CRC32 -- as on x86_64.
local function test_an_aarch64_host_keys_only_what_a_core_dispatches_on(tmp: string)
  local base = "fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics"
  local write, both = host(tmp, "aarch64", "processor : 0\nFeatures : " .. base .. "\n")
  both("the start", true)
  write("cpuinfo", "Features : " .. base .. " sve sve2\n")
  both("sve more", false)
  write("cpuinfo", "Features : " .. (base:gsub(" crc32", "")) .. "\n")
  both("no crc32", true)
  write("cpuinfo", "Features : " .. (base:gsub(" pmull", "")) .. "\n")
  both("no pmull", true)
end

--- Where neither names the machine, the script's (`uname -m`) and the
--- key's ([`sys.uname`]) are the same one: a host listing every feature
--- either list keeps, and some neither does, is named alike.
local function test_the_script_and_the_key_take_the_same_machine_by_default(tmp: string)
  local _, both = host(tmp, nil, "flags : aes avx2 fma fma4 pclmulqdq sse4_1 ssse3 " ..
    "avx512f hypervisor\nFeatures : asimd aes pmull crc32 sve\n")
  both("this host", true)
end

--- On macOS, where there is no /proc, the script and the key both read
--- the system volume's SystemVersion.plist for the kernel's release, and
--- no kernel version, as [`declared_key.system_sources`] says. SYSNAME
--- Darwin chooses these in the script as `sysname` does in the key, and
--- an update of the system moves the name and the host's identity alike.
local function test_a_macos_host_is_named_by_its_system_version(tmp: string)
  local darwin = declared_key.system_sources("Darwin")
  local text = assert(Fs.read(SCRIPT))
  assert(text:find(darwin[2], 1, true), "the script reads no " .. darwin[2])
  assert(darwin[3] == "", "a version beside the system's")
  -- Where each is found on the host: the real plist on a Mac, and
  -- none elsewhere.
  assert(script({ tmp .. "/cpuinfo", "", "", "arm64", "Darwin" }) ==
    declared_key.host_features({ cpu_features = {}, machine = "arm64",
      sysname = "Darwin" }), "the system's own")
  local plist = tmp .. "/SystemVersion.plist"
  local system: {string} = {}
  for i, path in ipairs(darwin) do system[i] = path == darwin[2] and plist or path end
  local sources: declared_key.HostSources = {
    packages = {}, system = system, cpu_features = {}, machine = "arm64",
    status = tmp .. "/status", own_proc = false, host_id = "macos-15", uid = 501,
  }
  local names: {string:boolean} = {}
  local identities: {string:boolean} = {}
  local function both(what: string)
    local named = script({ tmp .. "/cpuinfo", plist, "", "arm64", "Darwin" })
    assert(named == declared_key.host_features(sources), what .. ": the script names " ..
      named .. ", the key " .. declared_key.host_features(sources))
    local id = declared_key.host_identity(declared_key.digests(tmp), sources)
    assert(names[named] == nil and identities[id] == nil, what .. " moved nothing")
    names[named], identities[id] = true, true
  end
  assert(Fs.write(plist, "<key>ProductBuildVersion</key><string>24G84</string>\n"))
  both("the start")
  assert(Fs.write(plist, "<key>ProductBuildVersion</key><string>24G90</string>\n"))
  both("another build of the system")
end

--- On this host, with nothing given, the script and the key name it
--- alike: the processor's features the script reads -- /proc/cpuinfo,
--- or on macOS sysctl's names -- are those [`sys.cpu_features`] answers
--- the key. A worker whose /proc is a sandbox's own has no
--- /proc/cpuinfo to read, and checks nothing.
local function test_the_script_and_the_key_name_this_host_alike()
  local names = assert(sys.uname())
  if names.sysname == "Linux" and Fs.read("/proc/cpuinfo") == nil then return end
  assert(script({}) == declared_key.host_features(), "this host")
end
