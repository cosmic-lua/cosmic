--- Fuzz properties for cosmic.sse: the parser must not care where the
--- network cut the bytes, must terminate on arbitrary input, and must
--- read back what format wrote.
--- env: FUZZ_SEED FUZZ_ITERS

local check = require("cosmic.check")
local driver = require("_fuzz.driver")
local source = require("_fuzz.source")
local sse = require("cosmic.sse")
local stream = require("cosmic.stream")

local MAX_EVENTS = 8
local MAX_CHUNKS = 12
local MAX_FIELD_LEN = 24
local TOTALITY_INPUT_LEN = 1024

-- Field bytes that survive the SSE wire form unchanged, so an event
-- built from them round trips: no LF (which would start a new field
-- line), no CR (which the parser strips at a line end), no NUL (which
-- the spec makes the parser ignore in an id:). The colon, the space
-- and the leading-space cases are in here deliberately — format writes
-- "name: value" and the parser strips exactly one leading space, so
-- both survive.
local ROUND_TRIP_BYTES = "abcXY09 \t:;.,-_=+/\\\"'{}[]<>|!@#$%&*()~ data:id:"

-- The chunking-invariance generator is free of that restriction: both
-- sides parse the SAME bytes, so anything format can write is fair
-- game. CR and LF are in the alphabet on purpose — a CR ending one
-- chunk with its LF at the head of the next is exactly the split the
-- property exists to catch.
local CHUNKING_BYTES = ROUND_TRIP_BYTES .. "\r\n\r\n"

--- Draw a random string from an alphabet.
--- @param src source.Recorder The source to draw from
--- @param alphabet string The bytes to draw from
--- @param min_len integer The shortest string to produce
--- @param max_len integer The longest string to produce
--- @return string The generated string
local function random_text(
    src: source.Recorder, alphabet: string, min_len: integer, max_len: integer
  ): string
  local n = src:int(min_len, max_len)
  local out: {string} = {}
  for i = 1, n do
    local at = src:int(1, #alphabet)
    out[i] = alphabet:sub(at, at)
  end
  return table.concat(out)
end

--- Build a random Event over an alphabet.
--- data is always non-empty: an event whose data buffer is empty is a
--- no-op dispatch per spec, so format writes bytes the parser
--- deliberately drops.
--- @param src source.Recorder The source to draw from
--- @param alphabet string The bytes field values are drawn from
--- @return sse.Event The generated event
local function random_event(src: source.Recorder, alphabet: string): sse.Event
  local ev: sse.Event = {
    data = random_text(src, alphabet, 1, MAX_FIELD_LEN),
  }
  if src:int(1, 2) == 1 then
    ev.event = random_text(src, alphabet, 0, 8)
  end
  if src:int(1, 2) == 1 then
    ev.id = random_text(src, alphabet, 0, 8)
  end
  if src:int(1, 3) == 1 then
    ev.retry_ms = src:int(0, 100000)
  end
  return ev
end

--- Partition a byte count into 1..MAX_CHUNKS non-empty pieces.
--- @param src source.Recorder The source to draw from
--- @param total integer The number of bytes to partition
--- @return {integer} The chunk lengths, summing to total
local function random_split(src: source.Recorder, total: integer): {integer}
  if total < 1 then
    return {}
  end
  local wanted = src:int(0, math.min(MAX_CHUNKS - 1, total - 1))
  local used: {integer: boolean} = {}
  local cuts: {integer} = {}
  while #cuts < wanted do
    local cut = src:int(1, total - 1)
    if not used[cut] then
      used[cut] = true
      cuts[#cuts + 1] = cut
    end
  end
  table.sort(cuts)
  local lengths: {integer} = {}
  local prev = 0
  for _, cut in ipairs(cuts) do
    lengths[#lengths + 1] = cut - prev
    prev = cut
  end
  lengths[#lengths + 1] = total - prev
  return lengths
end

--- A Reader that hands back exactly the chunks it was given, in order,
--- then bare nil forever — the wire cut at the boundaries chosen.
--- @param chunks {string} The chunks to serve
--- @return stream.Reader The reader over them
local function chunked_reader(chunks: {string}): stream.Reader
  local at = 0
  local reader = {
    read = function(_self: stream.Reader, _n?: number): string | nil, string
      at = at + 1
      if at > #chunks then
        return nil
      end
      return chunks[at]
    end,
  }
  return reader as stream.Reader -- cast: table implements the Reader interface
end

--- What draining an EventStream produced.
local record Drained
  events: {sse.Event}
  --- Calls to :next(), the terminating one included.
  steps: integer
  --- The message :next() yielded alongside its terminal nil, if any.
  terminal_error: string
  --- True when the step bound was reached before :next() said nil.
  is_bounded: boolean
end

--- Drain an EventStream, refusing to loop past max_steps.
--- @param reader stream.Reader The bytes to parse
--- @param max_steps integer The most :next() calls to make
--- @return Drained What came out
local function drain(reader: stream.Reader, max_steps: integer): Drained
  local events_stream = sse.parse(reader)
  local out: Drained = {events = {}, steps = 0, is_bounded = false}
  for _ = 1, max_steps do
    out.steps = out.steps + 1
    local ev, err = events_stream:next()
    if not ev then
      out.terminal_error = err
      return out
    end
    out.events[#out.events + 1] = ev
  end
  out.is_bounded = true
  return out
end

--- Render an event's fields for a failure message.
--- @param ev sse.Event The event to render
--- @return string The one-line rendering
local function show(ev: sse.Event): string
  return string.format("{data=%q, event=%s, id=%s, retry_ms=%s}",
    ev.data, tostring(ev.event), tostring(ev.id), tostring(ev.retry_ms))
end

--- Compare two parses field by field.
--- @param want {sse.Event} The events the unchunked parse produced
--- @param got {sse.Event} The events the chunked parse produced
--- @return boolean True when the sequences match
--- @return string What differed
local function same_events(want: {sse.Event}, got: {sse.Event}): boolean, string
  if #want ~= #got then
    return false, string.format("event count: whole=%d chunked=%d", #want, #got)
  end
  for i = 1, #want do
    local a, b = want[i], got[i]
    if a.data ~= b.data or a.event ~= b.event
    or a.id ~= b.id or a.retry_ms ~= b.retry_ms then
      return false, string.format("event %d: whole=%s chunked=%s", i, show(a), show(b))
    end
  end
  return true
end

-- The generated input is self-describing, so the base64 in a failure
-- message replays the whole case: a header of comma-separated chunk
-- lengths, then one LF, then the SSE bytes those lengths partition.
-- The header is digits and commas only, so the first LF ends it no
-- matter what the payload holds.
local function gen_chunked_stream(src: source.Recorder): string
  local parts: {string} = {}
  for i = 1, src:int(1, MAX_EVENTS) do
    parts[i] = sse.format(random_event(src, CHUNKING_BYTES))
  end
  local bytes = table.concat(parts)
  local lengths: {string} = {}
  for i, len in ipairs(random_split(src, #bytes)) do
    lengths[i] = tostring(len)
  end
  return table.concat(lengths, ",") .. "\n" .. bytes
end

--- Split a generated input back into its chunk lengths and its bytes.
--- @param input string The generated input
--- @return {string} The chunks, in order
--- @return string The whole byte stream
local function decode_chunked_stream(input: string): {string}, string
  local header_end = input:find("\n", 1, true)
  local header = input:sub(1, header_end - 1)
  local bytes = input:sub(header_end + 1)
  local chunks: {string} = {}
  local at = 1
  for len_text in header:gmatch("[^,]+") do
    local len = math.floor(tonumber(len_text) or 0)
    chunks[#chunks + 1] = bytes:sub(at, at + len - 1)
    at = at + len
  end
  return chunks, bytes
end

local function test_chunking_invariance()
  local ok, msg = driver.run({
      name = "sse_chunking_invariance",
      gen = gen_chunked_stream,
      check = function(input: string): boolean, string
        local chunks, bytes = decode_chunked_stream(input)
        local bound = #bytes + 1
        local whole = drain(stream.new_reader(bytes), bound)
        local split = drain(chunked_reader(chunks), bound)
        if whole.is_bounded or split.is_bounded then
          return false, "draining did not terminate within " .. tostring(bound) .. " steps"
        end
        if whole.terminal_error or split.terminal_error then
          return false, string.format("unexpected terminal error: whole=%s chunked=%s",
            tostring(whole.terminal_error), tostring(split.terminal_error))
        end
        local held, detail = same_events(whole.events, split.events)
        if not held then
          return false, string.format("%s (chunks=%d)", detail, #chunks)
        end
        return true
      end,
    })
  check.truthy(ok, msg)
end
test_chunking_invariance()

local function test_parser_totality()
  local ok, msg = driver.run({
      name = "sse_parser_totality",
      gen = function(src: source.Recorder): string
        return driver.bytes(src, TOTALITY_INPUT_LEN)
      end,
      check = function(input: string): boolean, string
        -- Every dispatched event needs at least its blank line, so one
        -- step per input byte plus the terminating nil is generous. A
        -- parser that yields nothing while consuming nothing runs past
        -- it, which is the unbounded loop this bound exists to catch.
        local bound = #input + 1
        local drained = drain(stream.new_reader(input), bound)
        if drained.is_bounded then
          return false, string.format(
            ":next() ran %d steps over %d bytes without terminating",
            drained.steps, #input)
        end
        return true
      end,
    })
  check.truthy(ok, msg)
end
test_parser_totality()

-- The round-trip domain is exactly the events format can write back:
-- single-line data (multi-line data is valid SSE, but format splits it
-- into one data: line per segment and the parser rejoins them, so only
-- the concatenation survives), no CR (stripped at a line end), no NUL
-- in an id (ignored per spec), and non-empty data (an empty data buffer
-- dispatches nothing). The generator stays inside it; anything outside
-- belongs to the chunking property, which does not compare against a
-- source event.
--- The event the last gen() built. The driver calls gen() and then
--- check() on its output with nothing in between, so the check reads
--- the source event the wire bytes came from.
local pending_event: sse.Event = nil

--- Build a round-trippable event and return its wire form.
--- @param src source.Recorder The source to draw from
--- @return string The bytes format wrote
local function gen_round_trip_wire(src: source.Recorder): string
  pending_event = random_event(src, ROUND_TRIP_BYTES)
  return sse.format(pending_event)
end

local function test_format_parse_round_trip()
  local ok, msg = driver.run({
      name = "sse_format_parse_round_trip",
      gen = gen_round_trip_wire,
      check = function(input: string): boolean, string
        local want = pending_event
        local drained = drain(stream.new_reader(input), #input + 1)
        if drained.is_bounded then
          return false, "draining did not terminate"
        end
        if #drained.events ~= 1 then
          return false, string.format("want 1 event, got %d from %q",
            #drained.events, input)
        end
        local got = drained.events[1]
        -- format omits an event: line for the default type, so a nil
        -- or "message" event reads back as "message" — that IS the
        -- field format wrote.
        local want_event = want.event or "message"
        if got.data ~= want.data or got.event ~= want_event
        or got.id ~= want.id or got.retry_ms ~= want.retry_ms then
          return false, string.format("want %s, got %s", show(want), show(got))
        end
        return true
      end,
    })
  check.truthy(ok, msg)
end
test_format_parse_round_trip()
