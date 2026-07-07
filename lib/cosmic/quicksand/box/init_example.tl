--- Examples for cosmic.quicksand.Box.
---
--- These illustrate the declarative API shape and the composition
--- helper. run() itself is exercised from the integration test suite
--- rather than here, because its behavior depends on kernel features
--- that vary across CI hosts.

-- Example_new_and_close constructs a Box from a policy table and tears
-- it down. new() and close() are pure (no syscalls) and portable.
local function Example_new_and_close()
  local Box = require("cosmic.quicksand.box")
  local box = assert(Box.new({
        fs = {ro = {"/usr"}, rw = {"/tmp"}},
        net = {allow = {["api.example.com:443"] = {}}},
        proc = {no_new_privs = true},
        cwd = "/tmp",
      })) as Box.Box
  box:close()
  io.write("ok\n")
  -- Output:
  -- ok
end

-- Example_merge shows the composition pattern: keep policies as plain
-- data, overlay them with Box.merge, and feed the result into new().
local function Example_merge()
  local Box = require("cosmic.quicksand.box")
  local base = {fs = {ro = {"/usr", "/etc/ssl/certs"}}}
  local network = {net = {allow = {["api.example.com:443"] = {}}}}
  local policy = Box.merge(base, network, {cwd = "/work"})
  io.write(tostring((policy as {string: any}).cwd) .. "\n")
  -- Output:
  -- /work
end

-- Example_run_return_shape demonstrates that run() always comes back
-- as a clean (integer|nil, string|nil) pair with exactly one side set:
-- an integer exit code when the workload actually ran, or nil plus an
-- error string when the box could not be assembled on this host (setup
-- failures are never disguised as workload exit codes). The caller
-- distinguishes the two by checking whether code is nil.
local function Example_run_return_shape()
  local Box = require("cosmic.quicksand.box")
  local j = assert(Box.new()) as Box.Box
  local code, err = j:run({"/bin/true"})
  -- Which side is set varies by host capability, so assert the shape
  -- invariant rather than printing the values: exactly one of
  -- (code, err) is ever set.
  assert((code == nil) ~= (err == nil), "run() must set exactly one of code/err")
  if code ~= nil then
    assert(type(code) == "number", "exit code must be an integer")
  else
    assert(type(err) == "string", "assembly failure must carry a message")
  end
  io.write("exclusive\n")
  -- Output:
  -- exclusive
end

return {}
