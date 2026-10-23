--- What a worker of the whole-tree checks makes of a file ([`build.tree_worker`]): each file's answer is kept under its own
--- key, so a worker that makes many files' answers keeps each where the check looks it up.
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local check_memo = require("build.check_memo")
local teal = require("build.teal")
local tree_worker = require("build.tree_worker")

Test.policy{ profiles = { "cosmic" } }

local function test_reading_answers_each_file_under_its_own_key()
  local memo = assert(Sqlite.memory())
  assert(check_memo.prepare(memo, "read"))
  local built = assert(teal.load())
  local extra = "salt\n\n"
  local first_source = 'local fs = require("cosmic.fs")\nreturn fs\n'
  local second_source = 'local json = require("cosmic.json")\nreturn json\n'
  local first = tree_worker.reading(memo, built, "first.tl", first_source, extra)
  local second = tree_worker.reading(memo, built, "second.tl", second_source, extra)
  assert(#first == 1 and #second == 1)
  assert(check_memo.get(memo, "read", check_memo.key("salt", "tl", first_source)) == first[1], "first file's key")
  assert(check_memo.get(memo, "read", check_memo.key("salt", "tl", second_source)) == second[1], "second file's key")
  assert(memo:close())
end
