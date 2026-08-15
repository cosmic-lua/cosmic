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
  assert(line:find("INFO    server started", 1, true), "got: " .. line)
end
test_line_format()

local function test_level_tags()
  reset("debug")
  log.debug("d")
  log.info("i")
  log.warning("w")
  log.error("e")
  assert(#captured == 4, "expected 4 lines, got " .. tostring(#captured))
  assert(captured[1]:find("DEBUG   d", 1, true), "got: " .. captured[1])
  assert(captured[2]:find("INFO    i", 1, true), "got: " .. captured[2])
  assert(captured[3]:find("WARNING w", 1, true), "got: " .. captured[3])
  assert(captured[4]:find("ERROR   e", 1, true), "got: " .. captured[4])
end
test_level_tags()

local function test_error_threshold_suppresses_warning()
  reset("error")
  log.debug("hidden")
  log.info("hidden")
  log.warning("hidden")
  log.error("visible")
  assert(#captured == 1, "expected 1 line, got " .. tostring(#captured))
  assert(captured[1]:find("ERROR   visible", 1, true), "got: " .. captured[1])
end
test_error_threshold_suppresses_warning()

local function test_fields_sorted_by_key()
  reset("info")
  log.info("req", {zebra = 1, alpha = "ok", middle = true})
  local line = captured[1]
  assert(line:find("req alpha=ok middle=true zebra=1", 1, true), "got: " .. line)
end
test_fields_sorted_by_key()

-- Field values render with the shared grammar (cosmic._fields): "%"
-- and spaces percent-encode, so a value never splits a key=value
-- token — the same encoding instrument lines use.
local function test_field_values_use_shared_grammar()
  reset("info")
  log.info("m", {
      plain = "bare",
      spaced = "two words",
      eq = "k=v",
      pct = "50%",
      n = 42,
      b = false,
    })
  local line = captured[1]
  assert(line:find("plain=bare", 1, true), "got: " .. line)
  assert(line:find("spaced=two%20words", 1, true), "got: " .. line)
  assert(line:find("eq=k=v", 1, true), "got: " .. line)
  assert(line:find("pct=50%25", 1, true), "got: " .. line)
  assert(line:find("n=42", 1, true), "got: " .. line)
  assert(line:find("b=false", 1, true), "got: " .. line)
end
test_field_values_use_shared_grammar()

local function test_generic_log_function()
  reset("info")
  log.log("warning", "generic", {code = 7})
  assert(#captured == 1, "expected 1 line, got " .. tostring(#captured))
  assert(captured[1]:find("WARNING generic code=7", 1, true), "got: " .. captured[1])
end
test_generic_log_function()

local function test_level_getter_tracks_set_level()
  reset("info")
  assert(log.level() == "info", "got: " .. log.level())
  assert(log.set_level("warning"))
  assert(log.level() == "warning", "got: " .. log.level())
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

-- log() itself must not throw "compare nil with number" when a
-- runtime string smuggled in through a cast has no entry in severity[].
local function test_log_rejects_runtime_garbage_level()
  reset("info")
  log.log("verbose" as log.Level, "boom") -- cast: deliberate invalid input
  assert(#captured == 0, "an unknown level must be suppressed, not emitted")
end
test_log_rejects_runtime_garbage_level()

local function test_format_does_not_emit()
  reset("info")
  local line = log.format("error", "standalone", {id = 3})
  assert(#captured == 0, "format emitted a line")
  assert(line:match(iso_pattern), "no ISO timestamp: " .. line)
  assert(line:find("ERROR   standalone id=3", 1, true), "got: " .. line)
end
test_format_does_not_emit()

-- The sink contract: every emitted line arrives with its
-- level, so a destination that speaks severities (the syslog sink)
-- need not re-parse the line.
local function test_sink_receives_level()
  reset("info")
  local seen: {string} = {}
  log.set_output(function(line: string, level: log.Level)
      seen[#seen + 1] = level .. ":" .. line
    end)
  log.error("boom")
  log.set_output(function(line: string)
      captured[#captured + 1] = line
    end)
  assert(#seen == 1, "expected 1 line, got " .. tostring(#seen))
  assert(seen[1]:match("^error:"), "sink must receive the level, got: " .. seen[1])
end
test_sink_receives_level()

-- The sink maps log's four levels onto RFC 5424 wire severities
-- internally, so the falsifiable in-process contract is that every
-- level maps and the write never throws — delivery is unobservable
-- here (containers usually lack /dev/log), and a level that failed
-- to map to its integer would raise inside unix.syslog.
local function test_syslog_output_accepts_every_level_and_never_throws()
  local levels: {log.Level} = {"debug", "info", "warning", "error"}
  for _, level in ipairs(levels) do
    local ok, thrown = pcall(function(): boolean
        log.syslog_output("cosmic.log syslog test: " .. level, level)
        return true
      end)
    assert(ok, "syslog_output(" .. level .. ") must not throw: " .. tostring(thrown))
  end
end
test_syslog_output_accepts_every_level_and_never_throws()

-- An unknown level smuggled through a cast is dropped, not thrown
-- (mirrors log() and set_level()).
local function test_syslog_output_drops_runtime_garbage_level()
  local ok, thrown = pcall(function(): boolean
      log.syslog_output("boom", "verbose" as log.Level) -- cast: deliberate invalid input
      return true
    end)
  assert(ok, "unknown level must be dropped, not thrown: " .. tostring(thrown))
end
test_syslog_output_drops_runtime_garbage_level()

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
