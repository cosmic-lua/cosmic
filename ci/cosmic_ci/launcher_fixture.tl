local Time = require("cosmic.time")
--- What launcher_test.tl and launcher_noexec_test.tl share: the
--- launcher contract's artifact, copied where a case may run it, and
--- how a case runs it.
local Fixture = require("cosmic_ci.fixture")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local child_timeout_ns <const> = Time.seconds(30)

local record LauncherFixture
  record Context
    artifact: string
    socket: string
    target: string
    work: string
    diagnostics: string
  end
end

local type Context = LauncherFixture.Context

local private_environment = {
  "COSMIC_PORTABLE_ARTIFACT_FD", "COSMIC_PORTABLE_CORE_FD",
  "COSMIC_PORTABLE_TARGET_ID", "COSMIC_PORTABLE_CONFIGURATION_ID",
  "COSMIC_PORTABLE_CORE_OFFSET", "COSMIC_PORTABLE_CORE_LENGTH",
  "COSMIC_PORTABLE_CORE_SHA256", "COSMIC_PORTABLE_TEST_HOOK",
  "COSMIC_PORTABLE_TEST_READY", "COSMIC_PORTABLE_TEST_GO",
  "PORTABLE_PAYLOAD_MARKER", "PORTABLE_PAYLOAD_EXIT",
  "PORTABLE_PAYLOAD_SIGNAL", "PORTABLE_EXPECT_CWD",
  "PORTABLE_EXPECT_UMASK", "PORTABLE_CHECK_IO",
}

--- The environment the launcher runs in: the fixture's own, none of the
--- launcher's private contract, the cache `cache`, and `extra` over it.
function LauncherFixture.environment(cache?: string,
    extra?: {string:string}): {string:string}
  local values = Fixture.environment({
    PORTABLE_ORDINARY_ENV = "preserved",
    PORTABLE_CALLER_LOCALE = "preserved",
  })
  for _, name in ipairs(private_environment) do values[name] = nil end
  values.COSMIC_PORTABLE_CACHE = cache
  if extra then for name, value in pairs(extra) do values[name] = value end end
  return values
end

--- A case's context beneath `tmp`: the contract's launcher
--- (COSMIC_FIXTURE_LAUNCHER, cosmic_ci/launcher_setup.tl) copied into a
--- directory whose name holds a space, a run directory and a link to it,
--- and the target's socket payload, where the contract has it.
function LauncherFixture.setup(tmp: string): Context
  local work = tmp .. "/launcher"
  local program = work .. "/program space"
  local run = work .. "/run space"
  local alias = work .. "/run alias"
  local diagnostics = work .. "/logs"
  Fixture.mkdir(program); Fixture.mkdir(run); Fixture.mkdir(diagnostics)
  assert(Fs.symlink(run, alias))
  local artifact = program .. "/launcher.test"
  local contract = Fixture.required("COSMIC_FIXTURE_LAUNCHER")
  local target = Fixture.required("COSMIC_FIXTURE_TARGET")
  Fixture.copy(contract .. "/launcher.test", artifact, 0x1ed)
  return { artifact = artifact,
    socket = contract .. "/payloads/socket-" .. target,
    target = target, work = work, diagnostics = diagnostics }
end

function LauncherFixture.outcome_ok(outcome: Fixture.Outcome, label: string)
  assert(outcome.result.ok, label .. " failed; stdout=" .. outcome.out ..
    "; stderr=" .. outcome.err)
end

--- Runs the launcher (or `program`) from the case's directory.
function LauncherFixture.run(ctx: Context, label: string, cache?: string,
    extra?: {string:string}, program?: string): Fixture.Outcome
  return Fixture.call_with_environment(label, { program or ctx.artifact }, ctx.work,
    ctx.diagnostics, LauncherFixture.environment(cache, extra), child_timeout_ns)
end

--- The one public core a cache holds: a plain file whose name does not
--- begin with ".", the launcher's or startup's own.
function LauncherFixture.only_core(cache: string): string
  local found: string | nil = nil
  for _, name in ipairs((assert(Fs.list(cache)))) do
    local path = cache .. "/" .. name
    local st = assert(sys.lstat(path))
    if name:sub(1, 1) ~= "." and st.kind == "file" then
      assert(found == nil, "cache contains multiple public cores")
      found = path
    end
  end
  return (assert(found, "cache contains no public core"))
end

return LauncherFixture
