--- End to end: a sandboxed run keys each verdict by its test's
--- declared inputs (build/declared_key.tl). A verdict stands while
--- nothing declared changes -- whatever else of the tree does -- and in
--- another checkout of the same content, through the shared cache; a
--- test runs again when what it declares changes, always when it
--- declares the network, and every test runs under `--all`. Where this
--- host cannot sandbox a worker, the run says so, and there is nothing
--- more to check.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local observations = require("build.filesystem_observations")
local Test = require("cosmic.test")

--- What a sandboxed run of `cosmic test` needs of the host, and the
--- program it runs.
Test.needs{ host = { "/dev/urandom", "/etc", "/proc", "/usr/" }, tool = true }

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- A checkout of the suite at `root`: a test that reads a declared
--- directory, one that reads a declared variable, one that loads a
--- module of the tree, one that declares the network, and a file
--- nothing declares.
local function checkout(root: string)
  assert(Fs.mkdirs(root .. "/suite/data"))
  assert(Fs.write(root .. "/suite/data/f", "one\n"))
  assert(Fs.write(root .. "/suite/unrelated.txt", "u\n"))
  assert(Fs.write(root .. "/suite/lib.tl", "return { value = 1 }\n"))
  assert(Fs.write(root .. "/suite/data_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/data/" } }

local function test_data()
  assert(Fs.read("suite/data/f") ~= nil)
end
]]))
  assert(Fs.write(root .. "/suite/flavour_test.tl", [[
local Env = require("cosmic.env")
local Test = require("cosmic.test")

Test.needs { env = { "FLAVOUR" } }

local function test_flavour()
  assert(Env.get("FLAVOUR") ~= "sour")
end
]]))
  assert(Fs.write(root .. "/suite/plain_test.tl", [[
local lib = require("suite.lib")

local function test_plain()
  assert(lib.value ~= nil)
end
]]))
  assert(Fs.write(root .. "/suite/net_test.tl", [[
local Test = require("cosmic.test")

Test.needs { network = { "127.0.0.1" } }

local function test_net()
  assert(true)
end
]]))
end

--- The environment a sandboxed run of the suite is started with, its
--- shared cache at `cache`.
local function environment(cache: string): {string:string}
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = cache
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_TEST_NO_SHARED = nil
  env.COSMIC_SANDBOX = nil
  env.COSMIC_TEST_SANDBOX = "1"
  env.FLAVOUR = "sweet"
  return env
end

--- Runs `cosmic test` on `root` with `words` after it, answering what it
--- printed, which must say it passed.
local function run(root: string, output: string, env: {string:string}, words?: {string}): string
  local fd = assert(Fs.open_write(output))
  local argv: {string} = { assert(Proc.executable()), "test" }
  for _, word in ipairs(words or {}) do argv[#argv + 1] = word end
  local result, trouble = Child.run(argv, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ms = 60000,
  })
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil and result.ok, tostring(trouble) .. text)
  return text
end

local function test_a_sandboxed_verdict_stands_until_what_it_declares_changes(tmp: string)
  local root = tmp .. "/root"
  checkout(root)
  local env = environment(tmp .. "/cache/verdicts.db")
  local step = 0
  local function said(wanted: string, words?: {string}): string
    step = step + 1
    local text = run(root, tmp .. "/" .. step .. ".out", env, words)
    assert(text:find(wanted, 1, true), step .. ": " .. text)
    return text
  end
  local first = run(root, tmp .. "/first.out", env)
  if first:find("no worker can be sandboxed here", 1, true) then return end
  assert(first:find("4 ran, 0 stood", 1, true) and first:find("; sandboxed", 1, true), first)
  -- Nothing changed: all but the one that reaches the network stands,
  -- and none is assumed.
  local again = said("1 ran, 3 stood")
  assert(not again:find("assumed", 1, true), again)
  -- A file no test declares.
  assert(Fs.write(root .. "/suite/unrelated.txt", "changed\n"))
  said("1 ran, 3 stood")
  -- A file beneath a declared directory.
  assert(Fs.write(root .. "/suite/data/f", "two\n"))
  said("2 ran, 2 stood")
  -- A module of a test's closure.
  assert(Fs.write(root .. "/suite/lib.tl", "return { value = 2 }\n"))
  said("2 ran, 2 stood")
  -- A declared variable's value.
  env.FLAVOUR = "salty"
  said("2 ran, 2 stood")
  -- The declaration.
  local source = assert(Fs.read(root .. "/suite/data_test.tl"))
  assert(Fs.write(root .. "/suite/data_test.tl",
    (source:gsub('reads = { "suite/data/" }', 'reads = { "suite/data/", "suite/lib.tl" }'))))
  said("2 ran, 2 stood")
  -- Forced.
  said("4 ran, 0 stood", { "--all" })
  env.COSMIC_TEST_ALL = "1"
  said("4 ran, 0 stood")
end

--- A checkout of the same content stands on the verdicts another
--- reached, by their keys alone, and one whose declared input differs
--- runs that test.
local function test_a_sandboxed_verdict_stands_in_another_checkout(tmp: string)
  local env = environment(tmp .. "/cache/verdicts.db")
  checkout(tmp .. "/first")
  local first = run(tmp .. "/first", tmp .. "/first.out", env)
  if first:find("no worker can be sandboxed here", 1, true) then return end
  assert(first:find("4 ran, 0 stood", 1, true), first)
  checkout(tmp .. "/second")
  local second = run(tmp .. "/second", tmp .. "/second.out", env)
  assert(second:find("1 ran, 3 stood, 3 of them on another checkout's verdict", 1, true), second)
  checkout(tmp .. "/third")
  assert(Fs.write(tmp .. "/third/suite/data/f", "three\n"))
  local third = run(tmp .. "/third", tmp .. "/third.out", env)
  assert(third:find("2 ran, 2 stood, 2 of them on another checkout's verdict", 1, true), third)
  -- Told to stand on none of them, a checkout runs everything.
  checkout(tmp .. "/unshared")
  local unshared = run(tmp .. "/unshared", tmp .. "/unshared.out", env, { "--no-shared" })
  assert(unshared:find("4 ran, 0 stood", 1, true), unshared)
end
