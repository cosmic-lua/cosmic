local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")

--- Why the server would not send `reply`, "" where it would.
local function trouble_of(reply: Server.Reply, method?: string): string
  local ok, why = Server.check(reply, method)
  if ok then return "" end
  return tostring(why)
end

local function test_check_accepts_a_reply_the_server_sends()
  assert(trouble_of({ status = 200, body = "hi" }) == "")
  assert(trouble_of({ status = 204 }) == "")
  assert(trouble_of({ status = 200, headers = { ["Set-Cookie"] = { "a=1", "b=2" } }, body = "x" }) == "")
  assert(trouble_of({ status = 200, headers = { ["Content-Length"] = "5" } }, "HEAD") == "")
  assert(trouble_of({ status = 200, body = Stream.from_string("x") }) == "")
end

local function test_check_names_what_the_server_would_refuse()
  assert(trouble_of({ status = 200, body = "hi", length = 5 }):find("Content-Length is 5", 1, true))
  assert(trouble_of({ status = 204, body = "oops" }):find("204", 1, true))
  assert(trouble_of({ status = 200, headers = { ["X-A"] = "a\r\nb" } }):find("CR, LF or NUL", 1, true))
  assert(trouble_of({ status = 200, headers = { Connection = "close" } }):find("writes it itself", 1, true))
  assert(trouble_of({ status = 200, headers = { ["Content-Length"] = "2" } }):find("no body", 1, true))
  assert(trouble_of({ status = 99 }):find("status", 1, true))
end

--- `value`, as a handler that returns what it likes would.
local function unchecked(value: any): Server.Reply
  return value as Server.Reply -- checked: cast_refused
end

local function test_check_reads_what_a_handler_returned_not_only_what_it_declared()
  assert(trouble_of(unchecked({ status = 200, bodyy = "typo" })):find("no field bodyy", 1, true))
  local list = unchecked({ status = 200, headers = { ["Set-Cookie"] = { "a=1", 7 } } }) -- checked: arms_differ
  assert(trouble_of(list):find("strings or lists of them", 1, true))
end

local function test_reason_is_the_phrase_the_server_writes()
  assert(Server.reason(404) == "Not Found" and Server.reason(422) == "Unprocessable Content")
  assert(Server.reason(299) == "")
end
