#!/usr/bin/env cosmic
local check = require("cosmic.check")
local dial = require("cosmic.quicksand.proxy.dial")
local quicksand = require("cosmic.quicksand")
local ip = require("cosmic.ip")
local time = require("cosmic.time")

-- SSRF protection: dialing a private / reserved literal must be
-- refused after resolution, before any socket is opened. Covers
-- loopback, RFC1918, link-local (cloud metadata), CGNAT, and 0/8.
-- Pure address logic — no network access happens.
local function test_dial_blocks_private_targets()
  local targets: {string} = {
    "127.0.0.1",
    "10.1.2.3",
    "192.168.1.1",
    "172.16.0.1",
    "169.254.169.254",
    "100.64.0.1",
    "0.0.0.0",
  }
  for _, target in ipairs(targets) do
    local fd, err = dial.dial(target, 80, nil, nil)
    assert(fd == nil, "dial(" .. target .. ") should be refused")
    assert(err:find("SSRF", 1, true),
      "dial(" .. target .. ") should cite SSRF protection, got: "
      .. tostring(err))
  end
end
test_dial_blocks_private_targets()

local function test_resolve_literal_skips_resolver()
  local got, err = dial.resolve("8.8.8.8", nil,
    function(_: string): integer, any
      error("resolver must not run for literals")
    end)
  assert(got == check.must(ip.parse("8.8.8.8")):int(),
    "literal should parse directly: " .. tostring(err))
end
test_resolve_literal_skips_resolver()

local function test_resolve_error_propagates()
  local got, err = dial.resolve("host.test", nil,
    function(_: string): integer, any
      return nil, "boom"
    end)
  assert(got == nil and tostring(err):find("boom", 1, true),
    "resolver error should propagate, got: " .. tostring(err))
end
test_resolve_error_propagates()

-- The bounded path forks a helper and ships the result (or error)
-- back over a pipe.
local function test_resolve_bounded_roundtrip()
  local c = quicksand.capabilities()
  if not c.linux then return end
  local got, err = dial.resolve("host.test", 2000,
    function(_: string): integer, any
      return 1234
    end)
  assert(got == 1234, "value should cross the pipe: " .. tostring(err))
  got, err = dial.resolve("host.test", 2000,
    function(_: string): integer, any
      return nil, "nope"
    end)
  assert(got == nil and err == "nope",
    "error should cross the pipe, got: " .. tostring(err))
end
test_resolve_bounded_roundtrip()

-- A resolver that outlives its deadline is SIGKILL'd and reported as
-- a timeout, so a tarpitting DNS server can't wedge a worker.
local function test_resolve_timeout_kills_slow_resolver()
  local c = quicksand.capabilities()
  if not c.linux then return end
  local got, err = dial.resolve("host.test", 150,
    function(_: string): integer, any
      time.sleep(30)
      return 1
    end)
  assert(got == nil, "slow resolve should fail")
  assert(err == "resolve timeout", "expected timeout, got: " .. tostring(err))
end
test_resolve_timeout_kills_slow_resolver()
