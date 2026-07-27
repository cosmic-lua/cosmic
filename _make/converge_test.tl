#!/usr/bin/env cosmic
-- Convergence: a project that builds its own toolchain gates under it.
--
-- The unit under test is the DECISION, not the re-exec: whether this
-- project is a cosmic, and whether the artifact moved. The re-exec
-- itself is exercised end to end by every gate this repo runs.

local check = require("cosmic.check")
local converge = require("_make.converge")
local fs = require("cosmic.fs")
local project = require("_make.project")
local types = require("_make.types")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- A scanned project from a file map.
local function scan(name: string, files: {string: string}): types.Project
  local root = fs.join(tmpdir, "converge-" .. name)
  fs.rmrf(root)
  assert(fs.makedirs(root))
  for rel, body in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.makedirs(fs.dirname(path)))
    assert(fs.write(path, body))
  end
  -- Bound before must(): scan returns more than one value, and a
  -- multi-return call spreads into the parameter list it sits in.
  local scanned = project.scan(root)
  local proj = check.must(scanned)
  return proj
end

-- Both halves have to be true. A project with a `cosmic/` package is
-- not a toolchain unless it also ships a cosmic, and a project that
-- ships a binary called `cosmic` is not one unless it defines the
-- namespace -- rebuilding either before a gate is a rule nobody asked
-- for.
local function test_only_a_cosmic_converges()
  local plain = scan("plain", {
      ["main.tl"] = "print('x')\n",
      ["lib.tl"] = "return {}\n",
    })
  assert(not converge.toolchain_of(plain),
    "an ordinary project has no toolchain to converge on")

  local vendored = scan("vendored", {
      ["main.tl"] = "print('x')\n",
      ["cosmic/init.tl"] = "return {}\n",
    })
  assert(not converge.toolchain_of(vendored),
    "defining the namespace without shipping a cosmic is not a toolchain")

  local tool = scan("tool", {
      ["cmd/cosmic/main.tl"] = "print('x')\n",
      ["cosmic/init.tl"] = "return {}\n",
    })
  local found = converge.toolchain_of(tool)
  assert(found, "a project that defines cosmic/ and builds cosmic is one")
  assert((found as types.Binary).name == "cosmic", -- cast: guard above
    "and it is the binary the gate would run under")
end
test_only_a_cosmic_converges()

-- Every refusal names ITSELF. The verdict line is the record that
-- survives a truncated log, so "not a fixpoint" -- which means the
-- build oscillates -- must not be what an ordinary type error reports.
local function test_refusals_name_which_one_they_are()
  local tool = scan("why", {
      ["cmd/cosmic/main.tl"] = "print('x')\n",
      ["cosmic/init.tl"] = "return {}\n",
    })
  local ok, err, why = converge.to_the_tree(tool, {"check"},
    "/nonexistent/cosmic")
  assert(not ok, "a build that cannot run must refuse")
  assert(why == "build failed",
    "an unrunnable build is not an oscillation, got: " .. tostring(why))
  assert(err ~= "", "and says so")
end
test_refusals_name_which_one_they_are()

-- The probe grades the ANSWER, not the exit status.
--
-- Exiting 0 on argv you do not recognise is an ordinary CLI shape --
-- print usage, succeed -- and the `print('x')` main above is exactly
-- it. Accept exit 0 and such a binary gets re-exec'd with the whole
-- gate argv, prints something, exits 0, and the gate reports success
-- having run nothing. That is worse than a traceback, because a
-- traceback is visible.
local function test_the_probe_reads_the_answer()
  local engine = fs.join(os.getenv("TEST_BIN") or "", "cosmic")
  if not check.needs("a built cosmic at " .. engine, fs.isfile(engine)) then
    os.exit(check.EXIT_SKIP)
  end
  assert(converge.drives_a_build(engine),
    "the real engine answers `--make help`")

  -- A look-alike: succeeds, says nothing an engine says.
  local dir = fs.join(tmpdir, "converge-probe")
  fs.rmrf(dir)
  assert(fs.makedirs(dir))
  local fake = fs.join(dir, "lookalike")
  assert(fs.write(fake, "#!/bin/sh\necho 'usage: lookalike [options]'\nexit 0\n"))
  assert(fs.chmod(fake, tonumber("755", 8) as integer)) -- cast: octal literal
  assert(not converge.drives_a_build(fake),
    "a binary that exits 0 without answering is not an engine")

  -- And one that never answers at all does not hang the gate.
  local reader = fs.join(dir, "reader")
  assert(fs.write(reader, "#!/bin/sh\ncat > /dev/null\nexit 0\n"))
  assert(fs.chmod(reader, tonumber("755", 8) as integer)) -- cast: octal literal
  assert(not converge.drives_a_build(reader),
    "a binary that reads stdin gets EOF and still fails the probe")

  assert(not converge.drives_a_build(fs.join(dir, "nothing-here")),
    "and a path that is not a program is not an engine")
end
test_the_probe_reads_the_answer()
