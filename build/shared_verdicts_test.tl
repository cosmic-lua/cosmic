--- End to end: a verdict one checkout of a tree reached stands in
--- another checkout of the same content, at another path with its own
--- o/, through the cache `COSMIC_VERDICT_CACHE` names, by its declared
--- key (build/declared_key.tl), while a changed file or variable its
--- module declares, or `--all`, runs it again. Only a run whose workers are sandboxed
--- shares its verdicts: each suite declares what its tests read, and a
--- case stops where the run it starts cannot sandbox one (`shares`).

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local observations = require("build.filesystem_observations")
local shared_verdicts = require("build.shared_verdicts")
local Test = require("cosmic.test")

--- The program itself, which its tests start.
Test.needs{ tool = true }

--- Runs `cosmic test` on `root` with `words` after it, answering what
--- it printed.
local function run(root: string, output: string, env: {string:string},
                   words?: {string}, fails?: boolean): string
  local fd = assert(Fs.open_write(output))
  local args: {string} = { "test" }
  for _, word in ipairs(words or {}) do args[#args + 1] = word end
  local started = observations.program(args, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil and result.ok == not fails, tostring(trouble) .. text)
  return text
end

--- Whether the run that printed `text` shared its verdicts: where no
--- worker can be sandboxed, none is shared, and a case of sharing
--- has nothing to check. The run takes this one's switch
--- (COSMIC_TEST_SANDBOX, pinned): turned off, it shares nothing; and
--- where this test's own worker is sandboxed and the switch requires
--- it, a run that shared nothing fails the case rather than skip it.
local function shares(text: string): boolean
  if text:find("; sandboxed)", 1, true) ~= nil then return true end
  assert(not (observations.sandboxed() and sys.getenv("COSMIC_TEST_SANDBOX") == "1"),
    "sandboxed, and required to be, but the run it started was not:\n" .. text)
  return false
end

--- A checkout of the suite at `root`, its data file holding `data`, its
--- outside test reading the directory beside `root` named outside.
local function checkout(root: string, data: string)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/data.txt", data))
  assert(Fs.write(root .. "/suite/marker.txt", "marked\n"))
  assert(Fs.write(root .. "/suite/reads_test.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/" }, env = { "FLAVOUR" } }

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
local Test = require("cosmic.test")

Test.needs { reads = { "suite/marker.txt" }, host = { "]] .. Fs.dirname(root) ..
    [[/outside/" }, env = { "OUTSIDE" } }

local function test_reads_outside()
  assert(Fs.stat("suite/marker.txt") ~= nil)
  assert(Fs.read(assert(Env.get("OUTSIDE")) .. "/f") == "out\n")
end
]]))
end

--- A shared cache seeded by a first checkout's run under `tmp`: the
--- environment its runs are given, a `said` that runs `cosmic test` on
--- a checkout and checks what it printed, and that first run's output,
--- or nil where the run shared nothing, as `shares` has it. Each case
--- below seeds its own, so none starts more nested runs than a test's
--- bound (10 s in CI) holds under load.
local type Said = function(string, string, string, ?{string}): string

local function seeded(tmp: string): {string:string}, Said, string
  -- Resolved: a sandbox gives a host path its suite declares at the
  -- name it resolves to, and the one this test was handed is a link.
  tmp = assert(Fs.absolute(tmp))
  assert(Fs.mkdirs(tmp .. "/outside"))
  assert(Fs.write(tmp .. "/outside/f", "out\n"))
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.OUTSIDE = tmp .. "/outside"
  env.FLAVOUR = "sweet"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  local function said(name: string, root: string, wanted: string, words?: {string}): string
    local text = run(root, tmp .. "/" .. name .. ".out", env, words)
    assert(text:find(wanted, 1, true), name .. ": " .. text)
    return text
  end
  checkout(tmp .. "/first", "one\n")
  local first = said("first", tmp .. "/first", "5 ran, 0 stood")
  if not shares(first) then return env, said, nil end
  return env, said, first
end

local function test_a_second_checkout_stands_on_the_first_ones_verdicts(tmp: string)
  local _, said, first = seeded(tmp)
  if first == nil then return end
  tmp = assert(Fs.absolute(tmp))
  -- Every file of the second has an inode and times of its own.
  checkout(tmp .. "/second", "one\n")
  local second = said("second", tmp .. "/second",
    "0 ran, 5 stood, 5 of them on another checkout's verdict")
  -- Credited the lines the first run's tests hit.
  local covered = first:match("coverage [^\n]*")
  assert(covered ~= nil and covered == second:match("coverage [^\n]*"), first .. second)
  -- Now its own: its o/ holds them -- the read of the whole environment
  -- too, keyed on what its worker saw, where the cache is off, not on
  -- what the run that started it sees.
  local again = said("again", tmp .. "/second", "0 ran, 5 stood")
  assert(not again:find("another checkout", 1, true), again)
end

--- A checkout started after the tool rebuilt itself, from a shell that
--- was elsewhere before its last `cd`, stands on the first one's
--- verdicts: nothing a test is given differs.
local function test_a_rebooted_run_stands_on_the_first_ones_verdicts(tmp: string)
  local env, said, first = seeded(tmp)
  if first == nil then return end
  tmp = assert(Fs.absolute(tmp))
  env.COSMIC_REBOOTED = "1"
  env.OLDPWD = tmp .. "/elsewhere"
  checkout(tmp .. "/rebooted", "one\n")
  said("rebooted", tmp .. "/rebooted", "0 ran, 5 stood")
end

--- A checkout runs what no shared verdict answers for: a file a module
--- declares that differs, or an edit in the checkout itself.
local function test_a_checkout_runs_what_no_shared_verdict_answers_for(tmp: string)
  local _, said, first = seeded(tmp)
  if first == nil then return end
  tmp = assert(Fs.absolute(tmp))
  -- A file beneath what a module declares differs: its tests run.
  checkout(tmp .. "/changed", "two\n")
  said("changed", tmp .. "/changed", "4 ran, 1 stood")
  -- An edit to one module's input in a checkout runs that module's
  -- tests, looked up in the cache and not found there, while the rest
  -- stand on the checkout's own verdicts: no key of the run moved but
  -- theirs, so it says nothing of the cache.
  assert(Fs.write(tmp .. "/first/suite/data.txt", "three\n"))
  local edited = said("edited", tmp .. "/first", "4 ran, 1 stood")
  assert(not edited:find("shared verdicts: none of", 1, true), edited)
end

--- A run that chooses only an edited module runs its tests and says
--- nothing of the cache either, and a checkout whose variable a module
--- declares differs runs that module's tests.
local function test_a_chosen_edited_module_or_another_variable_runs(tmp: string)
  local env, said, first = seeded(tmp)
  if first == nil then return end
  tmp = assert(Fs.absolute(tmp))
  -- Chosen alone, the edited module's every test is looked up, and
  -- none is missing from the cache for want of a run: each ran in this
  -- checkout before.
  assert(Fs.write(tmp .. "/first/suite/data.txt", "four\n"))
  local chosen = said("chosen", tmp .. "/first", "4 ran, 0 stood", { "suite/reads_test.tl" })
  assert(not chosen:find("shared verdicts: none of", 1, true), chosen)
  -- A variable a module declares differs: its tests run.
  env.FLAVOUR = "salty"
  checkout(tmp .. "/salty", "one\n")
  said("salty", tmp .. "/salty", "4 ran, 1 stood")
end

--- Asked for every test, or told to stand on no shared verdict, a
--- checkout runs everything.
local function test_asked_for_or_told_to_share_nothing_every_test_runs(tmp: string)
  local _, said, first = seeded(tmp)
  if first == nil then return end
  tmp = assert(Fs.absolute(tmp))
  -- Asked for, every test runs, whatever stands.
  checkout(tmp .. "/all", "one\n")
  said("all", tmp .. "/all", "5 ran, 0 stood", { "--all" })
  -- Told to stand on none of them, a checkout runs everything.
  checkout(tmp .. "/unshared", "one\n")
  said("unshared", tmp .. "/unshared", "5 ran, 0 stood", { "--no-shared" })
end

--- Without the cache, a checkout runs everything.
local function test_without_the_cache_a_checkout_runs_everything(tmp: string)
  local env, said, first = seeded(tmp)
  if first == nil then return end
  tmp = assert(Fs.absolute(tmp))
  env.COSMIC_VERDICT_CACHE = "0"
  checkout(tmp .. "/alone", "one\n")
  said("alone", tmp .. "/alone", "5 ran, 0 stood")
end

--- A database a test reads through `cosmic.sqlite` is read by SQLite
--- in C, not through `cosmic.sys`: a checkout whose database holds
--- something else runs the test again, and fails it, while one whose
--- database is the same stands on the first one's verdict.
local function test_a_database_sqlite_reads_is_keyed_by_its_contents(tmp: string)
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  local function database_checkout(root: string, value: string)
    assert(Fs.mkdirs(root .. "/suite"))
    local db = assert(Sqlite.open(root .. "/suite/data.db", true))
    assert(db:exec("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('" .. value .. "')"))
    assert(db:close())
    assert(Fs.write(root .. "/suite/database_test.tl", [[
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/data.db" } }

local function test_reads_a_database()
  local db = assert(Sqlite.open("suite/data.db", false))
  local rows = assert(Sqlite.text_rows(db, "SELECT v FROM t"))
  assert(db:close())
  assert(rows[1][1] == "one", rows[1][1])
end
]]))
  end
  database_checkout(tmp .. "/first", "one")
  local first = run(tmp .. "/first", tmp .. "/first.out", env)
  assert(first:find("1 ran, 0 stood", 1, true), first)
  if not shares(first) then return end
  database_checkout(tmp .. "/same", "one")
  local same = run(tmp .. "/same", tmp .. "/same.out", env)
  assert(same:find("0 ran, 1 stood", 1, true), same)
  database_checkout(tmp .. "/changed", "two")
  local changed = run(tmp .. "/changed", tmp .. "/changed.out", env, nil, true)
  assert(changed:find("FAIL (1 of 1 failed", 1, true), changed)
end

--- A checkout at `root` whose tests read what `suite/link` is and
--- where it leads: a link to `target`, or a file where it is nil.
local function link_checkout(root: string, target: string | nil)
  assert(Fs.mkdirs(root .. "/suite"))
  if target ~= nil then
    assert(Fs.symlink(target, root .. "/suite/link"))
  else
    assert(Fs.write(root .. "/suite/link", "a"))
  end
  assert(Fs.write(root .. "/suite/link_test.tl", [[
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/" } }

local function test_reads_the_links_target()
  local target = sys.readlink("suite/link")
  assert(target == "a", tostring(target))
end

local function test_reads_what_the_link_is()
  local st = assert(sys.lstat("suite/link"))
  assert(st.kind == "link", st.kind)
end
]]))
end

--- The environment the link cases run in, sharing through a cache in
--- `tmp`, once a first checkout whose link leads to "a" has run and
--- shared its verdicts; nil where it shared nothing.
local function linked(tmp: string): {string:string} | nil
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  link_checkout(tmp .. "/first", "a")
  local first = run(tmp .. "/first", tmp .. "/first.out", env)
  assert(first:find("2 ran, 0 stood", 1, true), first)
  if not shares(first) then return nil end
  return env
end

--- What `lstat` and `readlink` answer of a file of the tree is keyed,
--- logged by those bindings themselves: a checkout whose link leads
--- elsewhere runs what read it again, and fails it, while one the same
--- stands on the first one's verdicts.
local function test_a_link_a_test_reads_is_keyed_by_what_it_is(tmp: string)
  local env = linked(tmp)
  if env == nil then return end
  link_checkout(tmp .. "/same", "a")
  local same = run(tmp .. "/same", tmp .. "/same.out", env)
  assert(same:find("0 ran, 2 stood", 1, true), same)
  link_checkout(tmp .. "/retargeted", "b")
  local retargeted = run(tmp .. "/retargeted", tmp .. "/retargeted.out", env, nil, true)
  assert(retargeted:find("FAIL (1 of 2 failed", 1, true), retargeted)
end

--- A checkout whose link is a file instead runs both tests that read
--- it again, and fails them.
local function test_a_link_made_a_file_runs_what_read_it_again(tmp: string)
  local env = linked(tmp)
  if env == nil then return end
  link_checkout(tmp .. "/file", nil)
  local file = run(tmp .. "/file", tmp .. "/file.out", env, nil, true)
  assert(file:find("FAIL (2 of 2 failed", 1, true), file)
end

--- A database a test attaches through the store (`cosmic.store`'s
--- `attach`) is read by SQLite in C too: a checkout whose database
--- holds something else runs the test again, and fails it, while one
--- whose database is the same stands on the first one's verdict. A
--- module that declares the working database, which every run
--- rewrites, runs every time.
local function test_a_database_attached_through_the_store_is_keyed_by_its_contents(tmp: string)
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  local function attached_checkout(root: string, value: string)
    assert(Fs.mkdirs(root .. "/suite"))
    local db = assert(Sqlite.open(root .. "/suite/data.db", true))
    assert(db:exec("CREATE TABLE meta (key TEXT, value TEXT); " ..
      "INSERT INTO meta VALUES ('v', '" .. value .. "')"))
    assert(db:close())
    assert(Fs.write(root .. "/suite/attached_test.tl", [[
local Store = require("cosmic.store")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/data.db" } }

local function test_reads_an_attached_database()
  assert(Store.attach("suite/data.db"))
  -- Through the store's own lookup: a hold on the store (this module
  -- declares no `store`) hands no test its databases.
  local value = Store.meta("v")
  assert(value == "one", tostring(value))
end
]]))
    assert(Fs.write(root .. "/suite/working_test.tl", [[
local Store = require("cosmic.store")
local Test = require("cosmic.test")

Test.needs { reads = { "o/build.db" } }

-- Through the store's own lookup: a hold on the store (this module
-- declares no `store`) hands no test its databases.
local function test_reads_the_working_database()
  assert(Store.attach("o/build.db"))
  local _ = Store.meta("reads the working database")
end
]]))
  end
  attached_checkout(tmp .. "/first", "one")
  local first = run(tmp .. "/first", tmp .. "/first.out", env)
  assert(first:find("2 ran, 0 stood", 1, true), first)
  if not shares(first) then return end
  attached_checkout(tmp .. "/same", "one")
  local same = run(tmp .. "/same", tmp .. "/same.out", env)
  assert(same:find("1 ran, 1 stood", 1, true), same)
  attached_checkout(tmp .. "/changed", "two")
  local changed = run(tmp .. "/changed", tmp .. "/changed.out", env, nil, true)
  assert(changed:find("FAIL (1 of 2 failed", 1, true), changed)
end

--- SQLite names a file with its links resolved: a database a test
--- makes in its own directory is its own still where the system temp
--- directory is reached through a link, as macOS's /var is, and the
--- test's verdict stands.
local function test_a_database_in_a_tests_own_directory_through_a_linked_temp_stands(tmp: string)
  assert(Fs.mkdirs(tmp .. "/real-temp"))
  assert(Fs.symlink("real-temp", tmp .. "/temp"))
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.TMPDIR = tmp .. "/temp"
  local root = tmp .. "/checkout"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/own_database_test.tl", [[
local Sqlite = require("cosmic.sqlite")

local function test_makes_a_database(tmp: string)
  local db = assert(Sqlite.open(tmp .. "/own.db", true))
  assert(db:exec("CREATE TABLE t (v TEXT)"))
  assert(db:close())
end
]]))
  local first = run(root, tmp .. "/first.out", env)
  assert(first:find("1 ran, 0 stood", 1, true), first)
  local again = run(root, tmp .. "/again.out", env)
  assert(again:find("0 ran, 1 stood", 1, true), again)
end

--- What the build left under o/ is an input like any file of the tree:
--- a checkout whose o/ holds the same bytes stands on a sibling's
--- verdict of a test that read it, one whose o/ holds other bytes runs
--- it, and a test that read the working database, which every run
--- rewrites, runs every time.
local function test_a_read_of_the_builds_output_is_keyed_by_its_bytes(tmp: string)
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  local function said(name: string, tool: string, wanted: string): string
    local root = tmp .. "/" .. name
    assert(Fs.mkdirs(root .. "/suite"))
    assert(Fs.mkdirs(root .. "/o/bin"))
    assert(Fs.write(root .. "/o/bin/tool", tool))
    assert(Fs.write(root .. "/suite/output_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.needs { reads = { "o/bin/tool" } }

local function test_reads_the_tool()
  assert(Fs.read("o/bin/tool") ~= nil)
  assert(Fs.stat("o/bin/tool") ~= nil)
end
]]))
    assert(Fs.write(root .. "/suite/working_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.needs { reads = { "o/build.db" } }

local function test_reads_the_working_database()
  assert(Fs.read("o/build.db") ~= nil)
end
]]))
    local text = run(root, tmp .. "/" .. name .. ".out", env)
    assert(text:find(wanted, 1, true), name .. ": " .. text)
    return text
  end
  if not shares(said("first", "one", "2 ran, 0 stood")) then return end
  said("same", "one", "1 ran, 1 stood")
  said("other", "two", "2 ran, 0 stood")
end

--- A row stands only under the key this checkout reaches for it --
--- which holds the runtime, the module and everything it read (see
--- `test_distinct_runtimes_never_share_a_key` for the runtime): one
--- whose key differs, its test and module the same, runs.
local function test_a_row_whose_key_this_checkout_does_not_reach_does_not_stand(tmp: string)
  local cache = tmp .. "/cache/verdicts.db"
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = cache
  env.FLAVOUR = "sweet"
  env.OUTSIDE = tmp
  checkout(tmp .. "/first", "one\n")
  local first = run(tmp .. "/first", tmp .. "/first.out", env, { "suite/reads_test.tl" })
  assert(first:find("4 ran, 0 stood", 1, true), first)
  if not shares(first) then return end
  local db = assert(Sqlite.open(cache, true))
  local tables = assert(Sqlite.text_rows(db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' AND name LIKE 'declared%'"))
  assert(#tables == 1, "one table")
  assert(db:exec("UPDATE " .. tables[1][1] .. " SET key = 'another runtime ' || key"))
  assert(db:close())
  checkout(tmp .. "/second", "one\n")
  local second = run(tmp .. "/second", tmp .. "/second.out", env, { "suite/reads_test.tl" })
  assert(second:find("4 ran, 0 stood", 1, true), second)
  -- And says why: the cache held these very tests, under keys it no
  -- longer reaches.
  assert(second:find("none of 4 tests looked up stood, though " .. cache ..
    " holds 4 rows, 4 of them of those tests: none under the keys this run reached", 1, true), second)
  assert(second:find("host features %x+, host %x+, runtime %x+") ~= nil, second)
end

--- A run none of whose lookups stood is told what the cache held: its
--- rows, those of the tests it looked up, and the digests every key of
--- it holds; an empty cache says nothing.
local function test_a_cache_that_answers_nothing_says_what_it_holds(tmp: string)
  local path = tmp .. "/cache/verdicts.db"
  local cache = assert(shared_verdicts.open(path))
  local empty = assert(shared_verdicts.census(cache, {}))
  assert(empty.rows == 0 and empty.of_tests == 0)
  assert(shared_verdicts.unmatched(path, 3, empty, {}) == nil, "an empty cache said something")
  local kept: {shared_verdicts.Kept} = {}
  for i, test in ipairs({ "a_test.tl test_a", "a_test.tl test_b", "b_test.tl test_c" }) do
    kept[#kept + 1] = { key = "k" .. i, test = test, hits = "", elapsed_ns = 1 }
  end
  assert(shared_verdicts.settle(cache, "first", { kept = kept, used = {}, failed = {} },
    Time.now_ns()))
  local census = assert(shared_verdicts.census(cache, { ["a_test.tl test_a"] = true,
    ["a_test.tl test_b"] = true, ["c_test.tl test_d"] = true }))
  assert(census.rows == 3 and census.of_tests == 2, census.rows .. " " .. census.of_tests)
  local line = assert(shared_verdicts.unmatched(path, 3, census,
    { { "host", "abab" }, { "runtime", "cdcd" } }))
  assert(line:find("none of 3 tests looked up stood", 1, true), line)
  assert(line:find("holds 3 rows, 2 of them of those tests: none under the keys this run reached", 1, true), line)
  assert(line:find("host abab, runtime cdcd", 1, true), line)
  assert(shared_verdicts.unmatched(path, 0, census, {}) == nil, "no lookup, yet a line")
  local other = assert(shared_verdicts.census(cache, { ["c_test.tl test_d"] = true }))
  local unreached = assert(shared_verdicts.unmatched(path, 1, other, {}))
  assert(unreached:find("0 of them of those tests: no other run reached them", 1, true), unreached)
  shared_verdicts.close(cache)
end

--- A cache that cannot answer -- its pages overwritten, or this
--- format's table in another shape -- is said so once and done without:
--- the run runs what it must and passes.
local function test_a_cache_that_cannot_answer_is_done_without(tmp: string)
  local env = observations.environment()
  env.FLAVOUR = "sweet"
  env.OUTSIDE = tmp
  local corrupt = tmp .. "/corrupt/verdicts.db"
  env.COSMIC_VERDICT_CACHE = corrupt
  checkout(tmp .. "/first", "one\n")
  if not shares(run(tmp .. "/first", tmp .. "/first.out", env, { "suite/reads_test.tl" })) then
    return
  end
  local bytes = assert(Fs.read(corrupt))
  assert(#bytes > 4096, "more than one page")
  assert(Fs.write(corrupt, bytes:sub(1, 4096) .. string.rep("\xff", #bytes - 4096)))
  checkout(tmp .. "/second", "one\n")
  local second = run(tmp .. "/second", tmp .. "/second.out", env, { "suite/reads_test.tl" })
  assert(second:find("4 ran, 0 stood", 1, true), second)
  assert(second:find("running without them", 1, true), second)
  assert(second:find("moved aside", 1, true), second)
  -- Set aside, it is not met again: the next run starts a fresh cache.
  checkout(tmp .. "/fresh", "one\n")
  local fresh = run(tmp .. "/fresh", tmp .. "/fresh.out", env, { "suite/reads_test.tl" })
  assert(not fresh:find("running without them", 1, true), fresh)
end

--- A cache holding this format's table in the shape of none is said so
--- once and done without: the run runs what it must and passes.
local function test_a_cache_of_another_shape_is_done_without(tmp: string)
  local env = observations.environment()
  env.FLAVOUR = "sweet"
  env.OUTSIDE = tmp
  local other = tmp .. "/other/verdicts.db"
  assert(Fs.mkdirs(tmp .. "/other"))
  local db = assert(Sqlite.open(other, true))
  local probe = assert(shared_verdicts.open(tmp .. "/probe/verdicts.db"))
  local named = assert(Sqlite.text_rows(probe.db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' AND name LIKE 'declared%'"))
  shared_verdicts.close(probe)
  assert(db:exec("CREATE TABLE " .. named[1][1] .. " (x TEXT)"))
  assert(db:close())
  env.COSMIC_VERDICT_CACHE = other
  checkout(tmp .. "/third", "one\n")
  local third = run(tmp .. "/third", tmp .. "/third.out", env, { "suite/reads_test.tl" })
  assert(third:find("4 ran, 0 stood", 1, true), third)
  if not shares(third) then return end
  local _, complaints = third:gsub("running without them", "")
  assert(complaints == 1, third)
end

--- Rewrites `path` as it was, a moment later: its contents the same,
--- its modification time not.
local function touch(path: string)
  local data = assert(Fs.read(path))
  assert(Time.sleep_ns(10000000))
  assert(Fs.write(path, data))
end

--- A file touched in a checkout, its contents the same, runs nothing
--- again, with the shared cache on as off: a declared key holds what a
--- file holds, not when it was written.
local function test_a_touched_file_runs_nothing_again(tmp: string)
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.FLAVOUR = "sweet"
  env.OUTSIDE = tmp
  checkout(tmp .. "/first", "one\n")
  local words = { "suite/reads_test.tl" }
  local first = run(tmp .. "/first", tmp .. "/first.out", env, words)
  assert(first:find("4 ran, 0 stood", 1, true), first)
  if not shares(first) then return end
  touch(tmp .. "/first/suite/data.txt")
  local touched = run(tmp .. "/first", tmp .. "/touched.out", env, words)
  assert(touched:find("0 ran, 4 stood", 1, true), touched)
  assert(not touched:find("another checkout", 1, true), touched)
  env.COSMIC_VERDICT_CACHE = "0"
  touch(tmp .. "/first/suite/data.txt")
  local alone = run(tmp .. "/first", tmp .. "/alone.out", env, words)
  assert(alone:find("0 ran, 4 stood", 1, true), alone)
end

--- A checkout made again at the path of one removed is another
--- checkout: it stands on what the removed one reached.
local function test_a_checkout_made_again_at_the_same_path_stands_on_the_last(tmp: string)
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.FLAVOUR = "sweet"
  env.OUTSIDE = tmp
  local words = { "suite/reads_test.tl" }
  checkout(tmp .. "/here", "one\n")
  local first = run(tmp .. "/here", tmp .. "/first.out", env, words)
  assert(first:find("4 ran, 0 stood", 1, true), first)
  if not shares(first) then return end
  assert(Fs.remove_tree(tmp .. "/here"))
  checkout(tmp .. "/here", "one\n")
  local again = run(tmp .. "/here", tmp .. "/again.out", env, words)
  assert(again:find("0 ran, 4 stood, 4 of them on another checkout's verdict", 1, true), again)
end

--- A checkout's own evidence comes first: a test that failed here runs
--- again, whatever another checkout reached under the same key, and the
--- shared row goes.
local function test_a_failure_here_is_not_answered_from_elsewhere(tmp: string)
  -- Resolved: a sandbox gives a host path its suite declares at the
  -- name it resolves to, and the one this test was handed is a link.
  tmp = assert(Fs.absolute(tmp))
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
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
  if not shares(failed) then return end
  -- The first passes, and shares it.
  assert(Fs.write(tmp .. "/outside/f", "out\n"))
  local first = run(tmp .. "/first", tmp .. "/first.out", env, { "suite/outside_test.tl" })
  assert(first:find("1 ran", 1, true), first)
  -- The second runs, its own failure standing against the shared pass
  -- though a file it stat'd was touched since, which moves its own key.
  assert(Fs.write(tmp .. "/outside/f", "not yet\n"))
  touch(tmp .. "/second/suite/marker.txt")
  local again = run(tmp .. "/second", tmp .. "/again.out", env, {}, true)
  assert(again:find("1 of 5 failed", 1, true), again)
  -- ...and the row it would have stood on is gone: a third checkout
  -- runs the test too.
  assert(Fs.write(tmp .. "/outside/f", "out\n"))
  checkout(tmp .. "/third", "one\n")
  local third = run(tmp .. "/third", tmp .. "/third.out", env, {})
  assert(third:find("1 ran, 4 stood", 1, true), third)
end

--- Two checkouts, first and second, of a suite whose one test stops
--- at its first read -- of f in the directory OUTSIDE names -- unless
--- that holds "out", and the environment they run in, sharing through
--- a cache in `tmp`; and `tmp` resolved.
local function early_suite(tmp: string): {string:string}, string
  -- Resolved: a sandbox gives a host path its suite declares at the
  -- name it resolves to, and the one this test was handed is a link.
  tmp = assert(Fs.absolute(tmp))
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  assert(Fs.mkdirs(tmp .. "/outside"))
  env.OUTSIDE = tmp .. "/outside"
  for _, name in ipairs({ "first", "second" }) do
    local root = tmp .. "/" .. name
    assert(Fs.mkdirs(root .. "/suite"))
    assert(Fs.write(root .. "/suite/c.txt", "c\n"))
    assert(Fs.write(root .. "/suite/early_test.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/c.txt" }, host = { "]] .. tmp .. [[/outside/" }, env = { "OUTSIDE" } }

local function test_stops_early()
  assert(Fs.read(assert(Env.get("OUTSIDE")) .. "/f") == "out\n")
  assert(Fs.read("suite/c.txt") == "c\n")
end
]]))
  end
  return env, tmp
end

--- A test that failed here runs until it passes here, though its
--- failing run stopped short of a read the passing one elsewhere made,
--- so no key of its own matches that one's.
local function test_a_failure_that_read_less_is_not_answered_from_elsewhere(tmp: string)
  local env, resolved = early_suite(tmp)
  tmp = resolved
  assert(Fs.write(tmp .. "/outside/f", "not yet\n"))
  local failed = run(tmp .. "/second", tmp .. "/failed.out", env, {}, true)
  assert(failed:find("1 of 1 failed", 1, true), failed)
  if not shares(failed) then return end
  assert(Fs.write(tmp .. "/outside/f", "out\n"))
  local passed = run(tmp .. "/first", tmp .. "/passed.out", env, {})
  assert(passed:find("1 ran", 1, true), passed)
  assert(Fs.write(tmp .. "/outside/f", "not yet\n"))
  local again = run(tmp .. "/second", tmp .. "/again.out", env, {}, true)
  assert(again:find("1 of 1 failed", 1, true), again)
end

--- Without the cache too, a test that failed here runs until it passes
--- here.
local function test_a_failure_here_runs_again_without_the_cache(tmp: string)
  local env, resolved = early_suite(tmp)
  tmp = resolved
  assert(Fs.write(tmp .. "/outside/f", "not yet\n"))
  local failed = run(tmp .. "/second", tmp .. "/failed.out", env, {}, true)
  assert(failed:find("1 of 1 failed", 1, true), failed)
  if not shares(failed) then return end
  env.COSMIC_VERDICT_CACHE = "0"
  local alone = run(tmp .. "/second", tmp .. "/alone.out", env, {}, true)
  assert(alone:find("1 of 1 failed", 1, true), alone)
end

--- A verdict is kept by its declared key alone (build/declared_key.tl),
--- with no reads to check it by: found under that key, freshened by a
--- run that relies on it, and taken out by one that fails under it. A
--- cache from before the map has the map made, and the tables
--- observation-keyed runs shared left as they were.
local function test_a_verdict_is_kept_by_its_key_alone(tmp: string)
  local path = tmp .. "/cache/verdicts.db"
  local cache = assert(shared_verdicts.open(path))
  shared_verdicts.close(cache)
  -- As a cache from before the map: an earlier table, and none of its.
  local db = assert(Sqlite.open(path, true))
  assert(db:exec("DROP TABLE declared_v1"))
  assert(db:exec("CREATE TABLE verdicts_v4 (key TEXT PRIMARY KEY)"))
  assert(db:close())
  cache = assert(shared_verdicts.open(path))
  local tables = assert(Sqlite.text_rows(cache.db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name"))
  assert(#tables == 2 and tables[1][1] == "declared_v1" and tables[2][1] == "verdicts_v4",
    "an earlier format's table was dropped: " .. tostring(#tables))
  assert(shared_verdicts.declared(cache, "declared") == nil)
  assert(shared_verdicts.settle(cache, "first", { kept = { {
    key = "declared", test = "suite/t_test.tl test_t", hits = "suite/t_test.tl\t1,2,5\n",
    elapsed_ns = 7 } }, used = {}, failed = {} }, Time.now_ns()))
  local found = assert(shared_verdicts.declared(cache, "declared"))
  assert(found.elapsed_ns == 7 and found.hits == "suite/t_test.tl\t1,2,5\n", found.hits)
  -- Relied on long after it was written, it stays; unrelied, it goes.
  local later = Time.now_ns() + 29 * 24 * 3600 * 1000000000
  assert(shared_verdicts.settle(cache, "second", { kept = {}, used = { "declared" },
    failed = {} }, later))
  assert(shared_verdicts.declared(cache, "declared") ~= nil, "a verdict relied on went")
  assert(shared_verdicts.settle(cache, "second", { kept = {}, used = {}, failed = {} },
    later + 31 * 24 * 3600 * 1000000000))
  assert(shared_verdicts.declared(cache, "declared") == nil, "an unrelied verdict stayed")
  assert(shared_verdicts.settle(cache, "first", { kept = { { key = "declared",
    test = "suite/t_test.tl test_t", hits = "", elapsed_ns = 1 } }, used = {}, failed = {} },
    Time.now_ns()))
  assert(shared_verdicts.settle(cache, "second", { kept = {}, used = {},
    failed = { "declared" } }, Time.now_ns()))
  assert(shared_verdicts.declared(cache, "declared") == nil, "a failure kept it")
  shared_verdicts.close(cache)
end
