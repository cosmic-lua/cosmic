--- The SIGPIPE inheritance contract, as Linux's /proc reports it.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local stand_in = require("build.stand_in")
local type raw_process = require("cosmic.internal.process")
local type Searcher = function(string): any, any

--- The raw process table the store hands the child module's loader.
local function raw_process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: a searcher takes loader data too
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: core/process.h declares the table
    end
  end
  error("cosmic.child is handed no raw table")
end

local process = raw_process_table()

local function probe_in(tmp: string): string
  return (assert(stand_in.build(tmp .. "/probe")))
end

Test.policy{ grants = { { path = "/proc", letters = "r" } }, requires = { "proc" } }

--- Linux exposes the inherited SIGPIPE disposition and the ignore this
--- process installs in /proc. A spawned child keeps only the inherited one.
local function test_a_child_keeps_the_inherited_sigpipe_mask(tmp: string)
  local probe = probe_in(tmp)
  local function ignored(text: string): integer
    return math.tointeger(tonumber(assert(text:match("SigIgn:%s*(%x+)"), text), 16)) as integer
  end
  local status = sys.open("/proc/self/status", sys.O_RDONLY)
  assert(status)
  local own = assert(sys.read(status, 65536))
  sys.close(status)
  local bit = 1 << (sys.SIGPIPE - 1)
  local inherited = ignored(own) & bit
  assert(process.ignore_sigpipe())
  local current = assert(sys.open("/proc/self/status", sys.O_RDONLY))
  assert(ignored((assert(sys.read(current, 65536)))) & bit ~= 0)
  assert(sys.close(current))
  local output = assert(sys.open(tmp .. "/status", sys.O_RDWR | sys.O_CREAT | sys.O_TRUNC, 384))
  local pid = assert(process.spawn(probe, { probe, "cat /proc/self/status" },
    nil, nil, nil, output, nil, false))
  assert(assert(process.waitpid(pid, false)).code == 0)
  local child = assert(sys.pread(output, 65536, 0))
  sys.close(output)
  assert(ignored(child) & bit == inherited, child)
end
