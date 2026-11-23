--- `cosmic agent worker`: the process that runs cosmic agent's `run` tool. The agent starts one a session, under the
--- sandbox its tools are held to, when the model first calls `run`, and sends it one snippet of Teal after another. It
--- checks each with a checker that lives as long as it does ([`Pipeline.kept_alone`]), so what a snippet lowers of the
--- standard library is not lowered again for the next, and runs the snippet only where the checker passes it: a snippet
--- is checked as `cosmic -e` checks a chunk, and reaches only `cosmic.*`.
---
--- It reads requests, one JSON object a line, on standard input, and answers each with one line on standard output:
---
---     {"id":1,"code":"print(1)"}
---     {"id":1,"ok":true,"output":"1\n"}
---
--- An answer holds the request's `id` and one of:
---
---     "refused": ["run.tl:1:7: ..."]   the checker's lines; the snippet did not run
---     "ok": true, "output": "..."      it ran: what it wrote to standard output and
---                                      standard error, together; "value", the JSON
---                                      of what it returned, where it returned one
---     "ok": false, "output", "error"   it raised `error`, after writing `output`
---     "error": "..."                   the request could not be read
---
--- "output" is at most 64KB, its last part, as UTF-8 (a byte that begins no character is U+FFFD), and "cut": true
--- says where more was written; "value" is at most 64KB of JSON, and a note where it is more. A snippet sets no
--- global, which the checker refuses; what it keeps for the next it writes to a file. It ends at the end of standard
--- input.
---
--- While a snippet runs, each call it makes of the agent ([`cosmic.agent.host`]) goes out as a line too, the request's
--- `id` beside `call` and `args`, and the snippet waits for the next line in: `{"reply":...}`, or `{"failed":"..."}`.

local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Host = require("cosmic.agent.host")
local Json = require("cosmic.json")
local Pipeline = require("build.pipeline")
local String = require("cosmic.string")
local standalone = require("build.standalone")
local sys = require("cosmic.sys")

local record worker
  --- `cosmic agent worker`: answers requests on standard input until it ends. 0 at its end, 1 where it could not start.
  main: function(): integer
end

--- An answer, as it is sent.
local type Answer = {string: Json.Value}

--- What a run within a capture answered, and what it wrote.
local record Ran
  answer: Answer
  output: string
end

--- Where a snippet's output goes while it runs.
local record Capture
  --- Runs `f` with descriptors 1 and 2 pointed at a file: what `f` answered and what was written there.
  run: function(Capture, f: function(): Answer): Ran
end

--- The most bytes of a snippet's output an answer holds, and of the JSON of what it returned: well within the line of
--- 1MB the agent reads an answer in, escaped.
local MAX_OUTPUT <const> = 64 * 1024

--- The name each snippet is checked and run as.
local SNIPPET <const> = "run.tl"

local function failed(id: Json.Value, why: string): Answer
  return { id = id, error = why }
end

--- The last MAX_OUTPUT bytes of `text`, from a character's start, as UTF-8, and whether that is less than all of it.
local function cut(text: string): string, boolean
  if #text <= MAX_OUTPUT then return String.as_utf8(text), false end
  local from = #text - MAX_OUTPUT + 1
  while from <= #text and (text:byte(from) or 0) & 0xC0 == 0x80 do from = from + 1 end
  return String.as_utf8(text:sub(from)), true
end

--- What a snippet returned, as an answer holds it: its JSON where that is within MAX_OUTPUT, else its text, cut.
local function value_of(value: any): Json.Value
  local text, _ = Json.encode_any(value)
  if text ~= nil and #text <= MAX_OUTPUT then
    local decoded, _ = Json.decode(text, { null_value = Json.null })
    if decoded ~= nil then return decoded end
  end
  local shown = String.as_utf8(tostring(value))
  if text ~= nil and #text > MAX_OUTPUT then
    return "(" .. String.counted(#text, "byte") .. " of JSON, more than an answer holds: write it to a file)"
  end
  local most, _ = cut(shown)
  return most
end

--- The lines between the worker and the agent: the requests and the replies to calls come in on `input`, a line each,
--- and the answers and calls go out on `out`.
local record Channel
  input: integer
  out: integer
  --- What was read of `input` past the last line taken.
  mut pending: string
  --- The id of the request whose snippet runs, which each of its calls carries.
  mut id: Json.Value
end

--- The most bytes of a call's line: well within the line of 1MB the agent reads.
local MAX_CALL <const> = 512 * 1024

--- The next line of `channel`'s input, nil at its end.
local function line_of(channel: Channel): string?
  while true do
    local nl = channel.pending:find("\n", 1, true)
    if nl ~= nil then
      local line = channel.pending:sub(1, nl - 1)
      channel.pending = channel.pending:sub(nl + 1)
      return line
    end
    local chunk, _ = Fs.take(channel.input, 65536)
    if chunk == nil or chunk == "" then return nil end
    channel.pending = channel.pending .. chunk
  end
end

--- How a snippet's calls ([`cosmic.agent.host`]) reach the agent on `channel`: a line `{"id":1,"call":"sql",
--- "args":{...}}` out, and the reply, `{"reply":...}` or `{"failed":"..."}`, the next line in.
local function transport_of(channel: Channel): Host.Transport
  return function(name: string, args: Json.Value): (Json.Value) | (nil, Failure)
    local text, why = Json.encode({ id = channel.id, call = name, args = args })
    if text == nil then return nil, Failure.new("host: " .. name .. ": " .. tostring(why)) end
    if #text > MAX_CALL then
      return nil, Failure.new("host: " .. name .. ": the call is " .. String.counted(#text, "byte") ..
          ", more than the " .. String.counted(MAX_CALL, "byte") .. " a call may be")
    end
    local sent, _ = Fs.put(channel.out, text .. "\n")
    if not sent then
      return nil, Failure.new("host: " .. name .. ": the agent cannot be reached")
    end
    local line = line_of(channel)
    if line == nil then return nil, Failure.new("host: " .. name .. ": the agent ended") end
    local reply, reply_why = Json.decode_object(line, { null_value = Json.null })
    if reply == nil then
      return nil, Failure.new("host: " .. name .. ": the agent's reply is no JSON object: " .. tostring(reply_why))
    end
    local trouble = reply["failed"]
    if trouble ~= nil then
      return nil, Failure.new("host: " .. name .. ": " .. tostring(trouble))
    end
    local value = reply["reply"]
    if value == nil then return Json.null end
    return value
  end
end

--- The answer to the request `line` holds, checked by `kept` and run within `capture`, its calls sent on `channel`.
local function answer_to(kept: Pipeline.Kept, capture: Capture, channel: Channel, line: string): Answer
  local request, why = Json.decode_object(line)
  if request == nil then
    return failed(Json.null, "the request is no JSON object: " .. tostring(why))
  end
  local given = request["id"]
  local id: Json.Value = if given == nil then Json.null else given end
  local code = request["code"]
  if not (code is string) then return failed(id, "the request has no code") end
  channel.id = id
  local made = kept:check(code)
  local lua = made.code
  if lua == nil then return { id = id, refused = Json.array(made.lines) } end
  local chunk, load_trouble = standalone.loaded(SNIPPET, lua)
  if chunk == nil then return failed(id, load_trouble) end
  local ran: mut {string: Json.Value} = {}
  local done_run = capture:run(function(): Answer
    local done, value = pcall(function(): any return (chunk()) end)
    if not done then return { ok = false, error = String.as_utf8(tostring(value)) } end
    if value == nil then return { ok = true } end
    return { ok = true, value = value_of(value) }
  end)
  for k, v in pairs(done_run.answer) do ran[k] = v end
  local shown, was_cut = cut(done_run.output)
  ran["id"] = id
  ran["output"] = shown
  if was_cut then ran["cut"] = true end
  return ran
end

--- A capture through a file in `dir`, with `null` the descriptor 0, 1 and 2 point at but while a snippet runs: then 1
--- and 2 are the file, and 0 stays /dev/null, so neither the snippet nor a program it starts reads the requests.
local function capture_in(dir: string, null: integer): Capture
  local path = dir .. "/output"
  return {
    run = function(_self: Capture, f: function(): Answer): Ran
      local fd, why = sys.open(path, sys.O_RDWR | sys.O_CREAT | sys.O_TRUNC, 0x180)
      if fd == nil then
        return { answer = { ok = false, error = "no file for the output: " .. why }, output = "" }
      end
      local _, _ = sys.dup2(fd, 1)
      local _, _ = sys.dup2(fd, 2)
      local answer = f()
      local _, _ = sys.dup2(null, 1)
      local _, _ = sys.dup2(null, 2)
      local _, _ = sys.close(fd)
      -- TODO: bound the file a snippet writes its output to, and read only its last MAX_OUTPUT bytes, once Fs reads a
      -- file's tail: a snippet that prints without end fills the sandbox's /tmp, and the whole is read here.
      local text, _ = Fs.read(path)
      return { answer = answer, output = text or "" }
    end,
  }
end

function worker.main(): integer
  local options, why = Pipeline.alone()
  if options == nil then
    local _, _ = Fs.put(Fs.stderr, "cosmic: agent worker: " .. why .. "\n")
    return 1
  end
  -- The requests come in on a copy of standard input and the answers go out on a copy of standard output; descriptors
  -- 0, 1 and 2 are /dev/null, but 1 and 2 while a snippet runs.
  local input, input_why = sys.dup(0)
  local out, out_why = sys.dup(1)
  local null, null_why = sys.open("/dev/null", sys.O_RDWR)
  -- TODO: remove the directory as a signal ends the worker, once cosmic.signal runs a handler at SIGTERM: the agent
  -- ends it so, and under --sandbox off the directory is the host's.
  local dir, dir_why = Fs.mkdtemp("cosmic-agent-worker-")
  if input == nil or out == nil or null == nil or dir == nil then
    local _, _ = Fs.put(Fs.stderr, "cosmic: agent worker: " .. input_why .. out_why .. null_why .. tostring(dir_why) ..
        "\n")
    return 1
  end
  local _, _ = sys.dup2(null, 0)
  local _, _ = sys.dup2(null, 1)
  local _, _ = sys.dup2(null, 2)
  local capture = capture_in(dir, null)
  local kept = Pipeline.kept_alone(SNIPPET, options)
  local channel: Channel = { input = input, out = out, pending = "", id = Json.null }
  Host.connect(transport_of(channel))
  while true do
    local line = line_of(channel)
    if line == nil then break end
    local answer = answer_to(kept, capture, channel, line)
    local text, encode_why = Json.encode(answer)
    if text == nil then
      local id = answer["id"]
      text = assert(Json.encode(failed(if id == nil then Json.null else id end, tostring(encode_why))))
    end
    -- An answer that cannot go out ends the worker, so the agent reads the end, not a wait.
    local sent, _ = Fs.put(out, text .. "\n")
    if not sent then break end
  end
  local _, _ = Fs.remove_tree(dir)
  return 0
end

return worker
