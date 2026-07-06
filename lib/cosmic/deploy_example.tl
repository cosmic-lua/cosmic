--- Examples for deploying cosmic scripts.
--- Demonstrates shebang usage, the cosmic.main() pattern for structured
--- scripts, installing scripts to PATH, and building portable executables.
---
--- cosmic-lua is a fat binary built on Cosmopolitan Libc, so a single
--- executable runs on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD.
--- Scripts run with `cosmic` inherit this portability automatically.
---
--- Shebangs (`#!/usr/bin/env cosmic`) work on Unix systems. On Windows,
--- invoke scripts explicitly: `cosmic script.tl`.

-- Example_shebang demonstrates making a Teal script directly executable
-- with a shebang line. The shebang is stripped during compilation so it
-- does not interfere with the Lua parser.
local function Example_shebang()
  local fs = require("cosmic.fs")
  local cio = require("cosmic.io")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = fs.mkdtemp("/tmp/deploy_example_XXXXXX")
  local script = fs.join(tmpdir, "greet.tl")

  -- Write a script with a shebang line
  cio.barf(script, '#!/usr/bin/env cosmic\nlocal name: string = "world"\nprint("hello " .. name)\n')

  -- Run it via cosmic (portable across all platforms)
  local h = spawn.spawn({cosmic, script}) as spawn.Handle
  local ok, out = h:read()
  fs.rmrf(tmpdir)
  assert(ok, out)
  print(out)
  -- Output:
  -- hello world
end

-- Example_script_args demonstrates structuring a script that accepts
-- command-line arguments. Arguments passed after the script name are
-- available in the global `arg` table, just like standard Lua.
local function Example_script_args()
  local fs = require("cosmic.fs")
  local cio = require("cosmic.io")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = fs.mkdtemp("/tmp/deploy_example_XXXXXX")
  local script = fs.join(tmpdir, "greet.tl")

  -- A script that reads arguments from the arg table
  cio.barf(script, [[#!/usr/bin/env cosmic
local name: string = arg[1] or "world"
print("hello " .. name)
]])

  -- Run with an argument
  local h = spawn.spawn({cosmic, script, "alice"}) as spawn.Handle
  local ok, out = h:read()
  assert(ok, out)
  io.write(out)

  -- Run without arguments to use the default
  h = spawn.spawn({cosmic, script}) as spawn.Handle
  ok, out = h:read()
  fs.rmrf(tmpdir)
  assert(ok, out)
  io.write(out)
  -- Output:
  -- hello alice
  -- hello world
end

-- Example_install_to_path demonstrates copying a script to a bin directory
-- so it can be invoked by name. On Unix, mark it executable with chmod.
-- Users add their bin directory to PATH if it is not already there.
local function Example_install_to_path()
  local fs = require("cosmic.fs")
  local cio = require("cosmic.io")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = fs.mkdtemp("/tmp/deploy_example_XXXXXX")

  -- Create a local bin directory (simulating ~/bin or ~/.local/bin)
  local bindir = fs.join(tmpdir, "bin")
  fs.makedirs(bindir)

  -- Write a script
  local script = fs.join(bindir, "mytool")
  cio.barf(script, '#!/usr/bin/env cosmic\nprint("mytool v1.0")\n')
  fs.chmod(script, 0x1ED) -- 0755

  -- Run it via cosmic (simulating PATH lookup)
  local h = spawn.spawn({cosmic, script}) as spawn.Handle
  local ok, out = h:read()
  fs.rmrf(tmpdir)
  assert(ok, out)
  print(out)
  -- Output:
  -- mytool v1.0
end

-- Example_portable_executable demonstrates using --embed to create a
-- standalone binary from a Teal script. The result is a single file
-- that runs on any platform without needing cosmic installed.
local function Example_portable_executable()
  local fs = require("cosmic.fs")
  local cio = require("cosmic.io")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = fs.mkdtemp("/tmp/deploy_example_XXXXXX")

  -- Write a Teal source file
  local tl_file = fs.join(tmpdir, "app.tl")
  cio.barf(tl_file, 'local msg: string = "portable app"\nprint(msg)\n')

  -- Compile .tl to .lua (--embed requires plain Lua)
  local h = spawn.spawn({cosmic, "--compile", tl_file}) as spawn.Handle
  local ok, lua_source = h:read()
  assert(ok, lua_source)

  -- Create app directory with compiled entry point
  local appdir = fs.join(tmpdir, "pkg")
  fs.makedirs(appdir)
  cio.barf(fs.join(appdir, "main.lua"), lua_source)

  -- Build a standalone executable
  local output = fs.join(tmpdir, "myapp")
  h = spawn.spawn({cosmic, "--embed", appdir, "--output", output}) as spawn.Handle
  ok, lua_source = h:read()
  assert(ok, lua_source)

  -- Run the standalone binary — no cosmic needed on the target machine
  h = spawn.spawn({output}) as spawn.Handle
  ok, lua_source = h:read()
  fs.rmrf(tmpdir)
  assert(ok, lua_source)
  print(lua_source)
  -- Output:
  -- portable app
end

return {}
