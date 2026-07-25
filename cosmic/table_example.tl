--- Examples for the cosmic.table module.
--- Demonstrates deep copy/merge/equality and the map/filter/reduce
--- list transforms. Bind the module as `tbl` so Lua's `table` global
--- stays reachable.

-- Example_deep_merge demonstrates layering overrides onto defaults:
-- nested tables merge recursively, scalars are replaced.
local function Example_deep_merge()
  local tbl = require("cosmic.table")
  local defaults: {string: any} = {
    host = "localhost",
    limits = {mem = 64, cpu = 1},
  }
  local overrides: {string: any} = {
    limits = {mem = 128},
    debug = true,
  }
  local config = tbl.deep_merge(defaults, overrides)
  print((config.limits as {string: any}).mem, -- cast: from any
    (config.limits as {string: any}).cpu, config.debug) -- cast: from any
  -- Output:
  -- 128	1	true
end

-- Example_deep_copy demonstrates that copies are fully independent:
-- mutating the copy leaves the original untouched.
local function Example_deep_copy()
  local tbl = require("cosmic.table")
  local original: {string: any} = {settings = {theme = "dark"}}
  local copy = tbl.deep_copy(original) as {string: any} -- cast: from any
  local copy_settings = copy.settings as {string: any} -- cast: from any
  copy_settings.theme = "light"
  print((original.settings as {string: any}).theme) -- cast: from any
  -- Output:
  -- dark
end

-- Example_map_filter_reduce demonstrates chaining the list
-- transforms: square the numbers, keep the even squares, sum them.
local function Example_map_filter_reduce()
  local tbl = require("cosmic.table")
  local squares = tbl.map({1, 2, 3, 4}, function(n: number): number
      return n * n
    end)
  local even = tbl.filter(squares, function(n: number): boolean
      return n % 2 == 0
    end)
  local sum = tbl.reduce(even, function(acc: number, n: number): number
      return acc + n
    end, 0)
  print(sum)
  -- Output:
  -- 20
end

-- Suppress unused warnings for examples
local _ = {Example_deep_merge, Example_deep_copy, Example_map_filter_reduce}
