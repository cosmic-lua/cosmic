--- Examples for the cosmic.envd module.
--- Demonstrates loading environment variables from a directory of files.

-- Example_load_dir creates a temp directory with sample env files and loads them.
-- Each file's name becomes the variable name; its content becomes the value.
local function Example_load_dir()
  local envd = require("cosmic.envd")
  local env = require("cosmic.env")
  local fs = require("cosmic.fs")
  local cio = require("cosmic.io")

  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
  local dir = fs.join(tmpdir, "envd_example")
  fs.makedirs(dir)
  cio.barf(fs.join(dir, "MY_APP_NAME"), "cosmic-example")
  cio.barf(fs.join(dir, "MY_APP_PORT"), "8080")

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
  -- MY_APP_PORT=8080
end

return {}
