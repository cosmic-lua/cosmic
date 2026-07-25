#!/usr/bin/env cosmic
-- Tests for the shell-free binary packer (#732): stage a tiny payload,
-- pack it with the PINNED cosmos zip onto a base file, and assert the
-- contract pieces — base prefix preserved, exec bit, mtime clamp.

local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")
local zip = require("cosmic.zip")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local test_bin = fs.join(os.getenv("TEST_BIN") or "", "cosmic")
local test_o = os.getenv("TEST_O") or "o"
local packer = fs.join(test_o, "_build/build-pack.lua")
local zip_bin = fs.join(test_o, "cosmos/.staged/zip")

local function run_pack(...: string): integer, string
  local args: {string} = {test_bin, "--", packer}
  for _, a in ipairs({...}) do
    table.insert(args, a)
  end
  local result, serr = child.run(args)
  if not result then
    return 1, tostring(serr)
  end
  local r = result as child.Result -- cast: record union after guard
  local code = 1
  if r.code ~= nil then
    code = r.code
  end
  return code, r.stderr
end

local function test_pack_end_to_end()
  local src = fs.join(tmpdir, "src")
  fs.makedirs(src)
  assert(fs.write(fs.join(src, "mod.lua"), "return {}\n"))
  assert(fs.write(fs.join(src, "main.lua"), "print('hi')\n"))
  -- the real base (the cosmos lua APE) already contains a zip archive,
  -- and the zip tool appends to that; stand in with a real archive
  local base = fs.join(tmpdir, "base.bin")
  local w = check.must(zip.writer(base))
  assert(w:add("stub.txt", "preexisting\n"))
  w:close()
  local built = fs.join(tmpdir, "built")
  local out = fs.join(tmpdir, "out.bin")

  local code, err = run_pack(
    "--out", out, "--built", built, "--epoch", "1700000000", "--zip", zip_bin,
    "--base", base,
    "--copy", fs.join(src, "mod.lua"), "cosmic/mod.lua",
    "--copy", fs.join(src, "main.lua"), "main.lua")
  assert(code == 0, "pack failed (" .. tostring(code) .. "): " .. err)

  -- the packed output is a valid archive holding the base's entries
  -- plus the staged payload
  local r = check.must(zip.reader(out))
  assert(r:read("stub.txt") == "preexisting\n", "base entry survives")
  assert(r:read("cosmic/mod.lua") == "return {}\n", "module packed")
  assert(r:read("main.lua") == "print('hi')\n", "main packed")
  r:close()
  local st = fs.stat(out)
  assert(st, "out should stat")
  local mode = (st as fs_types.Stat):mode() % 512 -- cast: mixed-representation Stat
  assert(mode % 2 == 1, "packed binary keeps the exec bit")

  -- the staged copy's mtime is clamped to the epoch (#733)
  local staged = fs.stat(fs.join(built, "main.lua"))
  assert(staged, "staged main.lua should exist")
  local secs = (staged as fs_types.Stat):mtim() -- cast: mixed-representation Stat
  assert(secs == 1700000000, "mtime clamped, got: " .. tostring(secs))
end
test_pack_end_to_end()

local function test_pack_missing_input_fails()
  local code, err = run_pack(
    "--out", fs.join(tmpdir, "o2.bin"), "--built", fs.join(tmpdir, "b2"),
    "--epoch", "1", "--zip", zip_bin, "--base", fs.join(tmpdir, "nope"),
    "--copy", fs.join(tmpdir, "missing.lua"), ".lua/x.lua")
  assert(code ~= 0, "missing copy source must fail")
  assert(err:match("read .* failed"), "error names the read, got: " .. err)
end
test_pack_missing_input_fails()
