#!/usr/bin/env cosmic
--- Core fetch tests against forked loopback servers: no external hosts,
--- no skip scaffolding. allow_private opts out of the SSRF guard so the
--- success path is exercised hermetically.
local check = require("cosmic.check")
local fetch = require("cosmic.fetch")
local net = require("cosmic.net")
local proc = require("cosmic.proc")

--- Read one HTTP request (head plus Content-Length body) from a connection.
local function read_request(conn: net.Socket): string
  local buf = ""
  while true do
    local head_end = buf:find("\r\n\r\n", 1, true)
    if head_end then
      local cl = buf:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
      local want = head_end + 3 + ((cl and math.tointeger(tonumber(cl))) or 0)
      if #buf >= want then
        return buf
      end
    end
    local data = conn:recv(4096)
    if not data or #data == 0 then
      return buf
    end
    buf = buf .. data
  end
end

--- Fork a loopback HTTP server that answers #responses requests in order,
--- then exits. An empty-string response means: accept, read the request,
--- and close without answering (a transport failure for the client).
--- A response of "echo" answers 200 with the raw request as the body.
--- @return integer port, integer child pid (caller must proc.wait it)
local function serve(responses: {string}): integer, integer
  local srv = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed")
  local port = check.must(s:local_endpoint()).port
  local pid = proc.fork()
  if pid == 0 then
    for _, resp in ipairs(responses) do
      local conn = s:accept()
      if conn then
        local c = conn
        local req = read_request(c)
        if resp == "echo" then
          assert(c:send("HTTP/1.1 200 OK\r\nContent-Length: " .. #req
              .. "\r\nConnection: close\r\n\r\n" .. req))
        elseif #resp > 0 then
          assert(c:send(resp))
        end
        assert(c:close())
      end
    end
    os.exit(0)
  end
  assert(s:close())
  return math.tointeger(port), pid
end

local function body_response(status_line: string, body: string, extra?: string): string
  return "HTTP/1.1 " .. status_line .. "\r\n" .. (extra or "")
  .. "Content-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body
end

local function test_module_loads()
  assert(fetch ~= nil, "fetch module should not be nil")
  assert(type(fetch.fetch) == "function", "fetch.fetch should be a function")
  assert(type(fetch.stream) == "function", "fetch.stream should be a function")
end
test_module_loads()

local function test_failure_shape()
  -- A failure is nil, Error and nothing past it (#1063, D24) — no
  -- Response exists, so there are no lying nil fields to poke at, and
  -- the classification is the typed kind field, not a message prefix.
  local resp, err = fetch.fetch("invalid://this-will-definitely-fail")
  assert(resp == nil, "no Response may exist for a failed fetch")
  assert(err ~= nil, "err must carry the failure")
  assert(err.kind == "invalid_request",
    "a validation failure carries kind invalid_request, got " .. tostring(err.kind))
  assert(#err.message > 0, "err.message should be a non-empty string")
  assert(err.message:find("invalid_request", 1, true) == nil,
    "the message stays clean; the kind is a field, not a prefix")
  assert(tostring(err) == "invalid_request: " .. err.message,
    "tostring(err) renders the classified form, got " .. tostring(err))
  assert(getmetatable(err) ~= nil, "every Error carries its __tostring metatable")
end
test_failure_shape()

local function test_loopback_get()
  local port, pid = serve({body_response("200 OK", "hello loopback")})
  local url = "http://127.0.0.1:" .. port .. "/"
  local result, err = fetch.fetch(url, {allow_private = true})
  assert(proc.wait(pid))
  assert(result ~= nil, "fetch should succeed, got error: " .. tostring(err))
  assert(result.status == 200, "status should be 200, got " .. tostring(result.status))
  assert(result.body == "hello loopback", "body mismatch: " .. tostring(result.body))
  assert(type(result.headers) == "table", "headers should be a table")
  assert(result.url == url, "result.url should be the effective URL, got " .. tostring(result.url))
  assert(err == nil, "err should be nil on success")
  assert(result:is_success() == true, "is_success must be true for 200")
end
test_loopback_get()

local function test_http_error_status_is_a_response()
  local port, pid = serve({body_response("404 Not Found", "nope")})
  local result, err = fetch.fetch("http://127.0.0.1:" .. port .. "/", {allow_private = true})
  assert(proc.wait(pid))
  assert(result ~= nil, "an HTTP 404 is a Response, not a failure: " .. tostring(err))
  assert(result.status == 404, "status should be 404, got " .. tostring(result.status))
  assert(err == nil, "err should be nil when a response arrived")
  assert(result:is_success() == false, "is_success must be false for 404")
end
test_http_error_status_is_a_response()

local function test_post_body_reaches_server()
  local port, pid = serve({"echo"})
  local result = check.must(fetch.fetch("http://127.0.0.1:" .. port .. "/submit",
      {allow_private = true, method = "POST", body = "hello=world"}))
  assert(proc.wait(pid))
  assert(result.body:find("POST /submit", 1, true) ~= nil,
    "server should have seen the POST request line: " .. tostring(result.body))
  assert(result.body:find("hello=world", 1, true) ~= nil,
    "server should have seen the POST body")
end
test_post_body_reaches_server()

local function test_ssrf_guard_blocks_private_by_default()
  local port, pid = serve({body_response("200 OK", "x")})
  local resp, err = fetch.fetch("http://127.0.0.1:" .. port .. "/")
  assert(resp == nil, "loopback fetch without allow_private must fail")
  assert(err and err.kind == "blocked",
    "kind should be 'blocked', got " .. tostring(err))
  -- unblock the waiting child so the test can reap it
  local unblock = fetch.fetch("http://127.0.0.1:" .. port .. "/", {allow_private = true})
  assert(unblock ~= nil, "allow_private fetch should succeed")
  assert(proc.wait(pid))
end
test_ssrf_guard_blocks_private_by_default()

local function test_error_kind_connect_for_refused_port()
  local resp, err = fetch.fetch("http://127.0.0.1:1/", {allow_private = true})
  assert(resp == nil, "connection to a dead port must fail")
  assert(err and err.kind == "connect",
    "kind should be 'connect', got " .. tostring(err))
end
test_error_kind_connect_for_refused_port()

local function test_follow_redirects_false_returns_redirect()
  local port, pid = serve({
      "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/next\r\n"
      .. "Content-Length: 0\r\nConnection: close\r\n\r\n",
    })
  local result = check.must(fetch.fetch("http://127.0.0.1:" .. port .. "/",
      {allow_private = true, follow_redirects = false}))
  assert(proc.wait(pid))
  assert(result.status == 302, "status should be 302, got " .. tostring(result.status))
  assert(result.headers.location == "http://127.0.0.1:1/next",
    "location header should be exposed, got " .. tostring(result.headers.location))
end
test_follow_redirects_false_returns_redirect()

local function test_redirect_followed_reports_final_url()
  -- serve() can't express a redirect that targets its own port (the
  -- response text needs the port), so fork by hand here.
  local srv = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed")
  local port2 = check.must(s:local_endpoint()).port
  local final_url = "http://127.0.0.1:" .. math.tointeger(port2) .. "/final"
  local pid2 = proc.fork()
  if pid2 == 0 then
    for i = 1, 2 do
      local conn = s:accept()
      if conn then
        local c = conn
        read_request(c)
        if i == 1 then
          assert(c:send("HTTP/1.1 302 Found\r\nLocation: " .. final_url
              .. "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
        else
          assert(c:send(body_response("200 OK", "made it")))
        end
        assert(c:close())
      end
    end
    os.exit(0)
  end
  assert(s:close())
  local result = check.must(fetch.fetch("http://127.0.0.1:" .. math.tointeger(port2) .. "/",
      {allow_private = true}))
  assert(proc.wait(pid2))
  assert(result.status == 200, "status should be 200 after redirect")
  assert(result.body == "made it", "body should come from the final URL")
  assert(result.url == final_url,
    "result.url should be the post-redirect URL, got " .. tostring(result.url))
end
test_redirect_followed_reports_final_url()

local function test_opts_table_not_mutated()
  local srv = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed")
  local port = check.must(s:local_endpoint()).port
  local redirect_url = "http://127.0.0.1:" .. math.tointeger(port) .. "/after"
  local pid = proc.fork()
  if pid == 0 then
    for i = 1, 2 do
      local conn = s:accept()
      if conn then
        local c = conn
        read_request(c)
        if i == 1 then
          assert(c:send("HTTP/1.1 303 See Other\r\nLocation: " .. redirect_url
              .. "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
        else
          assert(c:send(body_response("200 OK", "done")))
        end
        assert(c:close())
      end
    end
    os.exit(0)
  end
  assert(s:close())
  local headers = {["X-Custom"] = "keep", ["Authorization"] = "Bearer secret"}
  local opts: fetch.Options = {
    allow_private = true,
    method = "POST",
    body = "payload",
    headers = headers,
  }
  local result, err = fetch.fetch("http://127.0.0.1:" .. math.tointeger(port) .. "/", opts)
  assert(proc.wait(pid))
  assert(result ~= nil, "303-redirected POST should succeed: " .. tostring(err))
  -- a 303 turns the redirected request into a bodyless GET, but the
  -- caller's table must be untouched
  assert(opts.method == "POST", "opts.method must not be mutated, got " .. tostring(opts.method))
  assert(opts.body == "payload", "opts.body must not be mutated, got " .. tostring(opts.body))
  assert(opts.headers == headers, "opts.headers must still be the same table")
  assert(headers["X-Custom"] == "keep", "header value must not be mutated")
  assert(headers["Authorization"] == "Bearer secret",
    "Authorization must not be deleted from the caller's table")
end
test_opts_table_not_mutated()

-- scheme validation tests

local function test_fetch_empty_url_rejected()
  local resp, err = fetch.fetch("")
  assert(resp == nil, "an empty URL must fail")
  assert(err.kind == "invalid_request" and err.message == "empty URL",
    "expected kind invalid_request with a clean message, got: " .. tostring(err))
end
test_fetch_empty_url_rejected()

local function test_fetch_unsupported_scheme_rejected()
  local resp, err = fetch.fetch("ftp://example.com/file.txt")
  assert(resp == nil, "an ftp URL must fail")
  assert(err.message:find("unsupported URL scheme") ~= nil,
    "error should mention unsupported scheme, got: " .. tostring(err))
end
test_fetch_unsupported_scheme_rejected()

local function test_fetch_file_scheme_rejected()
  local resp, err = fetch.fetch("file:///etc/passwd")
  assert(resp == nil, "a file URL must fail")
  assert(err.message:find("unsupported URL scheme") ~= nil,
    "error should mention unsupported scheme, got: " .. tostring(err))
end
test_fetch_file_scheme_rejected()

local function test_fetch_no_scheme_rejected()
  local resp, err = fetch.fetch("example.com/path")
  assert(resp == nil, "a scheme-less URL must fail")
  assert(err.message:find("unsupported URL scheme") ~= nil,
    "error should mention unsupported scheme, got: " .. tostring(err))
end
test_fetch_no_scheme_rejected()

local function test_fetch_missing_host_rejected()
  local resp, err = fetch.fetch("http://")
  assert(resp == nil, "a host-less URL must fail")
  assert(err.kind == "invalid_request" and err.message == "missing URL host",
    "expected kind invalid_request with a clean message, got: " .. tostring(err))
end
test_fetch_missing_host_rejected()

-- The scheme comparison is case-insensitive: an uppercase scheme must
-- get past the scheme check (this host-less URL then fails on the host,
-- proving the scheme was accepted without any network traffic).
local function test_fetch_uppercase_scheme_accepted()
  local resp, err = fetch.fetch("HTTPS://")
  assert(resp == nil, "host-less URL still fails")
  assert(err.kind == "invalid_request" and err.message == "missing URL host",
    "uppercase scheme should pass the scheme check, got: " .. tostring(err))
end
test_fetch_uppercase_scheme_accepted()

local function test_fetch_with_proxy_nonexistent_socket()
  -- the proxy option is passed through to cosmo.Fetch: a socket path that
  -- doesn't exist produces a connection error
  local resp, err = fetch.fetch("http://example.com",
    {proxy = "unix:///tmp/nonexistent-cosmic-test.sock"})
  assert(resp == nil, "a nonexistent proxy socket must fail")
  assert(err ~= nil, "err should describe the failure")
end
test_fetch_with_proxy_nonexistent_socket()

local function test_timeout_option_accepted()
  local port, pid = serve({body_response("200 OK", "quick")})
  local result, err = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, timeout_ms = 30000})
  assert(proc.wait(pid))
  assert(result ~= nil, "fetch with timeout option should succeed: " .. tostring(err))
end
test_timeout_option_accepted()

local function test_max_response_bytes_enforced()
  local port, pid = serve({body_response("200 OK", string.rep("x", 4096))})
  local resp, err = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, max_response_bytes = 16})
  assert(proc.wait(pid))
  assert(resp == nil, "a body over max_response_bytes must fail")
  assert(err and err.kind == "too_large",
    "kind should be 'too_large', got " .. tostring(err))
end
test_max_response_bytes_enforced()
