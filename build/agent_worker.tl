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
--- "output" is at most a megabyte, its last part, and "cut": true says where more was written. A snippet sets no
--- global, which the checker refuses; what it keeps for the next it writes to a file. It ends at the end of standard
--- input.

local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Pipeline = require("build.pipeline")
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

--- The most bytes of a snippet's output an answer holds.
local MAX_OUTPUT <const> = 1024 * 1024

--- The name each snippet is checked and run as.
local SNIPPET <const> = "run.tl"

local function failed(id: Json.Value, why: string): Answer
  return { id = id, error = why }
end

--- The last MAX_OUTPUT bytes of `text`, from a character's start, and whether that is less than all of it.
local function cut(text: string): string, boolean
  if #text <= MAX_OUTPUT then return text, false end
  local from = #text - MAX_OUTPUT + 1
  while from <= #text and (text:byte(from) or 0) & 0xC0 == 0x80 do from = from + 1 end
  return text:sub(from), true
end

--- The answer to the request `line` holds, checked by `kept` and run within `capture`.
local function answer_to(kept: Pipeline.Kept, capture: Capture, line: string): Answer
  local request, why = Json.decode_object(line)
  if request == nil then
    return failed(Json.null, "the request is no JSON object: " .. tostring(why))
  end
  local given = request["id"]
  local id: Json.Value = if given == nil then Json.null else given end
  local code = request["code"]
  if not (code is string) then return failed(id, "the request has no code") end
  local made = kept:check(code)
  local lua = made.code
  if lua == nil then return { id = id, refused = Json.array(made.lines) } end
  local chunk, load_trouble = standalone.loaded(SNIPPET, lua)
  if chunk == nil then return failed(id, load_trouble) end
  local ran: mut {string: Json.Value} = {}
  local done_run = capture:run(function(): Answer
    local done, value = pcall(function(): any return (chunk()) end)
    if not done then return { ok = false, error = tostring(value) } end
    if value == nil then return { ok = true } end
    local text, _ = Json.encode_any(value)
    if text == nil then return { ok = true, value = tostring(value) } end
    local decoded, _ = Json.decode(text)
    if decoded == nil then return { ok = true, value = tostring(value) } end
    return { ok = true, value = decoded }
  end)
  for k, v in pairs(done_run.answer) do ran[k] = v end
  local shown, was_cut = cut(done_run.output)
  ran["id"] = id
  ran["output"] = shown
  if was_cut then ran["cut"] = true end
  return ran
end

--- A capture through a file in `dir`, with `null` the descriptor 1 and 2 point at between runs.
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
  -- The answers go out on a copy of standard output; descriptors 1 and 2 point at /dev/null but while a snippet runs.
  local out, out_why = sys.dup(1)
  local null, null_why = sys.open("/dev/null", sys.O_RDWR)
  local dir, dir_why = Fs.mkdtemp("cosmic-agent-worker-")
  if out == nil or null == nil or dir == nil then
    local _, _ = Fs.put(Fs.stderr, "cosmic: agent worker: " .. out_why .. null_why .. tostring(dir_why) .. "\n")
    return 1
  end
  local _, _ = sys.dup2(null, 1)
  local _, _ = sys.dup2(null, 2)
  local capture = capture_in(dir, null)
  local kept = Pipeline.kept_alone(SNIPPET, options)
  local pending = ""
  while true do
    local nl = pending:find("\n", 1, true)
    if nl == nil then
      local chunk, _ = Fs.take(Fs.stdin, 65536)
      if chunk == nil or chunk == "" then break end
      pending = pending .. chunk
    else
      local line = pending:sub(1, nl - 1)
      pending = pending:sub(nl + 1)
      local answer = answer_to(kept, capture, line)
      local text, encode_why = Json.encode(answer)
      if text == nil then
        local id = answer["id"]
        text = assert(Json.encode(failed(if id == nil then Json.null else id end, tostring(encode_why))))
      end
      local _, _ = Fs.put(out, text .. "\n")
    end
  end
  local _, _ = Fs.remove_tree(dir)
  return 0
end

return worker
