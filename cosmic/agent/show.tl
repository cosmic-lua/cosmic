--- @public
--- How `cosmic agent` shows an agent's events ([`Agent.Event`]): each a
--- function to set as an agent's `on`, so a program of its own shows them
--- as the verb does, or wraps one to show more.
---
--- [`Show.text`] is the verb's at a terminal: the turn's answer to one
--- writer, and each tool call, the first lines of what run and bash
--- answered, each call that failed, and what the model says on the way,
--- to another.
--- [`Show.json`] is its `--json` and its rpc: a line of JSON an event.
---
---     local agent = Agent.new({ sign = sign, cwd = cwd })
---     local text = Show.text(print, function(line: string) io.stderr:write(line, "\n") end)
---     agent.on = function(e: Agent.Event)
---       if e.kind == "request" then print("cost", e.request.cost) end
---       text(e)
---     end

local type Agent = require("cosmic.agent")
local Json = require("cosmic.json")
local String = require("cosmic.string")
local Tools = require("cosmic.agent.tools")

local record Show
  --- Lays out a run call's code for showing, or answers nil to show it as the model wrote it. `cosmic agent` gives
  --- the layout `cosmic fix` writes.
  type Arrange = function(code: string): string?
end

--- `text` cut to one line of at most 80 bytes.
---
---     print(Show.brief("one\ntwo")) -- one ...
function Show.brief(text: string): string
  local line = text:gsub("\n.*", " ...")
  if #line > 80 then line = String.cut(line, 77) .. "..." end
  return line
end

--- What a tool call shows of its input, cut by [`Show.brief`]: its shell
--- line or else its path, where it has one, else its JSON.
---
---     print(Show.input({ path = "a.tl", offset = 3 })) -- a.tl
function Show.input(input: Tools.Object): string
  for _, k in ipairs({ "command", "path" }) do
    local v = input[k]
    if v is string then return Show.brief(v) end
  end
  local text, _ = Json.encode(input)
  return Show.brief(text or "")
end

-- At most this many lines show of one call's code, diff or failure.
local MOST_LINES <const> = 12

--- The lines of `text`, a final newline making no empty line.
local function lines_of(text: string): {string}
  local out: mut {string} = {}
  if text == "" then return out end
  for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  if #out > 1 and out[#out] == "" then out[#out] = nil end
  return out
end

--- `line` cut to 120 bytes, its control bytes but tab taken out first: what a file or a program says must not move
--- the terminal's cursor or send it escape sequences.
local function cut(line: string): string
  local plain = line:gsub("[%z\1-\8\11-\31\127]", "")
  if #plain > 120 then return String.cut(plain, 117) .. "..." end
  return plain
end

-- At most this many lines show of what a call answered.
local MOST_ANSWER_LINES <const> = 6

--- `lines` in a Markdown code fence of `info`, each behind `lead`, cut to `most` lines and each line to 120 bytes,
--- to `err`. The fence is a backtick longer than the longest run of backticks in the lines it shows, so no line
--- closes it.
local function fenced(err: function(line: string), info: string, lines: {string}, lead: string, most: integer)
  local shown: mut {string} = {}
  local ticks = 3
  for i, line in ipairs(lines) do
    if i > most then break end
    local one = lead .. cut(line)
    shown[#shown + 1] = one
    for run in one:gmatch("`+") do
      if #run >= ticks then ticks = #run + 1 end
    end
  end
  local fence = string.rep("`", ticks)
  err(fence .. info)
  for _, line in ipairs(shown) do err(line) end
  if #lines > most then err("... " .. String.counted(#lines - most, "more line")) end
  err(fence)
end

--- What an edit changes, as diff lines: the lines of `old` and `new`
--- that differ, after the lines both begin and end with, `-` for those
--- it takes out and `+` for those it puts in, with one line of context on
--- each side.
---
---     for _, l in ipairs(Show.diff("a\nb\nc", "a\nB\nc")) do print(l) end -- " a", "-b", "+B", " c"
function Show.diff(old: string, new: string): {string}
  local a, b = lines_of(old), lines_of(new)
  local head = 0
  while head < #a and head < #b and a[head + 1] == b[head + 1] do head = head + 1 end
  local tail = 0
  while tail < #a - head and tail < #b - head and a[#a - tail] == b[#b - tail] do
    tail = tail + 1
  end
  local out: mut {string} = {}
  for i, line in ipairs(a) do
    if i == head then
      out[#out + 1] = " " .. line
    elseif i > head and i <= #a - tail then
      out[#out + 1] = "-" .. line
    end
  end
  for i, line in ipairs(b) do
    if i > head and i <= #b - tail then out[#out + 1] = "+" .. line end
  end
  for i, line in ipairs(a) do
    if tail > 0 and i == #a - tail + 1 then out[#out + 1] = " " .. line end
  end
  return out
end

--- The lines a tool call shows at a terminal, as Markdown: run's code in a
--- code fence named run, laid out by `layout` where one is given and
--- lays it out; bash's command in one named bash, each line behind "$ ";
--- edit's path, then its changes in one named diff, as [`Show.diff`] lines
--- (each replacement after a line "@@"); a path for read and write, the
--- statement for sql, else the name and [`Show.input`].
---
---     for _, l in ipairs(Show.call("read", { path = "a.tl", offset = 3 })) do print(l) end -- read a.tl, from line 3
function Show.call(name: string, input: Tools.Object, layout?: Show.Arrange): {string}
  local out: mut {string} = {}
  local function put(line: string) out[#out + 1] = line end
  local path = input["path"]
  local code = input["code"]
  local command = input["command"]
  local query = input["query"]
  if name == "run" and code is string then
    local laid = if layout ~= nil then layout(code) else nil end
    fenced(put, "run", lines_of(laid or code), "", MOST_LINES)
  elseif name == "bash" and command is string then
    fenced(put, "bash", lines_of(command), "$ ", MOST_LINES)
  elseif name == "edit" and path is string then
    put("edit " .. path)
    local diff: mut {string} = {}
    local replacements, _ = Tools.replacements(input)
    for _, r in ipairs(replacements or {}) do
      diff[#diff + 1] = "@@"
      for _, line in ipairs(Show.diff(r.old, r.new)) do diff[#diff + 1] = line end
    end
    fenced(put, "diff", diff, "", MOST_LINES)
  elseif name == "write" and path is string then
    local content = input["content"]
    local n = if content is string then #lines_of(content) else 0 end
    put("write " .. path .. " (" .. String.counted(n, "line") .. ")")
  elseif name == "read" and path is string then
    local offset = input["offset"]
    local at = if offset is number then math.tointeger(offset) else nil end
    local from = if at ~= nil then ", from line " .. tostring(at) else "" end
    put("read " .. path .. from)
  elseif name == "sql" and query is string then
    put("sql " .. Show.brief(query))
  else
    put(name .. " " .. Show.input(input))
  end
  return out
end

--- What shows the events as `cosmic agent` shows them at a terminal: the
--- turn's answer to `out`, and to `err` the words the model says on the
--- way (in a message that also calls a tool), each tool call as
--- [`Show.call`] shows it (run's code laid out by `layout`), and below
--- it what the call answered: the first lines of what run or bash said,
--- in a code fence named output, and of what any call that failed said,
--- in one named error. The other events show nothing.
function Show.text(out: function(line: string), err: function(line: string), layout?: Show.Arrange):
    function(event: Agent.Event)
  return function(e: Agent.Event)
    if e.kind == "text" then
      if e.calls == true then err(e.text) else out(e.text) end
    elseif e.kind == "tool" then
      for _, line in ipairs(Show.call(e.name, e.input, layout)) do err(line) end
    elseif e.kind == "result" then
      if e.result.is_error then
        fenced(err, "error", lines_of(e.result.text), "", MOST_LINES)
      elseif e.name == "run" or e.name == "bash" then
        fenced(err, "output", lines_of(e.result.text), "", MOST_ANSWER_LINES)
      end
    end
  end
end

--- The JSON object `cosmic agent ask --json` writes for `e`, or nil for one it writes nothing of (text, which the
--- message that holds it carries): `{type = "tool", name, input}`, `{type = "result", name, is_error}`, `{type = "blocked", name, caller, reason}`,
--- `{type = "message", message}`, or `{type = "request", request = {model, status, ms, the token counts, cost, warm}}`, warm true
--- for a request that asked for no reply ([`Agent.Session.warm`]).
function Show.object(e: Agent.Event): Json.Value?
  if e.kind == "tool" then return { type = "tool", name = e.name, input = e.input } end
  if e.kind == "result" then
    return { type = "result", name = e.name, is_error = e.result.is_error }
  end
  if e.kind == "blocked" then
    return { type = "blocked", name = e.name, caller = e.caller, reason = e.reason }
  end
  if e.kind == "message" then return { type = "message", message = e.message } end
  if e.kind == "request" then
    local q = e.request
    local usage: mut {string: Json.Value} = { model = q.served or q.model, status = q.status, ms = q.ms }
    local function put(k: string, v?: integer)
      if v ~= nil then usage[k] = v end
    end
    put("input_tokens", q.input_tokens)
    put("output_tokens", q.output_tokens)
    put("cache_read", q.cache_read)
    put("cache_write_5m", q.cache_write_5m)
    put("cache_write_1h", q.cache_write_1h)
    local cost = q.cost
    if cost ~= nil then usage["cost"] = cost end
    -- A warm request asks for no reply (Agent.Session.warm).
    if q.max_tokens == 0 then usage["warm"] = true end
    return { type = "request", request = usage }
  end
  return nil
end

--- What writes each event's [`Show.object`] to `out` as a line of JSON.
function Show.json(out: function(line: string)): function(event: Agent.Event)
  return function(e: Agent.Event)
    local object = Show.object(e)
    if object == nil then return end
    local text, why = Json.encode(object)
    out(text or assert(Json.encode({ type = "error", error = tostring(why) })))
  end
end

return Show
