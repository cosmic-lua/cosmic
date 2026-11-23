--- A streamed reply put back together into the message it streams.

local Json = require("cosmic.json")
local Streamed = require("cosmic.agent.stream")
local Test = require("cosmic.test")

Test.policy{}

local function test_a_streamed_reply_is_put_back_together()
  local function reading(text: string): Streamed.Read
    local left: string? = text
    return function(): string?, string
      local piece = left
      left = nil
      return piece, ""
    end
  end
  local wire = "event: message_start\r\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\"," ..
    "\"usage\":{\"input_tokens\":5}}}\r\n\r\n" ..
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ..
    "event: ping\ndata: {\"type\":\"ping\"}\n\n" ..
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"citations_delta\"," ..
    "\"citation\":{\"cited_text\":\"c\"}}}\n\n" ..
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hé\"}}\n\n" ..
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ..
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ..
    "data: {\"type\":\"message_stop\"}\n\n"
  local deltas = 0
  local m = assert(Streamed.message(reading(wire), function() deltas = deltas + 1 end))
  local text = assert(Json.encode(m))
  assert(deltas == 2 and text == '{"content":[{"citations":[{"cited_text":"c"}],"text":"hé","type":"text"}],' ..
      '"id":"m","stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":2}}', text)
  local failed, why = Streamed.message(reading(wire:sub(1, 200) .. "\n\ndata: {\"type\":\"error\",\"error\":" ..
      "{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"))
  assert(failed == nil and why == "the stream failed: overloaded_error: Overloaded", why)
  -- CRLF split across reads; a last event with no blank line after; a call with no input.
  local crlf = wire:gsub("\n\n", "\r\n\r\n")
  local cr = assert(crlf:find("\r\n\r\n", 100, true))
  local split = { crlf:sub(1, cr), crlf:sub(cr + 1, -3) }
  local at = 0
  local again = assert(Streamed.message(function(): string?, string
    at = at + 1
    return split[at], ""
  end))
  assert(assert(Json.encode(again)) == text, assert(Json.encode(again)))
  local empty = "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1}}}\n\n" ..
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\"," ..
    "\"id\":\"t\",\"name\":\"jobs\",\"input\":{}}}\n\n" ..
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\"}}\n\n" ..
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ..
    "data: {\"type\":\"message_delta\",\"delta\":{},\"usage\":{\"input_tokens\":null,\"output_tokens\":3}}\n\n" ..
    "data: {\"type\":\"message_stop\"}\n\n"
  local called = assert(Json.encode((assert(Streamed.message(reading(empty))))))
  assert(called:find('"input":{}', 1, true) ~= nil and called:find('"input_tokens":1', 1, true) ~= nil, called)
  local cut, cut_why = Streamed.message(reading(wire:sub(1, 300)))
  assert(cut == nil and cut_why:find("ended before its message did", 1, true) ~= nil, cut_why)
end
