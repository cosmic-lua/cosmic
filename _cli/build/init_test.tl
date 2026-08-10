#!/usr/bin/env cosmic
-- Tests for _cli.build: the closed verb vocabulary behind `-c`, spawned
-- the way make spawns it — one whitespace-split recipe line — with the
-- test cosmic binary standing in as the pinned bootstrap for compile
-- mode.

local child = require("cosmic.child")
local fs = require("cosmic.fs")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local test_bin = fs.join(os.getenv("TEST_BIN") or "", "cosmic")

--- Run one recipe line, the way `SHELL := cosmic` delivers it.
local function run_driver(...: string): integer, string, string
  local parts: {string} = {}
  for _, a in ipairs({...}) do
    parts[#parts + 1] = a
  end
  local r0, rerr = child.run({test_bin, "-c", table.concat(parts, " ")})
  if r0 == nil then
    return 1, "", tostring(rerr)
  end
  local r = r0
  local code = 1
  if r.code ~= nil then
    code = r.code
  end
  return code, r.stdout, r.stderr
end

local function test_copy_preserves_mode()
  local src = fs.join(tmpdir, "tool.sh")
  local dst = fs.join(tmpdir, "out/deep/tool.sh")
  assert(fs.write(src, "#!/bin/sh\n", {mode = tonumber("755", 8) as integer})) -- cast: octal is integral
  local code, _out, err = run_driver("copy", src, dst)
  assert(code == 0, "copy failed (" .. tostring(code) .. "): " .. err)
  assert(fs.read(dst) == "#!/bin/sh\n", "copy content")
  local st = fs.stat(dst)
  assert(st, "dst should stat")
  local mode = st:mode() % 512
  assert(mode % 2 == 1, "exec bit preserved, mode: " .. string.format("%o", mode))
end
test_copy_preserves_mode()

local function test_link_replaces()
  local linkpath = fs.join(tmpdir, "links/v.lua")
  local code, _out, err = run_driver("link", "/some/target", linkpath)
  assert(code == 0, "link failed: " .. err)
  assert(fs.readlink(linkpath) == "/some/target", "link target")
  -- ln -sfn semantics: re-linking replaces
  code, _out, err = run_driver("link", "/other/target", linkpath)
  assert(code == 0, "relink failed: " .. err)
  assert(fs.readlink(linkpath) == "/other/target", "link replaced")
end
test_link_replaces()

-- No flag-stamp argument: compiles are unconditionally strict, so the
-- fixture is just a source and an output path.
local function compile_fixture(name: string, content: string): string, string
  local dir = fs.join(tmpdir, name)
  assert(fs.make_dirs(dir))
  local src = fs.join(dir, "mod.tl")
  local out = fs.join(dir, "mod.lua")
  assert(fs.write(src, content))
  return src, out
end

local function test_compile_writes_output()
  local src, out = compile_fixture("c-ok", "local x: number = 1\nprint(x)\n")
  local code, _out, err = run_driver("compile", test_bin, src, out)
  assert(code == 0, "compile failed (" .. tostring(code) .. "): " .. err)
  -- cast: or fallback does not narrow
  local lua = (fs.read(out) or "") as string
  assert(lua:match("print"), "expected compiled lua, got: " .. lua)
end
test_compile_writes_output()

-- An unchanged compile does not REWRITE its output -- the file is
-- read-only for the second run, so a write would fail -- but it does
-- advance the mtime. Make only runs the recipe when the target is out
-- of date, and a target that cannot become up to date is one make
-- re-runs on every future invocation.
local function test_compile_unchanged_restamps_without_rewriting()
  local src, out = compile_fixture("c-mtime", "print(1)\n")
  local code = run_driver("compile", test_bin, src, out)
  assert(code == 0, "first compile failed")
  local st1 = fs.stat(out)
  assert(st1, "output should exist")
  local t1 = st1:modify_time()
  local body = fs.read(out)
  -- read-only: the second run must not write, only restamp
  assert(fs.set_mode(out, tonumber("444", 8) as integer)) -- cast: octal is integral
  code = run_driver("compile", test_bin, src, out)
  assert(code == 0, "second compile failed")
  local st2 = assert(fs.stat(out))
  local t2 = st2:modify_time()
  assert(t2.secs > t1.secs or (t2.secs == t1.secs and t2.nsecs >= t1.nsecs),
    "unchanged compile must bring the output up to date")
  assert(fs.read(out) == body, "and must not rewrite its contents")
end
test_compile_unchanged_restamps_without_rewriting()

-- strictness: a type error must fail AND leave no output, so a
-- file that did not typecheck can never be packed into the binary
local function test_compile_failure_no_output()
  local src, out = compile_fixture("c-bad", "local x: number = \"not a number\"\n")
  local code, _out, err = run_driver("compile", test_bin, src, out)
  assert(code ~= 0, "type error must fail the compile")
  assert(err ~= "", "compiler stderr must pass through")
  assert(not fs.stat(out), "failed compile must not write output")
end
test_compile_failure_no_output()

local function test_compile_requires_all_paths()
  local src, _out = compile_fixture("c-usage", "print(1)\n")
  local code, _stdout, err = run_driver("compile", test_bin, src)
  assert(code ~= 0, "a missing output path must fail")
  assert(err:match("usage: compile"), "expected a usage error, got: " .. err)
end
test_compile_requires_all_paths()

-- The vocabulary is CLOSED, so an unknown verb is refused rather than
-- passed through, and the refusal names what a recipe may run.
local function test_unknown_verb_is_refused_by_name()
  local code, _out, err = run_driver("explode")
  assert(code ~= 0, "an unknown verb must fail")
  assert(err:find("unknown verb 'explode'", 1, true),
    "the refusal should name the verb, got: " .. err)
  assert(err:find("copy", 1, true),
    "…and list the ones it has, got: " .. err)
end
test_unknown_verb_is_refused_by_name()

local function test_tee_prints_and_writes()
  local out = fs.join(tmpdir, "tee/summary.txt")
  -- The child is a script rather than `-e '...'`: a recipe line is argv,
  -- not shell, so `-c` refuses the parens inline Lua would need. That
  -- refusal is the feature, and a test cannot ask to be exempt from it.
  local script = fs.join(tmpdir, "tee-child.lua")
  assert(fs.write(script, 'print("report line")\n'))
  local code, stdout, err = run_driver("tee", out, test_bin, script)
  assert(code == 0, "tee failed (" .. tostring(code) .. "): " .. err)
  assert(stdout:match("report line"), "tee must print to stdout")
  -- cast: or fallback does not narrow
  local written = (fs.read(out) or "") as string
  assert(written:match("report line"), "tee must write the file")
end
test_tee_prints_and_writes()

local function test_child_flags_not_consumed()
  -- the payload after the mode is a foreign argv: cosmic flags in it
  -- belong to the child (the recipe shape `--build tee out cosmic
  -- --report ...`), and the dispatcher must not let getopt permute
  -- them into its own options
  local out = fs.join(tmpdir, "tee/version.txt")
  local code, stdout, err = run_driver("tee", out, test_bin, "--version")
  assert(code == 0, "tee --version failed (" .. tostring(code) .. "): " .. err)
  assert(stdout:match("cosmic%-lua"), "child --version output expected, got: " .. stdout)
end
test_child_flags_not_consumed()

local function test_tee_propagates_failure_after_writing()
  local out = fs.join(tmpdir, "tee/fail.txt")
  -- A script, for the same reason as above: argv, not shell.
  local script = fs.join(tmpdir, "tee-fail.lua")
  assert(fs.write(script, 'print("partial")\nos.exit(3)\n'))
  local code = run_driver("tee", out, test_bin, script)
  assert(code == 3, "tee must propagate the child's exit code, got: " .. tostring(code))
  -- cast: or fallback does not narrow
  local written = (fs.read(out) or "") as string
  assert(written:match("partial"), "tee must write the file before failing")
end
test_tee_propagates_failure_after_writing()

local function test_list_write_if_changed()
  local out = fs.join(tmpdir, "list/files.stamp")
  local code = run_driver("write-list", out, "a.tl", "b.tl")
  assert(code == 0, "write-list failed")
  assert(fs.read(out) == "a.tl\nb.tl\n", "write-list content")
  local st1 = fs.stat(out)
  assert(st1, "stamp should exist")
  local t1 = st1:modify_time()
  code = run_driver("write-list", out, "a.tl", "b.tl")
  assert(code == 0, "unchanged list must succeed")
  local t2 = assert(fs.stat(out)):modify_time()
  assert(t1.secs == t2.secs and t1.nsecs == t2.nsecs,
    "unchanged list must not rewrite the stamp")
  code = run_driver("write-list", out, "a.tl")
  assert(code == 0, "changed list must rewrite")
  assert(fs.read(out) == "a.tl\n", "changed list content")
end
test_list_write_if_changed()

local function test_require_marker()
  local dir = fs.join(tmpdir, "markers/nested")
  assert(fs.make_dirs(dir))
  assert(fs.write(fs.join(dir, "probe.err"), "x enforce-ran: pledge\n"))
  local code = run_driver("assert-marker", "enforce-ran:", fs.join(tmpdir, "markers"))
  assert(code == 0, "marker present must pass")
  local code2, _out, err = run_driver("assert-marker", "absent-marker:", fs.join(tmpdir, "markers"))
  assert(code2 ~= 0, "missing marker must fail")
  assert(err:match("absent%-marker"), "failure names the marker, got: " .. err)
end
test_require_marker()

local function test_require_elf()
  local elf = fs.join(tmpdir, "native.bin")
  assert(fs.write(elf, "\127ELF rest-of-binary"))
  local code = run_driver("assert-elf", elf)
  assert(code == 0, "ELF magic must pass")
  local ape = fs.join(tmpdir, "still-ape.bin")
  assert(fs.write(ape, "MZqFpD='"))
  local code2, _out, err = run_driver("assert-elf", ape)
  assert(code2 ~= 0, "non-ELF must fail")
  assert(err:match("not a native ELF"), "failure explains, got: " .. err)
end
test_require_elf()

-- Three cases of one contract: a file goes, a missing path is ignored,
-- and a DANGLING symlink goes -- which `fs.is_present` misreads as gone.
local function test_remove()
  local a = fs.join(tmpdir, "rm-a")
  local target = fs.join(tmpdir, "rm-link-target")
  local link = fs.join(tmpdir, "rm-dangling")
  assert(fs.write(a, "x"))
  assert(fs.write(target, "x"))
  assert(fs.symlink(target, link))
  assert(fs.remove(target), "target goes first, leaving the link dangling")
  assert(fs.is_link(link) and not fs.is_present(link), "precondition: dangling")
  local code = run_driver("remove", a, fs.join(tmpdir, "rm-missing"), link)
  assert(code == 0, "remove must succeed, missing files ignored")
  assert(not fs.stat(a), "existing file removed")
  assert(not fs.is_link(link), "dangling symlink removed")
end
test_remove()

local function test_verdict()
  local o_dir = fs.join(tmpdir, "verdict")
  assert(fs.make_dirs(o_dir))
  -- pass: clean summary + marker; launder: clean summary, NO marker;
  -- bad: failing summary; ghost: no summary at all
  assert(fs.write(fs.join(o_dir, "good-summary.txt"), "good: 2 checks: 2 passed, 0 failed\n"))
  assert(fs.write(fs.join(o_dir, "ci-ok-good"), "\n"))
  assert(fs.write(fs.join(o_dir, "launder-summary.txt"), "launder: 1 passed\n"))
  assert(fs.write(fs.join(o_dir, "bad-summary.txt"), "bad: 3 checks: 2 passed, 1 failed\n"))
  assert(fs.write(fs.join(o_dir, "ci-ok-bad"), "\n"))

  local code, stdout = run_driver("verdict", o_dir, "good")
  assert(code == 0, "all-green must pass")
  assert(stdout:match("ci: PASS"), "expected PASS verdict")

  code, stdout = run_driver("verdict", o_dir, "good", "launder", "bad", "ghost")
  assert(code ~= 0, "failures must fail the verdict")
  assert(stdout:match("::group::good"), "stage groups printed")
  -- the grading: text-clean summary without an exit marker fails
  assert(stdout:match("ci: FAIL %(launder %(exit%) bad ghost%)"),
    "expected marker/summary/missing grading, got: " .. stdout)
  assert(stdout:match("ghost: no summary produced"), "missing summary named")
end
test_verdict()
