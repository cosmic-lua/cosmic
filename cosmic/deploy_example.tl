--- Examples for deploying cosmic scripts.
--- Demonstrates shebang usage, reading argv in a structured script,
--- installing scripts to PATH, and building portable executables.
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
  local check = require("cosmic.check")
  local fs = require("cosmic.fs")
  local child = require("cosmic.child")
  local cosmic = arg[-1]

  local base = os.getenv("TEST_TMPDIR") or "/tmp"
  local tmpdir = check.must(fs.temp_dir(fs.join(base, "deploy_example_XXXXXX")))
  local script = fs.join(tmpdir, "greet.tl")

  -- Write a script with a shebang line
  assert(fs.write(script, '#!/usr/bin/env cosmic\nlocal name: string = "world"\nprint("hello " .. name)\n'))

  -- Run it via cosmic (portable across all platforms)
  local r = check.must(child.run({cosmic, script}))
  assert(fs.remove_all(tmpdir))
  assert(r.ok, r.stderr)
  print(r.stdout)
  -- Output:
  -- hello world
end

-- Example_script_args demonstrates structuring a script that accepts
-- command-line arguments. Arguments passed after the script name are
-- available in the global `arg` table, just like standard Lua.
local function Example_script_args()
  local check = require("cosmic.check")
  local fs = require("cosmic.fs")
  local child = require("cosmic.child")
  local cosmic = arg[-1]

  local base = os.getenv("TEST_TMPDIR") or "/tmp"
  local tmpdir = check.must(fs.temp_dir(fs.join(base, "deploy_example_XXXXXX")))
  local script = fs.join(tmpdir, "greet.tl")

  -- A script that reads arguments from the arg table
  assert(fs.write(script, [[#!/usr/bin/env cosmic
local name: string = arg[1] or "world"
print("hello " .. name)
]]))

  -- Run with an argument
  local r = check.must(child.run({cosmic, script, "alice"}))
  assert(r.ok, r.stderr)
  io.write(r.stdout)

  -- Run without arguments to use the default
  r = check.must(child.run({cosmic, script}))
  assert(fs.remove_all(tmpdir))
  assert(r.ok, r.stderr)
  io.write(r.stdout)
  -- Output:
  -- hello alice
  -- hello world
end

-- Example_install_to_path demonstrates copying a script to a bin directory
-- so it can be invoked by name. On Unix, mark it executable with chmod.
-- Users add their bin directory to PATH if it is not already there.
local function Example_install_to_path()
  local check = require("cosmic.check")
  local fs = require("cosmic.fs")
  local child = require("cosmic.child")
  local cosmic = arg[-1]

  local base = os.getenv("TEST_TMPDIR") or "/tmp"
  local tmpdir = check.must(fs.temp_dir(fs.join(base, "deploy_example_XXXXXX")))

  -- Create a local bin directory (simulating ~/bin or ~/.local/bin)
  local bindir = fs.join(tmpdir, "bin")
  assert(fs.make_dirs(bindir))

  -- Write a script
  local script = fs.join(bindir, "mytool")
  assert(fs.write(script, '#!/usr/bin/env cosmic\nprint("mytool v1.0")\n'))
  assert(fs.chmod(script, 0x1ED)) -- 0755

  -- Run it via cosmic (simulating PATH lookup)
  local r = check.must(child.run({cosmic, script}))
  assert(fs.remove_all(tmpdir))
  assert(r.ok, r.stderr)
  print(r.stdout)
  -- Output:
  -- mytool v1.0
end

-- Example_portable_executable demonstrates using --embed to create a
-- standalone binary from a Teal script. The result is a single file
-- that runs on any platform without needing cosmic installed.
local function Example_portable_executable()
  local check = require("cosmic.check")
  local fs = require("cosmic.fs")
  local child = require("cosmic.child")
  local cosmic = arg[-1]

  local base = os.getenv("TEST_TMPDIR") or "/tmp"
  local tmpdir = check.must(fs.temp_dir(fs.join(base, "deploy_example_XXXXXX")))

  -- Write a Teal source file
  local tl_file = fs.join(tmpdir, "app.tl")
  assert(fs.write(tl_file, 'local msg: string = "portable app"\nprint(msg)\n'))

  -- Compile .tl to .lua (--embed requires plain Lua)
  local r = check.must(child.run({cosmic, "--compile", tl_file}))
  assert(r.ok, r.stderr)
  local lua_source = r.stdout

  -- Create app directory with compiled entry point
  local appdir = fs.join(tmpdir, "pkg")
  assert(fs.make_dirs(appdir))
  assert(fs.write(fs.join(appdir, "main.lua"), lua_source))

  -- Build a standalone executable
  local output = fs.join(tmpdir, "myapp")
  r = check.must(child.run({cosmic, "--embed", appdir, "--output", output}))
  assert(r.ok, r.stderr)

  -- Run the standalone binary — no cosmic needed on the target machine
  r = check.must(child.run({output}))
  assert(fs.remove_all(tmpdir))
  assert(r.ok, r.stderr)
  print(r.stdout)
  -- Output:
  -- portable app
end

-- Suppress unused warnings for examples
local _ = {
  Example_shebang,
  Example_script_args,
  Example_install_to_path,
  Example_portable_executable,
}
