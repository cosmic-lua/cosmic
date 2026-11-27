--- @public
--- What a snippet that cosmic agent's `run` tool runs asks of the agent itself: the calls the worker cannot make in
--- its sandbox, which the agent serves in its own process. Each call goes out to the agent as a line beside the
--- worker's response line, and the snippet waits for the reply; the agent checks each call as it checks a tool's input, and
--- serves only what it offers.
---
--- [`Host.call`] returns a failure. [`Host.describe`], [`Host.declaration`], [`Host.modules`] and [`Host.docs`]
--- return a plain string to print, which says why where they fail. [`Host.sort`] and [`Host.sort_by`] raise what
--- `by` raised, as it is, and [`Host.uniq`] and [`Host.top`] do not fail. Every other call raises where it fails:
--- its message begins "host:", or "mcp: <server>.<tool>:" for an MCP tool that failed or gave no
--- `structuredContent`. So a snippet reads its value with no assert:
---
---     local Host = require("cosmic.agent.host")
---     local rows = Host.history("SELECT tool, count(*) AS n FROM outputs WHERE session = ?1 GROUP BY tool")
---     for _, row in ipairs(rows) do print(row["tool"], row["n"]) end
---
--- The MCP servers the agent was given ([`cosmic.agent.mcp`]) are reached the same way. A snippet requires a
--- server's module, whose functions are its tools, typed by their schemas ([`cosmic.agent.mcp_module`]):
---
---     local notes = require("mcp.notes")
---     print(notes.search({ query = "teal" }).text)
---
--- [`Host.search`] finds the tools that fit a task across every server, ranked, and [`Host.describe`] shows the Teal of
--- one, so a snippet reads what it needs rather than every server's module:
---
---     local Host = require("cosmic.agent.host")
---     for _, found in ipairs(Host.search("open issues").found) do print(found.server, found.name, found.about) end
---     print(Host.describe("github", "list_issues"))
---
--- [`Host.declaration`] shows a whole module's Teal. Beneath it, [`Host.servers`] names the servers, [`Host.tools`]
--- lists a server's tools, and [`Host.mcp`] calls one with any arguments, returning what the server sent.
---
--- [`Host.modules`] lists the modules a snippet may require, and [`Host.docs`] prints the docs of one, or of a
--- function, as `cosmic docs` does: both read this binary's docs, with no call to the agent.
---
--- [`Host.store`] keeps a small value for a later snippet of the session, which [`Host.load`] reads, as a file would, but
--- with the session: a resumed session reads it again.
---
--- With commands (--commands), a program runs too, in the snippet's sandbox, with a result a snippet reads as a value:
--- [`Host.bash`] runs a command and returns its output and how it ended:
---
---     local ran = Host.bash("git status --short")
---     for line in ran.output:gmatch("[^\n]+") do print(line) end
---
--- Calls made from tasks of one run ([`Poll.run`]) are out at once, and the agent serves each as it can, so calls that
--- wait on a server overlap:
---
---     local got: {integer: string} = {}
---     Poll.run(function()
---       for i = 1, 3 do local _ = Poll.spawn(function() got[i] = notes.get({ id = i }).text end) end
---     end)
---
--- The helpers named after commands ([`Host.find`], [`Host.grep`], [`Host.sed`], [`Host.wc`], [`Host.sort`],
--- [`Host.sqlite`], ...) are [`cosmic.shell`]'s calls, run in the snippet's own process, raising where they fail.
--- A file is read with [`Host.read`] and changed with [`Host.edit`] (exact text), [`Host.sed`] (a pattern on each line)
--- or [`Host.write`] (the whole of it).
---
--- Outside a worker no agent replies, and each call raises so.

local AgentEdit = require("cosmic.agent.edit")
local AgentFetch = require("cosmic.agent.fetch")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local type Doc = require("cosmic.doc")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Shell = require("cosmic.shell")
local Json = require("cosmic.json")
local McpModule = require("cosmic.agent.mcp_module")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")

local record Host
  --- A row of [`Host.history`]: each column's name and its cell. An integer or a real is a number, NULL is
  --- [`Json.null`], and a text or a blob is a string, as UTF-8 ([`String.as_utf8`]). Two columns of one name are one:
  --- name each with `AS`.
  type Row = {string: Json.Value}

  --- What an MCP server replied for a call of one of its tools, as [`Host.tool`] reads it.
  record Result
    --- The text of its text blocks, one after another, each on lines of its own.
    text: string
    --- Its blocks, as the server gave them: a text one `{type = "text", text = ...}`.
    content: {{string: Json.Value}}
    --- Its `structuredContent`, where it gave one.
    structured?: Json.Value
  end

  --- A tool [`Host.search`] found.
  record Found
    --- The MCP server it is a tool of: `require("mcp." .. server)`.
    server: string
    --- Its name in that module.
    name: string
    --- Its name as the server lists it, which [`Host.describe`] and [`Host.mcp`] take.
    tool: string
    --- The start of its description, on one line.
    about: string
    --- The Teal of its function, with the records it takes and returns ([`Host.describe`]).
    teal: string
  end

  --- What [`Host.load`] read.
  record Loaded
    --- What was kept: nil for nothing.
    value?: Json.Value
  end

  --- How [`Host.bash`] runs a command.
  record BashOptions
    --- The most seconds it may run, 1 to 24 days; nil for no limit but the snippet's own.
    timeout?: integer
  end

  --- How [`Host.fetch`] makes a request.
  record FetchOptions
    --- The method: GET by default, POST where there is a body.
    method?: string
    --- Request headers, name to value.
    headers?: {string: string}
    --- The request body.
    body?: string
    --- The most seconds it may take: 30 by default, at most 120.
    timeout?: integer
    --- Whether a status of 400 or more is returned as a value, in place of raising.
    any_status?: boolean
  end

  --- What [`Host.fetch`] got back.
  record Fetched
    --- The HTTP status: a redirect's too, which is not followed.
    status: integer
    --- The headers, keyed by lower-case name (`location` for a redirect).
    headers: {string: string}
    --- The body, its bytes as sent.
    body: string
    --- Whether the body was longer than 384KB, and cut there.
    cut: boolean
  end

  --- What a command of [`Host.bash`] did.
  record Ran
    --- What it wrote to standard output and standard error, as UTF-8: its last 16MB where it wrote more.
    output: string
    --- Whether it wrote more than `output` holds, so that its start was let go.
    cut: boolean
    --- Its exit status; nil where a signal ended it.
    code?: integer
    --- The signal that ended it; nil where it exited.
    signal?: integer
    --- Whether it exited 0, in its time.
    ok: boolean
    --- Whether it ran past its timeout, and was ended for it.
    timed_out: boolean
  end

  --- A line [`Host.grep`] found ([`Shell.Hit`]).
  --- One replacement of [`Host.edit`]: `old`, which the file holds once, becomes `new`.
  type Replacement = AgentEdit.Replacement

  type Hit = Shell.Hit

  --- A key and how often it was counted, as [`Host.top`] lists it ([`Shell.Count`]).
  type Count = Shell.Count

  --- What [`Host.search`] found.
  record Searched
    --- The tools that fit, best first.
    found: {Found}
    --- Each server that could not list its tools, and why: its tools are not among those found.
    skipped: {string}
  end

  --- What [`Host.search`] looks in, and how much it returns.
  record SearchOptions
    --- The one server to search; nil for every server.
    server?: string
    --- The most tools it returns, 1 or more: 8 by default.
    limit?: integer
  end

  --- How a call reaches the agent, and its reply: what the worker connects ([`Host.connect`]).
  type Transport = function(name: string, args: Json.Value): (Json.Value) | (nil, Failure)

  --- A change Host.edit or Host.write made to the file `path`: the replacements of an edit, or the lines a write wrote.
  --- It is for a person to see what a snippet changed, not a record of every write: a snippet writes with Fs too.
  record Change
    --- The file, as the snippet named it.
    path: string
    --- An edit's replacements; nil for a write.
    edits?: {Replacement}
    --- How many lines a write wrote; nil for an edit.
    lines?: integer
  end

  --- What hears each change ([`Host.connect`]).
  type Noted = function(change: Host.Change)

  --- What checks the Teal text of a file: the checker's lines, none where it passes ([`Host.connect`]).
  type Checks = function(path: string, text: string): {string}
end

--- The way calls reach the agent; nil outside a worker.
local transport: Host.Transport? = nil

--- What hears each change Host.edit and Host.write make; nil outside a worker.
local noted: Host.Noted? = nil

--- What checks a file's text; nil outside a worker.
local checks: Host.Checks? = nil

--- Sends each later call by `through`, tells `changes` each file Host.edit and Host.write change, and checks a file
--- for [`Host.check`] by `check`: the worker calls it before it runs a snippet.
function Host.connect(through: Host.Transport, changes?: Host.Noted, check?: Host.Checks)
  transport = through
  noted = changes
  checks = check
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

--- The rows of one read-only SQLite statement on the agent's sessions.db (its tables are in
--- [`cosmic.agent.sessions`]; `?1` is the session's id), or why there are none. The agent replies with at most 512KB of JSON, and a
--- query of more fails: narrow it with LIMIT and OFFSET, or substr() for a long text.
local function history_of(query: string): ({Host.Row}) | (nil, Failure)
  local answer, why = Host.call("history", { query = query })
  if answer == nil then return nil, why end
  local list, list_why = Json.to_array(answer)
  if list == nil then
    return nil, Failure.new("host: history: the agent's reply is no list of rows: " .. tostring(list_why))
  end
  local rows: mut {Host.Row} = {}
  for _, item in ipairs(list) do
    local row, row_why = Json.to_object(item)
    if row == nil then
      return nil, Failure.new("host: history: a row of the agent's reply is no object: " .. tostring(row_why))
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
local function servers_of(): ({{string: Json.Value}}) | (nil, Failure)
  return objects("mcp.servers", Json.null)
end

--- The tools the MCP server `server` offers, as it lists them: each one's `name`, `description`, `inputSchema` and
--- more. The first call to a server starts it.
local function tools_of(server: string): ({{string: Json.Value}}) | (nil, Failure)
  return objects("mcp.tools", { server = server })
end

--- What the MCP server `server` replied for the tool `tool` called with `arguments`: its `content` (a list of blocks, a text one
--- `{type = "text", text = ...}`), its `structuredContent` where it gives one, and `isError` true where the tool ran
--- and failed. A call the server refused, or one that got no reply, is a failure. The agent replies with at most 512KB.
local function mcp_of(server: string, tool: string, arguments?: {string: Json.Value}): ({string: Json.Value}) | (nil, Failure)
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

--- What the MCP server `server` replied for the tool `tool` called with `arguments`, read: the text of its blocks, the blocks, and
--- its `structuredContent`. A tool that ran and failed (`isError`) is a failure, its text the message, as is a call the
--- server refused or one that got no reply. The functions of `require("mcp.<server>")` call it ([`cosmic.agent.mcp_module`]).
local function tool_of(server: string, tool: string, arguments?: {string: Json.Value}): (Host.Result) | (nil, Failure)
  local answer, why = mcp_of(server, tool, arguments)
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

--- The `structuredContent` the MCP server `server` replied for the tool `tool` called with `arguments`, its null members taken out,
--- as [`Host.tool`] calls it: for a tool that lists an `outputSchema`, which the client holds its result to. A result
--- with none is a failure.
local function structured_of(server: string, tool: string, arguments?: {string: Json.Value}): (Json.Value) | (nil, Failure)
  local result, why = tool_of(server, tool, arguments)
  if result == nil then return nil, why end
  local structured = result.structured
  if structured == nil then
    return nil, Failure.new("mcp: " .. server .. "." .. tool .. ": the tool answered no structuredContent")
  end
  return structured
end

--- How many bytes of a tool's description a found tool holds.
local ABOUT <const> = 160

--- `name` as words: each run of letters and digits, and each capital that begins a word within one (listIssues).
local function spoken(name: string): string
  local split = name:gsub("(%l)(%u)", "%1 %2"):gsub("[%p%s]+", " ")
  return split
end

--- The tools of the MCP servers that best fit `query`, best first, ranked by BM25 over each tool's name, description
--- and server, each word of the query matched as a stem or a word's start: a word in none is let go. A server that
--- cannot list its tools is passed over and named in `skipped`; the search fails where none could, or none is
--- configured. Each server it searches is started, as [`Host.tools`] starts it.
local function search_of(query: string, options?: Host.SearchOptions): (Host.Searched) | (nil, Failure)
  local words: mut {string} = {}
  -- What is no space and no ASCII punctuation is a word's, so a letter beyond ASCII stays one.
  for word in query:gmatch("[^%s%p]+") do words[#words + 1] = "\"" .. word .. "\"*" end
  if #words == 0 then return nil, Failure.new("host: search: the query has no word to look for") end
  local opts: Host.SearchOptions = options or {}
  local limit = opts.limit or 8
  if limit < 1 then
    return nil, Failure.new("host: search: limit is " .. tostring(limit) .. ", below 1")
  end
  local names: mut {string} = {}
  if opts.server ~= nil then
    names[1] = opts.server
  else
    local servers, why = servers_of()
    if servers == nil then return nil, why end
    for _, server in ipairs(servers) do
      local name = server["name"]
      if name is string then names[#names + 1] = name end
    end
    if #names == 0 then
      return nil, Failure.new("host: search: the agent was given no MCP server")
    end
  end
  local db, db_why = Sqlite.memory()
  if db == nil then return nil, Failure.new("host: search: " .. tostring(db_why)) end
  local made, made_why = db:exec("CREATE VIRTUAL TABLE tools USING fts5(name, description, server, " ..
      "tool UNINDEXED, fn UNINDEXED, about UNINDEXED, teal UNINDEXED, tokenize = 'porter unicode61')")
  if not made then return nil, Failure.new("host: search: " .. tostring(made_why)) end
  local skipped: mut {string} = {}
  -- TODO: keep each server's tools for the session, until it says they changed (notifications/tools/list_changed):
  -- each search lists every server's anew.
  for _, server in ipairs(names) do
    local tools, why = tools_of(server)
    if tools == nil then
      skipped[#skipped + 1] = server .. ": " .. tostring(why)
    else
      for _, fn in ipairs(McpModule.made(server, tools).functions) do
        local description = fn.description:gsub("%s+", " ")
        local about = if #description > ABOUT then String.cut(description, ABOUT - 3) .. "..." else description end
        local put, put_why = db:run("INSERT INTO tools (name, description, server, tool, fn, about, teal) " ..
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)", { { text = spoken(fn.tool) }, { text = description },
              { text = server }, { text = fn.tool }, { text = fn.name }, { text = about }, { text = fn.teal } })
        if not put then return nil, Failure.new("host: search: " .. tostring(put_why)) end
      end
    end
  end
  if #skipped == #names then
    return nil, Failure.new("host: search: no server listed its tools: " .. table.concat(skipped, "; "))
  end
  local rows, why = db:rows("SELECT server, tool, fn, about, teal FROM tools WHERE tools MATCH ?1 " ..
      "ORDER BY bm25(tools, 5.0, 1.0, 2.0) LIMIT ?2", { { text = table.concat(words, " OR ") }, { integer = limit } })
  if rows == nil then return nil, Failure.new("host: search: " .. tostring(why)) end
  local found: mut {Host.Found} = {}
  for _, row in ipairs(rows) do
    found[#found + 1] = { server = row:text(1), tool = row:text(2), name = row:text(3), about = row:text(4),
      teal = row:text(5) }
  end
  return { found = found, skipped = skipped }
end

--- The Teal of the one function of `require("mcp." .. server)` that calls the tool `tool`, named as the server lists
--- it or as the module does, with the records it takes and returns, as [`Host.declaration`] shows the whole module.
--- A plain string, to print: where there is none, it says why.
function Host.describe(server: string, tool: string): string
  local tools, why = tools_of(server)
  if tools == nil then return "host: describe: " .. tostring(why) end
  for _, fn in ipairs(McpModule.made(server, tools).functions) do
    if fn.tool == tool or fn.name == tool then return fn.teal end
  end
  return "host: describe: the server " .. Json.quote(server) .. " lists no tool " .. Json.quote(tool)
end

--- Keeps `value` under `key` for a later snippet of this session, in sessions.db, in place of what was kept there;
--- no value, or [`Json.null`], lets the key go. A session gone on with reads it again. Small values alone:
--- a key holds 256KB of JSON and a session 1MB; what is larger goes to a file.
local function store_of(key: string, value?: Json.Value): (true) | (false, Failure)
  local _, why = Host.call("store.put", { key = key, value = if value == nil then Json.null else value end })
  if why ~= nil then return false, why end
  return true
end

--- What [`Host.store`] kept under `key` in this session: its `value`, nil for nothing.
local function load_of(key: string): (Host.Loaded) | (nil, Failure)
  local value, why = Host.call("store.get", { key = key })
  if value == nil then return nil, why end
  if value == Json.null then return {} end
  return { value = value }
end

--- The most seconds [`Host.bash`] may be given: a wait's most ([`Poll.MOST_NS`]), 24 days.
local MOST_SECONDS <const> = 24 * 24 * 60 * 60

--- Runs `command` with bash, or sh where there is none, in the snippet's own sandbox and directory: what it wrote to standard output and standard error, together, and how it ended. A command that exits other
--- than 0 still gives a result, `ok` false; a call fails for a command that could not start, or for a timeout
--- outside 1 to 24 days. A command still running when the snippet ends ends with its worker.
local function bash_of(command: string, options?: Host.BashOptions): (Host.Ran) | (nil, Failure)
  local seconds = if options ~= nil then options.timeout else nil end
  if seconds ~= nil and (seconds < 1 or seconds > MOST_SECONDS) then
    return nil, Failure.new("host: bash: timeout is " .. tostring(seconds) .. ": give 1 to " ..
        String.counted(MOST_SECONDS, "second"))
  end
  local found, _ = Proc.find("bash")
  local res, why = Child.run({ found or "/bin/sh", "-c", command }, { stdin = "null", stdout = "capture",
    stderr = "stdout", timeout_ns = if seconds ~= nil then Clock.seconds(seconds) else Child.FOREVER end })
  if res == nil then return nil, Failure.new("host: bash: " .. tostring(why)) end
  return { output = String.as_utf8(res.stdout or ""), cut = res.truncated, code = res.code, signal = res.signal,
    ok = res.ok, timed_out = res.timed_out }
end

--- The modules of cosmic's library a snippet has no use for: the agent's own, and tooling's.
local TOOLING <const>: {string: boolean} = {
  agent = true, cli = true, coverage = true, doc = true, entrypoint = true, layout = true, project = true, removed = true,
  store = true, test = true,
}

--- The modules a snippet may require, from this binary's docs: a line each, `cosmic.<name>: ` and the start of what
--- it is for (its first clause, at most about 60 bytes), but the agent's own and tooling's. Some hold more under them (cosmic.web.route), which
--- [`Host.docs`] of the module names. A plain string, to print: where the docs cannot be read, it says why. `index`
--- stands in for the docs' index ([`Doc.index`]), for a test.
function Host.modules(index?: {Doc.Summary}): string
  if index == nil then
    local Docs = require("cosmic.doc")
    local Store = require("cosmic.store")
    -- The binary's own database alone, the last searched: a project's own would make the list differ by the project.
    local databases = Store.databases()
    local own = databases[#databases]
    if own == nil then return "host: modules: this binary holds no database" end
    local view, why = Docs.view({ own })
    if view == nil then return "host: modules: " .. tostring(why) end
    local read, index_why = Docs.index(view)
    if read == nil then return "host: modules: " .. tostring(index_why) end
    index = read
  end
  local out: mut {string} = {}
  for _, summary in ipairs(index) do
    local name = summary.module:match("^cosmic%.([%w_]+)$")
    if name ~= nil and TOOLING[name] == nil then
      local about = summary.text:gsub("%s+", " "):gsub("^ ", "")
      -- The first clause past its first few words, and at most 60 bytes: each line is read on every request, and
      -- Host.docs has the rest.
      local stop = about:find("[.:;] ", 25)
      local dash = about:find(" %-%- ", 25)
      if dash ~= nil and (stop == nil or dash < stop) then stop = dash end
      if stop ~= nil then about = about:sub(1, stop - 1) end
      about = about:gsub("%.$", "")
      if #about > 60 then
        about = String.cut(about, 58):gsub("%s%S*$", ""):gsub("[%s,;:(]+$", "") .. "..."
      end
      out[#out + 1] = "cosmic." .. name .. (if about ~= "" then ": " .. about else "" end)
    end
  end
  return table.concat(out, "\n")
end

--- What `cosmic docs` prints of `query`, from this binary's docs: a module (`"cosmic.fs"`), a function
--- (`"Fs.read"`), or words to search for. A plain string, to print: where nothing is found, or the docs cannot be
--- read, it says so.
function Host.docs(query: string): string
  local words: mut {string} = {}
  for word in query:gmatch("%S+") do words[#words + 1] = word end
  if #words == 0 then return "host: docs: name a module, a function or words to search for" end
  local Docs = require("cosmic.doc")
  local Store = require("cosmic.store")
  local view, why = Docs.view(Store.databases())
  if view == nil then return "host: docs: " .. tostring(why) end
  local answer, answer_why = Docs.answer(view, words)
  if answer == nil then return "host: docs: " .. tostring(answer_why) end
  if not answer.found then return "host: docs: nothing is found for " .. Json.quote(query) end
  return table.concat(answer.lines, "\n")
end

-- The helpers below raise where they fail, so a snippet needs no assert: what raises ends the snippet, and the
-- error is what it gives back.

--- Raises `why` as the failure of the call `name`, at the snippet's line.
local function raise(name: string, why: Failure): never
  error("host: " .. name .. ": " .. tostring(why), 3)
end

--- Every file under `dir` ([`Shell.find`]); raises where `dir` cannot be walked.
function Host.find(dir: string, suffix?: string): mut {string}
  local found, why = Shell.find(dir, suffix)
  if found == nil then raise("find", why) end
  return found
end

--- The text of the file `path`, whole. Raises where it cannot be read.
function Host.read(path: string): string
  local text, why = Fs.read(path)
  if text == nil then error("host: read: " .. tostring(why), 2) end
  return text
end

--- The file a link at `path` names, through each link in turn, or `path` where it is none: so an edit changes what a
--- link names and leaves the link.
local function linked(path: string): string
  local at = path
  for _ = 1, 40 do
    local target, _ = Fs.readlink(at)
    if target == nil then return at end
    at = if target:sub(1, 1) == "/" then target else Fs.dirname(at) .. "/" .. target end
  end
  return at
end

--- Makes each of `edits` in the file `path`, as the agent's edit tool does ([`cosmic.agent.edit`]): each `old` is in
--- the file once, as it was before any edit, no two overlap, and a file of CRLF line ends keeps them. A link's file is
--- changed, and the link kept. Returns how many it made; raises, naming the edit by its index in `edits` and how to fix
--- it, where one does not match once, or the file cannot be read or written, and then changes nothing.
---
---     Host.edit("notes.md", { { old = "teh", new = "the" }, { old = "## Todo", new = "## Done" } })
function Host.edit(path: string, edits: {Host.Replacement}): integer
  local file = linked(path)
  local raw, why = Fs.read(file)
  if raw == nil then error("host: edit: " .. tostring(why), 2) end
  local edited, made = AgentEdit.apply(raw, edits, path, "old", 1)
  if edited == nil then error("host: edit: " .. made, 2) end
  local ok, write_why = Fs.write(file, edited)
  if not ok then error("host: edit: " .. tostring(write_why), 2) end
  local hears = noted
  if hears ~= nil then
    -- A copy, so a list the snippet changes after the call shows what was written.
    local copy: mut {Host.Replacement} = {}
    for _, r in ipairs(edits) do copy[#copy + 1] = { old = r.old, new = r.new } end
    hears({ path = path, edits = copy })
  end
  return made
end

--- The checker's lines on the Teal file `path`, as `cosmic fix` tells them of a file of its tree: none where it passes.
--- It reads the modules a snippet may require, and tells the lines of each module of a tree it requires too; it runs no
--- code. Raises where it cannot be read, or where
--- no checker is here (outside cosmic agent's worker).
function Host.check(path: string): {string}
  local text = Host.read(path)
  local check = checks
  if check == nil then
    error("host: check: no checker answers here: a snippet of cosmic agent's run tool reaches one", 2)
  end
  return check(path, text)
end

--- The lines of the file `path` ([`Shell.lines`]); raises where it cannot be read.
function Host.lines(path: string): mut {string}
  local lines, why = Shell.lines(path)
  if lines == nil then raise("lines", why) end
  return lines
end

--- Whether anything is at `path`, as `test -e` tells: false where it or a parent is missing. Raises where it cannot
--- look (a parent it may not search).
function Host.exists(path: string): boolean
  local status, why = Fs.status(path)
  if status == nil then error("host: exists: " .. tostring(why), 2) end
  return status.exists
end

--- Writes `text` to the file `path`, in place of what it held, as `>` does; a list of lines is written one a line, each ending
--- in a newline. Raises where it cannot be written.
function Host.write(path: string, text: string | {string})
  local body = if text is string then text elseif #text == 0 then "" else table.concat(text, "\n") .. "\n" end
  local ok, why = Fs.write(path, body)
  if not ok then error("host: write: " .. tostring(why), 2) end
  local hears = noted
  if hears ~= nil then
    local _, newlines = body:gsub("\n", "")
    hears({ path = path, lines = newlines + (if body ~= "" and body:sub(-1) ~= "\n" then 1 else 0 end) })
  end
end

--- The lines of `paths` that hold `pattern` ([`Shell.grep`]); raises where a file cannot
--- be read or the pattern is malformed.
function Host.grep(pattern: string, paths: {string}, plain?: boolean): mut {Host.Hit}
  local hits, why = Shell.grep(pattern, paths, plain)
  if hits == nil then raise("grep", why) end
  return hits
end

--- Replaces `pattern` in the file `path`, and returns how many ([`Shell.sed`]); raises where it
--- cannot be read or written, or the pattern is malformed.
function Host.sed(path: string, pattern: string, replacement: string, plain?: boolean): integer
  local count, why = Shell.sed(path, pattern, replacement, plain)
  if count == nil then raise("sed", why) end
  return count
end

--- How many lines the file `path` has ([`Shell.wc`]); raises where it cannot be read.
function Host.wc(path: string): integer
  local count, why = Shell.wc(path)
  if count == nil then raise("wc", why) end
  return count
end

--- How often each of `keys` is in it ([`Shell.uniq`]).
function Host.uniq(keys: {string}): {string: integer} return Shell.uniq(keys) end

--- The most counted of `counts` first ([`Shell.top`]).
function Host.top(counts: {string: integer}, most?: integer): mut {Host.Count}
  return Shell.top(counts, most)
end

--- A sorted copy of `list`, by `by`'s key where given ([`Shell.sort`]).
function Host.sort(list: {string}, by?: function(string): string): mut {string}
  return Shell.sort(list, by)
end

--- A sorted copy of `list` as `sort -V` orders it, a run of digits by its number ([`Shell.version_sort`]): `a.tl:9`
--- before `a.tl:10`.
function Host.version_sort(list: {string}, by?: function(string): string): mut {string}
  return Shell.version_sort(list, by)
end

--- A sorted copy of `list`, any kind of item, by the key `by` gives each (`Host.sort_by(items, function(i: Item):
--- string return i.id end)`), as `LC_ALL=C sort` orders bytes; items of one key keep their order.
function Host.sort_by<T>(list: {T}, by: function(T): string): mut {T}
  local keys: mut {string} = {}
  local order: mut {integer} = {}
  for i, v in ipairs(list) do
    local key = by(v)
    keys[#keys + 1] = key
    order[#order + 1] = i
  end
  table.sort(order, function(a: integer, b: integer): boolean
    local ka, kb = keys[a]!, keys[b]!
    if ka ~= kb then return ka < kb end
    return a < b
  end)
  local out: mut {T} = {}
  for _, i in ipairs(order) do out[#out + 1] = list[i]! end
  return out
end

--- The rows of `statement` on the SQLite file `path` ([`Shell.sqlite`]); raises where it
--- fails.
function Host.sqlite(path: string, statement: string, values?: {Json.Value}): mut {Host.Row}
  local rows, why = Shell.sqlite(path, statement, values)
  if rows == nil then raise("sqlite", why) end
  return rows
end

--- The SHA-256 of the file `path`, in hex ([`Hash.hex_file`] outside a snippet). Raises where it cannot be read.
function Host.sha256(path: string): string
  local hex, why = Hash.hex_file("sha256", path)
  if hex == nil then error("host: sha256: " .. tostring(why), 2) end
  return hex
end

--- The Teal of `require("mcp." .. server)`: the records and functions a snippet calls the server's tools by
--- ([`cosmic.agent.mcp_module`]). A plain string, to print: where there is none, it says why.
function Host.declaration(server: string): string
  local tools, why = tools_of(server)
  if tools == nil then return "host: declaration: " .. tostring(why) end
  return McpModule.made(server, tools).teal
end

--- The rows of one read-only SQLite statement on the agent's sessions.db, whose tables [`cosmic.agent.sessions`]
--- names (`?1` is the session's id); at most 512KB of JSON, so narrow a large one with LIMIT and OFFSET. Raises where it fails, as "host: ...".
function Host.history(query: string): {Host.Row}
  local value, why = history_of(query)
  if value == nil then error(tostring(why), 2) end
  return value
end

--- The characters of a kept output one history call reads: JSON takes a control character as six bytes, so a part
--- stays within the 512KB a reply holds.
local OUTPUT_PART <const> = 64 * 1024

--- The text kept of output `id` of sessions.db, which the note atop a cut output names ("kept as output 17"): what
--- the tool's call gave, but for a run output past 64KB, of which its first 16KB and last 48KB are kept; bytes that
--- are not UTF-8 come back replaced. It reads any session's outputs, as Host.history does: a forked session's notes
--- name the outputs of the session it was copied from. Raises where it fails, as "host: output: ...".
function Host.output(id: integer): string
  local function rows_of(query: string): {Host.Row}
    local rows, why = history_of(query)
    if rows == nil then error("host: output: " .. tostring(why):gsub("^host: history: ", ""), 3) end
    return rows
  end
  local sized = rows_of("SELECT length(text) AS n FROM outputs WHERE id = " .. tostring(id))[1]
  local n = if sized ~= nil then sized["n"] else nil end
  if not (n is integer) then
    error("host: output: no output " .. tostring(id) .. " in sessions.db", 2)
  end
  local parts: mut {string} = {}
  for start = 1, n, OUTPUT_PART do
    local row = rows_of("SELECT substr(text, " .. tostring(start) .. ", " .. tostring(OUTPUT_PART) ..
        ") AS part FROM outputs WHERE id = " .. tostring(id))[1]
    local part = if row ~= nil then row["part"] else nil end
    if not (part is string) then
      error("host: output: output " .. tostring(id) .. " changed as it was read", 2)
    end
    parts[#parts + 1] = part
  end
  return table.concat(parts)
end

--- What the agent's tool `name` returns for `input`, as the model would call it: its text. Only a tool code may call
--- is called (`callers` "code" or "both", cosmic.agent.tools), under the agent's `before` and `after` as a call by
--- code. Raises where the call is refused or the tool's result is an error, as "host: use: ...".
function Host.use(name: string, input?: {string: Json.Value}): string
  local none: {string: Json.Value} = {}
  local answer, why = Host.call("use", { name = name, input = input or none })
  if answer == nil then error(tostring(why), 2) end
  if not (answer is string) then error("host: use: the agent's reply is no text", 2) end
  return answer
end

--- The MCP servers the agent was given: each one's `name`, `reached`, and `description` where the config gives
--- one; none where it was given none. Raises where it fails, as "host: ...".
function Host.servers(): {{string: Json.Value}}
  local value, why = servers_of()
  if value == nil then error(tostring(why), 2) end
  return value
end

--- The tools the MCP server `server` offers, as it lists them; the first call to a server starts it. Raises where it fails, as "host: ...".
function Host.tools(server: string): {{string: Json.Value}}
  local value, why = tools_of(server)
  if value == nil then error(tostring(why), 2) end
  return value
end

--- What the MCP server `server` replied for the tool `tool` called with `arguments`, as the server sent it:
--- `content`, `structuredContent` and `isError`. Raises where it fails, as "host: ...".
function Host.mcp(server: string, tool: string, arguments?: {string: Json.Value}): {string: Json.Value}
  local value, why = mcp_of(server, tool, arguments)
  if value == nil then error(tostring(why), 2) end
  return value
end

--- What the MCP server `server` replied for the tool `tool` called with `arguments`, read: its text, blocks and
--- `structuredContent`; a tool that ran and failed (`isError`) raises with its text. Raises where it fails, as "host: ...".
function Host.tool(server: string, tool: string, arguments?: {string: Json.Value}): Host.Result
  local value, why = tool_of(server, tool, arguments)
  if value == nil then error(tostring(why), 2) end
  return value
end

--- The `structuredContent` the MCP server `server` replied for the tool `tool` called with `arguments`, its nulls
--- taken out; a result with none raises. Raises where it fails, as "host: ...".
function Host.structured(server: string, tool: string, arguments?: {string: Json.Value}): Json.Value
  local value, why = structured_of(server, tool, arguments)
  if value == nil then error(tostring(why), 2) end
  return value
end

--- The MCP tools that best fit `query`, best first, across the servers (or `options.server`), with the
--- servers that could not list theirs in `skipped`. Raises where it fails, as "host: ...".
function Host.search(query: string, options?: Host.SearchOptions): Host.Searched
  local value, why = search_of(query, options)
  if value == nil then error(tostring(why), 2) end
  return value
end

--- What [`Host.store`] kept under `key` in this session: its `value`, nil for nothing. Raises where it fails, as "host: ...".
function Host.load(key: string): Host.Loaded
  local value, why = load_of(key)
  if value == nil then error(tostring(why), 2) end
  return value
end

--- Runs `command` with bash in the snippet's sandbox and directory, where the session has commands: its output and how it
--- ended. A command that exits other than 0 still gives a result, `ok` false; one that cannot start raises. Raises where it fails, as "host: ...".
function Host.bash(command: string, options?: Host.BashOptions): Host.Ran
  local value, why = bash_of(command, options)
  if value == nil then error(tostring(why), 2) end
  return value
end

--- The response to a request of `url`, which follows no redirect
--- ([`cosmic.agent.fetch`]): made from the snippet's sandbox, which reaches no network in a session started without
--- --network or --connect, and no loopback, private, link-local or host's own address but those --connect names. A
--- status under 400 is returned; one of 400 or more raises, as `curl -f` fails, with the status and the start of the
--- body in the message, unless `any_status` is given; a request that gets no response raises.
function Host.fetch(url: string, options?: Host.FetchOptions): Host.Fetched
  local o: Host.FetchOptions = options or {}
  local got, why = AgentFetch.fetch({ url = url, method = o.method, headers = o.headers, body = o.body,
    timeout = o.timeout, any_status = o.any_status })
  if got == nil then error(tostring(why), 2) end
  return { status = got.status, headers = got.headers, body = got.body, cut = got.cut }
end

--- Keeps `value` under `key` for a later snippet of this session, in place of what was kept there; no value,
--- or [`Json.null`], lets the key go. A key is 1 to 256 bytes, its value at most 256KB of JSON, and a session keeps
--- 1MB, its keys and values together. Raises where it fails.
function Host.store(key: string, value?: Json.Value)
  local _, why = store_of(key, value)
  if why ~= nil then error(tostring(why), 2) end
end

--- Ends the turn with `text` as the reply to the user, once the snippet has run to its end: no request asks the model
--- for one, so a snippet that has what the user asked for saves a turn. A snippet that raises gives no answer, and the
--- last answer given is the one. Raises where it fails.
function Host.answer(text: string)
  local _, why = Host.call("answer", { text = text })
  if why ~= nil then error(tostring(why), 2) end
end

return Host
