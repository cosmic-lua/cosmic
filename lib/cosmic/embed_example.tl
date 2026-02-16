--- Examples for the cosmic.embed module.
--- Demonstrates creating custom executables and extracting zip contents.
---
--- Any file can be embedded, but the entry point must be a main.lua file
--- (plain Lua). Teal files are not compiled at runtime — compile them to
--- .lua first with --compile. See Example_embed_from_teal for that workflow.

-- Example_embed_directory demonstrates embedding a directory into a new executable.
-- The directory must contain a main.lua entry point.
local function Example_embed_directory()
  local fs = require("cosmic.fs")
  local cio = require("cosmic.io")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = fs.mkdtemp("/tmp/embed_example_XXXXXX")

  -- Create a simple app directory with a main.lua entry point
  local appdir = fs.join(tmpdir, "myapp")
  fs.makedirs(appdir)
  cio.barf(fs.join(appdir, "main.lua"), 'print("hello from myapp")\n')

  -- Build it
  local output = fs.join(tmpdir, "hello")
  local h = spawn.spawn({cosmic, "--embed", appdir, "--output", output})
  local ok, out = h:read()
  assert(ok, out)

  -- Run it
  h = spawn.spawn({output})
  ok, out = h:read()
  fs.rmrf(tmpdir)
  print(out)
  -- Output:
  -- hello from myapp
end

-- Example_extract_roundtrip demonstrates extracting and re-embedding
local function Example_extract_roundtrip()
  local fs = require("cosmic.fs")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = fs.mkdtemp("/tmp/embed_example_XXXXXX")

  -- Extract the running executable's zip contents
  local extractdir = fs.join(tmpdir, "extracted")
  local h = spawn.spawn({cosmic, "--extract", extractdir})
  local ok, out = h:read()
  assert(ok, out)

  -- The extracted directory contains main.lua and all bundled files
  local main_exists = fs.isfile(fs.join(extractdir, "main.lua"))
  fs.rmrf(tmpdir)
  print("main.lua extracted:", main_exists)
  -- Output:
  -- main.lua extracted:	true
end

-- Example_embed_with_libraries demonstrates using cosmic libraries in embedded code
local function Example_embed_with_libraries()
  local fs = require("cosmic.fs")
  local cio = require("cosmic.io")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = fs.mkdtemp("/tmp/embed_example_XXXXXX")

  -- Create an app that uses cosmic.child (a bundled library)
  local appdir = fs.join(tmpdir, "app")
  fs.makedirs(appdir)
  cio.barf(fs.join(appdir, "main.lua"), [[
local child = require("cosmic.child")
local h = child.spawn({"echo", "it works"})
local ok, out = h:read()
io.write(out)
]])

  local output = fs.join(tmpdir, "myapp")
  local h = spawn.spawn({cosmic, "--embed", appdir, "--output", output})
  local ok, out = h:read()
  assert(ok, out)

  h = spawn.spawn({output})
  ok, out = h:read()
  fs.rmrf(tmpdir)
  print(out)
  -- Output:
  -- it works
end

-- Example_embed_from_teal demonstrates the Teal workflow: compile .tl to .lua,
-- then embed. The entry point must be main.lua since Teal is not compiled at
-- runtime.
local function Example_embed_from_teal()
  local fs = require("cosmic.fs")
  local cio = require("cosmic.io")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = fs.mkdtemp("/tmp/embed_example_XXXXXX")
  local appdir = fs.join(tmpdir, "myapp")
  fs.makedirs(appdir)

  -- Write a Teal source file
  local tl_file = fs.join(tmpdir, "main.tl")
  cio.barf(tl_file, 'local msg: string = "hello from teal"\nprint(msg)\n')

  -- Compile .tl to .lua using cosmic --compile
  local h = spawn.spawn({cosmic, "--compile", tl_file})
  local ok, lua_source = h:read()
  assert(ok, lua_source)

  -- Write the compiled Lua as the entry point
  cio.barf(fs.join(appdir, "main.lua"), lua_source)

  -- Embed and run
  local output = fs.join(tmpdir, "from_teal")
  h = spawn.spawn({cosmic, "--embed", appdir, "--output", output})
  ok, lua_source = h:read()
  assert(ok, lua_source)

  h = spawn.spawn({output})
  ok, lua_source = h:read()
  fs.rmrf(tmpdir)
  print(lua_source)
  -- Output:
  -- hello from teal
end

return {}
