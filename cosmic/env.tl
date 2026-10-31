--- The process's environment.

local sys = require("cosmic.sys")

local record Env
  --- The variables the tree itself reads, which [`Env.read`] takes by
  --- name so that a misspelt one is a checker error.
  enum Name
    --- "0" refuses a stale tool where it would boot.
    "COSMIC_AUTO_BOOT"
    --- "0" turns the build's caches off.
    "COSMIC_BUILD_CACHE"
    --- Moves the build directory.
    "COSMIC_BUILD_HOME"
    --- The grammar the tool reads: "new" or nothing.
    "COSMIC_GRAMMAR"
    --- Set to anything, writes a line of memory use at each mark of a run.
    "COSMIC_MEMPROBE"
    --- The tree root, outright.
    "COSMIC_TREE"
    --- The count of boots.
    "COSMIC_WEB_BOOT"
    --- "1" is development mode.
    "COSMIC_WEB_DEV"
    --- The roots clients trust by default.
    "COSMIC_CA_ROOTS"
    --- The lock's path, handed to a child that would take it.
    "COSMIC_REBUILD_LOCK_HANDED"
    --- "must" fails a test that cannot be confined.
    "COSMIC_SANDBOX"
    --- "1" runs every test.
    "COSMIC_TEST_ALL"
    --- "1" starts no test after the first failure.
    "COSMIC_TEST_BAIL"
    --- "1" shows where the checker's conclusion from a test is false.
    "COSMIC_TEST_CHECK_TYPES"
    --- For a test of the runner alone: stands in for the compiler's identity.
    "COSMIC_TEST_COMPILER_SALT"
    --- "1" accepts verdicts from a host with other features.
    "COSMIC_TEST_FOREIGN_FEATURES"
    --- For a test of the runner alone: stands in for the harness epoch.
    "COSMIC_TEST_HARNESS_EPOCH"
    --- The module a held run was handed.
    "COSMIC_TEST_HELD"
    --- The CI leg's name.
    "COSMIC_TEST_LEG"
    --- "1" stands on no shared verdict.
    "COSMIC_TEST_NO_SHARED"
    --- For a test of the runner alone: "other" stands in for another platform.
    "COSMIC_TEST_PLATFORM"
    --- The requirements the CI leg promises.
    "COSMIC_TEST_PROMISES"
    --- "0" runs workers unsandboxed, "1" requires a sandbox.
    "COSMIC_TEST_SANDBOX"
    --- For a test of the runner alone: the core the store is keyed to.
    "COSMIC_TEST_STORE_RUNTIME"
    --- For a test of the runner alone: salts the store key.
    "COSMIC_TEST_STORE_SALT"
    --- The seconds a test may run.
    "COSMIC_TEST_TIMEOUT"
    --- The shared verdict cache.
    "COSMIC_VERDICT_CACHE"
    --- `<property>:<case>`, the one input to check.
    "FUZZ_CASE"
    --- "1" makes an unheld sandbox a failure.
    "COSMIC_CI_REQUIRE_SANDBOX"
    --- The commit a perf run compares against.
    "COSMIC_PERF_BASELINE_COMMIT"
    --- The commit a perf run measures.
    "COSMIC_PERF_CANDIDATE_COMMIT"
    --- The user's home directory.
    "HOME"
    --- Where programs are found.
    "PATH"
    --- Where temporary files go.
    "TMPDIR"
    --- The time zone.
    "TZ"
  end
end

-- TODO: type the table of [`Env.all`] by [`Env.Name`] once a child's environment is built from declared
-- names; its keys are any variable a child is handed, so its literal key reads stay strings.

--- One variable, or nil when it is not set; this is the os.getenv
--- operation, C's `getenv`. Any name is read: a program of its own
--- reads its own variables here, and the tree reads its own through
--- [`Env.read`].
function Env.get(name: string): string?
  return sys.getenv(name)
end

--- One variable the tree reads, or nil when it is not set. A name not
--- in [`Env.Name`] is a checker error.
function Env.read(name: Env.Name): string?
  return sys.getenv(name)
end

--- One variable, or the fallback when it is not set.
function Env.get_or(name: string, fallback: string): string
  local value = sys.getenv(name)
  if value == nil then
    return fallback
  end
  return value
end

--- Every variable the process has, in a table of the caller's own: it may be changed (a child's environment is built that
--- way) without changing the process's.
function Env.all(): mut {string:string}
  local copy: mut {string:string} = {}
  for name, value in pairs(sys.environ()) do
    copy[name] = value
  end
  return copy
end

return Env
