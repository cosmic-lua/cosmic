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
  cio.barf(fs.join(dir, "00-base"), "COSMIC_ENVD_TEST_A=value_a\nCOSMIC_ENVD_TEST_B=value_b\n")

  env.unset("COSMIC_ENVD_TEST_A")
  env.unset("COSMIC_ENVD_TEST_B")

  local result = envd.load_dir(dir)
  assert(result.count == 2, "expected 2, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_A") == "value_a",
    "expected 'value_a', got '" .. tostring(env.get("COSMIC_ENVD_TEST_A")) .. "'")
  assert(env.get("COSMIC_ENVD_TEST_B") == "value_b",
    "expected 'value_b', got '" .. tostring(env.get("COSMIC_ENVD_TEST_B")) .. "'")

  env.unset("COSMIC_ENVD_TEST_A")
  env.unset("COSMIC_ENVD_TEST_B")
end
test_basic_load()

local function test_no_overwrite()
  local dir = make_envd("nooverwrite")
  cio.barf(fs.join(dir, "vars"), "COSMIC_ENVD_TEST_EXISTING=new_value\n")

  env.set("COSMIC_ENVD_TEST_EXISTING", "original_value")

  local result = envd.load_dir(dir)
  assert(result.count == 0, "expected 0, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_EXISTING") == "original_value",
    "should not overwrite existing var")

  env.unset("COSMIC_ENVD_TEST_EXISTING")
end
test_no_overwrite()

local function test_comments_skipped()
  local dir = make_envd("comments")
  cio.barf(fs.join(dir, "vars"), "# this is a comment\nCOSMIC_ENVD_TEST_C=works\n# another comment\n")

  env.unset("COSMIC_ENVD_TEST_C")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_C") == "works")

  env.unset("COSMIC_ENVD_TEST_C")
end
test_comments_skipped()

local function test_comment_only_file_sets_nothing()
  local dir = make_envd("commentonly")
  cio.barf(fs.join(dir, "README"), "# this file is documentation\n# no vars here\n")

  local result = envd.load_dir(dir)
  assert(result.count == 0, "comment-only file should set nothing, got " .. tostring(result.count))
end
test_comment_only_file_sets_nothing()

local function test_blank_lines_skipped()
  local dir = make_envd("blanks")
  cio.barf(fs.join(dir, "vars"), "\n\nCOSMIC_ENVD_TEST_D=val\n\n")

  env.unset("COSMIC_ENVD_TEST_D")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_D") == "val")

  env.unset("COSMIC_ENVD_TEST_D")
end
test_blank_lines_skipped()

local function test_lexical_order_concat()
  local dir = make_envd("order")
  -- 01-first sets a key, 02-second overrides it
  cio.barf(fs.join(dir, "01-first"), "COSMIC_ENVD_TEST_ORDER=first\n")
  cio.barf(fs.join(dir, "02-second"), "COSMIC_ENVD_TEST_ORDER=second\n")

  env.unset("COSMIC_ENVD_TEST_ORDER")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_ORDER") == "second",
    "later file should win, got '" .. tostring(env.get("COSMIC_ENVD_TEST_ORDER")) .. "'")

  env.unset("COSMIC_ENVD_TEST_ORDER")
end
test_lexical_order_concat()

local function test_value_with_equals()
  local dir = make_envd("equals")
  cio.barf(fs.join(dir, "vars"), "COSMIC_ENVD_TEST_EQ=foo=bar=baz\n")

  env.unset("COSMIC_ENVD_TEST_EQ")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_EQ") == "foo=bar=baz",
    "value after first = should be preserved, got '" .. tostring(env.get("COSMIC_ENVD_TEST_EQ")) .. "'")

  env.unset("COSMIC_ENVD_TEST_EQ")
end
test_value_with_equals()

local function test_empty_value()
  local dir = make_envd("emptyval")
  cio.barf(fs.join(dir, "vars"), "COSMIC_ENVD_TEST_EMPTY=\n")

  env.unset("COSMIC_ENVD_TEST_EMPTY")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_EMPTY") == "",
    "empty value should be set as empty string, got '" .. tostring(env.get("COSMIC_ENVD_TEST_EMPTY")) .. "'")

  env.unset("COSMIC_ENVD_TEST_EMPTY")
end
test_empty_value()

local function test_invalid_key_lines_skipped()
  local dir = make_envd("invalidkey")
  cio.barf(fs.join(dir, "vars"), "123BAD=skip\nhas-dash=skip\nCOSMIC_ENVD_TEST_OK=good\n")

  env.unset("COSMIC_ENVD_TEST_OK")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_OK") == "good")

  env.unset("COSMIC_ENVD_TEST_OK")
end
test_invalid_key_lines_skipped()

local function test_missing_dir()
  local result = envd.load_dir(fs.join(tmpdir, "nonexistent_dir_xyz"))
  assert(result.count == 0, "missing dir should return count=0")
end
test_missing_dir()

local function test_load_result_source()
  local dir = make_envd("source")
  local result = envd.load_dir(dir)
  assert(result.source == dir, "source should be the dir path")
end
test_load_result_source()

local function test_parse_basic()
  local vars = envd.parse("FOO=bar\nBAZ=qux\n")
  assert(vars["FOO"] == "bar", "expected 'bar', got '" .. tostring(vars["FOO"]) .. "'")
  assert(vars["BAZ"] == "qux", "expected 'qux', got '" .. tostring(vars["BAZ"]) .. "'")
end
test_parse_basic()

local function test_parse_comments_and_blanks()
  local vars = envd.parse("# comment\n\nKEY=val\n  # indented comment\n")
  local count = 0
  for _ in pairs(vars) do count = count + 1 end
  assert(count == 1, "expected 1 key, got " .. tostring(count))
  assert(vars["KEY"] == "val")
end
test_parse_comments_and_blanks()

local function test_multiple_files_merge()
  local dir = make_envd("merge")
  cio.barf(fs.join(dir, "01-a"), "COSMIC_ENVD_TEST_X=from_a\nCOSMIC_ENVD_TEST_Y=from_a\n")
  cio.barf(fs.join(dir, "02-b"), "COSMIC_ENVD_TEST_Y=from_b\nCOSMIC_ENVD_TEST_Z=from_b\n")

  env.unset("COSMIC_ENVD_TEST_X")
  env.unset("COSMIC_ENVD_TEST_Y")
  env.unset("COSMIC_ENVD_TEST_Z")

  local result = envd.load_dir(dir)
  assert(result.count == 3, "expected 3, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_X") == "from_a")
  assert(env.get("COSMIC_ENVD_TEST_Y") == "from_b",
    "later file should win for Y, got '" .. tostring(env.get("COSMIC_ENVD_TEST_Y")) .. "'")
  assert(env.get("COSMIC_ENVD_TEST_Z") == "from_b")

  env.unset("COSMIC_ENVD_TEST_X")
  env.unset("COSMIC_ENVD_TEST_Y")
  env.unset("COSMIC_ENVD_TEST_Z")
end
test_multiple_files_merge()

local function test_underscore_prefix_key()
  local dir = make_envd("underscore")
  cio.barf(fs.join(dir, "vars"), "_COSMIC_ENVD_TEST_UNDER=val\n")

  env.unset("_COSMIC_ENVD_TEST_UNDER")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("_COSMIC_ENVD_TEST_UNDER") == "val")

  env.unset("_COSMIC_ENVD_TEST_UNDER")
end
test_underscore_prefix_key()
