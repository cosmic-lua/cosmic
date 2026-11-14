--- Work run in copies of the process (build/compile_fanout.tl): how many
--- copies a count of work gets, and what each copy's end says.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
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
  local ran = fanout.run(3, function(copy: integer)
    if copy == 2 then error("this copy fails") end
    assert(Fs.write(tmp .. "/" .. tostring(copy), "made by " .. tostring(copy)))
  end)
  local ended = ran.ended
  assert(ended[1] == true and ended[2] == false and ended[3] == true)
  assert(Fs.read(tmp .. "/1") == "made by 1" and Fs.read(tmp .. "/3") == "made by 3")
  assert(Fs.read(tmp .. "/2") == nil)
end

--- A copy is refused a connection the process opened before it forked ([`Sqlite.disown`]), and the process's
--- own use of it is as it was.
local function test_a_copy_is_refused_a_connection_the_process_opened(tmp: string)
  local db = assert(Sqlite.open(tmp .. "/held.db", { writable = true }))
  assert(db:exec("CREATE TABLE t (n INTEGER)"))
  local ran = fanout.run(2, function(copy: integer)
    local ok, why = pcall(function() local _, _ = db:exec("INSERT INTO t VALUES (1)") end)
    assert(Fs.write(tmp .. "/said-" .. tostring(copy), if ok then "used it" else tostring(why) end))
  end)
  assert(ran.ended[1] == true and ran.ended[2] == true)
  for copy = 1, 2 do
    local said = assert(Fs.read(tmp .. "/said-" .. tostring(copy)))
    assert(said:find("disowned its connections", 1, true), said)
  end
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM t"))
  assert(assert(rows[1]):text(1) == "0")
  assert(db:close())
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
  end).ended
  assert(ended[1] == true and ended[2] == true, "a copy did not run")
  assert(looks >= 1, "the process never looked")
  assert(seen_last == "made", "the last look came before a copy ended")
end

--- A copy still running when the process is out of patience is ended, counted, and told as one that did not end
--- well, while one that ended in time is told as it ended; the call comes back.
local function test_a_copy_that_does_not_end_is_ended_and_counted(tmp: string)
  local patience = fanout.patience_ns
  fanout.patience_ns = 500 * 1000000
  local ran = fanout.run(2, function(copy: integer)
    assert(Fs.write(tmp .. "/" .. tostring(copy), "started"))
    if copy == 2 then
      while true do local _, _ = sys.nanosleep(50 * 1000000) end
    end
  end)
  fanout.patience_ns = patience
  assert(Fs.read(tmp .. "/1") == "started" and Fs.read(tmp .. "/2") == "started", "a copy did not run")
  assert(ran.ended[1] == true, "a copy that ended in time is told as ended badly")
  assert(ran.ended[2] == false and ran.late == 1, "the copy that hung was not ended: " .. tostring(ran.late))
end

--- A copy that ended in time is told as it ended though the process looks at it only after its patience is over.
local function test_a_copy_that_ended_in_time_is_not_ended_for_a_late_look(tmp: string)
  local patience = fanout.patience_ns
  fanout.patience_ns = 300 * 1000000
  local looked = false
  local ran = fanout.run(1, function(copy: integer)
    assert(Fs.write(tmp .. "/" .. tostring(copy), "made"))
  end, function()
    if not looked then
      looked = true
      -- By the end of this look the copy has long ended, and the patience is over.
      local _, _ = sys.nanosleep(600 * 1000000)
    end
  end)
  fanout.patience_ns = patience
  assert(Fs.read(tmp .. "/1") == "made", "the copy did not run")
  assert(ran.ended[1] == true and ran.late == 0, "a copy that ended in time was ended: " .. tostring(ran.late))
end
