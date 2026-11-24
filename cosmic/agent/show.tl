--- @public
--- How `cosmic agent` shows an agent's events ([`Agent.Event`]): each a
--- function to set as an agent's `on`, so a program of its own shows them
--- as the verb does, or wraps one to show more.
---
--- [`Show.text`] is the verb's at a terminal: the model's words to one
--- writer, and each tool call, and each that failed, to another.
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
local type Tools = require("cosmic.agent.tools")

local record Show
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

--- What shows the events as `cosmic agent` shows them at a terminal: the
--- model's text to `out`, and to `err` each tool call (its name and
--- [`Show.input`]) and each that failed (its name and the start of what it
--- said). The other events show nothing.
function Show.text(out: function(line: string), err: function(line: string)): function(event: Agent.Event)
  return function(e: Agent.Event)
    if e.kind == "text" then
      out(e.text)
    elseif e.kind == "tool" then
      err(e.name .. " " .. Show.input(e.input))
    elseif e.kind == "result" then
      if e.result.is_error then err(e.name .. " failed: " .. Show.brief(e.result.text)) end
    end
  end
end

--- The JSON object `cosmic agent ask --json` writes for `e`, or nil for one it writes nothing of (text, which the
--- message that holds it carries): `{type = "tool", name, input}`, `{type = "result", name, is_error}`, `{type = "blocked", name, caller, reason}`,
--- `{type = "message", message}`, or `{type = "request", request = {model, status, ms, the token counts, cost}}`.
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
