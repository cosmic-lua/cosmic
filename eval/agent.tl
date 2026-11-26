--- Runs the evals of cosmic agent itself: fixed tasks on a copy of a fixture tree, each solved by `cosmic agent ask`
--- with each tool under test, and graded by comparing what the agent left against what a command computes from the
--- untouched fixture. It tells, for each tool and task, how many runs passed and what they spent: requests (turns),
--- tokens, cost, seconds and tool calls, read from each tool's own sessions.db. Two tools of one task compare, for
--- example, the agent with code mode and the release before it.
---
---     bin/cosmic eval/agent.tl --tool NAME=PATH [--tool NAME=PATH ...] --fixture DIR --out DIR
---         [--offer NAME=TOOL,...] [--effort [NAME=]LEVEL] [--tasks T,...|all] [--reps N] [--model M]
---         [--timeout S]
---
--- `--offer NAME=run,read` runs the agent of the tool NAME with `--tools run,read`, for a binary from before run became
--- the agent's one tool (a newer one refuses `--tools`). `--effort NAME=low` runs the agent of the tool NAME
--- with `--effort low`, and `--effort low` every tool not named so: one binary under two names compares two efforts.
--- Where none is given, the agent takes its own default.
--- The fixture is a tree the tasks read, such as this repository at a commit
--- (`git archive <commit> | tar -x -C DIR`); the report names it, and a task whose truth comes out empty on it is
--- marked unfit rather than graded. A task of MCP servers (mcp-*) gives the run `--mcp`, a config of the
--- servers laid out in its own temp directory, which the agent's tools may not read: only a snippet reaches them, so
--- a tool with no `--mcp` or no code mode fails it. The mcp-many-* tasks give eight servers, the one the task needs
--- named for what it holds and not for its tools, so a run finds its tools among the others'. Where the evals run as root, the tool's path must be one every
--- user may search, as the server runs as a user of its own. Each run is a fresh copy, `bench-<tool>-<task>-*` in the temp directory, removed
--- once the run is graded (as is each other directory the evals make), with
--- `HOME` and `XDG_DATA_HOME` the tool's own under <out>/<tool>. ANTHROPIC_API_KEY, or HARNESS_ANTHROPIC_API_KEY,
--- is the key. <out>/report.md is the report, <out>/results.json each run's numbers, and each run's answer, the
--- agent's words, and the grade are in <out>/<tool>/<task>-<rep>.txt. [`eval/agent`] runs this on the checkout's
--- own cosmic, and the report is the text template eval/report.tmpl. [`Agent.execute`] works through an [`Agent.System`], which a test
--- replaces with a fake.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Report = require("eval.report")
local ReportData = require("eval.report_data")
local Sqlite = require("cosmic.sqlite")

local record Agent
  --- One task: what the agent is asked, and how its work is graded.
  record Task
    name: string
    --- The prompt, which says what to leave and in what form.
    prompt: string
    --- A second prompt, asked once the first's turn ended, in the same session (ask goes on with the newest
    --- session in the directory): for a task about what the first turn saw.
    follow_up?: string
    --- A bash command run in an untouched copy of the fixture: its output is what a right answer leaves.
    truth: string
    --- A bash command run in the run's copy once the agent ended: its output must be the truth's. `$tool` is the
    --- path of the tool under test, for a task whose answer is a program to run.
    check: string
    --- The MCP servers the run is given, in one config, where the task needs them. Its truth runs with `$data`
    --- the path of the first one's data: the others are there to be passed over.
    servers?: {Server}
    --- A web API the run reaches over HTTP at a loopback port, where the task needs one: `{url}` in the prompt is
    --- its URL, and the run is given `--connect` to it. Its truth runs with `$data` the path of its data.
    site?: Site
  end

  --- A web API of a task: a program started for each run, which serves its data at 127.0.0.1 on a port the
  --- kernel chose, and writes that port to the file its second argument names once it serves.
  record Site
    --- The Teal of its program, a main taking the data's path and the port file's.
    source: string
    --- The data it serves, in data.tsv beside it.
    data: string
  end

  --- An MCP server of a task: written for each run to a directory of its own beside its config, which the
  --- agent's tools may not read, so the agent reaches the data through the server alone.
  record Server
    --- Its name in the config: the agent requires `mcp.<name>`.
    name: string
    --- What it is for, as the config says to the model; nil for none.
    about?: string
    --- The Teal of its program, a main taking the data's path as its first argument.
    source: string
    --- The data it serves, in data.tsv beside it.
    data: string
  end

  --- A tool under test: its name in the report, and the cosmic binary.
  record Tool
    name: string
    path: string
    --- The tools its agent offers (`--tools`), as `--offer NAME=LIST` names them; nil for the agent's default.
    tools?: string
    --- How hard its agent thinks (`--effort`); nil for the agent's default.
    effort?: string
  end

  --- What the command line asked for.
  record Options
    tools: {Tool}
    fixture: string
    out: string
    tasks: {Task}
    reps: integer
    model: string
    --- Each ask's deadline, in seconds: a task with a follow-up asks twice.
    timeout: integer
  end

  --- A finished command: its exit status (124 for a timeout), and its standard output and error.
  record Output
    code: integer
    stdout: string
    stderr: string
    --- How long it ran, by the wall clock; nil where not timed.
    seconds?: number
  end

  --- What one run spent, from its session in sessions.db.
  record Spent
    requests: integer
    input: integer
    output: integer
    cache_read: integer
    cache_write: integer
    cost: number
    seconds: number
    tools: integer
    runs: integer
    --- How many run calls the checker refused, and how often each of its codes was named in them.
    refused: integer
    codes: {string: integer}
    --- How many snippets of run named each Host helper, by its name (`bash` for Host.bash, a command no other
    --- helper served): the use a helper is kept or pruned by.
    helpers: {string: integer}
    --- What the session's first request read from the cache: the prefix it shared with another session.
    first_read: integer
  end

  --- One run's result.
  record Result
    tool: string
    task: string
    rep: integer
    --- "pass", "fail" or "unfit" (the truth was empty on the fixture).
    grade: string
    --- nil where no session was found for the run.
    spent?: Spent
    --- How long the agent ran, by the wall clock, tools and all.
    wall: number
  end

  --- What the evals do to the world. Tests give a fake.
  record System
    --- Runs `argv` in `cwd` with `env` (nil for this process's) for at most `seconds`.
    run: function(argv: {string}, cwd: string, env: {string: string}?, seconds: integer): Agent.Output
    --- A new, empty directory, its name starting `prefix`.
    fresh: function(prefix: string): string
    --- Removes the directory `dir` that `fresh` made, and all in it.
    discard: function(dir: string)
    --- What one run spent: the session of `tool` whose directory's name holds `marker`.
    spent: function(tool: string, marker: string): Agent.Spent?
    --- Writes `text` to the file `path`, making the directories it is in.
    put: function(path: string, text: string)
    --- Starts `argv` in `cwd` and waits, for at most `seconds`, until the file `ready` holds a port: the port,
    --- and a call that ends the program. Nil and why where it ended or did not say so in time.
    serve: function(argv: {string}, cwd: string, ready: string, seconds: integer): (string, function()) | (nil, string)
  end

  --- Every task, in the order a report lists them.
  tasks: {Task}
end

--- The inventory a server of the MCP tasks serves: 240 items, as `id name category price_cents stock`, tab
--- apart, drawn anew by each process, so no copy of this file tells them.
local function inventory(): string
  local adjectives <const> = { "red", "small", "brass", "quiet", "heavy", "folding", "round", "spare" }
  local nouns <const> = { "hammer", "lamp", "kettle", "rake", "puzzle", "atlas", "clamp", "basket", "drum", "bowl" }
  local categories <const> = { "books", "garden", "kitchen", "tools", "toys" }
  local seed = math.random(1, 2147483647)
  local function draw(n: integer): integer
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n
  end
  local lines: mut {string} = {}
  for i = 1, 240 do
    lines[#lines + 1] = string.format("i%04d\t%s %s\t%s\t%d\t%d", i, adjectives[draw(#adjectives) + 1],
      nouns[draw(#nouns) + 1], categories[draw(#categories) + 1], 100 + draw(9900), draw(61))
  end
  return table.concat(lines, "\n") .. "\n"
end

--- The sales web-csv's web API serves: 300 rows of `region customer amount_cents`, tab apart, drawn anew by each
--- process. Some customers' names hold a comma or a double quote, so the CSV quotes them and a split on commas
--- miscounts.
local function sales(): string
  local regions <const> = { "east", "north", "south", "west" }
  local customers <const> = { "Acme, Inc.", "Bolt & Nut", "Joe's \"Best\" Pies", "Northwind", "Lumen, Ltd.",
    "Okra Farms", "Pine \"&\" Oak, LLC", "Quill" }
  local seed = math.random(1, 2147483647)
  local function draw(n: integer): integer
    seed = (seed * 1103515245 + 12345) % 2147483648
    return (seed // 65536) % n
  end
  local lines: mut {string} = {}
  for _ = 1, 300 do
    lines[#lines + 1] = string.format("%s\t%s\t%d", regions[draw(#regions) + 1], customers[draw(#customers) + 1],
      100 + draw(99900))
  end
  return table.concat(lines, "\n") .. "\n"
end

--- The event log earlier-log's web API serves: 400 lines of `HH:MM:SS LEVEL component message`, about 17KB. That
--- is more than run shows, so the printed log is cut. Each process draws it anew, so no copy of this file tells it.
local function event_log(): string
  local levels <const> = { "INFO", "INFO", "INFO", "WARN", "ERROR" }
  local components <const> = { "billing", "cache", "gateway", "queue", "search", "storage" }
  local messages <const> = { "request done", "retrying after timeout", "connection reset by peer",
    "slow response from upstream", "config reloaded", "lease renewed", "disk usage above threshold" }
  local seed = math.random(1, 2147483647)
  local function draw(n: integer): integer
    seed = (seed * 1103515245 + 12345) % 2147483648
    return (seed // 65536) % n
  end
  local lines: mut {string} = {}
  for i = 1, 400 do
    local t = 36000 + i * 7
    lines[#lines + 1] = string.format("%02d:%02d:%02d %s %s %s", t // 3600, t // 60 % 60, t % 60,
      levels[draw(#levels) + 1], components[draw(#components) + 1], messages[draw(#messages) + 1])
  end
  return table.concat(lines, "\n") .. "\n"
end

--- The inventory server: list_items pages through the items' ids and names, and get_item tells one item's
--- category, price and stock.
local INVENTORY_SERVER <const> = [==[
local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Server = require("cosmic.mcp.server")

local PAGE <const> = 25

return function(argv: {string}): integer
  local text, why = Fs.read(argv[1] or "")
  if text == nil then error("inventory: the data: " .. tostring(why)) end
  local order: mut {{string: Json.Value}} = {}
  local by_id: mut {string: {string: Json.Value}} = {}
  for line in text:gmatch("[^\n]+") do
    local id, name, category, price, stock = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)\t(%d+)$")
    if id ~= nil and name ~= nil and category ~= nil and price ~= nil and stock ~= nil then
      order[#order + 1] = { id = id, name = name }
      by_id[id] = { id = id, name = name, category = category, price_cents = assert(math.tointeger(tonumber(price))),
        stock = assert(math.tointeger(tonumber(stock))) }
    end
  end
  local server = Server.new{
    info = { name = "inventory", version = "1" },
    tools = { {
      tool = { name = "list_items", description = "A page of the items, " .. tostring(PAGE) .. " at most, by id: " ..
          "each one's id and name, and `next`, the cursor of the page after it, which the last page has not.",
        inputSchema = Mcp.object_schema({ cursor = { type = "string", description = "The page's cursor, " ..
          "from the page before; none for the first" } }),
        outputSchema = Mcp.object_schema({ items = { type = "array", items = Mcp.object_schema({
          id = { type = "string" }, name = { type = "string" } }, { "id", "name" }) },
          next = { type = "string" } }, { "items" }) },
      call = function(args: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        local cursor = args["cursor"]
        local first = 1
        if cursor is string then
          local at = math.tointeger(tonumber(cursor))
          if at == nil or at < 1 then return Mcp.result({ "list_items: no such cursor: " .. cursor }, true) end
          first = at
        end
        local page: mut {Json.Value} = {}
        for i = first, math.min(first + PAGE - 1, #order) do
          local item = order[i]
          if item ~= nil then page[#page + 1] = item end
        end
        local out: mut {string: Json.Value} = { items = Json.array(page) }
        if first + PAGE <= #order then out["next"] = tostring(first + PAGE) end
        return Mcp.structured(out)
      end,
    }, {
      tool = { name = "get_item", description = "One item: its id, name, category, price in cents and stock.",
        inputSchema = Mcp.object_schema({ id = { type = "string" } }, { "id" }),
        outputSchema = Mcp.object_schema({ id = { type = "string" }, name = { type = "string" },
          category = { type = "string" }, price_cents = { type = "integer" }, stock = { type = "integer" } },
          { "id", "name", "category", "price_cents", "stock" }) },
      call = function(args: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        local item = by_id[tostring(args["id"])]
        if item == nil then return Mcp.result({ "no item " .. tostring(args["id"]) }, true) end
        return Mcp.structured(item)
      end,
    } },
  }
  assert(server:serve_stdio())
  return 0
end
]==]

--- The inventory web API, the same items over HTTP at a loopback port the kernel chose: the server replies to GET /items?page=N with
--- JSON, `{items, next}`, 40 items a page, each with every field, and `next` the page after it, which the last
--- page has not. It writes its port to the file its second argument names once it serves.
local INVENTORY_SITE <const> = [==[
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")

local PAGE <const> = 40

return function(argv: {string}): integer
  local text, why = Fs.read(argv[1] or "")
  if text == nil then error("inventory: the data: " .. tostring(why)) end
  local ready = argv[2] or ""
  local items: mut {Json.Value} = {}
  for line in text:gmatch("[^\n]+") do
    local id, name, category, price, stock = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)\t(%d+)$")
    if id ~= nil and name ~= nil and category ~= nil and price ~= nil and stock ~= nil then
      local item: {string: Json.Value} = { id = id, name = name, category = category,
        price_cents = assert(math.tointeger(tonumber(price))), stock = assert(math.tointeger(tonumber(stock))) }
      items[#items + 1] = item
    end
  end
  assert(Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    on_ready = function(addresses: {Net.Address}, _: Net.Server)
      assert(Fs.write(ready, tostring(assert(addresses[1]).port)))
    end,
    handle = function(req: Server.Request): Server.Reply
      if req.method ~= "GET" or req.path ~= "/items" then
        return { status = 404, body = "no such page: GET /items?page=N, from 1\n" }
      end
      local page = math.tointeger(tonumber(("&" .. req.query):match("&page=(%d+)") or "1")) or 1
      local first = (page - 1) * PAGE + 1
      local out: mut {Json.Value} = {}
      for i = first, math.min(first + PAGE - 1, #items) do
        local item = items[i]
        if item ~= nil then out[#out + 1] = item end
      end
      local body: mut {string: Json.Value} = { items = Json.array(out) }
      if first + PAGE <= #items then body["next"] = page + 1 end
      return { status = 200, headers = { ["Content-Type"] = "application/json" },
        body = assert(Json.encode(body)) .. "\n" }
    end,
  })
  return 0
end
]==]

--- A server that is there to be passed over: it lists the tools its data names, a line each as
--- `name<TAB>description<TAB>param,param`, each taking those string parameters, and replies to any call with
--- nothing found.
local DECOY_SERVER <const> = [==[
local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Server = require("cosmic.mcp.server")

return function(argv: {string}): integer
  local text, why = Fs.read(argv[1] or "")
  if text == nil then error("decoy: the data: " .. tostring(why)) end
  local tools: mut {Server.ToolSpec} = {}
  for line in text:gmatch("[^\n]+") do
    local name, description, params = line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)$")
    if name ~= nil and description ~= nil and params ~= nil then
      local properties: mut {string: Json.Value} = {}
      for param in params:gmatch("[^,]+") do properties[param] = { type = "string" } end
      tools[#tools + 1] = {
        tool = { name = name, description = description, inputSchema = Mcp.object_schema(properties) },
        call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
          return Mcp.result({ name .. ": nothing found" })
        end,
      }
    end
  end
  -- It is named for the directory of its data, which is its name in the config, as a real server names itself.
  local named = (argv[1] or ""):match("([^/]+)/[^/]*$") or "server"
  assert(Server.new{ info = { name = named, version = "1" }, tools = tools }:serve_stdio())
  return 0
end
]==]

--- The servers of the decoy kind a task of many servers passes over, by name: what each is for, and its tools.
--- catalog is the near miss: its products are the warehouse's items, without their stock or category.
local DECOYS <const>: {{string}} = {
  { "billing", "Invoices and payments of customers.",
    "list_invoices\tA page of the invoices, newest first.\tcursor,customer\n" ..
      "get_invoice\tOne invoice: its lines, total and state.\tid\n" ..
      "list_payments\tA page of the payments received.\tcursor\n" },
  { "calendar", "The team's calendar.",
    "list_events\tThe events between two dates.\tfrom,to\n" ..
      "create_event\tAdds an event.\ttitle,start,end\n" ..
      "free_busy\tWhen each person is busy.\tpeople,from,to\n" },
  { "catalog", "The product catalog shown on the shop's site.",
    "list_products\tA page of the products: each one's id, title and description.\tcursor\n" ..
      "get_product\tOne product: its title, description and images.\tid\n" ..
      "search_products\tProducts whose title or description holds the words.\tquery\n" },
  { "crm", "Customers, their contacts and the deals with them.",
    "list_contacts\tA page of the contacts.\tcursor\n" ..
      "get_contact\tOne contact: name, email, company.\tid\n" ..
      "search_contacts\tContacts whose name or company holds the words.\tquery\n" ..
      "list_deals\tA page of the deals, by stage.\tcursor,stage\n" },
  { "docs", "The company's internal wiki.",
    "search_docs\tPages whose text holds the words.\tquery\n" ..
      "get_page\tOne page's text.\tid\n" ..
      "list_spaces\tThe wiki's spaces.\t\n" },
  { "metrics", "Service metrics and dashboards.",
    "query_metric\tA metric's values over a time range.\tname,from,to\n" ..
      "list_dashboards\tThe dashboards.\t\n" },
  { "tickets", "Support tickets.",
    "list_tickets\tA page of the tickets, by state.\tcursor,state\n" ..
      "get_ticket\tOne ticket and its replies.\tid\n" ..
      "search_tickets\tTickets whose text holds the words.\tquery\n" },
}

--- The servers of a task of many: the warehouse, whose data its truth reads, then the decoys.
local function many_servers(): {Agent.Server}
  local out: mut {Agent.Server} = {
    { name = "warehouse", about = "The warehouse's records.", source = INVENTORY_SERVER, data = inventory() },
  }
  for _, decoy in ipairs(DECOYS) do
    out[#out + 1] = { name = assert(decoy[1]), about = decoy[2], source = DECOY_SERVER, data = assert(decoy[3]) }
  end
  return out
end

--- The sales web API: GET /sales.csv replies with the sales as CSV (RFC 4180), a header `region,customer,amount_cents`
--- then a row each, a field quoted where it holds a comma or a double quote. It writes its port to the file its
--- second argument names once it serves.
local SALES_SITE <const> = [==[
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")

local function field(text: string): string
  if text:find('[,"]') == nil then return text end
  return '"' .. (text:gsub('"', '""')) .. '"'
end

return function(argv: {string}): integer
  local text, why = Fs.read(argv[1] or "")
  if text == nil then error("sales: the data: " .. tostring(why)) end
  local ready = argv[2] or ""
  local rows: mut {string} = { "region,customer,amount_cents" }
  for line in text:gmatch("[^\n]+") do
    local region, customer, amount = line:match("^([^\t]+)\t([^\t]+)\t(%d+)$")
    if region ~= nil and customer ~= nil and amount ~= nil then
      rows[#rows + 1] = field(region) .. "," .. field(customer) .. "," .. amount
    end
  end
  local body = table.concat(rows, "\r\n") .. "\r\n"
  assert(Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    on_ready = function(addresses: {Net.Address}, _: Net.Server)
      assert(Fs.write(ready, tostring(assert(addresses[1]).port)))
    end,
    handle = function(req: Server.Request): Server.Reply
      if req.method ~= "GET" or req.path ~= "/sales.csv" then
        return { status = 404, body = "no such page: GET /sales.csv\n" }
      end
      return { status = 200, headers = { ["Content-Type"] = "text/csv" }, body = body }
    end,
  })
  return 0
end
]==]

--- The log web API: GET /log replies with the event log, as plain text, once; every request after the first is
--- refused with 410, so a question about the log after the first turn must be settled from sessions.db. It writes its port to the file its second argument names once it serves.
local LOG_SITE <const> = [==[
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")

return function(argv: {string}): integer
  local text, why = Fs.read(argv[1] or "")
  if text == nil then error("log: the data: " .. tostring(why)) end
  local ready = argv[2] or ""
  local served = false
  assert(Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    on_ready = function(addresses: {Net.Address}, _: Net.Server)
      assert(Fs.write(ready, tostring(assert(addresses[1]).port)))
    end,
    handle = function(req: Server.Request): Server.Reply
      if req.method ~= "GET" or req.path ~= "/log" then return { status = 404, body = "no such page: GET /log\n" } end
      if served then return { status = 410, body = "gone: the log is served once, and it was\n" } end
      served = true
      return { status = 200, headers = { ["Content-Type"] = "text/plain" }, body = text }
    end,
  })
  return 0
end
]==]

Agent.tasks = {
  {
    name = "largest",
    prompt = "Write to answer.txt the five largest .tl files under cosmic/ by line count, as `wc -l` counts " ..
      "lines: one `count path` per line, such as `412 cosmic/x.tl` (path from this directory), largest first, ties by path.",
    truth = "find cosmic -name '*.tl' -type f -exec wc -l {} + | grep -v ' total$' | awk '{print $1\" \"$2}' | " ..
      "sort -k1,1nr -k2,2 | head -5",
    check = "cat answer.txt",
  },
  {
    name = "todos",
    prompt = "Write to answer.txt every line of the .tl files under cosmic/ that holds `TODO`, as " ..
      "`path:line`, such as `cosmic/x.tl:12` (path from this directory, line numbered from 1), one a line, sorted by path, then by line.",
    truth = "grep -rn --include='*.tl' 'TODO' cosmic | cut -d: -f1,2 | sort -t: -k1,1 -k2,2n",
    check = "cat answer.txt",
  },
  {
    name = "requires",
    prompt = "For each .tl file under cosmic/agent/ whose name does not end in _test.tl, count the distinct " ..
      "modules it names in `require(\"cosmic.<...>\")`. Write to answer.txt the three with the most, as " ..
      "`count path`, such as `7 cosmic/agent/x.tl`, one a line, most first, ties by path.",
    truth = "for f in $(find cosmic/agent -name '*.tl' ! -name '*_test.tl'); do " ..
      "echo \"$(grep -o 'require(\"cosmic\\.[^\"]*\")' \"$f\" | sort -u | wc -l) $f\"; done | " ..
      "sort -k1,1nr -k2,2 | head -3",
    check = "cat answer.txt",
  },
  {
    name = "tests",
    prompt = "For every file under cosmic/agent/ whose name ends in _test.tl, count the lines that start " ..
      "`local function test_`. Write to answer.txt one `path count` per line, such as `cosmic/agent/x_test.tl 9`, most first, ties by path.",
    truth = "for f in $(find cosmic/agent -name '*_test.tl'); do " ..
      "echo \"$f $(grep -c '^local function test_' \"$f\")\"; done | sort -k2,2nr -k1,1",
    check = "cat answer.txt",
  },
  {
    name = "undocumented",
    prompt = "In the .tl files under cosmic/agent/ whose names do not end in _test.tl, find each line that " ..
      "starts `local function <name>(` where the line just before it does not start with `---`. Write to " ..
      "answer.txt one `path:line name` per line, such as `cosmic/agent/x.tl:40 helper`, sorted by path, then by line.",
    truth = [==[find cosmic/agent -name '*.tl' ! -name '*_test.tl' | sort | xargs awk 'FNR==1{prev=""} /^local function [A-Za-z_][A-Za-z0-9_]*\(/ { if (prev !~ /^---/) { n=$3; sub(/\(.*/,"",n); print FILENAME":"FNR" "n } } {prev=$0}' | sort -t: -k1,1 -k2,2n]==],
    check = "cat answer.txt",
  },
  {
    name = "fan-in",
    prompt = "For each .tl file directly in cosmic/ (not in a subdirectory, and not ending in _test.tl), say " ..
      "cosmic/<x>.tl, count the other .tl files anywhere under cosmic/ that hold the text `require(\"cosmic.<x>\")`. " ..
      "Write to answer.txt the ten with the most, as `count cosmic.<x>`, such as `31 cosmic.x`, most first, ties by name.",
    truth = [==[for f in $(find cosmic -maxdepth 1 -name '*.tl' ! -name '*_test.tl'); do m=$(basename "$f" .tl); n=$(grep -rlF --include='*.tl' "require(\"cosmic.$m\")" cosmic | grep -vx "$f" | wc -l); echo "$n cosmic.$m"; done | sort -k1,1nr -k2,2 | head -10]==],
    check = "cat answer.txt",
  },
  {
    name = "two-hop",
    prompt = "Take each distinct module cosmic/agent/init.tl names as `require(\"cosmic.<...>\")`. Its file is " ..
      "cosmic/<the name's parts as directories>.tl, or .../init.tl where that is missing (cosmic.agent.tools is " ..
      "cosmic/agent/tools.tl). Write to answer.txt each module's line count, as `wc -l` counts, as " ..
      "`count module`, the module's whole name as init.tl writes it (`120 cosmic.agent.tools`), most first, " ..
      "ties by name.",
    truth = [==[for m in $(grep -o 'require("cosmic\.[^"]*")' cosmic/agent/init.tl | sed 's/require("//; s/")//' | sort -u); do p=cosmic/$(echo "${m#cosmic.}" | tr . /); if [ -f "$p.tl" ]; then f=$p.tl; else f=$p/init.tl; fi; echo "$(wc -l < "$f") $m"; done | sort -k1,1nr -k2,2]==],
    check = "cat answer.txt",
  },
  {
    name = "rename-many",
    prompt = "Rename the constant MAX_BYTES to BYTES_MOST in every .tl file under cosmic/ that has it, " ..
      "everywhere it appears as a whole word, and change nothing else.",
    truth = "files=$(grep -rlw --include='*.tl' 'MAX_BYTES' cosmic | sort); [ -n \"$files\" ] && " ..
      "for f in $files; do echo \"$f\"; sed 's/\\<MAX_BYTES\\>/BYTES_MOST/g' \"$f\"; done | sha256sum | cut -c1-64",
    check = "for f in $(grep -rlw --include='*.tl' 'BYTES_MOST' cosmic | sort); do echo \"$f\"; cat \"$f\"; done | " ..
      "sha256sum | cut -c1-64",
  },
  {
    name = "sqlite",
    prompt = "Make files.db, a SQLite database with a table files(dir text, path text, lines integer): one row " ..
      "for each .tl file under cosmic/, `lines` as `wc -l` counts them and `dir` the path's directory " ..
      "(cosmic, or cosmic/x/y). Then, with SQL on it, write to answer.txt one `dir count lines` per line, the files " ..
      "and lines of each dir, such as `cosmic/x 4 812`: the ten dirs of the most lines, most first, ties by dir.",
    truth = "echo 'SQLite format 3'; find cosmic -name '*.tl' -type f -exec wc -l {} + | grep -v ' total$' | " ..
      "awk '{d=$2; sub(/\\/[^\\/]*$/, \"\", d); c[d]++; l[d] += $1} END {for (d in c) print d\" \"c[d]\" \"l[d]}' | " ..
      "sort -k3,3nr -k1,1 | head -10",
    check = "head -c 15 files.db; echo; cat answer.txt",
  },
  {
    name = "hashes",
    prompt = "Write to answer.txt the SHA-256 of each .md file directly in doc/guides/ (not in a subdirectory), " ..
      "as `sha256sum` prints it (`<hex>  doc/guides/x.md`), one a line, sorted by path.",
    truth = "for f in $(find doc/guides -maxdepth 1 -name '*.md' -type f | sort); do sha256sum \"$f\"; done",
    check = "cat answer.txt",
  },
  {
    name = "rename",
    prompt = "In cosmic/agent/tools.tl, rename the constant MAX_LINES to MOST_LINES everywhere it appears, " ..
      "and change nothing else.",
    truth = "n=$(grep -o 'MAX_LINES' cosmic/agent/tools.tl | wc -l); [ \"$n\" -gt 0 ] && " ..
      "{ sed 's/MAX_LINES/MOST_LINES/g' cosmic/agent/tools.tl | sha256sum | cut -c1-64; }",
    check = "sha256sum cosmic/agent/tools.tl | cut -c1-64",
  },
  {
    name = "imports",
    prompt = "Across the .tl files under cosmic/agent/, count each `require(\"cosmic.<...>\")` text, every time it " ..
      "appears. Write to answer.txt the five modules named most, as `count cosmic.<...>`, such as `12 cosmic.x`, most first, ties by name.",
    truth = [==[grep -rho --include='*.tl' 'require("cosmic\.[^"]*")' cosmic/agent | sed 's/require("//; s/")//' | sort | uniq -c | awk '{print $1" "$2}' | sort -k1,1nr -k2,2 | head -5]==],
    check = "cat answer.txt",
  },
  {
    name = "header",
    prompt = "cosmic/agent/tools.tl starts with a block of lines that each start `---`. Replace that whole block, " ..
      "its first line too, with the one line `--- The tools of cosmic agent.` and change nothing else.",
    truth = [==[head -1 cosmic/agent/tools.tl | grep -q '^---' && awk 'h && /^---/ {next} h {print "--- The tools of cosmic agent."; h=0} {print}' h=1 cosmic/agent/tools.tl | sha256sum | cut -c1-64]==],
    check = "sha256sum cosmic/agent/tools.tl | cut -c1-64",
  },
  {
    name = "mcp-value",
    prompt = "The inventory MCP server lists items and tells each one's category, price in cents and stock. " ..
      "Write to answer.txt, for each category, the sum over its items of price_cents times stock, as " ..
      "`sum category`, such as `123456 shoes`, one a line, largest first, ties by category.",
    truth = "awk -F'\\t' '{s[$3] += $4 * $5} END {for (c in s) print s[c]\" \"c}' \"$data\" | sort -k1,1nr -k2,2",
    check = "cat answer.txt",
    servers = { { name = "inventory", source = INVENTORY_SERVER, data = inventory() } },
  },
  {
    name = "mcp-low",
    prompt = "Write to answer.txt each item of the inventory MCP server whose stock is below 3, as `id stock`, such as `i9999 2`, " ..
      "one a line, sorted by id.",
    truth = "awk -F'\\t' '$5 < 3 {print $1\" \"$5}' \"$data\" | sort",
    check = "cat answer.txt",
    servers = { { name = "inventory", source = INVENTORY_SERVER, data = inventory() } },
  },
  {
    name = "mcp-many-low",
    prompt = "Write to answer.txt each item of the warehouse whose stock is below 3, as `id stock`, such as `i9999 2`, one a line, " ..
      "sorted by id.",
    truth = "awk -F'\\t' '$5 < 3 {print $1\" \"$5}' \"$data\" | sort",
    check = "cat answer.txt",
    servers = many_servers(),
  },
  {
    name = "mcp-many-value",
    prompt = "Write to answer.txt, for each category of the warehouse's items, the sum over its items of price " ..
      "in cents times stock, as `sum category`, such as `123456 shoes`, one a line, largest first, ties by category.",
    truth = "awk -F'\\t' '{s[$3] += $4 * $5} END {for (c in s) print s[c]\" \"c}' \"$data\" | sort -k1,1nr -k2,2",
    check = "cat answer.txt",
    servers = many_servers(),
  },
  {
    name = "web-low",
    prompt = "The inventory web API at {url} answers GET /items?page=N, from page 1, with JSON: `items`, each " ..
      "with id, name, category, price_cents and stock, and `next`, the page after it, which the last page has " ..
      "not. Write to answer.txt each item whose stock is below 3, as `id stock`, such as `i9999 2`, one a line, sorted by id.",
    truth = "awk -F'\\t' '$5 < 3 {print $1\" \"$5}' \"$data\" | sort",
    check = "cat answer.txt",
    site = { source = INVENTORY_SITE, data = inventory() },
  },
  {
    name = "web-csv",
    prompt = "The web API at {url} serves the sales as CSV at GET /sales.csv, with a header row " ..
      "`region,customer,amount_cents`. Write to answer.txt, for each customer, the sum of its amount_cents, as " ..
      "`sum customer`, the name as it reads unquoted, such as `5000 Zephyr Goods`, one a line, largest first, ties by customer in byte order.",
    truth = "awk -F'\\t' '{s[$2] += $3} END {for (c in s) print s[c]\" \"c}' \"$data\" | LC_ALL=C sort -k1,1nr -k2",
    check = "cat answer.txt",
    site = { source = SALES_SITE, data = sales() },
  },
  {
    name = "earlier-log",
    prompt = "The web API at {url} serves its event log as plain text at GET /log: lines of " ..
      "`HH:MM:SS LEVEL component message`. Print the log.",
    follow_up = "Write to answer.txt, for each component, how many lines of that log have level ERROR, as " ..
      "`count component`, such as `3 mailer`, one a line, most first, ties by component.",
    truth = "awk '$2 == \"ERROR\" {n[$3]++} END {for (c in n) print n[c]\" \"c}' \"$data\" | sort -k1,1nr -k2,2",
    check = "cat answer.txt",
    site = { source = LOG_SITE, data = event_log() },
  },
  {
    name = "docedit",
    prompt = "In cosmic/compress.tl, before each line that starts `local function <name>(`, such as " ..
      "`local function helper(`, where the line just before it does not start with `---`, insert the line `--- TODO: say what this does.`, and change " ..
      "nothing else.",
    truth = [==[n=$(awk '/^local function [A-Za-z_][A-Za-z0-9_]*\(/ && prev !~ /^---/ {n++} {prev=$0} END {print n+0}' cosmic/compress.tl); [ "$n" -gt 0 ] && awk '/^local function [A-Za-z_][A-Za-z0-9_]*\(/ && prev !~ /^---/ {print "--- TODO: say what this does."} {print; prev=$0}' cosmic/compress.tl | sha256sum | cut -c1-64]==],
    check = "sha256sum cosmic/compress.tl | cut -c1-64",
  },
  {
    name = "json-legs",
    prompt = "ci/cosmic_ci/capabilities.json has a `legs` object of arrays of strings. For each leg, count its " ..
      "strings that start `program:`. Write to answer.txt one `count leg` per line, such as `7 linux-x`, most first, ties by name.",
    truth = [==[jq -r '.legs | to_entries[] | "\([.value[] | select(startswith("program:"))] | length) \(.key)"' ci/cosmic_ci/capabilities.json | sort -k1,1nr -k2,2]==],
    check = "cat answer.txt",
  },
  {
    name = "error-lines",
    prompt = "Write to answer.txt every line of the non-test .tl files directly in cosmic/agent/ that holds " ..
      "`error(`, as `path:line`, such as `cosmic/agent/x.tl:12` (line numbered from 1), one a line, sorted by path, then by line.",
    truth = "for f in $(find cosmic/agent -maxdepth 1 -name '*.tl' ! -name '*_test.tl' | sort); do " ..
      "grep -n 'error(' \"$f\" | cut -d: -f1 | sed \"s|^|$f:|\"; done | sort -t: -k1,1 -k2,2n",
    check = "cat answer.txt",
  },
  {
    name = "append-many",
    prompt = "Add the line `-- end` at the end of each non-test .tl file directly in cosmic/agent/, and change nothing else.",
    truth = "for f in $(find cosmic/agent -maxdepth 1 -name '*.tl' ! -name '*_test.tl' | sort); do " ..
      "echo \"$f\"; cat \"$f\"; echo '-- end'; done | sha256sum | cut -c1-64",
    check = "for f in $(find cosmic/agent -maxdepth 1 -name '*.tl' ! -name '*_test.tl' | sort); do " ..
      "echo \"$f\"; cat \"$f\"; done | sha256sum | cut -c1-64",
  },
  {
    name = "tested-modules",
    prompt = "Take each distinct module cosmic/agent/host.tl names as `require(\"cosmic.<...>\")`. For each, count the " ..
      "_test.tl files directly in cosmic/agent/ that hold the text `require(\"<the module>\")`. Write to answer.txt " ..
      "`count module` for each module with a count of 1 or more, such as `3 cosmic.x`, most first, ties by name.",
    truth = [==[for m in $(grep -o 'require("cosmic\.[^"]*")' cosmic/agent/host.tl | sed 's/require("//; s/")//' | sort -u); do n=$(grep -lF "require(\"$m\")" cosmic/agent/*_test.tl 2>/dev/null | wc -l); [ "$n" -ge 1 ] && echo "$n $m"; done | sort -k1,1nr -k2,2]==],
    check = "cat answer.txt",
  },
  {
    name = "darwin-dirs",
    prompt = "ci/darwin-tests.txt lists test modules, one a line, with comment lines that start `#` and blank " ..
      "lines. For each first path component of the listed paths (`cosmic` in `cosmic/x_test.tl`), count its listed " ..
      "paths. Write to answer.txt `count dir` per line, such as `4 cosmic`, most first, ties by name.",
    truth = "grep -v '^#' ci/darwin-tests.txt | grep -v '^[[:space:]]*$' | awk -F/ '{n[$1]++} END {for (d in n) print n[d]\" \"d}' | sort -k1,1nr -k2,2",
    check = "cat answer.txt",
  },
  {
    name = "longest-lines",
    prompt = "For each non-test .tl file directly in cosmic/agent/, find the length in bytes of its longest line. " ..
      "Write to answer.txt the five files with the longest, as `length path`, such as `140 cosmic/agent/x.tl`, " ..
      "longest first, ties by path.",
    truth = "for f in $(find cosmic/agent -maxdepth 1 -name '*.tl' ! -name '*_test.tl'); do " ..
      "echo \"$(LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' \"$f\") $f\"; done | " ..
      "sort -k1,1nr -k2,2 | head -5",
    check = "cat answer.txt",
  },
  {
    name = "rename-shared",
    prompt = "In cosmic/, rename the function format of cosmic/web/cookies.tl (`Cookies.format`) to render, " ..
      "everywhere it is defined, called or named as `Cookies.format` in the .tl files, and change nothing else, " ..
      "comment prose too: other functions named format (Csp.format, Json.format, Example.format, string.format) stay.",
    truth = "n=$(grep -rl --include='*.tl' 'Cookies\\.format' cosmic | wc -l); [ \"$n\" -gt 0 ] && " ..
      "{ for f in $(find cosmic -name '*.tl' | sort); do echo \"$f\"; sed 's/Cookies\\.format\\>/Cookies.render/g' \"$f\"; done | " ..
      "sha256sum | cut -c1-64; }",
    check = "for f in $(find cosmic -name '*.tl' | sort); do echo \"$f\"; cat \"$f\"; done | sha256sum | cut -c1-64",
  },
  {
    name = "write-wordfreq",
    prompt = "Write top.tl in this directory: a cosmic program (Teal, checked) that takes the path of a text file as " ..
      "its first argument and prints the five most frequent words, a word being a run of the letters a to z once " ..
      "lowercased, as `count word`, such as `12 the`, most first, ties by word. It must pass `cosmic --standalone --check top.tl`.",
    truth = "cat doc/guides/*.md | tr 'A-Z' 'a-z' | grep -oE '[a-z]+' | sort | uniq -c | awk '{print $1\" \"$2}' | " ..
      "sort -k1,1nr -k2,2 | head -5",
    check = "cat doc/guides/*.md > all.txt; $tool --standalone --check top.tl > /dev/null 2>&1 && $tool --standalone top.tl all.txt",
  },
  {
    name = "write-dirs",
    prompt = "Write dirs.tl in this directory: a cosmic program (Teal, checked) that takes a directory as its first " ..
      "argument and prints, for each directory directly inside it, how many .tl files lie under that directory (at any " ..
      "depth), as `count path` with the path as the argument and the name joined by `/` (`cosmic/web`), such as " ..
      "`40 cosmic/web`, most first, ties by path. It must pass `cosmic --standalone --check dirs.tl`.",
    truth = "for d in $(find cosmic -mindepth 1 -maxdepth 1 -type d | sort); do echo \"$(find $d -name '*.tl' | wc -l) $d\"; done | " ..
      "sort -k1,1nr -k2,2",
    check = "$tool --standalone --check dirs.tl > /dev/null 2>&1 && $tool --standalone dirs.tl cosmic",
  },
  {
    name = "fix-bug",
    prompt = "Ranges.merge in eval/plant/ranges.tl has a bug: ranges that touch or share an end must join (`1-3` and " ..
      "`4-6` cover 1 to 6 with no gap, and `1-3` and `3-5` overlap), but it leaves them apart. Fix the bug and " ..
      "change nothing else. Its tests, eval/plant/ranges_test.tl, run with `cosmic test eval/plant/ranges_test.tl`.",
    truth = "echo pass",
    check = [==[mkdir mini && cp eval/plant/ranges.tl mini/ranges.tl && cp eval/plant/ranges_test.tl mini/ranges_test.tl && sed -i 's/eval\.plant\.ranges/ranges/' mini/ranges_test.tl && cat > mini/hidden_test.tl <<'EOF'
local Ranges = require("ranges")

local function show(list: {Ranges.Range}): string
  local parts: mut {string} = {}
  for _, r in ipairs(list) do parts[#parts + 1] = tostring(r.first) .. "-" .. tostring(r.last) end
  return table.concat(parts, ",")
end

local function test_touching_ranges_join()
  assert(show(Ranges.merge({ { first = 1, last = 3 }, { first = 4, last = 6 } })) == "1-6")
end

local function test_a_shared_end_joins()
  assert(show(Ranges.merge({ { first = 1, last = 3 }, { first = 3, last = 5 } })) == "1-5")
end

local function test_a_gap_stays()
  assert(show(Ranges.merge({ { first = 1, last = 3 }, { first = 5, last = 6 } })) == "1-3,5-6")
end
EOF
if (cd mini && $tool test > /dev/null 2>&1); then echo pass; else echo fail; fi]==],
  },
  {
    name = "fix-rle",
    prompt = "Rle in eval/plant/rle.tl does not round-trip: decoding what encode wrote does not always answer the " ..
      "first text (try `abc` and a run of twelve `a`). Find the bugs and fix them, and change nothing else. Its " ..
      "tests are eval/plant/rle_test.tl; run them with `cosmic test eval/plant/rle_test.tl`.",
    truth = "echo pass",
    check = [==[mkdir mini && cp eval/plant/rle.tl mini/rle.tl && cat > mini/hidden_test.tl <<'EOF'
local Rle = require("rle")

local function test_a_text_round_trips()
  for _, text in ipairs({ "abc", "aaabcc", "zzzzzzzzzzzzq", "x", "aabbaabb" }) do
    assert(Rle.decode(Rle.encode(text)) == text, text)
  end
end

local function test_encode_writes_every_run()
  assert(Rle.encode("aaabcc") == "3a1b2c", Rle.encode("aaabcc"))
  assert(Rle.encode("abc") == "1a1b1c")
end

local function test_a_length_has_many_digits()
  assert(Rle.decode("12a2b") == "aaaaaaaaaaaabb")
  assert(Rle.encode("aaaaaaaaaaaa") == "12a")
end
EOF
if (cd mini && $tool test > /dev/null 2>&1); then echo pass; else echo fail; fi]==],
  },
  {
    name = "fix-calc",
    prompt = "Calc.eval in eval/plant/calc.tl answers wrong values: it should give `2-3-4` = -5, `10-4-3` = 3, " ..
      "`2^3^2` = 512 (`^` groups from the right) and `-2^2` = -4 (`^` binds tighter than a minus before it), and " ..
      "keep `10/4/5` = 0.5, `2*3+4` = 10 and `(1+2)*3` = 9. Find the bugs and fix them, and change nothing else. " ..
      "Its tests are eval/plant/calc_test.tl; run them with `cosmic test eval/plant/calc_test.tl`.",
    truth = "echo pass",
    check = [==[mkdir mini && cp eval/plant/calc.tl mini/calc.tl && cat > mini/hidden_test.tl <<'EOF'
local Calc = require("calc")

local function test_minus_groups_from_the_left()
  assert(Calc.eval("2-3-4") == -5)
  assert(Calc.eval("10-4-3") == 3)
  assert(Calc.eval("1-2+3") == 2)
end

local function test_a_power_groups_from_the_right()
  assert(Calc.eval("2^3^2") == 512)
end

local function test_a_power_binds_tighter_than_a_minus()
  assert(Calc.eval("-2^2") == -4)
  assert(Calc.eval("-(1+2)") == -3)
  assert(Calc.eval("2*-3") == -6)
end

local function test_the_rest_holds()
  assert(Calc.eval("10/4/5") == 0.5)
  assert(Calc.eval("2*3+4") == 10)
  assert(Calc.eval("(1+2)*3") == 9)
end
EOF
if (cd mini && $tool test > /dev/null 2>&1); then echo pass; else echo fail; fi]==],
  },
}

local USAGE <const> = "usage: eval/agent --tool NAME=PATH [--tool NAME=PATH ...] --fixture DIR --out DIR " ..
  "[--offer NAME=TOOL,...] [--effort [NAME=]LEVEL] [--tasks T,...|all] [--reps N] [--model M] [--timeout S]"

local EFFORTS <const>: {string: boolean} = { low = true, medium = true, high = true, xhigh = true, max = true }

local function positive(text: string): integer?
  if not text:match("^[1-9]%d*$") then return nil end
  return math.tointeger(tonumber(text))
end

--- Reads the command line. `--reps` is 2, `--model` sonnet, `--timeout` 1200 and `--tasks` all unless given.
function Agent.parse(argv: {string}): Agent.Options?, string
  local tools: mut {Agent.Tool} = {}
  local offers: mut {string: string} = {}
  local efforts: mut {string: string} = {}
  local effort: string? = nil
  local fixture, out, model = "", "", "sonnet"
  local reps, timeout = 2, 1200
  local tasks: mut {Agent.Task} = {}
  for _, t in ipairs(Agent.tasks) do tasks[#tasks + 1] = t end
  local i = 1
  while argv[i] ~= nil do
    local word, value = argv[i], argv[i + 1]
    if value == nil then return nil, word .. " needs a value; " .. USAGE end
    if word == "--tool" then
      local name, path = value:match("^([%w_-]+)=(.+)$")
      if name == nil or path == nil then return nil, "--tool takes NAME=PATH: " .. value end
      -- A run starts the tool from its work copy: a path is absolute, or a bare name found on PATH.
      if path:find("/", 1, true) ~= nil and path:sub(1, 1) ~= "/" then
        return nil, "--tool " .. name .. ": give an absolute path or a name on PATH, not " .. path
      end
      for _, t in ipairs(tools) do
        if t.name == name then return nil, "two tools named " .. name end
      end
      tools[#tools + 1] = { name = name, path = path }
    elseif word == "--offer" then
      local name, list = value:match("^([%w_-]+)=(.+)$")
      if name == nil or list == nil then
        return nil, "--offer takes NAME=TOOL,TOOL,...: " .. value
      end
      local found = false
      for _, t in ipairs(tools) do
        if t.name == name then found = true end
      end
      if not found then return nil, "--offer " .. name .. ": name a --tool given before it" end
      offers[name] = list
    elseif word == "--effort" then
      local name, level = value:match("^([%w_-]+)=(.+)$")
      local wanted = level or value
      if EFFORTS[wanted] ~= true then
        return nil, "--effort takes low, medium, high, xhigh or max, or NAME=LEVEL: " .. value
      end
      if name == nil then
        effort = wanted
      else
        local found = false
        for _, t in ipairs(tools) do
          if t.name == name then found = true end
        end
        if not found then return nil, "--effort " .. name .. ": name a --tool given before it" end
        efforts[name] = wanted
      end
    elseif word == "--fixture" then
      fixture = value
    elseif word == "--out" then
      out = value
    elseif word == "--model" then
      model = value
    elseif word == "--tasks" then
      local picked: mut {Agent.Task} = {}
      for name in value:gmatch("[^,]+") do
        local found: Agent.Task? = nil
        for _, t in ipairs(Agent.tasks) do
          if t.name == name or name == "all" then
            if name ~= "all" then found = t end
          end
        end
        if name == "all" then
          for _, t in ipairs(Agent.tasks) do picked[#picked + 1] = t end
        elseif found == nil then
          return nil, "no task " .. name
        else
          picked[#picked + 1] = found
        end
      end
      tasks = picked
    elseif word == "--reps" or word == "--timeout" then
      local n = positive(value)
      if n == nil then return nil, word .. " takes a positive integer: " .. value end
      if word == "--reps" then reps = n else timeout = n end
    else
      return nil, "unknown option " .. word .. "; " .. USAGE
    end
    i = i + 2
  end
  if #tools == 0 then return nil, "--tool is required; " .. USAGE end
  if fixture == "" or out == "" then return nil, "--fixture and --out are required; " .. USAGE end
  -- The runs read and write them from other directories, and eval/agent runs from the checkout's root.
  if fixture:sub(1, 1) ~= "/" or out:sub(1, 1) ~= "/" then
    return nil, "--fixture and --out take absolute paths: " .. (if fixture:sub(1, 1) ~= "/" then fixture else out end)
  end
  if #tasks == 0 then return nil, "--tasks names no task" end
  local offering: mut {Agent.Tool} = {}
  for _, t in ipairs(tools) do
    offering[#offering + 1] = { name = t.name, path = t.path, tools = offers[t.name], effort = efforts[t.name] or effort }
  end
  return { tools = offering, fixture = fixture, out = out, tasks = tasks, reps = reps, model = model,
    timeout = timeout }, ""
end

--- `text`'s lines, each without its trailing blanks, and with no blank lines at its end: what grading compares.
function Agent.lines_of(text: string): string
  local out: mut {string} = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = (line:gsub("%s+$", "")) end
  while #out > 0 and out[#out] == "" do out[#out] = nil end
  return table.concat(out, "\n")
end

--- The environment a run of `tool` gets: `base`, with `key` and its own data directory and home.
local function env_of(base: {string: string}, key: string, data: string, home: string): {string: string}
  local e: mut {string: string} = {}
  for k, v in pairs(base) do e[k] = v end
  e["ANTHROPIC_API_KEY"] = key
  e["HARNESS_ANTHROPIC_API_KEY"] = nil
  e["XDG_DATA_HOME"] = data
  e["HOME"] = home
  -- The web API's 127.0.0.1 is this host's: a relay behind an https_proxy reaches only what no_proxy names directly.
  for _, name in ipairs({ "NO_PROXY", "no_proxy" }) do
    local listed = e[name]
    e[name] = if listed ~= nil and listed ~= "" then listed .. ",127.0.0.1" else "127.0.0.1" end
  end
  return e
end

--- `text` quoted for bash.
local function quoted(text: string): string
  return "'" .. (text:gsub("'", "'\\''")) .. "'"
end

--- Lays out `servers` for a run of `tool` in a fresh directory, through `system`: each one's program and data in a
--- directory of its name, and the config naming them all, each held to reading its own directory. Every user may
--- read them: where the agent is root, its servers run as a user of their own. The config's path.
local function laid_out(system: Agent.System, given: {Agent.Server}, tool: Agent.Tool, prefix: string): string
  local dir = system.fresh(prefix)
  local servers: mut {string: Json.Value} = {}
  for _, server in ipairs(given) do
    local own = dir .. "/" .. server.name
    system.put(own .. "/server.tl", server.source)
    system.put(own .. "/data.tsv", server.data)
    local entry: mut {string: Json.Value} = {
      command = Json.array({ tool.path, "--standalone", own .. "/server.tl", own .. "/data.tsv" }),
      policy = { grants = Json.array({ { path = own, letters = "r" } }) },
    }
    local about = server.about
    if about ~= nil then entry["description"] = about end
    servers[server.name] = entry
  end
  local encoded = assert(Json.encode({ servers = servers }))
  system.put(dir .. "/mcp.json", encoded)
  local opened = system.run({ "chmod", "-R", "a+rX", dir }, "/", nil, 60)
  assert(opened.code == 0, "chmod " .. dir .. ": " .. opened.stderr)
  return dir .. "/mcp.json"
end

--- Runs every task of `options` `reps` times with each tool, through `system`, with `key` and `base` the
--- environment; each run's answer goes to `write`. The results, in order.
function Agent.execute(options: Agent.Options, system: Agent.System, key: string, base: {string: string},
                       write: function(string, string)): {Agent.Result}
  -- Every directory the evals make, each removed once it is used, and all that are left where a step raises.
  local made: mut {string} = {}
  local function sweep()
    for _, dir in ipairs(made) do system.discard(dir) end
    made = {}
  end
  local own: Agent.System = {
    run = system.run,
    fresh = function(prefix: string): string
      local dir = system.fresh(prefix)
      made[#made + 1] = dir
      return dir
    end,
    discard = system.discard,
    spent = system.spent,
    put = system.put,
    serve = system.serve,
  }
  local ran, got = pcall(function(): {Agent.Result}
    local results: mut {Agent.Result} = {}
    local truths: mut {string: string} = {}
    for _, task in ipairs(options.tasks) do
      local pristine = own.fresh("truth-" .. task.name .. "-")
      own.run({ "cp", "-a", options.fixture .. "/.", pristine }, "/", nil, 600)
      local script = task.truth
      local first = task.servers and task.servers[1]
      local site = task.site
      local served: string? = if first ~= nil then first.data elseif site ~= nil then site.data else nil end
      local data_dir: string? = nil
      if served ~= nil then
        data_dir = own.fresh("data-" .. task.name .. "-")
        local data = data_dir .. "/data.tsv"
        own.put(data, served)
        script = "data=" .. quoted(data) .. "; " .. script
      end
      local truth = own.run({ "bash", "-c", script }, pristine, nil, 60)
      truths[task.name] = Agent.lines_of(truth.stdout)
      sweep()
    end
    for _, tool in ipairs(options.tools) do
      local data, home = options.out .. "/" .. tool.name .. "/data", options.out .. "/" .. tool.name .. "/home"
      own.run({ "mkdir", "-p", data, home }, "/", nil, 60)
      local env = env_of(base, key, data, home)
      for _, task in ipairs(options.tasks) do
        for rep = 1, options.reps do
          local marker = "bench-" .. tool.name .. "-" .. task.name .. "-"
          local work = own.fresh(marker)
          own.run({ "cp", "-a", options.fixture .. "/.", work }, "/", nil, 600)
          local argv: mut {string} = { tool.path, "agent", "ask", "--model", options.model }
          local effort = tool.effort
          if effort ~= nil then
            argv[#argv + 1] = "--effort"
            argv[#argv + 1] = effort
          end
          local offered = tool.tools
          if offered ~= nil then
            argv[#argv + 1] = "--tools"
            argv[#argv + 1] = offered
          end
          local servers = task.servers
          if servers ~= nil then
            local config = laid_out(own, servers, tool, "mcp-" .. tool.name .. "-" .. task.name .. "-")
            argv[#argv + 1] = "--mcp"
            argv[#argv + 1] = config
          end
          local prompt = task.prompt
          local stop: function() = function() end
          local unserved: string? = nil
          local site = task.site
          if site ~= nil then
            local dir = own.fresh("site-" .. tool.name .. "-" .. task.name .. "-")
            own.put(dir .. "/site.tl", site.source)
            own.put(dir .. "/data.tsv", site.data)
            local port, ended = own.serve({ tool.path, "--standalone", dir .. "/site.tl", dir .. "/data.tsv",
              dir .. "/port" }, dir, dir .. "/port", 60)
            if port == nil then
              unserved = "the web API did not start: " .. tostring(ended)
            else
              stop = ended
              argv[#argv + 1] = "--connect"
              argv[#argv + 1] = "127.0.0.1:" .. port
              prompt = (prompt:gsub("{url}", "http://127.0.0.1:" .. port))
            end
          end
          local follow_up = task.follow_up
          local again: mut {string} = {}
          for _, word in ipairs(argv) do again[#again + 1] = word end
          argv[#argv + 1] = prompt
          -- A run that raises still ends the web API.
          local asked: Agent.Output = { code = 127, stdout = "", stderr = unserved or "" }
          local ran, why = pcall(function()
            if unserved ~= nil then return end
            asked = own.run(argv, work, env, options.timeout)
            if follow_up == nil or asked.code ~= 0 then return end
            again[#again + 1] = follow_up
            local next_asked = own.run(again, work, env, options.timeout)
            asked = { code = next_asked.code, stdout = asked.stdout .. "\n--- follow-up\n" .. next_asked.stdout,
              stderr = asked.stderr .. "\n--- follow-up\n" .. next_asked.stderr,
              seconds = (asked.seconds or 0) + (next_asked.seconds or 0) }
          end)
          stop()
          if not ran then error(why, 0) end
          local truth = truths[task.name] or ""
          local left = Agent.lines_of(own.run({ "bash", "-c", "tool=" .. quoted(tool.path) .. "; " .. task.check }, work, nil, 60).stdout)
          local grade = "fail"
          if truth == "" then grade = "unfit" elseif left == truth then grade = "pass" end
          write(options.out .. "/" .. tool.name .. "/" .. task.name .. "-" .. tostring(rep) .. ".txt",
            "grade: " .. grade .. "\nexit: " .. tostring(asked.code) .. "\n--- left\n" .. left .. "\n--- truth\n" ..
              truth .. "\n--- words\n" .. asked.stdout .. "\n--- stderr\n" .. asked.stderr .. "\n")
          results[#results + 1] = { tool = tool.name, task = task.name, rep = rep, grade = grade,
            spent = own.spent(tool.name, work:match("[^/]+$") or marker), wall = asked.seconds or 0 }
          sweep()
        end
      end
    end
    return results
  end)
  sweep()
  if not ran then error(got, 0) end
  return got
end

--- What the session of a run spent, from `db`: the newest session whose directory's name holds `marker`.
function Agent.spent_in(db: Sqlite.Handle, marker: string): Agent.Spent?
  local found, _ = db:rows("SELECT id FROM sessions WHERE instr(cwd, ?1) > 0 ORDER BY id DESC LIMIT 1",
    { { text = marker } })
  local row = found and found[1]
  if row == nil then return nil end
  local id = row:integer(1)
  local r, _ = db:rows("SELECT count(*), coalesce(sum(input_tokens), 0), coalesce(sum(output_tokens), 0), " ..
      "coalesce(sum(cache_read), 0), coalesce(sum(coalesce(cache_write_5m, 0) + coalesce(cache_write_1h, 0)), 0), " ..
      "coalesce(sum(cost), 0.0), coalesce(sum(ms), 0) FROM requests WHERE session = ?1", { { integer = id } })
  local o, _ = db:rows("SELECT count(*), coalesce(sum(tool = 'run'), 0) FROM outputs WHERE session = ?1",
    { { integer = id } })
  local snippets, _ = db:rows("SELECT input FROM outputs WHERE session = ?1 AND tool = 'run'",
    { { integer = id } })
  -- A helper's name starts with a small letter (Host.Count is a record type), after no other word (MyHost.x).
  local helpers: mut {string: integer} = {}
  for _, snippet in ipairs(snippets or {}) do
    local seen: mut {string: boolean} = {}
    -- The code as the snippet has it, not its JSON, where `\nHost.x` would hide a helper that starts a line.
    local input = snippet:text(1)
    local fields, _ = Json.decode_object(input)
    local code = fields and fields["code"]
    local text = if code is string then code else input end
    for name in text:gmatch("%f[%w_]Host%.([%l_][%w_]*)") do
      if seen[name] == nil then
        seen[name] = true
        helpers[name] = (helpers[name] or 0) + 1
      end
    end
  end
  local first, _ = db:rows("SELECT coalesce(cache_read, 0) FROM requests WHERE session = ?1 AND status = 200 ORDER BY rowid " ..
      "LIMIT 1", { { integer = id } })
  local refusals, _ = db:rows("SELECT text FROM outputs WHERE session = ?1 AND tool = 'run' AND " ..
      "instr(text, 'The checker refused the snippet') = 1", { { integer = id } })
  local codes: mut {string: integer} = {}
  for _, refusal in ipairs(refusals or {}) do
    local seen: mut {string: boolean} = {}
    for code in refusal:text(1):gmatch("%(([%l_]+)%):") do
      if seen[code] == nil then
        seen[code] = true
        codes[code] = (codes[code] or 0) + 1
      end
    end
  end
  local req, out = r and r[1], o and o[1]
  if req == nil or out == nil then return nil end
  local opened = first and first[1]
  return { requests = req:integer(1), input = req:integer(2), output = req:integer(3), cache_read = req:integer(4),
    cache_write = req:integer(5), cost = req:number(6), seconds = req:integer(7) / 1000, tools = out:integer(1),
    runs = out:integer(2), refused = #(refusals or {}), codes = codes, helpers = helpers,
    first_read = if opened ~= nil then opened:integer(1) else 0 end }
end

--- `counts` as "key n, key n", most first, ties by key, each count written by `show`; nil when empty.
local function ranked(counts: {string: integer}, show: function(k: integer): string): string?
  local keys: mut {string} = {}
  for key in pairs(counts) do keys[#keys + 1] = key end
  if #keys == 0 then return nil end
  table.sort(keys, function(a: string, b: string): boolean
    local ka, kb = counts[a] or 0, counts[b] or 0
    if ka ~= kb then return ka > kb end
    return a < b
  end)
  local parts: mut {string} = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = key .. " " .. show(counts[key] or 0)
  end
  return table.concat(parts, ", ")
end

--- The report of `results` for `options`: for each task, each tool's passes and mean spending per run, as
--- Markdown, which the text template eval/report.tmpl writes.
function Agent.report(options: Agent.Options, results: {Agent.Result}): string
  local set: mut {string} = {}
  for _, tool in ipairs(options.tools) do
    local effort = tool.effort
    if effort ~= nil then set[#set + 1] = tool.name .. " " .. effort end
  end
  -- Each tool over every task: what a comparison reads first.
  local totals: mut {ReportData.Total} = {}
  for _, tool in ipairs(options.tools) do
    local passed, n, unfit, counted = 0, 0, 0, 0
    local cost, write, read, output = 0.0, 0.0, 0.0, 0.0
    for _, r in ipairs(results) do
      if r.tool == tool.name and r.grade == "unfit" then
        unfit = unfit + 1
      elseif r.tool == tool.name then
        n = n + 1
        if r.grade == "pass" then passed = passed + 1 end
        local spent = r.spent
        if spent ~= nil then
          counted = counted + 1
          cost, write = cost + spent.cost, write + spent.cache_write
          read, output = read + spent.cache_read, output + spent.output
        end
      end
    end
    local d = math.max(counted, 1)
    totals[#totals + 1] = { tool = tool.name, passed = passed, n = n, unfit = if unfit > 0 then unfit else nil end,
      cost = cost / d, cache_read = read / d, cache_write = write / d, output = output / d, total = cost }
  end
  local tasks: mut {ReportData.Task} = {}
  for _, task in ipairs(options.tasks) do
    local rows: mut {ReportData.Row} = {}
    for _, tool in ipairs(options.tools) do
      local passed, unfit, n, counted = 0, 0, 0, 0
      local sum: mut {string: number} = { requests = 0, input = 0, output = 0, cache_read = 0, cache_write = 0,
        cost = 0, seconds = 0, tools = 0, runs = 0, refused = 0, first_read = 0, wall = 0 }
      local codes: mut {string: integer} = {}
      local helpers: mut {string: integer} = {}
      for _, r in ipairs(results) do
        if r.tool == tool.name and r.task == task.name then
          n = n + 1
          if r.grade == "pass" then
            passed = passed + 1
          elseif r.grade == "unfit" then
            unfit = unfit + 1
          end
          sum["wall"] = (sum["wall"] or 0) + r.wall
          local s = r.spent
          if s ~= nil then
            counted = counted + 1
            sum["requests"] = (sum["requests"] or 0) + s.requests
            sum["input"] = (sum["input"] or 0) + s.input
            sum["output"] = (sum["output"] or 0) + s.output
            sum["cache_read"] = (sum["cache_read"] or 0) + s.cache_read
            sum["cache_write"] = (sum["cache_write"] or 0) + s.cache_write
            sum["cost"] = (sum["cost"] or 0) + s.cost
            sum["seconds"] = (sum["seconds"] or 0) + s.seconds
            sum["tools"] = (sum["tools"] or 0) + s.tools
            sum["runs"] = (sum["runs"] or 0) + s.runs
            sum["refused"] = (sum["refused"] or 0) + s.refused
            sum["first_read"] = (sum["first_read"] or 0) + s.first_read
            for code, k in pairs(s.codes) do codes[code] = (codes[code] or 0) + k end
            for name, k in pairs(s.helpers) do helpers[name] = (helpers[name] or 0) + k end
          end
        end
      end
      local d = math.max(counted, 1)
      local function mean(k: string): number return (sum[k] or 0) / d end
      local grade = tostring(passed) .. " of " .. tostring(n) .. " passed"
      if unfit > 0 then grade = "unfit on this fixture" end
      rows[#rows + 1] = { tool = tool.name, grade = grade, requests = mean("requests"), cost = mean("cost"),
        wall = (sum["wall"] or 0) / math.max(n, 1), seconds = mean("seconds"), input = mean("input"),
        output = mean("output"), cache_read = mean("cache_read"), first_read = mean("first_read"),
        cache_write = mean("cache_write"), tools = mean("tools"), runs = mean("runs"), refused = mean("refused"),
        refused_for = ranked(codes, function(k: integer): string return tostring(k) end),
        helpers = ranked(helpers, function(k: integer): string
          return string.format("%.1f", k / d)
        end) }
    end
    tasks[#tasks + 1] = { name = task.name, rows = rows }
  end
  return Report.render({ model = options.model, reps = options.reps, fixture = options.fixture,
    effort = if #set > 0 then table.concat(set, ", ") else nil end, totals = totals, tasks = tasks })
end

--- The world as it is: commands found on PATH, run with Child.
local function real(out: string): Agent.System
  local function run(argv: {string}, cwd: string, env: {string: string}?, seconds: integer): Agent.Output
    local first = argv[1] or ""
    local program = first
    if first:sub(1, 1) ~= "/" then
      local found, _ = Proc.find(first)
      program = found or first
    end
    local full: mut {string} = { program }
    for i = 2, #argv do full[#full + 1] = argv[i] end
    local began = Clock.monotonic_ns()
    local res, why = Child.run(full, { cwd = cwd, env = env, stdin = "null", stdout = "capture",
      stderr = "capture", timeout_ns = seconds * 1000000000 })
    local took = (Clock.monotonic_ns() - began) / 1e9
    if res == nil then
      return { code = 127, stdout = "", stderr = tostring(why), seconds = took }
    end
    local code = res.code or 128
    if res.timed_out then code = 124 end
    return { code = code, stdout = res.stdout or "", stderr = res.stderr or "", seconds = took }
  end
  local function fresh(prefix: string): string
    return (assert(Fs.mkdtemp(prefix)))
  end
  -- A directory that cannot be removed is left, rather than end the evals and lose the runs graded so far.
  local function discard(dir: string)
    local _, _ = Fs.remove_tree(dir)
  end
  local function spent(tool: string, marker: string): Agent.Spent?
    local db, _ = Sqlite.open(out .. "/" .. tool .. "/data/cosmic/agent/sessions.db")
    if db == nil then return nil end
    local s = Agent.spent_in(db, marker)
    local _, _ = db:close()
    return s
  end
  local function put(path: string, text: string)
    local parent = path:match("^(.*)/[^/]*$")
    if parent ~= nil and parent ~= "" then assert(Fs.mkdirs(parent)) end
    assert(Fs.write(path, text))
  end
  local function serve(argv: {string}, cwd: string, ready: string, seconds: integer): (string, function()) |
      (nil, string)
    local handle, why = Child.start(argv, { cwd = cwd, stdin = "null", stdout = "inherit", stderr = "inherit",
      timeout_ns = Child.FOREVER })
    if handle == nil then return nil, tostring(why) end
    local stop = function() local _, _ = handle:close() end
    local deadline = Clock.monotonic_ns() + seconds * 1000000000
    while Clock.monotonic_ns() < deadline do
      local text, _ = Fs.read(ready)
      local port = text and text:match("^(%d+)")
      if port ~= nil then return port, stop end
      local done, _ = handle:try_wait()
      if done ~= nil and done.finished then
        stop()
        return nil, "it ended before it served"
      end
      local _, _ = Clock.sleep(50000000)
    end
    stop()
    return nil, "it did not serve in " .. tostring(seconds) .. " s"
  end
  return { run = run, fresh = fresh, discard = discard, spent = spent, put = put, serve = serve }
end

--- Runs the evals `argv` asks for: 0 when every graded run passed, 1 when one did not, 2 for a bad command line.
function Agent.main(argv: {string}): integer
  local options, why = Agent.parse(argv)
  if options == nil then
    local _, _ = Fs.put(Fs.stderr, "eval/agent: " .. why .. "\n")
    return 2
  end
  local key = Env.get("ANTHROPIC_API_KEY") or Env.get("HARNESS_ANTHROPIC_API_KEY") or ""
  if key == "" then
    local _, _ = Fs.put(Fs.stderr, "eval/agent: set ANTHROPIC_API_KEY or HARNESS_ANTHROPIC_API_KEY\n")
    return 2
  end
  assert(Fs.mkdirs(options.out))
  local results = Agent.execute(options, real(options.out), key, Env.all(), function(path: string, text: string)
    assert(Fs.write(path, text))
    -- A line as each run ends, so a long round shows it moves.
    print((text:match("^grade: (%S+)") or "?") .. "  " .. path)
  end)
  assert(Fs.write(options.out .. "/report.md", Agent.report(options, results) .. "\n"))
  local rows: mut {Json.Value} = {}
  local failed = false
  for _, r in ipairs(results) do
    local row: mut {string: Json.Value} = { tool = r.tool, task = r.task, rep = r.rep, grade = r.grade, wall = r.wall }
    local s = r.spent
    if s ~= nil then
      row["requests"], row["cost"], row["input"], row["output"] = s.requests, s.cost, s.input, s.output
      row["cache_read"], row["cache_write"] = s.cache_read, s.cache_write
      row["seconds"], row["tools"], row["runs"] = s.seconds, s.tools, s.runs
      row["refused"], row["first_read"] = s.refused, s.first_read
      local codes: mut {string: Json.Value} = {}
      for code, k in pairs(s.codes) do codes[code] = k end
      row["codes"] = codes
      local helpers: mut {string: Json.Value} = {}
      for name, k in pairs(s.helpers) do helpers[name] = k end
      row["helpers"] = helpers
    end
    rows[#rows + 1] = row
    failed = failed or r.grade == "fail"
  end
  assert(Fs.write(options.out .. "/results.json", assert(Json.encode(Json.array(rows))) .. "\n"))
  print(options.out .. "/report.md")
  if failed then return 1 end
  return 0
end

return Agent
