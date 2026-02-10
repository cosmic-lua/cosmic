#!/usr/bin/env cosmic
local syslog = require("cosmic.syslog")

-- Test that priority constants are defined
local function test_constants()
  assert(syslog.LOG_EMERG ~= nil, "LOG_EMERG should be defined")
  assert(syslog.LOG_ALERT ~= nil, "LOG_ALERT should be defined")
  assert(syslog.LOG_CRIT ~= nil, "LOG_CRIT should be defined")
  assert(syslog.LOG_ERR ~= nil, "LOG_ERR should be defined")
  assert(syslog.LOG_WARNING ~= nil, "LOG_WARNING should be defined")
  assert(syslog.LOG_NOTICE ~= nil, "LOG_NOTICE should be defined")
  assert(syslog.LOG_INFO ~= nil, "LOG_INFO should be defined")
  assert(syslog.LOG_DEBUG ~= nil, "LOG_DEBUG should be defined")

  -- Check that priorities have expected ordering (lower = more severe)
  assert(syslog.LOG_EMERG < syslog.LOG_DEBUG, "LOG_EMERG should be lower than LOG_DEBUG")
  assert(syslog.LOG_ERR < syslog.LOG_WARNING, "LOG_ERR should be lower than LOG_WARNING")
  assert(syslog.LOG_WARNING < syslog.LOG_INFO, "LOG_WARNING should be lower than LOG_INFO")
end
test_constants()

-- Test that functions exist and are callable
-- Note: actual syslog delivery may fail in containerized environments
-- where /dev/log doesn't exist, but the functions should not error
local function test_write_functions_exist()
  assert(type(syslog.write) == "function", "write should be a function")
  assert(type(syslog.emerg) == "function", "emerg should be a function")
  assert(type(syslog.alert) == "function", "alert should be a function")
  assert(type(syslog.crit) == "function", "crit should be a function")
  assert(type(syslog.err) == "function", "err should be a function")
  assert(type(syslog.warning) == "function", "warning should be a function")
  assert(type(syslog.notice) == "function", "notice should be a function")
  assert(type(syslog.info) == "function", "info should be a function")
  assert(type(syslog.debug) == "function", "debug should be a function")
end
test_write_functions_exist()

-- Test calling every priority-level convenience function completes without error
local function test_write_calls()
  syslog.write(syslog.LOG_INFO, "cosmic.syslog test: write()")
  syslog.emerg("cosmic.syslog test: emerg()")
  syslog.alert("cosmic.syslog test: alert()")
  syslog.crit("cosmic.syslog test: crit()")
  syslog.err("cosmic.syslog test: err()")
  syslog.warning("cosmic.syslog test: warning()")
  syslog.notice("cosmic.syslog test: notice()")
  syslog.info("cosmic.syslog test: info()")
  syslog.debug("cosmic.syslog test: debug()")
end
test_write_calls()

-- Test that write dispatches to each priority constant without error
local function test_write_all_priorities()
  local priorities = {
    syslog.LOG_EMERG,
    syslog.LOG_ALERT,
    syslog.LOG_CRIT,
    syslog.LOG_ERR,
    syslog.LOG_WARNING,
    syslog.LOG_NOTICE,
    syslog.LOG_INFO,
    syslog.LOG_DEBUG,
  }
  for _, prio in ipairs(priorities) do
    assert(type(prio) == "number", "priority should be a number")
    syslog.write(prio, "test priority " .. tostring(prio))
  end
end
test_write_all_priorities()

print("All syslog tests passed")
