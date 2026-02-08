#!/usr/bin/env cosmic
local sse = require("cosmic.sse")
local fetch = require("cosmic.fetch")

--- Create a mock reader from a string.
local function mock_reader(content: string): fetch.Reader
  local pos = 1
  local is_closed = false

  local reader: fetch.Reader = {}

  function reader:read(): string, string
    if is_closed then
      return nil, "reader closed"
    end
    if pos > #content then
      return nil
    end
    -- return small chunks to test line buffering
    local chunk_size = 16
    local chunk = content:sub(pos, pos + chunk_size - 1)
    pos = pos + chunk_size
    return chunk
  end

  function reader:close(): boolean
    is_closed = true
    return true
  end

  function reader:closed(): boolean
    return is_closed
  end

  function reader:lines(): function(): string
    local buffer = ""
    local done = false

    return function(): string
      while not done do
        local newline_pos = buffer:find("\n")
        if newline_pos then
          local line = buffer:sub(1, newline_pos - 1)
          buffer = buffer:sub(newline_pos + 1)
          return line
        end

        local chunk = self:read()
        if not chunk then
          done = true
          if #buffer > 0 then
            local remaining = buffer
            buffer = ""
            return remaining
          end
          return nil
        end
        buffer = buffer .. chunk
      end
      return nil
    end
  end

  return reader
end

local function test_module_loads()
  assert(sse ~= nil, "sse module should not be nil")
  assert(sse.events ~= nil, "sse.events should not be nil")
  assert(type(sse.events) == "function", "sse.events should be a function")
end
test_module_loads()

local function test_simple_event()
  local reader = mock_reader("data: hello world\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should have 1 event, got: " .. #events_list)
  assert(events_list[1].data == "hello world", "data should be 'hello world', got: " .. events_list[1].data)
  assert(events_list[1].event == "message", "event type should default to 'message', got: " .. tostring(events_list[1].event))
end
test_simple_event()

local function test_event_type()
  local reader = mock_reader("event: custom\ndata: payload\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].event == "custom", "event type should be 'custom', got: " .. tostring(events_list[1].event))
  assert(events_list[1].data == "payload", "data should be 'payload'")
end
test_event_type()

local function test_event_id()
  local reader = mock_reader("id: 123\ndata: test\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].id == "123", "id should be '123', got: " .. tostring(events_list[1].id))
end
test_event_id()

local function test_retry_field()
  local reader = mock_reader("retry: 5000\ndata: test\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].retry == 5000, "retry should be 5000, got: " .. tostring(events_list[1].retry))
end
test_retry_field()

local function test_multiline_data()
  local reader = mock_reader("data: line one\ndata: line two\ndata: line three\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should have 1 event")
  local expected = "line one\nline two\nline three"
  assert(events_list[1].data == expected, "data should be multiline, got: " .. events_list[1].data)
end
test_multiline_data()

local function test_comments_ignored()
  local reader = mock_reader(": this is a comment\ndata: actual data\n: another comment\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].data == "actual data", "comment content should be ignored")
end
test_comments_ignored()

local function test_multiple_events()
  local reader = mock_reader("data: first\n\ndata: second\n\ndata: third\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 3, "should have 3 events, got: " .. #events_list)
  assert(events_list[1].data == "first", "first event data should be 'first'")
  assert(events_list[2].data == "second", "second event data should be 'second'")
  assert(events_list[3].data == "third", "third event data should be 'third'")
end
test_multiple_events()

local function test_crlf_line_endings()
  local reader = mock_reader("data: with crlf\r\n\r\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].data == "with crlf", "should handle CRLF, got: '" .. events_list[1].data .. "'")
end
test_crlf_line_endings()

local function test_field_without_space_after_colon()
  local reader = mock_reader("data:no space\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].data == "no space", "should parse field without space after colon")
end
test_field_without_space_after_colon()

local function test_field_without_value()
  local reader = mock_reader("data\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].data == "", "field without value should have empty string")
end
test_field_without_value()

local function test_unknown_fields_ignored()
  local reader = mock_reader("unknown: value\ndata: test\ncustom: ignored\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].data == "test", "should only parse known fields")
end
test_unknown_fields_ignored()

local function test_invalid_retry_ignored()
  local reader = mock_reader("retry: not-a-number\ndata: test\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].retry == nil, "invalid retry should be nil")
end
test_invalid_retry_ignored()

local function test_id_persists_across_events()
  local reader = mock_reader("id: 100\ndata: first\n\ndata: second\n\nid: 200\ndata: third\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 3, "should have 3 events")
  assert(events_list[1].id == "100", "first event should have id 100")
  assert(events_list[2].id == "100", "second event should inherit id 100")
  assert(events_list[3].id == "200", "third event should have id 200")
end
test_id_persists_across_events()

local function test_empty_stream()
  local reader = mock_reader("")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 0, "empty stream should yield no events")
end
test_empty_stream()

local function test_stream_without_trailing_blank_line()
  local reader = mock_reader("data: final")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should dispatch pending event at stream end")
  assert(events_list[1].data == "final", "data should be 'final'")
end
test_stream_without_trailing_blank_line()

local function test_blank_lines_without_data_ignored()
  local reader = mock_reader("\n\n\ndata: actual\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "blank lines without data should not create events")
  assert(events_list[1].data == "actual", "data should be 'actual'")
end
test_blank_lines_without_data_ignored()

local function test_complete_event_with_all_fields()
  local reader = mock_reader("event: update\nid: 42\nretry: 3000\ndata: line 1\ndata: line 2\n\n")
  local events_list: {sse.Event} = {}

  for event in sse.events(reader) do
    table.insert(events_list, event)
  end

  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].event == "update", "event type should be 'update'")
  assert(events_list[1].id == "42", "id should be '42'")
  assert(events_list[1].retry == 3000, "retry should be 3000")
  assert(events_list[1].data == "line 1\nline 2", "data should be multiline")
end
test_complete_event_with_all_fields()

-- Network test with real SSE endpoint (skip if unavailable)
local function test_real_sse_endpoint()
  local cosmo = require("cosmo")
  if not cosmo.FetchStream then
    io.stderr:write("SKIP: test_real_sse_endpoint (FetchStream not available)\n")
    return
  end

  -- Use httpbin's SSE-like streaming endpoint
  local result = fetch.stream("https://httpbin.org/stream/2")
  if not result.ok then
    io.stderr:write("SKIP: test_real_sse_endpoint (network unavailable)\n")
    return
  end

  -- Note: httpbin/stream returns JSON lines, not SSE format
  -- This test just verifies the integration path works
  result.reader:close()
end
test_real_sse_endpoint()
