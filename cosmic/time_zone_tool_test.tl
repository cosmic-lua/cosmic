--- The time zone `TZ` names in a fresh process, and the one `TZDIR`
--- does not: the case of cosmic/time_zone_test.tl that starts the
--- program, apart so the rest stand while the tree moves.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local Time = require("cosmic.time")

--- The program itself, which the test starts, running a file `--standalone`
--- ([`build.standalone`]). No zone is read from the host's files: a program
--- reads only the zones it carries.
Test.policy{ profiles = { "cosmic" } }

--- `local_zone` with no options reads the process's own `TZ` -- set
--- and empty, UTC -- and neither it nor `zone` reads `TZDIR`: a zone
--- is the binary's, whatever the host's files say.
local function test_the_environment_names_zones_and_holds_no_rules(tmp: string)
  local script = tmp .. "/local.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
return function(): integer
  local z, why = Time.local_zone()
  if z == nil then
    Fs.put(Fs.stdout, "nil " .. why .. "\n")
    return 1
  end
  local again = assert(Time.local_zone())
  local only, _ = Time.zone("Test/Here")
  Fs.put(Fs.stdout, z.name .. " " .. Time.civil(0, z).offset .. " " .. tostring(rawequal(z, again)) ..
    " " .. tostring(only) .. "\n")
  return 0
end
]]))
  -- Zones `TZDIR` would have given, as glibc reads it: Tokyo under
  -- Berlin's name, and one IANA has none of.
  assert(Fs.mkdirs(tmp .. "/tzdir/Test"))
  assert(Fs.mkdirs(tmp .. "/tzdir/Europe"))
  local tokyo = assert(Store.zoneinfo("Asia/Tokyo"))
  assert(Fs.write(tmp .. "/tzdir/Test/Here", tokyo))
  assert(Fs.write(tmp .. "/tzdir/Europe/Berlin", tokyo))
  for tz, want in pairs({ [""] = "UTC 0 true nil\n", ["Europe/Berlin"] = "Europe/Berlin 3600 true nil\n" }) do
    local started = this_program.program({ "--standalone", script },
      { env = { TZ = tz, TZDIR = tmp .. "/tzdir", XDG_CACHE_HOME = tmp .. "/cache" },
        stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) })
    local result = assert(Child.run(started.argv, started.options))
    assert(result.code == 0 and result.stdout == want, tostring(result.stdout) .. tostring(result.stderr))
  end
end
