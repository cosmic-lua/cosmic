#!/usr/bin/env cosmic
-- Tests for _cli.build: the closed verb vocabulary behind `-c`, spawned
-- the way make spawns it — one whitespace-split recipe line — with the
-- test cosmic binary standing in as the pinned bootstrap for compile
-- mode.

local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local test_bin = fs.join(os.getenv("TEST_BIN") or "", "cosmic")

--- Run one recipe line, the way `SHELL := cosmic` delivers it.
local function run_driver(...: string): integer, string, string
  local parts: {string} = {}
  for _, a in ipairs({...}) do
    parts[#parts + 1] = a
  end
  local result, serr = child.run({test_bin, "-c", table.concat(parts, " ")})
  if not result then
    return 1, "", tostring(serr)
  end
  local r = result as child.Result -- cast: record union after guard
  local code = 1
  if r.code ~= nil then
    code = r.code
  end
  return code, r.stdout, r.stderr
end

local function test_copy_preserves_mode()
  local src = fs.join(tmpdir, "tool.sh")
  local dst = fs.join(tmpdir, "out/deep/tool.sh")
  assert(fs.write(src, "#!/bin/sh\n", tonumber("755", 8) as integer)) -- cast: octal is integral
  local code, _out, err = run_driver("copy", src, dst)
  assert(code == 0, "copy failed (" .. tostring(code) .. "): " .. err)
  assert(fs.read(dst) == "#!/bin/sh\n", "copy content")
  local st = fs.stat(dst)
  assert(st, "dst should stat")
  local mode = (st as fs_types.Stat):mode() % 512 -- cast: mixed-representation Stat
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
  fs.makedirs(dir)
  local src = fs.join(dir, "mod.tl")
  local out = fs.join(dir, "mod.lua")
  assert(fs.write(src, content))
  return src, out
end

local function test_compile_writes_output()
  local src, out = compile_fixture("c-ok", "local x: number = 1\nprint(x)\n")
  env.set("TREE_LUA_PATH", ";;")
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
  env.set("TREE_LUA_PATH", ";;")
  local code = run_driver("compile", test_bin, src, out)
  assert(code == 0, "first compile failed")
  local st1 = fs.stat(out)
  assert(st1, "output should exist")
  local s1, n1 = (st1 as fs_types.Stat):mtim() -- cast: mixed-representation Stat
  local body = fs.read(out)
  -- read-only: the second run must not write, only restamp
  fs.chmod(out, tonumber("444", 8) as integer) -- cast: octal is integral
  code = run_driver("compile", test_bin, src, out)
  assert(code == 0, "second compile failed")
  local st2 = fs.stat(out)
  local s2, n2 = (st2 as fs_types.Stat):mtim() -- cast: mixed-representation Stat
  assert(s2 > s1 or (s2 == s1 and n2 >= n1),
    "unchanged compile must bring the output up to date")
  assert(fs.read(out) == body, "and must not rewrite its contents")
end
test_compile_unchanged_restamps_without_rewriting()

-- strictness: a type error must fail AND leave no output, so a
-- file that did not typecheck can never be packed into the binary
local function test_compile_failure_no_output()
  local src, out = compile_fixture("c-bad", "local x: number = \"not a number\"\n")
  env.set("TREE_LUA_PATH", ";;")
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
  local code = run_driver("list", out, "a.tl", "b.tl")
  assert(code == 0, "list failed")
  assert(fs.read(out) == "a.tl\nb.tl\n", "list content")
  local st1 = fs.stat(out)
  assert(st1, "stamp should exist")
  local s1, n1 = (st1 as fs_types.Stat):mtim() -- cast: mixed-representation Stat
  code = run_driver("list", out, "a.tl", "b.tl")
  assert(code == 0, "unchanged list must succeed")
  local s2, n2 = (fs.stat(out) as fs_types.Stat):mtim() -- cast: mixed-representation Stat
  assert(s1 == s2 and n1 == n2, "unchanged list must not rewrite the stamp")
  code = run_driver("list", out, "a.tl")
  assert(code == 0, "changed list must rewrite")
  assert(fs.read(out) == "a.tl\n", "changed list content")
end
test_list_write_if_changed()

local function test_require_marker()
  local dir = fs.join(tmpdir, "markers/nested")
  fs.makedirs(dir)
  assert(fs.write(fs.join(dir, "probe.err"), "x enforce-ran: pledge\n"))
  local code = run_driver("require-marker", "enforce-ran:", fs.join(tmpdir, "markers"))
  assert(code == 0, "marker present must pass")
  local code2, _out, err = run_driver("require-marker", "absent-marker:", fs.join(tmpdir, "markers"))
  assert(code2 ~= 0, "missing marker must fail")
  assert(err:match("absent%-marker"), "failure names the marker, got: " .. err)
end
test_require_marker()

local function test_require_elf()
  local elf = fs.join(tmpdir, "native.bin")
  assert(fs.write(elf, "\127ELF rest-of-binary"))
  local code = run_driver("require-elf", elf)
  assert(code == 0, "ELF magic must pass")
  local ape = fs.join(tmpdir, "still-ape.bin")
  assert(fs.write(ape, "MZqFpD='"))
  local code2, _out, err = run_driver("require-elf", ape)
  assert(code2 ~= 0, "non-ELF must fail")
  assert(err:match("not a native ELF"), "failure explains, got: " .. err)
end
test_require_elf()

local function test_remove()
  local a = fs.join(tmpdir, "rm-a")
  assert(fs.write(a, "x"))
  local code = run_driver("remove", a, fs.join(tmpdir, "rm-missing"))
  assert(code == 0, "remove must succeed, missing files ignored")
  assert(not fs.stat(a), "existing file removed")
end
test_remove()

local function test_verdict()
  local o_dir = fs.join(tmpdir, "verdict")
  fs.makedirs(o_dir)
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

-- `-c` is the SHELL half of the same driver (`SHELL := cosmic`, make's
-- default `.SHELLFLAGS` already `-c`): one line, split on whitespace,
-- run as argv through the modes table above.
local function run_recipe(line: string): integer, string, string
  local result, serr = child.run({test_bin, "-c", line})
  if not result then
    return 1, "", tostring(serr)
  end
  local r = result as child.Result -- cast: record union after guard
  local code = 1
  if r.code ~= nil then
    code = r.code
  end
  return code, r.stdout, r.stderr
end

local function test_recipe_dispatches()
  local src = fs.join(tmpdir, "recipe-src.txt")
  local dst = fs.join(tmpdir, "recipe/out.txt")
  assert(fs.write(src, "hello\n"))
  local code, _out, err = run_recipe("copy " .. src .. " " .. dst)
  assert(code == 0, "recipe copy failed (" .. tostring(code) .. "): " .. err)
  assert(fs.read(dst) == "hello\n", "recipe reaches the same modes table")
end
test_recipe_dispatches()

local function test_recipe_strips_the_sentinel()
  -- Generated recipes end in `;` so make routes them through SHELL at
  -- all: without it make execs the line itself and cosmic never sees
  -- it. The `;` is make's, not the verb's, so it must not reach argv.
  local src = fs.join(tmpdir, "sentinel-src.txt")
  local dst = fs.join(tmpdir, "sentinel/out.txt")
  assert(fs.write(src, "sentinel\n"))
  local code, _out, err = run_recipe("copy " .. src .. " " .. dst .. " ;")
  assert(code == 0, "a sentinel line must run (" .. tostring(code) .. "): " .. err)
  assert(fs.read(dst) == "sentinel\n", "sentinel stripped before dispatch")
end
test_recipe_strips_the_sentinel()

local function test_recipe_refuses_shell()
  -- A shell would treat these as a redirect and a command separator. As
  -- argv they would be inert literals, so the failure this prevents is
  -- silent: the line does something other than it looks like.
  local marker = fs.join(tmpdir, "recipe-pwned")
  local code, _out, err = run_recipe("copy a b ; touch " .. marker)
  assert(code ~= 0, "a shell metacharacter must fail the line")
  assert(err:match("argv, not shell"), "expected the argv/shell message, got: " .. err)
  assert(not fs.stat(marker), "nothing after ';' may run")

  code, _out, err = run_recipe("list " .. fs.join(tmpdir, "r.txt") .. " > x")
  assert(code ~= 0, "a redirect must fail the line")
  assert(err:match("argv, not shell"), "expected the argv/shell message, got: " .. err)
end
test_recipe_refuses_shell()

local function test_recipe_unknown_verb()
  local code, _out, err = run_recipe("rm -rf " .. tmpdir)
  assert(code ~= 0, "a verb outside the vocabulary must fail")
  assert(err:match("unknown verb 'rm'"), "expected the verb named, got: " .. err)
  -- the whole vocabulary is one line, so the message can carry it
  assert(err:match("copy") and err:match("verdict"),
    "expected the vocabulary listed, got: " .. err)
  assert(fs.stat(tmpdir), "an unknown verb runs nothing at all")
end
test_recipe_unknown_verb()

local function test_recipe_blank_is_a_noop()
  -- make hands us no blank lines, but a variable that expanded to
  -- nothing looks like one; a shell would do nothing, so do nothing.
  local code = run_recipe("   ")
  assert(code == 0, "a blank recipe line succeeds")
end
test_recipe_blank_is_a_noop()

-- exec: the one door out of the vocabulary, and it opens only onto
-- bytes already under the build root.
local function run_recipe_env(line: string, root: string): integer, string, string
  local envlist: {string} = {}
  for _, entry in ipairs(env.list()) do
    if not entry:match("^COSMIC_EXEC_ROOT=") then
      envlist[#envlist + 1] = entry
    end
  end
  envlist[#envlist + 1] = "COSMIC_EXEC_ROOT=" .. root
  local result, serr = child.run({test_bin, "-c", line}, {env = envlist})
  if not result then
    return 1, "", tostring(serr)
  end
  local r = result as child.Result -- cast: record union after guard
  local code = 1
  if r.code ~= nil then
    code = r.code
  end
  return code, r.stdout, r.stderr
end

-- The program's arguments travel through the same whitespace split as
-- the verb, so they cannot carry shell characters either: `-e print(42)`
-- is refused for its parentheses. Scripts keep this test's own argv to
-- paths and flags, which is what a real recipe passes.
local function write_script(name: string, body: string): string
  local path = fs.join(tmpdir, name)
  assert(fs.write(path, body))
  return path
end

local function test_exec_runs_bytes_under_the_root()
  local root = fs.dirname(fs.abspath(test_bin))
  local script = write_script("exec-print.lua", "print('42')\n")
  local code, out, err = run_recipe_env(
    "exec " .. test_bin .. " " .. script, root)
  assert(code == 0, "exec under the root failed (" .. tostring(code) .. "): " .. err)
  assert(out:match("42"), "expected the program's own output, got: " .. out)
end
test_exec_runs_bytes_under_the_root()

local function test_exec_refuses_outside_the_root()
  -- /bin/sh exists and is executable; being outside the root is the
  -- only reason it must not run.
  local code, _out, err = run_recipe_env("exec /bin/sh -c true", tmpdir)
  assert(code ~= 0, "a program outside the build root must be refused")
  assert(err:match("not under the build root"), "expected the root named, got: " .. err)
end
test_exec_refuses_outside_the_root()

-- The root check has to resolve SYMLINKS, not just normalize `..`.
-- abspath refuses a path that climbs out lexically, but the kernel
-- follows links at spawn -- so `o/tool -> /bin/echo` had an abspath
-- under the root, passed the prefix test, and ran the host binary. That
-- made "exec resolves only to pinned bytes under o/, never PATH" a
-- stronger claim than the check enforced.
local function test_exec_refuses_a_symlink_out_of_the_root()
  local root = fs.join(tmpdir, "exec-root")
  fs.rmrf(root)
  assert(fs.makedirs(root))
  local link = fs.join(root, "escape")
  assert(fs.symlink("/bin/sh", link))
  local code, _out, err = run_recipe_env("exec " .. link .. " -c true", root)
  assert(code ~= 0, "a symlink out of the root must be refused")
  assert(err:match("not under the build root"),
    "expected the root named, got: " .. err)
  assert(err:match("resolves to"),
    "and where it actually resolved to, got: " .. err)
end
test_exec_refuses_a_symlink_out_of_the_root()

-- The other direction, because refusing everything would also pass the
-- test above: a link INSIDE the root still runs. bin/make creates
-- exactly one (`o/bootstrap/lua -> cosmic`), so this is not hypothetical.
local function test_exec_allows_a_symlink_inside_the_root()
  local root = fs.dirname(fs.abspath(test_bin))
  local script = write_script("exec-linked.lua", "print('linked')\n")
  local link = fs.join(root, "exec-alias")
  fs.rmrf(link)
  assert(fs.symlink(fs.basename(test_bin), link))
  local code, out, err = run_recipe_env("exec " .. link .. " " .. script, root)
  fs.rmrf(link)
  assert(code == 0, "a link inside the root must still run: " .. err)
  assert(out:match("linked"), "expected the program's output, got: " .. out)
end
test_exec_allows_a_symlink_inside_the_root()

local function test_exec_never_searches_path()
  -- `sh` resolves through PATH for a shell; for exec it is just a
  -- relative path that is not under the root, so it cannot run.
  local code, _out, err = run_recipe_env("exec sh -c true", tmpdir)
  assert(code ~= 0, "a bare program name must not be found on PATH")
  assert(err:match("not under the build root"), "expected the root named, got: " .. err)
end
test_exec_never_searches_path()

local function test_exec_reports_a_missing_program()
  local code, _out, err = run_recipe_env(
    "exec " .. fs.join(tmpdir, "absent") .. " x", tmpdir)
  assert(code ~= 0, "a missing program must fail")
  assert(err:match("no such file"), "expected a missing-file message, got: " .. err)
end
test_exec_reports_a_missing_program()

local function test_exec_passes_through_the_exit_code()
  local root = fs.dirname(fs.abspath(test_bin))
  local script = write_script("exec-exit.lua", "os.exit(3)\n")
  local code = run_recipe_env("exec " .. test_bin .. " " .. script, root)
  assert(code == 3, "expected the program's own exit code, got " .. tostring(code))
end
test_exec_passes_through_the_exit_code()
