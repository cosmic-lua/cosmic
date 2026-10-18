--- How long a boot's workers take to start ([`build.workers`]'s
--- `boot_spec`) follows from where they get the bridge's compiles
--- (core/bridge.lua): from the shared cache a boot's bridge kept them in,
--- or, with the cache off, from source. The spec is read in this program,
--- started with and without `COSMIC_BUILD_CACHE=0`.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which this test starts.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- What `boot_spec` answers in a process of this program with `env`:
--- `startup_ns` and `open_bytes`, by a tab.
local function spec_with(env: {string:string}): string
  local command = this_program.program({ "-e",
    'local spec = require("build.workers").boot_spec("/root", "/tl")\n' ..
      'print(spec.startup_ns .. "\\t" .. spec.open_bytes)' },
    { env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(command.argv, command.options))
  assert(result.code == 0, result.stderr)
  return (assert(result.stdout):gsub("%s+$", ""))
end

local function test_workers_start_quickly_only_where_the_compiles_are_cached()
  local home = { HOME = "/home/someone" }
  assert(spec_with(home) == "1000000000\t524288", "with the cache on")
  assert(spec_with({ XDG_CACHE_HOME = "/cache" }) == "1000000000\t524288", "with XDG_CACHE_HOME")
  assert(spec_with({ XDG_CACHE_HOME = "relative", HOME = "/home/someone" }) ==
      "1000000000\t524288", "with a relative XDG_CACHE_HOME and an absolute HOME")
  local record Case
    name: string
    environment: {string:string}
  end
  local off: {Case} = {
    { name = "COSMIC_BUILD_CACHE=0", environment = { HOME = "/home/someone", COSMIC_BUILD_CACHE = "0" } },
    { name = "a relative name", environment = { HOME = "/home/someone", COSMIC_BUILD_CACHE = "cache.db" } },
    { name = "no absolute HOME", environment = { HOME = "home" } },
    { name = "no absolute HOME or XDG_CACHE_HOME", environment = { HOME = "home", XDG_CACHE_HOME = "relative" } },
  }
  for _, case in ipairs(off) do
    assert(spec_with(case.environment) == "9000000000\t3145728", "with " .. case.name)
  end
  local absolute = { HOME = "/home/someone", COSMIC_BUILD_CACHE = "/shared/cache.db" }
  assert(spec_with(absolute) == "1000000000\t524288", "with an absolute name")
end
