--- Listing live and reaped children where the kernel exposes its list.

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

Test.policy{ profiles = { "proc" }, requires = { "path:/proc/thread-self/children" } }

--- `children` lists the children of the thread that starts them, a
--- child still running among them and gone once reaped; off Linux there
--- is no such list, ENOSYS.
local function test_children_lists_a_running_child_until_it_is_reaped(tmp: string)
  local probe = probe_in(tmp)
  local ends = assert(process.pipe())
  local pid = assert(process.spawn(probe, { probe, "cat" }, nil, tmp, ends.reader, nil, nil, false))
  sys.close(ends.reader)
  local running, trouble = process.children()
  sys.close(ends.writer)
  assert(assert(process.waitpid(pid, false)).code == 0)
  assert(running ~= nil, trouble)
  local listed = false
  for _, child in ipairs(running) do
    assert(math.type(child) == "integer" and child > 0)
    if child == pid then listed = true end
  end
  assert(listed, "the running child " .. pid .. " is not listed")
  for _, child in ipairs((assert(process.children()))) do
    assert(child ~= pid, "the reaped child " .. pid .. " is still listed")
  end
end
