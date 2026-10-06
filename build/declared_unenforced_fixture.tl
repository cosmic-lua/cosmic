--- What build/declared_unenforced_test.tl and
--- build/declared_sandboxed_test.tl share: a suite of two tests, and the
--- runs of `cosmic test` on it that key each verdict by what its test
--- declares. Test support.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Clock = require("cosmic.clock")

local record declared_unenforced_fixture
  --- How a run ended and what it printed.
  record Run
    code: integer
    text: string
  end
end

--- Writes a checkout of the suite at `root`: a test that reads a declared
--- directory, and one that reads a declared variable and finds one it
--- does not declare unset, though the run has it.
function declared_unenforced_fixture.checkout(root: string)
  assert(Fs.mkdirs(root .. "/suite/data"))
  assert(Fs.write(root .. "/suite/data/f", "one\n"))
  assert(Fs.write(root .. "/suite/data_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy { grants = { { path = "suite/data/", letters = "r" } } }

local function test_data()
  assert(Fs.read("suite/data/f") ~= nil)
end
]]))
  assert(Fs.write(root .. "/suite/env_test.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy { env = { "FLAVOUR", "OUTER_TMPDIR" } }

local function test_env()
  assert(Env.get("FLAVOUR") == "sweet", tostring(Env.get("FLAVOUR")))
  assert(Env.get("UNDECLARED") == nil, "a variable it does not declare reached it")
  -- Unenforced (OUTER_TMPDIR set), TMPDIR is its own scratch directory:
  -- not the run's, nor the /tmp a sandbox would give it, and it may
  -- write there.
  local outer = Env.get("OUTER_TMPDIR")
  if outer ~= nil then
    local temporary = Env.get("TMPDIR")
    assert(temporary ~= nil and temporary ~= outer and temporary ~= "/tmp",
      "TMPDIR is " .. tostring(temporary) .. ", the run's " .. outer)
    assert(Fs.write(temporary .. "/written", "x"))
  end
end
]]))
end

--- The environment an unenforced run of the suite is started with, its
--- shared cache at `cache`: unsandboxed, keyed by declarations, with
--- a variable no test declares, and the run's own TMPDIR, which a
--- worker's is not.
function declared_unenforced_fixture.environment(cache: string): {string:string}
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = cache
  env.COSMIC_TEST_SANDBOX = "0"
  env.FLAVOUR = "sweet"
  env.UNDECLARED = "leaked"
  env.OUTER_TMPDIR = env.TMPDIR or "/tmp"
  return env
end

--- Runs `cosmic test` on `root`, answering its exit status and what it
--- printed, which must say it started.
function declared_unenforced_fixture.run(root: string, output: string, env: {string:string}): declared_unenforced_fixture.Run
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ns = Clock.seconds(60),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return { code = result.code or -1, text = text }
end

--- A run that must pass and say `wanted`.
function declared_unenforced_fixture.says(root: string, output: string, env: {string:string}, wanted: string): string
  local ran = declared_unenforced_fixture.run(root, output, env)
  local code, text = ran.code, ran.text
  assert(code == 0, text)
  assert(text:find(wanted, 1, true), wanted .. "\n" .. text)
  return text
end

return declared_unenforced_fixture
