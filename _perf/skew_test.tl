--- reads: _perf o/bootstrap/cosmic
--- Guard for the release compare step's cosmic-skew class.
---
--- release.yml's compare step measures the previous release binary
--- against the TREE's `_perf` (`_perf/baserun.tl`), so every non-test
--- `_perf/**` file is loaded by an OLD binary: the instrument is the
--- tree's, the `cosmic.*` and `cosmo.*` under it are the previous
--- release's. A `_perf/**` use of a cosmic API newer than that release
--- therefore crashes the release lane days after the use merges:
--- run.tl's version_info read killed the 2026-08-26 run (#1415), and
--- literal_bench's two-argument literal.format would have killed the
--- next (#1420). Making the baseline side run the tree's `_perf`
--- entirely, rather than only its path-given entry, makes this guard
--- MORE load-bearing, not less.
---
--- This test moves that failure to the PR that introduces it: every
--- non-test `_perf/**` file must type-check under the pinned bootstrap
--- (`o/bootstrap/cosmic`), which is at least as old as the previous
--- release — the pin only ever trails published releases, so
--- bootstrap-clean implies previous-release-clean.
---
--- The check runs against a constructed include directory holding
--- NOTHING but a `_perf` symlink, and asserts that emptiness before
--- using it. Caller include dirs come first, so a `_perf`-only
--- directory resolves `_perf.*` declarations from the tree — which is
--- what lets a `_perf` signature change land in one PR — while
--- `cosmic.*` still comes from `/zip/.tl`, the pin's. Handing the
--- repo root itself to the same flag would resolve `cosmic.*` from the
--- tree too and defeat this guard silently, with no failure to read;
--- hence a constructed directory rather than the tree.
---
--- When this fails, read it two ways. A `cosmic` API newer than the
--- pin: reach it through a tolerant map view plus a capability probe
--- (the pattern in `_perf/bench/literal_bench.tl`), or wait for the
--- pin to catch up. Anything else: a genuine type error in a `_perf`
--- file, to fix as one.

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

--- An include directory holding exactly one entry: a `_perf` symlink
--- into the tree. Asserts its own scope, because a directory that
--- resolved anything more would quietly stop guarding cosmic skew.
--- @return string The directory
local function perf_only_include_dir(): string
  local tmp = fs.join(check.must(os.getenv("TEST_TMPDIR")), "skew-include")
  assert(fs.make_dirs(tmp))
  local link = fs.join(tmp, "_perf")
  if not fs.is_link(link) then
    assert(fs.symlink(fs.absolute_path("_perf"), link))
  end
  local found = check.must(fs.find(tmp,
      {max_depth = 1, include_dirs = true, sorted = true}))
  assert(#found == 1 and fs.basename(found[1]) == "_perf",
    "the include dir must scope to _perf alone, or cosmic.* resolves " ..
    "from the tree and this guard passes over real skew; got " ..
    tostring(#found) .. " entries")
  return tmp
end

local function test_perf_sources_type_check_under_the_pinned_bootstrap()
  -- Never a silent skip: a missing bootstrap means the sweep checked
  -- nothing, and a gate that reports PASS over files it never read is
  -- worse than no gate.
  assert(fs.is_file(BOOTSTRAP), BOOTSTRAP ..
    " is missing; run bin/cosmic once (any verb) to land it")
  local files = perf_sources()
  assert(#files > 0, "the sweep found no _perf sources to guard")

  local argv: {string} = {BOOTSTRAP, "--check", "types",
    "--include-dir", perf_only_include_dir()}
  for _, f in ipairs(files) do
    argv[#argv + 1] = f
  end
  -- COSMIC_COVERAGE off: the bootstrap child would otherwise dump .cov
  -- files for its own embedded sources into this test's coverage
  -- directory.
  local r = check.must(child.run(argv,
      {env = env.list({set = {COSMIC_COVERAGE = "0"}})}))
  assert(r.ok, "a _perf file fails to type-check under the pinned " ..
    "bootstrap (" .. BOOTSTRAP .. "), so the release compare step " ..
    "would crash loading it under the previous release. If it reaches " ..
    "a cosmic API newer than the pin, use a tolerant map view + " ..
    "capability probe (see _perf/bench/literal_bench.tl) or wait for " ..
    "the pin; otherwise it is an ordinary type error:\n" .. r.stderr)
end
test_perf_sources_type_check_under_the_pinned_bootstrap()
