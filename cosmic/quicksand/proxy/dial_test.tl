#!/usr/bin/env cosmic
local check = require("cosmic.check")
local dial = require("cosmic.quicksand.proxy.dial")
local ip = require("cosmic.ip")

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

-- Bounded lookups are the C binding's job (cosmo.ResolveIp's
-- timeout_ms), which pins the deadline behavior against a tarpitted
-- resolver upstream. At this layer: a deadline must not disturb the
-- literal fast path, and a seam resolver's value comes back directly
-- — no helper process, no pipe.
local function test_resolve_literal_with_deadline()
  local got, err = dial.resolve("8.8.8.8", 150, nil)
  assert(got == check.must(ip.parse("8.8.8.8")):int(),
    "literal must parse immediately under a deadline: " .. tostring(err))
end
test_resolve_literal_with_deadline()

local function test_resolve_seam_value_returned_directly()
  local got, err = dial.resolve("host.test", nil,
    function(_: string): integer, any
      return 1234
    end)
  assert(got == 1234, "seam value should return directly: " .. tostring(err))
end
test_resolve_seam_value_returned_directly()
