--- @public
--- What a snippet that cosmic agent's `run` tool runs asks of the agent itself: the calls the worker cannot make in
--- its sandbox, which the agent makes in its own process. Each call goes out to the agent as a line beside the
--- snippet's own reply, and the snippet waits for the agent's reply; the agent checks each call as it checks a tool's
--- input, and makes only the calls it offers.
---
---     local Host = require("cosmic.agent.host")
---     local rows, why = Host.sql("SELECT tool, count(*) AS n FROM outputs WHERE session = ?1 GROUP BY tool")
---     if rows == nil then error(tostring(why)) end
---     for _, row in ipairs(rows) do print(row["tool"], row["n"]) end
---
--- The MCP servers the agent was given ([`cosmic.agent.mcp`]) are reached the same way. A snippet requires a
--- server's module, whose functions are its tools, typed by their schemas ([`cosmic.agent.mcp_module`]):
---
---     local notes = require("mcp.notes")
---     print(assert(notes.search({ query = "teal" })).text)
---
--- [`Host.declaration`] shows that module's Teal. Beneath it, [`Host.servers`] names the servers, [`Host.tools`]
--- lists a server's tools, and [`Host.mcp`] calls one with any arguments, returning what the server sent.
---
--- Outside a worker no agent replies, and each call fails so.

local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local McpModule = require("cosmic.agent.mcp_module")

local record Host
  --- A row of [`Host.sql`]: each column's name and its cell. An integer or a real is a number, NULL is
  --- [`Json.null`], and a text or a blob is a string, as UTF-8 ([`String.as_utf8`]). Two columns of one name are one:
  --- name each with `AS`.
  type Row = {string: Json.Value}

  --- What a tool of an MCP server responded with, as [`Host.tool`] reads it.
  record Result
    --- The text of its text blocks, one after another, each on lines of its own.
    text: string
    --- Its blocks, as the server gave them: a text one `{type = "text", text = ...}`.
    content: {{string: Json.Value}}
    --- Its `structuredContent`, where it gave one.
    structured?: Json.Value
  end

  --- How a call reaches the agent, and its reply: what the worker connects ([`Host.connect`]).
  type Transport = function(name: string, args: Json.Value): (Json.Value) | (nil, Failure)
end

--- The way calls reach the agent; nil outside a worker.
local transport: Host.Transport? = nil

--- Sends each later call by `through`: the worker calls it before it runs a snippet.
function Host.connect(through: Host.Transport)
  transport = through
end

--- The agent's reply to the call `name` with `args`, or why there is none: no agent, a call it does not serve, or
--- what the call failed with.
function Host.call(name: string, args: Json.Value): (Json.Value) | (nil, Failure)
  local through = transport
  if through == nil then
    return nil, Failure.new("host: no agent answers here: a snippet of cosmic agent's run tool reaches one")
  end
  return through(name, args)
end

--- The rows of one read-only SQLite statement on the agent's sessions.db, as the sql tool runs it (its tables are
--- named there; `?1` is the session's id), or why there are none. The agent replies with at most 512KB of JSON, and a
--- query of more fails: narrow it with LIMIT and OFFSET, or substr() for a long text.
function Host.sql(query: string): ({Host.Row}) | (nil, Failure)
  local answer, why = Host.call("sql", { query = query })
  if answer == nil then return nil, why end
  local list, list_why = Json.to_array(answer)
  if list == nil then
    return nil, Failure.new("host: sql: the agent's reply is no list of rows: " .. tostring(list_why))
  end
  local rows: mut {Host.Row} = {}
  for _, item in ipairs(list) do
    local row, row_why = Json.to_object(item)
    if row == nil then
      return nil, Failure.new("host: sql: a row of the agent's reply is no object: " .. tostring(row_why))
    end
    rows[#rows + 1] = row
  end
  return rows
end

--- The agent's reply to `name` with `args` as a list of objects, or why there is none.
local function objects(name: string, args: Json.Value): ({{string: Json.Value}}) | (nil, Failure)
  local answer, why = Host.call(name, args)
  if answer == nil then return nil, why end
  local list, list_why = Json.to_array(answer)
  if list == nil then
    return nil, Failure.new("host: " .. name .. ": the agent's reply is no list: " .. tostring(list_why))
  end
  local out: mut {{string: Json.Value}} = {}
  for _, item in ipairs(list) do
    local object, object_why = Json.to_object(item)
    if object == nil then
      return nil, Failure.new("host: " .. name .. ": an item of the agent's reply is no object: " .. tostring(object_why))
    end
    out[#out + 1] = object
  end
  return out
end

--- The MCP servers the agent was given: each one's `name`, `reached` ("sandboxed", "unsandboxed" or "http") and
--- `description` where the config gives one. None where it was given none.
function Host.servers(): ({{string: Json.Value}}) | (nil, Failure)
  return objects("mcp.servers", Json.null)
end

--- The tools the MCP server `server` offers, as it lists them: each one's `name`, `description`, `inputSchema` and
--- more. The first call to a server starts it.
function Host.tools(server: string): ({{string: Json.Value}}) | (nil, Failure)
  return objects("mcp.tools", { server = server })
end

--- The response of the tool `tool` of the MCP server `server` to `arguments`: its `content` (a list of blocks, a text
--- one `{type = "text", text = ...}`), its `structuredContent` where it gives one, and `isError` true where the tool
--- ran and failed. A call the server refused, or one that got no response, is a failure. The agent replies with at most
--- 512KB.
function Host.mcp(server: string, tool: string, arguments?: {string: Json.Value}): ({string: Json.Value}) | (nil, Failure)
  local answer, why = Host.call("mcp.call", { server = server, tool = tool, arguments = arguments or {} })
  if answer == nil then return nil, why end
  local result, result_why = Json.to_object(answer)
  if result == nil then
    return nil, Failure.new("host: mcp.call: the agent's reply is no object: " .. tostring(result_why))
  end
  return result
end

--- `value` with each null member taken out, as the client reads a null: absent.
local function without_nulls(value: Json.Value): Json.Value
  local object = Json.object_of(value)
  if object ~= nil and not Json.is_array(object) then
    local out: mut {string: Json.Value} = {}
    for key, member in pairs(object) do
      if member ~= Json.null then out[key] = without_nulls(member) end
    end
    return out
  end
  local list = Json.array_of(value)
  if list ~= nil then
    local out: mut {Json.Value} = {}
    for i, item in ipairs(list) do out[i] = without_nulls(item) end
    return Json.array(out)
  end
  return value
end

--- The response of the tool `tool` of the MCP server `server` to `arguments`, read: the text of its blocks, the blocks,
--- and its `structuredContent`. A tool that ran and failed (`isError`) is a failure, its text the message, as is a call
--- the server refused or one that got no response. The functions of `require("mcp.<server>")` call it
--- ([`cosmic.agent.mcp_module`]).
function Host.tool(server: string, tool: string, arguments?: {string: Json.Value}): (Host.Result) | (nil, Failure)
  local answer, why = Host.mcp(server, tool, arguments)
  if answer == nil then return nil, why end
  local content: mut {{string: Json.Value}} = {}
  local texts: mut {string} = {}
  for _, item in ipairs(Json.array_of(answer["content"]) or {}) do
    local block = Json.object_of(item)
    if block ~= nil then
      content[#content + 1] = block
      local text = block["text"]
      if block["type"] == "text" and text is string then texts[#texts + 1] = text end
    end
  end
  local text = table.concat(texts, "\n")
  if answer["isError"] == true then
    return nil, Failure.new("mcp: " .. server .. "." .. tool .. ": " .. (if text ~= "" then text else "the tool failed" end))
  end
  local structured = answer["structuredContent"]
  if structured == nil then return { text = text, content = content } end
  return { text = text, content = content, structured = without_nulls(structured) }
end

--- The `structuredContent` of the response of the tool `tool` of the MCP server `server` to `arguments`, its null
--- members taken out, as [`Host.tool`] calls it: for a tool that lists an `outputSchema`, which the client holds its
--- response to. A response with none is a failure.
function Host.structured(server: string, tool: string, arguments?: {string: Json.Value}): (Json.Value) | (nil, Failure)
  local result, why = Host.tool(server, tool, arguments)
  if result == nil then return nil, why end
  local structured = result.structured
  if structured == nil then
    return nil, Failure.new("mcp: " .. server .. "." .. tool .. ": the tool answered no structuredContent")
  end
  return structured
end

--- The Teal of `require("mcp." .. server)`: the records and functions a snippet calls the server's tools by
--- ([`cosmic.agent.mcp_module`]), or why there is none.
function Host.declaration(server: string): (string) | (nil, Failure)
  local tools, why = Host.tools(server)
  if tools == nil then return nil, why end
  return McpModule.made(server, tools).teal
end

return Host
