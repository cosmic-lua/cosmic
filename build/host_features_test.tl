--- [`declared_key.host_features`], which a key holds and which names a CI
--- leg's verdict cache, answers the digests CI's `leg-host-id`
--- (ci/cosmic_ci/host_id.tl) computes of the same hosts, and moves with
--- what `host_identity` keys of it: a cache named by it holds verdicts
--- whose keys the host reaches. The two trees cannot require each other,
--- so each reads the recorded hosts in ci/testdata/host_features, whose
--- digests recorded from the original shell implementation.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local sys = require("cosmic.sys")
local declared_key = require("build.declared_key")
local Test = require("cosmic.test")

--- The recorded hosts, which ci/cosmic_ci/host_id_test.tl holds the
--- command to as well; and where a macOS host's system version is read,
--- which no other host has.
Test.policy{
  grants = {
    { path = "ci/testdata/host_features/vectors.json", letters = "r" },
    { path = "/System/Library/CoreServices/SystemVersion.plist", letters = "r" },
  },
}

--- The features `text`, a /proc/cpuinfo, lists ("flags" on x86,
--- "Features" on arm), split at spaces and tabs alone as CI's
--- cosmic_ci/host_id.tl does, so a trailing carriage return is seen alike.
local function listed(text: string): {string}
  local found: {string} = {}
  for line in text:gmatch("[^\n]+") do
    local flags = line:match("^flags%s*:%s*(.*)$") or line:match("^Features%s*:%s*(.*)$")
    for flag in (flags or ""):gmatch("[^ \t]+") do found[#found + 1] = flag end
  end
  return found
end

--- A host under `tmp` of `machine` whose /proc/cpuinfo holds `cpuinfo`,
--- which the key is given the features of: `write` replaces one of its
--- files, and `both(what, moved)` checks that the name `host_features`
--- gives it and `host_identity` moved from every one seen before, or
--- neither.
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
    sources.cpu_features = listed((Fs.read(tmp .. "/cpuinfo")) or "")
    local named = declared_key.host_features(sources)
    assert(#named == 16, named)
    local id = declared_key.host_identity(declared_key.digests(tmp), sources)
    assert((names[named] == nil) == moved, what .. ": the name")
    assert((identities[id] == nil) == moved, what .. ": the identity")
    names[named], identities[id] = true, true
  end
  return write, both
end

--- On a machine no audit has read, every feature listed is keyed.
local function test_a_host_is_named_by_what_it_keys(tmp: string)
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

--- On macOS, where there is no /proc, the key reads the system volume's
--- SystemVersion.plist for the kernel's release, and no kernel version,
--- as [`declared_key.system_sources`] says, and an update of the system
--- moves the name and the host's identity alike.
local function test_a_macos_host_is_named_by_its_system_version(tmp: string)
  local darwin = declared_key.system_sources("Darwin")
  assert(darwin[2] == "/System/Library/CoreServices/SystemVersion.plist", darwin[2])
  assert(darwin[3] == "", "a version beside the system's")
  local plist = tmp .. "/SystemVersion.plist"
  local system: {string} = {}
  for i, path in ipairs(darwin) do system[i] = path == darwin[2] and plist or path end
  local sources: declared_key.HostSources = {
    packages = {}, system = system, cpu_features = {}, machine = "arm64", sysname = "Darwin",
    status = tmp .. "/status", own_proc = false, host_id = "macos-15", uid = 501,
  }
  local names: {string:boolean} = {}
  local identities: {string:boolean} = {}
  local function both(what: string)
    local named = declared_key.host_features(sources)
    local id = declared_key.host_identity(declared_key.digests(tmp), sources)
    assert(names[named] == nil and identities[id] == nil, what .. " moved nothing")
    names[named], identities[id] = true, true
  end
  assert(Fs.write(plist, "<key>ProductBuildVersion</key><string>24G84</string>\n"))
  both("the start")
  assert(Fs.write(plist, "<key>ProductBuildVersion</key><string>24G90</string>\n"))
  both("another build of the system")
end

local record Vector
  name: string
  sysname: string
  machine: string
  cpuinfo: string | nil
  osrelease: string | nil
  version: string | nil
  sysctl: {string:string} | nil
  digest: string
end

--- The sysctl names core/syscalls.c's `cpu_features` asks on macOS, by the
--- feature each answers for.
local darwin_features: {string:string} = {
  ["hw.optional.arm.FEAT_AES"] = "aes", ["hw.optional.AdvSIMD"] = "asimd",
  ["hw.optional.armv8_crc32"] = "crc32", ["hw.optional.arm.FEAT_PMULL"] = "pmull",
}

--- Each recorded host, as ci/testdata/host_features holds it -- x86_64,
--- aarch64 and a machine no audit has read, every feature a core
--- chooses code by missing in turn, odd spacing, a missing file, and
--- macOS's sysctl -- is named by the key as its vector says, and as ci/cosmic_ci/host_id.tl
--- does: a verdict cache is renamed by a byte of it.
local function test_every_recorded_host_is_named_as_the_ci_names_it(tmp: string)
  local text = assert(Fs.read("ci/testdata/host_features/vectors.json"))
  local recorded = assert(Json.decode_array(text))
  assert(#recorded >= 30, "the recorded hosts are gone")
  for i, entry in ipairs(recorded) do
    local vector = entry as Vector
    local release, version = tmp .. "/osrelease-" .. i, tmp .. "/version-" .. i
    if vector.osrelease ~= nil then assert(Fs.write(release, vector.osrelease)) end
    if vector.version ~= nil then assert(Fs.write(version, vector.version)) end
    local features: {string} = {}
    if vector.sysname == "Darwin" then
      for name, answer in pairs(vector.sysctl or {}) do
        if answer == "1" then features[#features + 1] = darwin_features[name] end
      end
    else
      features = listed(vector.cpuinfo or "")
    end
    local sources: declared_key.HostSources = {
      system = { "", release, vector.sysname == "Darwin" and "" or version },
      cpu_features = features, machine = vector.machine, sysname = vector.sysname,
    }
    local named = declared_key.host_features(sources)
    assert(named == vector.digest, vector.name .. ": the key names " .. named .. ", CI " ..
        vector.digest)
  end
end

--- On this host, with nothing given, the key's features -- the processor
--- itself asked, on this host's machine -- name it as the /proc/cpuinfo
--- the key's `listed` reading gives, which the vectors hold CI's reading
--- to. (The tree cannot require ci/'s module, so CI's own reading of
--- this host is not run here.) A worker whose /proc is a sandbox's own
--- has no /proc/cpuinfo, and checks nothing.
local function test_the_key_names_this_host_as_its_cpuinfo_does(tmp: string)
  local names = assert(sys.uname())
  if names.sysname ~= "Linux" then Test.skip("only Linux lists its features in /proc/cpuinfo") end
  local text = Fs.read("/proc/cpuinfo")
  if text == nil then Test.skip("this worker's /proc has no cpuinfo to read") end
  local release, version = tmp .. "/osrelease", tmp .. "/version"
  assert(Fs.write(release, Fs.read("/proc/sys/kernel/osrelease") or ""))
  assert(Fs.write(version, Fs.read("/proc/sys/kernel/version") or ""))
  local read = declared_key.host_features({ cpu_features = listed(text), system = { "", release, version } })
  assert(read == declared_key.host_features(), "this host")
end
