--- What a spawned child resolves its requires against.
---
--- The behavioural half of docs/design/make/resolution.md, run against
--- fixture projects with their own roots rather than against this one:
--- the claims are about ANY project, and asserting them here would let
--- a rule that only holds for cosmic pass.
---
--- Every assertion reads a `debug.getinfo(f, "S").source`, which is the
--- only thing that answers "which bytes ran" without trusting the
--- thing under test to report on itself.

local check = require("cosmic.check")
local cenv = require("cosmic.env")
local fs = require("cosmic.fs")
local mk = require("_make")
local spawn = require("cosmic.child")

local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmp = os.getenv("TEST_TMPDIR") or "/tmp"

--- A fixture project with one package and one test that reports where
--- its import came from.
--- @param name string A directory name unique to the caller
--- @return string The project root
local function fixture(name: string): string
  local root = fs.join(tmp, "res-" .. name)
  fs.rmrf(root)
  assert(fs.makedirs(fs.join(root, "greet")))
  -- The run target is a binary at cmd/app/, so `run` builds it before
  -- executing o/cmd/app/main.lua; a bare root main.tl is refused. Tests
  -- write the entry's body here.
  assert(fs.makedirs(fs.join(root, "cmd", "app")))
  assert(fs.write(fs.join(root, ".cosmicignore"), ""))
  assert(fs.write(fs.join(root, "greet", "init.tl"), [[
local record G
  hi: function(string): string
end
local g: G = {hi = function(who: string): string return "hi " .. who end}
return g
]]))
  return root
end

--- Run `--make <argv…>` in `root`, returning code and combined output.
--- @param root string The project root
--- @param argv {string} The `--make` arguments
--- @param extra? {string} Extra `NAME=VALUE` environment entries
--- @return integer Exit code
--- @return string stdout .. stderr
local function make(root: string, argv: {string},
    extra?: {string}): integer, string
  local full: {string} = {cosmic, "--make"}
  for _, a in ipairs(argv) do
    full[#full + 1] = a
  end
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "HOME=" .. root,
    "TMPDIR=" .. tmp,
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
  }
  for _, e in ipairs(extra or {}) do
    env[#env + 1] = e
  end
  local h = check.must(spawn.spawn(full, {cwd = root, env = env}))
  local r = check.must(h:wait())
  return r.code or 128, (r.stdout or "") .. (r.stderr or "")
end

-- The failure this exists to kill: a test scheduled and fenced against
-- `o/greet/init.lua` that loads `./greet/init.tl` instead -- the
-- source, lax-compiled -- is a test the graph's own output never
-- reaches.
local function test_a_test_loads_what_the_graph_built()
  local root = fixture("built")
  assert(fs.write(fs.join(root, "greet", "greet_test.tl"), [[
local greet = require("greet")
local function test_source()
  io.stderr:write("FROM " .. debug.getinfo(greet.hi, "S").source .. "\n")
end
test_source()
]]))
  local code, out = make(root, {"test"})
  assert(code == 0, "the fixture must pass: " .. out)
  -- A test's own output is CAPTURED by the runner, so the evidence is
  -- in its `.err` file rather than on the outer run's stderr.
  local captured = check.must(fs.read(fs.join(root, "o", "greet",
        "greet_test.tl.test.err")))
  local from = captured:match("FROM @(%S+)")
  assert(from, "the test must report its import's source: " .. captured)
  assert(from:find("/o/greet/init.lua", 1, true),
    "a test must load the graph's output, got: " .. from)
end
test_a_test_loads_what_the_graph_built()

-- `run` takes a path, and what it runs resolves against the tree. The
-- computed require is the interesting half: `require(name)` off argv is
-- invisible to the import scanner, so no closure names it and the
-- searcher has to find it in the project itself.
local function test_run_resolves_a_computed_require()
  local root = fixture("run")
  assert(fs.write(fs.join(root, "cmd/app/main.tl"), [[
local mod = require(arg[1]) as {string: function}
io.write("FROM " .. debug.getinfo(mod.hi, "S").source .. "\n")
]]))
  local code, out = make(root, {"run", "cmd/app/main.tl", "greet"})
  assert(code == 0, "run must succeed: " .. out)
  local from = out:match("FROM @(%S+)")
  assert(from, "the target must report its import's source: " .. out)
  assert(from:find(root, 1, true),
    "a computed require must resolve inside the project, got: " .. from)
end
test_run_resolves_a_computed_require()

-- `run` is a passthrough: the target's flags are the target's, and its
-- exit code is what the caller sees.
local function test_run_passes_argv_and_exit_code_through()
  local root = fixture("argv")
  assert(fs.write(fs.join(root, "cmd/app/main.tl"), [[
io.write("ARGS " .. table.concat(arg, " ") .. "\n")
os.exit(7)
]]))
  local code, out = make(root, {"run", "cmd/app/main.tl", "--out", "x", "-v"})
  assert(out:find("ARGS --out x -v", 1, true),
    "the target's own flags must arrive verbatim: " .. out)
  assert(code == 7, "the target's exit code is the verb's, got: " .. code)
end
test_run_passes_argv_and_exit_code_through()

-- A binary NAME is the rejected `run [binary]` spelling, so it is the
-- one wrong guess worth a sentence rather than "no such selection".
local function test_run_refuses_a_binary_name()
  local root = fixture("name")
  assert(fs.write(fs.join(root, "cmd/app/main.tl"), 'io.write("x")\n'))
  local code, out = make(root, {"run", "app"})
  assert(code ~= 0, "a binary name must be refused: " .. out)
  assert(out:find("takes a path, not a binary name", 1, true) or
    out:find("no such source", 1, true), "got: " .. out)
end
test_run_refuses_a_binary_name()

-- The resolution is per-invocation, in argv, and a GRANDCHILD does not
-- get it. That is the whole reason the channel is a flag and not an
-- environment variable: ten `_make/*_test.tl` files spawn a cosmic
-- against a different project root, and an inherited path would answer
-- their imports out of THIS tree while they build something else.
--
-- Asserted at the mechanism rather than by nesting a second build: the
-- target runs under `--make run`, so it resolves `greet` from
-- `o/greet/init.lua`; it then spawns a plain `cosmic` with its OWN
-- environment entire, and that one must fall back to compiling
-- `./greet/init.tl` from source. Same import, same environment, two
-- answers -- which is only possible if nothing was inherited.
local function test_resolution_does_not_inherit()
  local root = fixture("inherit")
  assert(fs.write(fs.join(root, "child.tl"), [[
local greet = require("greet")
io.write("CHILD " .. debug.getinfo(greet.hi, "S").source .. "\n")
]]))
  assert(fs.write(fs.join(root, "cmd/app/main.tl"), [[
local greet = require("greet")
local spawn = require("cosmic.child")
local check = require("cosmic.check")
io.write("PARENT " .. debug.getinfo(greet.hi, "S").source .. "\n")
local h = check.must(spawn.spawn({arg[0] and os.getenv("COSMIC_BIN"), "child.tl"}))
local r = check.must(h:wait())
io.write(r.stdout or "")
]]))
  local code, out = make(root, {"run", "cmd/app/main.tl"}, {"COSMIC_BIN=" .. cosmic})
  assert(code == 0, "the fixture must run: " .. out)
  local parent = out:match("PARENT @(%S+)")
  local child = out:match("CHILD @(%S+)")
  assert(parent and child, "both must report a source: " .. out)
  assert(parent:find("/o/greet/init.lua", 1, true),
    "the target resolves against the build, got: " .. parent)
  assert(child:find("greet/init.tl", 1, true) and
    not child:find("/o/", 1, true),
    "a grandchild must NOT inherit the resolution, got: " .. child)
end
test_resolution_does_not_inherit()

-- The same verb through the module API, which is the other calling
-- convention and the only one this process can see: every case above
-- runs `run` in a subprocess, where the coverage lane never watches it.
local function test_run_in_process()
  local root = fixture("inproc")
  assert(fs.write(fs.join(root, "cmd/app/main.tl"), [[
local greet = require("greet")
io.write("SAYS " .. greet.hi("x") .. "\n")
]]))
  local cwd = check.must(fs.getcwd())
  cenv.set("COSMIC_MAKE_ROOT", root)
  local code = mk.run({"run", "cmd/app/main.tl"})
  cenv.unset("COSMIC_MAKE_ROOT")
  assert(fs.chdir(cwd))
  assert(code == 0, "an in-process run should succeed")
end
test_run_in_process()

-- And its refusals, which are the pre-flight `_make.law` runs before
-- anything is built -- so they cost a walk rather than a rebuild.
local function test_run_refusals_in_process()
  local root = fixture("refuse")
  assert(fs.write(fs.join(root, "cmd/app/main.tl"), 'io.write("x")\n'))
  local cwd = check.must(fs.getcwd())
  cenv.set("COSMIC_MAKE_ROOT", root)
  local none = mk.run({"run"})
  local missing = mk.run({"run", "nosuch.tl"})
  local flag_first = mk.run({"run", "--out", "x"})
  local two = mk.run({"run", "cmd/app/main.tl", "greet/init.tl"})
  cenv.unset("COSMIC_MAKE_ROOT")
  assert(fs.chdir(cwd))
  assert(none ~= 0, "run with no path must fail")
  assert(missing ~= 0, "run with a path that names nothing must fail")
  assert(flag_first ~= 0, "a flag before the path must fail")
  -- Two paths is not an error: the second is the target's own argument,
  -- which is what passthrough MEANS.
  assert(two == 0, "the second path belongs to the target")
end
test_run_refusals_in_process()

print("all resolution tests passed")
