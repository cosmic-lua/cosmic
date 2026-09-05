#!/usr/bin/env cosmic
--- Examples for cosmic.ksuid.

--- A fresh id, and the creation time it carries back out.
local function Example_new_and_time_of()
  local check = require("cosmic.check")
  local ksuid = require("cosmic.ksuid")
  local id = ksuid.new()
  print(#id)
  print(ksuid.is_id(id))
  local seconds = check.must(ksuid.time_of(id))
  print(seconds >= 1400000000)
  -- Output:
  -- 27
  -- true
  -- true
end

--- Two ids minted a second apart sort in creation order as plain
--- strings — no separate timestamp field needed for that guarantee.
local function Example_sorts_lexicographically()
  local check = require("cosmic.check")
  local ksuid = require("cosmic.ksuid")
  local older = check.must(ksuid.encode(1700000000, ("\255"):rep(16)))
  local newer = check.must(ksuid.encode(1700000001, ("\0"):rep(16)))
  print(older < newer)
  -- Output:
  -- true
end

-- Suppress unused warnings for examples
local _ = {Example_new_and_time_of, Example_sorts_lexicographically}
