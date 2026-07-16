#!/usr/bin/env cosmic
local syslog = require("cosmic.syslog")

-- Priority constants are the wire protocol: RFC 5424 fixes their numeric
-- values (issue #505 — pinned exactly, not just "defined and ordered").
local function test_constants_rfc5424_values()
  assert(syslog.LOG_EMERG == 0, "LOG_EMERG must be 0, got " .. tostring(syslog.LOG_EMERG))
  assert(syslog.LOG_ALERT == 1, "LOG_ALERT must be 1, got " .. tostring(syslog.LOG_ALERT))
  assert(syslog.LOG_CRIT == 2, "LOG_CRIT must be 2, got " .. tostring(syslog.LOG_CRIT))
  assert(syslog.LOG_ERR == 3, "LOG_ERR must be 3, got " .. tostring(syslog.LOG_ERR))
  assert(syslog.LOG_WARNING == 4, "LOG_WARNING must be 4, got " .. tostring(syslog.LOG_WARNING))
  assert(syslog.LOG_NOTICE == 5, "LOG_NOTICE must be 5, got " .. tostring(syslog.LOG_NOTICE))
  assert(syslog.LOG_INFO == 6, "LOG_INFO must be 6, got " .. tostring(syslog.LOG_INFO))
  assert(syslog.LOG_DEBUG == 7, "LOG_DEBUG must be 7, got " .. tostring(syslog.LOG_DEBUG))
end
test_constants_rfc5424_values()

-- Delivery is unobservable here (containers usually lack /dev/log), so
-- the only falsifiable in-process contract beyond the constant values is
-- "never throws": a broken binding or bad argument handling would raise.
local function test_write_smoke_never_throws()
  local calls: {function()} = {
    function() syslog.write(syslog.LOG_INFO, "cosmic.syslog test: write()") end,
    function() syslog.emerg("cosmic.syslog test: emerg()") end,
    function() syslog.alert("cosmic.syslog test: alert()") end,
    function() syslog.crit("cosmic.syslog test: crit()") end,
    function() syslog.err("cosmic.syslog test: err()") end,
    function() syslog.warning("cosmic.syslog test: warning()") end,
    function() syslog.notice("cosmic.syslog test: notice()") end,
    function() syslog.info("cosmic.syslog test: info()") end,
    function() syslog.debug("cosmic.syslog test: debug()") end,
  }
  for i, call in ipairs(calls) do
    local ok, thrown = pcall(call as function(): any)
    assert(ok, "syslog call " .. i .. " must not throw: " .. tostring(thrown))
  end
end
test_write_smoke_never_throws()

print("All syslog tests passed")
