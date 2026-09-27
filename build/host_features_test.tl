--- .github/scripts/host-features.sh, which names a CI leg's verdict
--- cache, and `declared_key.host_features` answer the same digest of
--- the same host, and it moves with what `host_identity` keys of it: a
--- cache named by it holds verdicts whose keys the host reaches.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local declared_key = require("build.declared_key")
local Test = require("cosmic.test")

--- The script, run by the system's `sh`.
Test.needs{ reads = { ".github/scripts/host-features.sh" } }

local SCRIPT <const> = ".github/scripts/host-features.sh"

--- A host under `tmp` of `machine` (nil: this host's, on both sides)
--- whose /proc/cpuinfo holds `cpuinfo`:
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
  local sources: declared_key.HostSources = {
    packages = { write("packages", "p1") },
    system = { write("os", "o1"), write("osrelease", "6.17.0-1022-azure\n"),
      write("version", "#22-Ubuntu SMP\n") },
    cpuinfo = write("cpuinfo", cpuinfo), machine = machine,
    status = write("status", "Uid: 1 1 1 1\n"), own_proc = true, host_id = "h", uid = 1,
  }
  local function script(): string
    local argv = { "/bin/sh", SCRIPT, sources.cpuinfo, sources.system[2], sources.system[3] }
    if machine ~= nil then argv[#argv + 1] = machine end
    local result = assert(Child.run(argv, { stdout = "capture", stderr = "capture",
      timeout_ms = 10000 }))
    assert(result.ok, tostring(result.stderr))
    return ((result.stdout as string):gsub("%s+$", ""))
  end
  local names: {string:boolean} = {}
  local identities: {string:boolean} = {}
  local function both(what: string, moved: boolean)
    local named, keyed = script(), declared_key.host_features(sources)
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
--- mbedtls's AES-NI, xz's carry-less CRCs, glibc's FMA libm, which a
--- checked core linked before it was static musl on Linux -- so hosted
--- runners that differ in any other split neither the verdicts nor
--- their cache, and a host lacking one of them keys apart.
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
  write("cpuinfo", "flags : " .. (base:gsub(" fma", "")) .. "\n")
  both("no fma", true)
  write("cpuinfo", "flags : " .. base .. " fma4\n")
  both("fma4 more", true)
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
--- key's (`sys.uname`) are the same one: a host listing every feature
--- either list keeps, and some neither does, is named alike.
local function test_the_script_and_the_key_take_the_same_machine_by_default(tmp: string)
  local _, both = host(tmp, nil, "flags : aes avx2 fma fma4 pclmulqdq sse4_1 ssse3 " ..
    "avx512f hypervisor\nFeatures : asimd aes pmull crc32 sve\n")
  both("this host", true)
end
