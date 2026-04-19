--- Examples for cosmic.quicksand.Jail.
---
--- These illustrate the declarative API shape and the composition
--- helper. run() itself is exercised from the integration test suite
--- rather than here, because its behavior depends on kernel features
--- that vary across CI hosts.

-- Example_new_and_close constructs a Jail from a policy table and tears
-- it down. new() and close() are pure (no syscalls) and portable.
local function Example_new_and_close()
  local Jail = require("cosmic.quicksand.jail")
  local jail = assert(Jail.new({
        fs = {ro = {"/usr"}, rw = {"/tmp"}},
        net = {allow = {["api.example.com:443"] = {}}},
        proc = {no_new_privs = true},
        cwd = "/tmp",
      }))
  jail:close()
  io.write("ok\n")
  -- Output:
  -- ok
end

-- Example_merge shows the composition pattern: keep policies as plain
-- data, overlay them with Jail.merge, and feed the result into new().
local function Example_merge()
  local Jail = require("cosmic.quicksand.jail")
  local base = {fs = {ro = {"/usr", "/etc/ssl/certs"}}}
  local network = {net = {allow = {["api.example.com:443"] = {}}}}
  local policy = Jail.merge(base, network, {cwd = "/work"})
  io.write(tostring((policy as {string: any}).cwd) .. "\n")
  -- Output:
  -- /work
end

-- Example_run_return_shape demonstrates that run() always comes back
-- as a clean (integer|nil, string|nil) pair, whether the workload ran
-- to completion or the jail could not be assembled on this host. The
-- caller distinguishes "assembly failed" from "process exited" by
-- checking whether code is nil.
local function Example_run_return_shape()
  local Jail = require("cosmic.quicksand.jail")
  local j = assert(Jail.new())
  local code, err = j:run({"/bin/true"})
  if code == nil then
    io.write("err " .. tostring((err or ""):sub(1, 10)) .. "\n")
  else
    io.write("code " .. type(code) .. "\n")
  end
  -- Output:
  -- code number
end

return {}
