#!/usr/bin/env cosmic
--- Tests for cosmic.env's dotenv half:
--- parse_dotenv/format_dotenv/expand and load_dotenv/load_embedded_dotenv.
local check = require("cosmic.check")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp/env_dotenv_test"
assert(fs.make_dirs(tmpdir))

local function make_envd(name: string): string
  local dir = fs.join(tmpdir, name)
  assert(fs.make_dirs(dir))
  return dir
end

local function test_basic_load()
  local dir = make_envd("basic")
  assert(fs.write(fs.join(dir, "00-base"), "COSMIC_ENVD_TEST_A=value_a\nCOSMIC_ENVD_TEST_B=value_b\n"))

  assert(env.unset("COSMIC_ENVD_TEST_A"))
  assert(env.unset("COSMIC_ENVD_TEST_B"))

  local result = env.load_dotenv(dir)
  assert(result.count == 2, "expected 2, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_A") == "value_a",
    "expected 'value_a', got '" .. tostring(env.get("COSMIC_ENVD_TEST_A")) .. "'")
  assert(env.get("COSMIC_ENVD_TEST_B") == "value_b",
    "expected 'value_b', got '" .. tostring(env.get("COSMIC_ENVD_TEST_B")) .. "'")

  assert(env.unset("COSMIC_ENVD_TEST_A"))
  assert(env.unset("COSMIC_ENVD_TEST_B"))
end
test_basic_load()

local function test_no_overwrite()
  local dir = make_envd("nooverwrite")
  assert(fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_TEST_EXISTING=new_value\n"))

  assert(env.set("COSMIC_ENVD_TEST_EXISTING", "original_value"))

  local result = env.load_dotenv(dir)
  assert(result.count == 0, "expected 0, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_EXISTING") == "original_value",
    "should not overwrite existing var")

  assert(env.unset("COSMIC_ENVD_TEST_EXISTING"))
end
test_no_overwrite()

local function test_comments_skipped()
  local dir = make_envd("comments")
  assert(fs.write(fs.join(dir, "vars"), "# this is a comment\nCOSMIC_ENVD_TEST_C=works\n# another comment\n"))

  assert(env.unset("COSMIC_ENVD_TEST_C"))
  local result = env.load_dotenv(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_C") == "works")

  assert(env.unset("COSMIC_ENVD_TEST_C"))
end
test_comments_skipped()

local function test_blank_lines_and_comment_only_files()
  local dir = make_envd("blanks")
  assert(fs.write(fs.join(dir, "README"), "# this file is documentation\n# no vars here\n"))
  assert(fs.write(fs.join(dir, "vars"), "\n\nCOSMIC_ENVD_TEST_D=val\n\n"))

  assert(env.unset("COSMIC_ENVD_TEST_D"))
  local result = env.load_dotenv(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_D") == "val")

  assert(env.unset("COSMIC_ENVD_TEST_D"))
end
test_blank_lines_and_comment_only_files()

local function test_lexical_order_concat()
  local dir = make_envd("order")
  -- 01-first sets a key, 02-second overrides it
  assert(fs.write(fs.join(dir, "01-first"), "COSMIC_ENVD_TEST_ORDER=first\n"))
  assert(fs.write(fs.join(dir, "02-second"), "COSMIC_ENVD_TEST_ORDER=second\n"))

  assert(env.unset("COSMIC_ENVD_TEST_ORDER"))
  local result = env.load_dotenv(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_ORDER") == "second",
    "later file should win, got '" .. tostring(env.get("COSMIC_ENVD_TEST_ORDER")) .. "'")

  assert(env.unset("COSMIC_ENVD_TEST_ORDER"))
end
test_lexical_order_concat()

local function test_value_with_equals()
  local dir = make_envd("equals")
  assert(fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_TEST_EQ=foo=bar=baz\n"))

  assert(env.unset("COSMIC_ENVD_TEST_EQ"))
  local result = env.load_dotenv(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_EQ") == "foo=bar=baz",
    "value after first = should be preserved, got '" .. tostring(env.get("COSMIC_ENVD_TEST_EQ")) .. "'")

  assert(env.unset("COSMIC_ENVD_TEST_EQ"))
end
test_value_with_equals()

local function test_empty_value()
  local dir = make_envd("emptyval")
  assert(fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_TEST_EMPTY=\n"))

  assert(env.unset("COSMIC_ENVD_TEST_EMPTY"))
  local result = env.load_dotenv(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_EMPTY") == "",
    "empty value should be set string, got '" .. tostring(env.get("COSMIC_ENVD_TEST_EMPTY")) .. "'")

  assert(env.unset("COSMIC_ENVD_TEST_EMPTY"))
end
test_empty_value()

local function test_invalid_key_lines_skipped()
  local dir = make_envd("invalidkey")
  assert(fs.write(fs.join(dir, "vars"), "123BAD=skip\nhas-dash=skip\nCOSMIC_ENVD_TEST_OK=good\n"))

  assert(env.unset("COSMIC_ENVD_TEST_OK"))
  local result = env.load_dotenv(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_OK") == "good")

  assert(env.unset("COSMIC_ENVD_TEST_OK"))
end
test_invalid_key_lines_skipped()

-- A directory that cannot be opened is a reported error like any
-- other; the absent-is-ordinary case lives in load_embedded_dotenv,
-- tested below.
local function test_missing_dir_is_an_error()
  local missing = fs.join(tmpdir, "nonexistent_dir_xyz")
  local result = env.load_dotenv(missing)
  assert(result.count == 0, "missing dir should set nothing")
  assert(#result.errors == 1, "missing dir should be reported, got "
    .. tostring(#result.errors) .. " error(s)")
  assert(result.errors[1]:find(missing, 1, true),
    "error should name the directory, got: " .. result.errors[1])
end
test_missing_dir_is_an_error()

-- The test binary embeds no env.d, so the embedded load is the
-- absent-directory case: a clean empty result, not an error.
local function test_load_embedded_dotenv_clean_when_absent()
  local result = env.load_embedded_dotenv()
  assert(result.source == "/zip/embed/env.d", "got: " .. result.source)
  assert(#result.errors == 0, "absent embedded env.d is not an error, got: "
    .. tostring(result.errors[1]))
end
test_load_embedded_dotenv_clean_when_absent()

local function test_load_result_source()
  local dir = make_envd("source")
  local result = env.load_dotenv(dir)
  assert(result.source == dir, "source should be the dir path")
end
test_load_result_source()

local function test_parse_basic()
  local vars = env.parse_dotenv("FOO=bar\nBAZ=qux\n")
  assert(vars["FOO"] == "bar", "expected 'bar', got '" .. tostring(vars["FOO"]) .. "'")
  assert(vars["BAZ"] == "qux", "expected 'qux', got '" .. tostring(vars["BAZ"]) .. "'")
end
test_parse_basic()

local function test_parse_comments_and_blanks()
  local vars = env.parse_dotenv("# comment\n\nKEY=val\n  # indented comment\n")
  local count = 0
  for _ in pairs(vars) do count = count + 1 end
  assert(count == 1, "expected 1 key, got " .. tostring(count))
  assert(vars["KEY"] == "val")
end
test_parse_comments_and_blanks()

local function test_multiple_files_merge()
  local dir = make_envd("merge")
  assert(fs.write(fs.join(dir, "01-a"), "COSMIC_ENVD_TEST_X=from_a\nCOSMIC_ENVD_TEST_Y=from_a\n"))
  assert(fs.write(fs.join(dir, "02-b"), "COSMIC_ENVD_TEST_Y=from_b\nCOSMIC_ENVD_TEST_Z=from_b\n"))

  assert(env.unset("COSMIC_ENVD_TEST_X"))
  assert(env.unset("COSMIC_ENVD_TEST_Y"))
  assert(env.unset("COSMIC_ENVD_TEST_Z"))

  local result = env.load_dotenv(dir)
  assert(result.count == 3, "expected 3, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_X") == "from_a")
  assert(env.get("COSMIC_ENVD_TEST_Y") == "from_b",
    "later file should win for Y, got '" .. tostring(env.get("COSMIC_ENVD_TEST_Y")) .. "'")
  assert(env.get("COSMIC_ENVD_TEST_Z") == "from_b")

  assert(env.unset("COSMIC_ENVD_TEST_X"))
  assert(env.unset("COSMIC_ENVD_TEST_Y"))
  assert(env.unset("COSMIC_ENVD_TEST_Z"))
end
test_multiple_files_merge()

local function test_underscore_prefix_key()
  local dir = make_envd("underscore")
  assert(fs.write(fs.join(dir, "vars"), "_COSMIC_ENVD_TEST_UNDER=val\n"))

  assert(env.unset("_COSMIC_ENVD_TEST_UNDER"))
  local result = env.load_dotenv(dir)
  assert(result.count == 1, "expected 1, got " .. tostring(result.count))
  assert(env.get("_COSMIC_ENVD_TEST_UNDER") == "val")

  assert(env.unset("_COSMIC_ENVD_TEST_UNDER"))
end
test_underscore_prefix_key()

-- format_dotenv: the format half of parse_dotenv.

local function test_format_sorts_keys_and_terminates_lines()
  local text = env.format_dotenv({B = "2", A = "1", C = "3"})
  assert(text == "A=1\nB=2\nC=3\n", "got: " .. text)
end
test_format_sorts_keys_and_terminates_lines()

local function test_format_empty_map_is_empty_string()
  assert(env.format_dotenv({}) == "", "empty map should format to \"\"")
end
test_format_empty_map_is_empty_string()

local function test_format_round_trips_through_parse()
  local vars: {string: string} = {HOST = "localhost", PORT = "8080", EMPTY = ""}
  local parsed = env.parse_dotenv(env.format_dotenv(vars))
  for k, v in pairs(vars) do
    assert(parsed[k] == v, k .. ": expected '" .. v .. "', got '" .. tostring(parsed[k]) .. "'")
  end
  local count = 0
  for _ in pairs(parsed) do count = count + 1 end
  assert(count == 3, "expected 3 keys back, got " .. tostring(count))
end
test_format_round_trips_through_parse()

-- variable expansion

local function test_expand_plain_var()
  local vars = env.parse_dotenv("BASE=/opt\nPATH_VAR=${BASE}/bin\n")
  assert(vars["BASE"] == "/opt", "expected '/opt', got '" .. tostring(vars["BASE"]) .. "'")
  assert(vars["PATH_VAR"] == "/opt/bin", "expected '/opt/bin', got '" .. tostring(vars["PATH_VAR"]) .. "'")
end
test_expand_plain_var()

local function test_expand_undefined_var()
  assert(env.unset("COSMIC_ENVD_TEST_UNDEF"))
  local vars = env.parse_dotenv("VAL=${COSMIC_ENVD_TEST_UNDEF}rest\n")
  assert(vars["VAL"] == "rest", "undefined should expand to empty, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_undefined_var()

local function test_expand_from_env()
  assert(env.set("COSMIC_ENVD_TEST_FROMENV", "envval"))
  local vars = env.parse_dotenv("VAL=${COSMIC_ENVD_TEST_FROMENV}\n")
  assert(vars["VAL"] == "envval", "expected 'envval', got '" .. tostring(vars["VAL"]) .. "'")
  assert(env.unset("COSMIC_ENVD_TEST_FROMENV"))
end
test_expand_from_env()

local function test_expand_default_unset()
  assert(env.unset("COSMIC_ENVD_TEST_NOSUCH"))
  local vars = env.parse_dotenv("VAL=${COSMIC_ENVD_TEST_NOSUCH:-fallback}\n")
  assert(vars["VAL"] == "fallback", "expected 'fallback', got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_default_unset()

local function test_expand_default_empty()
  local vars = env.parse_dotenv("EMPTY=\nVAL=${EMPTY:-fallback}\n")
  assert(vars["VAL"] == "fallback", ":-default should trigger on empty, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_default_empty()

local function test_expand_default_set()
  local vars = env.parse_dotenv("BASE=real\nVAL=${BASE:-fallback}\n")
  assert(vars["VAL"] == "real", ":-default should not trigger when set, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_default_set()

local function test_expand_dash_default_unset()
  assert(env.unset("COSMIC_ENVD_TEST_NOSUCH2"))
  local vars = env.parse_dotenv("VAL=${COSMIC_ENVD_TEST_NOSUCH2-fallback}\n")
  assert(vars["VAL"] == "fallback", "expected 'fallback', got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_dash_default_unset()

local function test_expand_dash_default_empty()
  local vars = env.parse_dotenv("EMPTY=\nVAL=${EMPTY-fallback}\n")
  assert(vars["VAL"] == "", "-default should NOT trigger on empty, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_dash_default_empty()

local function test_expand_multiple_refs()
  local vars = env.parse_dotenv("HOST=localhost\nPORT=8080\nURL=http://${HOST}:${PORT}/api\n")
  assert(vars["URL"] == "http://localhost:8080/api",
    "expected 'http://localhost:8080/api', got '" .. tostring(vars["URL"]) .. "'")
end
test_expand_multiple_refs()

local function test_expand_with_ctx()
  local ctx: {string: string} = {PRIOR = "fromctx"}
  local vars = env.parse_dotenv("VAL=${PRIOR}/more\n", ctx)
  assert(vars["VAL"] == "fromctx/more", "expected 'fromctx/more', got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_with_ctx()

local function test_expand_across_files()
  local dir = make_envd("expand_across")
  assert(fs.write(fs.join(dir, "01-base"), "COSMIC_ENVD_TEST_BASE=/opt\n"))
  assert(fs.write(fs.join(dir, "02-derived"), "COSMIC_ENVD_TEST_DERIVED=${COSMIC_ENVD_TEST_BASE}/bin\n"))

  assert(env.unset("COSMIC_ENVD_TEST_BASE"))
  assert(env.unset("COSMIC_ENVD_TEST_DERIVED"))

  local result = env.load_dotenv(dir)
  assert(result.count == 2, "expected 2, got " .. tostring(result.count))
  assert(env.get("COSMIC_ENVD_TEST_BASE") == "/opt")
  assert(env.get("COSMIC_ENVD_TEST_DERIVED") == "/opt/bin",
    "expected '/opt/bin', got '" .. tostring(env.get("COSMIC_ENVD_TEST_DERIVED")) .. "'")

  assert(env.unset("COSMIC_ENVD_TEST_BASE"))
  assert(env.unset("COSMIC_ENVD_TEST_DERIVED"))
end
test_expand_across_files()

local function test_expand_no_expansion_without_braces()
  local vars = env.parse_dotenv("BASE=val\nVAL=$BASE/rest\n")
  assert(vars["VAL"] == "$BASE/rest",
    "$VAR without braces should not expand, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_no_expansion_without_braces()

local function test_expand_malformed_expr()
  local vars = env.parse_dotenv("VAL=${123BAD}\n")
  assert(vars["VAL"] == "${123BAD}",
    "malformed should be left as-is, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_malformed_expr()

local function test_expand_nested_default()
  local vars = env.parse_dotenv("VAL=${NOSUCH:-a=b}\n")
  assert(vars["VAL"] == "a=b",
    "default can contain =, got '" .. tostring(vars["VAL"]) .. "'")
end
test_expand_nested_default()

local function test_expand_function_directly()
  local ctx: {string: string} = {FOO = "bar"}
  local result = env.expand("hello ${FOO} world", ctx)
  assert(result == "hello bar world", "expected 'hello bar world', got '" .. result .. "'")
end
test_expand_function_directly()

-- parse must strip trailing \r from CRLF dotenv files.
local function test_parse_crlf_no_trailing_cr()
  local crlf_content = "COSMIC_ENVD_CRLF_A=hello\r\nCOSMIC_ENVD_CRLF_B=world\r\n"
  local vars = env.parse_dotenv(crlf_content)
  assert(vars["COSMIC_ENVD_CRLF_A"] == "hello",
    "CRLF: expected 'hello' (len 5), got len=" .. tostring(#tostring(vars["COSMIC_ENVD_CRLF_A"] or "")))
  assert(vars["COSMIC_ENVD_CRLF_B"] == "world",
    "CRLF: expected 'world' (len 5), got len=" .. tostring(#tostring(vars["COSMIC_ENVD_CRLF_B"] or "")))
end
test_parse_crlf_no_trailing_cr()

local function test_load_dotenv_crlf_file()
  local dir = make_envd("crlf_dir")
  local crlf_content = "COSMIC_ENVD_CRLF_C=crvalue\r\n"
  assert(fs.write(fs.join(dir, "vars"), crlf_content))

  assert(env.unset("COSMIC_ENVD_CRLF_C"))
  local result = env.load_dotenv(dir)
  assert(result.count == 1, "expected 1 var from CRLF file, got " .. tostring(result.count))
  local val = env.get("COSMIC_ENVD_CRLF_C")
  assert(val == "crvalue",
    "CRLF file: expected 'crvalue', got '" .. tostring(val) .. "'")
  assert(env.unset("COSMIC_ENVD_CRLF_C"))
end
test_load_dotenv_crlf_file()

-- COSMIC_DEBUG='' (empty string) must NOT enable debug mode; only a
-- non-empty value should. Capture the debug channel (the loader
-- writes via io.stderr) instead of asserting a count that passes
-- either way.
local function load_dotenv_capturing_stderr(dir: string): env.LoadResult, string
  local capture_path = fs.join(tmpdir, "env_debug_capture")
  local real_stderr = io.stderr
  io.stderr = assert(io.open(capture_path, "w"))
  local result = env.load_dotenv(dir)
  io.stderr:close()
  io.stderr = real_stderr
  return result, check.must(fs.read(capture_path))
end

local function test_cosmic_debug_empty_not_enabled()
  local dir = make_envd("debug_empty")
  assert(fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_DEBUG_TEST=value\n"))
  assert(env.unset("COSMIC_ENVD_DEBUG_TEST"))

  assert(env.set("COSMIC_DEBUG", ""))
  local result, captured = load_dotenv_capturing_stderr(dir)
  assert(env.unset("COSMIC_DEBUG"))

  assert(result.count == 1, "expected 1 with empty COSMIC_DEBUG, got " .. tostring(result.count))
  assert(not captured:match("%[env%]"),
    "COSMIC_DEBUG='' must not emit debug output, got: " .. captured)
  assert(env.unset("COSMIC_ENVD_DEBUG_TEST"))
end
test_cosmic_debug_empty_not_enabled()

local function test_cosmic_debug_nonempty_emits_debug()
  local dir = make_envd("debug_on")
  assert(fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_DEBUG_TEST2=value\n"))
  assert(env.unset("COSMIC_ENVD_DEBUG_TEST2"))

  assert(env.set("COSMIC_DEBUG", "1"))
  local result, captured = load_dotenv_capturing_stderr(dir)
  assert(env.unset("COSMIC_DEBUG"))

  assert(result.count == 1, "expected 1 with COSMIC_DEBUG=1, got " .. tostring(result.count))
  assert(captured:match("%[env%] set COSMIC_ENVD_DEBUG_TEST2"),
    "COSMIC_DEBUG=1 must log each set variable, got: " .. captured)
  assert(env.unset("COSMIC_ENVD_DEBUG_TEST2"))
end
test_cosmic_debug_nonempty_emits_debug()

-- The "[env] set" debug line must not print when env.set failed.
-- The loader calls set through the module table (a plain table, like
-- childio.read_retry elsewhere) precisely so this test can
-- monkey-patch a failure; the failure still lands in result.errors,
-- just silently under COSMIC_DEBUG.
local function test_debug_set_not_logged_on_failure()
  local dir = make_envd("debug_set_fails")
  assert(fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_DEBUG_FAIL=value\n"))
  assert(env.unset("COSMIC_ENVD_DEBUG_FAIL"))
  assert(env.set("COSMIC_DEBUG", "1"))

  local real_set = env.set
  env.set = function(_name: string, _value: string, _overwrite?: boolean): boolean, string
    return false, "setenv: EINVAL: simulated failure"
  end
  local result, captured = load_dotenv_capturing_stderr(dir)
  env.set = real_set
  assert(env.unset("COSMIC_DEBUG"))

  assert(result.count == 0, "expected 0 vars set when env.set fails, got " .. tostring(result.count))
  assert(#result.errors == 1, "expected 1 error recorded, got " .. tostring(#result.errors))
  assert(not captured:match("%[env%] set"),
    "must not log '[env] set' when env.set failed, got: " .. captured)
end
test_debug_set_not_logged_on_failure()

-- LoadResult.errors: per-file read failures are collected instead of
-- being visible only under COSMIC_DEBUG.

local function test_errors_empty_on_clean_load()
  local dir = make_envd("errclean")
  assert(fs.write(fs.join(dir, "vars"), "COSMIC_ENVD_ERR_TEST_A=1\n"))
  assert(env.unset("COSMIC_ENVD_ERR_TEST_A"))

  local result = env.load_dotenv(dir)
  assert(result.errors ~= nil, "LoadResult should carry an errors list")
  assert(#result.errors == 0, "clean load should collect no errors, got: "
    .. tostring(result.errors[1]))
  assert(env.unset("COSMIC_ENVD_ERR_TEST_A"))
end
test_errors_empty_on_clean_load()

local function test_errors_collect_unreadable_entries()
  local dir = make_envd("errunreadable")
  assert(fs.write(fs.join(dir, "00-good"), "COSMIC_ENVD_ERR_TEST_B=1\n"))
  -- A subdirectory inside env.d cannot be slurped (EISDIR): the load
  -- must still apply the readable files and report the failure.
  assert(fs.make_dirs(fs.join(dir, "10-subdir")))
  assert(env.unset("COSMIC_ENVD_ERR_TEST_B"))

  local result = env.load_dotenv(dir)
  assert(result.count == 1, "readable file should still load, got count " .. tostring(result.count))
  assert(#result.errors == 1, "expected 1 collected error, got " .. tostring(#result.errors))
  assert(result.errors[1]:match("10%-subdir"), "error should name the entry, got: " .. result.errors[1])
  assert(env.unset("COSMIC_ENVD_ERR_TEST_B"))
end
test_errors_collect_unreadable_entries()
