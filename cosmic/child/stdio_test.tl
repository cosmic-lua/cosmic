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
  local h = check.must(child.start({lua_bin, script, lua_bin},
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
local h = assert(child.start({arg[1], "-e", "print('MARKER')"},
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
local h = assert(child.start({arg[1], "-e", "print('FIRST')"},
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
local h = assert(child.start(
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
local h = assert(child.start({arg[1], "-e", "print('CAPTURED')"}))
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

--- The dup2-ordering hazard: stdout is captured (the default, a pipe)
--- while stderr is routed to fd.wrap(1) -- what is CURRENTLY the
--- grandchild's own real fd 1. Fixed 0->1->2 wiring dup2's the capture
--- pipe onto fd 1 first; reading fd 1 again for stderr's dup2(1, 2) then
--- reads the PIPE, not the real fd 1, so a fix that regressed would
--- route the grandchild's stderr into Result.stdout instead of the real
--- descriptor. Both halves are asserted: fd.wrap(1) must still reach the
--- real fd 1, and Result.stdout must hold only the grandchild's stdout.
local function test_stderr_fd_wrap_does_not_clobber_captured_stdout()
  local r, written = run_capturing("swap_stderr", [[
local child = require("cosmic.child")
local cfd = require("cosmic.fd")
local h = assert(child.start({"sh", "-c", "echo OUT; echo ERR >&2"},
  {stderr = cfd.wrap(1)}))
local r = assert(h:wait())
io.stderr:write("stdout=[" .. (r.stdout or "") .. "]\n")
]])
  assert(r.ok, "helper failed: " .. (r.stderr or ""))
  assert(written:find("ERR", 1, true),
    "stderr routed via fd.wrap(1) must reach the real fd 1, file was: " .. written)
  assert(not written:find("OUT", 1, true),
    "the captured stdout must not also reach the real fd 1, file was: " .. written)
  assert(r.stderr:find("stdout=[OUT\n]", 1, true),
    "Result.stdout must hold only the grandchild's stdout, got: " .. r.stderr)
end
test_stderr_fd_wrap_does_not_clobber_captured_stdout()

--- The full swap: stdout AND stderr each point at what the OTHER
--- started as. A fix that only handled the single-alias case above
--- (stderr = fd.wrap(1)) could still misroute a swap, since both
--- targets alias a std fd the other's wiring is about to overwrite.
local function test_full_stdio_swap_routes_each_stream_correctly()
  local r, written = run_capturing("swap_full", [[
local child = require("cosmic.child")
local cfd = require("cosmic.fd")
local h = assert(child.start({"sh", "-c", "echo OUT; echo ERR >&2"},
  {stdout = cfd.wrap(2), stderr = cfd.wrap(1)}))
local r = assert(h:wait())
io.stderr:write("stdout=[" .. (r.stdout or "") .. "] stderr=[" ..
  (r.stderr or "") .. "]\n")
]])
  assert(r.ok, "helper failed: " .. (r.stderr or ""))
  -- `written` is the file behind the helper's own real fd 1, which
  -- stderr = fd.wrap(1) targets; the helper's own real fd 2, which
  -- stdout = fd.wrap(2) targets, is what the OUTER spawn (run_capturing)
  -- itself captures into r.stderr here.
  assert(written:find("ERR", 1, true),
    "stderr = fd.wrap(1) should route the grandchild's stderr onto the " ..
    "real fd 1, but it is missing from the file: " .. written)
  assert(not written:find("OUT", 1, true),
    "stdout must not also reach the real fd 1, file was: " .. written)
  assert(r.stderr:find("OUT", 1, true),
    "stdout = fd.wrap(2) should route the grandchild's stdout into our " ..
    "own captured stderr, got: " .. r.stderr)
  assert(r.stderr:find("stdout=[] stderr=[]", 1, true),
    "spawn captured neither stream once both were redirected via " ..
    "fd.wrap, but got: " .. r.stderr)
end
test_full_stdio_swap_routes_each_stream_correctly()
