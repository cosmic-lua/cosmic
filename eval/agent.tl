--- Runs the evals of cosmic agent itself: fixed tasks on a copy of a fixture tree, each solved by `cosmic agent ask`
--- with each tool under test, and graded by comparing what the agent left against what a command computes from the
--- untouched fixture. It tells, for each tool and task, how many runs passed and what they spent: requests (turns),
--- tokens, cost, seconds and tool calls, read from each tool's own sessions.db. Two tools of one task compare, for
--- example, the agent with code mode and the release before it.
---
---     eval/agent --tool NAME=PATH [--tool NAME=PATH ...] --fixture DIR --out DIR
---         [--effort [NAME=]LEVEL] [--drop [NAME=]BULLET,...] [--tasks T,...|all] [--reps N] [--model M]
---         [--timeout S] [--round ID] [--db FILE] [--arm NAME] [--jobs N]
---         [--against FILE [--against-round ID] [--against-as NEW=OLD ...]]
---
--- Every run is committed, once graded, to a SQLite database (<out>/runs.db, or `--db`): the source of truth, from which
--- the report and results.json are written, and which `--against` reads (see eval/runs.tl). A round is named by
--- `--round`, the name of --out where not given, and goes on where it ended: the same command skips each run the
--- database holds, so a round that its session did not outlive loses the run it was in. Each tool is copied to
--- <out>/<tool>/tool/cosmic when its first run starts, and the round runs that copy, so a rebuild of the tree under the
--- tool does not change the arm; a tool whose binary is not the one the round noted is refused. `--arm NAME` runs only
--- that tool's runs (with every `--tool` still given, as the report names them), and `--jobs N` runs up to N tools at
--- once, each in a process of its own. <out>/round.log tells what each process did.
--- `--control NAME` names a tool whose binary another tool repeats: the report puts each other tool's passes, cost and
--- refusals against the controls' spread, so a difference inside one binary's noise reads as noise. A task marked
--- `held` is one the run text and the checker were not changed from: the report totals the tuned and the held-out
--- tasks apart, so a change that helps only the tasks it was made from shows. Each refusal cause names how many
--- tasks had it; one task alone is likely a fit to that task.
--- `--drop NAME=Host.sed,Json.read` runs the tool NAME with those bullets left out of the run text
--- (COSMIC_RUN_TEXT_DROP, which cosmic/agent/tools.tl reads): a bullet starts with the text, and the round tells
--- of a prefix that started none. `--effort NAME=low` runs the agent of the tool NAME
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
--- agent's words, and the grade are in <out>/<tool>/<task>-<rep>.txt. [`agent`] runs this on the pinned
--- release, in eval/, and the report is the text template eval/report.tmpl. [`Agent.execute`] works through an [`Agent.System`], which a test
--- replaces with a fake.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")
local ArtifactRow = require("artifact_row")
local Causes = require("causes")
local Report = require("report")
local ReportData = require("report_data")
local Runs = require("runs")
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
    --- A bash command run in an untouched copy of the fixture (after `setup`): its output is what a right answer
    --- leaves. `$tool` is the path of the first tool, and `$files` that of eval/testdata/files/<task name>, which
    --- holds what the task's truth and setup need, such as files written out in full.
    truth: string
    --- A bash command run in the run's copy once the agent ended: its output must be the truth's. `$tool` is the
    --- path of the tool under test, for a task whose answer is a program to run, and `$files` as for the truth.
    check: string
    --- The project of eval/testdata the task works in, such as "shop", in place of `--fixture`: a small cosmic
    --- project of its own, whose builds and tests take a second, so a check may build it. Nil for `--fixture`.
    fixture?: string
    --- A bash command run in each copy before the truth and before the agent: what makes the tree the task starts
    --- from, such as a change that breaks its build; `$tool` and `$files` as for the truth. Nil for none.
    setup?: string
    --- The MCP servers the run is given, in one config, where the task needs them. Its truth runs with `$data`
    --- the path of the first one's data: the others are there to be passed over.
    servers?: {Server}
    --- A web API the run reaches over HTTP at a loopback port, where the task needs one: `{url}` in the prompt is
    --- its URL, and the run is given `--connect` to it. Its truth runs with `$data` the path of its data.
    site?: Site
    --- True for a task held out from tuning: the run text and the checker were not changed from its refusals, so
    --- the report's per-set totals say whether a change helps beyond the tasks it was made from. A task moves to
    --- the tuned set when a change is made from its refusals.
    held?: boolean
    --- True for a task on cosmic's own tree, `--fixture` a checkout of the tool's own source: each run's copy gets
    --- the tool in its build directory, its `built_from` row naming the copy ([`ArtifactRow.with`]), so the copy is
    --- cosmic's own tree to it, as CI's copies of the tree are. A fixture that is not the tool's source makes the tool
    --- rebuild itself, which takes minutes.
    own?: boolean
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
    --- The run text bullets left out of its run tool (`--drop`), as COSMIC_RUN_TEXT_DROP takes them; nil for none.
    drop?: string
    --- How hard its agent thinks (`--effort`); nil for the agent's default.
    effort?: string
    --- True to let its agent's snippets run programs (`--commands`), in the agent's sandbox, with the tool itself
    --- first on PATH as `cosmic`, so a snippet may run `cosmic test` or `cosmic fix`.
    commands?: boolean
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
    --- True to leave AGENTS.md and CLAUDE.md out of each copy of the fixture (the truth's too), so the agent has
    --- only what the binary tells it; the report says so.
    without_agents_md?: boolean
    --- The earlier round whose refusal causes the report sets beside this round's: a runs database, or the
    --- results.json of a round from before there was one; nil for none.
    against?: string
    --- The round of the `against` database to read; nil for its newest.
    against_round?: string
    --- The names the earlier round gave its tools, by the names they have here (`--against-as NEW=OLD`).
    against_as?: {string: string}
    --- The round's name in the database (`--round`), as given; nil for the name of `out`.
    round?: string
    --- The database of the rounds (`--db`); nil for runs.db in `out`.
    db?: string
    --- The names of the only tools whose runs this process makes (`--arm`); nil for every tool.
    arms?: {string}
    --- How many tools run at once, each in a process of its own (`--jobs`); nil for one process.
    jobs?: integer
    --- The tools that repeat one base tool's binary, named by `--control`: the report puts every other tool's
    --- totals against their spread, so a difference inside the noise of one binary reads as one.
    controls?: {string}
    --- eval/testdata, which holds the projects of the tasks that name one (`fixture`) and their wanted trees
    --- (files/<task>); eval/agent gives it. Nil where not given: then such a task is refused.
    testdata?: string
  end

  --- What an earlier round says of one tool ([`Runs.Earlier`]).
  type Earlier = Runs.Earlier

  --- A finished command: its exit status (124 for a timeout), and its standard output and error.
  record Output
    code: integer
    stdout: string
    stderr: string
    --- How long it ran, by the wall clock; nil where not timed.
    seconds?: number
  end

  --- What one run spent, from its session in sessions.db ([`Runs.Spent`]).
  type Spent = Runs.Spent

  --- One run's result ([`Runs.Result`]).
  type Result = Runs.Result

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
    --- Writes the tool `from` at `to`, executable, as one built from the tree at `root` (its real path).
    retarget: function(from: string, to: string, root: string)
  end

  --- What a round keeps of its runs, where it keeps them: the result a run already has, which a round that goes on
  --- does not run again, and a call that takes each result as it is graded. Tests give none.
  record Store
    known: function(tool: string, task: string, rep: integer): Agent.Result?
    record: function(tool: Agent.Tool, result: Agent.Result)
  end

  --- What [`Agent.freeze`] made of a tool: the tool as the round runs it, its arm for the database, and what to tell.
  record Frozen
    tool: Tool
    arm: Runs.Arm
    --- Said where the copy kept is not the binary now at the tool's path, or where the tool is no binary to copy.
    note?: string
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

--- The shop tasks (eval/testdata/shop): a hash of every .tl file of the tree, names and text, and of what its
--- program prints; for a check that the tree builds, its tests pass and what it does is kept.
local SHOP_TL <const> = "find . -name '*.tl' | LC_ALL=C sort | while read -r f; do echo \"$f\"; cat \"$f\"; done | " ..
  "sha256sum | cut -c1-64"
local SHOP_BUILDS <const> = "if $tool fix --check . > /dev/null 2>&1; then echo checks; else echo refused; fi; " ..
  "if $tool test > /dev/null 2>&1; then echo tests; else echo failed; fi"
local SHOP_RECEIPT <const> = "$tool cmd/receipt/main.tl 2>&1 | sha256sum | cut -c1-64"
local SHOP_RECEIPT_WAS <const> = "sha256sum < \"$files/../receipt.txt\" | cut -c1-64"
--- Each mutant of Money.parse that the tests of shop-test-parse must catch, as a sed script.
local SHOP_MUTANTS <const> = {
  "/if sign == \"-\" then cents = -cents end/d",
  "s/math.tointeger(tonumber(frac))! \\* 10/math.tointeger(tonumber(frac))!/",
  "s/#frac > 2/#frac > 3/",
  "/text:sub(-1) == \".\"/d",
}

--- The git tasks: the shop tree as a repository of six commits, made at eval time by cosmic.git, with no git
--- program (eval/testdata/files/shop-git-commit/shop.tl). Names and dates are fixed, so every copy's commits have
--- the same oids.
local GIT_SHOP <const> = "\"$tool\" - < \"$files/../shop-git-commit/shop.tl\""
--- What the shop-git-commit check reports, from cosmic.git: the last two subjects, what HEAD changed, what is left,
--- who committed, HEAD's parent, and whether every object HEAD reaches reads.
local GIT_COMMIT_REPORT <const> = "\"$tool\" - < \"$files/../shop-git-commit/report.tl\""

local function shop_mutants(): string
  local out: mut {string} = { "kept=$(mktemp)", "cp money.tl \"$kept\"" }
  for _, m in ipairs(SHOP_MUTANTS) do
    out[#out + 1] = "sed -i '" .. m .. "' money.tl; if cmp -s money.tl \"$kept\"; then echo unchanged; " ..
      "elif $tool test > /dev/null 2>&1; then echo missed; else echo caught; fi; cp \"$kept\" money.tl"
  end
  return table.concat(out, "; ")
end

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
    held = true,
    prompt = "ci/cosmic_ci/capabilities.json has a `legs` object of arrays of strings. For each leg, count its " ..
      "strings that start `program:`. Write to answer.txt one `count leg` per line, such as `7 linux-x`, most first, ties by name.",
    truth = [==[jq -r '.legs | to_entries[] | "\([.value[] | select(startswith("program:"))] | length) \(.key)"' ci/cosmic_ci/capabilities.json | sort -k1,1nr -k2,2]==],
    check = "cat answer.txt",
  },
  {
    name = "error-lines",
    held = true,
    prompt = "Write to answer.txt every line of the non-test .tl files directly in cosmic/agent/ that holds " ..
      "`error(`, as `path:line`, such as `cosmic/agent/x.tl:12` (line numbered from 1), one a line, sorted by path, then by line.",
    truth = "for f in $(find cosmic/agent -maxdepth 1 -name '*.tl' ! -name '*_test.tl' | sort); do " ..
      "grep -n 'error(' \"$f\" | cut -d: -f1 | sed \"s|^|$f:|\"; done | sort -t: -k1,1 -k2,2n",
    check = "cat answer.txt",
  },
  {
    name = "append-many",
    held = true,
    prompt = "Add the line `-- end` at the end of each non-test .tl file directly in cosmic/agent/, and change nothing else.",
    truth = "for f in $(find cosmic/agent -maxdepth 1 -name '*.tl' ! -name '*_test.tl' | sort); do " ..
      "echo \"$f\"; cat \"$f\"; echo '-- end'; done | sha256sum | cut -c1-64",
    check = "for f in $(find cosmic/agent -maxdepth 1 -name '*.tl' ! -name '*_test.tl' | sort); do " ..
      "echo \"$f\"; cat \"$f\"; done | sha256sum | cut -c1-64",
  },
  {
    name = "tested-modules",
    held = true,
    prompt = "Take each distinct module cosmic/agent/host.tl names as `require(\"cosmic.<...>\")`. For each, count the " ..
      "_test.tl files directly in cosmic/agent/ that hold the text `require(\"<the module>\")`. Write to answer.txt " ..
      "`count module` for each module with a count of 1 or more, such as `3 cosmic.x`, most first, ties by name.",
    truth = [==[for m in $(grep -o 'require("cosmic\.[^"]*")' cosmic/agent/host.tl | sed 's/require("//; s/")//' | sort -u); do n=$(grep -lF "require(\"$m\")" cosmic/agent/*_test.tl 2>/dev/null | wc -l); [ "$n" -ge 1 ] && echo "$n $m"; done | sort -k1,1nr -k2,2]==],
    check = "cat answer.txt",
  },
  {
    name = "darwin-dirs",
    held = true,
    prompt = "ci/darwin-tests.txt lists test modules, one a line, with comment lines that start `#` and blank " ..
      "lines. For each first path component of the listed paths (`cosmic` in `cosmic/x_test.tl`), count its listed " ..
      "paths. Write to answer.txt `count dir` per line, such as `4 cosmic`, most first, ties by name.",
    truth = "grep -v '^#' ci/darwin-tests.txt | grep -v '^[[:space:]]*$' | awk -F/ '{n[$1]++} END {for (d in n) print n[d]\" \"d}' | sort -k1,1nr -k2,2",
    check = "cat answer.txt",
  },
  {
    name = "longest-lines",
    held = true,
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
    held = true,
    own = true,
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
    name = "write-json",
    prompt = "Write dirsjson.tl in this directory: a cosmic program (Teal, checked) that takes a directory as its first " ..
      "argument and prints one line of JSON: an array with an object for each directory directly inside it, in order " ..
      "of path, each with `name` (the path as the argument and the name joined by `/`, such as `cosmic/web`) and " ..
      "`files` (how many .tl files lie under that directory, at any depth, as a number). Compact: no spaces, the keys " ..
      "of an object sorted (`files` first). Such as `[{\"files\":40,\"name\":\"cosmic/web\"}]`. It must pass " ..
      "`cosmic --standalone --check dirsjson.tl`.",
    truth = [==[printf '['; sep=''; for d in $(find cosmic -mindepth 1 -maxdepth 1 -type d | sort); do printf '%s{"files":%s,"name":"%s"}' "$sep" "$(find $d -name '*.tl' | wc -l)" "$d"; sep=','; done; printf ']\n']==],
    check = "$tool --standalone --check dirsjson.tl > /dev/null 2>&1 && $tool --standalone dirsjson.tl cosmic",
  },
  {
    name = "write-csv",
    prompt = "Write guides.tl in this directory: a cosmic program (Teal, checked) that takes a directory as its first " ..
      "argument and prints CSV: the header `file,lines,title`, then a row for each .md file directly inside it, in order " ..
      "of path. `file` is the path as the argument and the name joined by `/`, `lines` is the number of lines of the " ..
      "file, and `title` is its first line without the leading `# `. A title that holds a comma or a double quote is " ..
      "written in double quotes with each double quote in it doubled (RFC 4180); any other title is written as it is. " ..
      "It must pass `cosmic --standalone --check guides.tl`.",
    truth = [==[echo 'file,lines,title'; for f in $(ls doc/guides/*.md | sort); do t=$(head -1 "$f" | sed 's/^# *//'); case "$t" in *[,\"]*) t="\"$(printf '%s' "$t" | sed 's/"/""/g')\"";; esac; echo "$f,$(wc -l < "$f" | tr -d ' '),$t"; done]==],
    check = "$tool --standalone --check guides.tl > /dev/null 2>&1 && $tool --standalone guides.tl doc/guides",
  },
  {
    name = "fix-bug",
    prompt = "Ranges.merge in test/plant/ranges.tl has a bug: ranges that touch or share an end must join (`1-3` and " ..
      "`4-6` cover 1 to 6 with no gap, and `1-3` and `3-5` overlap), but it leaves them apart. Fix the bug and " ..
      "change nothing else. Its tests, test/plant/ranges_test.tl, run with `cosmic test test/plant/ranges_test.tl`.",
    truth = "echo pass",
    check = [==[mkdir mini && cp test/plant/ranges.tl mini/ranges.tl && cp test/plant/ranges_test.tl mini/ranges_test.tl && sed -i 's/test\.plant\.ranges/ranges/' mini/ranges_test.tl && cat > mini/hidden_test.tl <<'EOF'
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
    name = "shop-rename-field",
    held = true,
    fixture = "shop",
    prompt = "Rename the field name of the record Invoice.Line (invoice.tl) to label, everywhere it is declared, " ..
      "written or read, tests too, and change nothing else: other fields called name (Invoice.Customer.name, " ..
      "Catalog.Product.name) stay, as do comments. The tree must still build, and its tests pass.",
    truth = "cp \"$files/invoice.tl\" \"$files/invoice_test.tl\" . && " .. SHOP_TL,
    check = SHOP_TL,
  },
  {
    name = "shop-uses",
    held = true,
    fixture = "shop",
    prompt = "Write answer.txt: each place in this tree's code that calls Money.format (money.tl), through any name " ..
      "the module is required as, tests included, as path:line, such as `catalog.tl:42`, one a line, sorted. Leave " ..
      "out comments and other functions called format.",
    truth = "cat \"$files/answer.txt\"",
    check = "sed 's#^\\./##' answer.txt | LC_ALL=C sort -u",
  },
  {
    name = "shop-move-module",
    held = true,
    fixture = "shop",
    prompt = "Move the module money.tl to units/money.tl, and its tests money_test.tl to units/money_test.tl, and " ..
      "make every file that requires it require it at its new place. Change nothing else. The tree must still build, " ..
      "its tests pass, and `cosmic cmd/receipt/main.tl` print what it did.",
    truth = "echo moved; echo 0; " .. SHOP_BUILDS .. "; " .. SHOP_RECEIPT,
    check = "if [ -f units/money.tl ] && [ -f units/money_test.tl ] && [ ! -e money.tl ] && [ ! -e money_test.tl ]; " ..
      "then echo moved; else echo 'not moved'; fi; grep -rl --include='*.tl' 'require(\"money\")' . | wc -l; " ..
      SHOP_BUILDS .. "; " .. SHOP_RECEIPT,
  },
  {
    name = "shop-signature",
    held = true,
    fixture = "shop",
    prompt = "Give Money.format (money.tl) a second parameter, `symbol: string`, written after any minus sign and " ..
      "before the number: `Money.format(Money.of(-310), \"$\")` is `-$3.10`. Make every caller pass \"$\", and " ..
      "change the tests to match. Change nothing else. The tree must still build, and its tests pass.",
    truth = "echo 1; echo '-$3.10'; " .. SHOP_BUILDS .. "; sha256sum < \"$files/receipt.txt\" | cut -c1-64",
    check = "grep -c '^function Money.format(a: Money.Amount, symbol: string): string$' money.tl; " ..
      "$tool -e 'local M = require(\"money\") print(M.format(M.of(-310), \"$\"))' 2>&1; " .. SHOP_BUILDS .. "; " ..
      SHOP_RECEIPT,
  },
  {
    name = "shop-make-build",
    held = true,
    fixture = "shop",
    setup = "cp \"$files/money.tl\" money.tl && sed -i " ..
      "'s/^function Invoice.total(inv: Invoice): Cash.Amount$/function Invoice.total(inv: Invoice): integer/; " ..
      "s/^  return sum$/  return sum.cents/' invoice.tl",
    prompt = "This tree does not build: Money.parse (money.tl) now answers why it refused a text, and " ..
      "Invoice.total (invoice.tl) now answers whole cents. Keep both changes, money.tl as it is and Invoice.total's " ..
      "declaration too, and change the rest so that the tree builds again, its tests pass and " ..
      "`cosmic cmd/receipt/main.tl` prints what it did before.",
    truth = "sha256sum < money.tl | cut -c1-64; grep -c '^function Invoice.total(inv: Invoice): integer$' invoice.tl; " ..
      "echo checks; echo tests; " .. SHOP_RECEIPT_WAS,
    check = "sha256sum < money.tl | cut -c1-64; grep -c '^function Invoice.total(inv: Invoice): integer$' invoice.tl; " ..
      SHOP_BUILDS .. "; " .. SHOP_RECEIPT,
  },
  {
    name = "shop-test-parse",
    held = true,
    fixture = "shop",
    prompt = "Money.parse (money.tl) has no tests. Add tests of it to money_test.tl, and change no other file: " ..
      "they must pass, and fail where parse is wrong. It reads `12.34`, `7`, `0.5` and `-3.10` (as -310 cents), " ..
      "and answers nil for `1.234`, `12,00`, `7.` and `abc`.",
    truth = "find . -name '*.tl' ! -name money_test.tl | LC_ALL=C sort | while read -r f; do echo \"$f\"; cat \"$f\"; " ..
      "done | sha256sum | cut -c1-64; echo passes; echo caught; echo caught; echo caught; echo caught",
    check = "find . -name '*.tl' ! -name money_test.tl | LC_ALL=C sort | while read -r f; do echo \"$f\"; cat \"$f\"; " ..
      "done | sha256sum | cut -c1-64; if $tool test > /dev/null 2>&1; then echo passes; else echo fails; fi; " ..
      shop_mutants(),
  },
  {
    name = "shop-dead",
    held = true,
    fixture = "shop",
    prompt = "Write answer.txt: each function a module of this tree declares that no other file calls or names, " ..
      "tests left out (they do not count as callers), so it could be local or dropped. Write each as Module.name, " ..
      "such as `Text.center`, one a line, sorted.",
    truth = "cat \"$files/answer.txt\"",
    check = "LC_ALL=C sort -u answer.txt",
  },
  {
    name = "shop-git-commit",
    fixture = "shop",
    setup = GIT_SHOP .. " && sed -i 's/the odd space after it/the odd space after it, trimmed first/' text.tl && " ..
      "echo '-- Columns are padded.' >> report.tl && echo 'call the printer' > notes.txt",
    prompt = "This tree is a git repository. Commit the change to text.tl alone, with the message " ..
      "`text: note the trim rule`, on top of the current branch. Leave the change to report.tl and the file " ..
      "notes.txt as they are, not committed.",
    truth = "\"$tool\" - < \"$files/truth.tl\" && " .. GIT_COMMIT_REPORT,
    check = GIT_COMMIT_REPORT,
  },
  {
    name = "shop-git-history",
    fixture = "shop",
    setup = GIT_SHOP,
    prompt = "This tree is a git repository. Write answer.txt: the subject (first line of the message) of each " ..
      "commit on the current branch that changed money.tl, newest first, one a line.",
    truth = "\"$tool\" - < \"$files/truth.tl\"",
    check = "cat answer.txt",
  },
  {
    name = "fix-rle",
    prompt = "Rle in test/plant/rle.tl does not round-trip: decoding what encode wrote does not always answer the " ..
      "first text (try `abc` and a run of twelve `a`). Find the bugs and fix them, and change nothing else. Its " ..
      "tests are test/plant/rle_test.tl; run them with `cosmic test test/plant/rle_test.tl`.",
    truth = "echo pass",
    check = [==[mkdir mini && cp test/plant/rle.tl mini/rle.tl && cat > mini/hidden_test.tl <<'EOF'
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
    prompt = "Calc.eval in test/plant/calc.tl answers wrong values: it should give `2-3-4` = -5, `10-4-3` = 3, " ..
      "`2^3^2` = 512 (`^` groups from the right) and `-2^2` = -4 (`^` binds tighter than a minus before it), and " ..
      "keep `10/4/5` = 0.5, `2*3+4` = 10 and `(1+2)*3` = 9. Find the bugs and fix them, and change nothing else. " ..
      "Its tests are test/plant/calc_test.tl; run them with `cosmic test test/plant/calc_test.tl`.",
    truth = "echo pass",
    check = [==[mkdir mini && cp test/plant/calc.tl mini/calc.tl && cat > mini/hidden_test.tl <<'EOF'
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
  "[--effort [NAME=]LEVEL] [--drop [NAME=]BULLET,...] [--tasks T,...|all] [--reps N] [--model M] [--timeout S] " ..
  "[--round ID] [--db FILE] [--arm NAME ...] [--jobs N] [--no-agents-md] [--against RUNS.db|RESULTS.json " ..
  "[--against-round ID] [--against-as NEW=OLD ...]] [--control NAME ...] [--commands NAME ...] [--testdata DIR]"

local EFFORTS <const>: {string: boolean} = { low = true, medium = true, high = true, xhigh = true, max = true }

local function positive(text: string): integer?
  if not text:match("^[1-9]%d*$") then return nil end
  return math.tointeger(tonumber(text))
end

--- Reads the command line. `--reps` is 2, `--model` sonnet, `--timeout` 1200 and `--tasks` all unless given.
function Agent.parse(argv: {string}): Agent.Options?, string
  local tools: mut {Agent.Tool} = {}
  local drops: mut {string: string} = {}
  local drop: string? = nil
  local efforts: mut {string: string} = {}
  local effort: string? = nil
  local fixture, out, model = "", "", "sonnet"
  local reps, timeout = 2, 1200
  local without_agents_md = false
  local against: string? = nil
  local against_round: string? = nil
  local against_as: mut {string: string} = {}
  local round: string? = nil
  local db: string? = nil
  local arms: mut {string} = {}
  local jobs: integer? = nil
  local controls: mut {string} = {}
  local commands: mut {string: boolean} = {}
  local testdata: string? = nil
  local tasks: mut {Agent.Task} = {}
  for _, t in ipairs(Agent.tasks) do tasks[#tasks + 1] = t end
  local i = 1
  while argv[i] ~= nil do
    local word, value = argv[i], argv[i + 1]
    if word == "--no-agents-md" then
      without_agents_md = true
      i = i + 1
      continue
    end
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
    elseif word == "--drop" then
      local name, list = value:match("^([%w_-]+)=(.+)$")
      local wanted = list or value
      if wanted == "" then
        return nil, "--drop takes BULLET,BULLET,... or NAME=BULLET,...: " .. value
      end
      if name == nil then
        drop = wanted
      else
        local found = false
        for _, t in ipairs(tools) do
          if t.name == name then found = true end
        end
        if not found then return nil, "--drop " .. name .. ": name a --tool given before it" end
        drops[name] = wanted
      end
    elseif word == "--arm" then
      local found = false
      for _, t in ipairs(tools) do
        if t.name == value then found = true end
      end
      if not found then return nil, "--arm " .. value .. ": name a --tool given before it" end
      arms[#arms + 1] = value
    elseif word == "--round" then
      if not value:match("^[%w_.-]+$") then
        return nil, "--round takes letters, digits and _.-: " .. value
      end
      round = value
    elseif word == "--db" then
      if value:sub(1, 1) ~= "/" then return nil, "--db takes an absolute path: " .. value end
      db = value
    elseif word == "--jobs" then
      local n = positive(value)
      if n == nil then return nil, "--jobs takes a positive integer: " .. value end
      jobs = n
    elseif word == "--against-round" then
      against_round = value
    elseif word == "--against-as" then
      local now, then_ = value:match("^([%w_-]+)=([%w_-]+)$")
      if now == nil or then_ == nil then
        return nil, "--against-as takes NEW=OLD, a tool's name here and in the earlier round: " .. value
      end
      against_as[now] = then_
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
    elseif word == "--control" then
      local found = false
      for _, t in ipairs(tools) do
        if t.name == value then found = true end
      end
      if not found then return nil, "--control " .. value .. ": name a --tool given before it" end
      controls[#controls + 1] = value
    elseif word == "--commands" then
      local found = false
      for _, t in ipairs(tools) do
        if t.name == value then found = true end
      end
      if not found then return nil, "--commands " .. value .. ": name a --tool given before it" end
      commands[value] = true
    elseif word == "--testdata" then
      if value:sub(1, 1) ~= "/" then return nil, "--testdata takes an absolute path: " .. value end
      testdata = value
    elseif word == "--against" then
      if value:sub(1, 1) ~= "/" then return nil, "--against takes an absolute path: " .. value end
      against = value
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
  -- The runs read and write them from other directories, and eval/agent runs from eval/.
  if fixture:sub(1, 1) ~= "/" or out:sub(1, 1) ~= "/" then
    return nil, "--fixture and --out take absolute paths: " .. (if fixture:sub(1, 1) ~= "/" then fixture else out end)
  end
  if #tasks == 0 then return nil, "--tasks names no task" end
  for _, t in ipairs(tasks) do
    if t.fixture ~= nil and testdata == nil then
      return nil, "task " .. t.name .. " works in eval/testdata/" .. t.fixture .. ": give --testdata (eval/agent does)"
    end
  end
  for name, _ in pairs(against_as) do
    local found = false
    for _, t in ipairs(tools) do
      if t.name == name then found = true end
    end
    if not found then return nil, "--against-as " .. name .. ": name a --tool" end
  end
  if (against_round ~= nil or next(against_as) ~= nil) and against == nil then
    return nil, "--against-round and --against-as need --against"
  end
  local offering: mut {Agent.Tool} = {}
  for _, t in ipairs(tools) do
    offering[#offering + 1] = { name = t.name, path = t.path, drop = drops[t.name] or drop, effort = efforts[t.name] or effort,
      commands = if commands[t.name] == true then true else nil end }
  end
  return { tools = offering, fixture = fixture, out = out, tasks = tasks, reps = reps, model = model,
    timeout = timeout, without_agents_md = if without_agents_md then true else nil end, against = against,
    controls = if #controls > 0 then controls else nil end, testdata = testdata, against_round = against_round,
    against_as = if next(against_as) ~= nil then against_as else nil end, round = round, db = db,
    arms = if #arms > 0 then arms else nil end, jobs = jobs }, ""
end

--- `text`'s lines, each without its trailing blanks, and with no blank lines at its end: what grading compares.
function Agent.lines_of(text: string): string
  local out: mut {string} = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = (line:gsub("%s+$", "")) end
  while #out > 0 and out[#out] == "" do out[#out] = nil end
  return table.concat(out, "\n")
end

--- The environment a run of `tool` gets: `base`, with `key` and its own data directory and home, and `bin` first on
--- PATH where it is given.
local function env_of(base: {string: string}, key: string, data: string, home: string, bin: string?): {string: string}
  local e: mut {string: string} = {}
  for k, v in pairs(base) do e[k] = v end
  if bin ~= nil then
    local path = e["PATH"]
    e["PATH"] = if path ~= nil and path ~= "" then bin .. ":" .. path else bin end
  end
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
--- environment; each run's answer goes to `write`. The results, in order. A run that ends with an error before its
--- first request, when no run before it made one, is graded "broken" and ends the round (the last result says why
--- in `stopped`), since every run after it would meet what it met.
function Agent.execute(options: Agent.Options, system: Agent.System, key: string, base: {string: string},
                       write: function(string, string), store?: Agent.Store): {Agent.Result}
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
    retarget = system.retarget,
  }
  -- A copy of the task's fixture at `dest`, with the files that instruct an agent left out when the evals say so,
  -- and the task's setup run in it.
  local first_tool = options.tools[1]
  -- What a task's truth and setup are run with: `$tool` and `$files`.
  local function prefix(task: Agent.Task): string
    return "tool=" .. quoted(first_tool and first_tool.path or "cosmic") .. "; files=" ..
      quoted((options.testdata or "") .. "/files/" .. task.name) .. "; "
  end
  local function copied(dest: string, task: Agent.Task)
    local project = task.fixture
    local from = if project ~= nil then (options.testdata or "") .. "/" .. project else options.fixture end
    own.run({ "cp", "-a", from .. "/.", dest }, "/", nil, 600)
    if options.without_agents_md == true then
      own.run({ "rm", "-f", dest .. "/AGENTS.md", dest .. "/CLAUDE.md" }, "/", nil, 60)
    end
    local setup = task.setup
    if setup ~= nil then
      local set = own.run({ "bash", "-c", prefix(task) .. setup }, dest, nil, 60)
      assert(set.code == 0, "the setup of " .. task.name .. " failed: " .. set.stderr)
    end
  end
  -- Why the round stopped before its end: the first run ended before its first request, so the rest would too.
  local halted: string? = nil
  local reached = false
  local ran, got = pcall(function(): {Agent.Result}
    local results: mut {Agent.Result} = {}
    local truths: mut {string: string} = {}
    -- What a right answer to `task` leaves, computed on the first run that is graded: a round that goes on, whose
    -- runs the store holds, makes none.
    local function truth_of(task: Agent.Task): string
      local known = truths[task.name]
      if known ~= nil then return known end
      local pristine = own.fresh("truth-" .. task.name .. "-")
      copied(pristine, task)
      local script = prefix(task) .. task.truth
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
      return truths[task.name] or ""
    end
    local only: mut {string: boolean} = {}
    for _, name in ipairs(options.arms or {}) do only[name] = true end
    for _, tool in ipairs(options.tools) do
      if halted ~= nil then break end
      if options.arms ~= nil and only[tool.name] ~= true then continue end
      local data, home = options.out .. "/" .. tool.name .. "/data", options.out .. "/" .. tool.name .. "/home"
      own.run({ "mkdir", "-p", data, home }, "/", nil, 60)
      local bin: string? = nil
      if tool.commands == true then
        -- The tool first on PATH as `cosmic`, in a directory of its own: the sandbox grants each directory of PATH,
        -- and one named bin would bring the directory that holds it, the tool's data too.
        local dir = options.out .. "/" .. tool.name .. "/path"
        local placed = own.run({ "bash", "-c", 'mkdir -p "$1" && cp "$(command -v "$0")" "$1/cosmic" && ' ..
            'chmod -R a+rX "$1"', tool.path, dir }, "/", nil, 60)
        assert(placed.code == 0, "the tool of " .. tool.name .. " was not put on PATH: " .. placed.stderr)
        bin = dir
      end
      local env = env_of(base, key, data, home, bin)
      for _, task in ipairs(options.tasks) do
        if halted ~= nil then break end
        for rep = 1, options.reps do
          if halted ~= nil then break end
          local done = (if store ~= nil then store.known(tool.name, task.name, rep) else nil end)
          if done ~= nil then
            -- A run the store holds: it counts as one made, so the first run of this process need not reach a request.
            if done.grade ~= "broken" then reached = true end
            results[#results + 1] = done
            continue
          end
          local truth = truth_of(task)
          local marker = "bench-" .. tool.name .. "-" .. task.name .. "-"
          local work = own.fresh(marker)
          copied(work, task)
          -- Each run's own build home and temporary directory, as a test's worker has them in its scratch
          -- directory (build/test_sandbox.tl): no run reads what another built.
          local scratch = own.fresh("scratch-" .. marker)
          -- Searchable by every user, its tmp as /tmp is: where the agent is root, its sandboxed programs run as a user
          -- of their own, which is granted files beneath it.
          local laid = own.run({ "bash", "-c", 'mkdir -p "$0/build" "$0/tmp" && chmod 755 "$0" "$0/build" && ' ..
              'chmod 1777 "$0/tmp"', scratch }, "/", nil, 60)
          assert(laid.code == 0, "the scratch directory of a run was not laid out: " .. laid.stderr)
          local run_env: mut {string: string} = {}
          for k, v in pairs(env) do run_env[k] = v end
          run_env["COSMIC_BUILD_HOME"] = scratch .. "/build"
          run_env["TMPDIR"] = scratch .. "/tmp"
          local program = tool.path
          if task.own == true then
            local found = own.run({ tool.path, "--standalone", work .. "/build/paths.tl", work }, work, run_env, 60)
            local directory = Agent.first_line(found.stdout)
            assert(found.code == 0 and directory ~= nil,
              "the build directory of " .. task.name .. "'s copy was not named: " .. found.stderr)
            program = directory .. "/bin/cosmic"
            own.retarget(tool.path, program, work)
            -- The sandbox grants a deep `bin` on PATH as its parent (cosmic/agent/policy.tl): this copy's own build
            -- directory, which its commands build into all the same.
            if bin ~= nil then run_env["PATH"] = directory .. "/bin:" .. (run_env["PATH"] or "") end
          end
          local argv: mut {string} = { program, "agent", "ask", "--model", options.model }
          local effort = tool.effort
          if effort ~= nil then
            argv[#argv + 1] = "--effort"
            argv[#argv + 1] = effort
          end
          if tool.commands == true then argv[#argv + 1] = "--commands" end
          local dropped = tool.drop
          -- Only what the arm asks for: a variable of the caller's shell must not leak into a control.
          if dropped ~= nil then
            run_env["COSMIC_RUN_TEXT_DROP"] = dropped
          else
            run_env["COSMIC_RUN_TEXT_DROP"] = nil
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
            asked = own.run(argv, work, run_env, options.timeout)
            if follow_up == nil or asked.code ~= 0 then return end
            again[#again + 1] = follow_up
            local next_asked = own.run(again, work, run_env, options.timeout)
            asked = { code = next_asked.code, stdout = asked.stdout .. "\n--- follow-up\n" .. next_asked.stdout,
              stderr = asked.stderr .. "\n--- follow-up\n" .. next_asked.stderr,
              seconds = (asked.seconds or 0) + (next_asked.seconds or 0) }
          end)
          stop()
          if not ran then error(why, 0) end
          local left = Agent.lines_of(own.run({ "bash", "-c", "tool=" .. quoted(tool.path) .. "; files=" ..
              quoted((options.testdata or "") .. "/files/" .. task.name) .. "; " .. task.check }, work, nil, 60).stdout)
          local grade = "fail"
          if truth == "" then grade = "unfit" elseif left == truth then grade = "pass" end
          local spent = own.spent(tool.name, work:match("[^/]+$") or marker)
          -- An error exit with no request made was not the model's: a setup that failed is told from a wrong answer.
          local broke: string? = nil
          -- A timeout (124) is slow, not broken: its request may have been out when it ended.
          if asked.code ~= 0 and asked.code ~= 124 and (spent == nil or spent.requests == 0) then
            grade = "broken"
            broke = Agent.first_line(if asked.stderr ~= "" then asked.stderr else asked.stdout end)
            if unserved == nil and not reached then
              halted = "the first run ended before its first request (exit " .. tostring(asked.code) .. "): " ..
                (broke or "no output")
            end
          elseif spent ~= nil and spent.requests > 0 then
            reached = true
          end
          write(options.out .. "/" .. tool.name .. "/" .. task.name .. "-" .. tostring(rep) .. ".txt",
            "grade: " .. grade .. "\nexit: " .. tostring(asked.code) .. "\n--- left\n" .. left .. "\n--- truth\n" ..
              truth .. "\n--- words\n" .. asked.stdout .. "\n--- stderr\n" .. asked.stderr .. "\n")
          local result: Agent.Result = { tool = tool.name, task = task.name, rep = rep, grade = grade, why = broke,
            spent = spent, wall = asked.seconds or 0 }
          results[#results + 1] = result
          if store ~= nil then store.record(tool, result) end
          sweep()
        end
      end
    end
    return results
  end)
  sweep()
  if not ran then error(got, 0) end
  local last = got[#got]
  if halted ~= nil and last ~= nil then last.stopped = halted end
  return got
end

--- Reads the results.json `text` of an earlier round: for each tool, the runs, the refused snippets, and the causes
--- and layers of its runs. A tool none of whose runs kept causes (a round from before the report named them) is left
--- out, and a file with no such tool, or a count that is not an integer, is refused with why.
function Agent.earlier(text: string): ({string: Agent.Earlier}) | (nil, string)
  local rows, why = Json.decode_array(text)
  if rows == nil then return nil, "not a results.json: " .. tostring(why) end
  local found: mut {string: Agent.Earlier} = {}
  for i, row in ipairs(rows) do
    local fields = Json.object_of(row)
    local named = fields and fields["tool"]
    local causes = fields and Json.object_of(fields["causes"])
    if fields == nil or not (named is string) then
      return nil, "row " .. tostring(i) .. " has no tool"
    end
    if causes ~= nil then
      local into = found[named] or { refused = 0, runs = 0, causes = {}, layers = {} }
      local refused = fields["refused"]
      if not (refused is integer) then
        return nil, "row " .. tostring(i) .. ": refused is not an integer"
      end
      into.refused = into.refused + refused
      into.runs = into.runs + 1
      for cause, k in pairs(causes) do
        if not (k is integer) then
          return nil, "row " .. tostring(i) .. ": cause " .. cause .. " is not an integer"
        end
        into.causes[cause] = (into.causes[cause] or 0) + k
      end
      for tag, k in pairs(Json.object_of(fields["layers"]) or {}) do
        if not (k is integer) then
          return nil, "row " .. tostring(i) .. ": layer " .. tag .. " is not an integer"
        end
        into.layers[tag] = (into.layers[tag] or 0) + k
      end
      found[named] = into
    end
  end
  if next(found) == nil then
    return nil, "it has no refusal causes: run that round again with this eval/agent"
  end
  return found
end

--- `earlier` with each tool the names of `renames` (NEW=OLD, `--against-as`) says it had under the name it has now.
function Agent.renamed(earlier: {string: Agent.Earlier}, renames: {string: string}?): {string: Agent.Earlier}
  local wanted: mut {string: string} = {}
  for now, then_ in pairs(renames or {}) do wanted[then_] = now end
  local out: mut {string: Agent.Earlier} = {}
  for name, e in pairs(earlier) do out[wanted[name] or name] = e end
  return out
end

--- What to say where `earlier` names none of `options`' tools, as the report's comparison would then show nothing and
--- say nothing of why; nil where at least one matches.
function Agent.unmatched(options: Agent.Options, earlier: {string: Agent.Earlier}): string?
  for _, tool in ipairs(options.tools) do
    if earlier[tool.name] ~= nil then return nil end
  end
  local names: mut {string} = {}
  for name in pairs(earlier) do names[#names + 1] = name end
  table.sort(names)
  return "it has no tool named like a tool of this round, so nothing is compared; its tools are " ..
    (if #names > 0 then table.concat(names, ", ") else "none" end) .. ": name them with --against-as NEW=OLD."
end

--- The first line of `text` that is not blank, cut to 200 bytes; nil for none.
function Agent.first_line(text: string): string?
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local trimmed = ((line:gsub("^%s+", "")):gsub("%s+$", ""))
    if trimmed ~= "" then return trimmed:sub(1, 200) end
  end
  return nil
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
  local snippets, _ = db:rows("SELECT input FROM outputs WHERE session = ?1 AND tool = 'run' ORDER BY rowid",
    { { integer = id } })
  -- A helper's name starts with a small letter, after no other word (MyHost.x).
  local helpers: mut {string: integer} = {}
  local resends, sorts = 0, 0
  local before: string? = nil
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
    if text == before then resends = resends + 1 end
    before = text
    if text:find("%f[%w_]Host%.sort%f[^%w_]") ~= nil or text:find("%f[%w_]table%.sort%f[^%w_]") ~= nil or
        text:find("%f[%w_]version_sort%f[^%w_]") ~= nil then
      sorts = sorts + 1
    end
  end
  local first, _ = db:rows("SELECT coalesce(cache_read, 0) FROM requests WHERE session = ?1 AND status = 200 ORDER BY rowid " ..
      "LIMIT 1", { { integer = id } })
  local refusals, _ = db:rows("SELECT text FROM outputs WHERE session = ?1 AND tool = 'run' AND " ..
      "instr(text, 'The checker refused the snippet') = 1", { { integer = id } })
  local codes: mut {string: integer} = {}
  local causes: mut {string: integer} = {}
  local guesses: mut {string: integer} = {}
  local layers: mut {string: integer} = {}
  for _, refusal in ipairs(refusals or {}) do
    local seen: mut {string: boolean} = {}
    local named: mut {string: boolean} = {}
    local tags: mut {string: boolean} = {}
    for _, finding in ipairs(Causes.findings(refusal:text(1))) do
      if seen[finding.code] == nil then
        seen[finding.code] = true
        codes[finding.code] = (codes[finding.code] or 0) + 1
      end
      local cause = finding.cause.tag .. ": " .. finding.cause.name
      if named[cause] == nil then
        named[cause] = true
        causes[cause] = (causes[cause] or 0) + 1
      end
      if tags[finding.cause.tag] == nil then
        tags[finding.cause.tag] = true
        layers[finding.cause.tag] = (layers[finding.cause.tag] or 0) + 1
      end
      local guess = Causes.guess(finding)
      if guess ~= nil then guesses[guess] = 1 end
    end
  end
  local req, out = r and r[1], o and o[1]
  if req == nil or out == nil then return nil end
  local opened = first and first[1]
  return { requests = req:integer(1), input = req:integer(2), output = req:integer(3), cache_read = req:integer(4),
    cache_write = req:integer(5), cost = req:number(6), seconds = req:integer(7) / 1000, tools = out:integer(1),
    runs = out:integer(2), refused = #(refusals or {}), codes = codes, causes = causes, layers = layers, guesses = guesses,
    resends = resends, sorts = sorts, helpers = helpers,
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

--- How many guessed names a tool's section of the report lists.
local GUESSES_SHOWN <const> = 25

--- The report of `results` for `options`: for each task, each tool's passes and mean spending per run, as
--- Markdown, which the text template eval/report.tmpl writes.
function Agent.report(options: Agent.Options, results: {Agent.Result}, earlier?: {string: Agent.Earlier}): string
  local set: mut {string} = {}
  for _, tool in ipairs(options.tools) do
    local effort = tool.effort
    if effort ~= nil then set[#set + 1] = tool.name .. " " .. effort end
  end
  local dropped: mut {string} = {}
  for _, tool in ipairs(options.tools) do
    local bullets = tool.drop
    if bullets ~= nil then dropped[#dropped + 1] = tool.name .. ": " .. bullets end
  end
  -- Each tool over every task: what a comparison reads first.
  local totals: mut {ReportData.Total} = {}
  for _, tool in ipairs(options.tools) do
    local passed, n, unfit, counted, broken = 0, 0, 0, 0, 0
    local cost, write, read, output, refused = 0.0, 0.0, 0.0, 0.0, 0.0
    for _, r in ipairs(results) do
      if r.tool == tool.name and r.grade == "unfit" then
        unfit = unfit + 1
      elseif r.tool == tool.name and r.grade == "broken" then
        broken = broken + 1
      elseif r.tool == tool.name then
        n = n + 1
        if r.grade == "pass" then passed = passed + 1 end
        local spent = r.spent
        if spent ~= nil then
          counted = counted + 1
          cost, write = cost + spent.cost, write + spent.cache_write
          read, output = read + spent.cache_read, output + spent.output
          refused = refused + spent.refused
        end
      end
    end
    local d = math.max(counted, 1)
    totals[#totals + 1] = { refused = refused / d, tool = tool.name, passed = passed, n = n, unfit = if unfit > 0 then unfit else nil end,
      broken = if broken > 0 then broken else nil end,
      cost = cost / d, cache_read = read / d, cache_write = write / d, output = output / d, total = cost }
  end
  -- Each tool over the tuned tasks and over the held-out ones, where there are both.
  local held_of: mut {string: boolean} = {}
  local any_held, any_tuned = false, false
  for _, task in ipairs(options.tasks) do
    held_of[task.name] = task.held == true
    if task.held == true then any_held = true else any_tuned = true end
  end
  local sets: mut {ReportData.SetTotal} = {}
  if any_held and any_tuned then
    for _, tool in ipairs(options.tools) do
      for _, wanted in ipairs({ false, true }) do
        local passed, n, counted = 0, 0, 0
        local cost, refused = 0.0, 0.0
        for _, r in ipairs(results) do
          if r.tool == tool.name and r.grade ~= "unfit" and r.grade ~= "broken" and held_of[r.task] == wanted then
            n = n + 1
            if r.grade == "pass" then passed = passed + 1 end
            local spent = r.spent
            if spent ~= nil then
              counted = counted + 1
              cost, refused = cost + spent.cost, refused + spent.refused
            end
          end
        end
        local d = math.max(counted, 1)
        sets[#sets + 1] = { tool = tool.name, set = (if wanted then "held out" else "tuned" end), passed = passed, n = n,
          cost = cost / d, refused = refused / d }
      end
    end
  end
  -- Each tool that is not a control, against the controls' spread of one binary's noise.
  local bands: mut {ReportData.Band} = {}
  local is_control: mut {string: boolean} = {}
  local controls = options.controls or {}
  for _, name in ipairs(controls) do is_control[name] = true end
  if #controls > 0 then
    local function range(values: {number}): number, number
      local low, high = values[1] or 0, values[1] or 0
      for _, v in ipairs(values) do
        if v < low then low = v end
        if v > high then high = v end
      end
      return low, high
    end
    local function verdict(value: number, low: number, high: number, spread: boolean): string
      if not spread then return "one control, no spread" end
      if value < low then return "below the controls" end
      if value > high then return "above the controls" end
      return "inside the controls"
    end
    local rates: mut {number} = {}
    local costs: mut {number} = {}
    local refusals: mut {number} = {}
    for _, total in ipairs(totals) do
      if is_control[total.tool] == true then
        rates[#rates + 1] = total.passed / math.max(total.n, 1)
        costs[#costs + 1] = total.cost
        refusals[#refusals + 1] = total.refused
      end
    end
    local spread = #rates > 1
    local r_low, r_high = range(rates)
    local c_low, c_high = range(costs)
    local f_low, f_high = range(refusals)
    for _, total in ipairs(totals) do
      if is_control[total.tool] ~= true then
        local rate = total.passed / math.max(total.n, 1)
        bands[#bands + 1] = { tool = total.tool, lines = {
          string.format("passed %.1f%%; controls %.1f%% to %.1f%%: %s", rate * 100, r_low * 100, r_high * 100,
            verdict(rate, r_low, r_high, spread)),
          string.format("cost $%.4f a run; controls $%.4f to $%.4f: %s", total.cost, c_low, c_high,
            verdict(total.cost, c_low, c_high, spread)),
          string.format("refused %.2f a run; controls %.2f to %.2f: %s", total.refused, f_low, f_high,
            verdict(total.refused, f_low, f_high, spread)) } }
      end
    end
  end
  local tasks: mut {ReportData.Task} = {}
  for _, task in ipairs(options.tasks) do
    local rows: mut {ReportData.Row} = {}
    for _, tool in ipairs(options.tools) do
      local passed, unfit, n, counted, broken = 0, 0, 0, 0, 0
      local why: string? = nil
      local sum: mut {string: number} = { requests = 0, input = 0, output = 0, cache_read = 0, cache_write = 0,
        cost = 0, seconds = 0, tools = 0, runs = 0, refused = 0, first_read = 0, wall = 0, resends = 0, sorts = 0 }
      local codes: mut {string: integer} = {}
      local helpers: mut {string: integer} = {}
      for _, r in ipairs(results) do
        if r.tool == tool.name and r.task == task.name then
          if r.grade ~= "broken" then n = n + 1 end
          if r.grade == "pass" then
            passed = passed + 1
          elseif r.grade == "unfit" then
            unfit = unfit + 1
          elseif r.grade == "broken" then
            broken = broken + 1
            why = why or r.why
          end
          if r.grade ~= "broken" then sum["wall"] = (sum["wall"] or 0) + r.wall end
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
            sum["resends"] = (sum["resends"] or 0) + s.resends
            sum["sorts"] = (sum["sorts"] or 0) + s.sorts
            for code, k in pairs(s.codes) do codes[code] = (codes[code] or 0) + k end
            for name, k in pairs(s.helpers) do helpers[name] = (helpers[name] or 0) + k end
          end
        end
      end
      local d = math.max(counted, 1)
      local function mean(k: string): number return (sum[k] or 0) / d end
      local grade = tostring(passed) .. " of " .. tostring(n) .. " passed"
      if unfit > 0 then grade = "unfit on this fixture" end
      if broken > 0 then grade = grade .. ", " .. tostring(broken) .. " broken" end
      rows[#rows + 1] = { tool = tool.name, grade = grade, requests = mean("requests"), cost = mean("cost"),
        wall = (sum["wall"] or 0) / math.max(n, 1), seconds = mean("seconds"), input = mean("input"),
        output = mean("output"), cache_read = mean("cache_read"), first_read = mean("first_read"),
        cache_write = mean("cache_write"), tools = mean("tools"), runs = mean("runs"), refused = mean("refused"),
        resends = if (sum["resends"] or 0) > 0 then mean("resends") else nil end,
        sorts = if (sum["sorts"] or 0) > 0 then mean("sorts") else nil end, broken = why,
        refused_for = ranked(codes, function(k: integer): string return tostring(k) end),
        helpers = ranked(helpers, function(k: integer): string
          return string.format("%.1f", k / d)
        end) }
    end
    tasks[#tasks + 1] = { name = task.name, rows = rows }
  end
  local causes: mut {ReportData.Causes} = {}
  local guesses: mut {ReportData.Guesses} = {}
  for _, tool in ipairs(options.tools) do
    local refused, counted_runs = 0, 0
    local by_cause: mut {string: integer} = {}
    local cause_tasks: mut {string: mut {string: integer}} = {}
    local by_layer: mut {string: integer} = {}
    local by_name: mut {string: integer} = {}
    local name_tasks: mut {string: mut {string: integer}} = {}
    for _, r in ipairs(results) do
      local s = r.spent
      if r.tool == tool.name and s ~= nil then
        refused = refused + s.refused
        counted_runs = counted_runs + 1
        for tag, k in pairs(s.layers) do by_layer[tag] = (by_layer[tag] or 0) + k end
        for key, k in pairs(s.causes) do
          by_cause[key] = (by_cause[key] or 0) + k
          local per = cause_tasks[key] or {}
          per[r.task] = (per[r.task] or 0) + k
          cause_tasks[key] = per
        end
        for key, k in pairs(s.guesses) do
          by_name[key] = (by_name[key] or 0) + k
          local per = name_tasks[key] or {}
          per[r.task] = (per[r.task] or 0) + k
          name_tasks[key] = per
        end
      end
    end
    local listed: mut {ReportData.Cause} = {}
    local before = if earlier ~= nil then earlier[tool.name] else nil end
    local function shown(k: integer): string return tostring(k) end
    for key, k in pairs(by_cause) do
      local tag, name = key:match("^(%l+): (.*)$")
      local per_task = cause_tasks[key] or {}
      local breadth = 0
      for _, _ in pairs(per_task) do breadth = breadth + 1 end
      local spread = (if breadth == 1 then "one task only, so fitting it is likely" else tostring(breadth) .. " tasks" end)
      listed[#listed + 1] = { tag = tag or "untagged", name = name or key, count = k,
        tasks = spread .. ": " .. (ranked(per_task, shown) or ""), was = if before ~= nil then before.causes[key] or 0 else nil end }
    end
    -- A cause the earlier round had and this one lacks is the change a fix is made for: it stays, at none.
    if before ~= nil then
      for key, k in pairs(before.causes) do
        if by_cause[key] == nil then
          local tag, name = key:match("^(%l+): (.*)$")
          listed[#listed + 1] = { tag = tag or "untagged", name = name or key, count = 0, tasks = "", was = k }
        end
      end
    end
    table.sort(listed, function(a: ReportData.Cause, b: ReportData.Cause): boolean
      if a.count ~= b.count then return a.count > b.count end
      if a.was ~= b.was then return (a.was or 0) > (b.was or 0) end
      return a.name < b.name
    end)
    if #listed > 0 then
      causes[#causes + 1] = { tool = tool.name, refused = refused, runs = counted_runs,
        layers = ranked(by_layer, shown) or "", causes = listed,
        was = if before ~= nil then tostring(before.refused) .. " refused snippets in " .. tostring(before.runs) ..
            " runs; by layer: " .. (ranked(before.layers, shown) or "none") else nil end }
    end
    local names: mut {ReportData.Guess} = {}
    for key, k in pairs(by_name) do
      names[#names + 1] = { name = key, runs = k, tasks = ranked(name_tasks[key] or {}, shown) or "" }
    end
    table.sort(names, function(a: ReportData.Guess, b: ReportData.Guess): boolean
      if a.runs ~= b.runs then return a.runs > b.runs end
      return a.name < b.name
    end)
    if #names > 0 then
      local more = #names - GUESSES_SHOWN
      while #names > GUESSES_SHOWN do names[#names] = nil end
      guesses[#guesses + 1] = { tool = tool.name, names = names, more = if more > 0 then more else nil end }
    end
  end
  return Report.render({ model = options.model, reps = options.reps, fixture = options.fixture,
    effort = if #set > 0 then table.concat(set, ", ") else nil end, totals = totals, sets = sets, bands = bands,
    tasks = tasks, drop = if #dropped > 0 then table.concat(dropped, "; ") else nil end,
    against_note = if earlier ~= nil then Agent.unmatched(options, earlier) else nil end,
    agents_md = if options.without_agents_md == true then "AGENTS.md and CLAUDE.md left out of the fixture" else nil end,
    causes = causes, guesses = guesses })
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
  local function retarget(from: string, to: string, root: string)
    local parent = to:match("^(.*)/[^/]*$")
    if parent ~= nil and parent ~= "" then assert(Fs.mkdirs(parent)) end
    local real_root = assert(sys.realpath(root))
    -- A tool named bare, as `--tool t=cosmic` names it, is the one on PATH, as [`real`]'s `run` finds it.
    local source = from
    if from:find("/", 1, true) == nil then
      local found, _ = Proc.find(from)
      source = found or from
    end
    assert(Fs.write(to, ArtifactRow.with(assert(Fs.read(source)), to .. ".retarget.db", real_root)))
    -- rwxr-xr-x
    assert(Fs.chmod(to, 493))
  end
  return { run = run, fresh = fresh, discard = discard, spent = spent, put = put, serve = serve, retarget = retarget }
end

--- Copies the binary of `tool` to <out>/<name>/tool/cosmic, where there is no copy yet, and gives the round that copy
--- to run: a rebuild of the tree it came from, while the round runs, changes no arm. Where the copy is there (the round goes
--- on), it is kept, and `note` says if the tool's path now holds another binary. A script (`bin/cosmic` is one) cannot be
--- copied out of its tree, and runs as it is. The arm names the binary by its sha256.
function Agent.freeze(tool: Agent.Tool, out: string): (Agent.Frozen) | (nil, string)
  local source = tool.path
  if source:find("/", 1, true) == nil then
    local found, _ = Proc.find(source)
    if found == nil then return nil, "no " .. source .. " on PATH for the tool " .. tool.name end
    source = found
  end
  local bytes, read_why = Fs.read(source)
  if bytes == nil then return nil, "tool " .. tool.name .. ": " .. tostring(read_why) end
  local dir = out .. "/" .. tool.name .. "/tool"
  local copy = dir .. "/cosmic"
  local path = copy
  local note: string? = nil
  local have = false
  local status, _ = Fs.status(copy)
  if status ~= nil then have = status.exists end
  if bytes:sub(1, 2) == "#!" then
    path = source
    note = "tool " .. tool.name .. " is a script, which runs from where it is: a change to its tree reaches the round"
  elseif not have then
    local made, made_why = Fs.mkdirs(dir)
    if made == nil then return nil, dir .. ": " .. tostring(made_why) end
    -- Written under another name and renamed, so a copy found later is whole.
    local partial = copy .. ".partial"
    local wrote, wrote_why = Fs.write(partial, bytes)
    if wrote == nil then return nil, partial .. ": " .. tostring(wrote_why) end
    -- rwxr-xr-x
    local chmoded, chmod_why = Fs.chmod(partial, 493)
    if chmoded == nil then return nil, partial .. ": " .. tostring(chmod_why) end
    local moved, moved_why = Fs.rename(partial, copy)
    if moved == nil then return nil, copy .. ": " .. tostring(moved_why) end
  else
    local was, _ = Hash.hex_file("sha256", copy)
    local now, _ = Hash.hex_file("sha256", source)
    if was ~= now then
      note = "tool " .. tool.name .. ": " .. tool.path .. " is not the binary this round began with, which it goes on with (" ..
        copy .. ")"
    end
  end
  local sha, sha_why = Hash.hex_file("sha256", path)
  if sha == nil then return nil, path .. ": " .. tostring(sha_why) end
  return { tool = { name = tool.name, path = path, drop = tool.drop, effort = tool.effort, commands = tool.commands },
    arm = { name = tool.name, sha = sha, path = tool.path, effort = tool.effort, drop = tool.drop, commands = tool.commands },
    note = note }
end

--- `counts` as a JSON object.
local function counts_of(counts: {string: integer}): {string: Json.Value}
  local object: mut {string: Json.Value} = {}
  for key, k in pairs(counts) do object[key] = k end
  return object
end

--- The line of each run of `results` for results.json, which tools that read it by tool name still read.
local function rows_of(results: {Agent.Result}): {Json.Value}
  local rows: mut {Json.Value} = {}
  for _, r in ipairs(results) do
    local row: mut {string: Json.Value} = { tool = r.tool, task = r.task, rep = r.rep, grade = r.grade, wall = r.wall }
    local s = r.spent
    if s ~= nil then
      row["requests"], row["cost"], row["input"], row["output"] = s.requests, s.cost, s.input, s.output
      row["cache_read"], row["cache_write"] = s.cache_read, s.cache_write
      row["seconds"], row["tools"], row["runs"] = s.seconds, s.tools, s.runs
      row["refused"], row["first_read"] = s.refused, s.first_read
      row["codes"], row["causes"], row["layers"] = counts_of(s.codes), counts_of(s.causes), counts_of(s.layers)
      row["guesses"], row["helpers"] = counts_of(s.guesses), counts_of(s.helpers)
    end
    local broke = r.why
    if broke ~= nil then row["why"] = broke end
    rows[#rows + 1] = row
  end
  return rows
end

--- The runs of `all` that are of a tool and a task of `options`, and a rep it asks for.
local function wanted(options: Agent.Options, all: {Agent.Result}): {Agent.Result}
  local tools: mut {string: boolean} = {}
  for _, t in ipairs(options.tools) do tools[t.name] = true end
  local tasks: mut {string: boolean} = {}
  for _, t in ipairs(options.tasks) do tasks[t.name] = true end
  local kept: mut {Agent.Result} = {}
  for _, r in ipairs(all) do
    if tools[r.tool] == true and tasks[r.task] == true and r.rep <= options.reps then
      kept[#kept + 1] = r
    end
  end
  return kept
end

--- Runs the arms `names` of the round, each in a process of its own, at most `jobs` at a time: this program again, given
--- `argv` and `--arm`. Each shares the database. Nil and why where one cannot start; a process that fails
--- is told of, and the round goes on with the others.
local function in_processes(argv: {string}, names: {string}, jobs: integer, log: function(string)): (true) | (nil, string)
  local again, again_why = Proc.relaunch()
  if again == nil then
    return nil, "--jobs: this program cannot start again: " .. tostring(again_why)
  end
  local env: mut {string: string} = {}
  for k, v in pairs(Env.all()) do env[k] = v end
  for k, v in pairs(again.env) do env[k] = v end
  local running: mut {string: Child.Handle} = {}
  local waiting: mut {string} = {}
  for _, name in ipairs(names) do waiting[#waiting + 1] = name end
  local function count(): integer
    local n = 0
    for _, _ in pairs(running) do n = n + 1 end
    return n
  end
  local failed: mut {string} = {}
  while #waiting > 0 or count() > 0 do
    while #waiting > 0 and count() < jobs do
      local name = table.remove(waiting, 1) or ""
      local words: mut {string} = {}
      for _, w in ipairs(again.argv) do words[#words + 1] = w end
      local script = again.script
      if script ~= nil then words[#words + 1] = script end
      for _, w in ipairs(argv) do words[#words + 1] = w end
      words[#words + 1] = "--arm"
      words[#words + 1] = name
      local handle, why = Child.start(words, { cwd = again.cwd, env = env, fds = again.fds, stdin = "null",
        stdout = "inherit", stderr = "inherit", timeout_ns = Child.FOREVER })
      if handle == nil then
        for _, h in pairs(running) do local _, _ = h:close() end
        return nil, "arm " .. name! .. " did not start: " .. tostring(why)
      end
      log("arm " .. name! .. " started in its own process")
      running[name] = handle
    end
    for name, handle in pairs(running) do
      local done, _ = handle:try_wait()
      if done ~= nil and done.finished then
        local res = done.result
        local code = (if res ~= nil then res.code else nil end)
        log("arm " .. name .. " ended with exit " .. tostring(code))
        running[name] = nil
        if code ~= 0 and code ~= 1 then
          failed[#failed + 1] = name .. " (exit " .. tostring(code) .. ")"
        end
      end
    end
    local _, _ = Clock.sleep(200000000)
  end
  if #failed > 0 then
    return nil, "the process of an arm ended with an error: " .. table.concat(failed, ", ")
  end
  return true
end

--- Runs the evals `argv` asks for: 0 when every graded run passed, 1 when one did not, 2 for a bad command line.
function Agent.main(argv: {string}): integer
  local options, why = Agent.parse(argv)
  if options == nil then
    local _, _ = Fs.put(Fs.stderr, "eval/agent: " .. why .. "\n")
    return 2
  end
  local function complain(text: string): integer
    local _, _ = Fs.put(Fs.stderr, "eval/agent: " .. text .. "\n")
    return 2
  end
  local key = Env.get("ANTHROPIC_API_KEY") or Env.get("HARNESS_ANTHROPIC_API_KEY") or ""
  if key == "" then return complain("set ANTHROPIC_API_KEY or HARNESS_ANTHROPIC_API_KEY") end
  local out = options.out
  assert(Fs.mkdirs(out))
  local round = options.round or out:match("([^/]+)/*$") or "round"
  -- A line for each step, from each process: what a round that ended without a word was doing.
  local function log(line: string)
    local stamp = Time.format_rfc3339(Clock.now_ns(), nil, { digits = 0 })
    local _, _ = Fs.append(out .. "/round.log", stamp .. " " .. round .. " " .. line .. "\n")
  end
  local earlier: {string: Agent.Earlier}? = nil
  local against = options.against
  if against ~= nil then
    local before: {string: Agent.Earlier}? = nil
    if against:sub(-3) == ".db" then
      local adb, open_why = Sqlite.open(against)
      if adb == nil then return complain("--against " .. against .. ": " .. tostring(open_why)) end
      local which = options.against_round or Runs.latest(adb, round)
      if which == nil then
        return complain("--against " .. against .. ": it holds no other round")
      end
      local found, bad = Runs.earlier(adb, which)
      local _, _ = adb:close()
      if found == nil then return complain("--against " .. against .. ": " .. bad) end
      before = found
    else
      local text, read_why = Fs.read(against)
      if text == nil then return complain("--against " .. against .. ": " .. tostring(read_why)) end
      local found, bad = Agent.earlier(text)
      if found == nil then return complain("--against " .. against .. ": " .. bad) end
      before = found
    end
    earlier = Agent.renamed(before, options.against_as)
    local note = Agent.unmatched(options, earlier)
    if note ~= nil then
      local _, _ = Fs.put(Fs.stderr, "eval/agent: --against " .. against .. ": " .. note .. "\n")
    end
  end
  local db, db_why = Runs.open(options.db or out .. "/runs.db")
  if db == nil then return complain(db_why) end
  -- The arms this process runs, each as the binary it keeps.
  local only: mut {string: boolean} = {}
  for _, name in ipairs(options.arms or {}) do only[name] = true end
  local running: mut {Agent.Tool} = {}
  local arms: mut {Runs.Arm} = {}
  local by_name: mut {string: Runs.Arm} = {}
  local selected: mut {string} = {}
  for _, tool in ipairs(options.tools) do
    if options.arms == nil or only[tool.name] == true then
      local frozen, freeze_why = Agent.freeze(tool, out)
      if frozen == nil then return complain(freeze_why) end
      running[#running + 1] = frozen.tool
      arms[#arms + 1] = frozen.arm
      by_name[tool.name] = frozen.arm
      selected[#selected + 1] = tool.name
      local note = frozen.note
      if note ~= nil then
        log(note)
        local _, _ = Fs.put(Fs.stderr, "eval/agent: " .. note .. "\n")
      end
    else
      running[#running + 1] = tool
    end
  end
  local began, began_why = Runs.begin(db, { id = round, model = options.model, reps = options.reps,
    fixture = options.fixture }, arms)
  if began == nil then return complain(began_why) end
  if options.arms == nil then
    local reopened, reopened_why = Runs.reopen(db, round)
    if reopened == nil then return complain(reopened_why) end
  end
  log("begun: arms " .. table.concat(selected, ", ") .. "; reps " .. tostring(options.reps) .. "; db " ..
      (options.db or out .. "/runs.db"))
  local jobs = options.jobs or 1
  local stopped: string? = nil
  if jobs > 1 and options.arms == nil and #selected > 1 then
    local started, start_why = in_processes(argv, selected, jobs, log)
    if started == nil then return complain(start_why) end
  else
    local store: Agent.Store = {
      known = function(tool: string, task: string, rep: integer): Agent.Result?
        local held = Runs.known(db, round, tool, task, rep)
        -- A run that did not reach the model is made again: its cause was the harness's, which may be mended.
        if held ~= nil and held.grade == "broken" then return nil end
        return held
      end,
      record = function(tool: Agent.Tool, result: Agent.Result)
        local arm = by_name[tool.name]
        assert(arm ~= nil, "no arm " .. tool.name)
        assert(Runs.put(db, round, arm, options.model, result))
      end,
    }
    local run_options: Agent.Options = { tools = running, fixture = options.fixture, out = out, tasks = options.tasks,
      reps = options.reps, model = options.model, timeout = options.timeout,
      without_agents_md = options.without_agents_md, against = options.against, controls = options.controls,
      testdata = options.testdata, arms = options.arms }
    local results = Agent.execute(run_options, real(out), key, Env.all(), function(path: string, text: string)
      assert(Fs.write(path, text))
      local grade = text:match("^grade: (%S+)") or "?"
      -- A line as each run ends, so a long round shows it moves.
      print(grade .. "  " .. path)
      log(grade .. " " .. path)
    end, store)
    local last = results[#results]
    stopped = last and last.stopped
    local _, _ = Runs.finish(db, round, stopped)
    if stopped ~= nil then log("stopped: " .. stopped) end
  end
  if options.arms ~= nil then
    -- Part of a round: the report waits for a call that names every arm.
    log("arms " .. table.concat(selected, ", ") .. " done")
    local _, _ = db:close()
    if stopped ~= nil then
      local _, _ = Fs.put(Fs.stderr, "eval/agent: stopped: " .. stopped .. "\n")
      return 1
    end
    return 0
  end
  local all, all_why = Runs.results(db, round)
  if all == nil then return complain(all_why) end
  local results = wanted(options, all)
  stopped = stopped or Runs.stopped(db, round)
  local _, _ = Runs.finish(db, round, nil)
  local _, _ = db:close()
  local expected = #options.tools * #options.tasks * options.reps
  local missing = expected - #results
  assert(Fs.write(out .. "/report.md", Agent.report(options, results, earlier) .. "\n"))
  assert(Fs.write(out .. "/results.json", assert(Json.encode(Json.array(rows_of(results)))) .. "\n"))
  print(out .. "/report.md")
  log("report written: " .. tostring(#results) .. " runs")
  if stopped ~= nil then
    local _, _ = Fs.put(Fs.stderr, "eval/agent: stopped: " .. stopped .. "\n")
    return 1
  end
  if missing > 0 then
    local _, _ = Fs.put(Fs.stderr, "eval/agent: " .. tostring(missing) .. " of " .. tostring(expected) ..
        " runs are not in the database: run the same command again to go on\n")
    return 1
  end
  for _, r in ipairs(results) do
    if r.grade == "fail" or r.grade == "broken" then return 1 end
  end
  return 0
end

return Agent
