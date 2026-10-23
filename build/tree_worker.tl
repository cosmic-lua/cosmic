--- What a worker of the whole-tree checks serves ([`build.tree_shard`]): the phases of the build's workers
--- ([`build.worker`]) and one for each check that makes its answers in them. A worker makes a file's answer by the
--- check's own code ([`build.tree_checks`]'s `read_outcome` and `generate`) over a memo of its own in memory, and hands
--- back the text that code kept there.
local Sqlite = require("cosmic.sqlite")
local check_memo = require("build.check_memo")
local tree_checks = require("build.tree_checks")
local tree_shard = require("build.tree_shard")
local worker = require("build.worker")
local type compiler = require("build.compiler")

local record tree_worker
  --- Serves phases as [`worker.serve`] does, with the compiler the tool carries, until the end of its input, and answers the
  --- exit status.
  serve: function(): integer
end

--- What `read` makes of a file: the text its memo keeps. `extra` begins with the salt the check keys by, which keeps each file's
--- answer apart from every other's in the worker's memo: one key for every file would answer each with the first's.
local function reading(memo: Sqlite.Handle, built: compiler, file: string, source: string, extra: string): {string}
  local salt = extra:match("^([^\n]*)\n")
  if salt == nil then return {} end
  local key = check_memo.key(salt, "tl", source)
  local held: {compiler} = { built }
  local _, _ = tree_checks.read_outcome(file, source, memo, key, held)
  local kept = check_memo.get(memo, "read", key)
  if kept == nil then return {} end
  return { kept }
end

--- What `generated` makes of a file: the text its memo keeps, and the fork's Lua. `extra` holds the salts the check keys by and
--- the fork's Lua where the check's memo held it, each on a line.
local function generating(memo: Sqlite.Handle, built: compiler, file: string, source: string, extra: string): {string}
  local salt, fork_salt, fork_row = extra:match("^([^\n]*)\n([^\n]*)\n(.*)$")
  if salt == nil or fork_salt == nil or fork_row == nil then return {} end
  local fork_key = check_memo.key(fork_salt, "tl", source)
  if fork_row ~= "" then
    check_memo.put(memo, "generated", fork_key, fork_row)
  end
  local held: {compiler} = { built }
  tree_checks.generate(file, source, memo, salt, fork_salt, held)
  local kept = check_memo.get(memo, "generated", check_memo.key(salt, "tl", source))
  if kept == nil then return {} end
  return { kept, check_memo.get(memo, "generated", fork_key) or "" }
end

function tree_worker.serve(): integer
  local opened, _ = Sqlite.open(":memory:", { writable = true })
  if opened == nil then return 1 end
  local memo: Sqlite.Handle = opened
  local _, _ = check_memo.prepare(memo, "read")
  local more: {string: function(compiler, string, integer): string} = {}
  more["tree_read"] = function(built: compiler, job: string, index: integer): string
    return tree_shard.serve(job, index, function(b: compiler, file: string, source: string, extra: string): {string}
      return reading(memo, b, file, source, extra)
    end, built)
  end
  more["tree_generated"] = function(built: compiler, job: string, index: integer): string
    return tree_shard.serve(job, index, function(b: compiler, file: string, source: string, extra: string): {string}
      return generating(memo, b, file, source, extra)
    end, built)
  end
  return worker.serve(nil, more)
end

return tree_worker
