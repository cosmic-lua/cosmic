--- How a test starts this very program (build.this_program's `program`).

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- What `program` copies is the whole of this process's environment,
--- and what it starts is this very program, which reads its own command
--- line in /proc.
Test.needs{
  host = { "/proc" },
  env = { "*" },
  lua = true,
}

--- Swaps [`Proc.relaunch`] for one answering `relaunch` while `fn` runs.
local function relaunching(relaunch: Proc.Relaunch | nil, fn: function())
  local real = Proc.relaunch
  Proc.relaunch = function(): Proc.Relaunch | nil, string
    return relaunch, relaunch == nil and "no artifact" or ""
  end
  local ok, trouble = pcall(function(): string
    fn()
    return ""
  end)
  Proc.relaunch = real
  assert(ok, tostring(trouble))
end

--- `program` starts the core the relaunch names with its arguments and
--- the program's after them, or, with no artifact to relaunch, the
--- program itself; either way without the startup test's handshake.
local function test_program_starts_the_relaunch_or_else_the_executable()
  relaunching({ argv = { "/cache/core-x", "--artifact", "/tree/o/bin/cosmic" }, env = {},
    fds = {} }, function()
      local argv = this_program.program({ "test", "--all" }).argv
      assert(table.concat(argv, " ") == "/cache/core-x --artifact /tree/o/bin/cosmic test --all",
        table.concat(argv, " "))
    end)
  relaunching(nil, function()
    local started = this_program.program({ "-e", "" }, { env = { HOME = "/home",
      COSMIC_PORTABLE_STARTUP_TEST_READY = "r", COSMIC_PORTABLE_STARTUP_TEST_GO = "g" },
      fds = { [3] = 1 } })
    local argv = started.argv
    assert(#argv == 3 and argv[1] == assert(Proc.executable()) and argv[2] == "-e" and
        argv[3] == "", table.concat(argv, " "))
    local env = started.options.env
    assert(env.HOME == "/home" and env.COSMIC_PORTABLE_STARTUP_TEST_READY == nil and
        env.COSMIC_PORTABLE_STARTUP_TEST_GO == nil)
    assert(started.options.fds[3] == 1 and next(started.options.fds, 3) == nil)
  end)
  -- And this very program's: its relaunch where it has one.
  local relaunch = Proc.relaunch()
  local argv = this_program.program({ "x" }).argv
  local lead = relaunch ~= nil and relaunch.argv or { assert(Proc.executable()) }
  assert(#argv == #lead + 1 and argv[#argv] == "x", table.concat(argv, " "))
  for i, word in ipairs(lead) do assert(argv[i] == word, table.concat(argv, " ")) end
end

--- `program` adds the relaunch's variables to the environment the
--- caller gives, in a copy, or to the whole of this process's where it
--- gives none, and takes out the startup test's handshake either way;
--- the relaunch's descriptors go beside the caller's, and one the
--- caller names already raises; every other option is the caller's,
--- and the caller's tables are left as they were.
local function test_program_adds_the_relaunch_to_a_copy_of_the_options()
  local relaunch: Proc.Relaunch = { argv = { "/cache/core-x", "--artifact", "/a" },
    env = { COSMIC_PORTABLE_ARTIFACT = "/a", SHARED = "relaunch" },
    fds = { [254] = 7, [255] = 8 } }
  relaunching(relaunch, function()
    local env: {string:string} = { HOME = "/home", SHARED = "caller",
      COSMIC_PORTABLE_STARTUP_TEST_READY = "r", COSMIC_PORTABLE_STARTUP_TEST_GO = "g" }
    local fds: {integer:integer | string} = { [3] = 1, [4] = "capture" }
    local sandbox: Child.Sandbox = { offline = true }
    -- Every field of [`Child.Options`], so one the copy drops fails.
    local given: Child.Options = { env = env, cwd = "/somewhere", stdin = "stream", input = "bytes",
      stdout = "capture", stderr = "stdout", fds = fds, capture_limit = 9,
      process_group = true, timeout_ns = Clock.ms(5), sandbox = sandbox }
    local opts = this_program.program({}, given).options
    assert(opts.env ~= env and opts.fds ~= fds, "the caller's tables are copied")
    assert(opts.env.HOME == "/home" and opts.env.COSMIC_PORTABLE_ARTIFACT == "/a" and
        opts.env.SHARED == "relaunch")
    assert(opts.env.COSMIC_PORTABLE_STARTUP_TEST_READY == nil and
        opts.env.COSMIC_PORTABLE_STARTUP_TEST_GO == nil)
    assert(opts.fds[3] == 1 and opts.fds[4] == "capture" and opts.fds[254] == 7 and
        opts.fds[255] == 8)
    assert(opts.cwd == "/somewhere" and opts.stdin == "stream" and opts.stdout == "capture" and
        opts.input == "bytes" and opts.stderr == "stdout" and opts.capture_limit == 9 and opts.process_group == true and
        opts.timeout_ns == Clock.ms(5) and opts.sandbox == sandbox)
    assert(given.env == env and given.fds == fds)
    assert(env.SHARED == "caller" and env.COSMIC_PORTABLE_ARTIFACT == nil and
        env.COSMIC_PORTABLE_STARTUP_TEST_READY == "r" and env.COSMIC_PORTABLE_STARTUP_TEST_GO == "g")
    assert(fds[254] == nil and fds[255] == nil)
    -- A descriptor the relaunch hands the core its artifact as, named
    -- by the caller too, raises rather than being dropped.
    local ok, trouble = pcall(this_program.program, {}, { fds = { [254] = "capture" } })
    assert(not ok and tostring(trouble):find("descriptor 254", 1, true), tostring(trouble))
    -- No environment given: this process's whole, which a child given
    -- none would have inherited, with the relaunch's added.
    local whole = this_program.program({ "x" }).options
    local own = Env.all()
    for name, value in pairs(own) do
      if name ~= "COSMIC_PORTABLE_STARTUP_TEST_READY" and name ~= "COSMIC_PORTABLE_STARTUP_TEST_GO" and
          relaunch.env[name] == nil then
        assert(whole.env[name] == value, name)
      end
    end
    for name, value in pairs(relaunch.env) do assert(whole.env[name] == value, name) end
    assert(whole.env.COSMIC_PORTABLE_STARTUP_TEST_READY == nil and
        whole.env.COSMIC_PORTABLE_STARTUP_TEST_GO == nil)
    assert(whole.fds[254] == 7 and whole.fds[255] == 8)
  end)
end

--- This very program, started as `program` says, starts with an empty
--- environment on the core the relaunch names: not the one a launcher
--- given no cache home would find or unpack elsewhere.
local function test_program_starts_this_program_with_no_environment(tmp: string)
  local started = this_program.program({ "-e", [[
local Fs = require("cosmic.fs")
local cmdline = Fs.read("/proc/self/cmdline")
print(cmdline ~= nil and cmdline:match("^[^%z]*") or "")
]] }, { env = {}, cwd = tmp, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, tostring(r.stdout) .. tostring(r.stderr))
  local relaunch = Proc.relaunch()
  if relaunch == nil or not Fs.exists("/proc/self/cmdline") then return end
  assert(r.stdout == relaunch.argv[1] .. "\n", tostring(r.stdout) .. " is no relaunch of " ..
      relaunch.argv[1])
end
