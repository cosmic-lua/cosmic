#!/usr/bin/env cosmic
local check = require("cosmic.check")
local envd = require("cosmic.envd")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp/envd_test"
fs.make_dirs(tmpdir)

local function make_envd(name: string): string
  local dir = fs.join(tmpdir, name)
  fs.make_dirs(dir)
  return dir
end

local function test_basic_load()
  local dir = make_envd("basic")
  fs.write(fs.join(dir, "00-base"), "COSMIC_ENVD_TEST_A=value_a\nCOSMIC_ENVD_TEST_B=value_b\n")

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
  fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_TEST_EXISTING=new_value\n")

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
  fs.write(fs.join(dir, "vars"), "# this is a comment\nCOSMIC_ENVD_TEST_C=works\n# another comment\n")

  env.unset("COSMIC_ENVD_TEST_C")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_C") == "works")

  env.unset("COSMIC_ENVD_TEST_C")
end
test_comments_skipped()

local function test_comment_only_file_sets_nothing()
  local dir = make_envd("commentonly")
  fs.write(fs.join(dir, "README"), "# this file is documentation\n# no vars here\n")

  local result = envd.load_dir(dir)
  assert(result.count == 0, "comment-only file should set nothing, got " .. tostring(result.count))
end
test_comment_only_file_sets_nothing()

local function test_blank_lines_skipped()
  local dir = make_envd("blanks")
  fs.write(fs.join(dir, "vars"), "\n\nCOSMIC_ENVD_TEST_D=val\n\n")

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
  fs.write(fs.join(dir, "01-first"), "COSMIC_ENVD_TEST_ORDER=first\n")
  fs.write(fs.join(dir, "02-second"), "COSMIC_ENVD_TEST_ORDER=second\n")

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
  fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_TEST_EQ=foo=bar=baz\n")

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
  fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_TEST_EMPTY=\n")

  env.unset("COSMIC_ENVD_TEST_EMPTY")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_EMPTY") == "",
    "empty value should be set string, got '" .. tostring(env.get("COSMIC_ENVD_TEST_EMPTY")) .. "'")

  env.unset("COSMIC_ENVD_TEST_EMPTY")
end
test_empty_value()

local function test_invalid_key_lines_skipped()
  local dir = make_envd("invalidkey")
  fs.write(fs.join(dir, "vars"), "123BAD=skip\nhas-dash=skip\nCOSMIC_ENVD_TEST_OK=good\n")

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
  fs.write(fs.join(dir, "01-a"), "COSMIC_ENVD_TEST_X=from_a\nCOSMIC_ENVD_TEST_Y=from_a\n")
  fs.write(fs.join(dir, "02-b"), "COSMIC_ENVD_TEST_Y=from_b\nCOSMIC_ENVD_TEST_Z=from_b\n")

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
  fs.write(fs.join(dir, "vars"), "_COSMIC_ENVD_TEST_UNDER=val\n")

  env.unset("_COSMIC_ENVD_TEST_UNDER")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("_COSMIC_ENVD_TEST_UNDER") == "val")

  env.unset("_COSMIC_ENVD_TEST_UNDER")
end
test_underscore_prefix_key()

-- variable expansion tests

local function test_expand_plain_var()
  local vars = envd.parse("BASE=/opt\nPATH_VAR=${BASE}/bin\n")
  assert(vars["BASE"] == "/opt", "expected '/opt', got '" .. tostring(vars["BASE"]) .. "'")
  assert(vars["PATH_VAR"] == "/opt/bin", "expected '/opt/bin', got '" .. tostring(vars["PATH_VAR"]) .. "'")
end
test_expand_plain_var()

local function test_expand_undefined_var()
  env.unset("COSMIC_ENVD_TEST_UNDEF")
  local vars = envd.parse("VAL=${COSMIC_ENVD_TEST_UNDEF}rest\n")
  assert(vars["VAL"] == "rest", "undefined should expand to empty, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_undefined_var()

local function test_expand_from_env()
  env.set("COSMIC_ENVD_TEST_FROMENV", "envval")
  local vars = envd.parse("VAL=${COSMIC_ENVD_TEST_FROMENV}\n")
  assert(vars["VAL"] == "envval", "expected 'envval', got '" .. tostring(vars["VAL"]) .. "'")
  env.unset("COSMIC_ENVD_TEST_FROMENV")
end
test_expand_from_env()

local function test_expand_default_unset()
  env.unset("COSMIC_ENVD_TEST_NOSUCH")
  local vars = envd.parse("VAL=${COSMIC_ENVD_TEST_NOSUCH:-fallback}\n")
  assert(vars["VAL"] == "fallback", "expected 'fallback', got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_default_unset()

local function test_expand_default_empty()
  local vars = envd.parse("EMPTY=\nVAL=${EMPTY:-fallback}\n")
  assert(vars["VAL"] == "fallback", ":-default should trigger on empty, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_default_empty()

local function test_expand_default_set()
  local vars = envd.parse("BASE=real\nVAL=${BASE:-fallback}\n")
  assert(vars["VAL"] == "real", ":-default should not trigger when set, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_default_set()

local function test_expand_dash_default_unset()
  env.unset("COSMIC_ENVD_TEST_NOSUCH2")
  local vars = envd.parse("VAL=${COSMIC_ENVD_TEST_NOSUCH2-fallback}\n")
  assert(vars["VAL"] == "fallback", "expected 'fallback', got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_dash_default_unset()

local function test_expand_dash_default_empty()
  local vars = envd.parse("EMPTY=\nVAL=${EMPTY-fallback}\n")
  assert(vars["VAL"] == "", "-default should NOT trigger on empty, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_dash_default_empty()

local function test_expand_multiple_refs()
  local vars = envd.parse("HOST=localhost\nPORT=8080\nURL=http://${HOST}:${PORT}/api\n")
  assert(vars["URL"] == "http://localhost:8080/api",
    "expected 'http://localhost:8080/api', got '" .. tostring(vars["URL"]) .. "'")
end
test_expand_multiple_refs()

local function test_expand_with_ctx()
  local ctx: {string: string} = {PRIOR = "fromctx"}
  local vars = envd.parse("VAL=${PRIOR}/more\n", ctx)
  assert(vars["VAL"] == "fromctx/more", "expected 'fromctx/more', got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_with_ctx()

local function test_expand_across_files()
  local dir = make_envd("expand_across")
  fs.write(fs.join(dir, "01-base"), "COSMIC_ENVD_TEST_BASE=/opt\n")
  fs.write(fs.join(dir, "02-derived"), "COSMIC_ENVD_TEST_DERIVED=${COSMIC_ENVD_TEST_BASE}/bin\n")

  env.unset("COSMIC_ENVD_TEST_BASE")
  env.unset("COSMIC_ENVD_TEST_DERIVED")

  local result = envd.load_dir(dir)
  assert(result.count == 2, "expected 2, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_BASE") == "/opt")
  assert(env.get("COSMIC_ENVD_TEST_DERIVED") == "/opt/bin",
    "expected '/opt/bin', got '" .. tostring(env.get("COSMIC_ENVD_TEST_DERIVED")) .. "'")

  env.unset("COSMIC_ENVD_TEST_BASE")
  env.unset("COSMIC_ENVD_TEST_DERIVED")
end
test_expand_across_files()

local function test_expand_no_expansion_without_braces()
  local vars = envd.parse("BASE=val\nVAL=$BASE/rest\n")
  assert(vars["VAL"] == "$BASE/rest",
    "$VAR without braces should not expand, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_no_expansion_without_braces()

local function test_expand_malformed_expr()
  local vars = envd.parse("VAL=${123BAD}\n")
  assert(vars["VAL"] == "${123BAD}",
    "malformed should be left as-is, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_malformed_expr()

local function test_expand_nested_default()
  local vars = envd.parse("VAL=${NOSUCH:-a=b}\n")
  assert(vars["VAL"] == "a=b",
    "default can contain =, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_nested_default()

local function test_expand_function_directly()
  local ctx: {string: string} = {FOO = "bar"}
  local result = envd.expand("hello ${FOO} world", ctx)
  assert(result == "hello bar world", "expected 'hello bar world', got '" .. result .. "'")
end
test_expand_function_directly()

-- FIX 3a: parse must strip trailing \r from CRLF dotenv files.
local function test_parse_crlf_no_trailing_cr()
  -- Simulate a CRLF dotenv file (e.g. produced on Windows or by some editors).
  local crlf_content = "COSMIC_ENVD_CRLF_A=hello\r\nCOSMIC_ENVD_CRLF_B=world\r\n"
  local vars = envd.parse(crlf_content)
  assert(vars["COSMIC_ENVD_CRLF_A"] == "hello",
    "CRLF: expected 'hello' (len 5), got len=" .. tostring(#tostring(vars["COSMIC_ENVD_CRLF_A"] or "")))
  assert(vars["COSMIC_ENVD_CRLF_B"] == "world",
    "CRLF: expected 'world' (len 5), got len=" .. tostring(#tostring(vars["COSMIC_ENVD_CRLF_B"] or "")))
end
test_parse_crlf_no_trailing_cr()

-- FIX 3a: load_dir must also strip trailing \r when reading from a real CRLF file.
local function test_load_dir_crlf_file()
  local dir = make_envd("crlf_dir")
  -- Write a CRLF-encoded dotenv file using raw bytes
  local crlf_content = "COSMIC_ENVD_CRLF_C=crvalue\r\n"
  fs.write(fs.join(dir, "vars"), crlf_content)

  env.unset("COSMIC_ENVD_CRLF_C")
  local result = envd.load_dir(dir)
  assert(result.count == 1, "expected 1 var from CRLF file, got " .. tostring(result.count))
  local val = env.get("COSMIC_ENVD_CRLF_C")
  assert(val == "crvalue",
    "CRLF file: expected 'crvalue', got '" .. tostring(val) .. "'")
  env.unset("COSMIC_ENVD_CRLF_C")
end
test_load_dir_crlf_file()

-- FIX 3b: COSMIC_DEBUG='' (empty string) must NOT enable debug mode.
-- Only a non-empty COSMIC_DEBUG value should enable debug output.
-- Rewritten for issue capture the debug channel (envd writes via
-- io.stderr) instead of asserting a count that passes either way.
local function load_dir_capturing_stderr(dir: string): envd.LoadResult, string
  local capture_path = fs.join(tmpdir, "envd_debug_capture")
  local real_stderr = io.stderr
  io.stderr = assert(io.open(capture_path, "w"))
  local result = envd.load_dir(dir)
  io.stderr:close()
  io.stderr = real_stderr
  return result, (check.must(fs.read(capture_path)))
end

local function test_cosmic_debug_empty_not_enabled()
  local dir = make_envd("debug_empty")
  fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_DEBUG_TEST=value\n")
  env.unset("COSMIC_ENVD_DEBUG_TEST")

  env.set("COSMIC_DEBUG", "")
  local result, captured = load_dir_capturing_stderr(dir)
  env.unset("COSMIC_DEBUG")

  assert(result.count == 1, "expected 1 with empty COSMIC_DEBUG, got " .. tostring(result.count))
  assert(not captured:match("%[envd%]"),
    "COSMIC_DEBUG='' must not emit debug output, got: " .. captured)
  env.unset("COSMIC_ENVD_DEBUG_TEST")
end
test_cosmic_debug_empty_not_enabled()

local function test_cosmic_debug_nonempty_emits_debug()
  local dir = make_envd("debug_on")
  fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_DEBUG_TEST2=value\n")
  env.unset("COSMIC_ENVD_DEBUG_TEST2")

  env.set("COSMIC_DEBUG", "1")
  local result, captured = load_dir_capturing_stderr(dir)
  env.unset("COSMIC_DEBUG")

  assert(result.count == 1, "expected 1 with COSMIC_DEBUG=1, got " .. tostring(result.count))
  assert(captured:match("%[envd%] set COSMIC_ENVD_DEBUG_TEST2"),
    "COSMIC_DEBUG=1 must log each set variable, got: " .. captured)
  env.unset("COSMIC_ENVD_DEBUG_TEST2")
end
test_cosmic_debug_nonempty_emits_debug()

-- FIX 12: the "[envd] set" debug line printed even when env.set failed.
-- Monkey-patch env.set (a plain module table, like childio.read_retry
-- elsewhere) so it fails, and confirm the debug line is now gated on
-- success — the failure still lands in result.errors, just silently
-- under COSMIC_DEBUG.
local function test_debug_set_not_logged_on_failure()
  local dir = make_envd("debug_set_fails")
  fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_DEBUG_FAIL=value\n")
  env.unset("COSMIC_ENVD_DEBUG_FAIL")
  env.set("COSMIC_DEBUG", "1")

  local real_set = env.set
  env.set = function(_name: string, _value: string, _overwrite?: boolean): boolean, string
    return false, "setenv: EINVAL: simulated failure"
  end
  local result, captured = load_dir_capturing_stderr(dir)
  env.set = real_set
  env.unset("COSMIC_DEBUG")

  assert(result.count == 0, "expected 0 vars set when env.set fails, got " .. tostring(result.count))
  assert(#result.errors == 1, "expected 1 error recorded, got " .. tostring(#result.errors))
  assert(not captured:match("%[envd%] set"),
    "must not log '[envd] set' when env.set failed, got: " .. captured)
end
test_debug_set_not_logged_on_failure()

-- LoadResult.errors (review item 39): per-file read failures
-- are collected instead of being visible only under COSMIC_DEBUG.

local function test_errors_empty_on_clean_load()
  local dir = make_envd("errclean")
  fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_ERR_TEST_A=1\n")
  env.unset("COSMIC_ENVD_ERR_TEST_A")

  local result = envd.load_dir(dir)
  assert(result.errors ~= nil, "LoadResult should carry an errors list")
  assert(#result.errors == 0, "clean load should collect no errors, got: "
    .. tostring(result.errors[1]))
  env.unset("COSMIC_ENVD_ERR_TEST_A")
end
test_errors_empty_on_clean_load()

local function test_errors_collect_unreadable_entries()
  local dir = make_envd("errunreadable")
  fs.write(fs.join(dir, "00-good"), "COSMIC_ENVD_ERR_TEST_B=1\n")
  -- A subdirectory inside env.d cannot be slurped (EISDIR): the load
  -- must still apply the readable files and report the failure.
  fs.make_dirs(fs.join(dir, "10-subdir"))
  env.unset("COSMIC_ENVD_ERR_TEST_B")

  local result = envd.load_dir(dir)
  assert(result.count == 1, "readable file should still load, got count " .. tostring(result.count))
  assert(#result.errors == 1, "expected 1 collected error, got " .. tostring(#result.errors))
  assert(result.errors[1]:match("10%-subdir"), "error should name the entry, got: " .. result.errors[1])
  env.unset("COSMIC_ENVD_ERR_TEST_B")
end
test_errors_collect_unreadable_entries()
