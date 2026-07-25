--- Examples for the cosmic.envd module.
--- Demonstrates loading dotenv files from an env.d directory, including
--- the extract/update/embed cycle for baking variables into an executable.

-- Example_load_dir creates a temp directory with dotenv files and loads them.
-- Files are concatenated in lexical order; later files override earlier ones.
local function Example_load_dir()
  local envd = require("cosmic.envd")
  local env = require("cosmic.env")
  local fs = require("cosmic.fs")

  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
  local dir = fs.join(tmpdir, "envd_example")
  fs.makedirs(dir)
  fs.write(fs.join(dir, "00-defaults"), "MY_APP_NAME=cosmic-example\nMY_APP_PORT=8080\n")
  fs.write(fs.join(dir, "01-overrides"), "MY_APP_PORT=9090\n")

  env.unset("MY_APP_NAME")
  env.unset("MY_APP_PORT")

  local result = envd.load_dir(dir)
  print("loaded " .. tostring(result.count) .. " variable(s)")
  print("MY_APP_NAME=" .. tostring(env.get("MY_APP_NAME")))
  print("MY_APP_PORT=" .. tostring(env.get("MY_APP_PORT")))

  env.unset("MY_APP_NAME")
  env.unset("MY_APP_PORT")
  -- Output:
  -- loaded 2 variable(s)
  -- MY_APP_NAME=cosmic-example
  -- MY_APP_PORT=9090
end

-- Example_extract_update_embed demonstrates the full cycle: extract the
-- current executable's zip, add an env.d directory with credentials,
-- re-embed, and run the new executable to show the vars are available.
local function Example_extract_update_embed()
  local check = require("cosmic.check")
  local fs = require("cosmic.fs")
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]

  local tmpdir = fs.mkdtemp("/tmp/envd_example_XXXXXX")

  -- 1. extract current executable
  local extractdir = fs.join(tmpdir, "extracted")
  local r = check.must(spawn.run({cosmic, "--extract", extractdir}))
  assert(r.ok, r.stderr)

  -- 2. add env.d with a credential
  local envd_dir = fs.join(extractdir, "embed", "env.d")
  fs.makedirs(envd_dir)
  fs.write(fs.join(envd_dir, "credentials"), "MY_SECRET_TOKEN=tok-example-12345\n")

  -- 3. re-embed with a main.lua that loads env.d and prints the var name
  -- No loader prelude: --embed wraps a custom entry with the cosmic
  -- runtime searcher (#687), so require() just works.
  fs.write(fs.join(extractdir, "main.lua"), [[
local envd = require("cosmic.envd")
local env = require("cosmic.env")
local result = envd.load()
print("envd loaded " .. result.count .. " var(s)")
print("MY_SECRET_TOKEN is " .. (env.get("MY_SECRET_TOKEN") and "set" or "unset"))
]])

  -- 4. build new executable
  local output = fs.join(tmpdir, "myapp")
  r = check.must(spawn.run({cosmic, "--embed", extractdir, "--output", output}))
  assert(r.ok, r.stderr)

  -- 5. run it
  r = check.must(spawn.run({output}))
  fs.rmrf(tmpdir)
  print(r.stdout)
  -- Output:
  -- envd loaded 1 var(s)
  -- MY_SECRET_TOKEN is set
end

-- Example_variable_expansion shows ${VAR} expansion in dotenv values.
-- Variables defined earlier in the same file or from an external context
-- are available for expansion. Supports ${VAR:-default} and ${VAR-default}.
local function Example_variable_expansion()
  local envd = require("cosmic.envd")

  -- basic expansion: later values can reference earlier ones
  local vars = envd.parse("HOST=localhost\nPORT=8080\nURL=http://${HOST}:${PORT}\n")
  print("URL=" .. vars["URL"])

  -- ${VAR:-default} uses fallback when unset or empty
  vars = envd.parse("TIMEOUT=${MISSING:-30}\n")
  print("TIMEOUT=" .. vars["TIMEOUT"])

  -- ${VAR-default} uses fallback only when unset (empty is kept)
  vars = envd.parse("EMPTY=\nKEEP=${EMPTY-fallback}\n")
  print("KEEP=" .. vars["KEEP"])
  -- Output:
  -- URL=http://localhost:8080
  -- TIMEOUT=30
  -- KEEP=
end

-- Suppress unused warnings for examples
local _ = {Example_load_dir, Example_extract_update_embed, Example_variable_expansion}
