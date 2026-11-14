--- Work done in copies of this process, each on a processor of its own:
--- what a build with many sources to parse or modules to compile makes
--- them in ([`build.shared_compiles`]'s `fan` and `fan_parses`, which say
--- what a copy does).
---
--- [`fanout.run`] forks the process `copies` times and runs `work` in
--- each copy, which then ends with [`sys.exit`]: it closes nothing, so a
--- handle the process held when it forked, a database's among them, is
--- never written by a copy. What a copy has to say it leaves in a file
--- of its own. Where the process cannot be forked (another thread
--- running, which on macOS the C library may have started itself; a
--- signal guard open) no copy runs, and the caller does the work itself,
--- as it does that of a copy still running after [`fanout.patience_ns`],
--- which is ended.

local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local process = require("cosmic.internal.process")

local record fanout
  --- The fewest pieces of work a copy is forked for: a copy repeats what
  --- the pieces share, which a caller with a few is quicker without.
  mut least: integer
  --- The most copies, whatever the processors.
  mut most: integer
  --- The most copies on a host that does not say what memory it has
  --- free (macOS): four of a build's largest, 1.5 GB each, fit in the
  --- 8 GB the smallest Mac this core runs on has.
  mut unmeasured: integer
  --- How long the copies of one [`fanout.run`] are waited for. The
  --- 1200 compiles of cosmic's own tree take one process under a minute
  --- on a four-core host ([`build.shared_compiles`]'s `fan`), so a copy
  --- still running after this has hung, and waiting on would hold the
  --- build for good.
  mut patience_ns: integer

  --- What [`fanout.run`] answers: whether each copy ended well, by its
  --- number, and how many were ended for running past `patience_ns`.
  record Ran
    ended: {integer:boolean}
    late: integer
  end
end

fanout.least = 48
fanout.most = 8
fanout.unmeasured = 4
fanout.patience_ns = 15 * 60 * 1000000000

--- The most copies COSMIC_COMPILE_COPIES asks for: a count, `0` or `1`
--- for none, so a build compiles in the one process as it did; `most`
--- where it is unset or no count.
local function asked(): integer
  local count = math.tointeger(tonumber(Env.get("COSMIC_COMPILE_COPIES") or ""))
  if count == nil or count < 0 then return fanout.most end
  return count
end

--- How many copies of `each` bytes the host has room for, by what its
--- /proc/meminfo says is available: `unmeasured` where it does not say,
--- as on macOS, which has none.
local function room(each: integer): integer
  local text, _ = Fs.read("/proc/meminfo")
  local available = math.tointeger(tonumber((text or ""):match("MemAvailable:%s*(%d+) kB")))
  -- TODO: bound the copies by the memory a Mac has free, once the core has a binding that answers it (hw.memsize
  -- and the pages in use): until then a host that does not say gets `unmeasured`.
  if available == nil then return fanout.unmeasured end
  return available * 1024 // each
end

--- How many copies do `count` pieces of work on `processors`, each copy
--- holding `each` bytes: none below two, since one copy is no quicker
--- than the process itself; no more than the host has memory for; and no
--- more than COSMIC_COMPILE_COPIES asks for. `bound` stands in for those
--- last two, for a test.
function fanout.copies(count: integer, processors: integer, each: integer, bound?: integer): integer
  local wanted = math.min(processors, fanout.most, bound or math.min(asked(), room(each)), count // fanout.least)
  return if wanted < 2 then 0 else wanted end
end

--- How long the process waits between two looks at its copies.
local look_ns <const> = 20 * 1000000

--- Runs `work` in `copies` copies of this process, each given its number
--- from 1, and waits for them all. A copy ends well where `work` returns; one
--- that raises, that could not be forked, or that was ended did not.
--- `watch`, when given, is called while the copies run, some fifty times
--- a second, and once more when they have all ended: what a copy leaves
--- for the process to read as it goes is read there.
function fanout.run(copies: integer, work: function(copy: integer), watch?: function()): fanout.Ran
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
  local running = 0
  for copy = 1, copies do
    ended[copy] = false
    if pids[copy] ~= nil then running = running + 1 end
  end
  local started = Clock.monotonic_ns()
  local late = 0
  while running > 0 do
    local out_of_patience = Clock.monotonic_ns() - started > fanout.patience_ns
    for copy = 1, copies do
      local pid = pids[copy]
      if pid ~= nil then
        -- Looked at before it is ended: a copy that ended in time is told as it ended, however late the look.
        local status, _ = process.waitpid(pid, true)
        local over = false
        if status ~= nil and status.pid ~= pid and out_of_patience then
          -- Ended and then waited for, so no copy outlives the call.
          local _, _ = sys.kill(pid, sys.SIGKILL)
          status, _ = process.waitpid(pid, false)
          late = late + 1
          over = true
        end
        if status == nil or status.pid == pid then
          ended[copy] = not over and status ~= nil and status.code == 0
          pids[copy] = nil
          running = running - 1
        end
      end
    end
    if watch ~= nil then watch() end
    if running > 0 then local _, _ = sys.nanosleep(look_ns) end
  end
  return { ended = ended, late = late }
end

return fanout
