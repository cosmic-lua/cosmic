#!/usr/bin/env cosmic
-- Tests for the build-recipe driver (#732). The driver is spawned the
-- way make spawns it, with the test cosmic binary standing in as the
-- pinned bootstrap for compile mode.

local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local test_bin = fs.join(os.getenv("TEST_BIN") or "", "cosmic")
local test_o = os.getenv("TEST_O") or "o"
local driver = fs.join(test_o, "lib/build/build-recipe.lua")

local function run_driver(...: string): integer, string, string
  local args: {string} = {test_bin, "--", driver}
  for _, a in ipairs({...}) do
    table.insert(args, a)
  end
  local result, serr = child.run(args)
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

local function compile_fixture(name: string, content: string): string, string, string
  local dir = fs.join(tmpdir, name)
  fs.makedirs(dir)
  local stamp = fs.join(dir, "compile-flag")
  local src = fs.join(dir, "mod.tl")
  local out = fs.join(dir, "mod.lua")
  assert(fs.write(stamp, "--compile\n"))
  assert(fs.write(src, content))
  return stamp, src, out
end

local function test_compile_writes_output()
  local stamp, src, out = compile_fixture("c-ok", "local x: number = 1\nprint(x)\n")
  env.set("TREE_LUA_PATH", ";;")
  local code, _out, err = run_driver("compile", stamp, test_bin, src, out)
  assert(code == 0, "compile failed (" .. tostring(code) .. "): " .. err)
  -- cast: or fallback does not narrow
  local lua = (fs.read(out) or "") as string
  assert(lua:match("print"), "expected compiled lua, got: " .. lua)
end
test_compile_writes_output()

local function test_compile_unchanged_keeps_mtime()
  local stamp, src, out = compile_fixture("c-mtime", "print(1)\n")
  env.set("TREE_LUA_PATH", ";;")
  local code = run_driver("compile", stamp, test_bin, src, out)
  assert(code == 0, "first compile failed")
  local st1 = fs.stat(out)
  assert(st1, "output should exist")
  local s1, n1 = (st1 as fs_types.Stat):mtim() -- cast: mixed-representation Stat
  -- second run with identical content must not rewrite the output
  fs.chmod(out, tonumber("444", 8) as integer) -- cast: octal is integral
  code = run_driver("compile", stamp, test_bin, src, out)
  assert(code == 0, "second compile failed")
  local st2 = fs.stat(out)
  local s2, n2 = (st2 as fs_types.Stat):mtim() -- cast: mixed-representation Stat
  assert(s1 == s2 and n1 == n2, "unchanged compile must not touch the output")
end
test_compile_unchanged_keeps_mtime()

local function test_compile_failure_no_output()
  local stamp, src, out = compile_fixture("c-bad", "local x: number = \"not a number\"\n")
  env.set("TREE_LUA_PATH", ";;")
  local code, _out, err = run_driver("compile", stamp, test_bin, src, out)
  assert(code ~= 0, "type error must fail the compile")
  assert(err ~= "", "compiler stderr must pass through")
  assert(not fs.stat(out), "failed compile must not write output")
end
test_compile_failure_no_output()

local function test_compile_rejects_bad_stamp()
  local stamp, src, out = compile_fixture("c-stamp", "print(1)\n")
  assert(fs.write(stamp, "--rm -rf\n"))
  local code, _out, err = run_driver("compile", stamp, test_bin, src, out)
  assert(code ~= 0, "bad stamp must fail")
  assert(err:match("bad compile flag"), "expected stamp error, got: " .. err)
end
test_compile_rejects_bad_stamp()

local function test_unknown_mode()
  local code, _out, err = run_driver("explode")
  assert(code ~= 0, "unknown mode must fail")
  assert(err:match("usage"), "expected usage error, got: " .. err)
end
test_unknown_mode()

local function test_tee_prints_and_writes()
  local out = fs.join(tmpdir, "tee/summary.txt")
  local code, stdout, err = run_driver("tee", out, test_bin, "-e", "print('report line')")
  assert(code == 0, "tee failed (" .. tostring(code) .. "): " .. err)
  assert(stdout:match("report line"), "tee must print to stdout")
  -- cast: or fallback does not narrow
  local written = (fs.read(out) or "") as string
  assert(written:match("report line"), "tee must write the file")
end
test_tee_prints_and_writes()

local function test_tee_propagates_failure_after_writing()
  local out = fs.join(tmpdir, "tee/fail.txt")
  local code = run_driver("tee", out, test_bin, "-e", "print('partial') os.exit(3)")
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
