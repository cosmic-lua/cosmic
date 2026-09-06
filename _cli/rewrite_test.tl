#!/usr/bin/env cosmic
-- Tests for `cosmic --rewrite`, spawned against fixture trees with cwd
-- inside the fixture -- the same shape `_cli/find_test.tl` uses, since
-- `--rewrite`'s own search mode delegates straight to `_cli.find`.

local check = require("cosmic.check")
local child = require("cosmic.child")
local rewrite_mod = require("_cli.rewrite")
local fs = require("cosmic.fs")

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local record Run
  code: integer
  out: string
  err: string
end

--- Same shape as `_cli/find_test.tl`'s own fixture helper (its doc
--- comment has the details), under a `rewrite-` root of its own so the
--- two tests never collide.
--- @param name string A name unique to this test, for the fixture's own directory
--- @param files {string: string} Relative path -> file contents
--- @return string The fixture's absolute root
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "rewrite-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for rel, content in pairs(files) do
    assert(fs.write(fs.join(root, rel), content))
  end
  return root
end

--- Run `cosmic <flag> ...` with cwd inside `dir`.
--- @param dir string The fixture root
--- @param flag string "--rewrite" or "--find"
--- @param ... string The flag's own arguments (pattern, then the rest)
--- @return Run The exit code and captured output
local function run_cli(dir: string, flag: string, ...: string): Run
  local argv: {string} = {cosmic, flag}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local h = check.must(child.start(argv, {cwd = dir}))
  local r = check.must(h:wait())
  return {code = r.code or 128, out = r.stdout or "", err = r.stderr or ""}
end

--- Run `cosmic --rewrite ...` with cwd inside `dir`.
--- @param dir string The fixture root
--- @param ... string The flag's own arguments (pattern, then the rest)
--- @return Run The exit code and captured output
local function rewrite(dir: string, ...: string): Run
  return run_cli(dir, "--rewrite", ...)
end

--- Two files, one hit each: `a.tl`'s applies cleanly; `b.tl`'s comment
--- sits between the captured argument and the call's closing paren --
--- outside the capture's own kept span -- so splicing it would drop
--- the comment, and `cosmic.ast.rewrite` refuses that hit instead.
--- Both files are pre-formatted (`cosmic --format`'s own output), so an
--- untouched file's bytes are unchanged, not just its matched span.
--- @return string The fixture's absolute root
local function two_hit_tree(): string
  return fixture("fix", {
      ["a.tl"] = "local function f()\n  os.execute(cmd)\nend\n",
      ["b.tl"] = "local function g()\n  os.execute(cmd --[[ note ]] )\nend\n",
    })
end

local function test_fix_applies_one_hit_and_refuses_the_commented_one()
  local root = two_hit_tree()
  local before_b = check.must(fs.read(fs.join(root, "b.tl")))
  local r = rewrite(root, "os.execute($CMD)", "assert(os.execute($CMD))",
    "--fix", "a.tl", "b.tl")
  assert(r.code == 1, "expected exit 1 (a refusal), got " .. tostring(r.code)
    .. ": " .. r.err)
  assert(r.out:find("rewrite: 1 applied, 1 refused in 2 file(s)", 1, true),
    "expected the verdict line: " .. r.out)
  assert(r.err:find("b.tl:2:3:", 1, true),
    "expected the refusal at b.tl's own position: " .. r.err)
  assert(r.err:find("comment", 1, true),
    "expected the refusal to name the comment loss: " .. r.err)

  local after_a = check.must(fs.read(fs.join(root, "a.tl")))
  assert(after_a:find("assert(os.execute(cmd))", 1, true),
    "expected a.tl's hit applied: " .. after_a)

  local after_b = check.must(fs.read(fs.join(root, "b.tl")))
  check.equal(after_b, before_b)
end

local function test_fix_without_a_replacement_argument_refuses_with_exit_2()
  local root = two_hit_tree()
  -- No REPL between the pattern and --fix: `paths` (the positionals
  -- --fix's own argument didn't absorb) comes back empty.
  local r = rewrite(root, "os.execute($CMD)", "--fix", "a.tl")
  assert(r.code == 2, "expected exit 2, got " .. tostring(r.code) .. ": " .. r.err)
  assert(r.out:find("rewrite: refused:", 1, true),
    "expected a refusal verdict: " .. r.out)
end

--- Without `--fix`, `--rewrite` is `--find`'s own search mode: same
--- exit code, same output, one mechanism rather than two.
local function test_search_mode_matches_find_exactly()
  local root = two_hit_tree()
  local find_r = run_cli(root, "--find", "os.execute($CMD)", "a.tl", "b.tl")
  local rewrite_r = run_cli(root, "--rewrite", "os.execute($CMD)", "a.tl", "b.tl")
  check.equal(rewrite_r.code, find_r.code)
  check.equal(rewrite_r.out, find_r.out)
end

--- The same fix run, in process, so its own lines land in coverage
--- rather than vanishing into the spawned binary's embedded copy.
--- `run`'s own `paths`/`fix_paths` split is `_cli.parse`'s, not a
--- convenience shape: for `os.execute($CMD) REPL --fix a.tl b.tl`,
--- cosmic.flags' `--fix` (registered for `--format`/`--fix`) absorbs
--- "a.tl" as its OWN value, so REPL lands as `paths[1]` and "b.tl"
--- as `paths[2]`, while `fix_paths` is "a.tl" followed by everything
--- `paths` holds (REPL included, at `fix_paths[2]`).
local function test_fix_runs_in_process()
  local root = two_hit_tree()
  local cwd = check.must(fs.cwd())
  assert(fs.set_cwd(root))
  local repl = "assert(os.execute($CMD))"
  local code = rewrite_mod.run("os.execute($CMD)", {repl, "b.tl"},
    {"a.tl", repl, "b.tl"})
  assert(fs.set_cwd(cwd))
  assert(code == 1, "expected exit 1 (a refusal) in process, got " .. tostring(code))
end
