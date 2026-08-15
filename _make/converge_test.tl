#!/usr/bin/env cosmic
-- Convergence: a project that builds its own toolchain gates under it.
--
-- The unit under test is the DECISION, not the re-exec: whether this
-- project is a cosmic, and whether the artifact moved. The re-exec
-- itself is exercised end to end by every gate this repo runs.

local check = require("cosmic.check")
local cenv = require("cosmic.env")
local converge = require("_make.converge")
local fs = require("cosmic.fs")
local help = require("_make.help")
local project = require("_make.project")
local types = require("_make.types")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- A scanned project from a file map.
local function scan(name: string, files: {string: string}): types.Project
  local root = fs.join(tmpdir, "converge-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for rel, body in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.make_dirs(fs.dirname(path)))
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
  assert(found.name == "cosmic",
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
  check.needs("a built cosmic at " .. engine, fs.is_file(engine))
  assert(converge.drives_a_build(engine),
    "the real engine answers `--make help`")

  -- A look-alike: succeeds, says nothing an engine says.
  local dir = fs.join(tmpdir, "converge-probe")
  assert(fs.remove_all(dir))
  assert(fs.make_dirs(dir))
  local fake = fs.join(dir, "lookalike")
  assert(fs.write(fake, "#!/bin/sh\necho 'usage: lookalike [options]'\nexit 0\n"))
  assert(fs.set_mode(fake, tonumber("755", 8) as integer)) -- cast: octal literal
  assert(not converge.drives_a_build(fake),
    "a binary that exits 0 without answering is not an engine")

  -- And one that never answers at all does not hang the gate.
  local reader = fs.join(dir, "reader")
  assert(fs.write(reader, "#!/bin/sh\ncat > /dev/null\nexit 0\n"))
  assert(fs.set_mode(reader, tonumber("755", 8) as integer)) -- cast: octal literal
  assert(not converge.drives_a_build(reader),
    "a binary that reads stdin gets EOF and still fails the probe")

  assert(not converge.drives_a_build(fs.join(dir, "nothing-here")),
    "and a path that is not a program is not an engine")
end
test_the_probe_reads_the_answer()

-- The probe's mark and what `--make help` actually prints are the SAME
-- constant (`_make.help`'s PROBE_MARK), never two copies that could
-- drift apart silently. This is the structural guarantee behind
-- test_the_probe_reads_the_answer's real-engine assertion above.
local function test_the_probe_mark_is_help_usages_own_constant()
  assert(help.usage():find(help.PROBE_MARK, 1, true) ~= nil,
    "usage() must print the exact mark the probe greps for")
end
test_the_probe_mark_is_help_usages_own_constant()

-- The outcomes below are the ones that only happen when something has
-- already gone wrong, which is why they need arranging rather than
-- observing: `--make ci` in this repo takes the happy path every time.
-- Untested, a regression in them is invisible until it strands a user
-- mid-build -- and `not a fixpoint` is a TERMINATING condition, so its
-- failure mode is an endless rebuild loop rather than an error.

--- An executable `#!/bin/sh` script at `path`.
local function script(path: string, body: string): string
  assert(fs.make_dirs(fs.dirname(path)))
  assert(fs.write(path, "#!/bin/sh\n" .. body))
  assert(fs.set_mode(path, tonumber("755", 8) as integer)) -- cast: octal literal
  return path
end

--- A scratch directory that is a project root and a working directory.
local function scratch(name: string): string
  local dir = fs.join(tmpdir, "converge-" .. name)
  assert(fs.remove_all(dir))
  assert(fs.make_dirs(dir))
  return dir
end

--- `to_the_tree` with `dir` as the working directory.
---
--- The outcome is a fact about a DIRECTORY: `o/bin/<name>` is resolved
--- against the cwd, and the build runs there. The repo root already
--- holds a real `o/bin/cosmic` and is the fixpoint, so each branch
--- below gets a directory arranged for it.
local function converge_in(dir: string, proj: types.Project,
    self: string): boolean, string, string
  local was = check.must(fs.cwd())
  assert(fs.set_cwd(dir))
  local ok, err, why = converge.to_the_tree(proj, {"check"}, self)
  assert(fs.set_cwd(was))
  return ok, err, why
end

--- A project that declares a toolchain: `cosmic/` plus a `cosmic`.
local function toolchain(name: string): types.Project
  return scan(name, {
      ["cmd/cosmic/main.tl"] = "print('x')\n",
      ["cosmic/init.tl"] = "return {}\n",
    })
end

-- A build that SUCCEEDS and produces nothing. Distinct from "build
-- failed": the exit code says everything went fine, so the only
-- evidence is the missing artifact, and without this branch the next
-- step runs `same_file` against a path that is not there.
local function test_a_build_that_makes_no_artifact_refuses()
  local dir = scratch("no-artifact")
  local self = script(fs.join(dir, "quiet"), "exit 0\n")
  assert(not fs.is_file(fs.join(dir, "o/bin/cosmic")),
    "the fixture must not start with an artifact")

  local ok, err, why = converge_in(dir, toolchain("no-artifact-proj"), self)
  assert(not ok, "a build that produced nothing must refuse")
  assert(why == "no artifact",
    "and name itself, got: " .. tostring(why))
  assert(err:find("o/bin/cosmic", 1, true),
    "naming the artifact it looked for, got: " .. err)
end
test_a_build_that_makes_no_artifact_refuses()

-- The generation cap. This is the branch whose whole purpose is to fail
-- loudly instead of spinning: the build keeps producing a DIFFERENT
-- binary, so every generation re-execs into one that builds another.
-- Reached by starting at the cap, which is what a third generation
-- would inherit.
local function test_a_build_that_never_settles_refuses()
  local dir = scratch("no-fixpoint")
  local self = script(fs.join(dir, "quiet"), "exit 0\n")
  -- An artifact that exists and is not what is running, so the fixpoint
  -- test below cannot fire and the cap is what answers.
  assert(fs.make_dirs(fs.join(dir, "o/bin")))
  assert(fs.write(fs.join(dir, "o/bin/cosmic"), "not the running binary\n"))

  assert(cenv.set("COSMIC_MAKE_GEN", "2", true))
  local ok, err, why = converge_in(dir, toolchain("no-fixpoint-proj"), self)
  assert(cenv.unset("COSMIC_MAKE_GEN"))
  assert(not ok, "a build that never settles must refuse")
  assert(why == "not a fixpoint",
    "and say which refusal it is, got: " .. tostring(why))
  assert(err:find("still changed after", 1, true),
    "saying the artifact kept moving, got: " .. err)
end
test_a_build_that_never_settles_refuses()

-- And the branch that is NOT a refusal. A project that declares a
-- toolchain by two ordinary names -- a `cosmic/` package and a `cosmic`
-- binary -- but whose binary is not an engine carries on under the
-- running one. Refusing here would be the bug wearing a better name:
-- every gate verb would pay a full build and then fail, permanently,
-- for a project whose only mistake was its naming.
local function test_a_look_alike_toolchain_carries_on()
  local dir = scratch("carry-on")
  local self = script(fs.join(dir, "quiet"), "exit 0\n")
  script(fs.join(dir, "o/bin/cosmic"),
    "echo 'usage: mytool [options]'\nexit 0\n")

  assert(cenv.unset("COSMIC_MAKE_GEN"))
  local ok, err = converge_in(dir, toolchain("carry-on-proj"), self)
  assert(ok, "a look-alike must not fail the gate: " .. tostring(err))
end
test_a_look_alike_toolchain_carries_on()
