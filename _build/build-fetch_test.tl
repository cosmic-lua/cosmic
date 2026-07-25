#!/usr/bin/env cosmic

local fetch = require("_build.build-fetch")

-- validate_archive_name tests

local function test_validate_archive_name_ok_zip()
  local ok, err = fetch.validate_archive_name("cosmos.zip")
  assert(ok, "expected ok for cosmos.zip, got: " .. tostring(err))
end
test_validate_archive_name_ok_zip()

local function test_validate_archive_name_ok_targz()
  local ok, err = fetch.validate_archive_name("v0.24.8.tar.gz")
  assert(ok, "expected ok for v0.24.8.tar.gz, got: " .. tostring(err))
end
test_validate_archive_name_ok_targz()

local function test_validate_archive_name_ok_hex()
  local ok, err = fetch.validate_archive_name(
    "0137f934c9946cfe4134a0217ac5cacf9dd49332.tar.gz"
  )
  assert(ok, "expected ok for hex-prefixed archive name, got: " .. tostring(err))
end
test_validate_archive_name_ok_hex()

local function test_validate_archive_name_ok_hyphen()
  local ok, err = fetch.validate_archive_name("my-archive-1.0.tar.gz")
  assert(ok, "expected ok for archive with hyphens, got: " .. tostring(err))
end
test_validate_archive_name_ok_hyphen()

local function test_validate_archive_name_empty()
  local ok, err = fetch.validate_archive_name("")
  assert(not ok, "expected failure for empty name")
  assert(err ~= nil, "expected error message for empty name")
end
test_validate_archive_name_empty()

local function test_validate_archive_name_dot()
  local ok, err = fetch.validate_archive_name(".")
  assert(not ok, "expected failure for '.'")
  assert(err ~= nil, "expected error message for '.'")
end
test_validate_archive_name_dot()

local function test_validate_archive_name_dotdot()
  local ok, err = fetch.validate_archive_name("..")
  assert(not ok, "expected failure for '..'")
  assert(err ~= nil, "expected error message for '..'")
end
test_validate_archive_name_dotdot()

local function test_validate_archive_name_slash()
  local ok, err = fetch.validate_archive_name("foo/bar.tar.gz")
  assert(not ok, "expected failure for name containing '/'")
  assert(err ~= nil, "expected error message for slash in name")
end
test_validate_archive_name_slash()

local function test_validate_archive_name_space()
  local ok, err = fetch.validate_archive_name("my archive.tar.gz")
  assert(not ok, "expected failure for name containing space")
  assert(err ~= nil, "expected error message for space in name")
end
test_validate_archive_name_space()
