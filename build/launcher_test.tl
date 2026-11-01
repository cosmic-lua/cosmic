--- The launcher's CPU check, run on the shell the template renders: the
--- x86_64 core is built for x86-64-v3 and the aarch64 Linux core for Armv8.2-A
--- with dot-product and half-precision floats, and either dies with SIGILL on
--- an older CPU, so the launcher names what the CPU lacks and exits 126 first.
--- The full launch, cache and all, is ci/fixtures/launcher_test.tl's.

local Child = require("cosmic.child")
local artifact = require("build.artifact")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local launcher = require("build.launcher")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true, profiles = { "system" } }

local arm = "  'Linux x86_64') cosmic_os=Linux; cosmic_target_id=1; " ..
  "cosmic_configuration_id=1; cosmic_offset=0; cosmic_block=0; cosmic_stored=0; " ..
  "cosmic_length=0; cosmic_sha256=0; cosmic_stub_block=; cosmic_stub_length=; " ..
  "cosmic_stub_sha256= ;;"

local arm64 = "  'Linux aarch64') cosmic_os=Linux; cosmic_target_id=2; " ..
  "cosmic_configuration_id=1; cosmic_offset=0; cosmic_block=0; cosmic_stored=0; " ..
  "cosmic_length=0; cosmic_sha256=0; cosmic_stub_block=; cosmic_stub_length=; " ..
  "cosmic_stub_sha256= ;;"

local v3 = "fpu sse4_2 avx avx2 fma bmi1 bmi2 movbe f16c abm xsave"

-- What the Linux kernel lists for a Cortex-A76 (a Raspberry Pi 5).
local v82 = "fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid " ..
  "asimdrdm lrcpc dcpop asimddp"

--- Runs the rendered launcher over a cpuinfo of `flags`, or one that is absent.
local function launch(tmp: string, hooks: boolean, flags?: string): Child.Result
  local script = tmp .. "/launcher"
  assert(Fs.write(script, launcher.render(arm, hooks), 0x1ed))
  local env: mut {string:string} = { PATH = "/usr/bin:/bin", COSMIC_PORTABLE_CACHE = tmp .. "/cache" }
  local cpuinfo = tmp .. "/cpuinfo"
  if flags ~= nil then
    assert(Fs.write(cpuinfo, "processor\t: 0\nflags\t\t: " .. flags .. "\nvmx flags\t: ept\n"))
  end
  env["COSMIC_PORTABLE_TEST_CPUINFO"] = cpuinfo
  return (assert(Child.run({ "/bin/sh", script }, { env = env, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })))
end

--- Runs the rendered launcher as an aarch64 Linux machine over a cpuinfo whose
--- Features line is `features`, or one that has none. A `uname` ahead of the
--- real one on PATH answers `-sm`, so the check runs on any host.
local function launch_aarch64(tmp: string, features?: string): Child.Result
  local script = tmp .. "/launcher"
  assert(Fs.write(script, launcher.render(arm64, true), 0x1ed))
  if Fs.stat(tmp .. "/bin") == nil then assert(Fs.mkdirs(tmp .. "/bin")) end
  assert(Fs.write(tmp .. "/bin/uname", table.concat({
    "#!/bin/sh",
    "[ \"$*\" = -sm ] && { echo 'Linux aarch64'; exit 0; }",
    "PATH=/usr/bin:/bin exec uname \"$@\"",
    "",
  }, "\n"), 0x1ed))
  local env: mut {string:string} = {
    PATH = tmp .. "/bin:/usr/bin:/bin",
    COSMIC_PORTABLE_CACHE = tmp .. "/cache",
  }
  local cpuinfo = tmp .. "/cpuinfo"
  if features ~= nil then
    assert(Fs.write(cpuinfo, "processor\t: 0\nBogoMIPS\t: 50.00\nFeatures\t: " .. features ..
        "\nCPU implementer\t: 0x41\n\nprocessor\t: 1\nFeatures\t: fp asimd\n"))
  end
  env["COSMIC_PORTABLE_TEST_CPUINFO"] = cpuinfo
  return (assert(Child.run({ "/bin/sh", script }, { env = env, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })))
end

local function on_x86_64_linux(): boolean
  local names = sys.uname()
  return names ~= nil and names.sysname == "Linux" and names.machine == "x86_64"
end

local function test_a_cpu_below_x86_64_v3_is_refused_by_name(tmp: string)
  if not on_x86_64_linux() then
    Test.skip("the check runs on x86_64 Linux")
    return
  end
  local r = launch(tmp, true, "fpu sse4_2 avx xsave abm")
  assert(r.code == 126, "exit status " .. tostring(r.code))
  assert((r.stderr or ""):find("cosmic portable: this CPU lacks avx2 fma bmi1 bmi2 movbe f16c; ", 1, true),
    tostring(r.stderr))
  assert(Fs.stat(tmp .. "/cache") == nil, "a refused launch made the cache")
end

local function test_a_feature_is_matched_whole(tmp: string)
  if not on_x86_64_linux() then
    Test.skip("the check runs on x86_64 Linux")
    return
  end
  -- "bmi1" is not "bmi2", and "avx2" is not "avx".
  local r = launch(tmp, true, "avx2 fma bmi1 movbe f16c abm xsave")
  assert((r.stderr or ""):find("this CPU lacks avx bmi2;", 1, true), tostring(r.stderr))
end

-- The arm's core is empty, so a launch that gets past the CPU check stops at
-- the digest of the core it extracts and has made the cache by then. A
-- launch the check refuses does neither (the first test above).
local function assert_passed_the_cpu_check(r: Child.Result, tmp: string)
  local err = r.stderr or ""
  assert(not err:find("this CPU lacks", 1, true), err)
  assert(r.code == 126, "exit status " .. tostring(r.code))
  assert(err:find("cosmic portable: extracted core digest differs", 1, true), err)
  assert(Fs.stat(tmp .. "/cache") ~= nil, "a launch past the check made no cache")
end

local function test_a_cpu_with_x86_64_v3_is_not_refused(tmp: string)
  if not on_x86_64_linux() then
    Test.skip("the check runs on x86_64 Linux")
    return
  end
  assert_passed_the_cpu_check(launch(tmp, true, v3), tmp)
end

local function test_an_aarch64_cpu_below_armv8_2_is_refused_by_name(tmp: string)
  -- A Cortex-A72 (a Raspberry Pi 4, Graviton1): NEON, AES, SHA and CRC32.
  local r = launch_aarch64(tmp, "fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid")
  assert(r.code == 126, "exit status " .. tostring(r.code))
  assert((r.stderr or ""):find("cosmic portable: this CPU lacks asimddp asimdhp fphp atomics asimdrdm; " ..
      "the aarch64 core needs Armv8.2-A", 1, true), tostring(r.stderr))
  assert(Fs.stat(tmp .. "/cache") == nil, "a refused launch made the cache")
end

local function test_an_aarch64_feature_is_matched_whole(tmp: string)
  -- "asimd" is not "asimdhp", "fp" is not "fphp", and only the first
  -- Features line counts.
  local r = launch_aarch64(tmp, (v82:gsub(" asimdhp", ""):gsub(" crc32", "")))
  assert((r.stderr or ""):find("this CPU lacks asimdhp crc32;", 1, true), tostring(r.stderr))
  local lone = launch_aarch64(tmp, "fp asimd")
  assert((lone.stderr or ""):find("this CPU lacks asimddp asimdhp fphp atomics asimdrdm crc32;", 1, true),
    tostring(lone.stderr))
end

-- A launch past the check goes on to the cache, which the stub `uname` has
-- told to use Linux's tools; those runs need a Linux host.
local function on_linux(): boolean
  local names = sys.uname()
  return names ~= nil and names.sysname == "Linux"
end

local function test_an_aarch64_cpu_with_armv8_2_is_not_refused(tmp: string)
  if not on_linux() then
    Test.skip("past the check, the launcher uses Linux's tools")
    return
  end
  assert_passed_the_cpu_check(launch_aarch64(tmp, v82), tmp)
end

local function test_an_aarch64_missing_features_line_is_not_refused(tmp: string)
  if not on_linux() then
    Test.skip("past the check, the launcher uses Linux's tools")
    return
  end
  assert_passed_the_cpu_check(launch_aarch64(tmp, nil), tmp)
end

local function test_a_missing_flags_line_is_not_refused(tmp: string)
  if not on_x86_64_linux() then
    Test.skip("the check runs on x86_64 Linux")
    return
  end
  assert_passed_the_cpu_check(launch(tmp, true, nil), tmp)
end

local function test_a_release_launcher_reads_only_proc_cpuinfo()
  local text = launcher.render(arm, false)
  assert(text:find('portable_cpuinfo=/proc/cpuinfo', 1, true), "release reads /proc/cpuinfo")
  assert(not text:find("TEST_CPUINFO", 1, true), "release carries the test override")
end

--- A header's script, without the comment that pads it to its fixed length.
local function script_of(header: string): string
  return (header:sub(1, 16384):gsub("\n# *\n$", "\n"))
end

-- The shell header is a fixed 16384 bytes and the arms and hooks go into it.
-- A ceiling under it leaves room for the next addition to be made on purpose:
-- the release launcher and the hook-bearing test launcher, each with the
-- largest arms a release has (every target compressed, with a stub, the
-- widest offsets), must stay under it, so growth meets the limit in a test
-- and not in a release build.
local script_ceiling <const> = 16000

local function test_the_shell_header_fits_its_capacity_with_every_target_arm()
  -- The cores are large so the offsets and lengths in the arms have their
  -- widest digits.
  local records = table.concat({
    "1\t1\trelease\tx86\tLinux\tx86_64",
    "2\t1\trelease\tarm\tLinux\taarch64",
    "3\t1\trelease\tmac\tDarwin\tarm64",
  }, "\n") .. "\n"
  local cores: {string:string} = {
    x86 = string.rep("x", 12000000),
    arm = string.rep("a", 12000000),
    mac = string.rep("m", 12000000),
  }
  local packing: artifact.Packing = {
    stubs = { x86 = string.rep("s", 60000), arm = string.rep("t", 60000),
      mac = string.rep("u", 120000) },
    compress = function(core: string): string?, string
      return core:sub(1, #core // 2), ""
    end,
  }
  for _, packed in ipairs({ false, true }) do
    local with = if packed then packing else nil end
    local release, release_trouble = artifact.prefix(records, cores, nil, with)
    assert(release ~= nil, "the release header: " .. release_trouble)
    local fixture, fixture_trouble = artifact.test_prefix(records, cores, with)
    assert(fixture ~= nil, "the fixture header: " .. fixture_trouble)
    for name, header in pairs({ release = release, fixture = fixture }) do
      assert(#script_of(header) <= script_ceiling, name .. " launcher is " ..
          tostring(#script_of(header)) .. " bytes, over its ceiling of " .. tostring(script_ceiling))
    end
    -- A line opening with an arm's quoted name is the arm the manifest
    -- selects (ci/fixtures/runtime_test.tl reads it so), so the launcher's
    -- own code must open no other line that way.
    for _, header in ipairs({ release, fixture }) do
      for _, host in ipairs({ "'Linux x86_64'", "'Linux aarch64'", "'Darwin arm64'" }) do
        local count = 0
        for line in header:sub(1, 16384):gmatch("[^\n]+") do
          if line:sub(1, #host + 2) == "  " .. host then count = count + 1 end
        end
        assert(count == 1, host .. " opens " .. tostring(count) .. " header lines")
      end
    end
  end
end

local function test_a_release_launcher_carries_no_test_hook_and_a_raw_arm_no_stub()
  local records = "1\t1\trelease\tx86\tLinux\tx86_64\n"
  local raw = assert(artifact.prefix(records, { x86 = "ELF-x" }))
  assert(raw:find("cosmic_stub_length=;", 1, true) ~= nil,
    "a raw arm sets its stub fields empty, so the environment's cannot be read")
  assert(raw:find("portable_test_hook", 1, true) == nil and raw:find("after_stub", 1, true) == nil)
  local packed = assert(artifact.prefix(records, { x86 = "ELF-x" },
    nil, { stubs = { x86 = "STUB" }, compress = function(core: string): string?, string
      return "frame-of-" .. core, ""
    end }))
  assert(packed:find("cosmic_stub_length=4;", 1, true) ~= nil, "a compressed arm names its stub")
  assert(packed:find("cosmic_stored=" .. tostring(#"frame-of-ELF-x") .. ";", 1, true) ~= nil,
    "and the stored length of its core")
  local hooked = assert(artifact.test_prefix(records, { x86 = "ELF-x" },
    { stubs = { x86 = "STUB" }, compress = function(core: string): string?, string
      return "frame-of-" .. core, ""
    end }))
  assert(hooked:find("portable_test_hook after_stub", 1, true) ~= nil,
    "the test launcher gates the stub's run")
end
