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

local function test_the_script_and_the_key_name_the_host_alike(tmp: string)
  local function write(name: string, text: string): string
    assert(Fs.write(tmp .. "/" .. name, text))
    return tmp .. "/" .. name
  end
  local sources: declared_key.HostSources = {
    packages = { write("packages", "p1") },
    system = { write("os", "o1"), write("osrelease", "6.17.0-1022-azure\n"),
      write("version", "#22-Ubuntu SMP\n") },
    cpuinfo = write("cpuinfo", "processor : 0\nflags : sse avx b_2 a\n" ..
      "vmx flags : ept\nprocessor : 1\nflags\t: a avx sse b_2\n"),
    status = write("status", "Uid: 1 1 1 1\n"), own_proc = true, host_id = "h", uid = 1,
  }
  local function script(): string
    local result = assert(Child.run({ "/bin/sh", SCRIPT, sources.cpuinfo, sources.system[2],
      sources.system[3] }, { stdout = "capture", stderr = "capture", timeout_ms = 10000 }))
    assert(result.ok, tostring(result.stderr))
    return ((result.stdout as string):gsub("%s+$", ""))
  end
  local function identity(): string
    return declared_key.host_identity(declared_key.digests(tmp), sources)
  end
  -- Each name, and each identity, seen: a change moves both or neither.
  local names: {string:boolean} = {}
  local identities: {string:boolean} = {}
  local function both(what: string, moved: boolean)
    local named, keyed = script(), declared_key.host_features(sources)
    assert(named == keyed, what .. ": the script names " .. named .. ", the key " .. keyed)
    assert(#named == 16, named)
    local id = identity()
    assert((names[named] == nil) == moved, what .. ": the name")
    assert((identities[id] == nil) == moved, what .. ": the identity")
    names[named], identities[id] = true, true
  end
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
