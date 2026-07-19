#!/usr/bin/env cosmic
--- Examples for cosmic.coverage.

local check = require("cosmic.check")

--- Count executed lines for a chunk of code.
--- start() installs a line hook, stop() removes it, and snapshot()
--- returns hit counts keyed by chunk source and line number.
local function Example_collect()
  local coverage = require("cosmic.coverage")
  local chunk = load(
    "local total = 0\nfor i = 1, 4 do\n  total = total + i\nend\n",
    "@example_chunk.lua")
  local run = assert(chunk)
  coverage.start()
  run()
  coverage.stop()
  local snap = coverage.snapshot()
  local hits = check.must(snap["@example_chunk.lua"])
  print("line 1 ran " .. hits[1] .. " time(s)")
  print("line 3 ran " .. hits[3] .. " time(s)")
  -- Output:
  -- line 1 ran 1 time(s)
  -- line 3 ran 4 time(s)
end

local _ = {Example_collect}
