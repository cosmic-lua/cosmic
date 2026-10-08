--- How a test starts this very program: its command line and options
--- (`program`), and the environment it needs to run (`environment`).

local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local type Child = require("cosmic.child")

local record this_program
  --- The variables `environment` passes on: those a process of this
  --- very program reads to run at all (caches, temporary directory, PATH,
  --- whether it may boot) and those that decide whether a `cosmic test`
  --- it runs sandboxes its workers.
  runtime_environment: {string}

  --- How to start this very program (`program`): the command line and
  --- the options to hand [`Child.run`] or [`Child.start`].
  record Program
    argv: {string}
    options: Child.Options
  end
end

this_program.runtime_environment = {
  "HOME", "XDG_CACHE_HOME", "PATH", "TMPDIR", "COSMIC_PORTABLE_CACHE", "COSMIC_VERDICT_CACHE",
  "COSMIC_BUILD_CACHE", "COSMIC_BUILD_HOME", "COSMIC_AUTO_BOOT", "COSMIC_TEST_SANDBOX", confine.held_variable,
}

--- The environment to start a process of this very program with, for a
--- test that would otherwise pass all of its own: each of
--- `runtime_environment` this process has, read by name, so the test
--- reads no more of the environment than these. TMPDIR is the exception
--- while a test runs: it names the test's own directory (build.confine's
--- `test_directory`), so what the process leaves there goes with the
--- test, not into the host's temporary directory. The core hands a child
--- the directory its coverage goes to whatever environment it is given.
function this_program.environment(): {string:string}
  local out: {string:string} = {}
  local own = confine.test_directory()
  for _, name in ipairs(this_program.runtime_environment) do
    if name == "TMPDIR" and own ~= nil then
      out[name] = own
    else
      out[name] = sys.getenv(name)
    end
  end
  return out
end

--- The variables of this process's own start that no process it starts
--- may inherit: the portable startup test's handshake
--- (core/startup_test.tl's launches), which a child would wait on for
--- a signal no one sends it.
local handshake: {string} = {
  "COSMIC_PORTABLE_STARTUP_TEST_READY", "COSMIC_PORTABLE_STARTUP_TEST_GO",
}

--- How to start this very program with `args` after it, skipping its
--- launcher as `cosmic test` starts a worker: the core it runs on,
--- handed its artifact, database and startup contract directly
--- ([`Proc.relaunch`]), so starting it takes no shell and lands on no
--- other core. With no artifact to relaunch, the program is as
--- [`Proc.executable`] names it.
---
--- The options are a copy of `opts`, its tables left as they were except
--- `env` and `fds`. `env` is the caller's variables or, where it gives
--- none, the whole of this process's (a child given none inherits them,
--- and nothing can be added to an inherited environment), with the
--- relaunch's added and the startup test's handshake removed. `fds` is
--- the caller's with the relaunch's descriptors beside them; `opts.fds`
--- naming a number the relaunch hands the child its artifact or core as
--- raises.
---
--- Under `opts.policy` the command line is the one a policy start
--- takes: [`Child.start`] relaunches the program itself, so `argv` is
--- [`Proc.executable`] and `args`, `env` is left unset (the policy's own
--- `env` and `set_env` are the child's whole environment, so `opts.env`
--- beside a policy raises), and `fds` is the caller's alone.
---
--- What the launcher does, a program started this way never sees: it
--- makes no core cache under XDG_CACHE_HOME or HOME, nor checks the one
--- COSMIC_PORTABLE_CACHE names, stamps no core `.verified-`, and needs
--- no PATH, HOME or TMPDIR to start. A test of any of that starts the
--- program itself, by [`Proc.executable`].
-- TODO: move this to [`cosmic.test`], with `environment` (the TODO atop
-- cosmic/test.tl), so another project's tests start their program this
-- way: today it lives in build/, which they cannot reach.
function this_program.program(args: {string}, opts?: Child.Options): this_program.Program
  local given: Child.Options = opts or {}
  if given.policy ~= nil and given.env ~= nil then
    error("this_program.program: env beside a policy: the policy's env and set_env are the " ..
        "child's whole environment", 2)
  end
  local relaunch: Proc.Relaunch
  if given.policy == nil then
    local found, _ = Proc.relaunch()
    relaunch = found
  end
  local argv: {string} = {}
  if relaunch ~= nil then
    for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
  else
    argv[1] = assert(Proc.executable())
  end
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local env: {string:string} | nil
  if given.policy == nil then
    env = {}
    for name, value in pairs(given.env or Env.all()) do env[name] = value end
  end
  local fds: {integer:integer | string} = {}
  for number, fd in pairs(given.fds or {}) do fds[number] = fd end
  if relaunch ~= nil and env ~= nil then
    for name, value in pairs(relaunch.env) do env[name] = value end
    for number, fd in pairs(relaunch.fds) do
      if fds[number] ~= nil then
        error("this_program.program: descriptor " .. tostring(number) ..
            " is the one the relaunch hands the program its artifact or core as", 2)
      end
      fds[number] = fd
    end
  end
  if env ~= nil then
    for _, name in ipairs(handshake) do env[name] = nil end
  end
  -- Field by field: a record has no copy that keeps its type. A field
  -- [`Child.Options`] gains is copied here too.
  return { argv = argv, options = {
    env = env, fds = fds, cwd = given.cwd, stdin = given.stdin, input = given.input,
    stdout = given.stdout, stderr = given.stderr, capture_limit = given.capture_limit,
    process_group = given.process_group, timeout_ns = given.timeout_ns, sandbox = given.sandbox,
    credentials = given.credentials, policy = given.policy, relay_log = given.relay_log,
  } }
end

return this_program
