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
  local srv, port = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed")
  local pid = proc.fork()
  if pid == 0 then
    for _, resp in ipairs(responses) do
      local conn = s:accept()
      if conn then
        local c = conn as net.Socket
        local req = read_request(c)
        if resp == "echo" then
          c:send("HTTP/1.1 200 OK\r\nContent-Length: " .. #req
            .. "\r\nConnection: close\r\n\r\n" .. req)
        elseif #resp > 0 then
          c:send(resp)
        end
        c:close()
      end
    end
    os.exit(0)
  end
  s:close()
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

local function test_result_structure_on_failure()
  local result = fetch.fetch("invalid://this-will-definitely-fail")
  assert(result ~= nil, "result should not be nil")
  assert(result.ok == false, "result.ok should be false for failed fetch")
  assert(result.status == nil, "result.status should be nil on error")
  assert(result.headers == nil, "result.headers should be nil on error")
  assert(result.body == nil, "result.body should be nil on error")
  assert(type(result.error) == "string" and #result.error > 0,
    "result.error should be a non-empty string")
  assert(result.error ~= "nil", "error should not be 'nil' string")
  assert(result:is_success() == false, "is_success must be false on failure")
end
test_result_structure_on_failure()

local function test_loopback_get()
  local port, pid = serve({body_response("200 OK", "hello loopback")})
  local url = "http://127.0.0.1:" .. port .. "/"
  local result = fetch.fetch(url, {allow_private = true})
  proc.wait(pid)
  assert(result.ok == true, "ok should be true, got error: " .. tostring(result.error))
  assert(result.status == 200, "status should be 200, got " .. tostring(result.status))
  assert(result.body == "hello loopback", "body mismatch: " .. tostring(result.body))
  assert(type(result.headers) == "table", "headers should be a table")
  assert(result.url == url, "result.url should be the effective URL, got " .. tostring(result.url))
  assert(result.error == nil, "error should be nil on success")
  assert(result.error_kind == nil, "error_kind should be nil on success")
  assert(result:is_success() == true, "is_success must be true for 200")
end
test_loopback_get()

local function test_http_error_status_is_ok_but_not_success()
  local port, pid = serve({body_response("404 Not Found", "nope")})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/", {allow_private = true})
  proc.wait(pid)
  assert(result.ok == true, "ok should be true for HTTP 404: " .. tostring(result.error))
  assert(result.status == 404, "status should be 404, got " .. tostring(result.status))
  assert(result.error == nil, "error should be nil on HTTP success")
  assert(result:is_success() == false, "is_success must be false for 404")
end
test_http_error_status_is_ok_but_not_success()

local function test_post_body_reaches_server()
  local port, pid = serve({"echo"})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/submit",
    {allow_private = true, method = "POST", body = "hello=world"})
  proc.wait(pid)
  assert(result.ok == true, "POST should succeed: " .. tostring(result.error))
  assert(result.body:find("POST /submit", 1, true) ~= nil,
    "server should have seen the POST request line: " .. tostring(result.body))
  assert(result.body:find("hello=world", 1, true) ~= nil,
    "server should have seen the POST body")
end
test_post_body_reaches_server()

local function test_ssrf_guard_blocks_private_by_default()
  local port, pid = serve({body_response("200 OK", "x")})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/")
  assert(result.ok == false, "loopback fetch without allow_private must fail")
  assert(result.error_kind == "blocked",
    "error_kind should be 'blocked', got " .. tostring(result.error_kind))
  -- unblock the waiting child so the test can reap it
  local unblock = fetch.fetch("http://127.0.0.1:" .. port .. "/", {allow_private = true})
  assert(unblock.ok == true, "allow_private fetch should succeed")
  proc.wait(pid)
end
test_ssrf_guard_blocks_private_by_default()

local function test_error_kind_connect_for_refused_port()
  local result = fetch.fetch("http://127.0.0.1:1/", {allow_private = true})
  assert(result.ok == false, "connection to a dead port must fail")
  assert(result.error_kind == "connect",
    "error_kind should be 'connect', got " .. tostring(result.error_kind))
end
test_error_kind_connect_for_refused_port()

local function test_follow_redirects_false_returns_redirect()
  local port, pid = serve({
      "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/next\r\n"
      .. "Content-Length: 0\r\nConnection: close\r\n\r\n",
    })
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, follow_redirects = false})
  proc.wait(pid)
  assert(result.ok == true, "redirect response should be returned: " .. tostring(result.error))
  assert(result.status == 302, "status should be 302, got " .. tostring(result.status))
  assert(result.headers.location == "http://127.0.0.1:1/next",
    "location header should be exposed, got " .. tostring(result.headers.location))
end
test_follow_redirects_false_returns_redirect()

local function test_redirect_followed_reports_final_url()
  -- serve() can't express a redirect that targets its own port (the
  -- response text needs the port), so fork by hand here.
  local srv, port2 = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed")
  local final_url = "http://127.0.0.1:" .. math.tointeger(port2) .. "/final"
  local pid2 = proc.fork()
  if pid2 == 0 then
    for i = 1, 2 do
      local conn = s:accept()
      if conn then
        local c = conn as net.Socket
        read_request(c)
        if i == 1 then
          c:send("HTTP/1.1 302 Found\r\nLocation: " .. final_url
            .. "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        else
          c:send(body_response("200 OK", "made it"))
        end
        c:close()
      end
    end
    os.exit(0)
  end
  s:close()
  local result = fetch.fetch("http://127.0.0.1:" .. math.tointeger(port2) .. "/",
    {allow_private = true})
  proc.wait(pid2)
  assert(result.ok == true, "redirected fetch should succeed: " .. tostring(result.error))
  assert(result.status == 200, "status should be 200 after redirect")
  assert(result.body == "made it", "body should come from the final URL")
  assert(result.url == final_url,
    "result.url should be the post-redirect URL, got " .. tostring(result.url))
end
test_redirect_followed_reports_final_url()

local function test_opts_table_not_mutated()
  local srv, port = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed")
  local redirect_url = "http://127.0.0.1:" .. math.tointeger(port) .. "/after"
  local pid = proc.fork()
  if pid == 0 then
    for i = 1, 2 do
      local conn = s:accept()
      if conn then
        local c = conn as net.Socket
        read_request(c)
        if i == 1 then
          c:send("HTTP/1.1 303 See Other\r\nLocation: " .. redirect_url
            .. "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        else
          c:send(body_response("200 OK", "done"))
        end
        c:close()
      end
    end
    os.exit(0)
  end
  s:close()
  local headers = {["X-Custom"] = "keep", ["Authorization"] = "Bearer secret"}
  local opts: fetch.Options = {
    allow_private = true,
    method = "POST",
    body = "payload",
    headers = headers,
  }
  local result = fetch.fetch("http://127.0.0.1:" .. math.tointeger(port) .. "/", opts)
  proc.wait(pid)
  assert(result.ok == true, "303-redirected POST should succeed: " .. tostring(result.error))
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
  local result = fetch.fetch("")
  assert(result.ok == false, "result.ok should be false for empty URL")
  assert(result.error == "empty URL", "expected 'empty URL', got: " .. tostring(result.error))
  assert(result.error_kind == nil, "validation failures have no error_kind")
end
test_fetch_empty_url_rejected()

local function test_fetch_unsupported_scheme_rejected()
  local result = fetch.fetch("ftp://example.com/file.txt")
  assert(result.ok == false, "result.ok should be false for ftp scheme")
  assert(result.error:find("unsupported URL scheme") ~= nil,
    "error should mention unsupported scheme, got: " .. tostring(result.error))
end
test_fetch_unsupported_scheme_rejected()

local function test_fetch_file_scheme_rejected()
  local result = fetch.fetch("file:///etc/passwd")
  assert(result.ok == false, "result.ok should be false for file scheme")
  assert(result.error:find("unsupported URL scheme") ~= nil,
    "error should mention unsupported scheme, got: " .. tostring(result.error))
end
test_fetch_file_scheme_rejected()

local function test_fetch_no_scheme_rejected()
  local result = fetch.fetch("example.com/path")
  assert(result.ok == false, "result.ok should be false for no-scheme URL")
  assert(result.error:find("unsupported URL scheme") ~= nil,
    "error should mention unsupported scheme, got: " .. tostring(result.error))
end
test_fetch_no_scheme_rejected()

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

local function test_fetch_with_proxy_nonexistent_socket()
  -- the proxy option is passed through to cosmo.Fetch: a socket path that
  -- doesn't exist produces a connection error
  local result = fetch.fetch("http://example.com", {proxy = "unix:///tmp/nonexistent-cosmic-test.sock"})
  assert(result.ok == false, "result.ok should be false for nonexistent socket")
  assert(result.error ~= nil, "result.error should describe the failure")
end
test_fetch_with_proxy_nonexistent_socket()

local function test_timeout_option_accepted()
  local port, pid = serve({body_response("200 OK", "quick")})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, timeout = 30})
  proc.wait(pid)
  assert(result.ok == true, "fetch with timeout option should succeed: " .. tostring(result.error))
end
test_timeout_option_accepted()
