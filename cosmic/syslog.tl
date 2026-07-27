--- System logging.
--- Wraps unix.syslog() for writing to the system log.
local unix = require("cosmo.unix")

-- Priority levels

--- Emergency: system is unusable.
local LOG_EMERG < const > = unix.LOG_EMERG
--- Alert: action must be taken immediately.
local LOG_ALERT < const > = unix.LOG_ALERT
--- Critical: critical conditions.
local LOG_CRIT < const > = unix.LOG_CRIT
--- Error: error conditions.
local LOG_ERR < const > = unix.LOG_ERR
--- Warning: warning conditions.
local LOG_WARNING < const > = unix.LOG_WARNING
--- Notice: normal but significant condition.
local LOG_NOTICE < const > = unix.LOG_NOTICE
--- Informational: informational messages.
local LOG_INFO < const > = unix.LOG_INFO
--- Debug: debug-level messages.
local LOG_DEBUG < const > = unix.LOG_DEBUG

--- Write a message to the system log.
--- @param priority integer Log priority (LOG_EMERG through LOG_DEBUG)
--- @param message string The message to log
local function write(priority: integer, message: string)
  unix.syslog(priority, message)
end

--- Write an emergency message to the system log.
--- @param message string The message to log
local function emerg(message: string)
  unix.syslog(LOG_EMERG, message)
end

--- Write an alert message to the system log.
--- @param message string The message to log
local function alert(message: string)
  unix.syslog(LOG_ALERT, message)
end

--- Write a critical message to the system log.
--- @param message string The message to log
local function crit(message: string)
  unix.syslog(LOG_CRIT, message)
end

--- Write an error message to the system log.
--- @param message string The message to log
local function err(message: string)
  unix.syslog(LOG_ERR, message)
end

--- Write a warning message to the system log.
--- @param message string The message to log
local function warning(message: string)
  unix.syslog(LOG_WARNING, message)
end

--- Write a notice message to the system log.
--- @param message string The message to log
local function notice(message: string)
  unix.syslog(LOG_NOTICE, message)
end

--- Write an info message to the system log.
--- @param message string The message to log
local function info(message: string)
  unix.syslog(LOG_INFO, message)
end

--- Write a debug message to the system log.
--- @param message string The message to log
local function debug_msg(message: string)
  unix.syslog(LOG_DEBUG, message)
end

local record SyslogModule
  -- Writing
  write: function(priority: integer, message: string)
  emerg: function(message: string)
  alert: function(message: string)
  crit: function(message: string)
  err: function(message: string)
  warning: function(message: string)
  notice: function(message: string)
  info: function(message: string)
  debug: function(message: string)

  -- Priority constants
  LOG_EMERG: integer
  LOG_ALERT: integer
  LOG_CRIT: integer
  LOG_ERR: integer
  LOG_WARNING: integer
  LOG_NOTICE: integer
  LOG_INFO: integer
  LOG_DEBUG: integer
end

local M: SyslogModule = {
  -- Writing
  write = write,
  emerg = emerg,
  alert = alert,
  crit = crit,
  err = err,
  warning = warning,
  notice = notice,
  info = info,
  debug = debug_msg,

  -- Priority constants
  LOG_EMERG = LOG_EMERG,
  LOG_ALERT = LOG_ALERT,
  LOG_CRIT = LOG_CRIT,
  LOG_ERR = LOG_ERR,
  LOG_WARNING = LOG_WARNING,
  LOG_NOTICE = LOG_NOTICE,
  LOG_INFO = LOG_INFO,
  LOG_DEBUG = LOG_DEBUG,
}

return M
