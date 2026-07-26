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

-- The TEST fence, same A/B shape. A test's writes belong to its own
-- step: the `test` verb points TMP at a scratch directory beside the
-- step's output, and the derived fence grants that directory and
-- nothing else. So a test reaching for a path outside it is denied.
--
-- This is the canary the plan asked for before the fence can stop being
-- opt-in. It asserts the DENIAL, not the redirection -- the redirection
-- holds on every platform and is covered by an ordinary test; only a
-- kernel can prove the second half.
local function test_the_fence_confines_a_test_to_its_own_step()
  if not sandbox.available().fs then
    check.skip("no landlock on this host; the fence cannot bite")
    return
  end

  local root = fs.join(tmpdir, "testfence")
  assert(fs.makedirs(root))
  local target = fs.join(tmpdir, "test-escaped.txt")
  local script = fs.join(root, "escape.lua")
  assert(fs.write(script,
      "local f = io.open('" .. target .. "', 'w')\n" ..
      "if not f then os.exit(9) end\n" ..
      "f:write('x')\n f:close()\n"))

  local envlist: {string} = {}
  for _, entry in ipairs(env.list()) do
    if not entry:match("^COSMIC_FENCE=") and not entry:match("^TMPDIR=") then
      envlist[#envlist + 1] = entry
    end
  end
  envlist[#envlist + 1] = "TMPDIR=" .. root
  envlist[#envlist + 1] = "COSMIC_FENCE=1"

  -- A: the same script run directly writes the file.
  local direct = check.must(child.run({cosmic, script}, {env = envlist}))
  assert(direct.ok, "the script must succeed unfenced: " .. direct.stderr)
  assert(fs.isfile(target), "unfenced, the write must land")
  assert(fs.unlink(target))

  -- B: through the test verb, whose fence grants only the step's own
  -- output directory. The verb always exits 0 (it records rather than
  -- grades), so the assertion is on the file, not the status.
  local out = fs.join(root, "step", "escape")
  local fenced = check.must(child.run(
      {cosmic, "-c", "test " .. out .. " " .. cosmic .. " " .. script},
      {env = envlist}))
  assert(fenced.ok, "the test verb records rather than grades: " ..
    fenced.stderr)
  assert(not fs.isfile(target),
    "fenced, a test must NOT write outside its own step")
  check.enforced("test fence")
end
test_the_fence_confines_a_test_to_its_own_step()

-- The other half of the canary, and the half that decides when the
-- fence can stop being opt-in: it must PERMIT a real compile.
--
-- A denial test alone cannot tell a correct fence from one that denies
-- everything. The derived grants come from argv, and a type check reads
-- two things argv never names -- `tlconfig.lua` and the include
-- directories modules resolve through -- so without them the fence
-- denied every compile in the tree. That is the concrete reason it
-- stayed `COSMIC_FENCE=1` while the docs presented it as the
-- enforcement story, and this is the assertion that has to pass before
-- the default can flip.
local function test_the_fence_permits_a_real_compile()
  if not sandbox.available().fs then
    check.skip("no landlock on this host; the fence cannot bite")
    return
  end

  local dir = fs.join(tmpdir, "compilefence")
  assert(fs.makedirs(fs.join(dir, "pkg")))
  -- Two files, so the compile resolves an import through the include
  -- path rather than only reading the file it was handed.
  assert(fs.write(fs.join(dir, "pkg", "greet.tl"),
      "local record G\n  hi: function(): string\nend\n" ..
      "local M: G = {hi = function(): string return 'hi' end}\nreturn M\n"))
  local source = fs.join(dir, "main.tl")
  assert(fs.write(source,
      "local g = require('pkg.greet')\nprint(g.hi())\n"))
  local built = fs.join(dir, "o", "main.lua")

  local permitted: {string} = {}
  for _, entry in ipairs(env.list()) do
    if not entry:match("^COSMIC_FENCE=") then
      permitted[#permitted + 1] = entry
    end
  end
  permitted[#permitted + 1] = "COSMIC_FENCE=1"

  local r = check.must(child.run({cosmic, "-c",
        "compile " .. cosmic .. " " .. source .. " " .. built ..
        " --include-dir " .. dir}, {cwd = dir, env = permitted}))
  assert(r.ok, "a real compile must SUCCEED under the fence; a fence " ..
    "that denies everything is not enforcement: " .. r.stderr)
  assert(fs.isfile(built), "…and produce its output")
  check.enforced("recipe fence permits a compile")
end
test_the_fence_permits_a_real_compile()
