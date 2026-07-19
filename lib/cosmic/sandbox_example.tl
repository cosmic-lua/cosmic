--- Examples for the cosmic.sandbox module.
--- Applying a policy is irreversible and process-wide, so each example
--- runs in a subprocess via cosmic.child.

-- Example_apply sandboxes a subprocess to a read-only view of /tmp and
-- the stdio+rpath promise groups in one call. The facade is
-- fail-closed: where a section cannot be enforced (no landlock, not
-- OpenBSD), apply reports failure instead of pretending to restrict.
local function Example_apply()
  local check = require("cosmic.check")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]
  local script = [[
local sandbox = require("cosmic.sandbox")
local avail = sandbox.available()
if avail.fs and avail.sys then
  assert(sandbox.apply({
    fs = { ro = { "/tmp" } },
    sys = { promises = "stdio rpath" },
  }))
else
  local ok, err = sandbox.apply({
    fs = { ro = { "/tmp" } },
    sys = { promises = "stdio rpath" },
  })
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
local _ = {Example_apply}
