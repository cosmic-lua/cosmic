--- The failure paths of every curl call core/http.c makes, reached
--- through the checked core's fault points (core/fault.h): each armed
--- point makes its call report a failure of curl's own shape, and the
--- request must answer `nil` and a message naming the call, leave
--- nothing behind -- no transfer, no descriptor, no block on the C heap
--- -- and leave the process-wide state as it found it, so the next
--- request succeeds.
---
--- Only the checked core has fault points, and CI runs this suite on
--- it; any other core has no instrument to arm one with. The case that
--- walks a fault in a fresh process, which starts this program, is in
--- core/fault_tool_test.tl.

local Http = require("cosmic.http")
local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")
local Test = require("cosmic.test")

Test.policy{ requires = { "checked" } }

local url = "http://cosmic.test/"

--- A whole reply: a status line, `head`'s header lines, and `body`.
local function reply(status: string, head: string, body: string): string
  return "HTTP/1.1 " .. status .. "\r\n" .. head .. "Content-Length: " ..
    tostring(#body) .. "\r\nConnection: close\r\n\r\n" .. body
end

--- Reads `response` to its end: the body, or nil and why not.
local function read_all(response: Http.Response): string | nil, string
  local parts: {string} = {}
  while true do
    local chunk, trouble = response:read()
    if chunk == nil then
      if trouble ~= "" then return nil, trouble end
      return table.concat(parts), ""
    end
    parts[#parts + 1] = chunk
  end
end

--- A request that succeeds: nothing a fault did lingers.
local function succeeds(what: string)
  local response, trouble = Http.open(url, { script = { reply("200 OK", "", "hello") },
    headers = { ["X-One"] = "1" } })
  assert(response ~= nil, "after " .. what .. ", a request failed: " .. trouble)
  assert(read_all(response) == "hello", "after " .. what .. ", the body is wrong")
  response:close()
end

--- The descriptor the next open is handed: the lowest free one, so an
--- earlier one left open shows as a higher number.
local function next_descriptor(tmp: string): integer
  local fd = assert(sys.open(tmp .. "/probe", sys.O_CREAT | sys.O_RDWR, 420))
  sys.close(fd)
  return fd
end

--- What a process holds before a fault, to hold it to after.
local record Held
  fd: integer
  bytes: integer
  blocks: integer
end

local function held(tmp: string): Held
  collectgarbage("collect")
  local bytes, blocks = testing.c_heap()
  return { fd = next_descriptor(tmp), bytes = bytes, blocks = blocks }
end

local function assert_released(tmp: string, before: Held, what: string)
  collectgarbage("collect")
  assert(testing.live_transfers() == 0, what .. " left a transfer alive")
  local bytes, blocks = testing.c_heap()
  assert(bytes == before.bytes and blocks == before.blocks,
    what .. " left " .. (blocks - before.blocks) .. " blocks on the C heap")
  local fd = next_descriptor(tmp)
  assert(fd == before.fd, what .. " left descriptor " .. before.fd .. " open")
end

local record Fault
  point: string
  skip: integer
  headers: {string: string}
end

--- Every point `open` passes on a scripted request with a header, the
--- slist append taken twice: once for the header, once for the script's
--- connect-to.
local faults: {Fault} = {
  { point = "curl_easy_init" },
  { point = "curl_easy_setopt(CURLOPT_URL)" },
  { point = "curl_easy_setopt(CURLOPT_ERRORBUFFER)" },
  { point = "curl_easy_setopt(CURLOPT_SSL_CTX_FUNCTION)" },
  { point = "curl_easy_setopt(CURLOPT_POSTFIELDS)" },
  { point = "curl_easy_setopt(CURLOPT_HTTPHEADER)" },
  { point = "curl_easy_setopt(CURLOPT_OPENSOCKETFUNCTION)" },
  { point = "curl_easy_setopt(CURLOPT_CONNECT_TO)" },
  { point = "curl_slist_append" },
  { point = "curl_slist_append", skip = 1 },
  { point = "curl_multi_add_handle" },
  { point = "curl_multi_poll" },
  { point = "curl_multi_perform" },
}

local function test_each_fault_point_in_open_fails_the_request_cleanly(tmp: string)
  succeeds("nothing")
  local before = held(tmp)
  for _, fault in ipairs(faults) do
    local what = fault.point .. " (skipping " .. tostring(fault.skip or 0) .. ")"
    testing.fail_at(fault.point, fault.skip)
    local response, trouble = Http.open(url, { method = "POST", body = "payload",
      headers = { ["X-One"] = "1" }, script = { reply("200 OK", "", "hello") } })
    assert(not testing.fail_at(), what .. " was never reached")
    assert(response == nil, what .. " did not fail the request")
    local call = fault.point:match("^[%w_]+")
    assert(trouble:find(call, 1, true) ~= nil, what .. ": the message does not name " ..
        call .. ": " .. trouble)
    if fault.point:find("(", 1, true) ~= nil then
      local option = fault.point:match("%((.*)%)")
      assert(trouble:find(option, 1, true) ~= nil, what .. ": " .. trouble)
    end
    assert_released(tmp, before, what)
    succeeds(what)
    assert_released(tmp, before, what .. ", then a request")
  end
end

--- A multi call that fails once `open` has returned is `read`'s to
--- report: the body is far larger than one drive moves, so `read` has
--- to drive the transfer again once the buffered part is gone.
local function test_a_fault_point_in_read_fails_the_read_cleanly(tmp: string)
  succeeds("nothing")
  local before = held(tmp)
  local body = string.rep("0123456789abcdef", 256 * 1024)
  for _, point in ipairs({ "curl_multi_poll", "curl_multi_perform" }) do
    local response = assert(Http.open(url, { script = { reply("200 OK", "", body) } }))
    testing.fail_at(point)
    local got, trouble = read_all(response)
    assert(not testing.fail_at(), point .. " was never reached by read")
    assert(got == nil and trouble:find(point, 1, true) ~= nil,
      point .. ": the read did not fail naming it: " .. tostring(trouble))
    response:close()
    assert_released(tmp, before, point .. " in read")
    succeeds(point .. " in read")
  end
end

--- A fault armed at a point no call passes stays armed, and disarming
--- says so; arming a new one replaces it.
local function test_fail_at_reports_a_fault_left_unfired()
  assert(not testing.fail_at(), "nothing armed")
  testing.fail_at("nowhere")
  assert(testing.fail_at("curl_easy_init", 3), "the unfired fault is reported")
  assert(testing.fail_at(), "the replacement is armed")
  assert(not testing.fail_at(), "and disarmed")
  assert(not pcall(testing.fail_at, ""), "an empty point is refused")
  assert(not pcall(testing.fail_at, "curl_easy_init", -1), "a negative skip is refused")
end
