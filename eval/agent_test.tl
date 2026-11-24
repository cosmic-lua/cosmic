--- [`eval/agent.tl`] with a fake System: the command line, the runs it makes, how each is graded, what a session
--- spent, and the report. No agent is started.
local Agent = require("eval.agent")
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
    "--tasks", "todos,rename", "--reps", "1" })
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
  assert(report:find("## todos\n\n- good: 1 of 1 passed; 3.0 requests, $0.500, 3 s wall (2 s in requests)", 1, true) ~= nil, report)
  assert(report:find("30 cache read (5 by the first request)", 1, true) ~= nil and
      report:find("1.0 of them run, 1.0 refused\n  - refused for: semicolon 1\n" ..
          "  - snippets naming each Host helper: grep 2.0, bash 1.0\n", 1, true) ~= nil, report)
  assert(report:find("- bad: 0 of 1 passed", 1, true) ~= nil, report)
  assert(report:find("- good: unfit on this fixture", 1, true) ~= nil, report)
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
  (2, 'run', '{"code":"Host.grep(\\"a\\", Host.find(\\".\\")) Host.grep(\\"b\\", {}) local c: {Host.Count} = MyHost.top()"}', 'ok'), (1, 'read', '', '');
]]))
  local s = assert(Agent.spent_in(db, "bench-a-todos-2"))
  assert(s.requests == 3 and s.input == 30 and s.output == 3 and s.cache_read == 300 and s.cache_write == 12)
  assert(s.cost == 0.75 and s.seconds == 2 and s.tools == 4 and s.runs == 3)
  assert(s.helpers["bash"] == 1 and s.helpers["grep"] == 1 and s.helpers["find"] == 1)
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
  local server = assert(task.server)
  assert(server.name == "inventory" and server.source:find("serve_stdio", 1, true) ~= nil)
  local _, items = server.data:gsub("\n", "")
  assert(items == 240 and server.data == assert(assert(Agent.tasks[#Agent.tasks]).server).data)
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
        local program = path:gsub("mcp%.json$", "server.tl")
        assert(config:find('"command":["/c","--standalone","' .. program, 1, true) ~= nil, config)
        local dir = path:gsub("/mcp%.json$", "")
        assert(config:find('"grants":[{"letters":"r","path":"' .. dir .. '"}]', 1, true) ~= nil, config)
        assert(put[dir .. "/data.tsv"] == server.data)
        configs = configs + 1
      end
      return { code = 0, stdout = "", stderr = "" }
    end,
    spent = function(_: string, _: string): Agent.Spent? return nil end,
    put = function(path: string, text: string) put[path] = text end,
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
