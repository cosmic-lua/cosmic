--- Examples for cosmic.quicksand.proc.

-- Example_default_signals shows the default signal set that
-- become_init() forwards to the main process.
local function Example_default_signals()
  local proc = require("cosmic.quicksand.proc")
  io.write(table.concat(proc.DEFAULT_SIGNALS, ",") .. "\n")
  -- Output:
  -- SIGINT,SIGTERM,SIGHUP
end

-- Example_drop_privs_noop demonstrates that drop_privs(nil) is a
-- no-op — useful when the caller wants to skip privilege dropping
-- without branching.
local function Example_drop_privs_noop()
  local proc = require("cosmic.quicksand.proc")
  local ok = proc.drop_privs(nil, nil)
  io.write(tostring(ok) .. "\n")
  -- Output:
  -- true
end

-- Example_no_new_privs_subprocess applies PR_SET_NO_NEW_PRIVS in a
-- subprocess because the bit cannot be cleared once set. No output
-- check: behavior depends on kernel support.
local function Example_no_new_privs_subprocess()
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]
  local script = [[
local proc = require("cosmic.quicksand.proc")
assert(proc.no_new_privs())
]]
  local h = spawn.spawn({cosmic, "-e", script})
  local hh = h as spawn.Handle
  hh:wait()
end

-- Suppress unused warnings for examples
local _ = {Example_default_signals, Example_drop_privs_noop, Example_no_new_privs_subprocess}
