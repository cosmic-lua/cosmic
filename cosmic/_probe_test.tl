#!/usr/bin/env cosmic
-- Tests for cosmic._probe.is_present.

local probe = require("cosmic._probe")
local sandbox = require("cosmic.sandbox")

local function test_present_field_on_plain_table()
  local t = {name = "x"}
  assert(probe.is_present(t, "name") == true)
end

local function test_absent_field_on_plain_table()
  local t = {name = "x"}
  assert(probe.is_present(t, "missing") == false)
end

local function test_nil_valued_field_reads_as_absent()
  local t: {string: any} = {name = "x", other = nil}
  assert(probe.is_present(t, "other") == false)
end

-- Exercise the library call shape cosmic.sandbox and cosmic.quicksand.box
-- use: a genuinely typed record passed with no cast at the call site.
local function test_typed_record_present_field()
  local fs: sandbox.Fs = {ro = {"/etc"}}
  assert(probe.is_present(fs, "ro") == true)
end

local function test_typed_record_absent_field()
  local fs: sandbox.Fs = {ro = {"/etc"}}
  -- "deny" is not a field of Fs; probing for it is exactly why callers
  -- reach for this helper instead of a typed field read.
  assert(probe.is_present(fs, "deny") == false)
end
