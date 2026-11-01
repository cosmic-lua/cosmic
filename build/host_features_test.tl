--- [`declared_key.host_kernel`], which a key holds and which names a CI
--- leg's verdict cache, and [`declared_key.host_cpu`], the processor's
--- features a key holds for a module that declares `cpu_features`,
--- answer what CI's `leg-host-id` (ci/cosmic_ci/host_id.tl) computes of
--- the same hosts: the kernel digest it names the cache by, and the
--- features it logs. The kernel moves with what `host_identity` keys of
--- it, so a cache named by it holds verdicts whose keys the host reaches;
--- the processor's features move no identity. The two trees cannot
--- require each other, so each reads the recorded hosts in
--- ci/testdata/host_features, whose kernel digests recorded from the
--- original shell implementation.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
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
  local found: mut {string} = {}
  for line in text:gmatch("[^\n]+") do
    local flags = line:match("^flags%s*:%s*(.*)$") or line:match("^Features%s*:%s*(.*)$")
    for flag in (flags or ""):gmatch("[^ \t]+") do found[#found + 1] = flag end
  end
  return found
end

--- A host under `tmp` of `machine` whose /proc/cpuinfo holds `cpuinfo`,
--- which the key is given the features of: `write` replaces one of its
--- files, and `seen(what, kernel, cpu)` checks that the name `host_kernel`
--- gives it moved from every one seen before (`kernel`), that the
--- processor's features `host_cpu` digests did (`cpu`), and that
--- `host_identity` moved with the kernel and with nothing else.
local type Write = function(string, string): string
local function host(tmp: string, machine: string, cpuinfo: string):
    Write, function(string, boolean, boolean)
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
  local names: mut {string:boolean} = {}
  local identities: mut {string:boolean} = {}
  local cpus: mut {string:boolean} = {}
  local function seen(what: string, kernel: boolean, cpu: boolean)
    sources.cpu_features = listed((Fs.read(tmp .. "/cpuinfo")) or "")
    local named = declared_key.host_kernel(sources)
    assert(#named == 16, named)
    local id = declared_key.host_identity(declared_key.digests(tmp), sources)
    local features = declared_key.host_cpu(sources)
    assert((names[named] == nil) == kernel, what .. ": the name")
    assert((identities[id] == nil) == kernel, what .. ": the identity")
    assert((cpus[features] == nil) == cpu, what .. ": the processor's features")
    names[named], identities[id], cpus[features] = true, true, true
  end
  return write, seen
end

--- On a machine no audit has read, every feature listed is keyed, in the
--- key of a module that declares `cpu_features` alone.
local function test_a_host_is_named_by_its_kernel_and_keys_its_features(tmp: string)
  local write, seen = host(tmp, "riscv64", "processor : 0\nflags : sse avx b_2 a\n" ..
      "vmx flags : ept\nprocessor : 1\nflags\t: a avx sse b_2\n")
  seen("the start", true, true)
  write("cpuinfo", "flags : sse a b_2 avx\n")
  seen("the same features in another order", false, false)
  write("cpuinfo", "flags : sse a b_2 avx avx2\n")
  seen("a feature more", false, true)
  write("osrelease", "6.17.0-1023-azure\n")
  seen("another kernel", true, false)
  write("version", "#23-Ubuntu SMP\n")
  seen("another build of it", true, false)
  assert(Fs.remove(tmp .. "/cpuinfo"))
  seen("no features at all", false, true)
end

--- On x86_64, only the features a core chooses code by are keyed --
--- mbedtls's AES-NI, xz's carry-less CRCs and the int8 kernels' VNNI --
--- so hosted runners that differ in any other split neither the
--- verdicts of a module that declares `cpu_features`, and a host lacking
--- one of them keys apart. The FMA features are not among them, and no
--- feature moves the host's identity or the cache's name.
local function test_an_x86_64_host_keys_only_what_a_core_dispatches_on(tmp: string)
  local base = "fpu sse sse2 ssse3 sse4_1 sse4_2 pclmulqdq aes avx fma avx2 bmi2 erms"
  local write, seen = host(tmp, "x86_64", "processor : 0\nflags : " .. base .. "\n")
  seen("the start", true, true)
  write("cpuinfo", "flags : " .. base .. " avx512bw avx512dq\n")
  seen("avx512 more", false, false)
  write("cpuinfo", "flags : " .. base .. " avx512f avx512vl avx512_vnni\n")
  seen("avx512 vnni", false, true)
  write("cpuinfo", "flags : " .. base .. " avx_vnni\n")
  seen("avx vnni", false, true)
  write("cpuinfo", "flags : " .. base .. " hypervisor md_clear\n")
  seen("a hypervisor's bits more", false, false)
  write("cpuinfo", "flags : " .. (base:gsub(" bmi2 erms", "")) .. "\n")
  seen("string features fewer", false, false)
  write("cpuinfo", "flags : " .. (base:gsub(" aes", "")) .. "\n")
  seen("no aes", false, true)
  write("cpuinfo", "flags : " .. (base:gsub(" fma avx2", "")) .. "\n")
  seen("no fma or avx2", false, false)
  write("cpuinfo", "flags : " .. base .. " fma4\n")
  seen("fma4 more", false, false)
  write("cpuinfo", "flags : " .. (base:gsub(" pclmulqdq", "")) .. "\n")
  seen("no pclmulqdq", false, true)
end

--- On aarch64, only the features a core chooses code by are keyed --
--- mbedtls's AES instructions and xz's CRC32 -- as on x86_64.
local function test_an_aarch64_host_keys_only_what_a_core_dispatches_on(tmp: string)
  local base = "fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics"
  local write, seen = host(tmp, "aarch64", "processor : 0\nFeatures : " .. base .. "\n")
  seen("the start", true, true)
  write("cpuinfo", "Features : " .. base .. " sve sve2\n")
  seen("sve more", false, false)
  write("cpuinfo", "Features : " .. (base:gsub(" crc32", "")) .. "\n")
  seen("no crc32", false, true)
  write("cpuinfo", "Features : " .. (base:gsub(" pmull", "")) .. "\n")
  seen("no pmull", false, true)
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
  local system: mut {string} = {}
  for _, path in ipairs(darwin) do system[#system + 1] = path == darwin[2] and plist or path end
  local sources: declared_key.HostSources = {
    packages = {}, system = system, cpu_features = {}, machine = "arm64", sysname = "Darwin",
    status = tmp .. "/status", own_proc = false, host_id = "macos-15", uid = 501,
  }
  local names: mut {string:boolean} = {}
  local identities: mut {string:boolean} = {}
  local function both(what: string)
    local named = declared_key.host_kernel(sources)
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
  cpuinfo: string?
  osrelease: string?
  version: string?
  sysctl: {string:string}?
  kernel: string
  kept: string
end

--- The sysctl names core/syscalls.c's `cpu_features` asks on macOS, by the
--- feature each answers for.
local darwin_features: {string:string} = {
  ["hw.optional.arm.FEAT_AES"] = "aes", ["hw.optional.AdvSIMD"] = "asimd",
  ["hw.optional.armv8_crc32"] = "crc32", ["hw.optional.arm.FEAT_PMULL"] = "pmull",
  ["hw.optional.arm.FEAT_SHA256"] = "sha2", ["hw.optional.armv8_2_sha512"] = "sha512",
}

--- Each recorded host, as ci/testdata/host_features holds it -- x86_64,
--- aarch64 and a machine no audit has read, every feature a core
--- chooses code by missing in turn, odd spacing, a missing file, and
--- macOS's sysctl -- is named by the key as its vector says and as
--- ci/cosmic_ci/host_id.tl does (a verdict cache is renamed by a byte of
--- it), and its processor's features are the vector's `kept`, which that
--- module lists, as the key's digest of them is.
local function test_every_recorded_host_is_named_as_the_ci_names_it(tmp: string)
  local text = assert(Fs.read("ci/testdata/host_features/vectors.json"))
  local recorded = assert(Json.decode_array(text))
  assert(#recorded >= 30, "the recorded hosts are gone")
  for i, entry in ipairs(recorded) do
    local vector = entry as Vector
    local release, version = tmp .. "/osrelease-" .. tostring(i), tmp .. "/version-" .. tostring(i)
    local osrelease = vector.osrelease
    if osrelease ~= nil then assert(Fs.write(release, osrelease)) end
    local vector_version = vector.version
    if vector_version ~= nil then assert(Fs.write(version, vector_version)) end
    local features: mut {string} = {}
    if vector.sysname == "Darwin" then
      for name, answer in pairs(vector.sysctl or {}) do
        if answer == "1" then features[#features + 1] = darwin_features[name] end
      end
    else
      features = listed(vector.cpuinfo or "")
    end
    local sources: declared_key.HostSources = {
      system = { "", release, if vector.sysname == "Darwin" then "" else version end },
      cpu_features = features, machine = vector.machine, sysname = vector.sysname,
    }
    local named = declared_key.host_kernel(sources)
    assert(named == vector.kernel, vector.name .. ": the key names " .. named .. ", CI " ..
        vector.kernel)
    assert(declared_key.host_cpu(sources) == Hash.hex_sha256("cpu " .. vector.kept),
      vector.name .. ": the key holds other features than " .. vector.kept)
  end
end

--- On this host, with nothing given, the key's kernel -- the processor
--- itself asked, on this host's machine -- names it as the files
--- the key reads give, which the vectors hold CI's reading to. (The
--- tree cannot require ci/'s module, so CI's own reading of this host is
--- not run here.) A worker whose /proc is a sandbox's own has no
--- /proc/sys/kernel to read, and checks nothing.
local function test_the_key_names_this_host_as_its_kernel_files_do(tmp: string)
  local names = assert(sys.uname())
  if names.sysname ~= "Linux" then Test.skip("only Linux lists its kernel in /proc") end
  -- TODO: run this sandboxed too, once a policy can grant a host file
  -- under /proc (kernel/osrelease, kernel/version): a sandbox's /proc is
  -- mounted subset=pid, and a grant of /proc/sys/kernel/osrelease reaches
  -- none of it, so every sandboxed leg skips here.
  local released = Fs.read("/proc/sys/kernel/osrelease")
  if released == nil then
    Test.skip("this worker's /proc has no kernel files to read")
    return
  end
  local release, version = tmp .. "/osrelease", tmp .. "/version"
  assert(Fs.write(release, released))
  assert(Fs.write(version, Fs.read("/proc/sys/kernel/version") or ""))
  local read = declared_key.host_kernel({ system = { "", release, version } })
  assert(read == declared_key.host_kernel(), "this host")
end
