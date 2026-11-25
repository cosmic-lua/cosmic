--- Runs the evals of cosmic agent itself: fixed tasks on a copy of a fixture tree, each solved by `cosmic agent ask`
--- with each tool under test, and graded by comparing what the agent left against what a command computes from the
--- untouched fixture. It tells, for each tool and task, how many runs passed and what they spent: requests (turns),
--- tokens, cost, seconds and tool calls, read from each tool's own sessions.db. Two tools of one task compare, for
--- example, the agent with code mode and the release before it.
---
---     cosmic --standalone eval/agent.tl --tool NAME=PATH [--tool NAME=PATH ...] --fixture DIR --out DIR
---         [--offer NAME=TOOL,...] [--effort [NAME=]LEVEL] [--tasks T,...|all] [--reps N] [--model M]
---         [--timeout S]
---
--- `--offer NAME=run,read` runs the agent of the tool NAME with `--tools run,read`: one binary under two names
--- compares, for example, the agent with bash and without it. `--effort NAME=low` runs the agent of the tool NAME
--- with `--effort low`, and `--effort low` every tool not named so: one binary under two names compares two efforts.
--- Where none is given, the agent takes its own default.
--- The fixture is a tree the tasks read, such as this repository at a commit
--- (`git archive <commit> | tar -x -C DIR`); the report names it, and a task whose truth comes out empty on it is
--- marked unfit rather than graded. A task of an MCP server (mcp-*) gives the run `--mcp`, a config of the
--- server laid out in its own temp directory, which the agent's tools may not read: only a snippet reaches it, so a
--- tool with no `--mcp` or no code mode fails it. Where the evals run as root, the tool's path must be one every
--- user may search, as the server runs as a user of its own. Each run is a fresh copy, `bench-<tool>-<task>-*` in the temp directory, with
--- `HOME` and `XDG_DATA_HOME` the tool's own under <out>/<tool>. ANTHROPIC_API_KEY, or HARNESS_ANTHROPIC_API_KEY,
--- is the key. <out>/report.md is the report, <out>/results.json each run's numbers, and each run's answer, the
--- agent's words, and the grade are in <out>/<tool>/<task>-<rep>.txt. [`eval/agent`] runs this on the bootstrap
--- cosmic: it requires `cosmic.*` modules only. [`Agent.execute`] works through an [`Agent.System`], which a test
--- replaces with a fake.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
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
    --- A bash command run in the run's copy once the agent ended: its output must be the truth's.
    check: string
    --- An MCP server the run is given, where the task needs one. Its truth runs with `$data` the path of the
    --- server's data.
    server?: Server
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
    --- What one run spent: the session of `tool` whose directory's name holds `marker`.
    spent: function(tool: string, marker: string): Agent.Spent?
    --- Writes `text` to the file `path`.
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
      "lines: one `count path` per line (path from this directory, as cosmic/x.tl), largest first, ties by path.",
    truth = "find cosmic -name '*.tl' -type f -exec wc -l {} + | grep -v ' total$' | awk '{print $1\" \"$2}' | " ..
      "sort -k1,1nr -k2,2 | head -5",
    check = "cat answer.txt",
  },
  {
    name = "todos",
    prompt = "Write to answer.txt every line of the .tl files under cosmic/ that holds `TODO`, as " ..
      "`path:line` (path from this directory, line numbered from 1), one a line, sorted by path, then by line.",
    truth = "grep -rn --include='*.tl' 'TODO' cosmic | cut -d: -f1,2 | sort -t: -k1,1 -k2,2n",
    check = "cat answer.txt",
  },
  {
    name = "requires",
    prompt = "For each .tl file under cosmic/agent/ whose name does not end in _test.tl, count the distinct " ..
      "modules it names in `require(\"cosmic.<...>\")`. Write to answer.txt the three with the most, as " ..
      "`count path`, one a line, most first, ties by path.",
    truth = "for f in $(find cosmic/agent -name '*.tl' ! -name '*_test.tl'); do " ..
      "echo \"$(grep -o 'require(\"cosmic\\.[^\"]*\")' \"$f\" | sort -u | wc -l) $f\"; done | " ..
      "sort -k1,1nr -k2,2 | head -3",
    check = "cat answer.txt",
  },
  {
    name = "tests",
    prompt = "For every file under cosmic/agent/ whose name ends in _test.tl, count the lines that start " ..
      "`local function test_`. Write to answer.txt one `path count` per line, most first, ties by path.",
    truth = "for f in $(find cosmic/agent -name '*_test.tl'); do " ..
      "echo \"$f $(grep -c '^local function test_' \"$f\")\"; done | sort -k2,2nr -k1,1",
    check = "cat answer.txt",
  },
  {
    name = "undocumented",
    prompt = "In the .tl files under cosmic/agent/ whose names do not end in _test.tl, find each line that " ..
      "starts `local function <name>(` where the line just before it does not start with `---`. Write to " ..
      "answer.txt one `path:line name` per line, sorted by path, then by line.",
    truth = [==[find cosmic/agent -name '*.tl' ! -name '*_test.tl' | sort | xargs awk 'FNR==1{prev=""} /^local function [A-Za-z_][A-Za-z0-9_]*\(/ { if (prev !~ /^---/) { n=$3; sub(/\(.*/,"",n); print FILENAME":"FNR" "n } } {prev=$0}' | sort -t: -k1,1 -k2,2n]==],
    check = "cat answer.txt",
  },
  {
    name = "fan-in",
    prompt = "For each .tl file directly in cosmic/ (not in a subdirectory, and not ending in _test.tl), say " ..
      "cosmic/<x>.tl, count the other .tl files anywhere under cosmic/ that hold the text `require(\"cosmic.<x>\")`. " ..
      "Write to answer.txt the ten with the most, as `count cosmic.<x>`, most first, ties by name.",
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
      "(cosmic, or cosmic/x/y). Then, with SQL on it, write to answer.txt one `dir count lines` per line, the " ..
      "files and lines of each dir: the ten dirs of the most lines, most first, ties by dir.",
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
      "appears. Write to answer.txt the five modules named most, as `count cosmic.<...>`, most first, ties by name.",
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
      "`sum category`, one a line, largest first, ties by category.",
    truth = "awk -F'\\t' '{s[$3] += $4 * $5} END {for (c in s) print s[c]\" \"c}' \"$data\" | sort -k1,1nr -k2,2",
    check = "cat answer.txt",
    server = { name = "inventory", source = INVENTORY_SERVER, data = inventory() },
  },
  {
    name = "mcp-low",
    prompt = "Write to answer.txt each item of the inventory MCP server whose stock is below 3, as `id stock`, " ..
      "one a line, sorted by id.",
    truth = "awk -F'\\t' '$5 < 3 {print $1\" \"$5}' \"$data\" | sort",
    check = "cat answer.txt",
    server = { name = "inventory", source = INVENTORY_SERVER, data = inventory() },
  },
  {
    name = "web-low",
    prompt = "The inventory web API at {url} answers GET /items?page=N, from page 1, with JSON: `items`, each " ..
      "with id, name, category, price_cents and stock, and `next`, the page after it, which the last page has " ..
      "not. Write to answer.txt each item whose stock is below 3, as `id stock`, one a line, sorted by id.",
    truth = "awk -F'\\t' '$5 < 3 {print $1\" \"$5}' \"$data\" | sort",
    check = "cat answer.txt",
    site = { source = INVENTORY_SITE, data = inventory() },
  },
  {
    name = "earlier-log",
    prompt = "The web API at {url} serves its event log as plain text at GET /log: lines of " ..
      "`HH:MM:SS LEVEL component message`. Print the log.",
    follow_up = "Write to answer.txt, for each component, how many lines of that log have level ERROR, as " ..
      "`count component`, one a line, most first, ties by component.",
    truth = "awk '$2 == \"ERROR\" {n[$3]++} END {for (c in n) print n[c]\" \"c}' \"$data\" | sort -k1,1nr -k2,2",
    check = "cat answer.txt",
    site = { source = LOG_SITE, data = event_log() },
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

--- Lays out `server` for a run of `tool` in a fresh directory, through `system`: its program, its data and the
--- config naming it, held to reading that directory, which every user may read: where the agent is root, its
--- servers run as a user of their own. The config's path.
local function laid_out(system: Agent.System, server: Agent.Server, tool: Agent.Tool, prefix: string): string
  local dir = system.fresh(prefix)
  system.put(dir .. "/server.tl", server.source)
  system.put(dir .. "/data.tsv", server.data)
  local servers: {string: Json.Value} = { [server.name] = {
    command = Json.array({ tool.path, "--standalone", dir .. "/server.tl", dir .. "/data.tsv" }),
    policy = { profiles = Json.array({ "cosmic" }), grants = Json.array({ { path = dir, letters = "r" } }) },
  } }
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
  local results: mut {Agent.Result} = {}
  local truths: mut {string: string} = {}
  for _, task in ipairs(options.tasks) do
    local pristine = system.fresh("truth-" .. task.name .. "-")
    system.run({ "cp", "-a", options.fixture .. "/.", pristine }, "/", nil, 600)
    local script = task.truth
    local server, site = task.server, task.site
    local served: string? = if server ~= nil then server.data elseif site ~= nil then site.data else nil end
    if served ~= nil then
      local data = system.fresh("data-" .. task.name .. "-") .. "/data.tsv"
      system.put(data, served)
      script = "data=" .. quoted(data) .. "; " .. script
    end
    local truth = system.run({ "bash", "-c", script }, pristine, nil, 60)
    truths[task.name] = Agent.lines_of(truth.stdout)
  end
  for _, tool in ipairs(options.tools) do
    local data, home = options.out .. "/" .. tool.name .. "/data", options.out .. "/" .. tool.name .. "/home"
    system.run({ "mkdir", "-p", data, home }, "/", nil, 60)
    local env = env_of(base, key, data, home)
    for _, task in ipairs(options.tasks) do
      for rep = 1, options.reps do
        local marker = "bench-" .. tool.name .. "-" .. task.name .. "-"
        local work = system.fresh(marker)
        system.run({ "cp", "-a", options.fixture .. "/.", work }, "/", nil, 600)
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
        local server = task.server
        if server ~= nil then
          local config = laid_out(system, server, tool, "mcp-" .. tool.name .. "-" .. task.name .. "-")
          argv[#argv + 1] = "--mcp"
          argv[#argv + 1] = config
        end
        local prompt = task.prompt
        local stop: function() = function() end
        local unserved: string? = nil
        local site = task.site
        if site ~= nil then
          local dir = system.fresh("site-" .. tool.name .. "-" .. task.name .. "-")
          system.put(dir .. "/site.tl", site.source)
          system.put(dir .. "/data.tsv", site.data)
          local port, ended = system.serve({ tool.path, "--standalone", dir .. "/site.tl", dir .. "/data.tsv",
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
          asked = system.run(argv, work, env, options.timeout)
          if follow_up == nil or asked.code ~= 0 then return end
          again[#again + 1] = follow_up
          local next_asked = system.run(again, work, env, options.timeout)
          asked = { code = next_asked.code, stdout = asked.stdout .. "\n--- follow-up\n" .. next_asked.stdout,
            stderr = asked.stderr .. "\n--- follow-up\n" .. next_asked.stderr,
            seconds = (asked.seconds or 0) + (next_asked.seconds or 0) }
        end)
        stop()
        if not ran then error(why, 0) end
        local truth = truths[task.name] or ""
        local left = Agent.lines_of(system.run({ "bash", "-c", task.check }, work, nil, 60).stdout)
        local grade = "fail"
        if truth == "" then grade = "unfit" elseif left == truth then grade = "pass" end
        write(options.out .. "/" .. tool.name .. "/" .. task.name .. "-" .. tostring(rep) .. ".txt",
          "grade: " .. grade .. "\nexit: " .. tostring(asked.code) .. "\n--- left\n" .. left .. "\n--- truth\n" ..
            truth .. "\n--- words\n" .. asked.stdout .. "\n--- stderr\n" .. asked.stderr .. "\n")
        results[#results + 1] = { tool = tool.name, task = task.name, rep = rep, grade = grade,
          spent = system.spent(tool.name, work:match("[^/]+$") or marker), wall = asked.seconds or 0 }
      end
    end
  end
  return results
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

--- The report of `results` for `options`: for each task, each tool's passes and mean spending per run, as
--- Markdown.
function Agent.report(options: Agent.Options, results: {Agent.Result}): string
  local lines: mut {string} = { "# cosmic agent evals", "",
    "Model " .. options.model .. "; runs of each task with each tool: " .. tostring(options.reps) .. "; fixture " ..
      options.fixture .. ". Each number is the mean of a run.", "" }
  local set: mut {string} = {}
  for _, tool in ipairs(options.tools) do
    local effort = tool.effort
    if effort ~= nil then set[#set + 1] = tool.name .. " " .. effort end
  end
  if #set > 0 then
    lines[#lines + 1] = "Effort: " .. table.concat(set, ", ") .. "; the agent's default for the rest."
    lines[#lines + 1] = ""
  end
  -- Each tool over every task: what a comparison reads first.
  lines[#lines + 1] = "## all tasks"
  lines[#lines + 1] = ""
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
    local left = if unfit > 0 then " (" .. tostring(unfit) .. " unfit on this fixture, left out)" else "" end
    lines[#lines + 1] = string.format("- %s: %d of %d passed%s; $%.4f, %.0f cache read, %.0f cache write, " ..
        "%.0f out a run; $%.3f in all", tool.name, passed, n, left, cost / d, read / d, write / d, output / d, cost)
  end
  lines[#lines + 1] = ""
  for _, task in ipairs(options.tasks) do
    lines[#lines + 1] = "## " .. task.name
    lines[#lines + 1] = ""
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
      local wall = (sum["wall"] or 0) / math.max(n, 1)
      local grade = tostring(passed) .. " of " .. tostring(n) .. " passed"
      if unfit > 0 then grade = "unfit on this fixture" end
      lines[#lines + 1] = string.format("- %s: %s; %.1f requests, $%.3f, %.0f s wall (%.0f s in requests); " ..
          "tokens %.0f in, %.0f out, %.0f cache read (%.0f by the first request), %.0f cache write; %.1f tool calls, " ..
          "%.1f of them run, %.1f refused", tool.name, grade, mean("requests"), mean("cost"),
        wall, mean("seconds"), mean("input"), mean("output"), mean("cache_read"), mean("first_read"),
        mean("cache_write"), mean("tools"), mean("runs"), mean("refused"))
      local named: mut {string} = {}
      for code in pairs(codes) do named[#named + 1] = code end
      table.sort(named, function(a: string, b: string): boolean
        local ka, kb = codes[a] or 0, codes[b] or 0
        if ka ~= kb then return ka > kb end
        return a < b
      end)
      if #named > 0 then
        local parts: mut {string} = {}
        for _, code in ipairs(named) do
          parts[#parts + 1] = code .. " " .. tostring(codes[code] or 0)
        end
        lines[#lines + 1] = "  - refused for: " .. table.concat(parts, ", ")
      end
      local used: mut {string} = {}
      for name in pairs(helpers) do used[#used + 1] = name end
      table.sort(used, function(a: string, b: string): boolean
        local ka, kb = helpers[a] or 0, helpers[b] or 0
        if ka ~= kb then return ka > kb end
        return a < b
      end)
      if #used > 0 then
        local parts: mut {string} = {}
        for _, name in ipairs(used) do
          parts[#parts + 1] = string.format("%s %.1f", name, (helpers[name] or 0) / d)
        end
        lines[#lines + 1] = "  - snippets naming each Host helper: " .. table.concat(parts, ", ")
      end
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
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
  local function spent(tool: string, marker: string): Agent.Spent?
    local db, _ = Sqlite.open(out .. "/" .. tool .. "/data/cosmic/agent/sessions.db")
    if db == nil then return nil end
    local s = Agent.spent_in(db, marker)
    local _, _ = db:close()
    return s
  end
  local function put(path: string, text: string)
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
  return { run = run, fresh = fresh, spent = spent, put = put, serve = serve }
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
