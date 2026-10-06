--- Bare maintenance and help must not inspect or rebuild a candidate project.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local type _ = require("build.cache")
local type _ = require("cosmic.proc")
local Clock = require("cosmic.clock")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function run(dir: string, words: {string}): Child.Result
  local env = this_program.environment()
  env.COSMIC_TREE = dir .. "/does-not-exist"
  local started = this_program.program(words, { cwd = dir, env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(10) })
  return (assert(Child.run(started.argv, started.options)))
end

local function test_bare_success_usage_and_help_ignore_broken_project(tmp: string)
  assert(Fs.write(tmp .. "/cosmic.tl", "this is not a valid project"))
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/boot.tl", "syntax nonsense"))
  local result = run(tmp, { "cache", "trim", "compiles", tmp .. "/missing", "--since-ns", "0", "--json" })
  assert(result.code == 0, result.stderr)
  assert((result.stdout or ""):find('"state":"missing"', 1, true), result.stdout)
  for _, words in ipairs({ { "cache", "--help" }, { "help", "cache" } }) do
    local help = run(tmp, words)
    assert(help.code == 0 and (help.stdout or ""):find("--since-ns", 1, true), help.stderr)
  end
  local usage = run(tmp, { "cache", "trim", "verdicts", "relative", "--whole" })
  assert(usage.code == 2 and not (usage.stderr or ""):find("stale", 1, true), usage.stderr)
  assert(Fs.stat(tmp .. "/o") == nil and Fs.stat(tmp .. "/missing") == nil)
end

local function test_busy_cache_cancellation_is_prompt_and_preserves_file(tmp: string)
  local path = tmp .. "/cache.db"
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE untouched (value TEXT); INSERT INTO untouched VALUES ('keep'); BEGIN IMMEDIATE"))
  local started = this_program.program({ "cache", "trim", "compiles", path, "--since-ns", "0", "--json" },
    { cwd = tmp, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(0.2) })
  local result = assert(Child.run(started.argv, started.options))
  assert(db:exec("ROLLBACK"))
  assert(db:close())
  assert(result.timed_out, "the live writer must block maintenance")
  assert(Fs.stat(path) ~= nil)
  db = assert(Sqlite.open(path))
  assert(assert(Sqlite.text_rows(db, "SELECT value FROM untouched"))[1][1] == "keep")
  assert(db:close())
end

local function test_long_lived_reader_prevents_a_save_ready_wal_snapshot(tmp: string)
  local path = tmp .. "/verdicts.db"
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("PRAGMA journal_mode=WAL; CREATE TABLE keep (value TEXT); INSERT INTO keep VALUES ('first')"))
  local script = 'local Sqlite = require("cosmic.sqlite"); local Fs = require("cosmic.fs"); ' ..
    'local db = assert(Sqlite.open(' .. string.format("%q", path) .. ')); ' ..
    'assert(db:exec("BEGIN")); assert(Sqlite.rows(db,"SELECT * FROM keep")); ' ..
    'assert(Fs.put(1,"r")); assert(Fs.take(0,1)); assert(db:exec("ROLLBACK")); assert(db:close())'
  local reader_start = this_program.program({ "-e", script }, { cwd = tmp,
    stdin = "stream", stdout = "stream", stderr = "capture" })
  local reader <close> = assert(Child.start(reader_start.argv, reader_start.options))
  assert(assert(reader.stdout_stream):read(1) == "r")
  assert(db:exec("INSERT INTO keep VALUES ('later')"))
  local started = this_program.program({ "cache", "trim", "verdicts", path, "--whole", "--json" },
    { cwd = tmp, stdout = "capture", stderr = "capture", timeout_ns = Clock.ms(200) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.timed_out and not (result.stdout or ""):find('"digest"', 1, true))
  assert(Fs.stat(path .. "-wal") ~= nil, "maintenance must never unlink a live WAL")
  assert(assert(reader.stdin_stream):close())
  assert(assert(reader:wait(Clock.seconds(5))).code == 0)
  assert(#assert(Sqlite.rows(db, "SELECT * FROM keep")) == 2)
  assert(db:close())
end

--- Readiness comes from the actual command's open, inside its guard. The
--- parent holds its write lock until the child has reported cooperative failure.
local function test_signal_exits_cooperatively_with_an_incomplete_json_report(tmp: string)
  local path = tmp .. "/cache.db"
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE untouched (value TEXT); BEGIN IMMEDIATE"))
  local script = 'local Sqlite = require("cosmic.sqlite"); local Fs = require("cosmic.fs"); ' ..
    'local cache = require("build.cache"); local Proc = require("cosmic.proc"); local original = Sqlite.open; ' ..
    'Sqlite.open = function(path, opts) local db, why = original(path, opts); assert(Fs.put(1,"r")); return db, why end; ' ..
    'Proc.exit(cache.run({[0]="cosmic","cache","trim","compiles",' .. string.format("%q", path) ..
    ',"--since-ns","0","--json"}))'
  local started = this_program.program({ "-e", script }, { cwd = tmp,
    stdout = "stream", stderr = "capture", process_group = false })
  local child <close> = assert(Child.start(started.argv, started.options))
  local output = assert(child.stdout_stream)
  local ready, ready_why = output:read(1)
  if ready ~= "r" then
    local stopped = assert(child:wait(Clock.seconds(5)))
    error(ready_why .. (stopped.stderr or ""))
  end
  Poll.run(function() assert(Poll.delay(Clock.ms(20))) end)
  local before = Clock.monotonic_ns()
  assert(child:stop())
  local result = assert(child:wait(Clock.seconds(5)))
  local elapsed = Clock.monotonic_ns() - before
  local report = assert(Stream.read_all(output))
  assert(result.code == 1 and not result.timed_out and elapsed < Clock.seconds(2), result.stderr)
  assert(Json.decode(report) ~= nil and report:find('"state":"failed"', 1, true), report)
  assert(not report:find('"digest"', 1, true) and not report:find('"fresh"', 1, true), report)
  assert(db:exec("ROLLBACK"))
  assert(db:close())
  assert(Fs.stat(path) ~= nil)
end
