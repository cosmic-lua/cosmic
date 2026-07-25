--- Examples for the cosmic.env module.
--- Demonstrates reading, setting, and listing environment variables.
--- For the common case of reading a single variable, env.get() is
--- the simplest approach (it wraps os.getenv() internally).

-- Example_get demonstrates reading a single environment variable.
-- This is the most common operation. env.get() returns the value
-- as a string, or nil if the variable is not set.
local function Example_get()
  local env = require("cosmic.env")
  local path = env.get("PATH")
  if path then
    print("PATH is set")
  end
  -- Output:
  -- PATH is set
end

-- Example_get_missing demonstrates reading a variable that is not set.
local function Example_get_missing()
  local env = require("cosmic.env")
  local value = env.get("COSMIC_EXAMPLE_UNSET_VAR")
  print(tostring(value))
  -- Output:
  -- nil
end

-- Example_set_and_get demonstrates setting and reading back a variable.
local function Example_set_and_get()
  local env = require("cosmic.env")
  local ok, err = env.set("COSMIC_EXAMPLE_VAR", "hello")
  if not ok then
    print("set failed: " .. tostring(err))
    return
  end
  print(env.get("COSMIC_EXAMPLE_VAR"))
  env.unset("COSMIC_EXAMPLE_VAR")
  -- Output:
  -- hello
end

-- Example_unset demonstrates removing an environment variable.
local function Example_unset()
  local env = require("cosmic.env")
  env.set("COSMIC_EXAMPLE_TEMP", "temporary")
  env.unset("COSMIC_EXAMPLE_TEMP")
  print(tostring(env.get("COSMIC_EXAMPLE_TEMP")))
  -- Output:
  -- nil
end

-- Example_all demonstrates listing all environment variables.
-- env.all() returns a plain {string:string} table, unlike the
-- raw unix.environ() call which has a less convenient format.
local function Example_all()
  local env = require("cosmic.env")
  local vars = env.all()
  local count = 0
  for _ in pairs(vars) do
    count = count + 1
  end
  print("environment has " .. tostring(count > 0) .. " variables")
  -- Output:
  -- environment has true variables
end

-- Suppress unused warnings for examples
local _ = {Example_get, Example_get_missing, Example_set_and_get, Example_unset, Example_all}
