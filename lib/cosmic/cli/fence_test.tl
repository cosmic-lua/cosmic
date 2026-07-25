#!/usr/bin/env cosmic
-- The recipe fence, proven against a real kernel.
--
-- Lives in the enforce lane (bin/make enforce) rather than the ordinary
-- test lane for the reason that lane exists: under CI's own
-- landlock-make sandbox an enforcement assertion degrades to a no-op
-- and everything looks green. Here the outer sandbox is dropped,
-- COSMIC_ENFORCE=1 is set, and the tripwire counts the enforce-ran
-- marker, so "the fence never actually ran" cannot pass for success.
--
-- What it asserts is a denial, A/B on one script so a failure cannot be
-- mistaken for the write being impossible anyway: unfenced the script
-- writes its file, fenced it must not. TMPDIR and the exec root both
-- point inside <tmp>/root, which leaves <tmp>/outside.txt reachable to
-- the unfenced run and outside the fence for the other.

local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local sandbox = require("cosmic.sandbox")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local cosmic = fs.join(os.getenv("TEST_BIN") or "", "cosmic")

local function test_the_fence_denies_an_undeclared_write()
  if not sandbox.available().fs then
    -- Not strict: without Landlock there is no mechanism to block an
    -- otherwise-supported operation, so this is a host limitation
    -- rather than an outer sandbox to blame.
    check.skip("no landlock on this host; the fence cannot bite")
    return
  end

  local root = fs.join(tmpdir, "root")
  assert(fs.makedirs(root))
  local target = fs.join(tmpdir, "outside.txt")
  local script = fs.join(root, "write-outside.lua")
  assert(fs.write(script,
      "local f = io.open('" .. target .. "', 'w')\n" ..
      "if not f then os.exit(9) end\n" ..
      "f:write('x')\n f:close()\n"))

  local envlist: {string} = {}
  for _, entry in ipairs(env.list()) do
    if not entry:match("^TMPDIR=") and not entry:match("^COSMIC_EXEC_ROOT=")
    and not entry:match("^COSMIC_FENCE=") then
      envlist[#envlist + 1] = entry
    end
  end
  envlist[#envlist + 1] = "TMPDIR=" .. root
  envlist[#envlist + 1] = "COSMIC_EXEC_ROOT=" .. fs.dirname(fs.abspath(cosmic))
  envlist[#envlist + 1] = "COSMIC_FENCE=1"

  -- A: unfenced, the write lands.
  local direct = check.must(child.run({cosmic, script}, {env = envlist}))
  assert(direct.ok, "the script must succeed unfenced: " .. direct.stderr)
  assert(fs.isfile(target), "unfenced, the write must land")
  assert(fs.unlink(target))

  -- B: the same script under exec's fence, which does not reach it.
  local fenced = check.must(child.run(
      {cosmic, "-c", "exec " .. cosmic .. " " .. script}, {env = envlist}))
  assert(not fenced.ok, "the fenced write must fail")
  assert(not fs.isfile(target),
    "fenced, the write must NOT land (fence did not deny)")
  check.enforced("recipe fence")
end
test_the_fence_denies_an_undeclared_write()
