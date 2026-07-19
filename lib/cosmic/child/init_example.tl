--- Examples for the cosmic.child module.
--- Demonstrates process spawning, stdin handling, structured results,
--- timeouts, and killing a running child.

-- Example_run demonstrates the one-shot run(): spawn, wait, and capture the
-- structured Result (stdout, stderr, code/signal, ok) in a single call.
local function Example_run()
  local check = require("cosmic.check")
  local child = require("cosmic.child")
  local r = check.must(child.run({"echo", "hello world"}))
  io.write(r.stdout)
  -- Output:
  -- hello world
end

-- Example_run_stdin demonstrates feeding stdin to a process.
local function Example_run_stdin()
  local check = require("cosmic.check")
  local child = require("cosmic.child")
  local r = check.must(child.run({"cat"}, {stdin = "hello from stdin"}))
  io.write(r.stdout)
  -- Output:
  -- hello from stdin
end

-- Example_run_exit_code demonstrates inspecting the exit code.
local function Example_run_exit_code()
  local check = require("cosmic.check")
  local child = require("cosmic.child")
  local r = check.must(child.run({"sh", "-c", "exit 0"}))
  print("exit code:", r.code)
  -- Output:
  -- exit code:	0
end

-- Example_kill demonstrates killing a running child. kill() defaults to
-- SIGTERM (signal 15); wait() then reports the terminating signal.
local function Example_kill()
  local check = require("cosmic.check")
  local child = require("cosmic.child")
  local h = check.must(child.spawn({"sleep", "10"}))
  h:kill()
  local r = check.must(h:wait())
  print("signal:", r.signal)
  -- Output:
  -- signal:	15
end

-- Example_wait_timeout demonstrates a bounded wait. wait(timeout_ms) returns
-- nil, "timeout" if the child has not finished in time; the handle stays
-- usable, so we kill and reap it afterwards.
local function Example_wait_timeout()
  local check = require("cosmic.check")
  local child = require("cosmic.child")
  local h = check.must(child.spawn({"sleep", "10"}))
  local r, err = h:wait(50)
  print(r, err)
  h:kill()
  h:wait()
  -- Output:
  -- nil	timeout
end

-- Example_run_pipe demonstrates capturing output through an explicit pipe.
-- This pattern is needed when you want to redirect a child's stdout into a
-- file descriptor you own rather than letting run()/wait() capture it.
--
-- Key steps:
--   1. Create a pipe with cosmic.fd.pipe().
--   2. Pass the write-end Handle to spawn via opts.stdout.
--   3. Close the write end in the parent BEFORE reading — otherwise the
--      reader will block forever waiting for EOF.
--   4. Read from the read end until EOF.
--   5. Wait for the child.
local function Example_run_pipe()
  local check = require("cosmic.check")
  local child = require("cosmic.child")
  local cfd = require("cosmic.fd")

  -- Create a pipe: pp.reader and pp.writer are cosmic.fd Handles.
  local pp = check.must(cfd.pipe())

  -- Spawn echo, redirecting its stdout into the write end of the pipe.
  local h = check.must(child.spawn({"echo", "from pipe"}, {stdout = pp.writer}))

  -- Close the write end in the parent so the reader sees EOF when the child exits.
  pp.writer:close()

  -- Read all output from the read end.
  local out = pp.reader:read()
  pp.reader:close()

  -- Wait for the child to exit.
  local r = check.must(h:wait())

  io.write(out)
  print("exit:", r.code)
  -- Output:
  -- from pipe
  -- exit:	0
end

-- Suppress unused warnings for examples
local _ = {
  Example_run,
  Example_run_stdin,
  Example_run_exit_code,
  Example_kill,
  Example_wait_timeout,
  Example_run_pipe,
}
