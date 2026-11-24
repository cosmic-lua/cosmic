--- [`cosmic.agent.fetch`]: what a snippet's Host.fetch asks for, and how its answer reads, over canned replies.
local AgentFetch = require("cosmic.agent.fetch")

local OK <const> = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nhi"
local MOVED <const> = "HTTP/1.1 302 Found\r\nLocation: http://169.254.169.254/\r\nContent-Length: 0\r\n\r\n"

local function test_a_request_is_answered_and_a_redirect_is_not_followed()
  local got = assert(AgentFetch.fetch({ url = "http://example.com/" }, { script = { OK } }))
  assert(got.status == 200 and got.body == "hi" and got.headers["content-type"] == "text/plain" and not got.cut)
  -- The redirect is answered, not followed: its one canned reply is all the request read.
  local moved = assert(AgentFetch.fetch({ url = "http://example.com/" }, { script = { MOVED, OK } }))
  assert(moved.status == 302 and moved.headers["location"] == "http://169.254.169.254/")
end

local function test_a_body_past_the_most_is_cut()
  local long = string.rep("x", AgentFetch.MOST_BYTES + 10)
  local reply = "HTTP/1.1 200 OK\r\nContent-Length: " .. tostring(#long) .. "\r\n\r\n" .. long
  local got = assert(AgentFetch.fetch({ url = "http://example.com/" }, { script = { reply } }))
  assert(got.cut and #got.body == AgentFetch.MOST_BYTES)
end

local function test_what_no_request_is_made_for()
  for _, url in ipairs({ "file:///etc/passwd", "ftp://example.com/", "example.com" }) do
    local _, why = AgentFetch.fetch({ url = url }, { script = { OK } })
    assert(tostring(why):find("give an http or https URL", 1, true) ~= nil, url .. ": " .. tostring(why))
  end
  local _, slow = AgentFetch.fetch({ url = "http://example.com/", timeout = 1000 }, { script = { OK } })
  assert(tostring(slow):find("give 1 to 120", 1, true) ~= nil, tostring(slow))
end
