--- Examples for the cosmic.child module.
--- Demonstrates process spawning, stdin handling, and exit codes.

-- Example_spawn demonstrates basic process spawning
local function Example_spawn()
  local spawn = require("cosmic.child")
  local h = spawn.spawn({"echo", "hello world"})
  local ok, out = h:read()
  print(out)
  -- Output:
  -- hello world
end

-- Example_spawn_stdin demonstrates passing stdin to a process
local function Example_spawn_stdin()
  local spawn = require("cosmic.child")
  local h = spawn.spawn({"cat"}, {stdin = "hello from stdin"})
  local ok, out = h:read()
  print(out)
  -- Output:
  -- hello from stdin
end

-- Example_spawn_exit_code demonstrates checking exit codes
local function Example_spawn_exit_code()
  local spawn = require("cosmic.child")
  local h = spawn.spawn({"sh", "-c", "exit 0"})
  local code = h:wait()
  print("exit code:", code)
  -- Output:
  -- exit code:	0
end

return {}
