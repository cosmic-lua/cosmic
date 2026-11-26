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
local function run(id: integer, sha: string, branch?: string, repository?: string, attempt?: integer): string
  return '{"id":' .. tostring(id) .. ',"head_sha":"' .. sha .. '","head_branch":"' ..
    (branch or "gh-readonly-queue/main/pr-1-" .. sha) .. '","head_repository":{"full_name":"' ..
    (repository or "o/r") .. '"},"run_attempt":' .. tostring(attempt or 1) .. '}'
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
    assert(db:run("INSERT INTO declared_v1 (key, origin) VALUES (?1, ?2)", { { text = key }, { text = origin } }))
  end
  assert(db:close())
end

local function rows(path: string, sql?: string): string
  local db = assert(Sqlite.open(path))
  local out: mut {string} = {}
  for _, row in ipairs((assert(db:rows(sql or "SELECT key, origin FROM declared_v1 ORDER BY key")))) do
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
  -- The second statement goes in over a comment of the same length, in the
  -- file's bytes: a defensive handle writes no schema text.
  local marker = "/*" .. string.rep("A", 20) .. "*/"
  -- The `--` comments out the table's own `)`, so the second statement is a whole one. SQLite refuses a schema
  -- row with text past its statement as malformed, which is one of the refusals this test allows.
  local hostile = "); DROP TABLE kept --" .. string.rep(" ", #marker - 21)
  local db = assert(Sqlite.open(from .. "/verdicts.db", { writable = true }))
  assert(db:exec("CREATE TABLE declared_v1 (key TEXT PRIMARY KEY, origin TEXT NOT NULL" .. marker .. "); " ..
      "INSERT INTO declared_v1 VALUES ('a', 'queue')"))
  assert(db:close())
  local bytes = assert(Fs.read(from .. "/verdicts.db"))
  local at = assert(bytes:find(marker, 1, true), "the schema text is in the file")
  assert(Fs.write(from .. "/verdicts.db", bytes:sub(1, at - 1) .. hostile .. bytes:sub(at + #marker)))
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
  for _, foreign in ipairs({ "verdicts-macos-aarch64-3a9f8d7b94f5492e-0de7cf39e1e63661-",
      "verdicts-linux-x86_64-checked-3a9f8d7b94f5492e-0de7cf39e1e63661-", "verdicts-linux-x86_64-3a9f8d7b94f5492e-" }) do
    assert(QueueVerdicts.name(tmp, foreign).code == 0, foreign)
    local other = GithubFake.new(function(_path: string, _nth: integer): string? return nil end)
    assert(QueueVerdicts.key(tmp, "linux-x86_64", other.host) == 0)
    assert(#other.outputs == 0, foreign .. ": " .. GithubFake.text(other.outputs))
  end
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

local FAILED <const> = "repos/o/r/actions/workflows/ci.yml/runs?event=merge_group&status=failure&per_page=50"
local TRIED_ARTIFACT <const> = "queue-tried-verdicts-linux-x86_64"
--- This run's commit, and the commits of earlier tries.
local NOW <const> = "2222222222222222222222222222222222222222"
local AHEAD <const> = "1111111111111111111111111111111111111111"
local function tried_sha(id: integer): string return string.format("%040x", id) end

--- A commit's tree, its files a.tl (of `mode`, else a plain file's),
--- b.tl and evil.tl.
local function tree(mode?: string): string
  return '{"truncated":false,"tree":[{"path":"a.tl","mode":"' .. (mode or "100644") .. '","type":"blob"},' ..
    '{"path":"b.tl","mode":"100644","type":"blob"},{"path":"evil.tl","mode":"100644","type":"blob"}]}'
end

--- A comparison of commits that changes `blob` into a.tl, adds b.tl and
--- removes gone.tl, which no tree holds.
local function change(blob: string): string
  return '{"status":"ahead","files":[{"filename":"b.tl","status":"added","sha":"bb"},' ..
    '{"filename":"a.tl","status":"modified","sha":"' .. blob .. '"},{"filename":"gone.tl","status":"removed"}]}'
end

local function tried_env(): mut {string:string}
  return { HEAD_REF = "refs/heads/gh-readonly-queue/main/pr-41-" .. SHA, BASE_SHA = SHA, SHA = NOW,
    ARTIFACT = TRIED_ARTIFACT, GITHUB_REPOSITORY = "o/r", RUN_ID = "20" }
end

--- A queue ref, or its branch, names its pull request and the commit its
--- entry was put on; nothing else does.
local function test_a_queue_ref_names_its_pull_request()
  local entry = assert(QueueVerdicts.entry_of("refs/heads/gh-readonly-queue/main/pr-4196-" .. SHA))
  assert(entry.pr == "4196" and entry.on == SHA, entry.pr .. " " .. entry.on)
  assert(assert(QueueVerdicts.entry_of("gh-readonly-queue/main/pr-7-" .. SHA)).pr == "7")
  for _, other in ipairs({ "refs/heads/main", "gh-readonly-queue/main/pr-x-" .. SHA,
      "gh-readonly-queue/main/pr-7-", "gh-readonly-queue/main/pr-7-abc", "claude/pr-7-" .. SHA, "" }) do
    assert(QueueVerdicts.entry_of(other) == nil, other)
  end
end

--- A run's jobs: its merge-queue ref job, and its gate with the step
--- that refuses the ref's caches again, of the conclusions given.
local function jobs(before: string, after: string): string
  return '{"total_count":3,"jobs":[{"name":"linux-x86_64","conclusion":"failure","steps":[{"name":"test","conclusion":"failure"}]},' ..
    '{"name":"' .. QueueVerdicts.REF_JOB .. '","conclusion":"' .. before .. '"},' ..
    '{"name":"' .. QueueVerdicts.GATE_JOB .. '","conclusion":"failure","steps":[{"name":"' ..
    QueueVerdicts.RECHECK_STEP .. '","conclusion":"' .. after .. '"},' ..
    '{"name":"every job passed","conclusion":"failure"}]}]}'
end

--- The newest failed run of the same pull request that was built on main
--- with this run's change, refused its ref's caches and holds the
--- verdicts is named: this run, another pull request's (pr-410 among
--- them), a fork's, one with none, one built on an entry that never
--- merged, one of another change, one whose comparison GitHub does not
--- answer and one attempted again are passed over.
local function test_the_newest_failed_try_of_the_pull_request_is_named()
  local mine = "gh-readonly-queue/main/pr-41-" .. OTHER
  local ahead = "gh-readonly-queue/main/pr-41-" .. AHEAD
  local fake = GithubFake.new(function(path: string, _nth: integer): string?
    if path:match("^repos/o/r/git/trees/") then return tree() end
    if path == FAILED then
      return '{"workflow_runs":[' .. table.concat({ run(5, tried_sha(5), mine), run(8, tried_sha(8), mine),
        run(9, tried_sha(9), mine), run(10, tried_sha(10), mine), run(11, tried_sha(11), mine),
        run(12, tried_sha(12), "gh-readonly-queue/main/pr-410-" .. OTHER),
        run(13, tried_sha(13), mine, "fork/r"), run(15, tried_sha(15), ahead), run(16, tried_sha(16), mine, nil, 2),
        run(20, NOW, "gh-readonly-queue/main/pr-41-" .. SHA) }, ",") .. ']}'
    end
    if path == "repos/o/r/compare/" .. OTHER .. "...main" then return '{"status":"ahead"}' end
    if path == "repos/o/r/compare/" .. AHEAD .. "...main" then return '{"status":"diverged"}' end
    for _, ref in ipairs({ mine, ahead }) do
      if path == "repos/o/r/actions/caches?ref=refs/heads/" .. ref .. "&per_page=1" then
        return '{"total_count":0}'
      end
    end
    if path == "repos/o/r/compare/" .. SHA .. "..." .. NOW then return change("aa") end
    if path == "repos/o/r/compare/" .. AHEAD .. "..." .. tried_sha(15) then return change("aa") end
    for _, id in ipairs({ 5, 8, 11, 16 }) do
      if path == "repos/o/r/compare/" .. OTHER .. "..." .. tried_sha(id) then
        return change("aa")
      end
    end
    if path == "repos/o/r/compare/" .. OTHER .. "..." .. tried_sha(10) then return change("a0") end
    local artifacts = "/artifacts?name=" .. TRIED_ARTIFACT
    if path == "repos/o/r/actions/runs/11" .. artifacts then return '{"artifacts":[]}' end
    for _, id in ipairs({ 5, 8, 9, 10, 11, 15, 16 }) do
      if path == "repos/o/r/actions/runs/" .. tostring(id) .. "/jobs?per_page=100" then
        return jobs("success", "success")
      end
      if path == "repos/o/r/actions/runs/" .. tostring(id) .. artifacts then
        return '{"artifacts":[{"id":' .. tostring(id * 100) .. ',"name":"' .. TRIED_ARTIFACT .. '","expired":false}]}'
      end
    end
    return nil
  end)
  assert(QueueVerdicts.find_tried(tried_env(), fake.host) == 0)
  assert(GithubFake.text(fake.outputs) == "run=8\nartifact=800\n", GithubFake.text(fake.outputs))
  -- Trees only for a change that matches otherwise (runs 11 and 8), and this run's once.
  assert(GithubFake.count(fake, "/git/trees/") == 3, table.concat(fake.calls, "\n"))
  for _, id in ipairs({ 9, 10, 12, 13, 15, 16, 20 }) do
    assert(GithubFake.count(fake, "runs/" .. tostring(id) .. "/") == 0, tostring(id) .. ": " .. table.concat(fake.calls, "\n"))
  end
end

--- A change GitHub lists in part, or with a file of no content named, or
--- that renames another file into the same one, moves a file or changes
--- its status, or that is not ahead of its base, is not this run's, even
--- where this run's comparison reads the same. Nor is a run built on a
--- commit GitHub does not place on main, one whose commit is no commit,
--- one whose ref holds a cache or whose caches GitHub does not count,
--- one whose jobs did not refuse its ref's caches exactly once before
--- and once after they ran, or whose jobs GitHub lists in part, or one
--- that holds no one artifact of the name and an id.
local function test_a_change_that_cannot_be_matched_is_not_taken()
  local mine = "gh-readonly-queue/main/pr-41-" .. OTHER
  local many: mut {string} = {}
  for i = 1, 300 do
    many[i] = '{"filename":"f' .. tostring(i) .. '","status":"added","sha":"aa"}'
  end
  local no_blob = '{"status":"ahead","files":[{"filename":"b.tl","status":"added"},' ..
    '{"filename":"a.tl","status":"modified","sha":"aa"}]}'
  local cut = '{"status":"ahead","files":[' .. table.concat(many, ",") .. ']}'
  local ref_job = '{"name":"' .. QueueVerdicts.REF_JOB .. '","conclusion":"success"}'
  local recheck = '{"name":"' .. QueueVerdicts.RECHECK_STEP .. '","conclusion":"success"}'
  local artifact = '{"id":500,"name":"' .. TRIED_ARTIFACT .. '","expired":false}'
  --- Each case: what differs from a run that is taken. The tried run's tree,
  --- this run's tree, the tried run's comparison, this run's, the tried run's commit, whether its base is
  --- on main, the count of its ref's caches, its jobs and its artifacts;
  --- "" where GitHub does not answer.
  local record Case
    tree?: string
    mine_tree?: string
    tried?: string
    mine?: string
    sha?: string
    main?: string
    caches?: string
    jobs?: string
    artifacts?: string
  end
  local cases: {string:Case} = {
    ["no files"] = { tried = '{"status":"ahead"}' },
    ["no blob"] = { tried = no_blob, mine = no_blob },
    ["another rename"] = { tried = '{"status":"ahead","files":[{"filename":"b.tl","status":"added","sha":"bb"},' ..
        '{"filename":"a.tl","previous_filename":"z.tl","status":"renamed","sha":"aa"}]}',
      mine = '{"status":"ahead","files":[{"filename":"b.tl","status":"added","sha":"bb"},' ..
        '{"filename":"a.tl","previous_filename":"x.tl","status":"renamed","sha":"aa"}]}' },
    ["moved"] = { tried = (change("aa"):gsub('"a%.tl"', '"evil.tl"')) },
    ["other status"] = { tried = (change("aa"):gsub('"modified"', '"added"')) },
    ["cut"] = { tried = cut, mine = cut },
    ["behind"] = { tried = (change("aa"):gsub('"ahead"', '"behind"')) },
    ["no commit"] = { sha = "not-a-commit" },
    ["not on main"] = { main = '{"status":"diverged"}' },
    ["main unanswered"] = { main = "" },
    ["cached"] = { caches = '{"total_count":1}' },
    ["uncounted"] = { caches = '{"actions_caches":[]}' },
    ["ref job failed"] = { jobs = jobs("failure", "success") },
    ["ref job skipped"] = { jobs = jobs("skipped", "success") },
    ["recheck skipped"] = { jobs = jobs("success", "skipped") },
    ["no ref job"] = { jobs = '{"total_count":1,"jobs":[{"name":"' .. QueueVerdicts.GATE_JOB .. '","steps":[' .. recheck .. ']}]}' },
    ["no recheck"] = { jobs = '{"total_count":2,"jobs":[' .. ref_job .. ',{"name":"' .. QueueVerdicts.GATE_JOB .. '","steps":[]}]}' },
    ["recheck in another job"] = { jobs = '{"total_count":3,"jobs":[' .. ref_job .. ',{"name":"' .. QueueVerdicts.GATE_JOB ..
        '","steps":[]},{"name":"linux-x86_64","steps":[' .. recheck .. ']}]}' },
    ["two ref jobs"] = { jobs = '{"total_count":3,"jobs":[' .. ref_job .. ',' .. ref_job .. ',{"name":"' .. QueueVerdicts.GATE_JOB ..
        '","steps":[' .. recheck .. ']}]}' },
    ["two rechecks"] = { jobs = '{"total_count":2,"jobs":[' .. ref_job .. ',{"name":"' .. QueueVerdicts.GATE_JOB ..
        '","steps":[' .. recheck .. ',' .. recheck .. ']}]}' },
    ["no jobs"] = { jobs = "" },
    ["mode changed"] = { tree = tree("100755") },
    ["tree cut"] = { tree = (tree():gsub('"truncated":false', '"truncated":true')) },
    ["tree uncut unsaid"] = { tree = (tree():gsub('"truncated":false,', '')) },
    ["tree unanswered"] = { tree = "" },
    ["no mode"] = { tree = '{"truncated":false,"tree":[{"path":"a.tl"},{"path":"b.tl","mode":"100644"}]}' },
    ["file not in tree"] = { tree = '{"truncated":false,"tree":[{"path":"b.tl","mode":"100644"}]}',
      mine_tree = '{"truncated":false,"tree":[{"path":"b.tl","mode":"100644"}]}' },
    ["file twice in tree"] = { tree = (tree():gsub('%]}$', ',{"path":"a.tl","mode":"100644"}]}')) },
    ["more jobs than listed"] = { jobs = (jobs("success", "success"):gsub('"total_count":3', '"total_count":4')) },
    ["jobs uncounted"] = { jobs = (jobs("success", "success"):gsub('"total_count":3,', '')) },
    ["another artifact"] = { artifacts = '{"artifacts":[{"id":500,"name":"queue-tried-verdicts-macos","expired":false}]}' },
    ["two artifacts"] = { artifacts = '{"artifacts":[' .. artifact .. ',' .. artifact:gsub("500", "501") .. ']}' },
    ["no artifact id"] = { artifacts = '{"artifacts":[{"name":"' .. TRIED_ARTIFACT .. '","expired":false}]}' },
    ["expired"] = { artifacts = '{"artifacts":[' .. artifact:gsub("false", "true") .. ']}' },
  }
  for name, case in pairs(cases) do
    for _, control in ipairs({ false, true }) do
      local function pick(given: string?, taken: string): string?
        local answer = if control or given == nil then taken else given end
        return if answer == "" then nil else answer end
      end
      local sha = if control then tried_sha(5) else case.sha or tried_sha(5) end
      local fake = GithubFake.new(function(path: string, _nth: integer): string?
        if path == "repos/o/r/git/trees/" .. sha .. "?recursive=1" then
          return pick(case.tree, tree())
        end
        if path == "repos/o/r/git/trees/" .. NOW .. "?recursive=1" then
          return pick(case.mine_tree, tree())
        end
        if path:match("^repos/o/r/git/trees/") then return tree() end
        if path == FAILED then return '{"workflow_runs":[' .. run(5, sha, mine) .. ']}' end
        if path == "repos/o/r/actions/caches?ref=refs/heads/" .. mine .. "&per_page=1" then
          return pick(case.caches, '{"total_count":0}')
        end
        if path == "repos/o/r/compare/" .. OTHER .. "...main" then
          return pick(case.main, '{"status":"ahead"}')
        end
        if path == "repos/o/r/compare/" .. SHA .. "..." .. NOW then
          return pick(case.mine, change("aa"))
        end
        if path == "repos/o/r/compare/" .. OTHER .. "..." .. sha then
          return pick(case.tried, change("aa"))
        end
        if path == "repos/o/r/actions/runs/5/jobs?per_page=100" then
          return pick(case.jobs, jobs("success", "success"))
        end
        if path == "repos/o/r/actions/runs/5/artifacts?name=" .. TRIED_ARTIFACT then
          return pick(case.artifacts, '{"artifacts":[' .. artifact .. ']}')
        end
        return nil
      end)
      assert(QueueVerdicts.find_tried(tried_env(), fake.host) == 0, name)
      local want = if control then "run=5\nartifact=500\n" else "" end
      assert(GithubFake.text(fake.outputs) == want, name .. ": " .. GithubFake.text(fake.outputs))
    end
  end
end

--- A first try and an API that fails write nothing, nor does a step that
--- names no queue ref, base, commit, artifact or repository, which fails.
local function test_a_first_try_takes_nothing()
  for _, case in ipairs({ "none", "failing", "unchanged" }) do
    local fake = GithubFake.new(function(path: string, _nth: integer): string?
      if path:match("^repos/o/r/git/trees/") then return tree() end
      if case == "none" and path == FAILED then return '{"workflow_runs":[]}' end
      if case == "none" and path == "repos/o/r/compare/" .. SHA .. "..." .. NOW then
        return change("aa")
      end
      if case == "unchanged" and path == FAILED then
        return '{"workflow_runs":[' .. run(5, tried_sha(5), "gh-readonly-queue/main/pr-41-" .. OTHER) .. ']}'
      end
      return nil
    end)
    assert(QueueVerdicts.find_tried(tried_env(), fake.host) == 0, case)
    assert(#fake.outputs == 0, case .. ": " .. GithubFake.text(fake.outputs))
  end
  for key, value in pairs({ HEAD_REF = "refs/heads/main", BASE_SHA = "main", SHA = "HEAD", ARTIFACT = "a/b",
      PASSED_ARTIFACT = "a b", GITHUB_REPOSITORY = "o" }) do
    local bad = tried_env()
    bad[key] = value
    local fake = GithubFake.new(function(_path: string, _nth: integer): string?
      return change("aa")
    end)
    assert(QueueVerdicts.find_tried(bad, fake.host) == 2, key)
    assert(#fake.calls == 0, key)
  end
end

--- A queue ref that holds a cache, or whose caches GitHub does not list,
--- fails the run; one that holds none passes; a step of no queue ref is
--- refused before it asks.
local function test_a_queue_ref_that_holds_a_cache_fails_the_run()
  local ref = "refs/heads/gh-readonly-queue/main/pr-41-" .. SHA
  local listing = "repos/o/r/actions/caches?ref=" .. ref .. "&per_page=1"
  local answers: {string:integer} = { ['{"total_count":0,"actions_caches":[]}'] = 0, ['{"total_count":1}'] = 1, ['{"total_count":2}'] = 1,
    ['{"actions_caches":[]}'] = 1, [""] = 1 }
  for answer, code in pairs(answers) do
    local fake = GithubFake.new(function(path: string, _nth: integer): string?
      if path == listing and answer ~= "" then return answer end
      return nil
    end)
    assert(QueueVerdicts.ref_caches({ GITHUB_REF = ref, GITHUB_REPOSITORY = "o/r" }, fake.host) == code, answer)
  end
  local fake = GithubFake.new(function(_path: string, _nth: integer): string? return nil end)
  assert(QueueVerdicts.ref_caches({ GITHUB_REF = "refs/heads/main", GITHUB_REPOSITORY = "o/r" }, fake.host) == 2)
  assert(#fake.calls == 0)
end

--- Where the run that failed holds none of this job's tried rows, the
--- rows this job left where its suite passed (PASSED_ARTIFACT) are named,
--- by the same rules; where it holds both, the tried rows are; where the
--- step names none, nothing is.
local function test_a_job_that_passed_in_a_failed_try_is_taken()
  local mine = "gh-readonly-queue/main/pr-41-" .. OTHER
  local passed = "queue-verdicts-linux-x86_64"
  for _, case in ipairs({ "passed", "none named", "neither", "two passed", "both" }) do
    local fake = GithubFake.new(function(path: string, _nth: integer): string?
      if path:match("^repos/o/r/git/trees/") then return tree() end
      if path == FAILED then return '{"workflow_runs":[' .. run(5, tried_sha(5), mine) .. ']}' end
      if path == "repos/o/r/actions/caches?ref=refs/heads/" .. mine .. "&per_page=1" then
        return '{"total_count":0}'
      end
      if path == "repos/o/r/compare/" .. OTHER .. "...main" then return '{"status":"ahead"}' end
      if path == "repos/o/r/compare/" .. SHA .. "..." .. NOW then return change("aa") end
      if path == "repos/o/r/compare/" .. OTHER .. "..." .. tried_sha(5) then return change("aa") end
      if path == "repos/o/r/actions/runs/5/jobs?per_page=100" then
        return jobs("success", "success")
      end
      if path == "repos/o/r/actions/runs/5/artifacts?name=" .. TRIED_ARTIFACT then
        return if case == "both" then '{"artifacts":[{"id":600,"name":"' .. TRIED_ARTIFACT .. '","expired":false}]}'
          else '{"artifacts":[]}' end
      end
      if path == "repos/o/r/actions/runs/5/artifacts?name=" .. passed and case ~= "neither" then
        local one = '{"id":700,"name":"' .. passed .. '","expired":false}'
        return '{"artifacts":[' .. one .. (if case == "two passed" then "," .. one:gsub("700", "701") else "" end) .. ']}'
      end
      return nil
    end)
    local step = tried_env()
    if case ~= "none named" then step["PASSED_ARTIFACT"] = passed end
    assert(QueueVerdicts.find_tried(step, fake.host) == 0, case)
    local want = if case == "passed" then "run=5\nartifact=700\n" elseif case == "both" then "run=5\nartifact=600\n"
      else "" end
    assert(GithubFake.text(fake.outputs) == want, case .. ": " .. GithubFake.text(fake.outputs))
  end
end
