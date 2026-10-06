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

--- Ignoring SIGPIPE for this process leaves a spawned program's inherited
--- disposition intact: default when this process installed the ignore,
--- ignored when it was already ignored at this process's start.
local function test_a_child_keeps_the_inherited_sigpipe_disposition(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local inherited = writing_to_a_closed_pipe(probe)
  assert(inherited == 0 or inherited == sys.SIGPIPE, "ended by " .. tostring(inherited))
  assert(process.ignore_sigpipe())
  local ended = writing_to_a_closed_pipe(probe)
  assert(ended == inherited, "ended by " .. tostring(ended) .. ", inherited " .. tostring(inherited))
end
