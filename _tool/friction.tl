#!/usr/bin/env cosmic
--- Friction indicators from an agent transcript.
---
--- A subagent's transcript is a JSONL file: one event per line, each
--- carrying a `timestamp` and, for a model turn, a `message` whose
--- `content` is a list of blocks (`tool_use`, `tool_result`, text) and
--- whose `usage` counts tokens. `summarize` reads one such file into a
--- `Summary` -- tool calls by name, results that came back as errors,
--- commands run more than once, the index of the first edit, wallclock
--- and token totals -- and `render` prints it as the block the `work`
--- skill's friction log pastes into an entry's "actually happened"
--- part. Nothing here judges: the numbers size a cost, the log names
--- what caused it.
---
---     cosmic _tool/friction.tl TRANSCRIPT...

local fs = require("cosmic.fs")
local json = require("cosmic.json")
local proc = require("cosmic.proc")
local shape = require("cosmic.shape")
local str = require("cosmic.string")
local time = require("cosmic.time")

--- Token counts as the transcript reports them, summed over a file.
local record Usage
  input_tokens: integer
  output_tokens: integer
  cache_read_input_tokens: integer
  cache_creation_input_tokens: integer
end

--- The parts of one tool-call block this module reads.
local record Input
  command: string
  file_path: string
end

--- One content block: a `tool_use`, a `tool_result`, or something else.
local record Block
  type: string
  name: string
  id: string
  input: Input
  tool_use_id: string
  is_error: boolean
  content: any
end

--- The parts of one model message this module reads.
local record Message
  content: any
  usage: Usage
end

--- The parts of one transcript event this module reads. One model
--- response is recorded as several events, one per content block, each
--- carrying the response's `requestId` and the same `usage`; tokens are
--- counted once per request.
local record Event
  timestamp: string
  requestId: string
  message: Message
end

--- One tool call, in transcript order.
local record Call
  --- 1-based position among the file's tool calls.
  index: integer
  name: string
  --- The command's first line, the file path, or "" when neither.
  arg: string
  is_error: boolean
  --- The first 200 bytes of an error result, "" otherwise.
  error_text: string
end

--- What `summarize` measures.
local record Summary
  path: string
  events: integer
  calls: {Call}
  by_name: {string: integer}
  errors: integer
  --- Commands (by `arg`) run more than once, with their counts.
  repeats: {string: integer}
  --- Index of the first Edit or Write call, 0 when there is none.
  first_edit: integer
  first_timestamp: string
  last_timestamp: string
  --- Seconds between the first and last event, -1 when unparseable.
  wall_seconds: integer
  usage: Usage
end

local USAGE < const > = shape.record({
    input_tokens = shape.optional(shape.integer),
    output_tokens = shape.optional(shape.integer),
    cache_read_input_tokens = shape.optional(shape.integer),
    cache_creation_input_tokens = shape.optional(shape.integer),
  })

local EVENT < const > = shape.record({
    timestamp = shape.optional(shape.string),
    message = shape.optional(shape.record({
          content = shape.optional(shape.any),
          usage = shape.optional(USAGE),
        })),
  })

local BLOCKS < const > = shape.list(shape.any)

local BLOCK < const > = shape.record({
    type = shape.optional(shape.string),
    name = shape.optional(shape.string),
    id = shape.optional(shape.string),
    input = shape.optional(shape.record({
          command = shape.optional(shape.string),
          file_path = shape.optional(shape.string),
        })),
    tool_use_id = shape.optional(shape.string),
    is_error = shape.optional(shape.boolean),
    content = shape.optional(shape.any),
  })

--- The transcript's timestamps carry milliseconds; the parser does not.
--- @param stamp string An ISO 8601 timestamp, with or without a fraction
--- @return integer | nil The UNIX time, nil when it does not parse
local function parse_stamp(stamp: string): integer | nil
  local trimmed = stamp:gsub("%.%d+Z$", "Z")
  local ts, _ = time.parse_iso8601(trimmed)
  return ts
end

--- What a tool call is about, in one line.
--- @param block Block A `tool_use` block
--- @return string The command's first line, the file path, or ""
local function call_arg(block: Block): string
  if block.input then
    if block.input.command then
      return str.split(block.input.command, "\n")[1] or ""
    end
    if block.input.file_path then
      return block.input.file_path
    end
  end
  return ""
end

--- The start of an error result's text.
--- @param content any The result's content, a string or a list
--- @return string At most 200 bytes
local function error_text(content: any): string
  local text = ""
  if content is string then
    text = content
  elseif content ~= nil then
    text = json.encode(content) or ""
  end
  return text:sub(1, 200)
end

--- Fold one message's blocks into the summary.
--- @param s Summary The summary being built
--- @param by_id {string: Call} Calls seen so far, by block id
--- @param blocks {any} The message's content blocks
local function fold_blocks(s: Summary, by_id: {string: Call}, blocks: {any})
  for _, raw in ipairs(blocks) do
    local block, _: Block | nil, string = shape.into(raw, BLOCK)
    if block and block.type == "tool_use" then
      local call: Call = {
        index = #s.calls + 1,
        name = block.name or "?",
        arg = call_arg(block),
        is_error = false,
        error_text = "",
      }
      s.calls[#s.calls + 1] = call
      s.by_name[call.name] = (s.by_name[call.name] or 0) + 1
      if block.id then
        by_id[block.id] = call
      end
      if s.first_edit == 0 and (call.name == "Edit" or call.name == "Write") then
        s.first_edit = call.index
      end
    elseif block and block.type == "tool_result" and block.is_error then
      local call = block.tool_use_id and by_id[block.tool_use_id]
      if call then
        call.is_error = true
        call.error_text = error_text(block.content)
        s.errors = s.errors + 1
      end
    end
  end
end

--- Add one usage record's counts to the running total.
--- @param total Usage The running total
--- @param u Usage One message's usage
local function add_usage(total: Usage, u: Usage)
  total.input_tokens = total.input_tokens + (u.input_tokens or 0)
  total.output_tokens = total.output_tokens + (u.output_tokens or 0)
  total.cache_read_input_tokens = total.cache_read_input_tokens
  + (u.cache_read_input_tokens or 0)
  total.cache_creation_input_tokens = total.cache_creation_input_tokens
  + (u.cache_creation_input_tokens or 0)
end

--- Read one transcript into its indicators.
--- @param path string The JSONL transcript
--- @return Summary | nil The indicators, nil when the file cannot be read
--- @return string? Why it could not
local function summarize(path: string): Summary | nil, string
  local body, err = fs.read(path)
  if body == nil then
    return nil, err
  end
  local s: Summary = {
    path = path, events = 0, calls = {}, by_name = {}, errors = 0,
    repeats = {}, first_edit = 0, first_timestamp = "", last_timestamp = "",
    wall_seconds = -1,
    usage = {
      input_tokens = 0, output_tokens = 0,
      cache_read_input_tokens = 0, cache_creation_input_tokens = 0,
    },
  }
  local by_id: {string: Call} = {}
  local seen: {string: integer} = {}
  local counted: {string: boolean} = {}
  for _, line in ipairs(str.lines(body)) do
    if line ~= "" then
      local decoded, _ = json.decode(line)
      local ev, _: Event | nil, string = shape.into(decoded, EVENT)
      if ev then
        s.events = s.events + 1
        if ev.timestamp then
          if s.first_timestamp == "" then
            s.first_timestamp = ev.timestamp
          end
          s.last_timestamp = ev.timestamp
        end
        if ev.message then
          local blocks, _: {any} | nil, string = shape.into(ev.message.content, BLOCKS)
          if blocks then
            fold_blocks(s, by_id, blocks)
          end
          local request = ev.requestId or ""
          if ev.message.usage and not counted[request] then
            counted[request] = request ~= ""
            add_usage(s.usage, ev.message.usage)
          end
        end
      end
    end
  end
  for _, call in ipairs(s.calls) do
    if call.arg ~= "" then
      seen[call.arg] = (seen[call.arg] or 0) + 1
    end
  end
  for key, n in pairs(seen) do
    if n > 1 then
      s.repeats[key] = n
    end
  end
  local first = parse_stamp(s.first_timestamp)
  local last = parse_stamp(s.last_timestamp)
  if first and last then
    s.wall_seconds = last - first
  end
  return s
end

--- The summary as the block a friction entry pastes.
--- @param s Summary The indicators
--- @return string The rendered block, newline-terminated
local function render(s: Summary): string
  local out: {string} = {}
  out[#out + 1] = ("%s: events=%d tool_calls=%d wall=%ds"):format(
    s.path, s.events, #s.calls, s.wall_seconds)
  out[#out + 1] = ("tokens: in=%d out=%d cache_read=%d cache_create=%d"):format(
    s.usage.input_tokens, s.usage.output_tokens,
    s.usage.cache_read_input_tokens, s.usage.cache_creation_input_tokens)
  local names: {string} = {}
  for name in pairs(s.by_name) do
    names[#names + 1] = name
  end
  table.sort(names)
  local parts: {string} = {}
  for _, name in ipairs(names) do
    parts[#parts + 1] = ("%s=%d"):format(name, s.by_name[name])
  end
  out[#out + 1] = "by tool: " .. table.concat(parts, " ")
  out[#out + 1] = ("first edit: %s"):format(
    s.first_edit > 0 and ("call %d"):format(s.first_edit) or "none")
  out[#out + 1] = ("errors (%d):"):format(s.errors)
  for _, call in ipairs(s.calls) do
    if call.is_error then
      out[#out + 1] = ("- %d %s: %s -> %s"):format(
        call.index, call.name, call.arg, call.error_text)
    end
  end
  local keys: {string} = {}
  for key in pairs(s.repeats) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a: string, b: string): boolean
      return s.repeats[a] > s.repeats[b] or (s.repeats[a] == s.repeats[b] and a < b)
    end)
  out[#out + 1] = ("repeated commands (%d):"):format(#keys)
  for _, key in ipairs(keys) do
    out[#out + 1] = ("- x%d %s"):format(s.repeats[key], key)
  end
  return table.concat(out, "\n") .. "\n"
end

--- Summarize every transcript named on the command line.
--- @param ... string Transcript paths
--- @return integer 0 when every file summarized, 1 otherwise
local function main(...: string): integer
  local paths = {...}
  if #paths == 0 then
    io.stderr:write("usage: cosmic _tool/friction.tl TRANSCRIPT...\n")
    return 1
  end
  local status = 0
  for _, path in ipairs(paths) do
    local s, err = summarize(path)
    if s then
      io.write(render(s))
    else
      io.stderr:write(("friction: %s: %s\n"):format(path, err))
      status = 1
    end
  end
  return status
end

local record friction_module
  summarize: function(path: string): Summary | nil, string
  render: function(s: Summary): string
  main: function(...: string): integer
end

local M: friction_module = {
  summarize = summarize,
  render = render,
  main = main,
}

if proc.is_main() then
  os.exit(main(...)) -- exits: a script's process boundary, no caller above main
end

return M
