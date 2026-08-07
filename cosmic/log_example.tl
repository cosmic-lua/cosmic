--- Examples for the cosmic.log module.
--- Demonstrates leveled logging with key=value fields, thresholds,
--- and output redirection. Examples capture lines with set_output so
--- their printed output is deterministic (real timestamps vary).

-- Example_info demonstrates the most common call: a message plus
-- key=value context fields, emitted at the default "info" threshold.
local function Example_info()
  local log = require("cosmic.log")
  log.set_output(function(line: string)
      -- drop the timestamp so the example output is stable
      print((line:gsub("^%S+ ", "")))
    end)
  log.info("server started", {port = 8080, tls = false})
  log.set_output()
  -- Output:
  -- INFO    server started port=8080 tls=false
end

-- Example_threshold demonstrates level filtering: debug lines are
-- suppressed until the threshold is lowered with set_level.
local function Example_threshold()
  local log = require("cosmic.log")
  log.set_output(function(line: string)
      print((line:gsub("^%S+ ", "")))
    end)
  assert(log.set_level("info"))
  log.debug("cache miss")
  assert(log.set_level("debug"))
  log.debug("cache miss", {key = "user:42"})
  assert(log.set_level("info"))
  log.set_output()
  -- Output:
  -- DEBUG   cache miss key=user:42
end

-- Example_format demonstrates formatting a line without emitting it,
-- for feeding cosmic.log's format into another sink.
local function Example_format()
  local log = require("cosmic.log")
  local line = log.format("warning", "disk almost full", {pct = 93})
  print((line:gsub("^%S+ ", "")))
  -- Output:
  -- WARNING disk almost full pct=93
end

-- Suppress unused warnings for examples
local _ = {Example_info, Example_threshold, Example_format}
