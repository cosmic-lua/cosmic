--- Leveled logging.
--- A small structured logger for scripts and services: four severity
--- levels, a module-wide threshold, and optional key=value fields per
--- line. Lines go to stderr by default; redirect with set_output (for
--- tests, or to ship lines elsewhere). For writing to the system log
--- daemon instead, see cosmic.syslog.
---
--- Example usage:
---   local log = require("cosmic.log")
---   log.info("server started", {port = 8080})
---   log.set_level("debug")
---   log.debug("cache miss", {key = "user:42"})
---
--- Line format: `<iso8601-utc> <LEVEL> <message> <key=value ...>` with
--- fields sorted by key so output is deterministic. Logging is
--- infallible: emitters return nothing and never throw; a message
--- below the threshold costs one map lookup and no formatting.
---
--- The initial threshold is "info", or the value of the
--- COSMIC_LOG_LEVEL environment variable when it names a valid level.
---
--- Reserved names: log.with(fields): Logger (a child logger carrying
--- context fields) and log.new(options): Logger (independent logger
--- instances) are reserved for a post-stable battery. Do not reuse
--- these names for anything else.
local env = require("cosmic.env")
local time = require("cosmic.time")

--- Severity levels accepted by set_level and log, in increasing
--- order of severity.
local enum Level
  "debug"
  "info"
  "warn"
  "error"
end

-- Numeric severity for threshold comparison. Total over Level so the
-- checker proves every enum value ranks.
local severity < total >: {Level: number} = {
  debug = 1,
  info = 2,
  warn = 3,
  error = 4,
}

-- Uppercase tags, padded to a fixed width so messages align.
local tag < total >: {Level: string} = {
  debug = "DEBUG",
  info = "INFO ",
  warn = "WARN ",
  error = "ERROR",
}

local current: Level = "info"
do
  local initial = env.get("COSMIC_LOG_LEVEL")
  if initial == "debug" or initial == "info"
  or initial == "warn" or initial == "error" then
    current = initial
  end
end

local function write_stderr(line: string)
  io.stderr:write(line .. "\n")
end

local output: function(line: string) = write_stderr

--- Render one field value for a key=value pair. Strings that contain
--- whitespace, quotes, or "=" are quoted with %q so lines stay
--- unambiguous; everything else is tostring'd.
local function render_value(v: any): string
  if v is string then
    if string.find(v, "[%s\"=]") then
      return string.format("%q", v)
    end
    return v
  end
  return tostring(v)
end

--- Format a log line without emitting it. Exposed so custom outputs
--- and tests can reuse the exact format. The timestamp is the current
--- UTC time in ISO 8601; fields are rendered sorted by key.
--- @param level Level The severity level
--- @param message string The log message
--- @param fields {string:any}? Optional key=value context fields
--- @return string The formatted line, without a trailing newline
local function format(level: Level, message: string, fields?: {string: any}): string
  local ts = time.format_iso8601((time.now())) or "?"
  local parts: {string} = {ts, tag[level], message}
  if fields then
    local keys: {string} = {}
    for k in pairs(fields) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = k .. "=" .. render_value(fields[k])
    end
  end
  return table.concat(parts, " ")
end

--- Log a message at the given level. Suppressed (at the cost of one
--- table lookup) when the level ranks below the current threshold.
--- @param level Level The severity level
--- @param message string The log message
--- @param fields {string:any}? Optional key=value context fields
local function log(level: Level, message: string, fields?: {string: any})
  if severity[level] < severity[current] then
    return
  end
  output(format(level, message, fields))
end

--- Log a debug message (suppressed unless the threshold is "debug").
--- @param message string The log message
--- @param fields {string:any}? Optional key=value context fields
local function debug_msg(message: string, fields?: {string: any})
  log("debug", message, fields)
end

--- Log an informational message.
--- @param message string The log message
--- @param fields {string:any}? Optional key=value context fields
local function info(message: string, fields?: {string: any})
  log("info", message, fields)
end

--- Log a warning message.
--- @param message string The log message
--- @param fields {string:any}? Optional key=value context fields
local function warn(message: string, fields?: {string: any})
  log("warn", message, fields)
end

--- Log an error message.
--- @param message string The log message
--- @param fields {string:any}? Optional key=value context fields
local function error_msg(message: string, fields?: {string: any})
  log("error", message, fields)
end

--- Set the minimum level that gets emitted. The Level enum checks
--- literals statically; runtime strings smuggled in through casts get
--- false, err rather than corrupting the threshold (never throw from
--- library code).
--- @param level Level The new threshold
--- @return boolean True when the threshold was set
--- @return string? Error message when the level is not a valid Level
local function set_level(level: Level): boolean, string
  if not severity[level] then
    return false, "unknown log level: " .. tostring(level)
    .. " (expected debug, info, warn, or error)"
  end
  current = level
  return true
end

--- Get the current minimum level.
--- @return Level The current threshold
local function level(): Level
  return current
end

--- Redirect where formatted lines go. The function receives each line
--- without a trailing newline. Call with no argument to restore the
--- default stderr output.
--- @param out function(line: string)? The new output, or nil for stderr
local function set_output(out?: function(line: string))
  if out then
    output = out
  else
    output = write_stderr
  end
end

local record LogModule
  type Level = Level

  log: function(level: Level, message: string, fields?: {string: any})
  debug: function(message: string, fields?: {string: any})
  info: function(message: string, fields?: {string: any})
  warn: function(message: string, fields?: {string: any})
  error: function(message: string, fields?: {string: any})

  format: function(level: Level, message: string, fields?: {string: any}): string
  set_level: function(level: Level): boolean, string
  level: function(): Level
  set_output: function(out?: function(line: string))
end

local M: LogModule = {
  log = log,
  debug = debug_msg,
  info = info,
  warn = warn,
  error = error_msg,

  format = format,
  set_level = set_level,
  level = level,
  set_output = set_output,
}

return M
