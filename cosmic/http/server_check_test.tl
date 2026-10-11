local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")

local function test_check_accepts_a_reply_the_server_sends()
  assert(Server.check({ status = 200, body = "hi" }) == "")
  assert(Server.check({ status = 204 }) == "")
  assert(Server.check({ status = 200, headers = { ["Set-Cookie"] = { "a=1", "b=2" } }, body = "x" }) == "")
  assert(Server.check({ status = 200, headers = { ["Content-Length"] = "5" } }, "HEAD") == "")
  assert(Server.check({ status = 200, body = Stream.from_string("x") }) == "")
end

local function test_check_names_what_the_server_would_refuse()
  assert(Server.check({ status = 200, body = "hi", length = 5 }):find("Content-Length is 5", 1, true))
  assert(Server.check({ status = 204, body = "oops" }):find("204", 1, true))
  assert(Server.check({ status = 200, headers = { ["X-A"] = "a\r\nb" } }):find("CR, LF or NUL", 1, true))
  assert(Server.check({ status = 200, headers = { Connection = "close" } }):find("writes it itself", 1, true))
  assert(Server.check({ status = 200, headers = { ["Content-Length"] = "2" } }):find("no body", 1, true))
  assert(Server.check({ status = 99 }):find("status", 1, true))
end

--- `value`, as a handler that answers what it likes would.
local function unchecked(value: any): Server.Reply
  return value as Server.Reply
end

local function test_check_reads_what_a_handler_returned_not_only_what_it_declared()
  assert(Server.check(unchecked("a string, not a reply")):find("not a Server.Reply", 1, true))
  assert(Server.check(unchecked({ status = 200, bodyy = "typo" })):find("no field bodyy", 1, true))
  local list = unchecked({ status = 200, headers = { ["Set-Cookie"] = { "a=1", 7 } } })
  assert(Server.check(list):find("strings or lists of them", 1, true))
end

local function test_reason_is_the_phrase_the_server_writes()
  assert(Server.reason(404) == "Not Found" and Server.reason(422) == "Unprocessable Content")
  assert(Server.reason(299) == "")
end
