--- Examples for the cosmic.child module.
--- Demonstrates process spawning, stdin handling, and exit codes.

-- Example_spawn demonstrates basic process spawning
local function Example_spawn()
  local spawn = require("cosmic.child")
  local h = spawn.spawn({"echo", "hello world"})
  local ok, out = (h as spawn.Handle):read()
  print(out)
  -- Output:
  -- hello world
end

-- Example_spawn_stdin demonstrates passing stdin to a process
local function Example_spawn_stdin()
  local spawn = require("cosmic.child")
  local h = spawn.spawn({"cat"}, {stdin = "hello from stdin"})
  local ok, out = (h as spawn.Handle):read()
  print(out)
  -- Output:
  -- hello from stdin
end

-- Example_spawn_exit_code demonstrates checking exit codes
local function Example_spawn_exit_code()
  local spawn = require("cosmic.child")
  local h = spawn.spawn({"sh", "-c", "exit 0"})
  local code = (h as spawn.Handle):wait()
  print("exit code:", code)
  -- Output:
  -- exit code:	0
end

-- Example_spawn_pipe demonstrates capturing output through an explicit pipe.
-- This pattern is needed when you want to interleave reads with the child's
-- execution rather than waiting for it to finish.
--
-- Key steps:
--   1. Create a pipe with cosmic.io.pipe().
--   2. Pass the write end fd to spawn via opts.stdout.
--   3. Close the write end in the parent BEFORE reading — otherwise the
--      reader will block forever waiting for EOF.
--   4. Read from the read end until EOF.
--   5. Wait for the child.
local function Example_spawn_pipe()
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
  local code = (h as child.Handle):wait()

  -- echo adds a trailing newline; strip it before printing
  io.write(out)
  print("exit:", code)
  -- Output:
  -- from pipe
  -- exit:	0
end

return {}
