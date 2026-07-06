--- Examples for the cosmic.child module.
--- Demonstrates process spawning, stdin handling, structured results,
--- timeouts, and killing a running child.

-- Example_run demonstrates the one-shot run(): spawn, wait, and capture the
-- structured Result (stdout, stderr, code/signal, ok) in a single call.
local function Example_run()
  local child = require("cosmic.child")
  local r = child.run({"echo", "hello world"}) as child.Result
  io.write(r.stdout)
  -- Output:
  -- hello world
end

-- Example_run_stdin demonstrates feeding stdin to a process.
local function Example_run_stdin()
  local child = require("cosmic.child")
  local r = child.run({"cat"}, {stdin = "hello from stdin"}) as child.Result
  io.write(r.stdout)
  -- Output:
  -- hello from stdin
end

-- Example_run_exit_code demonstrates inspecting the exit code.
local function Example_run_exit_code()
  local child = require("cosmic.child")
  local r = child.run({"sh", "-c", "exit 0"}) as child.Result
  print("exit code:", r.code)
  -- Output:
  -- exit code:	0
end

-- Example_kill demonstrates killing a running child. kill() defaults to
-- SIGTERM (signal 15); wait() then reports the terminating signal.
local function Example_kill()
  local child = require("cosmic.child")
  local h = child.spawn({"sleep", "10"}) as child.Handle
  h:kill()
  local r = h:wait() as child.Result
  print("signal:", r.signal)
  -- Output:
  -- signal:	15
end

-- Example_wait_timeout demonstrates a bounded wait. wait(timeout_ms) returns
-- nil, "timeout" if the child has not finished in time; the handle stays
-- usable, so we kill and reap it afterwards.
local function Example_wait_timeout()
  local child = require("cosmic.child")
  local h = child.spawn({"sleep", "10"}) as child.Handle
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
--   1. Create a pipe with cosmic.io.pipe().
--   2. Pass the write end fd to spawn via opts.stdout.
--   3. Close the write end in the parent BEFORE reading — otherwise the
--      reader will block forever waiting for EOF.
--   4. Read from the read end until EOF.
--   5. Wait for the child.
local function Example_run_pipe()
  local child = require("cosmic.child")
  local cio = require("cosmic.io")

  -- Create a pipe: p.reader and p.writer are cosmic.io Handles.
  local p, err = cio.pipe()
  assert(p, "pipe failed: " .. tostring(err))
  local pp = p as cio.Pipe

  -- Spawn echo, redirecting its stdout into the write end of the pipe.
  local h, serr = child.spawn({"echo", "from pipe"}, {stdout = pp.writer:fd()})
  assert(h, "spawn failed: " .. tostring(serr))

  -- Close the write end in the parent so the reader sees EOF when the child exits.
  pp.writer:close()

  -- Read all output from the read end.
  local out = pp.reader:read()
  pp.reader:close()

  -- Wait for the child to exit.
  local r = (h as child.Handle):wait() as child.Result

  io.write(out)
  print("exit:", r.code)
  -- Output:
  -- from pipe
  -- exit:	0
end

return {}
