--- reads: 3p _build _cli _docs _eval _fuzz _make _perf _tool _types cmd cosmic o/bootstrap/cosmic o/_types/types_gen
--- Guard for the cold-build rule.
---
--- Build generation 1 compiles the WHOLE tree with the pinned release
--- binary — its embedded tl and its patch set — before `--make ci`
--- converges and re-judges everything with the checker the tree just
--- built. A source that needs the tree's OWN checker (a new narrowing
--- rule, a new patch entry) therefore passes `--make ci` locally and
--- fails only a cold build: CI's `build` and `repro` lanes, or a fresh
--- clone. This test uses that pinned checker with a deliberately
--- conservative sibling-resolution order, so the guard runs on the PR.
---
--- The instrument: the pinned release embeds the exact tree it was cut
--- from at `/zip/.tl/**`. Putting `--include-dir /zip/.tl` FIRST makes
--- every checked module see the pin's shipped siblings before the tree;
--- `.` then admits modules absent from the snapshot, and generated
--- cosmo types come last. This is a pessimistic superset, not the exact
--- resolution order of every module in a real cold build.
---
--- The real snapshot exposure (Path B) is the top-level `--make`
--- bootstrap chain's bare requires before compilation, such as
--- `_cli.lint` and `_cli.main_handlers`. Spawned generator children
--- instead receive `--modules` from `_make.closure`/`_make.generate`:
--- the built closure and tree-first searcher precede the pin's payload.
--- A ModuleDoc field used only there can therefore pass a real cold
--- build while this intentionally conservative sweep refuses it.
--- The warm-tree reproduction is recorded in
--- `docs/design/make/log/coldbuild-staleness.md`.
---
--- A second shape lives here too, not only a checker rule: a call
--- between two modules the pinned release ALREADY SHIPS, widened by
--- an extra parameter on the caller's side. The tree's own two copies
--- agree with each other, so `--check types --include-dir .` alone
--- passes; the pinned release's SNAPSHOT of the callee still has the
--- old arity, so a bootstrap-chain load does not (PR #1775). The second test
--- case below reproduces it on a throwaway fixture instead of waiting
--- for a real one to land.
---
--- When this fails: the named file needs a newer checker/patch or
--- disagrees with a shipped sibling's snapshot. The latter is not by
--- itself proof that a real cold build fails: its load path matters.
--- To satisfy this conservative guard, stage behind a release and pin bump
--- (land the checker/patch/signature first, bump bin/cosmic.pin to a
--- release carrying it, then land the code that needs it), carry a
--- widened value in a new module instead, or rewrite the site to
--- satisfy both checkers.

local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

local BOOTSTRAP = fs.join("o", "bootstrap", "cosmic")
local GENERATED_TYPES = fs.join("o", "_types", "types_gen")
local SHIPPED_TREE = fs.join("/zip", ".tl")

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

--- Runs the conservative generation-1 check over `files`: the pinned
--- release's shipped snapshot of the tree first, then `tree_dir` — the
--- resolution root for the tree's own modules, "." for the real repo
--- or a fixture directory standing in for it — then the generated
--- cosmo types.
--- @param tree_dir string Include-dir standing in for the tree
--- @param files {string} The .tl files to check
--- @return child.Result The finished check's result (ok, stdout, stderr)
local function check_generation_1(tree_dir: string, files: {string}): child.Result
  local argv: {string} = {BOOTSTRAP, "--check", "types",
    "--include-dir", SHIPPED_TREE, "--include-dir", tree_dir,
    "--include-dir", GENERATED_TYPES}
  for _, f in ipairs(files) do
    argv[#argv + 1] = f
  end
  -- COSMIC_COVERAGE off: the bootstrap child would otherwise dump
  -- .cov files for its own embedded sources into this test's coverage
  -- directory.
  return check.must(child.run(argv,
      {env = env.list({set = {COSMIC_COVERAGE = "0"}})}))
end

--- The staging-rule sentence for a widened-call failure, with N and M
--- read straight out of the checker's own "given N, expects M" text so
--- the guidance always matches whatever call actually widened.
--- @param stderr string The checker's stderr
--- @return string The sentence, or "" when stderr names no such mismatch
local function widened_call_message(stderr: string): string
  local given, expects = stderr:match("given (%d+), expects (%d+)")
  if not given then
    return ""
  end
  return "a caller calls a callee with " .. given .. " args; the " ..
  "pinned release's callee takes " .. expects .. " — a signature " ..
  "change on a shipped module stages behind a release and pin bump, " ..
  "or moves into a new module.\n"
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

  local r = check_generation_1(".", files)
  assert(r.ok, widened_call_message(r.stderr) ..
    "the pinned-checker/shipped-snapshot guard rejects a tree source. " ..
    "This conservative sibling ordering also checks modules outside " ..
    "the real bootstrap-chain exposure; a snapshot mismatch alone " ..
    "does not prove every cold build fails. Stage the change " ..
    "behind a release + pin bump, or satisfy both checkers:\n" .. r.stderr)
end

--- Writes a fixture under `dir`: `_cli.lint`'s `lint_file` widened by
--- one optional parameter (declaration and interface field both, the
--- only two sites naming its old signature), with a caller passing
--- it — the exact #1775 shape, reproduced on a throwaway copy rather
--- than waiting for a real one to land.
--- @param dir string Scratch directory to write the fixture under
local function write_widened_call_fixture(dir: string)
  local lint_src = check.must(fs.read(fs.join("_cli", "lint.tl")))
  local widened, sites = lint_src:gsub(
    "%(path: string%): {Diagnostic} | nil, string",
    "(path: string, max_lines?: integer): {Diagnostic} | nil, string")
  assert(sites == 2, "_cli/lint.tl's lint_file signature text moved; " ..
    "expected 2 sites to widen (the declaration and the interface " ..
    "field), found " .. sites)

  check.must(fs.make_dir(fs.join(dir, "_cli")))
  check.must(fs.write(fs.join(dir, "_cli", "lint.tl"), widened))
  check.must(fs.write(fs.join(dir, "caller.tl"),
      "local lint = require(\"_cli.lint\")\n" ..
      "local _diags, _err = lint.lint_file(\"x.tl\", 10)\n"))
end

local function test_widened_call_between_shipped_modules_is_refused()
  local tmpdir = env.get_or("TEST_TMPDIR", "/tmp")
  write_widened_call_fixture(tmpdir)

  local r = check_generation_1(tmpdir, {fs.join(tmpdir, "caller.tl")})
  local message = widened_call_message(r.stderr)
  assert(not r.ok and message ~= "",
    "a call widened by an extra optional parameter on the caller's " ..
    "side only must fail generation 1's type check the same way " ..
    "#1775 did — the pinned release's shipped snapshot of the callee " ..
    "still has the old arity even though the fixture's own two copies " ..
    "agree. Instead: ok=" .. tostring(r.ok) ..
    "\nstdout: " .. r.stdout .. "\nstderr: " .. r.stderr)
end
