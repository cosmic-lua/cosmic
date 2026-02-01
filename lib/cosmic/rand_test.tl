#!/usr/bin/env cosmic
local rand = require("cosmic.rand")

local function test_bytes_returns_requested_length()
  local b = rand.bytes(16)
  assert(#b == 16, "bytes(16) should return 16 bytes, got " .. #b)
end
test_bytes_returns_requested_length()

local function test_bytes_different_each_call()
  local b1 = rand.bytes(32)
  local b2 = rand.bytes(32)
  assert(b1 ~= b2, "bytes should return different values each call")
end
test_bytes_different_each_call()

local function test_bytes_various_sizes()
  for _, size in ipairs({1, 8, 16, 32, 64, 128}) do
    local b = rand.bytes(size)
    assert(#b == size, "bytes(" .. size .. ") should return " .. size .. " bytes, got " .. #b)
  end
end
test_bytes_various_sizes()
