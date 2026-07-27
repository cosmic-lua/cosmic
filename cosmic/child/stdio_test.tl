#!/usr/bin/env cosmic
--- Tests for spawn's "inherit" stdio disposition.
---
--- Proving inherit works needs a vantage point OUTSIDE this process,
--- because this process's own stdout is the thing under test. Every
--- test here therefore runs a helper cosmic whose stdout is redirected
--- to a file (with a Handle, the already-supported disposition), has
--- that helper spawn a grandchild with stdout = "inherit", and then
--- reads the file. The grandchild's bytes can only reach the file by
--- travelling through the helper's real fd 1.

local check = require("cosmic.check")
local child = require("cosmic.child")
local cfd = require("cosmic.fd")
local fs = require("cosmic.fs")

local lua_bin = fs.join(os.getenv("TEST_BIN"), "cosmic")
local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local WRONLY_CREAT_TRUNC = cfd.O_WRONLY | cfd.O_CREAT | cfd.O_TRUNC

--- Run `script` under a fresh cosmic with its stdout redirected to
--- `outfile`, and return (result, file contents). The script receives
--- the cosmic path as arg[1] so it can spawn a grandchild.
local function run_capturing(name: string, src: string): child.Result, string
  local script = fs.join(TEST_TMPDIR, name .. ".lua")
  fs.write(script, src)
  local outfile = fs.join(TEST_TMPDIR, name .. ".out")
  local out_h = check.must(cfd.open(outfile, WRONLY_CREAT_TRUNC, tonumber("644", 8)))
  local h = check.must(child.spawn({lua_bin, script, lua_bin},
      {stdout = out_h}))
  local r = check.must(h:wait())
  out_h:close()
  -- parenthesised: must forwards extra returns, which would overflow
  -- this function's declared two
  return r, (check.must(fs.read(outfile)))
end

--- The core claim: an inherited stream reaches the real descriptor, and
--- precisely because it does, spawn cannot also capture it -- so the
--- matching Result field is empty. Both halves are asserted together
--- so neither can drift from the documented contract.
local function test_inherit_reaches_the_real_descriptor()
  local r, written = run_capturing("inherit_child", [[
local child = require("cosmic.child")
local h = assert(child.spawn({arg[1], "-e", "print('MARKER')"},
  {stdout = "inherit"}))
local r = assert(h:wait())
io.stderr:write("captured=[" .. (r.stdout or "") .. "]\n")
]])
  assert(r.ok, "helper failed: " .. (r.stderr or ""))
  assert(written:find("MARKER", 1, true),
    "inherited stdout must reach the real descriptor, file was: " .. written)
  assert(r.stderr:find("captured=[]", 1, true),
    "an inherited stream must leave Result.stdout empty, got: " .. r.stderr)
end
test_inherit_reaches_the_real_descriptor()

--- spawn must not close an inherited descriptor. This is the hazard the
--- old fd.wrap(1) workaround carried: if spawn closed what it was
--- handed, the parent's next write would hit a closed fd -- and worse,
--- a later open() could recycle fd 1. The second write below is the
--- observable.
local function test_inherit_leaves_our_descriptor_open()
  local r, written = run_capturing("inherit_reuse", [[
local child = require("cosmic.child")
local h = assert(child.spawn({arg[1], "-e", "print('FIRST')"},
  {stdout = "inherit"}))
assert(h:wait())
io.write("STILL_OPEN\n")
io.stdout:flush()
]])
  assert(r.ok, "helper failed: " .. (r.stderr or ""))
  assert(written:find("FIRST", 1, true),
    "the child's inherited write is missing: " .. written)
  assert(written:find("STILL_OPEN", 1, true),
    "spawn must not close an inherited descriptor, file was: " .. written)
end
test_inherit_leaves_our_descriptor_open()

--- stderr = "inherit" is wired to fd 2, not fd 1. A copy-paste that
--- resolved both to 1 would still pass the tests above, so this one
--- checks the streams stay distinct: the grandchild writes only to
--- stderr, and that must NOT land in the helper's redirected stdout.
local function test_inherit_stderr_is_separate_from_stdout()
  local r, written = run_capturing("inherit_stderr", [[
local child = require("cosmic.child")
local h = assert(child.spawn(
  {arg[1], "-e", "io.stderr:write('ERRMARK')"},
  {stderr = "inherit"}))
local r = assert(h:wait())
io.stderr:write("captured=[" .. (r.stderr or "") .. "]\n")
]])
  assert(r.ok, "helper failed: " .. (r.stderr or ""))
  assert(not written:find("ERRMARK", 1, true),
    "inherited stderr must not reach fd 1, stdout file was: " .. written)
  assert(r.stderr:find("ERRMARK", 1, true),
    "inherited stderr should reach our stderr, got: " .. r.stderr)
  assert(r.stderr:find("captured=[]", 1, true),
    "an inherited stream must leave Result.stderr empty, got: " .. r.stderr)
end
test_inherit_stderr_is_separate_from_stdout()

--- The default is unchanged: with no disposition given, spawn still
--- captures into Result rather than leaking to our streams.
local function test_default_still_captures()
  local r, written = run_capturing("inherit_default", [[
local child = require("cosmic.child")
local h = assert(child.spawn({arg[1], "-e", "print('CAPTURED')"}))
local r = assert(h:wait())
io.stderr:write("got=[" .. (r.stdout or ""):gsub("%s+$", "") .. "]\n")
]])
  assert(r.ok, "helper failed: " .. (r.stderr or ""))
  assert(not written:find("CAPTURED", 1, true),
    "a captured stream must not reach fd 1, file was: " .. written)
  assert(r.stderr:find("got=[CAPTURED]", 1, true),
    "the default must still capture into Result.stdout, got: " .. r.stderr)
end
test_default_still_captures()
