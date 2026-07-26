#!/usr/bin/env cosmic
local unveil = require("cosmic.unveil")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local check = require("cosmic.check")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(unveil.allow) == "function", "allow should be a function")
  assert(type(unveil.commit) == "function", "commit should be a function")
  assert(type(unveil.available) == "function", "available should be a function")
  assert(type(unveil.apply) == "function", "apply (compat shim) should be a function")
end
test_module_exports()

local function test_available_returns_boolean()
  local v = unveil.available()
  assert(type(v) == "boolean", "available() should return a boolean, got " .. type(v))
end
test_available_returns_boolean()

-- Fail-closed contract: on a host without a backing sandbox (no
-- landlock, not OpenBSD), allow/commit/apply must report failure
-- instead of pretending a sandbox exists — the raw libc call succeeds
-- there while enforcing nothing. The unsupported branch never reaches
-- the syscall, so this is safe in-process. best_effort is the explicit
-- opt-in to fail-open behavior.
local function test_fail_closed_when_unavailable()
  if unveil.available() then
    check.skip("unveil available on this host; fail-closed path not exercisable")
    return
  end
  local dir = fs.join(tmpdir, "fc")
  fs.makedirs(dir)
  local ok, err = unveil.allow(dir, "r")
  assert(not ok, "allow must fail when unveil is unsupported")
  assert(type(err) == "string" and err:match("unsupported"),
    "error should say unsupported: " .. tostring(err))
  local cok, cerr = unveil.commit()
  assert(not cok and type(cerr) == "string" and cerr:match("unsupported"),
    "commit must fail-closed too: " .. tostring(cerr))
  local aok, aerr = unveil.apply(dir, "r")
  assert(not aok and type(aerr) == "string" and aerr:match("unsupported"),
    "apply (compat) must fail-closed too: " .. tostring(aerr))
  assert(unveil.allow(dir, "r", {best_effort = true}),
    "best_effort must turn unsupported allow into a successful no-op")
  assert(unveil.commit({best_effort = true}),
    "best_effort must turn unsupported commit into a successful no-op")
end
test_fail_closed_when_unavailable()

-- Unveil only a sub-directory, then confirm both that the unveiled file
-- reads AND that a sibling file left outside the unveil is hidden. Both
-- files exist, so the denial is a genuine unveil effect, not a missing
-- path. Runs only where available() is true (OpenBSD natively, Linux
-- with landlock backing); there a successful commit means enforcement
-- is real, so a leaking sibling is a hard failure — no hedge.
local function test_unveil_restricts_paths()
  if not unveil.available() then
    -- The fail-closed contract for this host is asserted above.
    check.skip("unveil unavailable on this host (no landlock, not OpenBSD)")
    return
  end

  local allowed_dir = fs.join(tmpdir, "vis")
  fs.makedirs(allowed_dir)
  local allowed_file = fs.join(allowed_dir, "unveiled.txt")
  local hidden_file = fs.join(tmpdir, "secret.txt")
  fs.write(allowed_file, "visible")
  fs.write(hidden_file, "secret")

  local script = fs.join(tmpdir, "unveil_test.lua")
  fs.write(script, string.format([[
local unveil = require("cosmic.unveil")
local ok, err = unveil.allow(%q, "r")
if not ok then
  io.write("unveil-blocked: allow failed: " .. tostring(err) .. "\n")
  os.exit(0)
end
ok, err = unveil.commit()
if not ok then
  io.write("unveil-blocked: commit failed: " .. tostring(err) .. "\n")
  os.exit(0)
end
local f = io.open(%q, "r")
if f then
  local content = f:read("*a")
  f:close()
  io.write("read:" .. content .. "\n")
else
  io.write("read:failed\n")
end
local g = io.open(%q, "r")
if g then
  g:close()
  io.write("denied-leaked\n")
else
  io.write("denied-blocked\n")
end
]], allowed_dir, allowed_file, hidden_file))

  local h = check.must(spawn.spawn({cosmic, script}))
  local __r1 = check.must(h:wait())
  local ok, out = __r1.ok, __r1.stdout
  local s = out or ""
  -- Plain-text find of the distinct setup marker: the success marker
  -- "denied-blocked" must not match here.
  if s:find("unveil-blocked:", 1, true) then
    -- available() was true yet the call failed: an outer sandbox
    -- pre-empted an otherwise-supported mechanism. Strict: a hard
    -- failure on the enforce lane.
    check.skip("unveil blocked by an outer sandbox: " .. s, true)
    return
  end
  assert(ok, "unveil subprocess should exit cleanly: " .. s)
  assert(s:find("read:visible"), "should read unveiled file: " .. s)
  -- available() is true and commit succeeded, so enforcement must be
  -- real: a visible sibling is a fail-open bug, never a skip.
  assert(s:find("denied%-blocked"),
    "expected denial of the non-unveiled sibling: " .. s)
  check.enforced("unveil")
end
test_unveil_restricts_paths()
