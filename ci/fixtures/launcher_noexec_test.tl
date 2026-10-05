local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Fixture = require("cosmic_ci.fixture")
local LauncherFixture = require("cosmic_ci.launcher_fixture")
local String = require("cosmic.string")

local Test = require("cosmic.test")

-- The same launcher contract as launcher_test.tl, with private noexec
-- scratch supplied only after the worker's execution-refusal probe.
Test.policy{
  grants = {
    { path = "o/fixtures/product/prefix", letters = "r" },
    { path = "o/fixtures/launcher/launcher.test", letters = "r" },
    { path = "o/fixtures/launcher/payloads/socket-x86_64-linux-musl", letters = "r" },
    { path = "o/fixtures/launcher/payloads/socket-aarch64-linux-musl", letters = "r" },
    { path = "o/fixtures/launcher/payloads/socket-aarch64-macos", letters = "r" },
    { path = "/noexec", letters = "rwc" },
  },
  env = { "COSMIC_FIXTURE_TARGET" },
  profiles = { "system" },
}

local setup, run = LauncherFixture.setup, LauncherFixture.run
local outcome_ok, only_core = LauncherFixture.outcome_ok, LauncherFixture.only_core

local function test_launcher_noexec(tmp: string)
  local ctx = setup(tmp)
  local before = Fixture.hash(ctx.artifact)
  local base = ctx.work .. "/base"
  outcome_ok(run(ctx, "base", base), "base")
  local key = only_core(base):match("([^/]+)$") as string
  assert(ctx.target ~= "aarch64-macos", "noexec fixture requires the Linux grant")
  local parent = assert(Env.get("COSMIC_TEST_NOEXEC"), "no private noexec grant")
  local noexec = assert(sys.mkdtemp(parent .. "/cosmic-launcher.XXXXXX"))
  local called, failure = pcall(function(): boolean
    local cache = noexec .. "/cache"
    local answer = run(ctx, "noexec-launch", cache)
    assert(answer.result.code == 126 and not answer.result.timed_out and
        assert(Fs.stat(cache .. "/" .. key)).kind == "file",
      "noexec launch did not stop at 126 with the core intact")
    -- Shells differ in whether test -x notices the mount restriction;
    -- either the launcher or its failed exec diagnoses the refusal.
    local diagnostic = Fixture.small(answer.err, 4096)
    local refused =
      "\ncosmic portable: verified core was refused execution; " ..
      "Permission denied here usually means a noexec cache filesystem\n"
    assert(diagnostic ==
        "cosmic portable: verified core cannot execute on the cache filesystem\n" or
        String.ends_with(diagnostic, refused), diagnostic)
    return true
  end)
  local removed, remove_trouble = Fs.remove_tree(noexec)
  if not called then error(failure) end
  assert(removed, "noexec cleanup: " .. tostring(remove_trouble))
  assert(Fixture.hash(ctx.artifact) == before, "launcher artifact changed")
end
