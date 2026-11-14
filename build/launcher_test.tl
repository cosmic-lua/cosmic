--- The launcher's CPU check, run on the shell the template renders: the
--- x86_64 core is built for x86-64-v3 and the aarch64 Linux core for Armv8.2-A
--- with dot-product and half-precision floats, and either dies with SIGILL on
--- an older CPU, so the launcher names what the CPU lacks and exits 126 first.
--- The full launch, cache and all, is ci/fixtures/launcher_test.tl's. Also here: the list of the host's
--- programs the launcher runs, held to the launcher's text, and what the modules that run it grant, held to
--- that list.

local Child = require("cosmic.child")
local artifact = require("build.artifact")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local launcher = require("build.launcher")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

--- The host's shell, which runs the rendered launcher, and the programs
--- the launcher runs ([`programs`]), each granted where a host has it,
--- under /bin or /usr/bin; and the text of the modules that grant them,
--- which a test here holds to that list.
Test.policy{
  grants = {
    { path = "build/launcher_test.tl", letters = "r" },
    { path = "core/launcher_cache_test.tl", letters = "r" },
    { path = "cosmic/signal_ignored_test.tl", letters = "r" },
    { path = "build/test_policy_plan_tool_test.tl", letters = "r" },
    { path = "/bin/sh", letters = "r" }, { path = "/usr/bin/sh", letters = "r" },
    { path = "/bin/uname", letters = "r" }, { path = "/usr/bin/uname", letters = "r" },
    { path = "/bin/mkdir", letters = "r" }, { path = "/usr/bin/mkdir", letters = "r" },
    { path = "/bin/stat", letters = "r" }, { path = "/usr/bin/stat", letters = "r" },
    { path = "/bin/mktemp", letters = "r" }, { path = "/usr/bin/mktemp", letters = "r" },
    { path = "/bin/head", letters = "r" }, { path = "/usr/bin/head", letters = "r" },
    { path = "/bin/rm", letters = "r" }, { path = "/usr/bin/rm", letters = "r" },
    { path = "/bin/wc", letters = "r" }, { path = "/usr/bin/wc", letters = "r" },
    { path = "/bin/dd", letters = "r" }, { path = "/usr/bin/dd", letters = "r" },
    { path = "/bin/chmod", letters = "r" }, { path = "/usr/bin/chmod", letters = "r" },
    { path = "/bin/id", letters = "r" }, { path = "/usr/bin/id", letters = "r" },
    { path = "/bin/ln", letters = "r" }, { path = "/usr/bin/ln", letters = "r" },
    { path = "/bin/rmdir", letters = "r" }, { path = "/usr/bin/rmdir", letters = "r" },
    { path = "/bin/sha256sum", letters = "r" }, { path = "/usr/bin/sha256sum", letters = "r" },
  },
}

--- The host's programs the launcher runs on Linux, with the shell that reads it. A test below holds this list to
--- the launcher's own text, and what the modules that run the launcher grant to this list.
-- TODO: have those modules name this list, in place of the path of each program under /bin and /usr/bin that
-- each spells out, once a declaration can name a program (`processes` by name, which the sandbox resolves, with
-- what its loader reads).
local programs <const>: {string} = { "sh", "uname", "mkdir", "stat", "mktemp", "head", "rm", "wc", "dd", "chmod",
  "id", "ln", "rmdir", "sha256sum" }

--- Those of them the launcher runs to start a core its cache already holds: `sha256sum` only where the entry's
--- stamp does not hold, which no test of those modules arranges.
local warm_programs <const>: {string} = { "sh", "uname", "stat", "sha256sum" }

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

--- What a shell reads as a word to run that is no program of the host's: its own words.
local shell_words <const>: {string:boolean} = {
  ["case"] = true, esac = true, ["for"] = true, ["in"] = true, ["do"] = true, done = true, ["if"] = true,
  ["then"] = true, ["elif"] = true, ["else"] = true, fi = true, ["while"] = true, ["until"] = true,
  ["break"] = true, continue = true, ["return"] = true, exit = true, export = true, eval = true, exec = true,
  command = true, printf = true, test = true, trap = true, umask = true, shift = true, set = true, unset = true,
  read = true, cd = true, echo = true, ["true"] = true, ["false"] = true,
}

--- The programs the shell text `script` runs, as a set: the first word of each command that is no word of the
--- shell's, no assignment, and no name of the launcher's own (every function and variable of it begins
--- `portable_` or `cosmic_`). It reads the forms the launcher is written in, not the shell's grammar: a command
--- begins a line, or follows `;`, `|`, `&`, a bracket, a keyword, or `command`, `exec` or `eval` and their
--- options, after any `NAME=value` set for it alone, and may be named by its path. It does not read a command a
--- variable names (`$tool x`), one in a quoted word that `eval` or `trap` is given, one after a redirection, or
--- one inside a `${...}`: the launcher has none of those but its own files, which it runs by the variables that
--- hold them, and a change that adds one hides it from this.
local function commands_of(script: string): mut {string:boolean}
  local lines: mut {string} = {}
  for line in (script:gsub("\\\n", " ") .. "\n"):gmatch("([^\n]*)\n") do
    -- A comment, to the end of its line.
    lines[#lines + 1] = line:gsub("^%s*#.*$", ""):gsub("%s#.*$", "")
  end
  -- A double-quoted word holds a command only in a `$(`, and is otherwise words to print; a single-quoted word
  -- and a variable's expansion hold none.
  local bare = table.concat(lines, "\n"):gsub('"[^"]*"', function(quoted: string): string
    return if quoted:find("$(", 1, true) ~= nil then quoted:sub(2, -2) else "" end
  end):gsub("'[^']*'", ""):gsub("%${[^}]*}", "")
  -- The pattern that begins an arm of a `case`, up to its `)`.
  local unarmed = ("\n" .. bare):gsub("\n(%s*)[%w_|*?.-]+%)", "\n%1")
  local found: mut {string:boolean} = {}
  for segment in unarmed:gmatch("[^\n;|&(){}`]+") do
    local rest = segment:gsub("^%s+", "")
    local stripped = true
    while stripped do
      stripped = false
      -- A keyword a command follows, a word of the shell's that runs the one after it, an option of that word's,
      -- or a variable set for the command alone.
      local after = rest:match("^if%s+(.*)$") or rest:match("^then%s+(.*)$") or rest:match("^else%s+(.*)$") or
        rest:match("^elif%s+(.*)$") or rest:match("^while%s+(.*)$") or rest:match("^until%s+(.*)$") or
        rest:match("^do%s+(.*)$") or rest:match("^!%s+(.*)$") or rest:match("^command%s+(.*)$") or
        rest:match("^exec%s+(.*)$") or rest:match("^eval%s+(.*)$") or rest:match("^%-%a+%s+(.*)$") or
        rest:match("^[%a_][%w_]*=%S*%s+(.*)$")
      if after ~= nil then
        rest = after
        stripped = true
      end
    end
    -- A program named by its path is the last name of it.
    local word = rest:match("^/[%w_./-]*/([%a_][%w_.-]*)%f[%s%z]") or rest:match("^([%a_][%w_.-]*)%f[%s%z]")
    if word ~= nil and shell_words[word] ~= true and word:find("^portable_") == nil and
        word:find("^cosmic_") == nil and rest:find("^[%a_][%w_]*=") == nil then
      found[word] = true
    end
  end
  return found
end

--- The scan reads a command in each form the launcher writes one, and none where there is none: a comment, a
--- word to print, a pattern of a `case`, a variable's expansion, a name of the launcher's own.
local function test_the_scan_reads_a_command_in_each_form_the_launcher_writes()
  local found = commands_of(table.concat({
    "#!/bin/sh",
    "# comment_word here",
    "plain x # trailing_comment y",
    "if first x; then second x; elif third x; then fourth; else fifth x; fi",
    "while sixth; do seventh x; done",
    "until eighth; do :; done",
    "x=$(ninth -u) || tenth 'quoted_word; not_this'",
    'y="$(LC_ALL=C eleventh -c %s -- "$1")" && twelfth',
    "thirteenth x | fourteenth \\",
    "  -n 1",
    "case $x in",
    "  Linux) fifteenth -T a b || return 1 ;;",
    "  directory|'Directory') ;;",
    "  *) portable_die \"words (run sixteenth x; or seventeenth)\" ;;",
    "esac",
    "command -v eighteenth >/dev/null 2>&1",
    "exec /usr/bin/nineteenth x",
    "portable_out=${TMPDIR-twentieth}",
    "! twenty_first x",
    "cosmic_helper x",
    "( twenty_second; { twenty_third; } )",
    "z=`twenty_fourth`",
  }, "\n") .. "\n")
  local wanted: {string} = { "plain", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
    "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "eighteenth", "nineteenth",
    "twenty_first", "twenty_second", "twenty_third", "twenty_fourth" }
  local count = 0
  for _, name in ipairs(wanted) do
    assert(found[name] == true, "the scan did not read " .. name)
    count = count + 1
  end
  for name in pairs(found) do
    count = count - 1
    assert(count >= 0, "the scan read a command where there is none: " .. name)
  end
end

--- The launcher runs the programs of the list, and no other that the scan reads ([`commands_of`] says what it
--- does not): each is found in its text, with the hooks a test asks for and without, and nothing else is but
--- `shasum`, which it falls back to where there is no `sha256sum` (macOS, where no worker is sandboxed).
local function test_the_launcher_runs_the_listed_programs_and_no_other_the_scan_reads()
  local shipped = launcher.render(arm .. "\n" .. arm64, false)
  local found = commands_of(shipped)
  for name in pairs(commands_of(launcher.render(arm .. "\n" .. arm64, true))) do
    found[name] = true
  end
  assert(shipped:sub(1, 10) == "#!/bin/sh\n", "the launcher is no longer read by /bin/sh")
  found["sh"] = true
  local listed: mut {string:boolean} = { shasum = true }
  for _, name in ipairs(programs) do
    listed[name] = true
    assert(found[name] == true, name .. " is listed, and the launcher's text runs it nowhere this test reads")
  end
  for name in pairs(found) do
    assert(listed[name] == true, "the launcher runs " .. name .. ", which the list of its programs does not hold: " ..
        "add it there and to the modules that grant them, or to the shell's words if it is one")
  end
end

--- The absolute paths the policy of the module at `file` grants, however each grant is laid out; the module
--- declares no profile "system", which would give it every program.
local function granted(file: string): {string:boolean}
  local text = assert(Fs.read(file), file)
  local policy = assert(text:match("\nTest%.policy%s*(%b{})"), file .. " has no policy")
  assert(policy:find('"system"', 1, true) == nil, file .. " declares the system, and so grants every program")
  local out: mut {string:boolean} = {}
  for path in policy:gmatch('path%s*=%s*"(/[^"]+)"') do out[path] = true end
  return out
end

--- The modules that run the launcher's every path grant each program of the list, under /bin and /usr/bin, and
--- no other; those that start it on a core its cache holds grant what that runs, and no other.
local function test_the_modules_that_run_the_launcher_grant_its_programs()
  local function held(files: {string}, names: {string})
    local wanted: mut {string:boolean} = {}
    for _, name in ipairs(names) do
      wanted["/bin/" .. name] = true
      wanted["/usr/bin/" .. name] = true
    end
    for _, file in ipairs(files) do
      local grants = granted(file)
      for path in pairs(wanted) do
        assert(grants[path] == true, file .. " does not grant " .. path .. ", which the launcher may run")
      end
      for path in pairs(grants) do
        assert(wanted[path] == true, file .. " grants " .. path .. ", which is no program the launcher runs there")
      end
    end
  end
  held({ "build/launcher_test.tl", "core/launcher_cache_test.tl" }, programs)
  held({ "cosmic/signal_ignored_test.tl", "build/test_policy_plan_tool_test.tl" }, warm_programs)
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
