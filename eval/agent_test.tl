--- [`agent.tl`] with a fake System: the command line, the runs it makes, how each is graded, what a session
--- spent, and the report. No agent is started.
local Agent = require("agent")
local AgentMcp = require("cosmic.agent.mcp")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

Test.policy{}

--- `list` parsed, with `--testdata` given where it is not, as eval/agent gives it.
local function options(list: {string}): Agent.Options
  local given: mut {string} = {}
  local has = false
  for _, word in ipairs(list) do
    given[#given + 1] = word
    if word == "--testdata" then has = true end
  end
  if not has then
    given[#given + 1] = "--testdata"
    given[#given + 1] = "/td"
  end
  local parsed, why = Agent.parse(given)
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
  assert(assert(options({ "--tool", "a=cosmic", "--fixture", "/f", "--out", "/o" }).tools[1]).path == "cosmic")
  assert(Agent.parse({ "--tool", "a=/c", "--effort", "a=hard", "--fixture", "/f", "--out", "/o" }) == nil)
  assert(Agent.parse({ "--effort", "a=low", "--tool", "a=/c", "--fixture", "/f", "--out", "/o" }) == nil)
  for _, bad in ipairs({ { "--fixture", "/f", "--out", "/o" }, { "--tool", "t=/c", "--out", "/o" },
      { "--tool", "t", "--fixture", "/f", "--out", "/o" }, { "--tool", "t=/c", "--tool", "t=/d", "--fixture", "/f",
          "--out", "/o" }, { "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "nope" },
      { "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--reps", "0" }, { "--tool" },
      { "--tool", "t=bin/cosmic", "--fixture", "/f", "--out", "/o" }, { "--tool", "t=/c", "--fixture", "f", "--out", "/o" },
      { "--tool", "t=/c", "--fixture", "/f", "--out", "evals/x" } }) do
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
  local left: mut {string: boolean} = {}
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      local dir = "/tmp/" .. prefix .. tostring(made)
      left[dir] = true
      return dir
    end,
    discard = function(dir: string)
      assert(left[dir] == true, dir)
      left[dir] = nil
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
        causes = { ["prompt: a Lua habit the parser refuses"] = 1 }, layers = { prompt = 1 }, guesses = { ["Json.string_of (field_unknown)"] = 1 },
        resends = 1, sorts = 2, helpers = { bash = 1, grep = 2 } }
    end,
    put = function(_: string, _: string) error("no task here has a server") end,
    serve = function(_: {string}, _: string, _: string, _: integer): (string, function()) | (nil, string)
      error("no task here has a site")
    end,
  }
  local written: mut {string: string} = {}
  local results = Agent.execute(o, system, "k", { HARNESS_ANTHROPIC_API_KEY = "k", PATH = "/bin" },
    function(path: string, text: string) written[path] = text end)
  assert(next(left) == nil, "a directory the evals made is left: " .. tostring((next(left))))
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
    "  - snippets sent again to the letter: 1.0 a run",
    "  - snippets that sort: 2.0 a run",
    "- bad: 0 of 1 passed; 0.0 requests, $0.000, 3 s wall (0 s in requests); tokens 0 in, 0 out, 0 cache read (0 by the first request), 0 cache write; 0.0 tool calls, 0.0 of them run, 0.0 refused",
    "",
    "## rename",
    "",
    "- good: unfit on this fixture; 3.0 requests, $0.500, 3 s wall (2 s in requests); tokens 10 in, 20 out, 30 cache read (5 by the first request), 40 cache write; 4.0 tool calls, 1.0 of them run, 1.0 refused",
    "  - refused for: semicolon 1",
    "  - snippets naming each Host helper: grep 2.0, bash 1.0",
    "  - snippets sent again to the letter: 1.0 a run",
    "  - snippets that sort: 2.0 a run",
    "- bad: unfit on this fixture; 0.0 requests, $0.000, 3 s wall (0 s in requests); tokens 0 in, 0 out, 0 cache read (0 by the first request), 0 cache write; 0.0 tool calls, 0.0 of them run, 0.0 refused",
    "",
    "## refusals by root cause",
    "",
    "Each refused snippet counts once for each cause. The layer says what change removes it: lang (a rule of the " ..
      "language or checker), stdlib (a name or shape the library lacks) or prompt (only the run text's wording). " ..
      "eval/causes.tl holds the rules.",
    "",
    "- good: 2 refused snippets in 2 runs; by layer: prompt 2",
    "  - prompt: a Lua habit the parser refuses: 2 (2 tasks: rename 1, todos 1)",
    "",
    "## names the model guessed that do not exist",
    "",
    "Each name counts the runs that tried it. A name that recurs is a candidate for an alias, a function or a better hint.",
    "",
    "- good",
    "  - Json.string_of (field_unknown): 2 (rename 1, todos 1)",
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
--- A report with no effort set, no unfit run and no task is the totals alone.
local function test_a_report_of_no_task_is_its_totals()
  local o: Agent.Options = { tools = { { name = "a", path = "/a" } }, fixture = "/f", out = "/o", tasks = {}, reps = 1,
    model = "m", timeout = 1 }
  local spent: Agent.Spent = { requests = 1, input = 1, output = 2, cache_read = 3, cache_write = 4, cost = 0.25,
    seconds = 1, tools = 0, runs = 0, refused = 0, codes = {}, causes = {}, layers = {}, guesses = {}, resends = 0, sorts = 0, first_read = 0, helpers = {} }
  local report = Agent.report(o, { { tool = "a", task = "todos", rep = 1, grade = "pass", spent = spent, wall = 1 } })
  assert(report == "# cosmic agent evals\n\nModel m; runs of each task with each tool: 1; fixture /f. Each number is " ..
      "the mean of a run.\n\n## all tasks\n\n- a: 1 of 1 passed; $0.2500, 3 cache read, 4 cache write, 2 out a run; " ..
      "$0.250 in all\n", report)
end

--- `--control` names a tool given before it; the report puts each other tool against the controls' spread, and
--- shows the tuned tasks apart from the held-out ones.
local function test_a_report_puts_a_tool_against_its_controls_and_the_held_out_tasks_apart()
  assert(Agent.parse({ "--control", "a", "--tool", "a=/c", "--fixture", "/f", "--out", "/o" }) == nil)
  local controlled = assert(options({ "--tool", "a=/c", "--tool", "b=/c", "--control", "a", "--fixture", "/f", "--out", "/o" }).controls)
  assert(controlled[1] == "a")
  local tune: Agent.Task = { name = "tune", prompt = "p", truth = "t", check = "c" }
  local held: Agent.Task = { name = "held", prompt = "p", truth = "t", check = "c", held = true }
  local o: Agent.Options = { tools = { { name = "c1", path = "/a" }, { name = "c2", path = "/a" }, { name = "v", path = "/b" } },
    fixture = "/f", out = "/o", tasks = { tune, held }, reps = 1, model = "m", timeout = 1, controls = { "c1", "c2" } }
  local function spent(cost: number, refused: integer): Agent.Spent
    return { requests = 1, input = 1, output = 2, cache_read = 3, cache_write = 4, cost = cost, seconds = 1, tools = 0,
      runs = 0, refused = refused, codes = {}, causes = {}, layers = {}, guesses = {}, resends = 0, sorts = 0,
      first_read = 0, helpers = {} }
  end
  local results: mut {Agent.Result} = {}
  local rows = { { tool = "c1", cost = 0.10, refused = 1 }, { tool = "c2", cost = 0.11, refused = 2 },
    { tool = "v", cost = 0.20, refused = 4 } }
  for _, row in ipairs(rows) do
    for _, task in ipairs({ "tune", "held" }) do
      local grade = if row.tool == "v" and task == "held" then "fail" else "pass" end
      results[#results + 1] = { tool = row.tool, task = task, rep = 1, grade = grade,
        spent = spent(row.cost, row.refused), wall = 1 }
    end
  end
  local report = Agent.report(o, results)
  assert(report:find("- v, held out: 0 of 1 passed; $0.2000, 4.00 refused a run\n", 1, true) ~= nil, report)
  assert(report:find("- c1, tuned: 1 of 1 passed;", 1, true) ~= nil, report)
  assert(report:find("  - cost $0.2000 a run; controls $0.1000 to $0.1100: above the controls\n", 1, true) ~= nil, report)
  assert(report:find("  - passed 50.0%; controls 100.0% to 100.0%: below the controls\n", 1, true) ~= nil, report)
  -- One control has no spread to be inside of.
  local one: Agent.Options = { tools = o.tools, fixture = "/f", out = "/o", tasks = { tune, held }, reps = 1, model = "m",
    timeout = 1, controls = { "c1" } }
  assert(Agent.report(one, results):find("one control, no spread", 1, true) ~= nil)
  -- With no held-out task there is no set section, and with no control no band.
  local plain_options: Agent.Options = { tools = o.tools, fixture = "/f", out = "/o", tasks = { tune }, reps = 1,
    model = "m", timeout = 1 }
  local plain = Agent.report(plain_options, results)
  assert(plain:find("held out", 1, true) == nil and plain:find("against the controls", 1, true) == nil, plain)
end

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
local function test_a_task_of_a_server_gives_each_run_the_server(tmp: string)
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
  local left: mut {string: boolean} = {}
  local put: mut {string: string} = {}
  local truths, configs, opened = 0, 0, 0
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      local dir = "/tmp/" .. prefix .. tostring(made)
      left[dir] = true
      return dir
    end,
    discard = function(dir: string)
      assert(left[dir] == true, dir)
      left[dir] = nil
    end,
    run = function(argv: {string}, _: string, _: {string: string}?, _: integer): Agent.Output
      if argv[1] == "bash" and (argv[3] or ""):find("^data='/tmp/data%-mcp%-low%-%d+/data%.tsv'; tool='/c'; files='/td/files/mcp%-low'; awk") ~= nil then
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
  assert(next(left) == nil, "a directory the evals made is left: " .. tostring((next(left))))
  assert(#results == 2 and truths == 1 and configs == 2 and opened == 2)
  local laid = 0
  for path, text in pairs(put) do
    if path:find("/server%.tl$") ~= nil then
      assert(text == server.source)
      laid = laid + 1
    end
  end
  assert(laid == 2)
  -- The config is one the agent itself takes: a policy it refuses (a profile this build lacks) ends a run at once.
  for path, text in pairs(put) do
    if path:find("/mcp%.json$") ~= nil then
      assert(Fs.write(tmp .. "/mcp.json", text))
      local loaded, why = AgentMcp.load(tmp .. "/mcp.json")
      assert(loaded ~= nil and #loaded == 1 and assert(loaded[1]).name == "inventory", tostring(why))
    end
  end
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
  local left: mut {string: boolean} = {}
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      local dir = "/tmp/" .. prefix .. tostring(made)
      left[dir] = true
      return dir
    end,
    discard = function(dir: string)
      assert(left[dir] == true, dir)
      left[dir] = nil
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
  assert(next(left) == nil, "a directory the evals made is left: " .. tostring((next(left))))
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
  local left: mut {string: boolean} = {}
  local put: mut {string: string} = {}
  local truths, asked, started, stopped = 0, 0, 0, 0
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      local dir = "/tmp/" .. prefix .. tostring(made)
      left[dir] = true
      return dir
    end,
    discard = function(dir: string)
      assert(left[dir] == true, dir)
      left[dir] = nil
    end,
    run = function(argv: {string}, _: string, _: {string: string}?, _: integer): Agent.Output
      if argv[1] == "bash" and (argv[3] or ""):find("^data='/tmp/data%-web%-low%-%d+/data%.tsv'; tool='/c'; files='/td/files/web%-low'; awk") ~= nil then
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
  assert(next(left) == nil, "a directory the evals made is left: " .. tostring((next(left))))
  assert(#results == 2 and truths == 1 and asked == 2 and started == 2 and stopped == 2)
end

--- A task with a follow-up asks it once the first ask ends well, with the same flags in place of the first
--- prompt, and the run's words, stderr and wall time join both; a first ask that fails is not followed up.
local function test_a_task_with_a_follow_up_asks_twice_in_one_run()
  local o = options({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "earlier-log", "--reps", "2" })
  local task = assert(o.tasks[1])
  local follow_up = assert(task.follow_up)
  local made = 0
  local left: mut {string: boolean} = {}
  local asks: mut {{string}} = {}
  local written: mut {string: string} = {}
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      local dir = "/tmp/" .. prefix .. tostring(made)
      left[dir] = true
      return dir
    end,
    discard = function(dir: string)
      assert(left[dir] == true, dir)
      left[dir] = nil
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
  assert(next(left) == nil, "a directory the evals made is left: " .. tostring((next(left))))
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
  local left: mut {string: boolean} = {}
  local written: mut {string: string} = {}
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      local dir = "/tmp/" .. prefix .. tostring(made)
      left[dir] = true
      return dir
    end,
    discard = function(dir: string)
      assert(left[dir] == true, dir)
      left[dir] = nil
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
  assert(next(left) == nil, "a directory the evals made is left: " .. tostring((next(left))))
  assert(#results == 2 and served == 2 and asked == 0)
  -- It ended before the agent was asked: the setup failed, and the model was not tried.
  assert(results[1].grade == "broken" and results[2].grade == "broken")
  assert(results[1].why == "the web API did not start: it ended before it served" and results[2].stopped == nil)
  local answer = assert(written["/o/t/web-low-1.txt"])
  assert(answer:find("exit: 127\n", 1, true) ~= nil and
      answer:find("--- stderr\nthe web API did not start: it ended before it served\n", 1, true) ~= nil, answer)
end

--- A step that raises ends the evals, and still no directory they made is left: the copies of a run whose
--- server could not be laid out, and the truths before it.
local function test_a_step_that_raises_leaves_no_directory()
  local o = options({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "todos,mcp-low", "--reps", "1" })
  local made = 0
  local left: mut {string: boolean} = {}
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      local dir = "/tmp/" .. prefix .. tostring(made)
      left[dir] = true
      return dir
    end,
    discard = function(dir: string)
      assert(left[dir] == true, dir)
      left[dir] = nil
    end,
    run = function(_: {string}, _: string, _: {string: string}?, _: integer): Agent.Output
      return { code = 0, stdout = "x\n", stderr = "" }
    end,
    spent = function(_: string, _: string): Agent.Spent? return nil end,
    put = function(path: string, _: string)
      if path:find("server.tl", 1, true) ~= nil then error("disk full", 0) end
    end,
    serve = function(_: {string}, _: string, _: string, _: integer): (string, function()) | (nil, string)
      error("no task here has a site")
    end,
  }
  local ok, why = pcall(Agent.execute, o, system, "k", {}, function(_: string, _: string) end)
  assert(not ok and tostring(why) == "disk full", tostring(why))
  assert(made > 3 and next(left) == nil, "a directory the evals made is left: " .. tostring((next(left))))
end

--- A refused snippet's text gives each cause once, the names it guessed that do not exist, and the snippets sent
--- again to the letter and the ones that sort come from the run's snippets in order.
local function test_a_runs_refusals_name_their_causes_and_guesses()
  local db = assert(Sqlite.memory())
  assert(db:exec([[
CREATE TABLE sessions (id INTEGER PRIMARY KEY, cwd TEXT);
CREATE TABLE requests (session INTEGER, input_tokens INTEGER, output_tokens INTEGER, cache_read INTEGER,
  cache_write_5m INTEGER, cache_write_1h INTEGER, cost REAL, ms INTEGER, status INTEGER);
CREATE TABLE outputs (session INTEGER, tool TEXT, input TEXT, text TEXT);
INSERT INTO sessions VALUES (1, '/tmp/bench-a-json-1');
INSERT INTO requests VALUES (1, 1, 1, 1, 1, 1, 0.1, 100, 200);
INSERT INTO outputs VALUES
  (1, 'run', '{"code":"local a = Json.string_of(x)"}', 'The checker refused the snippet, so it did not run:
run.tl:2:11: `Json` has no field `string_of` (field_unknown): `Json` has: array, decode
run.tl:3:5: `Json.decode("1")` answers one of 2 lists of values, and `assert` tells none of them apart from the others: it passes one list (alternatives_as_value): bind its values
run.tl:4:1: `Json.get(v)` answers one of 2 lists of values, which is no value (alternatives_as_value): bind them
run.tl: 3 errors in its bodies on line 2; follow the fix above'),
  (1, 'run', '{"code":"local a = Json.string_of(x)"}', 'The checker refused the snippet, so it did not run:
run.tl:1:11: cosmic has no module `cosmic.nothere` (require_unknown): `cosmic docs` lists them
run.tl:2:1: `foo` is not declared (unknown_variable): declare it with `local foo = ...`
run.tl:3:1: `Fs` is not declared (unknown_variable): require its module above this use: `local Fs = require("cosmic.fs")`
run.tl:4:1: odd one (not_in_any_rule): x'),
  (1, 'run', '{"code":"table.sort(t)"}', 'ok'),
  (1, 'run', '{"code":"Host.sort(Host.find(\"a\"))"}', 'ok'),
  (1, 'run', '{"code":"Host.sort_by(x) my_version_sort(y)"}', 'ok');
]]))
  local s = assert(Agent.spent_in(db, "bench-a-json-1"))
  assert(s.refused == 2 and s.resends == 1 and s.sorts == 2, tostring(s.resends))
  assert(s.layers["stdlib"] == 2 and s.layers["lang"] == 1 and s.layers["prompt"] == 1 and s.layers["untagged"] == 1)
  assert(s.causes["lang: `!` on a call whose first value may be false"] == 1, tostring((next(s.causes))))
  assert(s.causes["stdlib: a call that may fail used as a value"] == 1)
  assert(s.causes["stdlib: a function or field the stdlib lacks"] == 1 and s.causes["stdlib: a module the stdlib lacks"] == 1)
  assert(s.causes["prompt: a stdlib module used without `require`"] == 1)
  assert(s.causes["stdlib: a name that is declared nowhere"] == 1)
  assert(s.causes["untagged: other: not_in_any_rule"] == 1)
  -- A name counts once for a run, however often it was tried.
  assert(s.guesses["Json.string_of (field_unknown)"] == 1 and s.guesses["cosmic.nothere (require_unknown)"] == 1)
  assert(s.guesses["foo (unknown_variable)"] == 1 and s.guesses["Fs (unknown_variable)"] == 1)
  assert(s.codes["alternatives_as_value"] == 1 and s.codes["field_unknown"] == 1)
  assert(db:close())
end

--- A run that ends with an error before its first request is the setup's, not the model's: it is graded
--- "broken" with the first line of its error, and where no run before it made a request it ends the round.
local function test_a_run_that_ends_before_its_first_request_is_broken_and_ends_the_round()
  local o = options({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "todos,rename", "--reps", "3" })
  local asked, kept = 0, 0
  local made = 0
  local system: Agent.System = {
    fresh = function(prefix: string): string
      made = made + 1
      return "/tmp/" .. prefix .. tostring(made)
    end,
    discard = function(_: string) end,
    run = function(argv: {string}, _: string, _: {string: string}?, _: integer): Agent.Output
      if argv[1] == "/c" then
        asked = asked + 1
        return { code = 2, stdout = "", stderr = "\nsandbox: $.profiles[0]: there is no profile \"cosmic\"\nmore\n" }
      end
      if argv[1] == "bash" and (argv[3] or ""):find("TODO", 1, true) ~= nil then
        return { code = 0, stdout = "x.tl:1\n", stderr = "" }
      end
      return { code = 0, stdout = "", stderr = "" }
    end,
    spent = function(_: string, _: string): Agent.Spent? return nil end,
    put = function(_: string, _: string) end,
    serve = function(_: {string}, _: string, _: string, _: integer): (string, function()) | (nil, string)
      error("no task here has a site")
    end,
  }
  local written: mut {string: string} = {}
  local results = Agent.execute(o, system, "k", {}, function(path: string, text: string)
    written[path] = text
  end)
  assert(asked == 1 and #results == 1, tostring(asked))
  local first = assert(results[1])
  assert(first.grade == "broken" and first.why == "sandbox: $.profiles[0]: there is no profile \"cosmic\"")
  local stopped = first.stopped or ""
  assert(stopped:find("before its first request (exit 2)", 1, true) ~= nil, stopped)
  assert(assert(written["/o/t/todos-1.txt"]):find("grade: broken\n", 1, true) == 1)
  local report = Agent.report(o, results)
  assert(report:find("- t: 0 of 0 passed (1 broken, left out: the agent ended before its first request);", 1, true) ~= nil, report)
  assert(report:find("- t: 0 of 0 passed, 1 broken;", 1, true) ~= nil, report)
  assert(report:find("  - broken: sandbox: $.profiles[0]: there is no profile \"cosmic\"\n", 1, true) ~= nil, report)
  -- Once a run made its requests, a later run's error is the model's or the run's own: the round goes on.
  asked = 0
  local replied = false
  local again: Agent.System = {
    fresh = system.fresh,
    discard = system.discard,
    run = function(argv: {string}, _: string, _: {string: string}?, _: integer): Agent.Output
      if argv[1] == "/c" then
        asked = asked + 1
        if asked == 1 then
          replied = true
          return { code = 0, stdout = "", stderr = "" }
        end
        return { code = 1, stdout = "", stderr = "timed out" }
      end
      if argv[1] == "bash" and (argv[3] or ""):find("TODO", 1, true) ~= nil then
        return { code = 0, stdout = "x.tl:1\n", stderr = "" }
      end
      return { code = 0, stdout = "", stderr = "" }
    end,
    spent = function(_: string, _: string): Agent.Spent?
      if not replied then return nil end
      return { requests = 1, input = 1, output = 1, cache_read = 0, cache_write = 0, cost = 0.1, seconds = 1, tools = 0,
        runs = 0, refused = 0, codes = {}, causes = {}, layers = {}, guesses = {}, resends = 0, sorts = 0, first_read = 0, helpers = {} }
    end,
    put = system.put,
    serve = system.serve,
  }
  local later = Agent.execute(o, again, "k", {}, function(_: string, _: string) kept = kept + 1 end)
  assert(asked == 6 and #later == 6 and kept == 6, tostring(asked))
  assert(assert(later[1]).grade == "fail" and assert(later[6]).stopped == nil)
end

--- `--no-agents-md` leaves AGENTS.md and CLAUDE.md out of every copy of the fixture, the truth's too, and the
--- report says so; without it, no copy is touched.
local function test_no_agents_md_leaves_the_instructions_out_of_each_copy()
  assert(options({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o" }).without_agents_md == nil)
  local o = options({ "--tool", "t=/c", "--no-agents-md", "--fixture", "/f", "--out", "/o", "--tasks", "todos",
    "--reps", "1" })
  assert(o.without_agents_md == true)
  assert(Agent.parse({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--no-agents-md", "--testdata", "/td" }) ~= nil)
  local removed: mut {string} = {}
  local system: Agent.System = {
    fresh = function(prefix: string): string return "/tmp/" .. prefix .. "1" end,
    discard = function(_: string) end,
    run = function(argv: {string}, _: string, _: {string: string}?, _: integer): Agent.Output
      if argv[1] == "rm" then
        local line = table.concat(argv, " ")
        removed[#removed + 1] = line
      end
      return { code = 0, stdout = "", stderr = "" }
    end,
    spent = function(_: string, _: string): Agent.Spent? return nil end,
    put = function(_: string, _: string) end,
    serve = function(_: {string}, _: string, _: string, _: integer): (string, function()) | (nil, string)
      error("no task here has a site")
    end,
  }
  local results = Agent.execute(o, system, "k", {}, function(_: string, _: string) end)
  assert(#removed == 2 and removed[1]:find("^rm %-f /tmp/truth%-todos%-1/AGENTS%.md /tmp/truth%-todos%-1/CLAUDE%.md$") ~= nil,
    table.concat(removed, "; "))
  assert(removed[2]:find("^rm %-f /tmp/bench%-t%-todos%-1/AGENTS%.md") ~= nil)
  assert(Agent.report(o, results):find("Fixture: AGENTS.md and CLAUDE.md left out of the fixture.\n", 1, true) ~= nil)
end

--- A run that timed out is slow, not broken: its first request may have been out when it ended.
local function test_a_timeout_before_the_first_request_is_a_failure_and_goes_on()
  local o = options({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "todos", "--reps", "2" })
  local asked = 0
  local system: Agent.System = {
    fresh = function(prefix: string): string return "/tmp/" .. prefix .. "1" end,
    discard = function(_: string) end,
    run = function(argv: {string}, _: string, _: {string: string}?, _: integer): Agent.Output
      if argv[1] == "/c" then
        asked = asked + 1
        return { code = 124, stdout = "", stderr = "" }
      end
      if argv[1] == "bash" and (argv[3] or ""):find("TODO", 1, true) ~= nil then
        return { code = 0, stdout = "x.tl:1\n", stderr = "" }
      end
      return { code = 0, stdout = "", stderr = "" }
    end,
    spent = function(_: string, _: string): Agent.Spent? return nil end,
    put = function(_: string, _: string) end,
    serve = function(_: {string}, _: string, _: string, _: integer): (string, function()) | (nil, string)
      error("no task here has a site")
    end,
  }
  local results = Agent.execute(o, system, "k", {}, function(_: string, _: string) end)
  assert(asked == 2 and #results == 2 and assert(results[1]).grade == "fail" and assert(results[2]).stopped == nil)
end

--- `--against` takes an absolute path; a results.json of an earlier round gives each tool's causes, and the report
--- sets this round's beside them, with a cause the round no longer has left in at none.
local function test_a_report_sets_its_causes_beside_an_earlier_rounds()
  assert(options({ "--tool", "a=/c", "--fixture", "/f", "--out", "/o", "--against", "/r/results.json" }).against ==
      "/r/results.json")
  assert(Agent.parse({ "--tool", "a=/c", "--fixture", "/f", "--out", "/o", "--against", "results.json" }) == nil)
  local before, why = Agent.earlier(
    '[{"tool":"a","task":"t","refused":3,"causes":{"lang: x":2,"prompt: gone":1},"layers":{"lang":2,"prompt":1}},' ..
      '{"tool":"a","task":"u","refused":1,"causes":{"lang: x":1},"layers":{"lang":1}},{"tool":"a","task":"v"}]')
  local a = assert(before, why)["a"]
  assert(a ~= nil and a.refused == 4 and a.causes["lang: x"] == 3 and a.causes["prompt: gone"] == 1 and a.layers["lang"] == 3)
  assert(a.runs == 2)
  -- A tool none of whose runs kept causes is left out, and a count that is no integer is refused.
  local mixed, _ = Agent.earlier('[{"tool":"a","refused":1,"causes":{"lang: x":1},"layers":{}},{"tool":"b","refused":1}]')
  assert(mixed ~= nil and mixed["a"] ~= nil and mixed["b"] == nil)
  for _, text in ipairs({ '[{"tool":"a","refused":1.5,"causes":{}}]', '[{"tool":"a","refused":1,"causes":{"x":"3"}}]',
      '[{"tool":"a","refused":1,"causes":{},"layers":{"lang":2.0}}]', '[{"refused":1,"causes":{}}]' }) do
    local got, wrong = Agent.earlier(text)
    assert(got == nil, text .. " " .. wrong!)
  end
  local none, bad = Agent.earlier('[{"tool":"a","task":"t","refused":3}]')
  assert(none == nil and bad:find("no refusal causes", 1, true) ~= nil, tostring(bad))
  local broken_text, _ = Agent.earlier("{")
  assert(broken_text == nil)
  local o: Agent.Options = { tools = { { name = "a", path = "/a" } }, fixture = "/f", out = "/o", tasks = {}, reps = 1,
    model = "m", timeout = 1 }
  local spent: Agent.Spent = { requests = 1, input = 1, output = 2, cache_read = 3, cache_write = 4, cost = 0.25,
    seconds = 1, tools = 0, runs = 0, refused = 2, codes = {}, causes = { ["lang: x"] = 1, ["stdlib: new"] = 1 },
    layers = { lang = 1, stdlib = 1 }, guesses = {}, resends = 0, sorts = 0, first_read = 0, helpers = {} }
  local report = Agent.report(o, { { tool = "a", task = "todos", rep = 1, grade = "pass", spent = spent, wall = 1 } }, before)
  assert(report:find("- a: 2 refused snippets in 1 runs; by layer: lang 1, stdlib 1; before: 4 refused snippets in 2 runs; by layer: lang 3, " ..
      "prompt 1\n", 1, true) ~= nil, report)
  assert(report:find("  - lang: x: 1 (was 3) (one task only, so fitting it is likely: todos 1)\n", 1, true) ~= nil, report)
  assert(report:find("  - stdlib: new: 1 (was 0) (one task only, so fitting it is likely: todos 1)\n", 1, true) ~= nil, report)
  assert(report:find("  - prompt: gone: 0 (was 1)\n", 1, true) ~= nil, report)
  -- Without an earlier round the lines are as before.
  assert(Agent.report(o, { { tool = "a", task = "todos", rep = 1, grade = "pass", spent = spent, wall = 1 } }):find(
    "  - lang: x: 1 (one task only, so fitting it is likely: todos 1)\n", 1, true) ~= nil)
end

--- A task of a project of eval/testdata copies that project, not `--fixture`, and runs its setup in each copy
--- with `$files`; `--commands` gives a tool's runs the flag, with the tool first on PATH in a directory of its own.
local function test_a_task_of_a_testdata_project_copies_it_and_runs_its_setup()
  local base = { "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "shop-make-build", "--reps", "1" }
  assert(Agent.parse(base) == nil)
  assert(Agent.parse({ "--commands", "t", "--tool", "t=/c", "--fixture", "/f", "--out", "/o" }) == nil)
  assert(Agent.parse({ "--tool", "t=/c", "--testdata", "td", "--fixture", "/f", "--out", "/o" }) == nil)
  local o = options({ "--tool", "t=/c", "--tool", "u=/d", "--commands", "t", "--testdata", "/td", "--fixture", "/f",
    "--out", "/o", "--tasks", "shop-make-build", "--reps", "1" })
  assert(assert(o.tools[1]).commands == true and assert(o.tools[2]).commands == nil and o.testdata == "/td")
  local copies: mut {string} = {}
  local setups: mut {string} = {}
  local placed: mut {string} = {}
  local asked: mut {{string}} = {}
  local paths: mut {string} = {}
  local system: Agent.System = {
    fresh = function(prefix: string): string return "/tmp/" .. prefix .. "1" end,
    discard = function(_: string) end,
    run = function(argv: {string}, dir: string, env: {string: string}?, _: integer): Agent.Output
      local line = table.concat(argv, " ")
      if argv[1] == "cp" then copies[#copies + 1] = line end
      local script = argv[3] or ""
      if argv[1] == "bash" and script:find("cp \"$files/money.tl\"", 1, true) ~= nil then
        local seen = dir .. ": " .. script
        setups[#setups + 1] = seen
      end
      if argv[1] == "bash" and script:find("command -v", 1, true) ~= nil then
        local seen = (argv[4] or "") .. " " .. (argv[5] or "")
        placed[#placed + 1] = seen
      end
      if argv[1] == "/c" or argv[1] == "/d" then
        asked[#asked + 1] = argv
        local seen = env and env["PATH"] or ""
        paths[#paths + 1] = seen
      end
      return { code = 0, stdout = "", stderr = "" }
    end,
    spent = function(_: string, _: string): Agent.Spent? return nil end,
    put = function(_: string, _: string) end,
    serve = function(_: {string}, _: string, _: string, _: integer): (string, function()) | (nil, string)
      error("no task here has a site")
    end,
  }
  local _ = Agent.execute(o, system, "k", { PATH = "/bin" }, function(_: string, _: string) end)
  assert(#copies == 3 and copies[1] == "cp -a /td/shop/. /tmp/truth-shop-make-build-1", table.concat(copies, "; "))
  assert(#setups == 3 and setups[1]:find("^/tmp/truth%-shop%-make%-build%-1: tool='/c'; " ..
      "files='/td/files/shop%-make%-build'; cp ") ~= nil, setups[1])
  assert(#placed == 1 and placed[1] == "/c /o/t/path", table.concat(placed, "; "))
  local function has(argv: {string}, word: string): boolean
    for _, w in ipairs(argv) do
      if w == word then return true end
    end
    return false
  end
  assert(#asked == 2 and has(assert(asked[1]), "--commands") and not has(assert(asked[2]), "--commands"))
  assert(paths[1] == "/o/t/path:/bin" and paths[2] == "/bin", table.concat(paths, "; "))
end

--- The shop tasks need eval/testdata: without it they are refused, not run on `--fixture`.
local function test_a_task_of_a_testdata_project_needs_testdata()
  local parsed, why = Agent.parse({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "shop-dead" })
  assert(parsed == nil and why:find("give --testdata", 1, true) ~= nil, why)
  assert(Agent.parse({ "--tool", "t=/c", "--fixture", "/f", "--out", "/o", "--tasks", "todos" }) ~= nil)
end
