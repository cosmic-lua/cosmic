--- Tests for cosmic.log.
local log = require("cosmic.log")

-- Capture emitted lines instead of writing to stderr. Every test
-- resets the capture buffer and pins the threshold it needs, so tests
-- stay independent of COSMIC_LOG_LEVEL in the environment.
local captured: {string} = {}
log.set_output(function(line: string)
    captured[#captured + 1] = line
  end)

local function reset(level: log.Level)
  captured = {}
  assert(log.set_level(level))
end

local iso_pattern < const > = "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ "

local function test_default_threshold_suppresses_debug()
  reset("info")
  log.debug("hidden")
  log.info("visible")
  assert(#captured == 1, "expected 1 line, got " .. tostring(#captured))
  assert(captured[1]:find("visible", 1, true), "got: " .. captured[1])
end
test_default_threshold_suppresses_debug()

local function test_line_format()
  reset("info")
  log.info("server started")
  local line = captured[1]
  assert(line:match(iso_pattern), "no ISO timestamp: " .. line)
  assert(line:find("INFO  server started", 1, true), "got: " .. line)
end
test_line_format()

local function test_level_tags()
  reset("debug")
  log.debug("d")
  log.info("i")
  log.warn("w")
  log.error("e")
  assert(#captured == 4, "expected 4 lines, got " .. tostring(#captured))
  assert(captured[1]:find("DEBUG d", 1, true), "got: " .. captured[1])
  assert(captured[2]:find("INFO  i", 1, true), "got: " .. captured[2])
  assert(captured[3]:find("WARN  w", 1, true), "got: " .. captured[3])
  assert(captured[4]:find("ERROR e", 1, true), "got: " .. captured[4])
end
test_level_tags()

local function test_error_threshold_suppresses_warn()
  reset("error")
  log.debug("hidden")
  log.info("hidden")
  log.warn("hidden")
  log.error("visible")
  assert(#captured == 1, "expected 1 line, got " .. tostring(#captured))
  assert(captured[1]:find("ERROR visible", 1, true), "got: " .. captured[1])
end
test_error_threshold_suppresses_warn()

local function test_fields_sorted_by_key()
  reset("info")
  log.info("req", {zebra = 1, alpha = "ok", middle = true})
  local line = captured[1]
  assert(line:find("req alpha=ok middle=true zebra=1", 1, true), "got: " .. line)
end
test_fields_sorted_by_key()

local function test_field_values_quoted_when_ambiguous()
  reset("info")
  log.info("m", {
      plain = "bare",
      spaced = "two words",
      eq = "k=v",
      n = 42,
      b = false,
    })
  local line = captured[1]
  assert(line:find("plain=bare", 1, true), "got: " .. line)
  assert(line:find('spaced="two words"', 1, true), "got: " .. line)
  assert(line:find('eq="k=v"', 1, true), "got: " .. line)
  assert(line:find("n=42", 1, true), "got: " .. line)
  assert(line:find("b=false", 1, true), "got: " .. line)
end
test_field_values_quoted_when_ambiguous()

local function test_generic_log_function()
  reset("info")
  log.log("warn", "generic", {code = 7})
  assert(#captured == 1, "expected 1 line, got " .. tostring(#captured))
  assert(captured[1]:find("WARN  generic code=7", 1, true), "got: " .. captured[1])
end
test_generic_log_function()

local function test_level_getter_tracks_set_level()
  reset("info")
  assert(log.level() == "info", "got: " .. log.level())
  assert(log.set_level("warn"))
  assert(log.level() == "warn", "got: " .. log.level())
end
test_level_getter_tracks_set_level()

local function test_set_level_rejects_runtime_garbage()
  reset("info")
  local ok, err = log.set_level("verbose" as log.Level) -- cast: deliberate invalid input
  assert(not ok, "expected rejection")
  assert(err and err:find("unknown log level: verbose", 1, true),
    "got: " .. tostring(err))
  assert(log.level() == "info", "threshold corrupted: " .. log.level())
end
test_set_level_rejects_runtime_garbage()

local function test_format_does_not_emit()
  reset("info")
  local line = log.format("error", "standalone", {id = 3})
  assert(#captured == 0, "format emitted a line")
  assert(line:match(iso_pattern), "no ISO timestamp: " .. line)
  assert(line:find("ERROR standalone id=3", 1, true), "got: " .. line)
end
test_format_does_not_emit()

local function test_set_output_restores_stderr_default()
  reset("info")
  -- Restoring the default must not raise; emitting afterwards writes
  -- to stderr (visible in test output on failure) rather than the
  -- capture buffer.
  log.set_output()
  log.debug("suppressed, goes nowhere")
  log.set_output(function(line: string)
      captured[#captured + 1] = line
    end)
  log.info("captured again")
  assert(#captured == 1, "expected 1 line, got " .. tostring(#captured))
end
test_set_output_restores_stderr_default()
