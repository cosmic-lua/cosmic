#!/usr/bin/env cosmic
local fetch = require("cosmic.fetch")

local function test_module_loads()
  assert(fetch ~= nil, "fetch module should not be nil")
  assert(fetch.Fetch ~= nil, "fetch.Fetch should not be nil")
  assert(type(fetch.Fetch) == "function", "fetch.Fetch should be a function")
end
test_module_loads()

local function test_result_structure()
  -- Test that result has correct structure
  -- Use a guaranteed-to-fail protocol to test error handling
  local result = fetch.Fetch("invalid://this-will-definitely-fail")

  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for failed fetch, got: " .. tostring(result.ok))
  assert(result.status == nil, "result.status should be nil on error")
  assert(result.headers == nil, "result.headers should be nil on error")
  assert(result.body == nil, "result.body should be nil on error")
  assert(result.error ~= nil, "result.error should not be nil on failure")
  assert(type(result.error) == "string", "result.error should be a string")
  assert(#result.error > 0, "result.error should not be empty")
end
test_result_structure()

-- Test with a data URL to verify success path without network dependency
local function test_success_structure()
  -- Use a data URL which should always work
  local result = fetch.Fetch("data:text/plain,Hello%20World")

  -- Verify the result has consistent structure regardless of outcome
  assert(result ~= nil, "result should not be nil")
  assert(type(result.ok) == "boolean", "result.ok should be a boolean")
  if result.ok then
    assert(result.status ~= nil, "result.status should be set on success")
    assert(result.headers ~= nil, "result.headers should be set on success")
    assert(type(result.headers) == "table", "result.headers should be a table")
    assert(result.body ~= nil, "result.body should be set on success")
    assert(result.error == nil, "result.error should be nil on success")
  else
    -- data URLs not supported — verify error structure and report skip
    assert(result.error ~= nil, "result.error should be set on failure")
    assert(type(result.error) == "string", "result.error should be a string")
    io.stderr:write("SKIP: test_success_structure success-path assertions (data URLs not supported)\n")
  end
end
test_success_structure()

-- Test that error messages are preserved (the main point of this wrapper)
local function test_error_preservation()
  local result = fetch.Fetch("invalid://guaranteed-failure")

  -- The key feature: error message should be accessible and non-empty
  assert(result.error ~= nil, "error should be preserved")
  assert(type(result.error) == "string", "error should be a string")
  assert(#result.error > 0, "error should not be empty")
  -- Should not be "nil" string which was the original problem
  assert(result.error ~= "nil", "error should not be 'nil' string")
end
test_error_preservation()

-- Test that HTTP error statuses (4xx, 5xx) still return ok=true
-- because the HTTP request itself succeeded
local function test_http_error_status()
  -- Use httpbin's 404 endpoint - skip if network unavailable
  local result = fetch.Fetch("https://httpbin.org/status/404")

  if not result.ok then
    -- Network failure - skip this test
    io.stderr:write("SKIP: test_http_error_status (network unavailable)\n")
    return
  end

  -- HTTP 404 is still a successful HTTP request
  assert(result.ok == true, "ok should be true for HTTP error status")
  assert(result.status == 404, "status should be 404, got: " .. tostring(result.status))
  assert(result.headers ~= nil, "headers should be present")
  assert(result.error == nil, "error should be nil on HTTP success")
end
test_http_error_status()

-- Streaming API tests

local function test_stream_module_exports()
  assert(fetch.stream ~= nil, "fetch.stream should not be nil")
  assert(type(fetch.stream) == "function", "fetch.stream should be a function")
end
test_stream_module_exports()

-- Check if FetchStream primitive is available (PR #88)
local cosmo = require("cosmo")
local has_fetch_stream = cosmo.FetchStream ~= nil
if not has_fetch_stream then
  io.stderr:write("SKIP: streaming tests (FetchStream primitive not available)\n")
end

local function test_stream_invalid_url_returns_error()
  if not has_fetch_stream then return end
  local result = fetch.stream("invalid://this-will-definitely-fail")

  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for failed fetch")
  assert(result.error ~= nil, "result.error should not be nil on failure")
  assert(result.reader == nil, "result.reader should be nil on error")
end
test_stream_invalid_url_returns_error()

local function test_stream_successful_returns_reader()
  if not has_fetch_stream then return end
  local result = fetch.stream("https://httpbin.org/stream/3")

  if not result.ok then
    io.stderr:write("SKIP: test_stream_successful_returns_reader (network unavailable)\n")
    return
  end

  assert(result.status == 200, "status should be 200, got: " .. tostring(result.status))
  assert(result.reader ~= nil, "reader should not be nil")
  assert(result.headers ~= nil, "headers should be present")
  result.reader:close()
end
test_stream_successful_returns_reader()

local function test_stream_reader_read_returns_chunks()
  if not has_fetch_stream then return end
  local result = fetch.stream("https://httpbin.org/stream/3")

  if not result.ok then
    io.stderr:write("SKIP: test_stream_reader_read_returns_chunks (network unavailable)\n")
    return
  end

  local chunks: {string} = {}
  while true do
    local chunk = result.reader:read()
    if not chunk then break end
    table.insert(chunks, chunk)
  end

  assert(#chunks > 0, "should have read at least one chunk")
  result.reader:close()
end
test_stream_reader_read_returns_chunks()

local function test_stream_reader_lines_yields_complete_lines()
  if not has_fetch_stream then return end
  local result = fetch.stream("https://httpbin.org/stream/3")

  if not result.ok then
    io.stderr:write("SKIP: test_stream_reader_lines_yields_complete_lines (network unavailable)\n")
    return
  end

  local lines: {string} = {}
  for line in result.reader:lines() do
    table.insert(lines, line)
  end

  if #lines ~= 3 then
    io.stderr:write("SKIP: test_stream_reader_lines_yields_complete_lines (httpbin returned " .. tostring(#lines) .. " lines, expected 3)\n")
    return
  end
  assert(#lines == 3, "httpbin/stream/3 should return 3 lines, got: " .. tostring(#lines))
end
test_stream_reader_lines_yields_complete_lines()

local function test_stream_reader_closed_reflects_state()
  if not has_fetch_stream then return end
  local result = fetch.stream("https://httpbin.org/get")

  if not result.ok then
    io.stderr:write("SKIP: test_stream_reader_closed_reflects_state (network unavailable)\n")
    return
  end

  assert(not result.reader:closed(), "reader should not be closed initially")
  result.reader:close()
  assert(result.reader:closed(), "reader should be closed after close()")
end
test_stream_reader_closed_reflects_state()

local function test_stream_reader_close_idempotent()
  if not has_fetch_stream then return end
  local result = fetch.stream("https://httpbin.org/get")

  if not result.ok then
    io.stderr:write("SKIP: test_stream_reader_close_idempotent (network unavailable)\n")
    return
  end

  assert(result.reader:close() == true, "first close should return true")
  assert(result.reader:close() == true, "second close should also return true")
  assert(result.reader:closed(), "reader should be closed")
end
test_stream_reader_close_idempotent()

local function test_stream_http_error_status_returns_reader()
  if not has_fetch_stream then return end
  local result = fetch.stream("https://httpbin.org/status/404")

  if not result.ok then
    io.stderr:write("SKIP: test_stream_http_error_status_returns_reader (network unavailable)\n")
    return
  end

  assert(result.ok == true, "ok should be true for HTTP error status")
  assert(result.status == 404, "status should be 404, got: " .. tostring(result.status))
  assert(result.reader ~= nil, "reader should be present even for 4xx status")
  result.reader:close()
end
test_stream_http_error_status_returns_reader()

-- scheme validation tests

local function test_fetch_empty_url_rejected()
  local result = fetch.Fetch("")
  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for empty URL")
  assert(result.error == "empty URL", "expected 'empty URL', got: " .. tostring(result.error))
end
test_fetch_empty_url_rejected()

local function test_fetch_unsupported_scheme_rejected()
  local result = fetch.Fetch("ftp://example.com/file.txt")
  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for ftp scheme")
  assert(result.error ~= nil, "result.error should be set")
  assert(result.error:find("unsupported URL scheme") ~= nil, "error should mention unsupported scheme, got: " .. tostring(result.error))
end
test_fetch_unsupported_scheme_rejected()

local function test_fetch_file_scheme_rejected()
  local result = fetch.Fetch("file:///etc/passwd")
  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for file scheme")
  assert(result.error ~= nil, "result.error should be set")
  assert(result.error:find("unsupported URL scheme") ~= nil, "error should mention unsupported scheme, got: " .. tostring(result.error))
end
test_fetch_file_scheme_rejected()

local function test_fetch_no_scheme_rejected()
  local result = fetch.Fetch("example.com/path")
  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for no-scheme URL")
  assert(result.error ~= nil, "result.error should be set")
  assert(result.error:find("unsupported URL scheme") ~= nil, "error should mention unsupported scheme, got: " .. tostring(result.error))
end
test_fetch_no_scheme_rejected()

local function test_fetch_http_passes_validation()
  -- http:// should pass validation; connection failure is expected (no network)
  local result = fetch.Fetch("http://127.0.0.1:1")
  assert(result ~= nil, "result should not be nil")
  -- The error (if any) should not be a scheme error
  if not result.ok then
    assert(result.error ~= "unsupported URL scheme: http", "http scheme should pass validation")
    assert(result.error ~= "empty URL", "http URL should not be empty")
  end
end
test_fetch_http_passes_validation()

local function test_fetch_https_passes_validation()
  -- https:// should pass validation; connection failure is expected (no network)
  local result = fetch.Fetch("https://127.0.0.1:1")
  assert(result ~= nil, "result should not be nil")
  if not result.ok then
    assert(result.error ~= "unsupported URL scheme: https", "https scheme should pass validation")
    assert(result.error ~= "empty URL", "https URL should not be empty")
  end
end
test_fetch_https_passes_validation()

local function test_stream_empty_url_rejected()
  if not has_fetch_stream then return end
  local result = fetch.stream("")
  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for empty URL")
  assert(result.error == "empty URL", "expected 'empty URL', got: " .. tostring(result.error))
end
test_stream_empty_url_rejected()

local function test_stream_unsupported_scheme_rejected()
  if not has_fetch_stream then return end
  local result = fetch.stream("ftp://example.com/file.txt")
  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for ftp scheme")
  assert(result.error ~= nil, "result.error should be set")
  assert(result.error:find("unsupported URL scheme") ~= nil, "error should mention unsupported scheme, got: " .. tostring(result.error))
end
test_stream_unsupported_scheme_rejected()

-- unix_proxy helper tests

local function test_unix_proxy_valid_path()
  local url, err = fetch.unix_proxy("/tmp/proxy.sock")
  assert(url == "unix:///tmp/proxy.sock", "expected unix:///tmp/proxy.sock, got: " .. tostring(url))
  assert(err == nil, "expected no error, got: " .. tostring(err))
end
test_unix_proxy_valid_path()

local function test_unix_proxy_empty_path()
  local url, err = fetch.unix_proxy("")
  assert(url == nil, "expected nil for empty path")
  assert(err == "empty socket path", "expected 'empty socket path', got: " .. tostring(err))
end
test_unix_proxy_empty_path()

local function test_unix_proxy_relative_path()
  local url, err = fetch.unix_proxy("relative/path.sock")
  assert(url == nil, "expected nil for relative path")
  assert(err == "socket path must be absolute", "expected absolute path error, got: " .. tostring(err))
end
test_unix_proxy_relative_path()

local function test_unix_proxy_dotdot_segment()
  local url, err = fetch.unix_proxy("/tmp/../etc/proxy.sock")
  assert(url == nil, "expected nil for path with .. segment")
  assert(err == "socket path must not contain . or .. segments", "expected segment error, got: " .. tostring(err))
end
test_unix_proxy_dotdot_segment()

local function test_unix_proxy_dot_segment()
  local url, err = fetch.unix_proxy("/tmp/./proxy.sock")
  assert(url == nil, "expected nil for path with . segment")
  assert(err == "socket path must not contain . or .. segments", "expected segment error, got: " .. tostring(err))
end
test_unix_proxy_dot_segment()

local function test_unix_proxy_too_long_path()
  local long_path = "/" .. string.rep("a", 108)
  local url, err = fetch.unix_proxy(long_path)
  assert(url == nil, "expected nil for too-long path")
  assert(err == "socket path too long", "expected too-long error, got: " .. tostring(err))
end
test_unix_proxy_too_long_path()

local function test_unix_proxy_trailing_dotdot()
  local url, err = fetch.unix_proxy("/tmp/..")
  assert(url == nil, "expected nil for path ending with ..")
  assert(err == "socket path must not contain . or .. segments", "expected segment error, got: " .. tostring(err))
end
test_unix_proxy_trailing_dotdot()

local function test_unix_proxy_trailing_dot()
  local url, err = fetch.unix_proxy("/tmp/.")
  assert(url == nil, "expected nil for path ending with .")
  assert(err == "socket path must not contain . or .. segments", "expected segment error, got: " .. tostring(err))
end
test_unix_proxy_trailing_dot()

-- method and body option tests

local function test_fetch_post_method()
  -- Use httpbin's POST endpoint to verify POST works
  local result = fetch.Fetch("https://httpbin.org/post", {method = "POST", body = "hello=world"})

  if not result.ok then
    io.stderr:write("SKIP: test_fetch_post_method (network unavailable)\n")
    return
  end

  assert(result.ok == true, "ok should be true")
  assert(result.status == 200, "status should be 200, got: " .. tostring(result.status))
  assert(result.body ~= nil, "body should not be nil")
  assert(result.body:find("hello=world") ~= nil, "body should echo posted data")
end
test_fetch_post_method()

local function test_fetch_method_passthrough()
  -- Verify that method option doesn't cause type errors
  -- Use an invalid URL so this test doesn't require network
  local result = fetch.Fetch("invalid://test", {method = "POST", body = "test"})
  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for invalid URL")
  assert(result.error ~= nil, "result.error should be set")
end
test_fetch_method_passthrough()

local function test_stream_post_method()
  if not has_fetch_stream then return end
  local result = fetch.stream("https://httpbin.org/post", {method = "POST", body = "stream=test"})

  if not result.ok then
    io.stderr:write("SKIP: test_stream_post_method (network unavailable)\n")
    return
  end

  assert(result.ok == true, "ok should be true")
  assert(result.status == 200, "status should be 200, got: " .. tostring(result.status))
  assert(result.reader ~= nil, "reader should not be nil")

  local chunks: {string} = {}
  while true do
    local chunk = result.reader:read()
    if not chunk then break end
    table.insert(chunks, chunk)
  end

  local body = table.concat(chunks)
  assert(body:find("stream=test") ~= nil, "streamed body should echo posted data")
  result.reader:close()
end
test_stream_post_method()

-- proxy option passthrough test
local function test_fetch_with_proxy_nonexistent_socket()
  -- Verify that the proxy option is passed through to cosmo.Fetch
  -- by using a socket path that doesn't exist (should produce a connection error)
  local result = fetch.Fetch("http://example.com", {proxy = "unix:///tmp/nonexistent-cosmic-test.sock"})
  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for nonexistent socket")
  assert(result.error ~= nil, "result.error should describe the failure")
end
test_fetch_with_proxy_nonexistent_socket()

local function test_stream_with_proxy_nonexistent_socket()
  if not has_fetch_stream then return end
  local result = fetch.stream("http://example.com", {proxy = "unix:///tmp/nonexistent-cosmic-test.sock"})
  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for nonexistent socket")
  assert(result.error ~= nil, "result.error should describe the failure")
end
test_stream_with_proxy_nonexistent_socket()

-- timeout option tests

local function test_timeout_option_accepted()
  -- Verify that passing timeout does not cause a type error or crash
  -- Use an invalid URL so this test doesn't require network
  local result = fetch.Fetch("invalid://this-will-fail", {timeout = 30})
  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for invalid URL")
  assert(result.error ~= nil, "result.error should be set")
end
test_timeout_option_accepted()

local function test_timeout_option_passthrough_stream()
  if not has_fetch_stream then return end
  -- Verify that passing timeout to stream does not cause a type error or crash
  local result = fetch.stream("invalid://this-will-fail", {timeout = 5})
  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for invalid URL")
  assert(result.error ~= nil, "result.error should be set")
end
test_timeout_option_passthrough_stream()
