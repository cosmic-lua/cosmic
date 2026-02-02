--- Examples for the cosmic.fs module.
--- Demonstrates filesystem operations, path manipulation, and directory walking.

-- Example_path demonstrates path manipulation
local function Example_path()
  local fs = require("cosmic.fs")

  print(fs.dirname("/usr/local/bin"))
  print(fs.basename("/usr/local/bin"))
  print(fs.join("usr", "local", "bin"))

  -- Output:
  -- /usr/local
  -- bin
  -- usr/local/bin
end

-- Example_exists demonstrates checking file existence
local function Example_exists()
  local fs = require("cosmic.fs")

  print(fs.exists("."))
  print(fs.isdir("."))
  print(fs.isfile("."))

  -- Output:
  -- true
  -- true
  -- false
end

-- Example_stat demonstrates getting file metadata
local function Example_stat()
  local fs = require("cosmic.fs")

  local st = fs.stat("/")
  if st then
    print("is_dir:", fs.is_dir(st:mode()))
  end

  -- Output:
  -- is_dir:	true
end

return {}
