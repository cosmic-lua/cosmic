--- System logging.
--- Wraps unix.syslog() for writing to the system log. The severity is
--- a string enum (api-review-8: was eight LOG_* integer constants plus
--- eight per-level wrapper functions) — one write(), with the level
--- named in words, like cosmic.log.
local unix = require("cosmo.unix")

--- RFC 5424 severity, named. write() maps these onto the fixed wire
--- values (emergency=0 … debug=7).
local enum Level
  "emergency"
  "alert"
  "critical"
  "error"
  "warning"
  "notice"
  "info"
  "debug"
end

local PRIORITY < const >: {Level: integer} = {
  emergency = unix.LOG_EMERG,
  alert = unix.LOG_ALERT,
  critical = unix.LOG_CRIT,
  error = unix.LOG_ERR,
  warning = unix.LOG_WARNING,
  notice = unix.LOG_NOTICE,
  info = unix.LOG_INFO,
  debug = unix.LOG_DEBUG,
}

--- Write a message to the system log.
--- @param level Level Severity: "emergency" | "alert" | "critical" |
--- "error" | "warning" | "notice" | "info" | "debug"
--- @param message string The message to log
local function write(level: Level, message: string)
  unix.syslog(PRIORITY[level], message)
end

local record SyslogModule
  type Level = Level
  write: function(level: Level, message: string)
end

local M: SyslogModule = {
  write = write,
}

return M
