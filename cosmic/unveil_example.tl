--- Examples for the cosmic.unveil module.
--- Unveil enforces on OpenBSD natively and on Linux kernels with
--- Landlock; `available()` reports which. Because a committed policy is
--- process-wide and irreversible, each example runs in a subprocess via
--- cosmic.child.

-- Example_allow demonstrates unveiling a single directory read-only and
-- committing the policy. The API is fail-closed: on hosts without a
-- backing sandbox, allow() returns false + "unveil unsupported on this
-- host" instead of pretending to restrict.
local function Example_allow()
  local check = require("cosmic.check")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]
  local script = [[
local unveil = require("cosmic.unveil")
if unveil.available() then
  assert(unveil.allow("/tmp", "r"))
  assert(unveil.commit())
else
  local ok, err = unveil.allow("/tmp", "r")
  assert(not ok and err:find("unsupported"))
end
io.write("done\n")
]]
  local r = check.must(spawn.run({cosmic, "-e", script}))
  io.write(r.stdout)
  -- Output:
  -- done
end

-- Suppress unused warnings for examples
local _ = {Example_allow}
