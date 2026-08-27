--- reads: _perf o/bootstrap/cosmic
--- Guard for the skew a bare load of the tree's _perf runs into.
---
--- A cosmic binary handed a tree .tl path compiles it against the
--- cosmic declarations EMBEDDED in that binary, and answers every
--- require("_perf.*") from its own embedded copies rather than from
--- the tree at cwd. What such a run takes from the tree is the entry
--- script, named by path, plus any module the embed does not carry. So
--- a _perf/** use of a cosmic API a released binary predates fails
--- when that binary loads it, days after the use merges and with
--- nothing on its PR to show for it. release.yml's peers job is a bare
--- load of this shape (`./dl/cosmic-lua _perf/peers/run.tl --bin
--- ./dl/cosmic-lua`), and so is a --modules run that falls through to
--- source because the prebuilt o/<path>.lua is missing.
---
--- This test moves that failure to the PR that introduces it: every
--- non-test _perf/** file must type-check under the pinned bootstrap
--- (`o/bootstrap/cosmic`), which is at least as old as any released
--- binary those loads reach — the pin only ever trails published
--- releases, so bootstrap-clean implies release-clean.
---
--- A failure has two readings, and they call for opposite moves:
---
--- 1. **A cosmic API newer than the pin.** Reach it through a tolerant
---    map view plus a capability probe — the pattern in
---    _perf/bench/literal_bench.tl — or drop the use until the pin
---    catches up.
--- 2. **A _perf signature the pinned binary declares differently.** The
---    binary is checking the call against its OWN embedded copy of the
---    sibling _perf module the tree just changed. No cast is honest
---    here; the signature change lands once a release carries it and
---    the pin names that release.

local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

local BOOTSTRAP = fs.join("o", "bootstrap", "cosmic")

--- Every non-test .tl under _perf, sorted for a stable argv.
--- @return {string} The paths
local function perf_sources(): {string}
  local found = check.must(fs.find("_perf", {glob = "*.tl"}))
  local out: {string} = {}
  for _, path in ipairs(found) do
    if not path:match("_test%.tl$") then
      out[#out + 1] = path
    end
  end
  table.sort(out)
  return out
end

local function test_perf_sources_type_check_under_the_pinned_bootstrap()
  -- Never a silent skip: a missing bootstrap means the sweep checked
  -- nothing, and a gate that reports PASS over files it never read is
  -- worse than no gate.
  assert(fs.is_file(BOOTSTRAP), BOOTSTRAP ..
    " is missing; run bin/cosmic once (any verb) to land it")
  local files = perf_sources()
  assert(#files > 0, "the sweep found no _perf sources to guard")

  local argv: {string} = {BOOTSTRAP, "--check", "types"}
  for _, f in ipairs(files) do
    argv[#argv + 1] = f
  end
  -- COSMIC_COVERAGE off: the bootstrap child would otherwise dump .cov
  -- files for its own embedded sources into this test's coverage
  -- directory.
  local r = check.must(child.run(argv,
      {env = env.list({set = {COSMIC_COVERAGE = "0"}})}))
  assert(r.ok, "a _perf file does not type-check under the pinned " ..
    "bootstrap (" .. BOOTSTRAP .. "), so a bare load of the tree's " ..
    "_perf under a released binary fails the same way. Two readings: a " ..
    "cosmic API newer than the pin takes a tolerant map view + " ..
    "capability probe (see _perf/bench/literal_bench.tl); a _perf " ..
    "signature the pinned binary declares differently means it is " ..
    "checking the call against its own embedded copy of that sibling " ..
    "module, and lands after a release and a pin bump:\n" .. r.stderr)
end
