--- End to end: a sandboxed run and an unsandboxed one of the same suite
--- key their verdicts apart (build/declared_key.tl). The runs that are
--- unsandboxed alone are in `declared_unenforced_test.tl`, which every host
--- runs; this case starts a sandboxed run, whose workers nest in this
--- test's own sandbox, so it declares `nests` and is not applicable where
--- the host gives no nest (`requires`).

local confine = require("build.confine")
local fixture = require("build.declared_unenforced_fixture")
local Test = require("cosmic.test")

--- What a run of `cosmic test` needs of the host, the program it runs, and
--- `nests`, which lets it start a sandboxed run.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
  requires = { "nest" },
}

local checkout, environment, says = fixture.checkout, fixture.environment, fixture.says

--- Neither a sandboxed verdict nor an unenforced one stands for the
--- other, whichever came first: each keys under a runtime of its own.
--- The two runs differ in COSMIC_TEST_SANDBOX, which every key holds
--- pinned, and a sandboxed runtime carries " sandboxed". The runtime's
--- " declared" tag (build/test.tl) names the mode in the key itself, so
--- the two would stay apart even if neither of those told them apart,
--- as in an auto-mode run on a host that can sandbox a worker one day
--- and not the next. This case does not turn on that tag: no test can
--- reach a runtime except through the keys these runs print.
---
--- Where this host cannot sandbox a worker of the run it starts, there
--- is nothing to check, and the case is skipped: a run nested in this
--- test's own sandbox, which the kernel refuses root, or a host refusing
--- user namespaces (told by the run's summary). Off Linux, which has no
--- sandbox, the module is not applicable (`requires`).
local function test_a_sandboxed_and_an_unenforced_verdict_stand_apart(tmp: string)
  local function environments(cache: string): {string:string}, {string:string}
    local unenforced = environment(cache)
    local sandboxed: {string:string} = {}
    for name, value in pairs(unenforced) do sandboxed[name] = value end
    sandboxed.COSMIC_TEST_SANDBOX = nil
    sandboxed.UNDECLARED = nil
    sandboxed.OUTER_TMPDIR = nil
    return sandboxed, unenforced
  end
  local sandboxed, unenforced = environments(tmp .. "/cache/verdicts.db")
  checkout(tmp .. "/first")
  local ran = fixture.run(tmp .. "/first", tmp .. "/first.out", sandboxed)
  local code, first = ran.code, ran.text
  assert(code == 0, first)
  if not first:find("; sandboxed", 1, true) then
    Test.skip(confine.unsandboxed_reason(first))
    return
  end
  assert(first:find("2 ran, 0 stood", 1, true), first)
  says(tmp .. "/first", tmp .. "/first-unenforced.out", unenforced, "2 ran, 0 stood")
  sandboxed, unenforced = environments(tmp .. "/other-cache/verdicts.db")
  checkout(tmp .. "/second")
  says(tmp .. "/second", tmp .. "/second-unenforced.out", unenforced, "2 ran, 0 stood")
  local second = says(tmp .. "/second", tmp .. "/second.out", sandboxed, "2 ran, 0 stood")
  assert(second:find("; sandboxed", 1, true), second)
end
