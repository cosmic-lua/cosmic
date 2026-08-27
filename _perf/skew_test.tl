--- reads: _perf o/bootstrap/cosmic
--- Guard for the release compare step's bare-load skew class.
---
--- release.yml's compare step runs the tree's _perf harness and bench
--- modules BARE under the previous release binary
--- (`o/perf/prev/cosmic-lua _perf/run.tl`), so that binary's EMBEDDED
--- cosmic declarations type-check every file the load reaches, while
--- `_perf.*` resolves from the tree at cwd. A _perf/** use of a cosmic
--- API newer than that release therefore crashes the release lane days
--- after the use merges: run.tl's version_info read killed the
--- 2026-08-26 run (#1415), and literal_bench's two-argument
--- literal.format would have killed the next (#1420).
---
--- This test moves that failure to the PR that introduces it: every
--- non-test _perf/** file must type-check under the pinned bootstrap
--- (`o/bootstrap/cosmic`), which is at least as old as the previous
--- release — the pin only ever trails published releases, so
--- bootstrap-clean implies previous-release-clean.
---
--- When this fails: the named file reaches an API the pinned release
--- does not declare. Reach it through a tolerant map view plus a
--- capability probe instead — the pattern in
--- _perf/bench/literal_bench.tl — or drop the use until the pin
--- catches up.

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
  assert(r.ok, "a _perf file reaches an API the pinned bootstrap (" ..
    BOOTSTRAP .. ") does not declare, so the release compare step " ..
    "would crash loading it bare under the previous release. Reach " ..
    "the new API through a tolerant map view + capability probe " ..
    "(see _perf/bench/literal_bench.tl):\n" .. r.stderr)
end
test_perf_sources_type_check_under_the_pinned_bootstrap()
