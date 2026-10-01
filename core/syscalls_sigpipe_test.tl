--- SIGPIPE as a spawned program starts with it, on every system: a
--- module of its own, because this process ignores SIGPIPE for good once
--- anything of it does, and the case must first learn whether it was
--- started so. core/syscalls_test.tl reads the same from Linux's
--- /proc/self/status, which macOS has none of.

local sys = require("cosmic.sys")
local stand_in = require("build.stand_in")

local type raw_process = require("cosmic.internal.process")
local type Searcher = function(string): any, any

--- The raw process table `require` hands [`cosmic.child`]'s loader.
local function raw_behind_child(): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error("cosmic.child is handed no raw table")
end

local process = raw_behind_child() as raw_process -- cast: the table core/process.h declares

--- How a stand-in program (build/stand_in.tl) ends writing to a pipe no
--- one reads, handed as its descriptor 3: the signal that ended it, or
--- 0 where its write failed instead (EPIPE), as one that ignores
--- SIGPIPE's does.
local function writing_to_a_closed_pipe(probe: string): integer
  local ends = assert(process.pipe())
  sys.close(ends.reader)
  local pid = assert(process.spawn(probe, { probe, "write-fd 3 lost" }, nil, nil, nil, nil, nil,
    false, { [3] = ends.writer }))
  sys.close(ends.writer)
  local status = assert(process.waitpid(pid, false))
  if status.signal > 0 then return status.signal end
  assert(status.code == 1, tostring(status.code))
  return 0
end

--- A program spawned once this process ignores SIGPIPE starts with it at
--- its default, as it would started from a shell, and is ended by a
--- write to a closed pipe -- unless this process was started with it
--- ignored, which a program it starts inherits, and which leaves nothing
--- here to check.
local function test_a_child_starts_with_sigpipe_at_its_default(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  -- Started with SIGPIPE ignored, as a CI runner may start this
  -- process: a condition of the host, not a sandbox it refuses, so no
  -- skip ([`Test.skip`]), and a run where it holds checks nothing here.
  if writing_to_a_closed_pipe(probe) == 0 then return end
  assert(process.ignore_sigpipe())
  local ended = writing_to_a_closed_pipe(probe)
  assert(ended == sys.SIGPIPE, "ended by " .. tostring(ended))
end
