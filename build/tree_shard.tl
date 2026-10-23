--- The per-file work of the whole-tree checks ([`build.tree_checks`]), done in the processes of a [`build.workers`]
--- pool, so that a tree whose answers the memo ([`build.check_memo`]) lacks costs the processors' count less than it
--- costs one.
---
--- A check hands over its files and the salt it keys them by; the files the memo has no answer for go to the workers
--- ([`build.tree_worker`]), each of which makes the text the check's own code makes of its share of them and writes it
--- to a file of its own beside the job. The text is put in the memo under the key the check looks it up by, so the check
--- then runs as it would have, finding the memo full. What a worker makes is what the check's own process would have: a
--- file a worker did not answer, because it was lost or the pool could not start, is left to the check, which makes its
--- answer itself. A pool changes how long a check takes and nothing it finds.
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local check_memo = require("build.check_memo")
local bind = require("build.bind")
local type compiler = require("build.compiler")

local text = bind.text
local integer = bind.integer

local record tree_shard
  --- The workers a check shards over: `ready` starts them where `bytes` of source is worth them, `size` is how many
  --- there are, `path` names a file of the pool's scratch directory and `run` has the first `count` of them serve a phase
  --- on a job and answers why each did not finish, "" for one that did ([`worker.Pool`] is these, which this module
  --- cannot name: [`build.worker`] loads it). `say` tells what a wait is for.
  record Shards
    ready: function(bytes: integer): boolean
    size: function(): integer
    path: function(name: string): string | nil, string
    run: function(phase: string, job: string, count: integer): {string}
    say: function(line: string)
  end
  --- What a worker makes of one file: the texts the check's memo keeps, the file's first and the fork's Lua after it.
  type Compute = function(built: compiler, file: string, source: string, extra: string): {string}
  --- Makes the memo's answers for the files of `files` (rows of a path and its source) that `memo` lacks under `kind`, in
  --- the workers of `shards`, where there are enough to be worth starting them, and puts each in `memo`: a file's key is
  --- `salt`'s and the dialect and source's ([`check_memo.key`]), and where `fork_salt` is not "" the answer comes with the
  --- fork's Lua, which keeps under `fork_salt`'s key. The files left out are those no check of the fork reads
  --- ([`checker/tl.tl`] and the declaration files). Answers how many files the workers answered.
  warm: function(shards: Shards | nil, memo: Sqlite.Handle, kind: string, files: {{string}}, salt: string,
                 fork_salt: string): integer
  --- The worker's side of a phase over the job `job`, as shard `index`, making the texts of each of its files as
  --- `compute` does with `built`: answers "" or why not.
  serve: function(job: string, index: integer, compute: Compute, built: compiler): string
end

--- How many answers a worker commits at a time, so that one lost partway leaves what it reached.
local batch <const> = 16

--- How many files make workers worth starting: a worker takes some seconds to load the checker before it serves, which
--- the answers of fewer files do not repay.
local threshold <const> = 32

--- One file to answer, with the keys its texts are kept under.
local record Item
  file: string
  source: string
  extra: string
  key: string
  also: string
end

--- An item with how much source it holds, to deal the largest first, and its place.
local record Entry
  item: Item
  size: integer
  ordinal: integer
end

--- Where worker `index`'s answers to `job` are.
local function results_of(job: string, index: integer): string
  return job .. "." .. tostring(index)
end

--- A new file at `path` with `statements` run on it.
local function created(path: string, statements: {string}): Sqlite.Handle | nil, string
  local db, trouble = Sqlite.open(path, { writable = true })
  if db == nil then return nil, trouble end
  for _, statement in ipairs(statements) do
    local ok, why = db:exec(statement)
    if not ok then
      local _, _ = db:close()
      return nil, why
    end
  end
  return db, ""
end

--- Writes the job of `items` for `count` shards at `path`: each shard takes every `count`th item, the largest first, so
--- that the shards are of about the same size. Answers why it could not.
local function written(path: string, items: {Item}, count: integer): string | nil
  local jobs, create_trouble = created(path, {
    "PRAGMA synchronous = OFF",
    "CREATE TABLE items (ordinal INTEGER PRIMARY KEY, shard INTEGER NOT NULL, file TEXT NOT NULL, " ..
      "source TEXT NOT NULL, extra TEXT NOT NULL)",
    "BEGIN",
  })
  if jobs == nil then return create_trouble end
  local order: {Entry} = {}
  for ordinal, item in ipairs(items) do
    order[#order + 1] = { item = item, size = #item.source, ordinal = ordinal }
  end
  table.sort(order, function(a: Entry, b: Entry): boolean
    if a.size ~= b.size then return a.size > b.size end
    return a.ordinal < b.ordinal
  end)
  for rank, entry in ipairs(order) do
    local ok, why = Sqlite.run(jobs,
      "INSERT INTO items (ordinal, shard, file, source, extra) VALUES (?1, ?2, ?3, ?4, ?5)",
      { integer(entry.ordinal), integer((rank - 1) % count + 1), text(entry.item.file), text(entry.item.source),
        text(entry.item.extra) })
    if not ok then
      local _, _ = jobs:close()
      return why
    end
  end
  local committed, commit_trouble = jobs:exec("COMMIT")
  local _, _ = jobs:close()
  if not committed then return commit_trouble end
  return nil
end

--- The texts the workers wrote for `job`, by the ordinal of the item each answers.
local function read_back(job: string, count: integer): {integer: {string}}
  local made: {integer: {string}} = {}
  for index = 1, count do
    local results, _ = Sqlite.open(results_of(job, index))
    if results ~= nil then
      local rows, _ = Sqlite.text_rows(results, "SELECT ordinal, value FROM results ORDER BY ordinal, slot")
      if rows ~= nil then
        for _, row in ipairs(rows) do
          local ordinal = math.tointeger(tonumber(row:text(1)))
          if ordinal ~= nil then
            local list: {string} = made[ordinal] or {}
            list[#list + 1] = row:text(2)
            made[ordinal] = list
          end
        end
      end
      local _, _ = results:close()
    end
  end
  return made
end

--- Has the workers of `shards` make the texts of `items` for `phase`: by each item's place, the texts a worker made of it.
local function made_by(shards: tree_shard.Shards, phase: string, items: {Item}): {integer: {string}}
  local count = math.min(shards.size(), #items)
  if count < 1 then return {} end
  local job, _ = shards.path("tree")
  if job == nil then return {} end
  if written(job, items, count) ~= nil then return {} end
  for index, why in ipairs(shards.run("tree_" .. phase, job, count)) do
    if why ~= "" then
      shards.say(phase .. ": worker " .. tostring(index) .. " of " .. tostring(count) .. " did not finish (" .. why ..
          "); the check makes the answers it left itself")
    end
  end
  return read_back(job, count)
end

function tree_shard.warm(shards: tree_shard.Shards | nil, memo: Sqlite.Handle, kind: string, files: {{string}}, salt: string,
                         fork_salt: string): integer
  if shards == nil then return 0 end
  local lacking: {Item} = {}
  local bytes = 0
  for _, row in ipairs(files) do
    local file, source = row[1], row[2]
    if file ~= nil and source ~= nil and file ~= "checker/tl.tl" and not file:match("%.d%.tl$") then
      local key = check_memo.key(salt, "tl", source)
      if check_memo.get(memo, kind, key) == nil then
        local fork_key = ""
        local held = ""
        if fork_salt ~= "" then
          fork_key = check_memo.key(fork_salt, "tl", source)
          held = check_memo.get(memo, kind, fork_key) or ""
        end
        lacking[#lacking + 1] = { file = file, source = source, key = key, also = fork_key,
          extra = salt .. "\n" .. fork_salt .. "\n" .. held }
        bytes = bytes + #source
      end
    end
  end
  if #lacking < threshold or shards.size() < 2 or not shards.ready(bytes) then return 0 end
  shards.say(kind .. ": making " .. String.counted(#lacking, "answer") .. " the memo lacks in " ..
      String.counted(shards.size(), "process", "processes"))
  local answered = 0
  for at, texts in pairs(made_by(shards, kind, lacking)) do
    local item = lacking[at]
    local first = texts[1]
    if item ~= nil and first ~= nil then
      answered = answered + 1
      check_memo.put(memo, kind, item.key, first)
      local fork = texts[2]
      if item.also ~= "" and fork ~= nil and fork ~= "" then
        check_memo.put(memo, kind, item.also, fork)
      end
    end
  end
  return answered
end

function tree_shard.serve(job: string, index: integer, compute: tree_shard.Compute, built: compiler): string
  local jobs, open_trouble = Sqlite.open(job)
  if jobs == nil then return open_trouble end
  local rows, rows_trouble = Sqlite.text_rows(jobs,
    "SELECT ordinal, file, source, extra FROM items WHERE shard = ?1 ORDER BY ordinal", { integer(index) })
  local _, _ = jobs:close()
  if rows == nil then return rows_trouble end
  local out, out_trouble = created(results_of(job, index), {
    "PRAGMA synchronous = OFF",
    "CREATE TABLE results (ordinal INTEGER NOT NULL, slot INTEGER NOT NULL, value TEXT NOT NULL, " ..
      "PRIMARY KEY (ordinal, slot)) WITHOUT ROWID",
    "BEGIN",
  })
  if out == nil then return out_trouble end
  local pending = 0
  for _, row in ipairs(rows) do
    local ordinal = math.tointeger(tonumber(row:text(1))) or 0
    for slot, value in ipairs(compute(built, row:text(2), row:text(3), row:text(4))) do
      local ok, why = Sqlite.run(out, "INSERT INTO results (ordinal, slot, value) VALUES (?1, ?2, ?3)",
        { integer(ordinal), integer(slot), text(value) })
      if not ok then
        local _, _ = out:close()
        return why
      end
    end
    pending = pending + 1
    if pending >= batch then
      pending = 0
      local ok, why = out:exec("COMMIT")
      if ok then ok, why = out:exec("BEGIN") end
      if not ok then
        local _, _ = out:close()
        return why
      end
    end
  end
  local ok, why = out:exec("COMMIT")
  local _, _ = out:close()
  if not ok then return why end
  return ""
end

return tree_shard
