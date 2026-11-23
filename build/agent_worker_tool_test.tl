--- `cosmic agent worker` as the run tool drives it ([`cosmic.agent.worker`]): one process that checks and runs one
--- snippet after another, answering each as its own.
local Fs = require("cosmic.fs")
local Host = require("cosmic.agent.host")
local Json = require("cosmic.json")
local Sessions = require("cosmic.agent.sessions")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")
local Worker = require("cosmic.agent.worker")
local agent_worker = require("build.agent_worker")
local test_child = require("build.test_child")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "/bin/sh", letters = "r" }, { path = "/bin/sleep", letters = "r" }, { path = "/usr/bin/sleep", letters = "r" } } }

--- The worker, as `cosmic agent worker` runs it, in a child of this module.
test_child.register("worker", function(_args: {string}): integer
  return agent_worker.main()
end)

--- A set whose worker is this program, as a test starts it.
local function set(): Worker.Set
  local dir = assert(Fs.mkdtemp("agent-worker-store-"))
  local started = this_program.program(test_child.words(dir, "build.agent_worker_tool_test", "worker"),
    { env = this_program.environment(), timeout_ns = -1 })
  return Worker.new(started.argv, started.options)
end

--- `answer` as JSON text, for an assertion's message.
local function shown(answer: Worker.Answer): string
  local text, _ = Json.encode(answer)
  return text or "?"
end

local function run(w: Worker.Set, code: string, seconds?: integer): Worker.Answer
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  return assert(Worker.run(w, code, { cwd = dir, seconds = seconds or 60 }))
end

local function test_a_snippet_runs_and_answers_what_it_printed_and_returned()
  local w = set()
  local answer = run(w, "print(\"hello\")\nreturn { n = 2 }\n")
  assert(answer["ok"] == true and answer["output"] == "hello\n", shown(answer))
  local value, _ = Json.to_object(answer["value"])
  assert(value ~= nil and value["n"] == 2, shown(answer))
  Worker.close(w)
end

local function test_a_refused_snippet_does_not_run_and_the_next_does_in_the_same_worker()
  local w = set()
  local refused = run(w, "local Fs = require(\"cosmic.fs\")\nprint(\"ran\")\nFs.reed(\"x\")\n")
  local lines, _ = Json.to_array(refused["refused"])
  assert(lines ~= nil, shown(refused))
  assert(refused["output"] == nil and tostring(lines[1]):find("nearest `read`", 1, true) ~= nil, shown(refused))
  local ran = run(w, "local Fs = require(\"cosmic.fs\")\nprint(Fs.basename(\"/a/b.tl\"))\n")
  assert(ran["ok"] == true and ran["output"] == "b.tl\n", shown(ran))
  assert(w.started == 1, "one worker answered both")
  Worker.close(w)
end

local function test_a_snippet_that_raises_is_answered_with_its_output_and_why()
  local w = set()
  local answer = run(w, "print(\"before\")\nerror(\"boom\")\n")
  assert(answer["ok"] == false and answer["output"] == "before\n", shown(answer))
  assert(tostring(answer["error"]):find("boom", 1, true) ~= nil, shown(answer))
  Worker.close(w)
end

local function test_a_snippet_past_its_timeout_ends_the_worker_and_the_next_starts_another()
  local w = set()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local answer, why = Worker.run(w, "while true do end\n", { cwd = dir, seconds = 1 })
  assert(answer == nil and tostring(why):find("ran past 1 second", 1, true) ~= nil, tostring(why))
  local after = run(w, "return 7\n")
  assert(after["value"] == 7 and w.started == 2, shown(after))
  Worker.close(w)
end

--- The run tool shows the model what a snippet printed and returned, and a refusal as an error that ran nothing.
local function test_the_run_tool_shows_what_a_snippet_printed_returned_and_was_refused_for()
  local w = set()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local context: Tools.Context = { cwd = dir, worker = w }
  local ran = Tools.run("run", { code = "print(\"two\")\nreturn 2\n" }, context)
  assert(not ran.is_error and ran.text == "two\nReturned: 2", ran.text)
  local refused = Tools.run("run", { code = "local n: string = 1\nreturn n\n" }, context)
  assert(refused.is_error and refused.text:find("did not run", 1, true) ~= nil and
      refused.text:find("run.tl:1:", 1, true) ~= nil, refused.text)
  local raised = Tools.run("run", { code = "error(\"boom\")\n" }, context)
  assert(raised.is_error and raised.text:find("Error: run.tl:1: boom", 1, true) ~= nil, raised.text)
  local long = Tools.run("run", { code = "for i = 1, 4000 do print(\"line \" .. tostring(i)) end\n" }, context)
  assert(not long.is_error and long.text:find("truncated", 1, true) ~= nil and long.text:find("line 4000", 1, true) ~= nil and
      long.text:find("line 1\n", 1, true) == nil and long.raw ~= nil, long.text:sub(1, 200))
  assert(#long.text < 9 * 1024, tostring(#long.text))
  local none = Tools.run("run", { code = "local x = 1\nassert(x == 1)\n" }, context)
  assert(not none.is_error and none.text == "(no output)", none.text)
  Worker.close(w)
end

--- A turn the user stops ends the snippet running, and the worker with it.
local function test_a_stopped_turn_ends_the_snippet_and_the_worker()
  local w = set()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local asked = 0
  local answer, why = Worker.run(w, "while true do end\n", { cwd = dir, seconds = 60, stopped = function(): boolean
    asked = asked + 1
    return asked > 2
  end })
  assert(answer == nil and tostring(why):find("stopped by the user", 1, true) ~= nil and w.handle == nil, tostring(why))
  Worker.close(w)
end

--- What a snippet prints or returns reaches the model whatever its bytes or size, and the snippet reads no request.
local function test_an_answer_holds_any_bytes_and_a_large_value_and_the_snippet_reads_no_request()
  local w = set()
  local bytes = run(w, "print(\"a\\xffb\")\nreturn \"\\xfe\"\n")
  assert(bytes["ok"] == true and bytes["output"] == "a\u{FFFD}b\n" and bytes["value"] == "\u{FFFD}", shown(bytes))
  local nulls = run(w, "local Json = require(\"cosmic.json\")\nreturn Json.array({ 1, Json.null, 2 })\n")
  local list, _ = Json.to_array(nulls["value"])
  assert(list ~= nil and #list == 3 and list[2] == Json.null, shown(nulls))
  local big = run(w, "return string.rep(\"x\", 200000)\n")
  assert(big["ok"] == true and tostring(big["value"]):find("more than an answer holds", 1, true) ~= nil, shown(big))
  local much = run(w, "for i = 1, 20000 do print(\"line \" .. tostring(i)) end\n")
  local output = tostring(much["output"])
  assert(much["cut"] == true and #output <= 64 * 1024 and output:find("line 20000\n", 1, true) ~= nil, #output)
  local Fs_take = "local Fs = require(\"cosmic.fs\")\nlocal got, _ = Fs.take(Fs.stdin, 100)\nreturn got == \"\"\n"
  local read = run(w, Fs_take, 10)
  assert(read["ok"] == true and read["value"] == true, shown(read))
  assert(w.started == 1, "one worker answered all")
  Worker.close(w)
end

--- An answer out of step, one that is no JSON, and a worker that ends are each told, and the worker ended.
local function test_a_worker_that_answers_wrong_or_ends_is_ended_and_told()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local cases: {{string}} = {
    { "read line; echo '{\"id\":99}'; sleep 5", "another request" },
    { "read line; echo 'not json'; sleep 5", "no JSON object" },
    { "read line; echo '{\"id\":99,\"call\":\"sql\"}'; sleep 5", "another request" },
    { "read line; echo '{\"id\":1,\"call\":\"sql\"}'; read reply; exit 0", "it ended" },
    { "read line; exit 0", "it ended" },
  }
  for _, case in ipairs(cases) do
    local w = Worker.new({ "/bin/sh", "-c", assert(case[1]) })
    local answer, why = Worker.run(w, "return 1\n", { cwd = dir, seconds = 10 })
    assert(answer == nil and tostring(why):find(assert(case[2]), 1, true) ~= nil and w.handle == nil, tostring(why))
  end
end

--- A snippet queries sessions.db through the agent, which answers it read-only, as the sql tool does, row by row.
local function test_a_snippet_queries_the_sessions_through_the_agent()
  local w = set()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local db = assert(Sessions.open(dir .. "/sessions.db"))
  local id = assert(Sessions.start(db, "/", "m", 0))
  local _ = assert(Sessions.output(db, id, { tool = "bash", input = "{}", text = "a\xffb", is_error = false }))
  local context: Tools.Context = { cwd = dir, worker = w, db = db, session = id }
  local code = [[
local Host = require("cosmic.agent.host")
local rows = assert(Host.sql("SELECT tool, text, 1.5 AS r, NULL AS z, ?1 AS here FROM outputs"))
local row = assert(rows[1])
print(row["tool"], row["text"], row["r"], row["z"] == require("cosmic.json").null, row["here"])
local none, why = Host.sql("DELETE FROM outputs")
print(none == nil, tostring(why))
local again = assert(Host.sql("SELECT count(*) AS n FROM outputs"))
return assert(again[1])["n"]
]]
  local ran = Tools.run("run", { code = code }, context)
  assert(not ran.is_error, ran.text)
  assert(ran.text:find("bash\ta\u{FFFD}b\t1.5\ttrue\t" .. tostring(id) .. "\n", 1, true) ~= nil, ran.text)
  assert(ran.text:find("true\thost: sql: attempt to write", 1, true) ~= nil and ran.text:find("readonly", 1, true) ~= nil, ran.text)
  assert(ran.text:find("Returned: 1", 1, true) ~= nil, ran.text)
  local big = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\n" ..
      "local _, why = Host.sql(\"SELECT printf('%.1000c', 'x') AS x FROM generate_series(1, 1000)\")\n" ..
      "return tostring(why)\n" }, context)
  assert(big.text:find("narrow the query", 1, true) ~= nil and big.text:find("after 5", 1, true) ~= nil, big.text)
  local other = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\n" ..
      "local _, why = Host.call(\"bash\", { command = \"id\" })\nreturn tostring(why)\n" }, context)
  assert(other.text:find("serves no call", 1, true) ~= nil and other.text:find("it serves sql", 1, true) ~= nil, other.text)
  local function returned(query: string): string
    local r = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\n" ..
        "local rows, why = Host.sql(" .. Json.quote(query) .. ")\n" ..
        "if rows == nil then return tostring(why) end\nreturn rows\n" }, context)
    return r.text
  end
  local inf = returned("SELECT 1e999 AS x")
  assert(inf:find("JSON holds no number", 1, true) ~= nil, inf)
  local twice = returned("SELECT 1 AS a, 2 AS a")
  assert(twice == "Returned: [{\"a\":2}]", twice)
  -- Control characters take six bytes of JSON each, which the limit counts.
  local escaped = returned("SELECT replace(printf('%.100000c', 'x'), 'x', char(1)) AS c")
  assert(escaped:find("narrow the query", 1, true) ~= nil, escaped:sub(1, 300))
  assert(w.started == 1, "one worker answered all")
  -- A query that runs past the snippet's time is stopped between its rows, and the worker ended.
  local slow = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\n" ..
      "local _, _ = Host.sql(\"SELECT NULL AS n FROM generate_series(1, 1000000000000) WHERE value % 200000 = 0\")\n",
    timeout = 2 }, context)
  assert(slow.is_error and slow.text:find("ran past 2 seconds", 1, true) ~= nil, slow.text)
  local served, _ = Worker.run(w, "local Host = require(\"cosmic.agent.host\")\nlocal _, why = Host.sql(\"SELECT 1\")\n" ..
      "return tostring(why)\n", { cwd = dir, seconds = 30 })
  assert(served ~= nil and tostring(served["value"]):find("serves no call to this worker", 1, true) ~= nil, if served ~= nil then shown(served) else "nil" end)
  Worker.close(w)
  local _, _ = db:close()
end

--- Outside a worker no agent answers a call.
local function test_a_call_outside_a_worker_fails()
  local rows, why = Host.sql("SELECT 1")
  assert(rows == nil and tostring(why):find("no agent answers here", 1, true) ~= nil, tostring(why))
end
