--- The shards of the whole-tree checks ([`build.tree_shard`]): a file's answer comes back under its own key whichever
--- worker made it, a file the memo holds is not made again, and a check with too few files or no workers is left to
--- itself.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local check_memo = require("build.check_memo")
local tree_shard = require("build.tree_shard")
local type compiler = require("build.compiler")

Test.policy{ profiles = { "cosmic" } }

--- The files of a tree of `count` files, each with a source of its own.
local function files_of(count: integer): {{string}}
  local files: {{string}} = {}
  for at = 1, count do
    files[#files + 1] = { "f" .. at .. ".tl", "local x = " .. at }
  end
  return files
end

--- Shards of `size` workers that serve in this process, and the files each was asked for.
local function shards_of(size: integer, dir: string, asked: {string}): tree_shard.Shards
  local built: compiler = {} as compiler
  return {
    ready = function(_bytes: integer): boolean return true end,
    size = function(): integer return size end,
    path = function(name: string): string | nil, string return dir .. "/" .. name, "" end,
    run = function(_phase: string, job: string, count: integer): {string}
      local why: {string} = {}
      for index = 1, count do
        why[index] = tree_shard.serve(job, index, function(_b: compiler, file: string, source: string, _extra: string): {string}
          asked[#asked + 1] = file
          return { "made " .. file .. ": " .. source }
        end, built)
      end
      return why
    end,
    say = function(_line: string) end,
  }
end

local function test_each_file_is_answered_under_its_own_key()
  local dir = assert(Fs.mkdtemp("tree_shard_"))
  local memo = assert(Sqlite.memory())
  assert(check_memo.prepare(memo, "read"))
  local files = files_of(40)
  local asked: {string} = {}
  local answered = tree_shard.warm(shards_of(3, dir, asked), memo, "read", files, "salt", "")
  assert(answered == 40, answered)
  assert(#asked == 40, #asked)
  for _, row in ipairs(files) do
    local kept = check_memo.get(memo, "read", check_memo.key("salt", "tl", row[2]))
    assert(kept == "made " .. row[1] .. ": " .. row[2], tostring(kept))
  end
  assert(memo:close())
  local _ = Fs.remove_tree(dir)
end

local function test_a_file_the_memo_holds_is_not_made_again()
  local dir = assert(Fs.mkdtemp("tree_shard_"))
  local memo = assert(Sqlite.memory())
  assert(check_memo.prepare(memo, "read"))
  local files = files_of(40)
  local first = files[1]
  check_memo.put(memo, "read", check_memo.key("salt", "tl", first[2]), "held")
  local asked: {string} = {}
  assert(tree_shard.warm(shards_of(2, dir, asked), memo, "read", files, "salt", "") == 39)
  for _, file in ipairs(asked) do
    assert(file ~= "f1.tl", file)
  end
  assert(check_memo.get(memo, "read", check_memo.key("salt", "tl", first[2])) == "held")
  assert(memo:close())
  local _ = Fs.remove_tree(dir)
end

local function test_too_few_files_or_no_workers_are_left_to_the_check()
  local dir = assert(Fs.mkdtemp("tree_shard_"))
  local memo = assert(Sqlite.memory())
  assert(check_memo.prepare(memo, "read"))
  local asked: {string} = {}
  assert(tree_shard.warm(shards_of(3, dir, asked), memo, "read", files_of(5), "salt", "") == 0)
  assert(tree_shard.warm(nil, memo, "read", files_of(40), "salt", "") == 0)
  assert(#asked == 0)
  assert(memo:close())
  local _ = Fs.remove_tree(dir)
end

local function test_a_lost_worker_leaves_its_files_unanswered()
  local dir = assert(Fs.mkdtemp("tree_shard_"))
  local memo = assert(Sqlite.memory())
  assert(check_memo.prepare(memo, "read"))
  local shards = shards_of(2, dir, {})
  shards.run = function(_phase: string, _job: string, _count: integer): {string}
    return { "lost", "lost" }
  end
  assert(tree_shard.warm(shards, memo, "read", files_of(40), "salt", "") == 0)
  assert(check_memo.get(memo, "read", check_memo.key("salt", "tl", "local x = 1")) == nil)
  assert(memo:close())
  local _ = Fs.remove_tree(dir)
end
