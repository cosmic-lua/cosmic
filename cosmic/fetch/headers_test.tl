#!/usr/bin/env cosmic
-- Header CRLF / injection validation. HTTP headers are
-- CRLF-delimited, so a CR or LF embedded in a header name or value smuggles
-- additional header lines (or a body) past cosmo.Fetch. fetch rejects such
-- headers before the request is issued. These tests need no network: the
-- request is rejected during validation, before any connection is attempted.
local fetch = require("cosmic.fetch")

-- A dead loopback port: any request that passes validation fails to connect,
-- so a header-validation error is unambiguously from validation, not the wire.
local dead = "http://127.0.0.1:1"

local function test_rejects_crlf_in_header_value()
  local result = fetch.fetch(dead, {headers = {["X-Test"] = "value\r\nX-Injected: evil"}})
  assert(result.ok == false, "result.ok should be false for CRLF in header value")
  assert(result.error ~= nil and result.error:find("X%-Test") ~= nil,
    "error should name the offending header, got: " .. tostring(result.error))
  assert(result.error:find("CR, LF, or NUL") ~= nil,
    "error should explain the forbidden bytes, got: " .. tostring(result.error))
end
test_rejects_crlf_in_header_value()

local function test_rejects_lf_only_in_header_value()
  local result = fetch.fetch(dead, {headers = {["X-Test"] = "a\nb"}})
  assert(result.ok == false, "a bare LF in a header value must be rejected")
end
test_rejects_lf_only_in_header_value()

local function test_rejects_cr_only_in_header_value()
  local result = fetch.fetch(dead, {headers = {["X-Test"] = "a\rb"}})
  assert(result.ok == false, "a bare CR in a header value must be rejected")
end
test_rejects_cr_only_in_header_value()

local function test_rejects_crlf_in_header_name()
  local result = fetch.fetch(dead, {headers = {["X-Bad\r\nX-Injected"] = "value"}})
  assert(result.ok == false, "result.ok should be false for CRLF in header name")
  assert(result.error ~= nil and result.error:find("header name") ~= nil,
    "error should mention the header name, got: " .. tostring(result.error))
end
test_rejects_crlf_in_header_name()

local function test_rejects_nul_in_header_value()
  local result = fetch.fetch(dead, {headers = {["X-Test"] = "a\0b"}})
  assert(result.ok == false, "a NUL in a header value must be rejected")
  assert(result.error ~= nil and result.error:find("CR, LF, or NUL") ~= nil,
    "error should explain the forbidden bytes, got: " .. tostring(result.error))
end
test_rejects_nul_in_header_value()

local function test_rejects_empty_header_name()
  local result = fetch.fetch(dead, {headers = {[""] = "value"}})
  assert(result.ok == false, "an empty header name must be rejected")
  assert(result.error ~= nil and result.error:find("empty") ~= nil,
    "error should mention the empty name, got: " .. tostring(result.error))
end
test_rejects_empty_header_name()

local function test_allows_clean_headers()
  -- Well-formed headers must pass validation; the connection to the dead
  -- port then fails, but never with a header-validation error.
  local result = fetch.fetch(dead, {
      headers = {["X-Test"] = "clean-value", ["Accept"] = "application/json"},
    })
  if not result.ok then
    assert(result.error:find("header") == nil,
      "clean headers must pass validation, got: " .. tostring(result.error))
  end
end
test_allows_clean_headers()

local function test_stream_rejects_crlf_in_header_value()
  local result = fetch.stream(dead, {headers = {["X-Test"] = "value\r\nX-Injected: evil"}})
  assert(result.ok == false, "stream should reject CRLF in a header value")
  assert(result.error ~= nil and result.error:find("CR, LF, or NUL") ~= nil,
    "stream error should explain the forbidden bytes, got: " .. tostring(result.error))
end
test_stream_rejects_crlf_in_header_value()

local function test_stream_rejects_crlf_in_header_name()
  local result = fetch.stream(dead, {headers = {["X-Bad\r\nX-Injected"] = "value"}})
  assert(result.ok == false, "stream should reject CRLF in a header name")
  assert(result.error ~= nil and result.error:find("header name") ~= nil,
    "stream error should mention the header name, got: " .. tostring(result.error))
end
test_stream_rejects_crlf_in_header_name()
