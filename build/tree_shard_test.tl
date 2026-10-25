--- The shards of the whole-tree checks ([`build.tree_shard`]): a file's answer comes back under its own key whichever
--- worker made it, a file the memo holds is not made again, and a check with too few files or no workers is left to
--- itself.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local check_memo = require("build.check_memo")
local teal = require("build.teal")
local tree_shard = require("build.tree_shard")
local type compiler = require("build.compiler")

Test.policy{ profiles = { "cosmic" } }

--- The files of a tree of `count` files, each with a source of its own.
local function files_of(count: integer): {{string}}
  local files: mut {{string}} = {}
  for at = 1, count do
    files[#files + 1] = { "f" .. tostring(at) .. ".tl", "local x = " .. tostring(at) }
  end
  return files
end

--- Shards of `size` workers that serve in this process, and the files each was asked for.
local function shards_of(size: integer, dir: string, asked: mut {string}, lost?: boolean): tree_shard.Shards
  local built = assert(teal.load())
  return {
    ready = function(_bytes: integer): boolean return true end,
    size = function(): integer return size end,
    path = function(name: string): string?, string return dir .. "/" .. name, "" end,
    run = function(_phase: string, job: string, count: integer): {string}
      local why: mut {string} = {}
      for index = 1, count do
        if lost == true then
          why[index] = "lost"
        else
          why[index] = tree_shard.serve(job, index, function(_b: compiler, file: string, source: string, _extra: string): {string}
            asked[#asked + 1] = file
            return { "made " .. file .. ": " .. source }
          end, built)
        end
      end
      return why
    end,
    say = function(line: string)
      if lost == true then asked[#asked + 1] = line end
    end,
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
    local file, source = row[1], row[2]
    assert(file ~= nil and source ~= nil)
    local kept = check_memo.get(memo, "read", check_memo.key("salt", "tl", source))
    assert(kept == "made " .. file .. ": " .. source, tostring(kept))
  end
  assert(memo:close())
  local _ = Fs.remove_tree(dir)
end

local function test_a_file_the_memo_holds_is_not_made_again()
  local dir = assert(Fs.mkdtemp("tree_shard_"))
  local memo = assert(Sqlite.memory())
  assert(check_memo.prepare(memo, "read"))
  local files = files_of(40)
  local held = check_memo.key("salt", "tl", "local x = 1")
  check_memo.put(memo, "read", held, "held")
  local asked: {string} = {}
  assert(tree_shard.warm(shards_of(2, dir, asked), memo, "read", files, "salt", "") == 39)
  for _, file in ipairs(asked) do
    assert(file ~= "f1.tl", file)
  end
  assert(check_memo.get(memo, "read", held) == "held")
  assert(memo:close())
  local _ = Fs.remove_tree(dir)
end

local function test_too_few_files_or_workers_are_left_to_the_check()
  local dir = assert(Fs.mkdtemp("tree_shard_"))
  local memo = assert(Sqlite.memory())
  assert(check_memo.prepare(memo, "read"))
  local asked: {string} = {}
  -- three workers and five files, then one worker and forty
  for _, case in ipairs({ { 3, 5 }, { 1, 40 } }) do
    assert(tree_shard.warm(shards_of(case[1] or 0, dir, asked), memo, "read", files_of(case[2] or 0), "salt", "") == 0)
  end
  assert(tree_shard.warm(nil, memo, "read", files_of(40), "salt", "") == 0)
  assert(#asked == 0)
  assert(memo:close())
  local _ = Fs.remove_tree(dir)
end

local function test_a_lost_worker_leaves_its_files_unanswered()
  local dir = assert(Fs.mkdtemp("tree_shard_"))
  local memo = assert(Sqlite.memory())
  assert(check_memo.prepare(memo, "read"))
  local asked: {string} = {}
  assert(tree_shard.warm(shards_of(2, dir, asked, true), memo, "read", files_of(40), "salt", "") == 0)
  local lost = 0
  for _, line in ipairs(asked) do
    if line:find("did not finish (lost)", 1, true) ~= nil then lost = lost + 1 end
  end
  assert(lost == 2, "a worker that did not finish was not said: " .. table.concat(asked, " | "))
  assert(check_memo.get(memo, "read", check_memo.key("salt", "tl", "local x = 1")) == nil)
  assert(memo:close())
  local _ = Fs.remove_tree(dir)
end
