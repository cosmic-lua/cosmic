#!/usr/bin/env cosmic
-- The ksuid codec is pure arithmetic: encode and time_of are pinned
-- against fixed inputs, and the property the design leans on — that
-- LEXICOGRAPHIC order is CREATION order — is asserted directly, worst
-- case against worst case.

local check = require("cosmic.check")
local ksuid = require("_work.ksuid")

local ZEROS = ("\0"):rep(16)
local ONES = ("\255"):rep(16)

local function test_encode_shape()
  local id = check.must(ksuid.encode(1700000000, ZEROS))
  assert(#id == ksuid.LEN, "length: " .. #id)
  assert(id:match("^[%w]+$"), "charset: " .. id)
  assert(ksuid.is_id(id), "well-formed")
end
test_encode_shape()

local function test_time_round_trips()
  for _, seconds in ipairs({1400000000, 1700000042, 2000000000}) do
    local id = check.must(ksuid.encode(seconds, ZEROS))
    local back = check.must(ksuid.time_of(id))
    assert(back == seconds, ("want %d, got %d"):format(seconds, back))
    local noisy = check.must(ksuid.encode(seconds, ONES))
    local nback = check.must(ksuid.time_of(noisy))
    assert(nback == seconds, "payload must not disturb the timestamp")
  end
end
test_time_round_trips()

local function test_lexicographic_order_is_time_order()
  -- Worst case: the older id with the largest payload must still sort
  -- before the newer id with the smallest.
  local older = check.must(ksuid.encode(1700000000, ONES))
  local newer = check.must(ksuid.encode(1700000001, ZEROS))
  assert(older < newer, older .. " must sort before " .. newer)
end
test_lexicographic_order_is_time_order()

local function test_domain_edges()
  local early, err = ksuid.encode(1399999999, ZEROS)
  assert(early == nil and err:find("range", 1, true), "before the epoch")
  local short, serr = ksuid.encode(1700000000, "short")
  assert(short == nil and serr:find("16 bytes", 1, true), "payload size")
  assert(not ksuid.is_id("abc"), "short id refused")
  assert(not ksuid.is_id(("!"):rep(27)), "bad charset refused")
end
test_domain_edges()

local function test_new_is_fresh_and_current()
  local a = ksuid.new()
  local b = ksuid.new()
  assert(ksuid.is_id(a) and ksuid.is_id(b), "well-formed")
  assert(a ~= b, "two ids never collide")
  local seconds = check.must(ksuid.time_of(a))
  assert(seconds > 1700000000, "carries a current timestamp")
end
test_new_is_fresh_and_current()
