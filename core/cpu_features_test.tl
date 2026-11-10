--- What [`sys.cpu_features`] answers, which is the processor's own: a
--- verdict earned on one processor says nothing of another's, so this
--- module declares `cpu_features` and its tests are keyed by the
--- processor's features (doc/testing.md, "processor features"). A test
--- that only needs the answer to be some list belongs where it is; one
--- whose pass or fail depends on what the processor has belongs here.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

--- The processor's features are the subject, and /proc is where the
--- kernel lists them.
Test.policy{
  cpu_features = true,
  profiles = { "proc" },
}

--- The features `cpu_features` can answer, by machine.
local KNOWN_FEATURES <const>: {string:{string:boolean}} = {
  x86_64 = { aes = true, avx512_vnni = true, avx512f = true, avx512vl = true, avx_vnni = true,
    pclmulqdq = true, sha_ni = true, sse4_1 = true, ssse3 = true },
  aarch64 = { aes = true, asimd = true, crc32 = true, pmull = true, sha2 = true, sha512 = true },
  arm64 = { aes = true, asimd = true, crc32 = true, pmull = true, sha2 = true, sha512 = true },
}

--- The file at `path`, or "" where it cannot be read.
local function read_file(path: string): string
  return (Fs.read(path)) or ""
end

--- `cpu_features` names each feature this processor has, of those it
--- can answer for its machine, once and in byte order, as
--- /proc/cpuinfo's "flags" or "Features" does where the worker has one
--- to read: its own procfs, a sandbox's, has none.
local function test_cpu_features_are_named_as_proc_cpuinfo_names_them()
  local names = assert(sys.uname())
  local known = KNOWN_FEATURES[names.machine] or {}
  local features = sys.cpu_features()
  for i, name in ipairs(features) do
    assert(known[name] == true, names.machine .. " answers " .. name)
    local before = features[i - 1]
    assert(i == 1 or (before ~= nil and before < name), "not in byte order, or twice: " .. name)
  end
  local cpuinfo = read_file("/proc/cpuinfo")
  if cpuinfo == "" then Test.skip("this host has no /proc/cpuinfo to list flags from") end
  local listed: mut {string:boolean} = {}
  for line in cpuinfo:gmatch("[^\n]+") do
    local flags = line:match("^flags%s*:%s*(.*)$") or line:match("^Features%s*:%s*(.*)$")
    for flag in (flags or ""):gmatch("%S+") do listed[flag] = true end
  end
  local expected: mut {string} = {}
  for name in pairs(known) do
    if listed[name] == true then expected[#expected + 1] = name end
  end
  table.sort(expected)
  assert(table.concat(features, " ") == table.concat(expected, " "),
    "cpu_features answers " .. table.concat(features, " ") .. ", /proc/cpuinfo lists " ..
      table.concat(expected, " "))
end
