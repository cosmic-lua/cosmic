local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local sys = require("cosmic.sys")
local Fixture = require("cosmic_ci.fixture")
local LauncherFixture = require("cosmic_ci.launcher_fixture")
local Runner = require("cosmic_ci.runner")
local String = require("cosmic.string")

local Test = require("cosmic.test")

--- Run unsandboxed and sharing nothing (cosmic_ci/orchestration.tl's
--- `fixture`), its workers are given the environment they declare:
--- all of it, which says where the candidate and its products are
--- (COSMIC_FIXTURE_*) and where the host's toolchain is. A release that
--- keys every unsandboxed run by declaration gives a worker only that.
Test.needs{ env = { "*" } }

-- The launcher on a cache filesystem that refuses to run what it holds:
-- the host's own noexec mount (/dev/shm, or COSMIC_PORTABLE_NOEXEC_ROOT),
-- which a sandboxed worker is given none of, so this case runs apart from
-- launcher_test.tl's, unsandboxed and sharing nothing
-- (cosmic_ci/orchestration.tl's `phase_fixtures`).
-- TODO: run this case sandboxed with launcher_test.tl's once
-- ci/cosmic-driver.pin names a release whose [`Test.needs`] can give a
-- sandboxed worker a noexec directory of its own to write (a field for
-- one, mounted noexec in its root by build/test_sandbox.tl), which no
-- release, nor main, has yet: today its scratch directory is the only
-- one it writes, and that one runs what it holds.

local setup, run = LauncherFixture.setup, LauncherFixture.run
local outcome_ok, only_core = LauncherFixture.outcome_ok, LauncherFixture.only_core

local function test_launcher_noexec(tmp: string)
  local ctx = setup(tmp); local before = Fixture.hash(ctx.artifact)
  local base = ctx.work .. "/base"; outcome_ok(run(ctx, "base", base), "base")
  local key = only_core(base):match("([^/]+)$") as string
  if ctx.target ~= "aarch64-macos" then
    local parent = Env.get_or("COSMIC_PORTABLE_NOEXEC_ROOT", "/dev/shm")
    local parent_is_dir = Predicate.is_dir(parent)
    if parent_is_dir then
      local noexec = sys.mkdtemp(parent .. "/cosmic-launcher.XXXXXX")
      if noexec then
        local called, failure = pcall(function(): boolean
          local probe = noexec .. "/probe"
          Fixture.write(probe, "#!/bin/sh\nexit 0\n", 0x1c0)
          -- A noexec mount refuses the exec itself, so the probe may not
          -- even start; that is the answer, not a fixture error.
          local probe_run = Runner.execute({ argv = { probe }, cwd = ctx.work })
          if not probe_run.result or not probe_run.result.ok then
            local cache = noexec .. "/cache"
            local answer = run(ctx, "noexec-launch", cache)
            assert(answer.result.code == 126 and
              assert(Fs.stat(cache .. "/" .. key)).kind == "file",
              "noexec launch did not stop at 126 with the core intact")
            -- `[ -x ]` reflects noexec only where test(1) asks the kernel;
            -- BusyBox answers from the mode bits, so there the exec itself
            -- fails, the shell names the errno, and the launcher's EXIT
            -- trap ends the output. Either way the launcher stops at 126
            -- with the verified core left intact.
            local diagnostic = Fixture.small(answer.err, 4096)
            local refused =
              "\ncosmic portable: verified core was refused execution; " ..
              "Permission denied here usually means a noexec cache filesystem\n"
            assert(diagnostic ==
              "cosmic portable: verified core cannot execute on the cache filesystem\n" or
              String.ends_with(diagnostic, refused), diagnostic)
          end
          return true
        end)
        local removed, remove_trouble = Fs.remove_tree(noexec)
        assert(removed, "noexec cleanup: " .. tostring(remove_trouble))
        if not called then error(failure) end
      end
    end
  end
  assert(Fixture.hash(ctx.artifact) == before, "launcher artifact changed")
end
