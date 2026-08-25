--- Examples for the cosmic.deep module.
--- Demonstrates deep copy, recursive merge, and structural equality
--- for nested tables.

-- Example_merge demonstrates layering overrides onto defaults:
-- nested tables merge recursively, scalars are replaced.
local function Example_merge()
  local deep = require("cosmic.deep")
  -- A record fixture is what makes the merge result typed: the generic
  -- signature hands back the type it was given, so the reads below need
  -- no cast.
  local record Limits
    mem: integer
    cpu: integer
  end
  local record Config
    host: string
    limits: Limits
    debug: boolean
  end
  local defaults: Config = {
    host = "localhost",
    limits = {mem = 64, cpu = 1},
  }
  local overrides: Config = {
    limits = {mem = 128},
    debug = true,
  }
  local config = deep.merge(defaults, overrides)
  print(config.limits.mem, config.limits.cpu, config.debug)
  -- Output:
  -- 128	1	true
end

-- Example_copy demonstrates that copies are fully independent:
-- mutating the copy leaves the original untouched.
local function Example_copy()
  local deep = require("cosmic.deep")
  local record Settings
    theme: string
  end
  local record Prefs
    settings: Settings
  end
  local original: Prefs = {settings = {theme = "dark"}}
  local copy = deep.copy(original)
  local copy_settings = copy.settings
  copy_settings.theme = "light"
  print(original.settings.theme)
  -- Output:
  -- dark
end

-- Example_equal demonstrates structural comparison: same key sets and
-- deep-equal values, regardless of table identity.
local function Example_equal()
  local deep = require("cosmic.deep")
  print(deep.equal({a = {1, 2}}, {a = {1, 2}}))
  print(deep.equal({a = {1, 2}}, {a = {1, 3}}))
  -- Output:
  -- true
  -- false
end

-- Suppress unused warnings for examples
local _ = {Example_merge, Example_copy, Example_equal}
