-- DO NOT MERGE: a tripwire that fails only on the alpine-x86_64 leg,
-- which only a merge-queue (or main) run has, to exercise the queue's
-- cancel job and `cosmic test --bail` on a real failure.
local Test = require("cosmic.test")
local Fs = require("cosmic.fs")
local Clock = require("cosmic.clock")

Test.policy{ grants = { { path = "/etc/os-release", letters = "r" } } }

local function test_a_tripwire_the_alpine_leg_trips()
  local release = Fs.read("/etc/os-release")
  assert(release == nil or not release:find("ID=alpine", 1, true), "tripwire: the alpine leg, as meant")
end

local function test_b_holds_a_slot()
  assert(Clock.sleep_ns(Clock.ms(3000)))
end

local function test_c_holds_a_slot()
  assert(Clock.sleep_ns(Clock.ms(3000)))
end

local function test_d_holds_a_slot()
  assert(Clock.sleep_ns(Clock.ms(3000)))
end

local function test_e_after_the_failure()
  assert(true)
end

local function test_f_after_the_failure()
  assert(true)
end

local function test_g_after_the_failure()
  assert(true)
end
