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

--- Run `cosmic <argv>` verbatim, cwd inside `dir` -- for the orderings
--- below, where `--apply` deliberately does NOT come right after
--- `--rewrite`'s own arguments the way `run_cli`/`rewrite` assume.
--- @param dir string The fixture root
--- @param argv {string} The full argument list, cosmic's own name excluded
--- @return Run The exit code and captured output
local function run_argv(dir: string, argv: {string}): Run
  local full: {string} = {cosmic}
  for _, a in ipairs(argv) do
    full[#full + 1] = a
  end
  local h = check.must(child.start(full, {cwd = dir}))
  local r = check.must(h:wait())
  return {code = r.code or 128, out = r.stdout or "", err = r.stderr or ""}
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

local function test_apply_applies_one_hit_and_refuses_the_commented_one()
  local root = two_hit_tree()
  local before_b = check.must(fs.read(fs.join(root, "b.tl")))
  local r = rewrite(root, "os.execute($CMD)", "assert(os.execute($CMD))",
    "--apply", "a.tl", "b.tl")
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

local function test_apply_without_a_replacement_argument_refuses_with_exit_2()
  local root = two_hit_tree()
  -- No REPL between the pattern and --apply: `paths` (the positionals
  -- left after the pattern) holds only "a.tl", short of the two entries
  -- (REPL, PATH) apply mode requires.
  local r = rewrite(root, "os.execute($CMD)", "--apply", "a.tl")
  assert(r.code == 2, "expected exit 2, got " .. tostring(r.code) .. ": " .. r.err)
  assert(r.out:find("rewrite: refused:", 1, true),
    "expected a refusal verdict: " .. r.out)
end

--- Without `--apply`, `--rewrite` is `--find`'s own search mode: same
--- exit code, same output, one mechanism rather than two.
local function test_search_mode_matches_find_exactly()
  local root = two_hit_tree()
  local find_r = run_cli(root, "--find", "os.execute($CMD)", "a.tl", "b.tl")
  local rewrite_r = run_cli(root, "--rewrite", "os.execute($CMD)", "a.tl", "b.tl")
  check.equal(rewrite_r.code, find_r.code)
  check.equal(rewrite_r.out, find_r.out)
end

--- The same apply run, in process, so its own lines land in coverage
--- rather than vanishing into the spawned binary's embedded copy.
--- `run`'s `paths` is one list -- `_cli.parse`'s `rewrite_paths` -- REPL
--- at `paths[1]` followed by every target path, with no second list to
--- reassemble against.
local function test_apply_runs_in_process()
  local root = two_hit_tree()
  local cwd = check.must(fs.cwd())
  assert(fs.set_cwd(root))
  local repl = "assert(os.execute($CMD))"
  local code = rewrite_mod.run("os.execute($CMD)", {repl, "a.tl", "b.tl"}, true)
  assert(fs.set_cwd(cwd))
  assert(code == 1, "expected exit 1 (a refusal) in process, got " .. tostring(code))
end

--- The review that bounced this item found `--fix`'s reuse (a
--- FILE-taking flag) order/count-fragile: `--fix PATH... --rewrite
--- PATTERN REPL` absorbed a PATH as `--fix`'s own value and reassembled
--- `replacement`/`real_paths` by counting across two separately
--- populated lists, so this exact ordering silently read a real file as
--- REPL and reported "0 applied ... exit 0" -- a clean-looking run that
--- had actually mismatched every argument. `--apply` is a bare switch
--- now: it never absorbs a PATH, and there is only one list
--- (`rewrite_paths`) to read REPL and the target paths from, so the
--- same ordering either behaves or refuses out loud -- never that
--- silent no-op. Here REPL still has to be `paths[1]`, so listing PATHs
--- before `--rewrite` makes "a.tl" the (mis-set) REPL and leaves no
--- valid path behind it, which `find.files_for` refuses outright.
local function test_apply_before_rewrite_flag_refuses_loudly_not_silently()
  local root = two_hit_tree()
  local before_a = check.must(fs.read(fs.join(root, "a.tl")))
  local before_b = check.must(fs.read(fs.join(root, "b.tl")))
  local r = run_argv(root, {"--apply", "a.tl", "b.tl",
      "--rewrite", "os.execute($CMD)", "assert(os.execute($CMD))"})
  assert(r.code == 2, "expected exit 2 (a clear refusal), got " .. tostring(r.code)
    .. ": out=" .. r.out .. " err=" .. r.err)
  assert(r.out:find("rewrite: refused:", 1, true),
    "expected an out-loud refusal verdict: " .. r.out)
  assert(not r.out:find("applied", 1, true),
    "must never report an applied count on a mismatched ordering: " .. r.out)
  check.equal(check.must(fs.read(fs.join(root, "a.tl"))), before_a)
  check.equal(check.must(fs.read(fs.join(root, "b.tl"))), before_b)
end

--- The reviewer's second repro, same translation: `--apply` before
--- `--rewrite` again, this time with a REPL ("." in the original) that
--- reads as a bare path rather than a syntax error. With one list and
--- no reassembly, "a.tl" (the first positional) is still read as REPL
--- and "." (the actual intended REPL) lands in the target paths, where
--- it expands to the whole fixture via `find.files_for`'s own project
--- scan. The outcome is loud either way: "a.tl" spliced into a.tl's own
--- statement does not reparse (refused, per the next test's mechanism),
--- and b.tl's hit is refused for its comment -- a "0 applied, 1
--- refused" verdict with both files unchanged, never a silent
--- "0 applied ... exit 0".
local function test_apply_before_rewrite_with_dot_path_as_repl_refuses_loudly()
  local root = two_hit_tree()
  local before_a = check.must(fs.read(fs.join(root, "a.tl")))
  local before_b = check.must(fs.read(fs.join(root, "b.tl")))
  local r = run_argv(root, {"--apply", "a.tl", "b.tl",
      "--rewrite", "os.execute($CMD)", "."})
  assert(r.code == 1, "expected exit 1 (a refusal), got " .. tostring(r.code)
    .. ": out=" .. r.out .. " err=" .. r.err)
  assert(r.out:find("rewrite: 0 applied, 1 refused in 2 file(s)", 1, true),
    "expected the verdict line: " .. r.out)
  assert(r.err:find("a.tl", 1, true) and r.err:find("syntax error", 1, true),
    "expected a.tl's mis-set REPL to be reported as a parse failure: " .. r.err)
  check.equal(check.must(fs.read(fs.join(root, "a.tl"))), before_a)
  check.equal(check.must(fs.read(fs.join(root, "b.tl"))), before_b)
end

--- Non-blocking finding from the same review: `fix_one`'s `not result`
--- guard (the branch `cosmic.ast.rewrite` failing entirely, as opposed
--- to refusing one hit) had no test driving it -- only Teal's flow
--- typing enforced that the guard narrows `result` before use. A REPL
--- that is valid on its own but breaks the statement it lands in
--- (replacing a call `os.execute(cmd)` with the bare name `cmd`, not a
--- legal statement by itself) drives exactly that path: `ast.rewrite`
--- reparses its own spliced output, fails, and returns `nil, err`.
local function test_apply_leaves_the_file_untouched_when_the_splice_wont_reparse()
  local root = fixture("nilresult", {
      ["n.tl"] = "os.execute(cmd)\n",
    })
  local before = check.must(fs.read(fs.join(root, "n.tl")))
  local r = rewrite(root, "os.execute($CMD)", "$CMD", "--apply", "n.tl")
  assert(r.code == 1, "expected exit 1 (nothing applied), got " .. tostring(r.code)
    .. ": " .. r.err)
  assert(r.out:find("rewrite: 0 applied, 0 refused in 1 file(s)", 1, true),
    "expected the verdict line: " .. r.out)
  assert(r.err:find("n.tl", 1, true) and r.err:find("syntax error", 1, true),
    "expected the unreparseable splice reported as a parse failure: " .. r.err)
  local after = check.must(fs.read(fs.join(root, "n.tl")))
  check.equal(after, before)
end
