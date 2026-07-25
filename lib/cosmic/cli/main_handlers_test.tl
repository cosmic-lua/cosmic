#!/usr/bin/env cosmic
--- Tests for the cosmic.cli.main_handlers surfaces #504 flagged as
--- zero-coverage: the format gate, --docs lookup (including its
--- not-found UX), the --examples chain, and --make.
---
--- These spawn the built binary rather than calling the handlers
--- in-process, for two reasons: the handlers write to stdout/stderr
--- (which would corrupt this test's own output), and #504 asks for the
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

-- --check-format: the gate that keeps the tree formatted. Exercised in
-- both directions so a gate that accepted everything would fail here.

local formatted = fs.join(tmpdir, "formatted.tl")
fs.write(formatted, 'local x = 1\nprint(x)\n')

local misformatted = fs.join(tmpdir, "misformatted.tl")
fs.write(misformatted, 'local function f()\n        return 1\nend\nprint(f())\n')

local function test_check_format_accepts_formatted_source()
  local r = cli("--check-format", formatted)
  assert(r.code == 0,
    "well-formatted file should pass, got " .. r.code .. ": " .. r.err)
end
test_check_format_accepts_formatted_source()

local function test_check_format_rejects_misformatted_source()
  local r = cli("--check-format", misformatted)
  assert(r.code ~= 0, "misformatted file must be rejected, got exit 0")
  assert((r.out .. r.err):find("misformatted", 1, true),
    "the diagnostic should name the file, got: " .. r.out .. r.err)
end
test_check_format_rejects_misformatted_source()

local function test_check_format_reports_missing_file()
  local r = cli("--check-format", fs.join(tmpdir, "nope-does-not-exist.tl"))
  assert(r.code ~= 0, "a missing file must not pass the gate")
  assert(#(r.out .. r.err) > 0,
    "a missing file should produce a diagnostic, not silence")
end
test_check_format_reports_missing_file()

local function test_check_format_rejects_unparseable_source()
  local broken = fs.join(tmpdir, "broken.tl")
  fs.write(broken, 'local function f(\n')
  local r = cli("--check-format", broken)
  assert(r.code ~= 0, "unparseable source must be rejected, got exit 0")
end
test_check_format_rejects_unparseable_source()

-- --docs: the lookup path and, per #504, its not-found UX.

local function test_docs_finds_a_real_module()
  local r = cli("--docs", "cosmic.fs")
  assert(r.code == 0, "--docs cosmic.fs should succeed, got: " .. r.err)
  assert(r.out:find("fs", 1, true), "expected fs docs, got: " .. r.out)
end
test_docs_finds_a_real_module()

--- The not-found path must fail loudly and say something useful -- the
--- specific UX complaint in #504. A miss that exited 0, or exited 1
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

-- --examples: the chain #504 lists as zero-coverage.

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

-- --make: handle_make delegates to cosmic.make, which SCANS a
-- directory and generates a Makefile rather than running one the user
-- wrote. With no directory it prints the generated file; with one it
-- pipes it to make.

local function test_make_prints_the_generated_makefile()
  local r = cli("--make")
  assert(r.code == 0, "bare --make should succeed, got: " .. r.err)
  assert(r.out:find("Generated by cosmic --make", 1, true),
    "expected the generated-makefile header, got: " .. r.out)
  for _, target in ipairs({"check:", "format:", "test:", "ci:", "clean:"}) do
    assert(r.out:find(target, 1, true),
      "generated makefile should define " .. target .. ", got: " .. r.out)
  end
end
test_make_prints_the_generated_makefile()

--- Scanning a directory and actually running the generated rules. The
--- generated file uses `COSMIC ?= cosmic`, so without an override the
--- recipes shell out to a `cosmic` that is not on PATH in a test
--- environment; point it at the binary under test instead.
local function test_make_builds_a_scanned_directory()
  local dir = fs.join(tmpdir, "mk-src")
  fs.makedirs(dir)
  fs.write(fs.join(dir, "a.tl"), "local x = 1\nprint(x)\n")
  -- cwd is the scanned directory so the generated BUILD_DIR (o/) lands
  -- under it; without this the recipes run with the repo as cwd and
  -- write their artifacts into the repo's own o/.
  local argv = {cosmic, "--make", dir}
  local h = check.must(spawn.spawn(argv, {
        env = {"PATH=" .. os.getenv("PATH"), "COSMIC=" .. cosmic},
        cwd = dir,
      }))
  local r = check.must(h:wait())
  assert(r.code == 0,
    "--make on a scanned dir should build, got " .. tostring(r.code)
    .. ": " .. (r.stderr or ""))
end
test_make_builds_a_scanned_directory()

--- The target name is interpolated into a shell command, so make.run
--- rejects anything that is not a plain make target. This is a
--- security boundary: without it, `--make DIR '; rm -rf ~'` would run
--- arbitrary commands.
local function test_make_rejects_shell_metacharacters_in_target()
  local dir = fs.join(tmpdir, "mk-inject")
  fs.makedirs(dir)
  local r = cli("--make", dir, "; echo pwned")
  assert(r.code ~= 0, "an injected target must not exit 0")
  assert(r.err:find("invalid make target", 1, true),
    "expected the guard's rejection on stderr, got: " .. r.err)
  -- The rejection message quotes the offending target, so "pwned"
  -- legitimately appears on stderr. What must NOT appear is the
  -- *output* of running it, which `echo` would put on stdout.
  assert(not r.out:find("pwned", 1, true),
    "the injected command must never run, stdout was: " .. r.out)
end
test_make_rejects_shell_metacharacters_in_target()
