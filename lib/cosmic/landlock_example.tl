--- Examples for the cosmic.landlock module.
--- Landlock is Linux-only and irreversible once applied, so examples
--- that actually restrict the process run in a subprocess via
--- cosmic.child. Output checks are omitted where the result depends on
--- kernel support that varies by host.

-- Example_available demonstrates the capability probe. Applications
-- should gate jail setup on available() so they degrade cleanly on
-- kernels older than 5.13 and on non-Linux hosts. This example prints
-- a different line depending on whether landlock is supported, so no
-- output check is attached.
local function Example_available()
  local landlock = require("cosmic.landlock")
  if landlock.available() then
    io.write("available\n")
  else
    io.write("not available\n")
  end
end

-- Example_masks demonstrates composing access-flag constants into rule
-- masks. cosmic.landlock.READ / EXEC / WRITE / RW / ALL are bitmask
-- integers; combine with `|`.
local function Example_masks()
  local landlock = require("cosmic.landlock")
  local rx = landlock.READ | landlock.EXEC
  local rw = landlock.RW
  io.write(tostring(rx > 0) .. " " .. tostring(rw > 0) .. "\n")
  -- Output:
  -- true true
end

-- Example_restrict demonstrates pinning the process to a read-only view
-- of /usr plus read/write access to /tmp. After restrict returns,
-- opening files outside the allowlist fails with EACCES. Runs in a
-- subprocess because the restriction cannot be undone; no output check
-- is attached because behavior depends on kernel support.
local function Example_restrict()
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]
  local script = [[
local ll = require("cosmic.landlock")
if not ll.available() then return end
assert(ll.restrict{
  rules = {
    { path = "/usr", access = ll.READ | ll.EXEC },
    { path = "/tmp", access = ll.RW },
  },
})
]]
  spawn.spawn({cosmic, "-e", script}):wait()
end

return {}
