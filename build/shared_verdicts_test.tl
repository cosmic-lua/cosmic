--- End to end: a verdict one checkout of a tree reached stands in
--- another checkout of the same content, at another path with its own
--- o/, through the cache `COSMIC_VERDICT_CACHE` names -- one a run no
--- key could hold reached is assumed there on the terms it is in its
--- own -- while a changed file or variable it read, or `--all` for one
--- assumed, runs it again.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local observations = require("build.filesystem_observations")
local shared_verdicts = require("build.shared_verdicts")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- Runs `cosmic test` on `root` with `words` after it, answering what
--- it printed.
local function run(root: string, output: string, env: {string:string},
                   words?: {string}): string
  local fd = assert(Fs.open_write(output))
  local argv: {string} = { assert(Proc.executable()), "test" }
  for _, word in ipairs(words or {}) do argv[#argv + 1] = word end
  local result, trouble = Child.run(argv, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil and result.ok, tostring(trouble) .. text)
  return text
end

--- A checkout of the suite at `root`, its data file holding `data`.
local function checkout(root: string, data: string)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/data.txt", data))
  assert(Fs.write(root .. "/suite/reads_test.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")

local function test_reads_data()
  assert(Fs.read("suite/data.txt") ~= nil)
  assert(Fs.stat("suite/data.txt") ~= nil)
  assert(Fs.list("suite") ~= nil)
end

local function test_reads_flavour()
  assert(Env.get("FLAVOUR") ~= "sour")
end

local function test_reads_everything()
  assert(Env.all().FLAVOUR ~= nil)
end

local function test_plain()
  assert(1 + 1 == 2)
end
]]))
  assert(Fs.write(root .. "/suite/outside_test.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")

local function test_reads_outside()
  assert(Fs.read(assert(Env.get("OUTSIDE")) .. "/f") == "out\n")
end
]]))
end

local function test_a_second_checkout_stands_on_the_first_ones_verdicts(tmp: string)
  assert(Fs.mkdirs(tmp .. "/outside"))
  assert(Fs.write(tmp .. "/outside/f", "out\n"))
  local env = Env.all()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.OUTSIDE = tmp .. "/outside"
  env.FLAVOUR = "sweet"
  env.COSMIC_TEST_ALL = nil
  local function said(name: string, root: string, wanted: string, words?: {string}): string
    local text = run(root, tmp .. "/" .. name .. ".out", env, words)
    assert(text:find(wanted, 1, true), name .. ": " .. text)
    return text
  end
  checkout(tmp .. "/first", "one\n")
  local first = said("first", tmp .. "/first", "5 ran, 0 stood")
  -- Every file of the second has an inode and times of its own.
  checkout(tmp .. "/second", "one\n")
  local second = said("second", tmp .. "/second",
    "0 ran, 4 stood, 1 assumed (--all runs them), 5 of them on another checkout's verdict")
  -- Credited the lines the first run's tests hit.
  local covered = first:match("coverage [^\n]*")
  assert(covered ~= nil and covered == second:match("coverage [^\n]*"), first .. second)
  -- Now its own: its o/ holds them -- the read of the whole environment
  -- too, keyed on what its worker saw, where the cache is off, not on
  -- what the run that started it sees.
  local again = said("again", tmp .. "/second", "0 ran, 4 stood, 1 assumed")
  assert(not again:find("another checkout", 1, true), again)
  -- A file one test read differs: that test runs.
  checkout(tmp .. "/changed", "two\n")
  said("changed", tmp .. "/changed", "1 ran, 3 stood, 1 assumed")
  -- A variable two tests read differs -- one by name, one in the whole
  -- environment: those run.
  env.FLAVOUR = "salty"
  checkout(tmp .. "/salty", "one\n")
  said("salty", tmp .. "/salty", "2 ran, 2 stood, 1 assumed")
  env.FLAVOUR = "sweet"
  -- Asked for, a test no key holds runs, whoever last ran it.
  checkout(tmp .. "/all", "one\n")
  said("all", tmp .. "/all", "1 ran, 4 stood, 4 of them", { "--all" })
  -- Without the cache, a checkout runs everything.
  env.COSMIC_VERDICT_CACHE = "0"
  checkout(tmp .. "/alone", "one\n")
  said("alone", tmp .. "/alone", "5 ran, 0 stood")
end

--- A verdict is keyed on the runtime that reached it: one reached under
--- another runtime never stands, however the rest of its key agrees.
local function test_a_verdict_of_another_runtime_does_not_stand(tmp: string)
  local cache = tmp .. "/cache/verdicts.db"
  local env = Env.all()
  env.COSMIC_VERDICT_CACHE = cache
  env.FLAVOUR = "sweet"
  env.OUTSIDE = tmp
  checkout(tmp .. "/first", "one\n")
  local first = run(tmp .. "/first", tmp .. "/first.out", env, { "suite/reads_test.tl" })
  assert(first:find("4 ran, 0 stood", 1, true), first)
  -- Each row as another runtime would have keyed it: its test and
  -- module the same, its key not.
  local opened = assert(shared_verdicts.open(cache))
  assert(opened.db:exec("UPDATE verdicts SET key = 'another runtime ' || key"))
  shared_verdicts.close(opened)
  checkout(tmp .. "/second", "one\n")
  local second = run(tmp .. "/second", tmp .. "/second.out", env, { "suite/reads_test.tl" })
  assert(second:find("4 ran, 0 stood", 1, true), second)
end
