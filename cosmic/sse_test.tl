#!/usr/bin/env cosmic
local check = require("cosmic.check")
local sse = require("cosmic.sse")
local fetch = require("cosmic.fetch")

--- Create a mock reader over a string. When fail_with is given, read()
--- returns nil, fail_with after the content is consumed — a mid-stream
--- transport failure — instead of a clean EOF.
local function mock_reader(content: string, fail_with?: string): fetch.Body
  local pos = 1
  local is_closed = false
  local failed = false

  local reader: fetch.Body = {}

  function reader:read(_n?: integer): string | nil, string
    if is_closed then
      return nil, "reader closed"
    end
    if pos > #content then
      if fail_with and not failed then
        failed = true
        return nil, fail_with
      end
      return nil
    end
    -- return small chunks to test line buffering
    local chunk_size = 16
    local chunk = content:sub(pos, pos + chunk_size - 1)
    pos = pos + chunk_size
    return chunk
  end

  function reader:close(): boolean, string
    is_closed = true
    return true
  end

  function reader:closed(): boolean
    return is_closed
  end

  function reader:lines(): function(): string | nil, string
    local buffer = ""
    local done = false

    return function(): string | nil, string
      if done then
        return nil
      end
      while true do
        local newline_pos = buffer:find("\n")
        if newline_pos then
          local line = buffer:sub(1, newline_pos - 1)
          buffer = buffer:sub(newline_pos + 1)
          return line
        end

        local chunk, err = self:read()
        if err then
          done = true
          return nil, err
        end
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
    end
  end

  return reader
end

--- Collect every event; return the events, the terminal error (if any),
--- and the stream's final last_event_id.
local function collect(content: string, fail_with?: string): {sse.Event}, string, string | nil
  local stream = sse.parse(mock_reader(content, fail_with))
  local events_list: {sse.Event} = {}
  local terminal_err: string
  while true do
    local event, err = stream:next()
    if not event then
      terminal_err = err
      break
    end
    table.insert(events_list, event)
  end
  return events_list, terminal_err, stream:last_event_id()
end

local function test_module_loads()
  assert(sse ~= nil, "sse module should not be nil")
  assert(type(sse.parse) == "function", "sse.parse should be a function")
  assert(type(sse.format) == "function", "sse.format should be a function")
end
test_module_loads()

local function test_simple_event()
  local events_list = collect("data: hello world\n\n")
  assert(#events_list == 1, "should have 1 event, got: " .. #events_list)
  assert(events_list[1].data == "hello world", "data should be 'hello world', got: " .. events_list[1].data)
  assert(events_list[1].event == "message", "event type should default to 'message', got: " .. tostring(events_list[1].event))
end
test_simple_event()

local function test_event_type()
  local events_list = collect("event: custom\ndata: payload\n\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].event == "custom", "event type should be 'custom', got: " .. tostring(events_list[1].event))
  assert(events_list[1].data == "payload", "data should be 'payload'")
end
test_event_type()

local function test_event_id()

  -- The honest-nil contract: before any id: line arrives, last_event_id
  -- is bare nil, and its declared type says so (string | nil) — code
  -- concatenating it unguarded should fail the checker, not crash at
  -- runtime on an id-less stream.
  local function test_last_event_id_nil_before_any_id()
    local _events, _err, last = collect("data: no ids here\n\n")
    assert(last == nil, "no id: line seen, last_event_id must return nil")
  end
  test_last_event_id_nil_before_any_id()
  local events_list = collect("id: 123\ndata: test\n\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].id == "123", "id should be '123', got: " .. tostring(events_list[1].id))
end
test_event_id()

local function test_retry_field()
  local events_list = collect("retry: 5000\ndata: test\n\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].retry_ms == 5000, "retry should be 5000, got: " .. tostring(events_list[1].retry_ms))
end
test_retry_field()

local function test_multiline_data()
  local events_list = collect("data: line one\ndata: line two\ndata: line three\n\n")
  assert(#events_list == 1, "should have 1 event")
  local expected = "line one\nline two\nline three"
  assert(events_list[1].data == expected, "data should be multiline, got: " .. events_list[1].data)
end
test_multiline_data()

local function test_comments_ignored()
  local events_list = collect(": this is a comment\ndata: actual data\n: another comment\n\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].data == "actual data", "comment content should be ignored")
end
test_comments_ignored()

local function test_multiple_events()
  local events_list = collect("data: first\n\ndata: second\n\ndata: third\n\n")
  assert(#events_list == 3, "should have 3 events, got: " .. #events_list)
  assert(events_list[1].data == "first", "first event data should be 'first'")
  assert(events_list[2].data == "second", "second event data should be 'second'")
  assert(events_list[3].data == "third", "third event data should be 'third'")
end
test_multiple_events()

local function test_crlf_line_endings()
  local events_list = collect("data: with crlf\r\n\r\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].data == "with crlf", "should handle CRLF, got: '" .. events_list[1].data .. "'")
end
test_crlf_line_endings()

local function test_field_without_space_after_colon()
  local events_list = collect("data:no space\n\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].data == "no space", "should parse field without space after colon")
end
test_field_without_space_after_colon()

local function test_lone_data_field_not_dispatched()
  -- "data" alone leaves the data buffer empty at the blank line; the spec
  -- resets the buffers and dispatches nothing.
  local events_list = collect("data\n\n")
  assert(#events_list == 0, "empty-data event must not dispatch, got: " .. #events_list)
end
test_lone_data_field_not_dispatched()

local function test_two_empty_data_lines_dispatch_newline()
  -- two empty data lines join to "\n", which is non-empty and dispatches
  local events_list = collect("data\ndata\n\n")
  assert(#events_list == 1, "should have 1 event, got: " .. #events_list)
  assert(events_list[1].data == "\n", "data should be a single newline")
end
test_two_empty_data_lines_dispatch_newline()

local function test_empty_data_dispatch_resets_event_type()
  -- an event type buffered before an empty-data dispatch must not leak
  -- into the next event
  local events_list = collect("event: custom\n\ndata: hi\n\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].event == "message",
    "event type must reset on empty-data dispatch, got: " .. tostring(events_list[1].event))
end
test_empty_data_dispatch_resets_event_type()

local function test_empty_data_dispatch_resets_retry()
  -- a retry buffered before an empty-data dispatch (which discards the
  -- whole block, undispatched) must not leak into the next event
  local events_list = collect("retry: 5000\n\ndata: hi\n\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].retry_ms == nil,
    "retry must reset on empty-data dispatch, got: " .. tostring(events_list[1].retry_ms))
end
test_empty_data_dispatch_resets_retry()

local function test_unknown_fields_ignored()
  local events_list = collect("unknown: value\ndata: test\ncustom: ignored\n\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].data == "test", "should only parse known fields")
end
test_unknown_fields_ignored()

local function test_invalid_retry_ignored()
  local events_list = collect("retry: not-a-number\ndata: test\n\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].retry_ms == nil, "invalid retry should be nil")
end
test_invalid_retry_ignored()

local function test_retry_digits_only()
  -- "3000ms" is not digits-only; tonumber-style prefixes must not pass
  local events_list = collect("retry: 3000ms\ndata: a\n\nretry: 0x10\ndata: b\n\n")
  assert(#events_list == 2, "should have 2 events")
  assert(events_list[1].retry_ms == nil, "'3000ms' must be ignored")
  assert(events_list[2].retry_ms == nil, "'0x10' must be ignored")
end
test_retry_digits_only()

local function test_id_persists_across_events()
  local events_list = collect("id: 100\ndata: first\n\ndata: second\n\nid: 200\ndata: third\n\n")
  assert(#events_list == 3, "should have 3 events")
  assert(events_list[1].id == "100", "first event should have id 100")
  assert(events_list[2].id == "100", "second event should inherit id 100")
  assert(events_list[3].id == "200", "third event should have id 200")
end
test_id_persists_across_events()

local function test_last_event_id_updates_on_sight()
  -- id: takes effect as soon as the line is seen, even when no event is
  -- ever dispatched — that is what reconnection needs
  local events_list, err, last_id = collect("id: 42\n: comment\n\n")
  assert(#events_list == 0, "no events expected")
  assert(err == nil, "no error expected")
  assert(last_id == "42", "last_event_id must update on sight of id:, got " .. tostring(last_id))
end
test_last_event_id_updates_on_sight()

local function test_id_with_nul_ignored()
  local events_list, _, last_id = collect("id: bad\0id\ndata: x\n\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].id == nil, "an id containing NUL is ignored")
  assert(last_id == nil, "last_event_id must not pick up a NUL id")
end
test_id_with_nul_ignored()

local function test_empty_stream()
  local events_list = collect("")
  assert(#events_list == 0, "empty stream should yield no events")
end
test_empty_stream()

local function test_unterminated_event_discarded_at_eof()
  -- an event without its terminating blank line may be truncated
  -- mid-field; the spec discards it rather than dispatching it
  local events_list = collect("data: final")
  assert(#events_list == 0,
    "unterminated event must be discarded at EOF, got: " .. #events_list)
end
test_unterminated_event_discarded_at_eof()

local function test_blank_lines_without_data_ignored()
  local events_list = collect("\n\n\ndata: actual\n\n")
  assert(#events_list == 1, "blank lines without data should not create events")
  assert(events_list[1].data == "actual", "data should be 'actual'")
end
test_blank_lines_without_data_ignored()

local function test_complete_event_with_all_fields()
  local events_list = collect("event: update\nid: 42\nretry: 3000\ndata: line 1\ndata: line 2\n\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].event == "update", "event type should be 'update'")
  assert(events_list[1].id == "42", "id should be '42'")
  assert(events_list[1].retry_ms == 3000, "retry should be 3000")
  assert(events_list[1].data == "line 1\nline 2", "data should be multiline")
end
test_complete_event_with_all_fields()

local function test_comments_only()
  local events_list = collect(": comment1\n: comment2\n\n")
  assert(#events_list == 0, "comments-only stream should yield no events, got: " .. #events_list)
end
test_comments_only()

local function test_binary_input()
  -- Binary bytes in data field: parser should not crash
  local events_list = collect("data: \x01\x02\xff\xfe\n\n")
  assert(#events_list == 1, "binary input should yield one event, got: " .. #events_list)
end
test_binary_input()

local function test_utf8_data()
  local events_list = collect("data: héllo wörld\n\n")
  assert(#events_list == 1, "should have 1 event")
  assert(events_list[1].data == "héllo wörld", "UTF-8 data should pass through unchanged, got: " .. events_list[1].data)
end
test_utf8_data()

local function test_read_error_propagates()
  -- TDD: a reader whose read() errors after one chunk
  -- must surface nil, "connection reset" — not a clean nil
  local events_list, err = collect("data: one\n\n", "connection reset")
  assert(#events_list == 1, "the complete event still arrives")
  assert(events_list[1].data == "one", "first event data intact")
  assert(err == "connection reset",
    "the iterator must yield the transport error, got: " .. tostring(err))
end
test_read_error_propagates()

local function test_read_error_then_iterator_exhausted()
  local stream = sse.parse(mock_reader("data: one\n\n", "boom"))
  local first = check.must(stream:next())
  assert(first.data == "one", "first event expected")
  local second, err = stream:next()
  assert(second == nil and err == "boom", "error must be yielded once")
  local third, err3 = stream:next()
  assert(third == nil and err3 == nil, "after the error the iterator returns plain nil")
end
test_read_error_then_iterator_exhausted()

local function test_stream_loops_with_positive_branch()
  -- The documented loop shape: the POSITIVE branch narrows the yield
  -- past nil (a guard before a break does not survive the flow join).
  local stream = sse.parse(mock_reader("data: a\n\ndata: b\n\n"))
  local seen: {string} = {}
  while true do
    local event = stream:next()
    if event then
      table.insert(seen, event.data)
    else
      break
    end
  end
  assert(#seen == 2 and seen[1] == "a" and seen[2] == "b",
    "the positive-branch loop must see both events")
end
test_stream_loops_with_positive_branch()

local function test_error_discards_partial_event()
  -- data buffered before the failure belongs to an unterminated event;
  -- it must be discarded, not dispatched as if complete
  local events_list, err = collect("data: complete\n\ndata: doomed\n", "reset")
  assert(#events_list == 1, "only the terminated event arrives, got: " .. #events_list)
  assert(events_list[1].data == "complete", "the terminated event is intact")
  assert(err == "reset", "the failure is reported")
end
test_error_discards_partial_event()

local function test_events_from_socket_backed_reader()
  -- The stream contract: sse consumes ANY stream.Reader, not just
  -- fetch.Body — here a socket wrapped as an fd Handle.
  local net = require("cosmic.net")
  local fd = require("cosmic.fd")

  local sp = check.must(net.socket_pair())
  local a, b = sp.a, sp.b

  assert(a:send("data: from a socket\n\nevent: ping\ndata: second\n\n"))
  assert(a:close())

  local stream_events = sse.parse(fd.wrap(b:fd()))
  local ev1 = check.must(stream_events:next())
  assert(ev1.data == "from a socket", "first event data: " .. tostring(ev1.data))
  assert(ev1.event == "message", "default event type")
  local ev2 = check.must(stream_events:next())
  assert(ev2.data == "second", "second event data: " .. tostring(ev2.data))
  assert(ev2.event == "ping", "explicit event type")
  local done, derr = stream_events:next()
  assert(done == nil and derr == nil, "clean close ends the stream")
  assert(b:close())
end
test_events_from_socket_backed_reader()

-- format: the serializing half (D20 rule 6 — a pair ships both halves).
local function test_format_roundtrip()
  local ev: sse.Event = {data = "line1\nline2", event = "update", id = "7", retry_ms = 250}
  local wire = sse.format(ev)
  local back = check.must(sse.parse(mock_reader(wire)):next())
  assert(back.data == ev.data, "data round-trips, got: " .. back.data)
  assert(back.event == "update", "event type round-trips")
  assert(back.id == "7", "id round-trips")
  assert(back.retry_ms == 250, "retry_ms round-trips")
end
test_format_roundtrip()

local function test_format_minimal_event()
  local wire = sse.format({data = "hi"} as sse.Event) -- cast: partial literal
  assert(wire == "data: hi\n\n", "minimal event is one data line + blank, got: " .. wire)
end
test_format_minimal_event()
