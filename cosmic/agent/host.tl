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

return Host
