#!/usr/bin/env cosmic
local syslog = require("cosmic.syslog")

-- The wire protocol is RFC 5424's fixed numeric severities; the API is
-- the named Level enum (api-review-8). The mapping is internal, so the
-- falsifiable in-process contract is the enum's word set and that
-- write() never throws for any of them — delivery is unobservable here
-- (containers usually lack /dev/log), and a broken binding or a level
-- that failed to map to its integer would raise.
local function test_write_accepts_every_level_and_never_throws()
  local levels: {syslog.Level} = {
    "emergency", "alert", "critical", "error",
    "warning", "notice", "info", "debug",
  }
  for _, level in ipairs(levels) do
    local ok, thrown = pcall(function(): boolean
        syslog.write(level, "cosmic.syslog test: " .. level)
        return true
      end)
    assert(ok, "write(" .. level .. ") must not throw: " .. tostring(thrown))
  end
end
test_write_accepts_every_level_and_never_throws()
