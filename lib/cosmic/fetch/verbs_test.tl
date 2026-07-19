#!/usr/bin/env cosmic
--- Verb helpers, request-body building, and download, tested against
--- forked loopback echo servers (same pattern as init_test.tl): the
--- server answers with the raw request, so method lines, headers, and
--- bodies can be asserted from the response body.
local fetch = require("cosmic.fetch")
local fs = require("cosmic.fs")
local net = require("cosmic.net")
local proc = require("cosmic.proc")
local check = require("cosmic.check")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

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
--- then exits. A response of "echo" answers 200 with the raw request as
--- the body.
--- @return integer port, integer child pid (caller must proc.wait it)
local function serve(responses: {string}): integer, integer
  local srv, port = net.listen_tcp("127.0.0.1", 0)
  assert(srv ~= nil, "listen_tcp failed")
  local s = srv as net.Socket
  local pid = proc.fork()
  if pid == 0 then
    for _, resp in ipairs(responses) do
      local conn = s:accept()
      if conn is net.Socket then
        local c = conn
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

--- Run one echoed request and return the raw request the server saw.
local function echo_request(run: function(string): fetch.Result): string
  local port, pid = serve({"echo"})
  local r = run("http://127.0.0.1:" .. port)
  proc.wait(math.tointeger(pid))
  assert(r.ok, "request failed: " .. tostring(r.error))
  assert(r:is_success(), "expected 2xx, got " .. tostring(r.status))
  return r.body
end

-- verb tests

local function test_verbs_set_method()
  local req = echo_request(function(base: string): fetch.Result
      return fetch.get(base .. "/x", {allow_private = true})
    end)
  assert(req:find("^GET /x HTTP/1") ~= nil, "expected GET line, got: " .. req:sub(1, 40))

  req = echo_request(function(base: string): fetch.Result
      return fetch.post(base .. "/x", {allow_private = true, body = "hi"})
    end)
  assert(req:find("^POST /x HTTP/1") ~= nil, "expected POST line")
  assert(req:find("\r\n\r\nhi$") ~= nil, "expected body 'hi'")

  req = echo_request(function(base: string): fetch.Result
      return fetch.put(base .. "/x", {allow_private = true, body = "data"})
    end)
  assert(req:find("^PUT /x HTTP/1") ~= nil, "expected PUT line")

  req = echo_request(function(base: string): fetch.Result
      return fetch.delete(base .. "/x", {allow_private = true})
    end)
  assert(req:find("^DELETE /x HTTP/1") ~= nil, "expected DELETE line")
end
test_verbs_set_method()

-- query tests

local function test_query_appended_sorted_and_encoded()
  local req = echo_request(function(base: string): fetch.Result
      return fetch.get(base .. "/s", {allow_private = true, query = {q = "hello world", a = "1"}})
    end)
  assert(req:find("GET /s?a=1&q=hello%20world HTTP", 1, true) ~= nil,
    "expected sorted, percent-encoded query, got: " .. req:sub(1, 60))
end
test_query_appended_sorted_and_encoded()

local function test_query_appends_to_existing()
  local req = echo_request(function(base: string): fetch.Result
      return fetch.get(base .. "/s?x=1", {allow_private = true, query = {y = "2"}})
    end)
  assert(req:find("GET /s?x=1&y=2 HTTP", 1, true) ~= nil, "expected & continuation")
end
test_query_appends_to_existing()

-- json body tests

local function test_json_body_and_default_post()
  local req = echo_request(function(base: string): fetch.Result
      -- No method and no verb helper: a json body must default to POST.
      return fetch.fetch(base .. "/j", {allow_private = true, json = {n = 7}})
    end)
  assert(req:find("^POST /j HTTP/1") ~= nil, "expected POST default for json body")
  assert(req:lower():find("content-type: application/json", 1, true) ~= nil,
    "expected json content type")
  assert(req:find('{"n":7}', 1, true) ~= nil, "expected encoded json body")
end
test_json_body_and_default_post()

local function test_json_respects_caller_content_type()
  local req = echo_request(function(base: string): fetch.Result
      return fetch.post(base .. "/j", {
          allow_private = true,
          json = {n = 1},
          headers = {["content-type"] = "application/vnd.api+json"},
        })
    end)
  assert(req:lower():find("content-type: application/vnd.api+json", 1, true) ~= nil,
    "expected caller content type kept")
  assert(req:lower():find("content-type: application/json\r\n", 1, true) == nil,
    "expected no second content type")
end
test_json_respects_caller_content_type()

-- form body tests

local function test_form_body()
  local req = echo_request(function(base: string): fetch.Result
      return fetch.post(base .. "/f", {allow_private = true, form = {b = "two words", a = "1"}})
    end)
  assert(req:lower():find("content-type: application/x-www-form-urlencoded", 1, true) ~= nil,
    "expected form content type")
  assert(req:find("\r\n\r\na=1&b=two%20words", 1, true) ~= nil, "expected sorted encoded form body")
end
test_form_body()

-- multipart tests

local function test_multipart_body()
  local req = echo_request(function(base: string): fetch.Result
      return fetch.post(base .. "/m", {
          allow_private = true,
          multipart = {
            {name = "field", value = "plain"},
            {name = "up", value = "file-bytes", filename = "a.txt", content_type = "text/plain"},
          },
        })
    end)
  local boundary = req:match("multipart/form%-data; boundary=(%w+)")
  assert(boundary, "expected multipart content type with boundary")
  assert(req:find('Content-Disposition: form-data; name="field"\r\n\r\nplain\r\n', 1, true) ~= nil,
    "expected plain field part")
  assert(req:find('name="up"; filename="a.txt"\r\nContent-Type: text/plain\r\n\r\nfile-bytes\r\n', 1, true) ~= nil,
    "expected file part with content type")
  assert(req:find("--" .. boundary .. "--", 1, true) ~= nil, "expected closing boundary")
end
test_multipart_body()

-- option validation tests

local function test_conflicting_body_options()
  local r = fetch.post("http://127.0.0.1:1/x", {json = {a = 1}, form = {b = "2"}})
  assert(not r.ok, "expected conflicting body options to fail")
  assert(r.error and r.error:find("at most one", 1, true), "expected conflict error, got: " .. tostring(r.error))
end
test_conflicting_body_options()

local function test_multipart_validation()
  local r = fetch.post("http://127.0.0.1:1/x", {multipart = {{name = 'bad"name', value = "v"}}})
  assert(not r.ok and r.error ~= nil, "expected bad multipart name rejected")
end
test_multipart_validation()

-- Result:json() tests

local function test_result_json()
  local port, pid = serve({"HTTP/1.1 200 OK\r\nContent-Length: 15\r\nConnection: close\r\n\r\n{\"answer\": 42}\n"})
  local r = fetch.get("http://127.0.0.1:" .. port, {allow_private = true})
  proc.wait(math.tointeger(pid))
  assert(r.ok, "request failed: " .. tostring(r.error))
  local v = r:json()
  assert((v as {string: any}).answer == 42, "expected decoded json body")
end
test_result_json()

local function test_result_json_bad_body()
  local port, pid = serve({"HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nnot-json"})
  local r = fetch.get("http://127.0.0.1:" .. port, {allow_private = true})
  proc.wait(math.tointeger(pid))
  local v, err = r:json()
  assert(v == nil and err ~= nil, "expected decode failure for bad json")
end
test_result_json_bad_body()

-- download tests

local function test_download_success()
  local path = fs.join(TEST_TMPDIR, "dl.bin")
  local port, pid = serve({"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nfile-content"})
  local r = fetch.download("http://127.0.0.1:" .. port, path, {allow_private = true})
  proc.wait(math.tointeger(pid))
  assert(r.ok and r:is_success(), "download failed: " .. tostring(r.error))
  assert(r.body == "", "expected empty body on download success")
  assert(fs.read(path) == "file-content", "expected file written")
  fs.unlink(path)
end
test_download_success()

local function test_download_non_2xx_writes_nothing()
  local path = fs.join(TEST_TMPDIR, "dl404.bin")
  local port, pid = serve({"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nnot found"})
  local r = fetch.download("http://127.0.0.1:" .. port, path, {allow_private = true})
  proc.wait(math.tointeger(pid))
  assert(r.ok, "expected transport success")
  assert(not r:is_success() and r.status == 404, "expected 404 result")
  assert(r.body == "not found", "expected diagnostic body, got: " .. tostring(r.body))
  assert(not fs.exists(path), "expected no file for non-2xx")
end
test_download_non_2xx_writes_nothing()

local function test_download_transport_failure()
  local path = fs.join(TEST_TMPDIR, "dlfail.bin")
  local r = fetch.download("http://127.0.0.1:1", path, {allow_private = true, timeout = 2})
  assert(not r.ok and r.error ~= nil, "expected connect failure")
  assert(not fs.exists(path), "expected no file on transport failure")
end
test_download_transport_failure()
