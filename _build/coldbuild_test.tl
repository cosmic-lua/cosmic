--- reads: 3p _build _cli _docs _eval _fuzz _make _perf _tool _types cmd cosmic o/bootstrap/cosmic o/_types/types_gen
--- Guard for the cold-build rule.
---
--- Build generation 1 compiles the WHOLE tree with the pinned release
--- binary — its embedded tl and its patch set — before `--make ci`
--- converges and re-judges everything with the checker the tree just
--- built. A source that needs the tree's OWN checker (a new narrowing
--- rule, a new patch entry) therefore passes `--make ci` locally and
--- fails only a cold build: CI's `build` and `repro` lanes, or a fresh
--- clone. This test runs generation 1's type check directly, so that
--- failure lands on the PR that introduces it.
---
--- The instrument: `--check types --include-dir .` under the pinned
--- bootstrap resolves MODULES from the tree ahead of its embedded
--- copies (probed: a scratch root shadowing cosmic.literal with a new
--- API type-checks under an old release binary) while the CHECKER
--- stays the pinned tl plus the pinned patch set — exactly what
--- generation 1 runs. The 08-23 release binary run this way refuses
--- the tree at the byte-identical site PR #1416's cold build failed
--- on, and today's bootstrap sweeps it clean.
---
--- When this fails: the named file needs a checker or patch newer
--- than the pinned release. Stage that change behind a release and
--- pin bump (land the checker/patch first, bump bin/cosmic.pin to a
--- release carrying it, then land the code that needs it), or rewrite
--- the site to satisfy both checkers.

local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

local BOOTSTRAP = fs.join("o", "bootstrap", "cosmic")
local GENERATED_TYPES = fs.join("o", "_types", "types_gen")

--- The trees generation 1 compiles; mirrors the `--- reads:` line
--- above so the dependency set and the sweep cover the same files.
local TREES < const >: {string} = {
  "3p", "_build", "_cli", "_docs", "_eval", "_fuzz",
  "_make", "_perf", "_tool", "_types", "cmd", "cosmic",
}

--- Every .tl under the swept trees, testdata excluded, sorted for a
--- stable argv.
--- @return {string} The paths
local function tree_sources(): {string}
  local out: {string} = {}
  for _, tree in ipairs(TREES) do
    local found = check.must(fs.find(tree, {glob = "*.tl"}))
    for _, path in ipairs(found) do
      if not path:find("/testdata/", 1, true) then
        out[#out + 1] = path
      end
    end
  end
  table.sort(out)
  return out
end

local function test_tree_type_checks_under_the_pinned_checker()
  -- Loud, never a silent skip: a gate that reports PASS over files it
  -- never read is worse than no gate.
  assert(fs.is_file(BOOTSTRAP), BOOTSTRAP ..
    " is missing; run bin/cosmic once (any verb) to land it")
  assert(fs.is_dir(GENERATED_TYPES), GENERATED_TYPES ..
    " is missing; run a graph verb (e.g. bin/cosmic --make build) first")
  local files = tree_sources()
  assert(#files > 0, "the sweep found no tree sources to guard")

  local argv: {string} = {BOOTSTRAP, "--check", "types",
    "--include-dir", ".", "--include-dir", GENERATED_TYPES}
  for _, f in ipairs(files) do
    argv[#argv + 1] = f
  end
  -- COSMIC_COVERAGE off: the bootstrap child would otherwise dump
  -- .cov files for its own embedded sources into this test's coverage
  -- directory.
  local r = check.must(child.run(argv,
      {env = env.list({set = {COSMIC_COVERAGE = "0"}})}))
  assert(r.ok, "a tree source needs a checker or patch newer than the " ..
    "pinned release, so build generation 1 (and every cold build) " ..
    "fails on it even though the converged `--make ci` is green. " ..
    "Stage the change behind a release + pin bump, or satisfy both " ..
    "checkers:\n" .. r.stderr)
end
test_tree_type_checks_under_the_pinned_checker()
