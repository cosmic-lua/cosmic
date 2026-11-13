--- Work run in copies of the process (build/compile_fanout.tl): how many
--- copies a count of work gets, and what each copy's end says.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local fanout = require("build.compile_fanout")

--- A build with few modules, or one processor, makes no copy; one with
--- many gets a copy a processor, up to the most, and up to what the
--- caller asks.
local function test_few_modules_or_one_processor_make_no_copy()
  assert(fanout.copies(0, 8, 1, 8) == 0)
  assert(fanout.copies(fanout.least * 2 - 1, 8, 1, 8) == 0, "one copy's worth of work is the process's own")
  assert(fanout.copies(fanout.least * 2, 8, 1, 8) == 2)
  assert(fanout.copies(10000, 1, 1, 8) == 0)
  assert(fanout.copies(10000, 4, 1, 8) == 4)
  assert(fanout.copies(10000, 64, 1, 64) == fanout.most)
  assert(fanout.copies(10000, 4, 1, 1) == 0 and fanout.copies(10000, 4, 1, 0) == 0)
  assert(fanout.copies(10000, 4, 1, 3) == 3)
end

--- Each copy runs the work with its own number, and the process is told
--- which ended well: a copy that raises did not, and what the others
--- wrote is there.
local function test_each_copy_runs_and_one_that_raises_is_told(tmp: string)
  local ended = fanout.run(3, function(copy: integer)
    if copy == 2 then error("this copy fails") end
    assert(Fs.write(tmp .. "/" .. tostring(copy), "made by " .. tostring(copy)))
  end)
  if ended[1] ~= true and ended[3] ~= true then
    Test.skip("this host forks no copy of the process")
  end
  assert(ended[1] == true and ended[2] == false and ended[3] == true)
  assert(Fs.read(tmp .. "/1") == "made by 1" and Fs.read(tmp .. "/3") == "made by 3")
  assert(Fs.read(tmp .. "/2") == nil)
end

--- While its copies run the process is called to look at what they leave, and once more when they have ended: what a
--- copy wrote is there by the last call.
local function test_the_process_looks_while_its_copies_run(tmp: string)
  local looks = 0
  local seen_last: string? = nil
  local ended = fanout.run(2, function(copy: integer)
    assert(Fs.write(tmp .. "/" .. tostring(copy), "made"))
  end, function()
    looks = looks + 1
    seen_last = Fs.read(tmp .. "/2")
  end)
  if ended[1] ~= true or ended[2] ~= true then
    Test.skip("this host forks no copy of the process")
  end
  assert(looks >= 1, "the process never looked")
  assert(seen_last == "made", "the last look came before a copy ended")
end
