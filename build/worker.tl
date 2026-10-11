--- A build's phases, run in the processes of a [`build.workers`] pool.
---
--- A phase's job is a SQLite file the build writes into the pool's
--- scratch directory, and each worker writes its results to a file of
--- its own beside it (`job.<number>`), which the build reads back. A
--- worker that stops partway leaves the results it reached. Whatever a
--- phase has no result for, the build does itself ([`worker.parse`] and
--- [`worker.compile`] say how), so a worker that fails, or one that is
--- lost, changes how long a build takes and nothing it makes.
---
--- Nothing a worker makes depends on which worker made it: a source
--- parses, and a module compiles, to the same rows and bytes in any
--- process ([`build.shards`] chooses only who does what).

local Log = require("cosmic.log")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local analysis_schema = require("build.analysis_schema")
local bind = require("build.bind")
local compilation = require("build.compilation")
local derivation = require("build.derivation")
local receivers = require("build.receivers")
local shards = require("build.shards")
local teal = require("build.teal")
local type compiler = require("build.compiler")
local type importer = require("build.importer")

local log = Log.new("cosmic")

local text = bind.text
local blob = bind.blob
local integer = bind.integer

local type Fresh = derivation.Fresh
local type Module = compilation.Module

local record worker
  --- The workers of one build, as a phase reaches them ([`build.workers`]
  --- makes one).
  record Pool
    --- How long the workers may still be loading, in nanoseconds: 0 once
    --- they are expected to serve a job at once, and for a pool with none.
    warming: function(): integer
    --- How many workers a phase can use: the running ones, or the most
    --- one could start before any has.
    size: function(): integer
    --- A path of the pool's own scratch directory, which exists while
    --- workers do. Nil and why where there is none.
    path: function(name: string): string | nil, string
    --- Has each of the first `count` workers serve `phase` on `job`, a
    --- file this module reads, as the worker numbered from 1 that it is of
    --- `count`, and waits for them all. Each answer is "" for a worker
    --- that finished, and why for one that did not: its results are then
    --- missing or only partly there, which the phase meets by doing that
    --- work itself.
    run: function(phase: string, job: string, count: integer): {string}
  end
end

--- Where worker `index`'s results of `job` are.
local function results_of(job: string, index: integer): string
  return job .. "." .. index
end

--- Runs each statement of `statements` on `db`.
local function make(db: Sqlite.Handle, statements: {string}): boolean, string
  for _, statement in ipairs(statements) do
    local ok, trouble = db:exec(statement)
    if not ok then return false, trouble end
  end
  return true, ""
end

--- A new file at `path` with `statements` run on it, kept apart from
--- anything that reads it until it is closed.
local function created(path: string, statements: {string}): Sqlite.Handle | nil, string
  local db, trouble = Sqlite.open(path, { writable = true })
  if db == nil then return nil, trouble end
  local ok, why = make(db, { "PRAGMA synchronous = OFF" })
  if ok then ok, why = make(db, statements) end
  if not ok then
    local _, _ = db:close()
    return nil, why
  end
  return db, ""
end

--- The results a worker wrote at `path`, or nil where it left none: a
--- worker that was lost before its first result.
local function opened(path: string): Sqlite.Handle | nil
  local db, _ = Sqlite.open(path)
  return db
end

-- Parsing

--- Deals `fresh` to `count` shards of about the same size in source,
--- the largest first, each source to the lightest shard so far.
local function dealt(fresh: {Fresh}, count: integer): {integer}
  local order: {integer} = {}
  for at = 1, #fresh do order[at] = at end
  table.sort(order, function(a: integer, b: integer): boolean
    if #fresh[a].source ~= #fresh[b].source then return #fresh[a].source > #fresh[b].source end
    return a < b
  end)
  local busy: {integer} = {}
  for shard = 1, count do busy[shard] = 0 end
  local shard_of: {integer} = {}
  for _, at in ipairs(order) do
    local best = 1
    for shard = 2, count do
      if busy[shard] < busy[best] then best = shard end
    end
    shard_of[at] = best
    busy[best] = busy[best] + #fresh[at].source + 1
  end
  return shard_of
end

--- Writes the job of a parse into the pool's scratch directory: the
--- sources of `fresh`, each marked with the shard `shard_of` deals it
--- to. Answers the job's path, or nil and why.
local function parse_job(pool: worker.Pool, fresh: {Fresh},
                         shard_of: {integer}): string | nil, string
  local job, job_trouble = pool.path("parse")
  if job == nil then return nil, job_trouble end
  local jobs, create_trouble = created(job, {
    "CREATE TABLE sources (ordinal INTEGER PRIMARY KEY, shard INTEGER NOT NULL, " ..
      "source_hash TEXT NOT NULL, file TEXT NOT NULL, source TEXT NOT NULL, " ..
      "mapped INTEGER NOT NULL)",
    "BEGIN",
  })
  if jobs == nil then return nil, create_trouble end
  for at, one in ipairs(fresh) do
    local ok, why = Sqlite.run(jobs,
      "INSERT INTO sources (ordinal, shard, source_hash, file, source, mapped) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      { integer(at), integer(shard_of[at]), text(one.source_hash), text(one.file),
        text(one.source), integer(one.mapped and 1 or 0) })
    if not ok then
      local _, _ = jobs:close()
      return nil, why
    end
  end
  local committed, commit_trouble = jobs:exec("COMMIT")
  local closed, close_trouble = jobs:close()
  if not committed then return nil, commit_trouble end
  if not closed then return nil, close_trouble end
  return job, ""
end

--- Parses `all`, as [`derivation.parse_fresh`] does into `db`, in the
--- pool's workers: each source is parsed by one of them, and its rows
--- are written here in `all`'s order, as a parse here writes them. While
--- the workers load ([`worker.Pool`]'s `warming`) the first sources are
--- parsed here instead. A source no worker parsed is parsed here, which
--- says why where it cannot be. The answer and the counts are
--- `parse_fresh`'s, and `tally.worked` counts the sources a worker parsed.
--- @param pool the workers, already ready for these sources
--- @param built the compiler a source that no worker parsed is parsed with
function worker.parse(pool: worker.Pool, db: Sqlite.Handle, built: compiler,
                      all: {Fresh}, tally: derivation.Parses,
                      made: {derivation.Source}): boolean, string
  local here = 0
  while here < #all and pool.warming() > 0 do
    local ok, why = derivation.parse_fresh(db, built, { all[here + 1] }, tally, made)
    if not ok then return false, why end
    here = here + 1
  end
  local fresh: {Fresh} = table.move(all, here + 1, #all, 1, {})
  if #fresh == 0 then return true, "" end
  local count = math.min(pool.size(), #fresh)
  local shard_of = dealt(fresh, count)
  local job, job_trouble = parse_job(pool, fresh, shard_of)
  local widths, widths_trouble = derivation.table_widths(db)
  if job == nil or widths == nil then
    local _, _ = log:complain("build: workers: " .. (job_trouble ~= "" and job_trouble or widths_trouble) ..
        "; parsing in this process")
    return derivation.parse_fresh(db, built, fresh, tally, made)
  end

  local _ = pool.run("parse", job, count)
  local read: {integer:Sqlite.Handle} = {}
  for shard = 1, count do read[shard] = opened(results_of(job, shard)) end
  local function close_results()
    for shard = 1, count do
      local results = read[shard]
      if results ~= nil then
        local _, _ = results:close()
      end
    end
  end
  for at, one in ipairs(fresh) do
    local taken = false
    local results = read[shard_of[at]]
    if results ~= nil then
      local rows, _ = Sqlite.rows(results,
        "SELECT rows FROM parses WHERE source_hash = ?1", { text(one.source_hash) })
      local names, _ = Sqlite.text_rows(results,
        "SELECT name FROM requires WHERE source_hash = ?1 ORDER BY ordinal",
        { text(one.source_hash) })
      if rows ~= nil and names ~= nil and #rows == 1 then
        local packed = rows[1][1].blob
        local unpacked = packed ~= nil and derivation.unpacked_parse(packed, widths) or nil
        if unpacked ~= nil then
          local requires: {string} = {}
          for _, row in ipairs(names) do requires[#requires + 1] = row[1] end
          local put, _ = derivation.put_parse(db, one.source_hash, requires, unpacked)
          taken = put
        end
      end
    end
    if taken then
      tally.parsed = tally.parsed + 1
      tally.worked = tally.worked + 1
      made[#made + 1] = { source_hash = one.source_hash, mapped = one.mapped }
    else
      local ok, why = derivation.parse_fresh(db, built, { one }, tally, made)
      if not ok then
        close_results()
        return false, why
      end
    end
  end
  close_results()
  return true, ""
end

--- The worker's side of a parse: the sources of shard `index` in the
--- job, parsed in order, their rows packed ([`derivation.packed_parses`])
--- into the worker's results. Stops at the first source that does not
--- parse, which the build then parses itself.
local function serve_parse(built: compiler, job: string, index: integer): string
  local jobs, open_trouble = Sqlite.open(job)
  if jobs == nil then return open_trouble end
  local rows, rows_trouble = Sqlite.text_rows(jobs,
    "SELECT source_hash, file, source, mapped FROM sources WHERE shard = ?1 ORDER BY ordinal",
    { integer(index) })
  local _, _ = jobs:close()
  if rows == nil then return rows_trouble end
  local fresh: {Fresh} = {}
  for _, row in ipairs(rows) do
    fresh[#fresh + 1] = { source_hash = row[1], file = row[2], source = row[3], mapped = row[4] == "1" }
  end
  local scratch, scratch_trouble = Sqlite.open(":memory:", { writable = true })
  if scratch == nil then return scratch_trouble end
  local made_tables, tables_trouble = make(scratch, analysis_schema.statements)
  if not made_tables then
    local _, _ = scratch:close()
    return tables_trouble
  end
  local tally: derivation.Parses = { parsed = 0, shared = 0, worked = 0 }
  local made: {derivation.Source} = {}
  local parsed, parse_trouble = derivation.parse_fresh(scratch, built, fresh, tally, made)
  local packed, packed_trouble = derivation.packed_parses(scratch, made)
  local _, _ = scratch:close()
  if packed == nil then return packed_trouble end
  local out, out_trouble = created(results_of(job, index), {
    "CREATE TABLE parses (source_hash TEXT PRIMARY KEY, rows BLOB NOT NULL) WITHOUT ROWID",
    "CREATE TABLE requires (source_hash TEXT NOT NULL, ordinal INTEGER NOT NULL, " ..
      "name TEXT NOT NULL, PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID",
    "BEGIN",
  })
  if out == nil then return out_trouble end
  for _, one in ipairs(made) do
    local found = packed[one.source_hash]
    if found ~= nil then
      local ok, why = Sqlite.run(out, "INSERT INTO parses (source_hash, rows) VALUES (?1, ?2)",
        { text(one.source_hash), blob(found.rows) })
      for ordinal, name in ipairs(found.requires) do
        if ok then
          ok, why = Sqlite.run(out,
            "INSERT INTO requires (source_hash, ordinal, name) VALUES (?1, ?2, ?3)",
            { text(one.source_hash), integer(ordinal), text(name) })
        end
      end
      if not ok then
        local _, _ = out:close()
        return why
      end
    end
  end
  local committed, commit_trouble = out:exec("COMMIT")
  local _, _ = out:close()
  if not committed then return commit_trouble end
  if not parsed then return parse_trouble end
  return ""
end

-- Compiling

-- TODO: compile a shard in this process too: it waits, a processor idle,
-- for the whole phase. Waits on `compile_derived` ([`build.importer`])
-- compiling a module ahead of the loop that takes each result in order.

--- Compiles `wanted`, as [`compilation.generate`] does one by one, in
--- the pool's workers, and answers what they made, to be read as the
--- build reaches each module. A module's imports are checked by each
--- worker it needs them in ([`build.shards`]).
--- @param pool the workers, already ready for these modules
--- @param db the working database, whose `inputs` the workers read the
---   tree through
--- @param root the root the checker names files under
--- @param order every module of the build, imports first
--- @param wanted the modules to compile, by path
--- @param own_tree whether the tree is cosmic's own ([`compilation.generate`])
--- @param judged whether a module the contracts refuse is refused
--- @param lenient whether a table literal may omit a field ([`build.teal`]'s
---   `environment_for`)
--- @return what they made, or nil and why the job could not be made: ""
---   where one process does as well, or where a source declares a `global`,
---   and the build compiles it all itself
function worker.compile(pool: worker.Pool, db: Sqlite.Handle, root: string,
                        order: {Module}, wanted: {string:boolean}, own_tree: boolean,
                        judged: boolean, lenient: boolean): importer.Ahead | nil, string
  local items: {shards.Item} = {}
  local by_path: {string:Module} = {}
  for _, m in ipairs(order) do
    items[#items + 1] = { path = m.path, requires = m.requires, size = #m.source }
    by_path[m.path] = m
  end
  local sources, sources_trouble = Sqlite.text_rows(db,
    "SELECT path, kind, source FROM inputs WHERE kind <> 'vendor'")
  if sources == nil then return nil, sources_trouble end
  local inputs: {{string}} = sources
  -- A `global` a module declares stays in the checker's environment for
  -- every module checked after it, in the same process: one is refused for
  -- declaring it again unlike another, and one that names it is accepted
  -- without requiring its declarer. Workers each check some of the modules,
  -- so they would answer differently. No source of the tree declares one
  -- (its standard library's are the vendored compiler's), so a build that
  -- finds a line leading with the word, in code or in a string, compiles
  -- alone.
  for _, row in ipairs(inputs) do
    if row[3]:find("^%s*global%s") or row[3]:find("[\n;]%s*global%s") then return nil, "" end
  end
  local plan = shards.best(items, wanted, pool.size())
  local count = #plan
  if count < 2 then return nil, "" end
  local job, job_trouble = pool.path("compile")
  if job == nil then return nil, job_trouble end
  local jobs, create_trouble = created(job, {
    "CREATE TABLE inputs (path TEXT NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL, " ..
      "PRIMARY KEY (path, kind)) WITHOUT ROWID",
    "CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID",
    "CREATE TABLE modules (shard INTEGER NOT NULL, seq INTEGER NOT NULL, path TEXT NOT NULL, " ..
      "file TEXT NOT NULL, kind TEXT NOT NULL, generated INTEGER NOT NULL, " ..
      "tests TEXT NOT NULL, stubbed INTEGER NOT NULL, stub TEXT NOT NULL, " ..
      "pruned INTEGER NOT NULL, PRIMARY KEY (shard, seq)) WITHOUT ROWID",
    "BEGIN",
  })
  if jobs == nil then return nil, create_trouble end
  local writing: Sqlite.Handle = jobs
  local function fail(why: string): nil, string
    local _, _ = writing:close()
    return nil, why
  end
  for _, row in ipairs(inputs) do
    local ok, why = Sqlite.run(writing, "INSERT OR IGNORE INTO inputs (path, kind, source) VALUES (?1, ?2, ?3)",
      { text(row[1]), text(row[2]), text(row[3]) })
    if not ok then return fail(why) end
  end
  for name, value in pairs({ root = root, own_tree = own_tree and "1" or "0",
      judged = judged and "1" or "0", lenient = lenient and "1" or "0" }) do
    local ok, why = Sqlite.run(writing, "INSERT INTO meta (name, value) VALUES (?1, ?2)",
      { text(name), text(value) })
    if not ok then return fail(why) end
  end
  local shard_of: {string:integer} = {}
  for shard, paths in ipairs(plan) do
    for seq, path in ipairs(paths) do
      local m = by_path[path]
      shard_of[path] = shard
      local ok, why = Sqlite.run(writing,
        "INSERT INTO modules (shard, seq, path, file, kind, generated, tests, stubbed, stub, " ..
          "pruned) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        { integer(shard), integer(seq), text(m.path), text(m.file), text(m.kind),
          integer(m.generated and 1 or 0), text(table.concat(m.tests, "\n")),
          integer(m.stub ~= nil and 1 or 0), text(m.stub ~= nil and m.stub.text or ""),
          integer(m.stub ~= nil and m.stub.pruned and 1 or 0) })
      if not ok then return fail(why) end
    end
  end
  local committed, commit_trouble = writing:exec("COMMIT")
  if not committed then return fail(commit_trouble) end
  local closed, close_trouble = writing:close()
  if not closed then return nil, close_trouble end

  local _ = pool.run("compile", job, count)
  local read: {integer:Sqlite.Handle} = {}
  for shard = 1, count do read[shard] = opened(results_of(job, shard)) end
  local ahead: importer.Ahead = {
    take = function(path: string): compilation.Generated | nil
      local results = read[shard_of[path] or 0]
      if results == nil then return nil end
      local rows, _ = Sqlite.rows(results,
        "SELECT refused, lua, bytecode FROM made WHERE path = ?1", { text(path) })
      if rows == nil or #rows ~= 1 then return nil end
      local refs, _ = Sqlite.rows(results,
        "SELECT module, member, line FROM refs WHERE path = ?1 ORDER BY ordinal", { text(path) })
      if refs == nil then return nil end
      local lua, bytecode = rows[1][2].blob, rows[1][3].blob
      if lua == nil or bytecode == nil then return nil end
      local references: {receivers.Reference} = {}
      for _, row in ipairs(refs) do
        references[#references + 1] = { module = row[1].text or "", member = row[2].text or "",
          line = row[3].integer or 0 }
      end
      return { lua = lua, bytecode = bytecode, references = references,
        refused = rows[1][1].integer == 1 }
    end,
    close = function()
      for shard = 1, count do
        local results = read[shard]
        if results ~= nil then
          local _, _ = results:close()
        end
        read[shard] = nil
      end
    end,
  }
  return ahead, ""
end

--- The worker's side of a compile: the modules of shard `index` in the
--- job, compiled in order against one checker environment over the
--- job's `inputs`, each result kept as it is made. Stops at the first
--- module the compiler refuses, which the build compiles itself to say why.
local function serve_compile(built: compiler, job: string, index: integer): string
  local opened_jobs, open_trouble = Sqlite.open(job)
  if opened_jobs == nil then return open_trouble end
  local jobs: Sqlite.Handle = opened_jobs
  local function close_with(why: string): string
    local _, _ = jobs:close()
    return why
  end
  local meta, meta_trouble = Sqlite.text_rows(jobs, "SELECT name, value FROM meta")
  if meta == nil then return close_with(meta_trouble) end
  local settings: {string:string} = {}
  for _, row in ipairs(meta) do settings[row[1]] = row[2] end
  local rows, rows_trouble = Sqlite.text_rows(jobs,
    "SELECT m.path, m.file, m.kind, m.generated, m.tests, i.source, m.stubbed, m.stub, " ..
      "m.pruned FROM modules m " ..
      "JOIN inputs i ON i.path = m.path AND i.kind = m.kind " ..
      "WHERE m.shard = ?1 ORDER BY m.seq", { integer(index) })
  if rows == nil then return close_with(rows_trouble) end
  local modules: {{string}} = rows
  local env, env_trouble = teal.environment_for(built, jobs, settings.root, settings.lenient == "1")
  if env == nil then return close_with(env_trouble) end
  local typed = receivers.install(env)
  local own_tree, judged = settings.own_tree == "1", settings.judged == "1"
  local out, out_trouble = created(results_of(job, index), {
    "CREATE TABLE made (path TEXT PRIMARY KEY, refused INTEGER NOT NULL, lua BLOB NOT NULL, " ..
      "bytecode BLOB NOT NULL) WITHOUT ROWID",
    "CREATE TABLE refs (path TEXT NOT NULL, ordinal INTEGER NOT NULL, module TEXT NOT NULL, " ..
      "member TEXT NOT NULL, line INTEGER NOT NULL, PRIMARY KEY (path, ordinal)) WITHOUT ROWID",
  })
  if out == nil then return close_with(out_trouble) end
  local kept: Sqlite.Handle = out
  local function stop(why: string): string
    local _, _ = kept:close()
    return close_with(why)
  end
  for _, row in ipairs(modules) do
    local tests: {string} = {}
    for name in row[5]:gmatch("[^\n]+") do tests[#tests + 1] = name end
    local m: Module = {
      path = row[1], file = row[2], kind = row[3], source = row[6], source_hash = "",
      requires = {}, tests = tests, has_top_level_return = false, generated = row[4] == "1",
      key = "", graph_key = "", lua = "",
      stub = row[7] == "1" and { text = row[8], pruned = row[9] == "1" } or nil,
    }
    local generated, generate_trouble = compilation.generate(m, built, env, typed, own_tree, judged,
      function(_file: string, _source: string, _checked: compiler.Result): string
        return ""
      end)
    if generated == nil then return stop(generate_trouble) end
    local begun, begin_trouble = kept:exec("BEGIN")
    if not begun then return stop(begin_trouble) end
    local ok, why = Sqlite.run(kept,
      "INSERT INTO made (path, refused, lua, bytecode) VALUES (?1, ?2, ?3, ?4)",
      { text(m.path), integer(generated.refused and 1 or 0), blob(generated.lua),
        blob(generated.bytecode) })
    for ordinal, reference in ipairs(generated.references) do
      if ok then
        ok, why = Sqlite.run(kept,
          "INSERT INTO refs (path, ordinal, module, member, line) VALUES (?1, ?2, ?3, ?4, ?5)",
          { text(m.path), integer(ordinal), text(reference.module), text(reference.member),
            integer(reference.line) })
      end
    end
    if ok then ok, why = kept:exec("COMMIT") end
    if not ok then
      local _, _ = kept:exec("ROLLBACK")
      return stop(why)
    end
  end
  return stop("")
end

-- Serving

local phases: {string:function(compiler, string, integer): string} = {
  parse = serve_parse,
  compile = serve_compile,
}

--- Serves phases, a line of standard input each (`phase`, the job file,
--- this worker's number and how many workers there are, by tabs),
--- answering a line of standard output: `ok`, or `fail` and why. Ends
--- at the end of its input, and answers the exit status.
--- @param built the compiler the build runs, or the tool's own
function worker.serve(built?: compiler): integer
  local checker = built
  if checker == nil then
    local loaded, trouble = teal.load()
    if loaded == nil then
      local _, _ = Stream.to_fd(2):write("worker: " .. trouble .. "\n")
      return 1
    end
    checker = loaded
  end
  local input = Stream.lines(Stream.from_fd(0))
  local output = Stream.to_fd(1)
  while true do
    local line, _ = input:read()
    if line == nil then return 0 end
    local phase, job, index = line:match("^([^\t]+)\t([^\t]+)\t(%d+)\t%d+$")
    local serve = phase ~= nil and phases[phase] or nil
    local said = "unknown job: " .. line
    if serve ~= nil and job ~= nil then
      local ran, answer = pcall(serve, checker, job, math.tointeger(tonumber(index)) or 0)
      if ran and answer is string then
        said = answer
      else
        said = tostring(answer)
      end
    end
    local reply = said == "" and "ok" or "fail\t" .. (said:gsub("\n", " / "))
    local sent, _ = output:write(reply .. "\n")
    if not sent then return 1 end
  end
end

return worker
