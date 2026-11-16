--- What the runner answers of the requirement `pinned_zig` ([`build.c`]'s `worker_zig`): the zig a check of the core's
--- C starts, where a test's worker can start it, and why not where it cannot, as after a seeded boot, which installs no
--- zig. Each case is a tree of its own holding only bin/zig.pin, and a cache of its own.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Zig = require("build.zig")
local c = require("build.c")

Test.policy{}

--- A root under `tmp` whose bin/zig.pin names this host, and the variables that put its caches under `tmp/cache`.
local function seeded(tmp: string): string, {string:string}
  local names = assert(sys.uname())
  local host = assert(Zig.host(names.sysname, names.machine))
  assert(Fs.mkdirs(tmp .. "/root/bin") and Fs.mkdirs(tmp .. "/cache"))
  assert(Fs.write(tmp .. "/root/bin/zig.pin", "version 0.16.0\n" .. host .. " " .. string.rep("a", 64) .. "\n"))
  return tmp .. "/root", { HOME = tmp, XDG_CACHE_HOME = tmp .. "/cache" }
end

--- Installs a stand-in for the pinned zig where `root`'s pin names it under `variables`' cache, and answers its path.
local function install(root: string, variables: {string:string}): string
  local cache = assert(Fs.cache_dir("zig", { environment = variables }))
  local found = assert(Zig.pinned_install(root, cache))
  assert(Fs.mkdirs(found.path))
  assert(Fs.write(found.path .. "/zig", "#!/bin/sh\n", 0x1ed))
  return found.path .. "/zig"
end

--- `variables` with COSMIC_ZIG naming `zig`.
local function naming(variables: {string:string}, zig: string): {string:string}
  local out: mut {string:string} = { COSMIC_ZIG = zig }
  for name, value in pairs(variables) do out[name] = value end
  return out
end

--- A seeded boot's host, with no zig installed: the requirement is absent, and the reason names the step that installs
--- it, so the checks are skipped saying so rather than fail on a bin/zig a sandboxed worker cannot start.
local function test_no_pinned_zig_installed_is_absent_and_says_how_to_install_it(tmp: string)
  local root, variables = seeded(tmp)
  local key, why = c.worker_zig(root, variables, true)
  assert(key == nil, tostring(key))
  assert(why:find("is not installed", 1, true) ~= nil, why)
  assert(why:find("COSMIC_BOOT_SEED=0", 1, true) ~= nil, why)
end

--- With the pinned zig installed, the requirement is present, keyed by the install's name, sandboxed or not.
local function test_the_installed_pinned_zig_is_present_keyed_by_its_install(tmp: string)
  local root, variables = seeded(tmp)
  local zig = install(root, variables)
  local key, why = c.worker_zig(root, variables, true)
  assert(key == Fs.basename(Fs.dirname(zig)), tostring(key) .. ": " .. why)
  assert(c.worker_zig(root, variables, false) == key)
end

--- A COSMIC_ZIG outside the zig cache is one a sandboxed worker does not see, so it is absent there and present where
--- workers run unsandboxed; one under the cache is present either way, and one that is not there is absent.
local function test_a_cosmic_zig_is_present_where_a_worker_sees_it(tmp: string)
  local root, variables = seeded(tmp)
  local outside = tmp .. "/zig"
  assert(Fs.write(outside, "#!/bin/sh\n", 0x1ed))
  local named = naming(variables, outside)
  local key, why = c.worker_zig(root, named, true)
  assert(key == nil and why:find("outside the zig cache", 1, true) ~= nil, tostring(key) .. ": " .. why)
  assert(c.worker_zig(root, named, false) == "COSMIC_ZIG " .. outside)
  local inside = install(root, variables)
  local under = naming(variables, inside)
  assert(c.worker_zig(root, under, true) == "COSMIC_ZIG " .. inside)
  local gone = naming(variables, tmp .. "/no-such-zig")
  local none, said = c.worker_zig(root, gone, false)
  assert(none == nil and said:find("which is not there", 1, true) ~= nil, said)
end
