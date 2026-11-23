--- @public
--- What a snippet that cosmic agent's `run` tool runs asks of the agent itself: the calls the worker cannot make in
--- its sandbox, which the agent answers in its own process. Each call goes out to the agent as a line beside the
--- snippet's answer, and the snippet waits for the reply; the agent checks each call as it checks a tool's input, and
--- answers only what it serves.
---
---     local Host = require("cosmic.agent.host")
---     local rows, why = Host.sql("SELECT tool, count(*) AS n FROM outputs WHERE session = ?1 GROUP BY tool")
---     if rows == nil then error(tostring(why)) end
---     for _, row in ipairs(rows) do print(row["tool"], row["n"]) end
---
--- The MCP servers the agent was given ([`cosmic.agent.mcp`]) are reached the same way: [`Host.servers`] names
--- them, [`Host.tools`] lists a server's tools, and [`Host.mcp`] calls one.
---
---     local result = assert(Host.mcp("notes", "search", { query = "teal" }))
---     print(require("cosmic.json").encode(result["content"]))
---
--- Outside a worker no agent answers, and each call fails so.

local Failure = require("cosmic.failure")
local Json = require("cosmic.json")

local record Host
  --- A row of [`Host.sql`]: each column's name and its cell. An integer or a real is a number, NULL is
  --- [`Json.null`], and a text or a blob is a string, as UTF-8 ([`String.as_utf8`]). Two columns of one name are one:
  --- name each with `AS`.
  type Row = {string: Json.Value}

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
--- named there; `?1` is the session's id), or why there are none. The agent answers at most 512KB of JSON, and a
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

--- The agent's answer to `name` with `args` as a list of objects, or why there is none.
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

--- What the tool `tool` of the MCP server `server` answered `arguments`: its `content` (a list of blocks, a text one
--- `{type = "text", text = ...}`), its `structuredContent` where it gives one, and `isError` true where the tool ran
--- and failed. A call the server refused, or one that got no answer, is a failure. The agent answers at most 512KB.
function Host.mcp(server: string, tool: string, arguments?: {string: Json.Value}): ({string: Json.Value}) | (nil, Failure)
  local answer, why = Host.call("mcp.call", { server = server, tool = tool, arguments = arguments or {} })
  if answer == nil then return nil, why end
  local result, result_why = Json.to_object(answer)
  if result == nil then
    return nil, Failure.new("host: mcp.call: the agent's reply is no object: " .. tostring(result_why))
  end
  return result
end

return Host
