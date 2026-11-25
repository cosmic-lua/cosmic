--- The verdicts the merge queue reached for a commit, for the relay
--- (relay.yml), which saves them as main's a minute after the merge, and
--- for main's push of the same commit. Main moves only through the queue, and the commit the
--- queue tested is the commit main's push runs (ci.yml). The queue's run
--- saves no cache of its own (a merge_group's cache is scoped to its
--- ref), so without these main's push ran its whole native suite again
--- for the commit the queue had just passed, standing on no verdict.
---
--- Each of the queue's legs trims its verdicts to what its suite job used
--- (cosmic_ci/verdicts.tl) and uploads them as `queue-verdicts-<leg>`.
--- Main's push of the same leg finds that run (`queue-run`), downloads
--- the artifact, and merges its rows into the verdicts it restored
--- (`verdicts-merge`), before its suites. Its suites then stand on what
--- the queue reached and run only the tests whose keys differ.
---
--- A row is keyed by everything its test was given (build/declared_key.tl):
--- the host, the runtime, the harness, the store and the test. A row
--- of the queue's stands for a test of the push only where the push's key
--- is the same. So taking them in decides how many tests stand, never
--- whether a verdict is right, as a restore of the cache does. Neither
--- step fails the leg: a run with no rows to take runs its tests.
local Fs = require("cosmic.fs")
local Env = require("cosmic.env")
local Github = require("cosmic_ci.github")
local Plural = require("cosmic_ci.plural")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")

local record QueueVerdicts
  --- What a merge came to: standard output and the diagnostics.
  record Said
    code: integer
    out: string
    err: string
  end
end

--- How long one lookup may take, in seconds.
local LOOKUP_SECONDS <const> = 30

--- What a run on the list of runs, its repository, and an artifact on a
--- run's list are read for.
local record RunRow
  id?: any
  head_sha?: any
  head_branch?: any
  head_repository?: any
end
local RUN_ROW <const> = Shape.record_of("RunRow")
local record RepositoryRow
  full_name?: any
end
local REPOSITORY_ROW <const> = Shape.record_of("RepositoryRow")
local record RunList
  workflow_runs?: {any}
end
local RUN_LIST <const> = Shape.record_of("RunList")
local record ArtifactRow
  name?: any
  expired?: any
end
local ARTIFACT_ROW <const> = Shape.record_of("ArtifactRow")
local record ArtifactList
  artifacts?: {any}
end
local ARTIFACT_LIST <const> = Shape.record_of("ArtifactList")

--- How many of the newest runs that tested a commit are asked for the
--- artifact: a run the queue started again (its entry put back) holds a
--- newer id.
local TRIED <const> = 5

--- Whether `item`, a run on the list, is a merge-queue run of `sha` in
--- `repository` itself (its branch the queue's, `gh-readonly-queue/`),
--- and its id.
local function queue_run_of(item: any, repository: string, sha: string): integer?
  local run, _ = RUN_ROW:into(item)
  if run == nil or run.head_sha ~= sha then return nil end
  local branch = run.head_branch
  if not (branch is string) or branch:sub(1, #"gh-readonly-queue/") ~= "gh-readonly-queue/" then
    return nil
  end
  local from, _ = REPOSITORY_ROW:into(run.head_repository)
  if from == nil or from.full_name ~= repository then return nil end
  local id = run.id
  if id is integer then return id end
  return nil
end

--- The ids of the merge-queue runs of ci.yml that tested `sha` in
--- `repository`, newest first and at most TRIED; nil and why where the
--- list cannot be read.
local function queue_runs(host: Github.Host, repository: string, sha: string): {integer}?, string
  local path = "repos/" .. repository .. "/actions/workflows/ci.yml/runs?event=merge_group&head_sha=" ..
    sha .. "&per_page=20"
  local pages = Github.ask(host, path, false, LOOKUP_SECONDS)
  if pages == nil then return nil, "GitHub did not answer which merge-queue runs tested " .. sha end
  local listed, trouble = RUN_LIST:decode_into(pages[1] or "")
  if listed == nil then return nil, "the list of runs: " .. trouble end
  local ids: mut {integer} = {}
  for _, item in ipairs(listed.workflow_runs or {}) do
    local id = queue_run_of(item, repository, sha)
    if id ~= nil then ids[#ids + 1] = id end
  end
  table.sort(ids, function(a: integer, b: integer): boolean return a > b end)
  while #ids > TRIED do table.remove(ids) end
  return ids, ""
end

--- Whether run `id` holds an artifact `name` that has not expired, and why
--- not.
local function holds_artifact(host: Github.Host, repository: string, id: integer, name: string): boolean, string
  local path = "repos/" .. repository .. "/actions/runs/" .. tostring(id) .. "/artifacts?name=" .. name
  local pages = Github.ask(host, path, false, LOOKUP_SECONDS)
  if pages == nil then
    return false, "GitHub did not answer which artifacts run " .. tostring(id) .. " holds"
  end
  local listed, trouble = ARTIFACT_LIST:decode_into(pages[1] or "")
  if listed == nil then return false, "the list of artifacts: " .. trouble end
  for _, item in ipairs(listed.artifacts or {}) do
    local artifact, _ = ARTIFACT_ROW:into(item)
    if artifact ~= nil and artifact.name == name and artifact.expired == false then
      return true, ""
    end
  end
  return false, "run " .. tostring(id) .. " holds no " .. name .. " that has not expired"
end

--- `driver.tl queue-run`: writes `run=<id>` to $GITHUB_OUTPUT, the newest
--- merge-queue run of ci.yml that tested SHA and uploaded ARTIFACT, in
--- GITHUB_REPOSITORY. Where it finds none it says why and writes nothing:
--- the push runs its tests. 2 where the step names no commit, artifact or
--- repository, else 0.
function QueueVerdicts.find(env: {string:string}, host: Github.Host): integer
  local sha, name, repository = env["SHA"] or "", env["ARTIFACT"] or "", env["GITHUB_REPOSITORY"] or ""
  if not Github.is_commit(sha) or not name:match("^[%w._-]+$") or not repository:match("^[%w._-]+/[%w._-]+$") then
    local _, _ = Fs.put(Fs.stderr, "queue-run: SHA, ARTIFACT and GITHUB_REPOSITORY must name a commit, " ..
        "an artifact and a repository\n")
    return 2
  end
  local ids, why = queue_runs(host, repository, sha)
  if ids ~= nil then
    why = "no merge-queue run of this repository tested " .. sha
    for _, id in ipairs(ids) do
      local held, absent = holds_artifact(host, repository, id, name)
      if held then
        host.output("run=" .. tostring(id))
        host.print("merge-queue run " .. tostring(id) .. " tested " .. sha .. " and uploaded " .. name)
        return 0
      end
      why = absent
    end
  end
  Github.say(host, "no verdicts from the merge queue: " .. why .. "; the push runs what they would have answered")
  return 0
end

function QueueVerdicts.find_command(_argv: {string}): integer
  local env = Env.all()
  return QueueVerdicts.find(env, Github.live(env))
end

--- What a merge-queue run that failed left for the entry's next try. A
--- queue run saves no cache, so an entry that moved every key and whose
--- suite the deadline stopped (COSMIC_TEST_DEADLINE) started cold again
--- on its next try, and could be stopped as far short. Each of its legs
--- uploads what it reached as `queue-tried-verdicts-<job>`, and the next
--- run of the same pull request takes it in before its suites.
---
--- Only the same pull request's: its run ran that pull request's code,
--- which the next try runs again, so its rows give that try nothing its
--- own code could not.

--- How many of the newest failed merge-queue runs are read for the pull
--- request's: about 15 hours of the queue's failures.
local FAILED_LISTED <const> = 50

--- The pull request a merge-queue ref is of, `refs/heads/gh-readonly-queue/<base>/pr-<n>-<sha>`
--- or its branch alone, as a number's text; nil for any other ref.
function QueueVerdicts.entry_of(ref: string): string?
  local branch = ref:match("^refs/heads/(.*)$") or ref
  return branch:match("^gh%-readonly%-queue/[%w._/-]-/pr%-(%d+)%-%x+$")
end

--- Whether `item`, a run on the list, is a merge-queue run in `repository`
--- itself of pull request `entry`, other than run `own`, and its id.
local function tried_run_of(item: any, repository: string, entry: string, own: integer?): integer?
  local run, _ = RUN_ROW:into(item)
  if run == nil then return nil end
  local branch = run.head_branch
  if not (branch is string) or QueueVerdicts.entry_of(branch) ~= entry then return nil end
  local from, _ = REPOSITORY_ROW:into(run.head_repository)
  if from == nil or from.full_name ~= repository then return nil end
  local id = run.id
  if id is integer and id ~= own then return id end
  return nil
end

--- The ids of the failed merge-queue runs of ci.yml for pull request
--- `entry` in `repository`, other than `own`, newest first and at most
--- TRIED; nil and why where the list cannot be read.
local function tried_runs(host: Github.Host, repository: string, entry: string, own: integer?): {integer}?, string
  local path = "repos/" .. repository .. "/actions/workflows/ci.yml/runs?event=merge_group&status=failure&per_page=" ..
    tostring(FAILED_LISTED)
  local pages = Github.ask(host, path, false, LOOKUP_SECONDS)
  if pages == nil then return nil, "GitHub did not answer which merge-queue runs failed" end
  local listed, trouble = RUN_LIST:decode_into(pages[1] or "")
  if listed == nil then return nil, "the list of runs: " .. trouble end
  local ids: mut {integer} = {}
  for _, item in ipairs(listed.workflow_runs or {}) do
    local id = tried_run_of(item, repository, entry, own)
    if id ~= nil then ids[#ids + 1] = id end
  end
  table.sort(ids, function(a: integer, b: integer): boolean return a > b end)
  while #ids > TRIED do table.remove(ids) end
  return ids, ""
end

--- `driver.tl queue-tried-run`: writes `run=<id>` to $GITHUB_OUTPUT, the
--- newest merge-queue run of ci.yml in GITHUB_REPOSITORY that failed for
--- the pull request HEAD_REF is of and uploaded ARTIFACT, other than
--- RUN_ID, this run. Where it finds none it says why and writes nothing:
--- the run's suites run their tests. 2 where the step names no queue
--- ref, artifact or repository, else 0.
function QueueVerdicts.find_tried(env: {string:string}, host: Github.Host): integer
  local ref, name, repository = env["HEAD_REF"] or "", env["ARTIFACT"] or "", env["GITHUB_REPOSITORY"] or ""
  local entry = QueueVerdicts.entry_of(ref)
  if entry == nil or not name:match("^[%w._-]+$") or not repository:match("^[%w._-]+/[%w._-]+$") then
    local _, _ = Fs.put(Fs.stderr, "queue-tried-run: HEAD_REF, ARTIFACT and GITHUB_REPOSITORY must name " ..
        "a merge-queue ref, an artifact and a repository\n")
    return 2
  end
  local own = math.tointeger(tonumber(env["RUN_ID"] or ""))
  local ids, trouble = tried_runs(host, repository, entry, own)
  local why = if ids == nil then trouble else "no failed merge-queue run of pull request " .. entry .. " is listed" end
  for _, id in ipairs(ids or {}) do
    local held, absent = holds_artifact(host, repository, id, name)
    if held then
      host.output("run=" .. tostring(id))
      host.print("merge-queue run " .. tostring(id) .. " of pull request " .. entry .. " failed and uploaded " .. name)
      return 0
    end
    why = absent
  end
  host.print("no verdicts from an earlier try: " .. why .. "; the suites run what they would have answered")
  return 0
end

function QueueVerdicts.find_tried_command(_argv: {string}): integer
  local env = Env.all()
  return QueueVerdicts.find_tried(env, Github.live(env))
end

--- `name` quoted as an SQL identifier.
local function quoted(name: string): string
  return '"' .. name:gsub('"', '""') .. '"'
end

--- The texts of column 1 of `sql`'s rows on `db`, nil and why.
local function column(db: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): {string}?, string
  local rows, trouble = db:text_rows(sql, values)
  if rows == nil then return nil, tostring(trouble) end
  local out: mut {string} = {}
  for _, row in ipairs(rows) do out[#out + 1] = row:text(1) end
  return out, ""
end

--- Takes the rows of every table of the database `from` into the table of
--- the same name in `into`, in one transaction: a row whose primary key
--- `into` holds already is replaced, since a key names everything its
--- verdict was reached under. A table or index `into` lacks is made as
--- `from` made it; a column only one of them has is left out. The rows
--- taken, or nil and why.
local function merged(into: string, from: string): integer?, string
  local db, opened = Sqlite.open(into, { writable = true })
  if db == nil then return nil, tostring(opened) end
  local function steps(): integer?, string
    local attached, trouble = db:run("ATTACH DATABASE ?1 AS queue", { { text = from } })
    if not attached then return nil, tostring(trouble) end
    local begun, begin_trouble = db:exec("BEGIN IMMEDIATE")
    if not begun then return nil, tostring(begin_trouble) end
    local function within(): integer?, string
      local made, made_trouble = db:text_rows("SELECT name, sql FROM queue.sqlite_schema " ..
          "WHERE type IN ('table', 'index') AND sql IS NOT NULL AND name NOT LIKE 'sqlite_%' " ..
          "AND name NOT IN (SELECT name FROM main.sqlite_schema) ORDER BY type = 'index', name")
      if made == nil then return nil, tostring(made_trouble) end
      for _, row in ipairs(made) do
        -- One statement that makes a table or an index, as SQLite keeps
        -- it: a file whose schema holds more is no cache of ours.
        local sql = row:text(2)
        if sql:match("^CREATE TABLE ") == nil and sql:match("^CREATE INDEX ") == nil or sql:find(";", 1, true) ~= nil then
          return nil, row:text(1) .. " is made by no single CREATE TABLE or CREATE INDEX"
        end
        local ok, why = db:exec(sql)
        if not ok then return nil, "making " .. row:text(1) .. ": " .. tostring(why) end
      end
      local tables, tables_trouble = column(db, "SELECT name FROM queue.sqlite_schema " ..
          "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      if tables == nil then return nil, tables_trouble end
      local taken = 0
      for _, name in ipairs(tables) do
        local shared, shared_trouble = column(db, "SELECT q.name FROM pragma_table_info(?1, 'queue') AS q " ..
            "JOIN pragma_table_info(?1, 'main') AS m ON m.name = q.name ORDER BY q.cid", { { text = name } })
        if shared == nil then return nil, shared_trouble end
        if #shared > 0 then
          local names: mut {string} = {}
          for i, each in ipairs(shared) do names[i] = quoted(each) end
          local list = table.concat(names, ", ")
          local ok, why = db:run("INSERT OR REPLACE INTO main." .. quoted(name) .. " (" .. list ..
              ") SELECT " .. list .. " FROM queue." .. quoted(name))
          if not ok then return nil, "taking " .. name .. ": " .. tostring(why) end
          local counted, count_trouble = column(db, "SELECT changes()")
          if counted == nil then return nil, count_trouble end
          taken = taken + (math.tointeger(tonumber(counted[1])) or 0)
        end
      end
      return taken, ""
    end
    local taken, why = within()
    if taken == nil then
      local _, _ = db:exec("ROLLBACK")
      return nil, why
    end
    local committed, commit_trouble = db:exec("COMMIT")
    if not committed then return nil, tostring(commit_trouble) end
    return taken, ""
  end
  local taken, why = steps()
  local _, _ = db:close()
  if taken == nil then return nil, why end
  return taken, ""
end

--- Merges each `.db` file in `from` into the file of the same name in
--- `into` (`merged`), and puts a copy where `into` has none. A file that
--- cannot be merged is left as it was and said: the suites run what it
--- would have answered. 2 where a directory is not absolute, else 0.
function QueueVerdicts.merge(from: string, into: string): QueueVerdicts.Said
  if from:sub(1, 1) ~= "/" or into:sub(1, 1) ~= "/" or from:find("\0", 1, true) ~= nil or
      into:find("\0", 1, true) ~= nil then
    return { code = 2, out = "", err = "verdicts-merge: FROM and the cache's directory must be absolute paths\n" }
  end
  local listed, _ = Fs.list(from)
  local names: mut {string} = {}
  for _, entry in ipairs(listed or {}) do
    if entry:sub(-3) == ".db" then names[#names + 1] = entry end
  end
  table.sort(names)
  if #names == 0 then
    return { code = 0, out = "verdicts-merge: no verdicts from the merge queue in " .. from .. "\n", err = "" }
  end
  local out: mut {string} = {}
  local err: mut {string} = {}
  local made, made_trouble = Fs.mkdirs(into)
  if not made then
    return { code = 0, out = "", err = "verdicts-merge: " .. tostring(made_trouble) .. "\n" }
  end
  for _, name in ipairs(names) do
    local source, target = from .. "/" .. name, into .. "/" .. name
    local present, _ = Fs.stat(target)
    if present == nil then
      local bytes, read_trouble = Fs.read(source)
      local ok, why = false, tostring(read_trouble)
      if bytes ~= nil then
        local wrote_ok, wrote_why = Fs.write(target, bytes)
        ok, why = wrote_ok, if wrote_ok then "" else tostring(wrote_why) end
      end
      if ok then
        out[#out + 1] = "verdicts-merge: " .. name .. ": the merge queue's, whole (none was restored)"
      else
        err[#err + 1] = "verdicts-merge: " .. name .. ": " .. why
      end
    else
      local taken, why = merged(target, source)
      if taken ~= nil then
        out[#out + 1] = "verdicts-merge: " .. name .. ": took " .. Plural.count(taken, "row") .. " from the merge queue"
      else
        err[#err + 1] = "verdicts-merge: " .. name .. ": left as restored: " .. why
      end
    end
  end
  local function text(lines: {string}): string
    if #lines == 0 then return "" end
    return table.concat(lines, "\n") .. "\n"
  end
  return { code = 0, out = text(out), err = text(err) }
end

--- `driver.tl verdicts-merge FROM`, into the directory of the file
--- COSMIC_VERDICT_CACHE names.
function QueueVerdicts.merge_command(argv: {string}): integer
  local path = Env.get("COSMIC_VERDICT_CACHE") or ""
  local said: QueueVerdicts.Said
  if path:sub(1, 1) ~= "/" then
    said = { code = 0, out = "verdicts-merge: COSMIC_VERDICT_CACHE names no file; nothing to merge into\n", err = "" }
  else
    said = QueueVerdicts.merge(argv[1] or "", Fs.dirname(path))
  end
  if said.out ~= "" then local _, _ = Fs.put(Fs.stdout, said.out) end
  if said.err ~= "" then local _, _ = Fs.put(Fs.stderr, said.err) end
  return said.code
end

--- The file, beside the verdicts the queue uploads, that names the cache
--- they belong in: what the queue's `leg-host-id` named, its host's
--- kernel among it. The relay on main's push (relay.yml) runs on another
--- runner, whose kernel may be another, so it reads the name from here
--- rather than naming its own host.
local KEY_FILE <const> = "cache-key"

--- Whether `key` is the start of a verdict cache's name as `leg-host-id`
--- writes it (cosmic_ci/host_id.tl): `verdicts-`, the leg and the host's
--- parts, ending in `-`; of the leg `leg` where one is named, whose name
--- is followed by the host's two digests alone (16 hex digits each), so
--- the cache of another job of that host (`linux-x86_64-checked-...`) is
--- none.
local function is_key(key: string, leg?: string): boolean
  if leg ~= nil then
    local start = "verdicts-" .. leg .. "-"
    if key:sub(1, #start) ~= start then return false end
    local rest = key:sub(#start + 1)
    if #rest ~= 34 or rest:match("^%x+%-%x+%-$") == nil or rest:sub(17, 17) ~= "-" then
      return false
    end
  end
  return #key <= 200 and key:match("^verdicts%-[%w_.%-]+%-$") ~= nil
end

--- Writes `key`, the cache the verdicts in `dir` belong in, to `dir`'s
--- KEY_FILE. 2 where `key` is no verdict cache's name, 1 where the file
--- cannot be written, else 0.
function QueueVerdicts.name(dir: string, key: string): QueueVerdicts.Said
  if not is_key(key) then
    return { code = 2, out = "", err = "verdicts-name: VERDICTS names no verdict cache: " .. key .. "\n" }
  end
  local wrote, why = Fs.write(dir .. "/" .. KEY_FILE, key .. "\n")
  if not wrote then
    return { code = 1, out = "", err = "verdicts-name: " .. tostring(why) .. "\n" }
  end
  return { code = 0, out = "verdicts-name: the verdicts in " .. dir .. " belong in " .. key .. "\n", err = "" }
end

--- `driver.tl verdicts-name DIR`, of the cache VERDICTS names.
function QueueVerdicts.name_command(argv: {string}): integer
  local said = QueueVerdicts.name(argv[1] or ".", Env.get("VERDICTS") or "")
  if said.out ~= "" then local _, _ = Fs.put(Fs.stdout, said.out) end
  if said.err ~= "" then local _, _ = Fs.put(Fs.stderr, said.err) end
  return said.code
end

--- `driver.tl verdicts-key DIR LEG`: writes `verdicts=<name>` to the
--- step's outputs, the cache of the leg `leg` the queue's verdicts in `dir`
--- belong in ([`QueueVerdicts.name`]). Where `dir` names none, or one that
--- is no verdict cache of that leg, it says so and writes nothing, and the
--- relay saves no verdicts. Always 0.
function QueueVerdicts.key(dir: string, leg: string, host: Github.Host): integer
  local text, _ = Fs.read(dir .. "/" .. KEY_FILE)
  local key = (text or ""):gsub("\n$", "")
  if not is_key(key, leg) then
    host.print("verdicts-key: " .. dir .. " names no verdict cache of " .. leg .. "; no verdicts are relayed")
    return 0
  end
  host.output("verdicts=" .. key)
  host.print("verdicts-key: the merge queue's verdicts belong in " .. key)
  return 0
end

--- `driver.tl verdicts-key DIR LEG`, on the live API's host.
function QueueVerdicts.key_command(argv: {string}): integer
  local env = Env.all()
  return QueueVerdicts.key(argv[1] or ".", argv[2] or "", Github.live(env))
end

--- What main's branch is read for.
local record RefRow
  object?: any
end
local REF_ROW <const> = Shape.record_of("RefRow")
local record ObjectRow
  sha?: any
end
local OBJECT_ROW <const> = Shape.record_of("ObjectRow")

--- `driver.tl main-newest`: writes `newest=false` to the step's outputs
--- where main in GITHUB_REPOSITORY has moved past SHA, so main's push of
--- SHA leaves the save of a cache the relay keeps (relay.yml) to the push
--- of the newer commit: its own, saved later, would be the newest and
--- lack what the newer commit's relay saved. `newest=true` where main is
--- SHA; nothing where GitHub does not say, and the push saves as before.
--- 2 where the step names no commit or repository, else 0.
function QueueVerdicts.newest(env: {string:string}, host: Github.Host): integer
  local sha, repository = env["SHA"] or "", env["GITHUB_REPOSITORY"] or ""
  if not Github.is_commit(sha) or not repository:match("^[%w._-]+/[%w._-]+$") then
    local _, _ = Fs.put(Fs.stderr, "main-newest: SHA and GITHUB_REPOSITORY must name a commit and a repository\n")
    return 2
  end
  local pages = Github.ask(host, "repos/" .. repository .. "/git/ref/heads/main", false, LOOKUP_SECONDS)
  local head = ""
  local ref, _ = REF_ROW:decode_into((pages or {})[1] or "")
  if ref ~= nil then
    local object, _ = OBJECT_ROW:into(ref.object)
    if object ~= nil then
      local named = object.sha
      if named is string then head = named end
    end
  end
  if not Github.is_commit(head) then
    host.print("main-newest: GitHub did not say where main is; this run saves its caches")
    return 0
  end
  host.output("newest=" .. tostring(head == sha))
  if head ~= sha then
    host.print("main-newest: main has moved to " .. head .. "; its relay saves the caches")
  end
  return 0
end

function QueueVerdicts.newest_command(_argv: {string}): integer
  local env = Env.all()
  return QueueVerdicts.newest(env, Github.live(env))
end

return QueueVerdicts
