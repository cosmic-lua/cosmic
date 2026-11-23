--- @public
--- The background jobs of one run of `cosmic agent`: commands bash starts
--- and does not wait for, under the same sandbox. Each writes its
--- output, stdout and stderr together, to a file of its own in a
--- private temporary directory, so a job never waits on a reader; the
--- jobs tool reads it from where it last read. Every job ends when
--- the set closes: as the session ends, or as SIGTERM ends a turn.
---
---     local set = Jobs.new()
---     local job = assert(Jobs.start(set, "sleep 1; echo done", { cwd = "/work" }))
---     Jobs.close(set, function(_: Jobs.Job, _: string) end)

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

local record Jobs
  --- One job.
  record Job
    --- Its number in the set, from 1.
    id: integer
    --- The command, as bash was given it.
    command: string
    --- The child bash runs in.
    handle: Child.Handle
    --- The file its output goes to.
    file: string
    --- When it started, on the monotonic clock.
    started: integer
    --- How much of the output the model has read, in bytes.
    mut read: integer
    --- Its outcome, once it has exited.
    mut result?: Child.Result
    --- When it exited, on the monotonic clock.
    mut ended?: integer
    --- Whether its whole output is kept (in sessions.db).
    mut kept: boolean
    --- Whether [`Jobs.kill`] ended it.
    mut killed: boolean
    --- Whether it was ended for writing more than 1GB.
    mut over: boolean
  end

  --- What [`Jobs.read`] read.
  record Read
    --- The new output, whole characters.
    text: string
    --- How many bytes before it were passed over, past the most.
    skipped: integer
  end

  --- The jobs of one run.
  record Set
    --- The directory of their files; nil until the first job.
    mut dir?: string
    --- The jobs, by id, from 1.
    list: mut {Job}
  end

  --- Where a job runs.
  record Options
    --- The working directory.
    cwd: string
    --- What it is held to; nil for nothing.
    policy?: Sandbox.Policy
    --- Seconds it may run; nil or 0 for no limit.
    seconds?: integer
  end

  --- The most of a job's output kept, its last bytes.
  KEPT: integer
end

--- The most jobs running at once.
local RUNNING <const> = 16
Jobs.KEPT = 16 * 1024 * 1024
--- The most output a job may write before it is ended.
local MOST_WRITTEN <const> = 1024 * 1024 * 1024

--- A set with no jobs.
function Jobs.new(): Jobs.Set
  return { list = {} }
end

--- Settles `job` where it has exited, without waiting: whether it has.
function Jobs.settle(job: Jobs.Job): boolean
  if job.result ~= nil then return true end
  local polled, _ = job.handle:try_wait()
  if polled == nil or not polled.finished then return false end
  job.result = polled.result
  job.ended = Clock.monotonic_ns()
  return true
end

--- Starts `command` as a job of `set`, under `opts`: the job, or nil and why.
function Jobs.start(set: Jobs.Set, command: string, opts: Jobs.Options): Jobs.Job?, string
  local running = 0
  for _, j in ipairs(set.list) do
    if not Jobs.settle(j) then running = running + 1 end
  end
  if running >= RUNNING then
    return nil, String.counted(running, "job") .. " run already, the most at once: wait for one or kill one"
  end
  if set.dir == nil then
    local dir, why = Fs.mkdtemp("agent-jobs-")
    if dir == nil then return nil, tostring(why) end
    set.dir = dir
  end
  local id = #set.list + 1
  local file = string.format("%s/%d.out", set.dir, id)
  -- Appended to, so a command that opens its stdout again writes after what is there;
  -- read and write, as a sandbox that nests takes a file only so.
  local fd, open_why = sys.open(file, sys.O_RDWR | sys.O_CREAT | sys.O_TRUNC | sys.O_APPEND, 0x180)
  if fd == nil then return nil, file .. ": " .. tostring(open_why) end
  local found, _ = Proc.find("bash")
  local seconds = opts.seconds
  local handle, why = Child.start({ found or "/bin/sh", "-c", command }, { cwd = opts.cwd, stdin = "null",
    stdout = fd, stderr = "stdout", policy = opts.policy,
    timeout_ns = if seconds ~= nil and seconds > 0 then Clock.seconds(seconds) else Child.FOREVER end })
  local _, _ = Fs.close(fd)
  if handle == nil then
    local _, _ = Fs.remove(file)
    return nil, why
  end
  local job: Jobs.Job = { id = id, command = command, handle = handle, file = file, started = Clock.monotonic_ns(),
    read = 0, kept = false, killed = false, over = false }
  set.list[#set.list + 1] = job
  return job, ""
end

--- The job `id` of `set`, or nil.
function Jobs.find(set: Jobs.Set, id: integer): Jobs.Job?
  return set.list[id]
end

--- The process groups of the jobs still running, which a sweep of
--- strays ([`Child.end_strays`]) spares.
function Jobs.groups(set?: Jobs.Set): {integer}
  local out: mut {integer} = {}
  for _, j in ipairs(set and set.list or {}) do
    if j.result == nil and j.handle.process_group then out[#out + 1] = j.handle.pid end
  end
  return out
end

--- How many bytes of output `job` has written.
function Jobs.size(job: Jobs.Job): integer
  local st, _ = Fs.stat(job.file)
  return if st ~= nil then st.size else 0 end
end

--- Whether byte `b` continues a UTF-8 character.
local function continues(b?: integer): boolean
  return b ~= nil and b & 0xC0 == 0x80
end

--- `text` less a character cut at its end: what a job still writing
--- may finish.
local function complete(text: string): string
  local at = #text
  while at > 0 and at > #text - 3 and continues(text:byte(at)) do at = at - 1 end
  local lead = text:byte(at)
  if lead == nil or lead < 0xC0 then return text end
  local wants = if lead >= 0xF0 then 4 elseif lead >= 0xE0 then 3 else 2 end
  if #text - at + 1 >= wants then return text end
  return text:sub(1, at - 1)
end

--- The bytes of `job`'s output from `first` to `upto`.
local function bytes(job: Jobs.Job, first: integer, upto: integer): string
  if first >= upto then return "" end
  local fd, _ = Fs.open_read(job.file)
  if fd == nil then return "" end
  local data, _ = sys.pread(fd, upto - first, first)
  local _, _ = Fs.close(fd)
  return data or ""
end

--- Where `text` starts its first whole character, within 4 bytes.
local function start(text: string): integer
  local at = 1
  while at <= #text and at <= 4 and continues(text:byte(at)) do at = at + 1 end
  return at
end

--- The last `most` bytes at most of `job`'s output up to `upto`, from
--- the start of a character.
function Jobs.output(job: Jobs.Job, upto: integer, most: integer): string
  local first = math.max(upto - most, 0)
  local got = bytes(job, first, upto)
  return if first > 0 then got:sub(start(got)) else got end
end

--- Reads what `job` wrote since the last read, at most `most` bytes, the
--- last; a character it is still writing waits for the next read.
function Jobs.read(job: Jobs.Job, most: integer): Jobs.Read
  local upto = Jobs.size(job)
  local first = math.max(job.read, upto - most)
  local skipped = first - job.read
  local got = bytes(job, first, upto)
  local from = if skipped > 0 then start(got) else 1 end
  local text = got:sub(from)
  if job.result == nil then text = complete(text) end
  job.read = first + from - 1 + #text
  return { text = text, skipped = skipped }
end

--- Settles each job of `set` that has exited, keeps each one's own
--- timeout, and ends one whose output passed `MOST_WRITTEN`.
function Jobs.check(set?: Jobs.Set)
  for _, j in ipairs(set and set.list or {}) do
    if not Jobs.settle(j) and Jobs.size(j) > MOST_WRITTEN then
      j.over = true
      Jobs.kill(j)
    end
  end
end

--- Waits up to `seconds` for `job` to exit, a slice at a time, until
--- `stopped` says the user stopped the turn: whether it has exited.
function Jobs.wait(job: Jobs.Job, seconds: integer, stopped?: function(): boolean): boolean
  local deadline = Clock.monotonic_ns() + Clock.seconds(seconds)
  while not Jobs.settle(job) do
    local left = deadline - Clock.monotonic_ns()
    if left <= 0 or (stopped ~= nil and stopped()) then return false end
    local _, _ = Child.wait_any({ job.handle }, math.min(left, Clock.ms(200)))
  end
  return true
end

--- Ends `job`, its group with it, where it still runs.
function Jobs.kill(job: Jobs.Job)
  if Jobs.settle(job) then return end
  local _, _ = job.handle:close()
  local _ = Jobs.settle(job)
  -- Ended here, not by itself in the meantime.
  local result = job.result
  job.killed = result ~= nil and result.timed_out
end

--- Ends every job of `set`, and hands `keep` the output of each whose
--- whole output is not kept yet: its last [`Jobs.KEPT`] bytes. Removes
--- the files.
function Jobs.close(set: Jobs.Set, keep: function(job: Jobs.Job, output: string))
  -- SIGTERM to all first, so their grace periods run together.
  for _, j in ipairs(set.list) do
    if not Jobs.settle(j) then local _, _ = j.handle:stop() end
  end
  for _, j in ipairs(set.list) do
    Jobs.kill(j)
    if not j.kept then
      local whole = Jobs.output(j, Jobs.size(j), Jobs.KEPT)
      j.kept = true
      keep(j, whole)
    end
  end
  local dir = set.dir
  if dir ~= nil then
    local _, _ = Fs.remove_tree(dir)
    set.dir = nil
  end
end

return Jobs
