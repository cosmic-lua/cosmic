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
local Sqlite = require("cosmic.sqlite")
local observations = require("build.filesystem_observations")
local shared_verdicts = require("build.shared_verdicts")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- Runs `cosmic test` on `root` with `words` after it, answering what
--- it printed.
local function run(root: string, output: string, env: {string:string},
                   words?: {string}, fails?: boolean): string
  local fd = assert(Fs.open_write(output))
  local argv: {string} = { assert(Proc.executable()), "test" }
  for _, word in ipairs(words or {}) do argv[#argv + 1] = word end
  local result, trouble = Child.run(argv, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil and result.ok == not fails, tostring(trouble) .. text)
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
  -- Told to stand on none of them, a checkout runs everything.
  checkout(tmp .. "/unshared", "one\n")
  said("unshared", tmp .. "/unshared", "5 ran, 0 stood", { "--no-shared" })
  -- Without the cache, a checkout runs everything.
  env.COSMIC_VERDICT_CACHE = "0"
  checkout(tmp .. "/alone", "one\n")
  said("alone", tmp .. "/alone", "5 ran, 0 stood")
end

--- A row stands only under the key this checkout reaches for it --
--- which holds the runtime, the module and everything it read (see
--- `test_distinct_runtimes_never_share_a_key` for the runtime): one
--- whose key differs, its test and module the same, runs.
local function test_a_row_whose_key_this_checkout_does_not_reach_does_not_stand(tmp: string)
  local cache = tmp .. "/cache/verdicts.db"
  local env = Env.all()
  env.COSMIC_VERDICT_CACHE = cache
  env.FLAVOUR = "sweet"
  env.OUTSIDE = tmp
  checkout(tmp .. "/first", "one\n")
  local first = run(tmp .. "/first", tmp .. "/first.out", env, { "suite/reads_test.tl" })
  assert(first:find("4 ran, 0 stood", 1, true), first)
  local db = assert(Sqlite.open(cache, true))
  local tables = assert(Sqlite.text_rows(db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' AND name LIKE 'verdicts%'"))
  assert(#tables == 1, "one table")
  assert(db:exec("UPDATE " .. tables[1][1] .. " SET key = 'another runtime ' || key"))
  assert(db:close())
  checkout(tmp .. "/second", "one\n")
  local second = run(tmp .. "/second", tmp .. "/second.out", env, { "suite/reads_test.tl" })
  assert(second:find("4 ran, 0 stood", 1, true), second)
end

--- A cache that cannot answer -- its pages overwritten, or this
--- format's table in another shape -- is said so once and done without:
--- the run runs what it must and passes.
local function test_a_cache_that_cannot_answer_is_done_without(tmp: string)
  local env = Env.all()
  env.FLAVOUR = "sweet"
  env.OUTSIDE = tmp
  local corrupt = tmp .. "/corrupt/verdicts.db"
  env.COSMIC_VERDICT_CACHE = corrupt
  checkout(tmp .. "/first", "one\n")
  run(tmp .. "/first", tmp .. "/first.out", env, { "suite/reads_test.tl" })
  local bytes = assert(Fs.read(corrupt))
  assert(#bytes > 4096, "more than one page")
  assert(Fs.write(corrupt, bytes:sub(1, 4096) .. string.rep("\xff", #bytes - 4096)))
  checkout(tmp .. "/second", "one\n")
  local second = run(tmp .. "/second", tmp .. "/second.out", env, { "suite/reads_test.tl" })
  assert(second:find("4 ran, 0 stood", 1, true), second)
  assert(second:find("running without them", 1, true), second)
  -- This format's table, in the shape of none.
  local other = tmp .. "/other/verdicts.db"
  assert(Fs.mkdirs(tmp .. "/other"))
  local db = assert(Sqlite.open(other, true))
  local probe = assert(shared_verdicts.open(tmp .. "/probe/verdicts.db"))
  local named = assert(Sqlite.text_rows(probe.db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' AND name LIKE 'verdicts%'"))
  shared_verdicts.close(probe)
  assert(db:exec("CREATE TABLE " .. named[1][1] .. " (x TEXT)"))
  assert(db:close())
  env.COSMIC_VERDICT_CACHE = other
  checkout(tmp .. "/third", "one\n")
  local third = run(tmp .. "/third", tmp .. "/third.out", env, { "suite/reads_test.tl" })
  assert(third:find("4 ran, 0 stood", 1, true), third)
  local _, complaints = third:gsub("running without them", "")
  assert(complaints == 1, third)
end

--- A checkout's own evidence comes first: a test that failed here runs
--- again, whatever another checkout reached under the same key, and the
--- shared row goes.
local function test_a_failure_here_is_not_answered_from_elsewhere(tmp: string)
  local env = Env.all()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.COSMIC_TEST_ALL = nil
  env.FLAVOUR = "sweet"
  assert(Fs.mkdirs(tmp .. "/outside"))
  env.OUTSIDE = tmp .. "/outside"
  assert(Fs.write(tmp .. "/outside/f", "out\n"))
  checkout(tmp .. "/first", "one\n")
  checkout(tmp .. "/second", "one\n")
  -- The second fails first: what it read outside is not what it wants.
  assert(Fs.write(tmp .. "/outside/f", "not yet\n"))
  local failed = run(tmp .. "/second", tmp .. "/failed.out", env,
    { "suite/outside_test.tl" }, true)
  assert(failed:find("1 of 1 failed", 1, true), failed)
  -- The first passes, and shares it.
  assert(Fs.write(tmp .. "/outside/f", "out\n"))
  local first = run(tmp .. "/first", tmp .. "/first.out", env, { "suite/outside_test.tl" })
  assert(first:find("1 ran", 1, true), first)
  -- The second runs, its own failure standing against the shared pass.
  assert(Fs.write(tmp .. "/outside/f", "not yet\n"))
  local again = run(tmp .. "/second", tmp .. "/again.out", env, {}, true)
  assert(again:find("1 of 5 failed", 1, true), again)
  -- ...and the row it would have stood on is gone: a third checkout
  -- runs the test too.
  assert(Fs.write(tmp .. "/outside/f", "out\n"))
  checkout(tmp .. "/third", "one\n")
  local third = run(tmp .. "/third", tmp .. "/third.out", env, {})
  assert(third:find("1 ran, 4 stood", 1, true), third)
end
