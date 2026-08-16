#!/usr/bin/env cosmic
--- Tests for fs.octal: the base-8 parse and its 0-on-invalid contract.
local fs = require("cosmic.fs")
local check = require("cosmic.check")

local function test_octal_755()
  check.equal(fs.octal("755"), 493)
end
test_octal_755()

local function test_octal_zero()
  check.equal(fs.octal("0"), 0)
end
test_octal_zero()

local function test_octal_777()
  check.equal(fs.octal("777"), 511)
end
test_octal_777()

local function test_octal_empty_is_zero()
  check.equal(fs.octal(""), 0)
end
test_octal_empty_is_zero()

local function test_octal_digit_out_of_base_is_zero()
  check.equal(fs.octal("758"), 0)
end
test_octal_digit_out_of_base_is_zero()

local function test_octal_trailing_non_octal_is_zero()
  check.equal(fs.octal("08"), 0)
end
test_octal_trailing_non_octal_is_zero()
