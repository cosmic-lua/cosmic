--- Examples for the cosmic.embed module.
--- Demonstrates creating custom executables and extracting zip contents.
---
--- NOTE: embedded code must be plain Lua (.lua files). The zip runtime does
--- not compile Teal, so .tl files must be compiled first with --compile.
--- See Example_embed_from_teal below for the compile-then-embed workflow.

-- Example_embed_directory demonstrates embedding a directory into a new executable.
-- The entry point must be main.lua (plain Lua, not Teal).
local function Example_embed_directory()
  local cosmo = require("cosmo")
  local unix = require("cosmo.unix")
  local path = require("cosmo.path")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = unix.mkdtemp("/tmp/embed_example_XXXXXX")

  -- Create a simple app directory with a main.lua entry point.
  -- This must be a .lua file — .tl files are not compiled at runtime.
  local appdir = path.join(tmpdir, "myapp")
  unix.makedirs(appdir)
  cosmo.Barf(path.join(appdir, "main.lua"), 'print("hello from myapp")\n')

  -- Build it
  local output = path.join(tmpdir, "hello")
  local h = spawn.spawn({cosmic, "--embed", appdir, "--output", output})
  local ok, out = h:read()
  assert(ok, out)

  -- Run it
  h = spawn.spawn({output})
  ok, out = h:read()
  unix.rmrf(tmpdir)
  print(out)
  -- Output:
  -- hello from myapp
end

-- Example_extract_roundtrip demonstrates extracting and re-embedding
local function Example_extract_roundtrip()
  local unix = require("cosmo.unix")
  local path = require("cosmo.path")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = unix.mkdtemp("/tmp/embed_example_XXXXXX")

  -- Extract the running executable's zip contents
  local extractdir = path.join(tmpdir, "extracted")
  local h = spawn.spawn({cosmic, "--extract", extractdir})
  local ok, out = h:read()
  assert(ok, out)

  -- The extracted directory contains main.lua and all bundled files
  local main_exists = path.isfile(path.join(extractdir, "main.lua"))
  unix.rmrf(tmpdir)
  print("main.lua extracted:", main_exists)
  -- Output:
  -- main.lua extracted:	true
end

-- Example_embed_with_libraries demonstrates using cosmic libraries in embedded code
local function Example_embed_with_libraries()
  local cosmo = require("cosmo")
  local unix = require("cosmo.unix")
  local path = require("cosmo.path")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = unix.mkdtemp("/tmp/embed_example_XXXXXX")

  -- Create an app that uses cosmic.child (a bundled library)
  local appdir = path.join(tmpdir, "app")
  unix.makedirs(appdir)
  cosmo.Barf(path.join(appdir, "main.lua"), [[
local child = require("cosmic.child")
local h = child.spawn({"echo", "it works"})
local ok, out = h:read()
io.write(out)
]])

  local output = path.join(tmpdir, "myapp")
  local h = spawn.spawn({cosmic, "--embed", appdir, "--output", output})
  local ok, out = h:read()
  assert(ok, out)

  h = spawn.spawn({output})
  ok, out = h:read()
  unix.rmrf(tmpdir)
  print(out)
  -- Output:
  -- it works
end

-- Example_embed_from_teal demonstrates compiling Teal to Lua before embedding.
-- You cannot embed .tl files directly — the zip runtime only executes Lua.
-- Use cosmic --compile to produce .lua output, then embed that.
local function Example_embed_from_teal()
  local cosmo = require("cosmo")
  local unix = require("cosmo.unix")
  local path = require("cosmo.path")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = unix.mkdtemp("/tmp/embed_example_XXXXXX")
  local appdir = path.join(tmpdir, "myapp")
  unix.makedirs(appdir)

  -- Write a Teal source file
  local tl_file = path.join(tmpdir, "main.tl")
  cosmo.Barf(tl_file, 'local msg: string = "hello from teal"\nprint(msg)\n')

  -- Compile .tl to .lua using cosmic --compile
  local h = spawn.spawn({cosmic, "--compile", tl_file})
  local ok, lua_source = h:read()
  assert(ok, lua_source)

  -- Write the compiled Lua as the entry point
  cosmo.Barf(path.join(appdir, "main.lua"), lua_source)

  -- Embed and run
  local output = path.join(tmpdir, "from_teal")
  h = spawn.spawn({cosmic, "--embed", appdir, "--output", output})
  ok, lua_source = h:read()
  assert(ok, lua_source)

  h = spawn.spawn({output})
  ok, lua_source = h:read()
  unix.rmrf(tmpdir)
  print(lua_source)
  -- Output:
  -- hello from teal
end

return {}
