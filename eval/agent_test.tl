--- [`eval/agent.tl`] with a fake System: the command line, the runs it makes, how each is graded, what a session
--- spent, and the report. No agent is started.
local Agent = require("eval.agent")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

Test.policy{}

local function options(list: {string}): Agent.Options
  local parsed, why = Agent.parse(list)
  return (assert(parsed, why))
end

local function test_the_command_line_names_tools_a_fixture_and_tasks()
  local o = options({ "--tool", "old=/a/cosmic", "--tool", "new=/b/cosmic", "--fixture", "/f", "--out", "/o" })
  assert(#o.tools == 2 and o.tools[2].name == "new" and o.tools[2].path == "/b/cosmic")
  assert(o.reps == 2 and o.model == "sonnet" and o.timeout == 1200 and #o.tasks == #Agent.tasks)
  local some = options({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "todos,rename",
    "--reps", "3", "--model", "opus" })
  assert(#some.tasks == 2 and some.tasks[2].name == "rename" and some.reps == 3 and some.model == "opus")
  local offered = options({ "--tool", "a=/c", "--tool", "b=/c", "--offer", "b=run,read", "--fixture", "/f", "--out", "/o" })
  assert(assert(offered.tools[1]).tools == nil and assert(offered.tools[2]).tools == "run,read")
  assert(Agent.parse({ "--offer", "a=run", "--tool", "a=/c", "--fixture", "/f", "--out", "/o" }) == nil)
  local efforts = options({ "--tool", "a=/c", "--tool", "b=/c", "--tool", "c=/c", "--effort", "b=low", "--effort",
    "high", "--fixture", "/f", "--out", "/o" })
  assert(assert(efforts.tools[1]).effort == "high" and assert(efforts.tools[2]).effort == "low" and
      assert(efforts.tools[3]).effort == "high")
  assert(assert(options({ "--tool", "a=/c", "--fixture", "/f", "--out", "/o" }).tools[1]).effort == nil)
  assert(Agent.parse({ "--tool", "a=/c", "--effort", "a=hard", "--fixture", "/f", "--out", "/o" }) == nil)
  assert(Agent.parse({ "--effort", "a=low", "--tool", "a=/c", "--fixture", "/f", "--out", "/o" }) == nil)
  for _, bad in ipairs({ { "--fixture", "/f", "--out", "/o" }, { "--tool", "t=/c", "--out", "/o" },
      { "--tool", "t", "--fixture", "/f", "--out", "/o" }, { "--tool", "t=/c", "--tool", "t=/d", "--fixture", "/f",
          "--out", "/o" }, { "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "nope" },
      { "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--reps", "0" }, { "--tool" } }) do
    assert(Agent.parse(bad) == nil, table.concat(bad, " "))
  end
end

local function test_grading_ignores_trailing_blanks_and_blank_lines_at_the_end()
  assert(Agent.lines_of("a  \nb\t\n\n\n") == "a\nb")
  assert(Agent.lines_of("") == "")
end

--- Each tool's runs get a fresh copy, its own data directory and home, the key; each is graded against the truth
--- of an untouched copy, and a task whose truth is empty is unfit.
local function test_runs_are_graded_against_the_truth_of_an_untouched_copy()
  local o = options({ "--tool", "good=/g", "--tool", "bad=/b", "--fixture", "/f", "--out", "/o",
    "--tasks", "todos,rename", "--reps", "1", "--effort", "bad=low" })
  local asked: mut {string} = {}
  local made = 0
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      return "/tmp/" .. prefix .. tostring(made)
    end,
    run = function(argv: {string}, cwd: string, env: {string: string}?, _: integer): Agent.Output
      local first, script = argv[1] or "", argv[3] or ""
      if first == "bash" then
        if script:find("TODO", 1, true) ~= nil then
          return { code = 0, stdout = "x.tl:1\n", stderr = "" }
        end
        if script:find("MAX_LINES", 1, true) ~= nil then
          return { code = 1, stdout = "", stderr = "" }
        end
        -- A check: the good tool left the truth, the bad one something else.
        if cwd:find("good", 1, true) ~= nil then
          return { code = 0, stdout = "x.tl:1  \n\n", stderr = "" }
        end
        return { code = 0, stdout = "y.tl:2\n", stderr = "" }
      end
      if first == "/g" or first == "/b" then
        local e = assert(env)
        assert(e["ANTHROPIC_API_KEY"] == "k" and e["HARNESS_ANTHROPIC_API_KEY"] == nil)
        assert(e["XDG_DATA_HOME"] == (if first == "/g" then "/o/good/data" else "/o/bad/data" end))
        assert(argv[4] == "--model" and argv[5] == "sonnet")
        if first == "/b" then
          assert(argv[6] == "--effort" and argv[7] == "low")
        else
          assert(argv[6] ~= "--effort")
        end
        asked[#asked + 1] = first .. " " .. cwd
      end
      return { code = 0, stdout = "", stderr = "", seconds = 3 }
    end,
    spent = function(tool: string, marker: string): Agent.Spent?
      if tool == "bad" then return nil end
      assert(marker:find("^bench%-good%-") ~= nil, marker)
      return { requests = 3, input = 10, output = 20, cache_read = 30, cache_write = 40, cost = 0.5, seconds = 2,
        tools = 4, runs = 1, refused = 1, codes = { semicolon = 1 }, first_read = 5,
        helpers = { bash = 1, grep = 2 } }
    end,
    put = function(_: string, _: string) error("no task here has a server") end,
    serve = function(_: {string}, _: string, _: string, _: integer): (string, function()) | (nil, string)
      error("no task here has a site")
    end,
  }
  local written: mut {string: string} = {}
  local results = Agent.execute(o, system, "k", { HARNESS_ANTHROPIC_API_KEY = "k", PATH = "/bin" },
    function(path: string, text: string) written[path] = text end)
  assert(#results == 4 and #asked == 4)
  assert(results[1].tool == "good" and results[1].task == "todos" and results[1].grade == "pass")
  assert(results[2].task == "rename" and results[2].grade == "unfit")
  assert(results[3].tool == "bad" and results[3].grade == "fail" and results[3].spent == nil)
  local answer = assert(written["/o/bad/todos-1.txt"])
  assert(answer:find("grade: fail\n", 1, true) == 1 and answer:find("--- left\ny.tl:2\n--- truth\nx.tl:1\n", 1, true) ~= nil,
    answer)
  local report = Agent.report(o, results)
  local want = table.concat({
    "# cosmic agent evals",
    "",
    "Model sonnet; runs of each task with each tool: 1; fixture /f. Each number is the mean of a run.",
    "",
    "Effort: bad low; the agent's default for the rest.",
    "",
    "## all tasks",
    "",
    "- good: 1 of 1 passed (1 unfit on this fixture, left out); $0.5000, 30 cache read, 40 cache write, 20 out a run; $0.500 in all",
    "- bad: 0 of 1 passed (1 unfit on this fixture, left out); $0.0000, 0 cache read, 0 cache write, 0 out a run; $0.000 in all",
    "",
    "## todos",
    "",
    "- good: 1 of 1 passed; 3.0 requests, $0.500, 3 s wall (2 s in requests); tokens 10 in, 20 out, 30 cache read (5 by the first request), 40 cache write; 4.0 tool calls, 1.0 of them run, 1.0 refused",
    "  - refused for: semicolon 1",
    "  - snippets naming each Host helper: grep 2.0, bash 1.0",
    "- bad: 0 of 1 passed; 0.0 requests, $0.000, 3 s wall (0 s in requests); tokens 0 in, 0 out, 0 cache read (0 by the first request), 0 cache write; 0.0 tool calls, 0.0 of them run, 0.0 refused",
    "",
    "## rename",
    "",
    "- good: unfit on this fixture; 3.0 requests, $0.500, 3 s wall (2 s in requests); tokens 10 in, 20 out, 30 cache read (5 by the first request), 40 cache write; 4.0 tool calls, 1.0 of them run, 1.0 refused",
    "  - refused for: semicolon 1",
    "  - snippets naming each Host helper: grep 2.0, bash 1.0",
    "- bad: unfit on this fixture; 0.0 requests, $0.000, 3 s wall (0 s in requests); tokens 0 in, 0 out, 0 cache read (0 by the first request), 0 cache write; 0.0 tool calls, 0.0 of them run, 0.0 refused",
    "",
  }, "\n")
  assert(report == want, report)
  assert(report:find("## todos\n\n- good: 1 of 1 passed; 3.0 requests, $0.500, 3 s wall (2 s in requests)", 1, true) ~= nil, report)
  assert(report:find("30 cache read (5 by the first request)", 1, true) ~= nil and
      report:find("1.0 of them run, 1.0 refused\n  - refused for: semicolon 1\n" ..
          "  - snippets naming each Host helper: grep 2.0, bash 1.0\n", 1, true) ~= nil, report)
  assert(report:find("- bad: 0 of 1 passed", 1, true) ~= nil, report)
  assert(report:find("- good: unfit on this fixture", 1, true) ~= nil, report)
  assert(report:find("Effort: bad low; the agent's default for the rest.", 1, true) ~= nil, report)
  assert(report:find("## all tasks\n\n- good: 1 of 1 passed (1 unfit on this fixture, left out); $0.5000, 30 cache read, " ..
      "40 cache write, 20 out a run; $0.500 in all\n- bad: 0 of 1 passed (1 unfit on this fixture, left out); $0.0000", 1, true) ~= nil, report)
end

--- What a run spent is its session's, the newest whose directory's name holds the run's marker.
local function test_what_a_run_spent_is_read_from_its_session()
  local db = assert(Sqlite.memory())
  assert(db:exec([[
CREATE TABLE sessions (id INTEGER PRIMARY KEY, cwd TEXT);
CREATE TABLE requests (session INTEGER, input_tokens INTEGER, output_tokens INTEGER, cache_read INTEGER,
  cache_write_5m INTEGER, cache_write_1h INTEGER, cost REAL, ms INTEGER, status INTEGER);
CREATE TABLE outputs (session INTEGER, tool TEXT, input TEXT, text TEXT);
INSERT INTO sessions VALUES (1, '/tmp/bench-a-todos-1'), (2, '/tmp/bench-a-todos-2');
INSERT INTO requests VALUES (2, NULL, NULL, NULL, NULL, NULL, NULL, 0, 529),
  (2, 10, 1, 100, 5, NULL, 0.25, 1500, 200), (2, 20, 2, 200, NULL, 7, 0.5, 500, 200),
  (1, 999, 999, 999, 999, 999, 9.0, 9, 200);
INSERT INTO outputs VALUES (2, 'run', '{}', 'The checker refused the snippet, so it did not run:
-e:1: x (view_written): y
-e:2: z (view_written): w
-e:3: q (semicolon): r'), (2, 'bash', '', ''), (2, 'run', '{"code":"Host.bash(\\"ls\\")"}', 'ok'),
  (2, 'run', '{"code":"Host.grep(\"a\", Host.find(\".\")) Host.grep(\"b\", {}) local c: {Host.Count} = MyHost.top()\nHost.write(\"x\", \"\")"}', 'ok'), (1, 'read', '', '');
]]))
  local s = assert(Agent.spent_in(db, "bench-a-todos-2"))
  assert(s.requests == 3 and s.input == 30 and s.output == 3 and s.cache_read == 300 and s.cache_write == 12)
  assert(s.cost == 0.75 and s.seconds == 2 and s.tools == 4 and s.runs == 3)
  assert(s.helpers["bash"] == 1 and s.helpers["grep"] == 1 and s.helpers["find"] == 1 and s.helpers["write"] == 1)
  assert(s.helpers["Count"] == nil and s.helpers["top"] == nil)
  assert(s.refused == 1 and s.codes["view_written"] == 1 and s.codes["semicolon"] == 1 and s.first_read == 100)
  assert(Agent.spent_in(db, "bench-b-") == nil)
  assert(db:close())
end

--- A task of an MCP server lays the server out for each run, beside a config the run is given with --mcp, and its
--- truth reads the server's data from `$data`.
local function test_a_task_of_a_server_gives_each_run_the_server()
  local o = options({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "mcp-low", "--reps", "2" })
  local task = assert(o.tasks[1])
  local servers = assert(task.servers)
  local server = assert(servers[1])
  assert(#servers == 1)
  assert(server.name == "inventory" and server.source:find("serve_stdio", 1, true) ~= nil)
  local _, items = server.data:gsub("\n", "")
  local listed: Agent.Task? = nil
  for _, t in ipairs(Agent.tasks) do
    if t.name == "mcp-low" then listed = t end
  end
  assert(items == 240 and server.data == assert(assert(assert(listed).servers)[1]).data)
  local made = 0
  local put: mut {string: string} = {}
  local truths, configs, opened = 0, 0, 0
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      return "/tmp/" .. prefix .. tostring(made)
    end,
    run = function(argv: {string}, _: string, _: {string: string}?, _: integer): Agent.Output
      if argv[1] == "bash" and (argv[3] or ""):find("^data='/tmp/data%-mcp%-low%-%d+/data%.tsv'; awk") ~= nil then
        truths = truths + 1
        return { code = 0, stdout = "i0001 0\n", stderr = "" }
      end
      if argv[1] == "chmod" then
        assert(argv[2] == "-R" and argv[3] == "a+rX" and (argv[4] or ""):find("^/tmp/mcp%-t%-mcp%-low%-") ~= nil)
        opened = opened + 1
      end
      if argv[1] == "/c" then
        assert(argv[6] == "--mcp" and argv[8] == task.prompt, table.concat(argv, " "))
        local path = assert(argv[7])
        local config = assert(put[path], path)
        local dir = path:gsub("/mcp%.json$", "") .. "/inventory"
        assert(config:find('"command":["/c","--standalone","' .. dir .. "/server.tl", 1, true) ~= nil, config)
        assert(config:find('"grants":[{"letters":"r","path":"' .. dir .. '"}]', 1, true) ~= nil, config)
        assert(put[dir .. "/data.tsv"] == server.data)
        configs = configs + 1
      end
      return { code = 0, stdout = "", stderr = "" }
    end,
    spent = function(_: string, _: string): Agent.Spent? return nil end,
    put = function(path: string, text: string) put[path] = text end,
    serve = function(_: {string}, _: string, _: string, _: integer): (string, function()) | (nil, string)
      error("no task here has a site")
    end,
  }
  local results = Agent.execute(o, system, "k", {}, function(_: string, _: string) end)
  assert(#results == 2 and truths == 1 and configs == 2 and opened == 2)
  local laid = 0
  for path, text in pairs(put) do
    if path:find("/server%.tl$") ~= nil then
      assert(text == server.source)
      laid = laid + 1
    end
  end
  assert(laid == 2)
end

--- A task of many servers gives each run one config of them all, each in a directory of its own and said what it
--- is for, and its truth reads the first one's data.
local function test_a_task_of_many_servers_gives_each_run_them_all()
  local o = options({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "mcp-many-low" })
  local task = assert(o.tasks[1])
  local servers = assert(task.servers)
  assert(#servers == 8 and assert(servers[1]).name == "warehouse" and task.prompt:find("warehouse", 1, true) ~= nil)
  local put: mut {string: string} = {}
  local truth_data: string? = nil
  local config: string? = nil
  local made = 0
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      return "/tmp/" .. prefix .. tostring(made)
    end,
    run = function(argv: {string}, _: string, _: {string: string}?, _: integer): Agent.Output
      if argv[1] == "bash" and truth_data == nil then
        local path = assert((argv[3] or ""):match("^data='([^']+)'"))
        truth_data = put[path]
      end
      if argv[1] == "/c" then config = put[assert(argv[7])] end
      return { code = 0, stdout = "x\n", stderr = "" }
    end,
    spent = function(_: string, _: string): Agent.Spent? return nil end,
    put = function(path: string, text: string) put[path] = text end,
    serve = function(_: {string}, _: string, _: string, _: integer): (string, function()) | (nil, string)
      error("no task here has a site")
    end,
  }
  local _ = Agent.execute(o, system, "k", {}, function(_: string, _: string) end)
  assert(truth_data == assert(servers[1]).data)
  local decoded = assert(Json.decode_object(assert(config)))
  local listed = assert(Json.object_of(decoded["servers"]))
  local names: mut {string} = {}
  for name in pairs(listed) do names[#names + 1] = name end
  table.sort(names)
  assert(table.concat(names, ",") == "billing,calendar,catalog,crm,docs,metrics,tickets,warehouse",
    table.concat(names, ","))
  for _, server in ipairs(servers) do
    local entry = assert(Json.object_of(listed[server.name]))
    assert(entry["description"] == server.about and server.about ~= nil, server.name)
    local found = 0
    for path, text in pairs(put) do
      if path:find("/" .. server.name .. "/data%.tsv$") ~= nil and text == server.data then
        found = found + 1
      end
    end
    assert(found == o.reps, server.name .. ": laid out " .. tostring(found) .. " times")
  end
end

--- web-csv's sales hold customers whose names a split on commas would cut, and its site quotes them.
local function test_web_csvs_sales_need_a_csv_reader()
  local o = options({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "web-csv" })
  local site = assert(assert(o.tasks[1]).site)
  assert(site.data:find("Acme, Inc.", 1, true) ~= nil and site.source:find("sales.csv", 1, true) ~= nil)
  assert(site.source:find("gsub('\"', '\"\"')", 1, true) ~= nil)
end

--- A task of a web API starts its program for each run, gives the run --connect to the port it said, puts its URL
--- in the prompt, and ends it once the run ends; its truth reads the API's data from `$data`.
local function test_a_task_of_a_site_gives_each_run_the_site()
  local o = options({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "web-low", "--reps", "2" })
  local task = assert(o.tasks[1])
  local site = assert(task.site)
  assert(site.source:find("Server.serve", 1, true) ~= nil and task.prompt:find("{url}", 1, true) ~= nil)
  local made = 0
  local put: mut {string: string} = {}
  local truths, asked, started, stopped = 0, 0, 0, 0
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      return "/tmp/" .. prefix .. tostring(made)
    end,
    run = function(argv: {string}, _: string, _: {string: string}?, _: integer): Agent.Output
      if argv[1] == "bash" and (argv[3] or ""):find("^data='/tmp/data%-web%-low%-%d+/data%.tsv'; awk") ~= nil then
        truths = truths + 1
        return { code = 0, stdout = "i0001 0\n", stderr = "" }
      end
      if argv[1] == "/c" then
        assert(started == stopped + 1, "the site serves while the run asks")
        assert(argv[6] == "--connect" and argv[7] == "127.0.0.1:" .. tostring(40000 + started),
          table.concat(argv, " "))
        local prompt = assert(argv[8])
        assert(prompt:find("at http://127.0.0.1:" .. tostring(40000 + started) .. " answers", 1, true) ~= nil, prompt)
        asked = asked + 1
      end
      return { code = 0, stdout = "", stderr = "" }
    end,
    spent = function(_: string, _: string): Agent.Spent? return nil end,
    put = function(path: string, text: string) put[path] = text end,
    serve = function(argv: {string}, cwd: string, ready: string, _: integer): (string, function()) | (nil, string)
      assert(argv[1] == "/c" and argv[2] == "--standalone" and argv[3] == cwd .. "/site.tl", table.concat(argv, " "))
      assert(argv[4] == cwd .. "/data.tsv" and argv[5] == ready and ready == cwd .. "/port")
      assert(put[cwd .. "/site.tl"] == site.source and put[cwd .. "/data.tsv"] == site.data)
      started = started + 1
      return tostring(40000 + started), function() stopped = stopped + 1 end
    end,
  }
  local results = Agent.execute(o, system, "k", {}, function(_: string, _: string) end)
  assert(#results == 2 and truths == 1 and asked == 2 and started == 2 and stopped == 2)
end

--- A task with a follow-up asks it once the first ask ends well, with the same flags in place of the first
--- prompt, and the run's words, stderr and wall time join both; a first ask that fails is not followed up.
local function test_a_task_with_a_follow_up_asks_twice_in_one_run()
  local o = options({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "earlier-log", "--reps", "2" })
  local task = assert(o.tasks[1])
  local follow_up = assert(task.follow_up)
  local made = 0
  local asks: mut {{string}} = {}
  local written: mut {string: string} = {}
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      return "/tmp/" .. prefix .. tostring(made)
    end,
    run = function(argv: {string}, _: string, _: {string: string}?, _: integer): Agent.Output
      if argv[1] == "/c" then
        asks[#asks + 1] = argv
        -- The second run's first ask fails.
        if #asks == 3 then return { code = 1, stdout = "", stderr = "broke", seconds = 1 } end
        return { code = 0, stdout = "said " .. tostring(#asks), stderr = "err " .. tostring(#asks),
          seconds = #asks + 1 }
      end
      return { code = 0, stdout = "", stderr = "" }
    end,
    spent = function(_: string, _: string): Agent.Spent? return nil end,
    put = function(_: string, _: string) end,
    serve = function(_: {string}, _: string, _: string, _: integer): (string, function()) | (nil, string)
      return "40001", function() end
    end,
  }
  local results = Agent.execute(o, system, "k", {}, function(path: string, text: string)
    written[path] = text
  end)
  assert(#results == 2 and #asks == 3, tostring(#asks))
  local first, second = assert(asks[1]), assert(asks[2])
  assert(#second == #first, table.concat(second, " "))
  for i = 1, #first - 1 do assert(second[i] == first[i], table.concat(second, " ")) end
  assert((first[#first] or ""):find("http://127.0.0.1:40001", 1, true) ~= nil and second[#second] == follow_up)
  assert(results[1].wall == 5 and results[2].wall == 1, tostring(results[1].wall))
  local answer = assert(written["/o/t/earlier-log-1.txt"])
  assert(answer:find("--- words\nsaid 1\n--- follow-up\nsaid 2\n", 1, true) ~= nil and
      answer:find("--- stderr\nerr 1\n--- follow-up\nerr 2\n", 1, true) ~= nil, answer)
  local failed = assert(written["/o/t/earlier-log-2.txt"])
  assert(failed:find("exit: 1\n", 1, true) ~= nil and failed:find("follow-up", 1, true) == nil, failed)
end

--- A web API that does not start fails the run that needed it, which never asks the agent, and the rest go on.
local function test_a_site_that_does_not_start_fails_its_run()
  local o = options({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "web-low", "--reps", "2" })
  local made, asked, served = 0, 0, 0
  local written: mut {string: string} = {}
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      return "/tmp/" .. prefix .. tostring(made)
    end,
    run = function(argv: {string}, _: string, _: {string: string}?, _: integer): Agent.Output
      if argv[1] == "/c" then asked = asked + 1 end
      -- The truth has a line; the check finds no answer.txt.
      if argv[1] == "bash" and (argv[3] or ""):find("^data=") ~= nil then
        return { code = 0, stdout = "i0001 0\n", stderr = "" }
      end
      return { code = 0, stdout = "", stderr = "" }
    end,
    spent = function(_: string, _: string): Agent.Spent? return nil end,
    put = function(_: string, _: string) end,
    serve = function(_: {string}, _: string, _: string, _: integer): (string, function()) | (nil, string)
      served = served + 1
      return nil, "it ended before it served"
    end,
  }
  local results = Agent.execute(o, system, "k", {}, function(path: string, text: string)
    written[path] = text
  end)
  assert(#results == 2 and served == 2 and asked == 0)
  assert(results[1].grade == "fail" and results[2].grade == "fail")
  local answer = assert(written["/o/t/web-low-1.txt"])
  assert(answer:find("exit: 127\n", 1, true) ~= nil and
      answer:find("--- stderr\nthe web API did not start: it ended before it served\n", 1, true) ~= nil, answer)
end
