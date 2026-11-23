--- [`QueueVerdicts.find`] against a fake API, and [`QueueVerdicts.merge`]
--- over caches of the shape build/shared_verdicts.tl keeps.
local Fs = require("cosmic.fs")
local GithubFake = require("cosmic_ci.github_fake")
local QueueVerdicts = require("cosmic_ci.queue_verdicts")
local Sqlite = require("cosmic.sqlite")

local SHA <const> = "0123456789abcdef0123456789abcdef01234567"
local OTHER <const> = "fedcba9876543210fedcba9876543210fedcba98"
local RUNS <const> = "repos/o/r/actions/workflows/ci.yml/runs?event=merge_group&head_sha=" .. SHA .. "&per_page=20"
local ARTIFACT <const> = "queue-verdicts-linux-x86_64"

local function env(): mut {string:string}
  return { SHA = SHA, ARTIFACT = ARTIFACT, GITHUB_REPOSITORY = "o/r" }
end

--- A run on the list: of `sha`, on the queue's branch of o/r where
--- `branch` and `repository` say nothing else.
local function run(id: integer, sha: string, branch?: string, repository?: string): string
  return '{"id":' .. tostring(id) .. ',"head_sha":"' .. sha .. '","head_branch":"' ..
    (branch or "gh-readonly-queue/main/pr-1-" .. sha) .. '","head_repository":{"full_name":"' ..
    (repository or "o/r") .. '"}}'
end

local function artifacts_of(id: integer): string
  return "repos/o/r/actions/runs/" .. tostring(id) .. "/artifacts?name=" .. ARTIFACT
end

--- The newest run that tested the commit and holds the verdicts is
--- named: a newer one without them is passed over, and a run of another
--- commit, of another branch than the queue's or of a fork is never named.
local function test_the_newest_queue_run_of_the_commit_is_named()
  local fake = GithubFake.new(function(path: string, _nth: integer): string?
    if path == RUNS then
      return '{"workflow_runs":[' .. table.concat({ run(7, SHA), run(9, SHA), run(10, SHA), run(12, OTHER),
        run(13, SHA, "main"), run(14, SHA, nil, "fork/r") }, ",") .. ']}'
    end
    if path == artifacts_of(10) then return '{"artifacts":[]}' end
    if path == artifacts_of(9) or path == artifacts_of(7) then
      return '{"artifacts":[{"name":"' .. ARTIFACT .. '","expired":false}]}'
    end
    return nil
  end)
  assert(QueueVerdicts.find(env(), fake.host) == 0)
  assert(GithubFake.text(fake.outputs) == "run=9\n", GithubFake.text(fake.outputs))
  assert(GithubFake.count(fake, "runs/12/") + GithubFake.count(fake, "runs/13/") + GithubFake.count(fake, "runs/14/") == 0,
    table.concat(fake.calls, "\n"))
end

--- No run, a run with no artifact, an expired one and an API that fails
--- each write nothing and pass the step, saying why.
local function test_a_push_with_nothing_to_take_writes_nothing()
  local answers: {string:string} = {
    ["no run"] = '{"workflow_runs":[]}',
    ["no artifact"] = '{"artifacts":[]}',
    ["expired"] = '{"artifacts":[{"name":"' .. ARTIFACT .. '","expired":true}]}',
  }
  for _, case in ipairs({ "no run", "no artifact", "expired", "failing" }) do
    local fake = GithubFake.new(function(path: string, _nth: integer): string?
      if case == "failing" then return nil end
      if path == RUNS then
        if case == "no run" then return answers[case] end
        return '{"workflow_runs":[' .. run(3, SHA) .. ']}'
      end
      return answers[case]
    end)
    assert(QueueVerdicts.find(env(), fake.host) == 0, case)
    assert(#fake.outputs == 0, case .. ": " .. GithubFake.text(fake.outputs))
    assert(GithubFake.text(fake.summaries):find("no verdicts from the merge queue", 1, true), case)
  end
end

local function test_a_step_that_names_no_commit_fails()
  local fake = GithubFake.new(function(_path: string, _nth: integer): string? return nil end)
  local bad = env()
  bad["SHA"] = "main"
  assert(QueueVerdicts.find(bad, fake.host) == 2)
  assert(#fake.calls == 0)
end

--- A cache with the table build/shared_verdicts.tl keeps, its rows by key
--- and origin; `extra` adds a column the other side may lack.
local function cache(path: string, rows: {string:string}, extra?: boolean)
  local db = assert(Sqlite.open(path, { writable = true }))
  local parts = if extra == true then ", parts TEXT NOT NULL DEFAULT ''" else "" end
  assert(db:exec("CREATE TABLE declared_v1 (key TEXT PRIMARY KEY, origin TEXT NOT NULL" .. parts .. "); " ..
      "CREATE INDEX declared_v1_by_origin ON declared_v1 (origin)"))
  for key, origin in pairs(rows) do
    assert(Sqlite.run(db, "INSERT INTO declared_v1 (key, origin) VALUES (?1, ?2)", { { text = key }, { text = origin } }))
  end
  assert(db:close())
end

local function rows(path: string, sql?: string): string
  local db = assert(Sqlite.open(path))
  local out: mut {string} = {}
  for _, row in ipairs((assert(Sqlite.text_rows(db, sql or "SELECT key, origin FROM declared_v1 ORDER BY key")))) do
    out[#out + 1] = table.concat(row:texts(), "=")
  end
  assert(db:close())
  return table.concat(out, " ")
end

--- The queue's rows join the restored ones, its own replacing a row of the
--- same key; a column only one side has is left out.
local function test_the_queues_rows_join_those_restored(tmp: string)
  local from, into = tmp .. "/queue", tmp .. "/verdicts"
  assert(Fs.mkdirs(from))
  assert(Fs.mkdirs(into))
  cache(from .. "/verdicts.db", { a = "queue", b = "queue" }, true)
  cache(into .. "/verdicts.db", { b = "main", c = "main" })
  local said = QueueVerdicts.merge(from, into)
  assert(said.code == 0 and said.err == "", said.out .. said.err)
  assert(said.out:find("took 2 rows", 1, true), said.out)
  assert(rows(into .. "/verdicts.db") == "a=queue b=queue c=main", rows(into .. "/verdicts.db"))
end

--- A table the restored cache lacks (a newer format's) is made as the
--- queue's was, its index too; where nothing was restored the queue's
--- file is the cache.
local function test_what_the_restored_cache_lacks_is_the_queues(tmp: string)
  local from, into = tmp .. "/queue", tmp .. "/verdicts"
  assert(Fs.mkdirs(from))
  assert(Fs.mkdirs(into))
  cache(from .. "/verdicts.db", { a = "queue" })
  cache(from .. "/fixtures.db", { f = "queue" })
  local db = assert(Sqlite.open(into .. "/verdicts.db", { writable = true }))
  assert(db:exec("CREATE TABLE verdicts_v3 (key TEXT PRIMARY KEY)"))
  assert(db:close())
  local said = QueueVerdicts.merge(from, into)
  assert(said.code == 0 and said.err == "", said.out .. said.err)
  assert(rows(into .. "/verdicts.db") == "a=queue", rows(into .. "/verdicts.db"))
  assert(rows(into .. "/verdicts.db", "SELECT name FROM sqlite_schema WHERE type = 'index' AND sql IS NOT NULL ORDER BY name") ==
      "declared_v1_by_origin")
  assert(rows(into .. "/fixtures.db") == "f=queue", rows(into .. "/fixtures.db"))
  assert(said.out:find("fixtures.db: the merge queue's, whole", 1, true), said.out)
end

--- A file that is no database is said and leaves the cache as it was; an
--- empty download takes nothing.
local function test_a_merge_that_cannot_be_made_leaves_the_cache(tmp: string)
  local from, into = tmp .. "/queue", tmp .. "/verdicts"
  assert(Fs.mkdirs(from))
  assert(Fs.mkdirs(into))
  assert(QueueVerdicts.merge(from, into).out:find("no verdicts from the merge queue", 1, true))
  assert(Fs.write(from .. "/verdicts.db", "not a database"))
  cache(into .. "/verdicts.db", { c = "main" })
  local said = QueueVerdicts.merge(from, into)
  assert(said.code == 0 and said.err:find("left as restored", 1, true) ~= nil, said.out .. said.err)
  assert(rows(into .. "/verdicts.db") == "c=main")
  assert(QueueVerdicts.merge("queue", into).code == 2)
end

--- A file whose schema holds more than the statement that makes a table
--- is refused (by SQLite, or by the merge where SQLite reads it), and
--- nothing of it is taken.
local function test_a_schema_of_more_than_a_table_is_refused(tmp: string)
  local from, into = tmp .. "/queue", tmp .. "/verdicts"
  assert(Fs.mkdirs(from))
  assert(Fs.mkdirs(into))
  local db = assert(Sqlite.open(from .. "/verdicts.db", { writable = true }))
  assert(db:exec("CREATE TABLE declared_v1 (key TEXT PRIMARY KEY, origin TEXT NOT NULL); " ..
      "INSERT INTO declared_v1 VALUES ('a', 'queue'); PRAGMA writable_schema = ON; " ..
      "UPDATE sqlite_schema SET sql = sql || '; DROP TABLE kept' WHERE name = 'declared_v1'"))
  assert(db:close())
  db = assert(Sqlite.open(into .. "/verdicts.db", { writable = true }))
  assert(db:exec("CREATE TABLE kept (key TEXT PRIMARY KEY)"))
  assert(db:close())
  local said = QueueVerdicts.merge(from, into)
  assert(said.code == 0 and said.err:find("left as restored", 1, true) ~= nil, said.out .. said.err)
  assert(rows(into .. "/verdicts.db", "SELECT name FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY name") == "kept")
end

--- The queue writes the name of its verdicts' cache beside them, and the
--- relay reads it back as the step's output; a name that is no verdict
--- cache's is refused on the way in and passed over on the way out.
local function test_the_cache_the_verdicts_belong_in_is_relayed_beside_them(tmp: string)
  local key = "verdicts-linux-x86_64-3a9f8d7b94f5492e-0de7cf39e1e63661-"
  local wrote = QueueVerdicts.name(tmp, key)
  assert(wrote.code == 0, wrote.err)
  local fake = GithubFake.new(function(_path: string, _nth: integer): string? return nil end)
  assert(QueueVerdicts.key(tmp, "linux-x86_64", fake.host) == 0)
  assert(GithubFake.text(fake.outputs) == "verdicts=" .. key .. "\n", GithubFake.text(fake.outputs))
  for _, bad in ipairs({ "", "verdicts-linux-x86_64", "other-linux-x86_64-", "verdicts-a b-", "verdicts-a\n-" }) do
    assert(QueueVerdicts.name(tmp .. "/none", bad).code == 2, bad)
  end
  assert(Fs.write(tmp .. "/cache-key", "verdicts-a\nb-\n"))
  local refused = GithubFake.new(function(_path: string, _nth: integer): string? return nil end)
  assert(QueueVerdicts.key(tmp, "linux-x86_64", refused.host) == 0)
  assert(#refused.outputs == 0, GithubFake.text(refused.outputs))
  local missing = GithubFake.new(function(_path: string, _nth: integer): string? return nil end)
  assert(QueueVerdicts.key(tmp .. "/absent", "linux-x86_64", missing.host) == 0)
  assert(#missing.outputs == 0, GithubFake.text(missing.outputs))
  -- Another leg's cache is not the relay's to write.
  assert(QueueVerdicts.name(tmp, "verdicts-macos-aarch64-3a9f8d7b94f5492e-").code == 0)
  local other = GithubFake.new(function(_path: string, _nth: integer): string? return nil end)
  assert(QueueVerdicts.key(tmp, "linux-x86_64", other.host) == 0)
  assert(#other.outputs == 0, GithubFake.text(other.outputs))
end

--- Main's push says whether main is still its commit: false where main
--- moved past it, true where not, and nothing where GitHub does not say.
local function test_a_push_says_whether_main_moved_past_it()
  local REF = "repos/o/r/git/ref/heads/main"
  for _, case in ipairs({ { SHA, "newest=true\n" }, { OTHER, "newest=false\n" }, { "", "" }, { "main", "" } }) do
    local head, said = case[1] or "", case[2] or ""
    local fake = GithubFake.new(function(path: string, _nth: integer): string?
      if path == REF and head ~= "" then return '{"object":{"sha":"' .. head .. '"}}' end
      return nil
    end)
    assert(QueueVerdicts.newest(env(), fake.host) == 0, head)
    assert(GithubFake.text(fake.outputs) == said, head .. ": " .. GithubFake.text(fake.outputs))
  end
  local bad = env()
  bad["SHA"] = "main"
  assert(QueueVerdicts.newest(bad, GithubFake.new(function(_path: string, _nth: integer): string?
    return nil
  end).host) == 2)
end
