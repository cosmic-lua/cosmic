--- `cosmic agent worker` as the run tool drives it ([`cosmic.agent.worker`]): one process that checks and runs one
--- snippet after another, answering each as its own.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")
local Worker = require("cosmic.agent.worker")
local agent_worker = require("build.agent_worker")
local test_child = require("build.test_child")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic" } }

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
