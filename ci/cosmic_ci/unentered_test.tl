local Fs = require("cosmic.fs")
local Unentered = require("cosmic_ci.unentered")

local function share(index: integer, count: integer, keys: {string}): Unentered.Share
  return { index = index, count = count, keys = keys }
end

--- A share's file is its `shard I/N` line, then a key a line.
local function test_a_shares_file_parses()
  local read = assert(Unentered.parse("shard 2/3\ncore/a.c:f\ncore/b.c:g\n"))
  assert(read.index == 2 and read.count == 3, tostring(read.index))
  assert(#read.keys == 2 and read.keys[2] == "core/b.c:g", read.keys[2])
  local empty = assert(Unentered.parse("shard 1/1\n"))
  assert(#empty.keys == 0)
  local none, why = Unentered.parse("core/a.c:f\n")
  assert(none == nil and why:find("shard I/N", 1, true) ~= nil, why)
end

--- A function every share left unentered is one no test entered; one any
--- share entered is not.
local function test_a_function_no_share_entered_is_found()
  local keys = assert(Unentered.join({
    share(1, 3, { "core/text.c:cosmic_open_text", "core/a.c:f" }),
    share(2, 3, { "core/text.c:cosmic_open_text" }),
    share(3, 3, { "core/a.c:f", "core/text.c:cosmic_open_text" }),
  }))
  assert(#keys == 1 and keys[1] == "core/text.c:cosmic_open_text", table.concat(keys, ","))
end

--- With a share missing, a second of one share, or shares of another
--- count, the join cannot tell.
local function test_a_join_that_cannot_tell_says_why()
  local _, missing = Unentered.join({ share(1, 3, {}), share(3, 3, {}) })
  assert(missing == "no list from share 2 of 3", missing)
  local _, twice = Unentered.join({ share(1, 2, {}), share(1, 2, {}) })
  assert(twice == "share 1 of 2 twice", twice)
  local _, counts = Unentered.join({ share(1, 2, {}), share(2, 3, {}) })
  assert(counts == "shares of 2 and of 3", counts)
  local _, none = Unentered.join({})
  assert(none == "no share wrote its list", none)
end

--- The command reads every file of DIR: 1 and the function where none
--- entered it, 0 where every one was entered.
local function test_the_command_fails_for_a_function_no_share_entered()
  local dir = assert(Fs.mkdtemp("cosmic-unentered-test-"))
  assert(Fs.write(dir .. "/share-1.txt", "shard 1/2\ncore/a.c:f\n"))
  assert(Fs.write(dir .. "/share-2.txt", "shard 2/2\ncore/a.c:f\ncore/b.c:g\n"))
  assert(Unentered.command({ dir }) == 1)
  assert(Fs.write(dir .. "/share-2.txt", "shard 2/2\ncore/b.c:g\n"))
  assert(Unentered.command({ dir }) == 0)
  assert(Fs.write(dir .. "/share-1.txt", "not a list\n"))
  assert(Unentered.command({ dir }) == 1)
  assert(Unentered.command({}) == 2)
end
