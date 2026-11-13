--- Work done in copies of this process, each on a processor of its own:
--- what a build with many modules to compile makes them in
--- ([`build.shared_compiles`]'s `fan`, which says what a copy does).
---
--- [`fanout.run`] forks the process `copies` times and runs `work` in
--- each copy, which then ends with [`sys.exit`]: it closes nothing, so a
--- handle the process held when it forked, a database's among them, is
--- never written by a copy. What a copy has to say it leaves in a file
--- of its own. Where the process cannot be forked (macOS; another thread
--- running; a signal guard open) no copy runs, and the caller does the
--- work itself.

local Env = require("cosmic.env")
local sys = require("cosmic.sys")
local process = require("cosmic.internal.process")

local record fanout
  --- The fewest pieces of work a copy is forked for: a copy repeats what
  --- the pieces share, which a caller with a few is quicker without.
  mut least: integer
  --- The most copies, whatever the processors.
  mut most: integer
  asked: function(): integer
end

fanout.least = 48
fanout.most = 8

--- How many copies do `count` pieces of work on `processors`: none below
--- two, since one copy is no quicker than the process itself. `most` is
--- the caller's bound on them, [`fanout.asked`] by default.
function fanout.copies(count: integer, processors: integer, most?: integer): integer
  local wanted = math.min(processors, fanout.most, most or fanout.asked(), count // fanout.least)
  return if wanted < 2 then 0 else wanted end
end

--- The most copies COSMIC_COMPILE_COPIES asks for: a count, `0` or `1`
--- for none, so a build compiles in the one process as it did; `most`
--- where it is unset or no count.
function fanout.asked(): integer
  local asked = math.tointeger(tonumber(Env.get("COSMIC_COMPILE_COPIES") or ""))
  if asked == nil or asked < 0 then return fanout.most end
  return asked
end

--- Runs `work` in `copies` copies of this process, each given its number
--- from 1, and waits for them all: whether each ended well, by its
--- number. A copy ends well where `work` returns; one that raises, or that
--- could not be forked, did not.
function fanout.run(copies: integer, work: function(copy: integer)): {integer:boolean}
  local pids: mut {integer:integer} = {}
  for copy = 1, copies do
    local pid, _ = process.fork(false)
    if pid == nil then break end
    if pid == 0 then
      local done = false
      match pcall(work, copy) do
      | (true) then done = true
      | (false, _) then done = false
      end
      sys.exit(if done then 0 else 1 end)
    end
    pids[copy] = pid
  end
  local ended: mut {integer:boolean} = {}
  for copy = 1, copies do
    local pid = pids[copy]
    local ended_well = false
    if pid ~= nil then
      local status, _ = process.waitpid(pid, false)
      ended_well = status ~= nil and status.code == 0
    end
    ended[copy] = ended_well
  end
  return ended
end

return fanout
