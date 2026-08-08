--- Examples for the cosmic.deep module.
--- Demonstrates deep copy, recursive merge, and structural equality
--- for nested tables.

-- Example_merge demonstrates layering overrides onto defaults:
-- nested tables merge recursively, scalars are replaced.
local function Example_merge()
  local deep = require("cosmic.deep")
  local defaults: {string: any} = {
    host = "localhost",
    limits = {mem = 64, cpu = 1},
  }
  local overrides: {string: any} = {
    limits = {mem = 128},
    debug = true,
  }
  local config = deep.merge(defaults, overrides)
  print((config.limits as {string: any}).mem, -- cast: from any
    (config.limits as {string: any}).cpu, config.debug) -- cast: from any
  -- Output:
  -- 128	1	true
end

-- Example_copy demonstrates that copies are fully independent:
-- mutating the copy leaves the original untouched.
local function Example_copy()
  local deep = require("cosmic.deep")
  local original: {string: any} = {settings = {theme = "dark"}}
  local copy = deep.copy(original) as {string: any} -- cast: from any
  local copy_settings = copy.settings as {string: any} -- cast: from any
  copy_settings.theme = "light"
  print((original.settings as {string: any}).theme) -- cast: from any
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
