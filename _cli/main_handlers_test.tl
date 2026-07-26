#!/usr/bin/env cosmic
--- Tests for the _cli.main_handlers surfaces flagged as
--- zero-coverage: the format gate, --docs lookup (including its
--- not-found UX), the --examples chain, and --make.
---
--- These spawn the built binary rather than calling the handlers
--- in-process, for two reasons: the handlers write to stdout/stderr
--- (which would corrupt this test's own output), and asks for the
--- *chain* -- argument parsing, dispatch, and handler together -- not
--- just the leaf function.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")

-- Absolute: TEST_BIN is relative to the repo root under `make test`,
-- and the --make test below runs a child with a different cwd.
local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR")

local record Run
  code: integer
  out: string
  err: string
end

--- Run the cosmic binary with the given arguments and collect its exit
--- code and streams.
local function cli(...: string): Run
  local argv: {string} = {cosmic}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local h = check.must(spawn.spawn(argv))
  local r = check.must(h:wait())
  -- code is nil when the child was signaled; report that as non-zero
  -- so callers can treat "did not exit cleanly" uniformly.
  return {
    code = r.code or 128,
    out = r.stdout or "",
    err = r.stderr or "",
  }
end

-- --check format: the gate that keeps the tree formatted. Exercised in
-- both directions so a gate that accepted everything would fail here.

local formatted = fs.join(tmpdir, "formatted.tl")
fs.write(formatted, 'local x = 1\nprint(x)\n')

local misformatted = fs.join(tmpdir, "misformatted.tl")
fs.write(misformatted, 'local function f()\n        return 1\nend\nprint(f())\n')

local function test_check_format_accepts_formatted_source()
  local r = cli("--check", "format", formatted)
  assert(r.code == 0,
    "well-formatted file should pass, got " .. r.code .. ": " .. r.err)
end
test_check_format_accepts_formatted_source()

local function test_check_format_rejects_misformatted_source()
  local r = cli("--check", "format", misformatted)
  assert(r.code ~= 0, "misformatted file must be rejected, got exit 0")
  assert((r.out .. r.err):find("misformatted", 1, true),
    "the diagnostic should name the file, got: " .. r.out .. r.err)
end
test_check_format_rejects_misformatted_source()

local function test_check_format_reports_missing_file()
  local r = cli("--check", "format", fs.join(tmpdir, "nope-does-not-exist.tl"))
  assert(r.code ~= 0, "a missing file must not pass the gate")
  assert(#(r.out .. r.err) > 0,
    "a missing file should produce a diagnostic, not silence")
end
test_check_format_reports_missing_file()

local function test_check_format_rejects_unparseable_source()
  local broken = fs.join(tmpdir, "broken.tl")
  fs.write(broken, 'local function f(\n')
  local r = cli("--check", "format", broken)
  assert(r.code ~= 0, "unparseable source must be rejected, got exit 0")
end
test_check_format_rejects_unparseable_source()

-- --docs: the lookup path and, per, its not-found UX.

local function test_docs_finds_a_real_module()
  local r = cli("--docs", "cosmic.fs")
  assert(r.code == 0, "--docs cosmic.fs should succeed, got: " .. r.err)
  assert(r.out:find("fs", 1, true), "expected fs docs, got: " .. r.out)
end
test_docs_finds_a_real_module()

--- The not-found path must fail loudly and say something useful -- the
--- specific UX complaint in. A miss that exited 0, or exited 1
--- with an empty message, both regress it.
local function test_docs_miss_fails_with_a_message()
  local r = cli("--docs", "zzz-no-such-symbol-anywhere")
  assert(r.code ~= 0, "a docs miss must not exit 0")
  local said = r.out .. r.err
  assert(#said > 0, "a docs miss must explain itself, got empty output")
  assert(said:find("zzz%-no%-such%-symbol%-anywhere") or
    said:lower():find("no ") or said:lower():find("not found"),
    "the miss should reference the query or say not-found, got: " .. said)
end
test_docs_miss_fails_with_a_message()

-- --examples: the chain lists as zero-coverage.

local function test_examples_lists_without_argument()
  local r = cli("--examples")
  assert(r.code == 0, "bare --examples should succeed, got: " .. r.err)
  assert(#r.out > 0, "bare --examples should list something")
end
test_examples_lists_without_argument()

local function test_examples_shows_a_known_module()
  -- poll ships poll_example.tl, so this exercises the show-module path
  -- rather than the listing path.
  local r = cli("--examples", "poll")
  assert(r.code == 0, "--examples poll should succeed, got: " .. r.err)
  assert(r.out:find("poll", 1, true),
    "expected poll examples, got: " .. r.out)
end
test_examples_shows_a_known_module()

local function test_examples_miss_fails()
  local r = cli("--examples", "zzz-no-such-module")
  assert(r.code ~= 0, "--examples on an unknown module must not exit 0")
end
test_examples_miss_fails()

-- --make: the dispatch chain, not the verb. `--make <verb> [paths…]`
-- has to survive getopt, which permutes -- so the paths after the verb
-- are sliced off as a payload the way --build's and --test's are, and
-- the verb reaches _make with them intact. The verbs themselves
-- are tested in _make/.

local function test_make_dispatches_verb_and_paths()
  local dir = fs.join(tmpdir, "mk-src")
  fs.makedirs(dir)
  fs.write(fs.join(dir, "a.tl"), "local x: integer = 1\nprint(x)\n")
  fs.write(fs.join(dir, "b.tl"), "return {}\n")
  local h = check.must(spawn.spawn({cosmic, "--make", "check", "a.tl"},
      {cwd = dir}))
  local r = check.must(h:wait())
  assert(r.code == 0, "--make check should pass here, got " ..
    tostring(r.code) .. ": " .. tostring(r.stderr))
  -- The path reached the verb: without the payload slice, getopt would
  -- have taken a.tl as a script to run and the whole project would
  -- have been checked (or worse, executed).
  assert((r.stdout or ""):find("check: PASS (1 file)", 1, true),
    "the selection must reach the verb, got: " .. tostring(r.stdout))
end
test_make_dispatches_verb_and_paths()

--- --make with no verb is a usage error: a flag with no argument says
--- so rather than quietly picking a default action.
local function test_make_requires_a_verb()
  local r = cli("--make")
  assert(r.code ~= 0, "bare --make must not exit 0")
  assert(r.err:find("--make requires", 1, true),
    "expected a usage error, got: " .. r.err)
end
test_make_requires_a_verb()

-- The check gates run `cosmic --test <out> -- cosmic --check format F`.
-- That `--` is load-bearing: without it the OUTER getopt consumes the
-- child's --check format, the child runs argument-less, drops into the
-- REPL, reads EOF and exits 0 -- so --test faithfully records a pass
-- for a check that never ran, and every teal/format .got was a 0
-- regardless of the file.
--
-- This pins the propagation in both directions, so a gate that cannot
-- fail is caught here rather than by noticing, months later, that
-- nothing has ever gone red.
local function test_test_wrapper_propagates_child_exit_code()
  local bad = fs.join(tmpdir, "wrap_bad.tl")
  fs.write(bad, 'local function f()\n        return 1\nend\nprint(f())\n')
  local good = fs.join(tmpdir, "wrap_good.tl")
  fs.write(good, 'local x = 1\nprint(x)\n')

  local base_bad = fs.join(tmpdir, "wrap_bad.fmt")
  cli("--test", base_bad, "--", cosmic, "--check", "format", bad)
  local got_bad = check.must(fs.read(base_bad .. ".got"),
    "--test should record an exit code for the failing check")
  assert(got_bad:gsub("%s+$", "") ~= "0",
    "a failing check must be recorded as non-zero, got: " .. got_bad)

  local base_good = fs.join(tmpdir, "wrap_good.fmt")
  cli("--test", base_good, "--", cosmic, "--check", "format", good)
  local got_good = check.must(fs.read(base_good .. ".got"),
    "--test should record an exit code for the passing check")
  assert(got_good:gsub("%s+$", "") == "0",
    "a passing check must be recorded as 0, got: " .. got_good)
end
test_test_wrapper_propagates_child_exit_code()

--- The same, WITHOUT the `--`. Requiring that separator without saying
--- so means omitting it silently runs no check; --test slices its
--- command vector off before the option
--- parse, the way --build always has, so the child keeps its own flags
--- either way and the trap is gone rather than merely documented.
local function test_test_wrapper_needs_no_separator()
  local bad = fs.join(tmpdir, "nosep_bad.tl")
  fs.write(bad, 'local function f()\n        return 1\nend\nprint(f())\n')
  local good = fs.join(tmpdir, "nosep_good.tl")
  fs.write(good, 'local x = 1\nprint(x)\n')

  local base_bad = fs.join(tmpdir, "nosep_bad.fmt")
  cli("--test", base_bad, cosmic, "--check", "format", bad)
  local got_bad = check.must(fs.read(base_bad .. ".got"),
    "--test without `--` should still record an exit code")
  assert(got_bad:gsub("%s+$", "") ~= "0",
    "without `--` a failing check must still be non-zero, got: " .. got_bad)

  local base_good = fs.join(tmpdir, "nosep_good.fmt")
  cli("--test", base_good, cosmic, "--check", "format", good)
  local got_good = check.must(fs.read(base_good .. ".got"),
    "--test without `--` should still record an exit code")
  assert(got_good:gsub("%s+$", "") == "0",
    "without `--` a passing check must be 0, got: " .. got_good)
end
test_test_wrapper_needs_no_separator()
