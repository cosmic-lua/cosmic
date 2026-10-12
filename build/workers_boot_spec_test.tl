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
  assert(spec_with({}) == "1000000000\t524288", "with the cache on")
  assert(spec_with({ COSMIC_BUILD_CACHE = "0" }) == "9000000000\t3145728", "with the cache off")
end
