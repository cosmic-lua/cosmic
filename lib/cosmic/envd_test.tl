#!/usr/bin/env cosmic
local envd = require("cosmic.envd")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local cio = require("cosmic.io")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp/envd_test"
fs.makedirs(tmpdir)

local function make_envd(name: string): string
  local dir = fs.join(tmpdir, name)
  fs.makedirs(dir)
  return dir
end

local function test_basic_load()
  local dir = make_envd("basic")
  cio.barf(fs.join(dir, "COSMIC_ENVD_TEST_A"), "value_a")
  cio.barf(fs.join(dir, "COSMIC_ENVD_TEST_B"), "value_b")

  -- ensure not already set
  env.unset("COSMIC_ENVD_TEST_A")
  env.unset("COSMIC_ENVD_TEST_B")

  local result = envd.load_dir(dir)
  assert(result.count == 2, "expected 2, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_A") == "value_a",
    "expected 'value_a', got '" .. tostring(env.get("COSMIC_ENVD_TEST_A")) .. "'")
  assert(env.get("COSMIC_ENVD_TEST_B") == "value_b",
    "expected 'value_b', got '" .. tostring(env.get("COSMIC_ENVD_TEST_B")) .. "'")

  -- cleanup
  env.unset("COSMIC_ENVD_TEST_A")
  env.unset("COSMIC_ENVD_TEST_B")
end
test_basic_load()

local function test_no_overwrite()
  local dir = make_envd("nooverwrite")
  cio.barf(fs.join(dir, "COSMIC_ENVD_TEST_EXISTING"), "new_value")

  -- set existing value first
  env.set("COSMIC_ENVD_TEST_EXISTING", "original_value")

  local result = envd.load_dir(dir)
  assert(result.count == 0, "expected 0, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_EXISTING") == "original_value",
    "should not overwrite existing var")

  env.unset("COSMIC_ENVD_TEST_EXISTING")
end
test_no_overwrite()

local function test_dotfiles_skipped()
  local dir = make_envd("dotfiles")
  cio.barf(fs.join(dir, ".hidden"), "should_skip")
  cio.barf(fs.join(dir, "COSMIC_ENVD_TEST_VISIBLE"), "visible")

  env.unset("COSMIC_ENVD_TEST_VISIBLE")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get(".hidden") == nil, "dotfile should not be set")
  assert(env.get("COSMIC_ENVD_TEST_VISIBLE") == "visible")

  env.unset("COSMIC_ENVD_TEST_VISIBLE")
end
test_dotfiles_skipped()

local function test_invalid_names_skipped()
  local dir = make_envd("invalid")
  cio.barf(fs.join(dir, "123BAD"), "skip")
  cio.barf(fs.join(dir, "has-dash"), "skip")
  cio.barf(fs.join(dir, "has space"), "skip")
  cio.barf(fs.join(dir, "COSMIC_ENVD_TEST_GOOD"), "good")

  env.unset("COSMIC_ENVD_TEST_GOOD")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_GOOD") == "good")

  env.unset("COSMIC_ENVD_TEST_GOOD")
end
test_invalid_names_skipped()

local function test_empty_files_skipped()
  local dir = make_envd("empty")
  cio.barf(fs.join(dir, "COSMIC_ENVD_TEST_EMPTY1"), "")
  cio.barf(fs.join(dir, "COSMIC_ENVD_TEST_EMPTY2"), "   \n\t  ")
  cio.barf(fs.join(dir, "COSMIC_ENVD_TEST_NOTEMPTY"), "value")

  env.unset("COSMIC_ENVD_TEST_EMPTY1")
  env.unset("COSMIC_ENVD_TEST_EMPTY2")
  env.unset("COSMIC_ENVD_TEST_NOTEMPTY")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_EMPTY1") == nil, "empty file should not set var")
  assert(env.get("COSMIC_ENVD_TEST_EMPTY2") == nil, "whitespace-only file should not set var")
  assert(env.get("COSMIC_ENVD_TEST_NOTEMPTY") == "value")

  env.unset("COSMIC_ENVD_TEST_NOTEMPTY")
end
test_empty_files_skipped()

local function test_missing_dir()
  local result = envd.load_dir(fs.join(tmpdir, "nonexistent_dir_xyz"))
  assert(result.count == 0, "missing dir should return count=0")
end
test_missing_dir()

local function test_multiline_content()
  local dir = make_envd("multiline")
  cio.barf(fs.join(dir, "COSMIC_ENVD_TEST_MULTI"), "line1\nline2\nline3")

  env.unset("COSMIC_ENVD_TEST_MULTI")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_MULTI") == "line1\nline2\nline3",
    "multiline content should be preserved")

  env.unset("COSMIC_ENVD_TEST_MULTI")
end
test_multiline_content()

local function test_trailing_newline_trimmed()
  local dir = make_envd("trailing")
  cio.barf(fs.join(dir, "COSMIC_ENVD_TEST_TRIM"), "myvalue\n")

  env.unset("COSMIC_ENVD_TEST_TRIM")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_TRIM") == "myvalue",
    "trailing newline should be trimmed, got '" .. tostring(env.get("COSMIC_ENVD_TEST_TRIM")) .. "'")

  env.unset("COSMIC_ENVD_TEST_TRIM")
end
test_trailing_newline_trimmed()

local function test_underscore_prefix()
  local dir = make_envd("underscore")
  cio.barf(fs.join(dir, "_COSMIC_ENVD_TEST_UNDER"), "val")

  env.unset("_COSMIC_ENVD_TEST_UNDER")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("_COSMIC_ENVD_TEST_UNDER") == "val")

  env.unset("_COSMIC_ENVD_TEST_UNDER")
end
test_underscore_prefix()

local function test_load_result_source()
  local dir = make_envd("source")
  local result = envd.load_dir(dir)
  assert(result.source == dir, "source should be the dir path")
end
test_load_result_source()
