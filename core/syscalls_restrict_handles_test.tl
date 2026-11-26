--- The /proc handles a restriction opens to inspect a process's
--- descriptors, which are Linux's: the module requires Linux. A refusal
--- before the inspection is core/syscalls_restrict_refusal_test.tl's.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")

Test.policy{ requires = { "os:linux" } }

--- A restriction refused after it opened its /proc handles leaves them open;
--- a fork copies them, and a restriction in the copy lets them go: it closes a
--- copy that still names its parent's entry, and leaves open a file the
--- program put in the number of one -- a file it names in fds.
local function test_a_forked_restriction_leaves_open_a_file_put_in_its_parents_handles()
  local process = require("cosmic.internal.process")
  local restriction: raw_process.Restriction = { promises = {}, grants = {}, rlimits = {} }
  -- An end not named in fds, so each restriction here is refused, after it inspects /proc.
  local held = assert(process.pipe())
  local refused, why = process.restrict_self(restriction, {})
  assert(not refused, why)
  local parent = sys.getpid()
  local pid, fork_why = process.fork(false)
  if pid == 0 then
    --- The descriptors that name an entry of the parent's /proc, in order.
    local function parents(): {integer}
      local found: mut {integer} = {}
      for name in pairs(sys.readdir("/proc/self/fd") or {}) do
        local target = sys.readlink("/proc/self/fd/" .. name)
        local fd = math.tointeger(tonumber(name))
        if fd ~= nil and target ~= nil and target:find("^/proc/" .. tostring(parent) .. "/") ~= nil then
          found[#found + 1] = fd
        end
      end
      table.sort(found)
      return found
    end
    local handles = parents()
    local replaced = handles[1] or -1
    if replaced >= 0 then assert(sys.dup2(held.reader, replaced)) end
    local _, _ = process.restrict_self(restriction, { replaced })
    -- Still the pipe: a handle closed here would be opened again in its number.
    local now = sys.readlink("/proc/self/fd/" .. tostring(replaced))
    local kept = now ~= nil and now:find("^pipe:") ~= nil
    local left = #parents()
    local status = 10 + #handles * 4 + (if kept then 0 else 1 end) + (if left == 0 then 0 else 2 end)
    sys.exit(if #handles == 3 and kept and left == 0 then 0 else status end)
  end
  assert(pid ~= nil, fork_why)
  local status, wait_why = process.waitpid(pid, false)
  assert(status ~= nil, wait_why)
  assert(sys.close(held.reader) and sys.close(held.writer))
  assert(status.code == 0, "child status " .. tostring(status.code) ..
      " (10 + 4 x the parent's handles found, + 1 if the replaced one is not the pipe, + 2 if any is left)")
end
