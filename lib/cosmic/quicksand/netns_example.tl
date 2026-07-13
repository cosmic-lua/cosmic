--- Examples for cosmic.quicksand.netns.

-- Example_open_self opens the current process's own netns file
-- descriptor. Useful as a sanity check and as a reference for the
-- fd-based enter() flow. On non-Linux hosts open() returns nil+err,
-- which the example also handles.
local function Example_open_self()
  local netns = require("cosmic.quicksand.netns")
  local fd, _err = netns.open(nil)
  if not fd then
    io.write("no netns\n")
    return
  end
  io.write("opened\n")
  netns.close(fd)
end

-- Example_unshare_in_subprocess creates a fresh network namespace
-- and brings loopback up. unshare() is irreversible for the current
-- thread, so this runs in a subprocess. No output check is attached
-- because the result depends on whether the host allows
-- unprivileged user-namespace creation.
local function Example_unshare_in_subprocess()
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]
  local script = [[
local ns = require("cosmic.quicksand.netns")
if not ns.unshare_user() then return end
assert(ns.unshare())
assert(ns.bring_up("lo"))
]]
  local h = spawn.spawn({cosmic, "-e", script})
  local hh = h as spawn.Handle
  hh:wait()
end

-- Suppress unused warnings for examples
local _ = {Example_open_self, Example_unshare_in_subprocess}
