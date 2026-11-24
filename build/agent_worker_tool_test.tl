--- `cosmic agent worker` as the run tool drives it ([`cosmic.agent.worker`]): one process that checks and runs one
--- snippet after another, answering each as its own.
local AgentMcp = require("cosmic.agent.mcp")
local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Host = require("cosmic.agent.host")
local Json = require("cosmic.json")
local Poll = require("cosmic.poll")
local Sessions = require("cosmic.agent.sessions")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")
local Worker = require("cosmic.agent.worker")
local agent_worker = require("build.agent_worker")
local test_child = require("build.test_child")
local _ = require("build.standalone")
--- What the MCP server script requires, as its standalone run loads it.
local type _ = require("cosmic.mcp.server")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "/bin/sh", letters = "r" }, { path = "/bin/sleep", letters = "r" }, { path = "/usr/bin/sleep", letters = "r" }, { path = "/usr/bin/setsid", letters = "r" } },
  -- Most tests start a worker, whose first snippet loads the checker: 1.6 s alone here, 3.5 s beside four others,
  -- and past 10 s on a loaded macOS runner (test_a_snippet_keeps_a_value_for_a_later_one, 2026-11-24). A test that
  -- hangs still ends at the bound.
  timeout = 30 }

--- The worker, as `cosmic agent worker` runs it, in a child of this module.
test_child.register("worker", function(_args: {string}): integer
  return agent_worker.main()
end)

--- A set whose worker is this program, as a test starts it.
local function set_of_worker(): Worker.Set
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

local function run(w: Worker.Set, code: string, seconds?: integer, cwd?: string): Worker.Answer
  local dir = cwd or assert(Fs.mkdtemp("agent-worker-"))
  return assert(Worker.run(w, code, { cwd = dir, seconds = seconds or 60 }))
end

local function test_a_snippet_runs_and_answers_what_it_printed_and_returned()
  local w = set_of_worker()
  local answer = run(w, "print(\"hello\")\nreturn { n = 2 }\n")
  assert(answer["ok"] == true and answer["output"] == "hello\n", shown(answer))
  local value, _ = Json.to_object(answer["value"])
  assert(value ~= nil and value["n"] == 2, shown(answer))
  Worker.close(w)
end

local function test_a_refused_snippet_does_not_run_and_the_next_does_in_the_same_worker()
  local w = set_of_worker()
  local refused = run(w, "local Fs = require(\"cosmic.fs\")\nprint(\"ran\")\nFs.reed(\"x\")\n")
  local lines, _ = Json.to_array(refused["refused"])
  assert(lines ~= nil, shown(refused))
  assert(refused["output"] == nil and tostring(lines[1]):find("nearest `read`", 1, true) ~= nil, shown(refused))
  local ran = run(w, "local Fs = require(\"cosmic.fs\")\nprint(Fs.basename(\"/a/b.tl\"))\n")
  assert(ran["ok"] == true and ran["output"] == "b.tl\n", shown(ran))
  assert(w.started == 1, "one worker answered both")
  Worker.close(w)
end

local function test_a_statements_semicolons_are_dropped_and_a_tables_or_a_calls_are_refused()
  local w = set_of_worker()
  local ran = run(w, "local a, b = 1, 2; print(a); print(b);\n")
  assert(ran["ok"] == true and ran["output"] == "1\n2\n", shown(ran))
  for _, code in ipairs({ "local t = { a = 1; b = 2 }\nprint(t.a)\n", "local f = print; (f)(1)\n",
      "local n: integer = \"x\"; print(n)\n" }) do
    local refused = run(w, code)
    local lines, _ = Json.to_array(refused["refused"])
    assert(lines ~= nil and #lines > 0, shown(refused))
    -- A `;` the mend cannot take is told of as the first check told of it.
    assert(code:find("integer", 1, true) ~= nil or tostring(lines[1]):find("(semicolon)", 1, true) ~= nil, shown(refused))
  end
  -- Beside another error, the `;` is mended all the same, and the refusal tells of the other alone.
  local other = run(w, "local a = 1; print(a)\nlocal t: mut {{string, integer}} = {}\nprint(#t)\n")
  local said = assert(Json.to_array(other["refused"]))
  local parts: mut {string} = {}
  for _, l in ipairs(said) do parts[#parts + 1] = tostring(l) end
  local told = table.concat(parts, "\n")
  assert(told:find("(tuple_type)", 1, true) ~= nil and told:find("(semicolon)", 1, true) == nil, shown(other))
  -- A snippet runs once, so an unused name is no reason to refuse it.
  local unused = run(w, "local seen = 1\nprint(\"ran\")\n")
  assert(unused["ok"] == true and unused["output"] == "ran\n", shown(unused))
  Worker.close(w)
end

local function test_a_snippet_that_raises_is_answered_with_its_output_and_why()
  local w = set_of_worker()
  local answer = run(w, "print(\"before\")\nerror(\"boom\")\n")
  assert(answer["ok"] == false and answer["output"] == "before\n", shown(answer))
  assert(tostring(answer["error"]):find("boom", 1, true) ~= nil, shown(answer))
  Worker.close(w)
end

local function test_a_snippet_past_its_timeout_ends_the_worker_and_the_next_starts_another()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local answer, why = Worker.run(w, "while true do end\n", { cwd = dir, seconds = 1 })
  assert(answer == nil and tostring(why):find("ran past 1 second", 1, true) ~= nil, tostring(why))
  local after = run(w, "return 7\n")
  assert(after["value"] == 7 and w.started == 2, shown(after))
  Worker.close(w)
end

--- The run tool shows the model what a snippet printed and returned, and a refusal as an error that ran nothing.
local function test_the_run_tool_shows_what_a_snippet_printed_returned_and_was_refused_for()
  local w = set_of_worker()
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
  -- Past 8KB, its start and its end, and between them a line of how much was cut.
  assert(not long.is_error and long.text:find("Output cut", 1, true) ~= nil and long.text:find("line 4000\n", 1, true) ~= nil and
      long.text:find("\nline 1\n", 1, true) ~= nil and long.text:find("line 2000\n", 1, true) == nil and
      long.text:find(" cut ...]\n", 1, true) ~= nil and #long.text < 8400 and long.raw ~= nil, long.text:sub(1, 200))
  -- Past 64KB, the count is of all that was cut, not of what the worker answered.
  local huge = Tools.run("run", { code = "for i = 1, 40000 do print(\"line \" .. tostring(i)) end\n" }, context)
  local cut_bytes = tonumber(huge.text:match("%[%.%.%. (%d+) bytes cut %.%.%.%]")) or 0
  assert(not huge.is_error and cut_bytes > 400000 and huge.text:find("line 40000\n", 1, true) ~= nil, huge.text:sub(1, 300))
  local wide = Tools.run("run", { code = "for i = 1, 4000 do print(\"line \" .. tostring(i)) end\n", output_bytes = 60000 },
    context)
  assert(not wide.is_error and wide.text:find("line 2000\n", 1, true) ~= nil and #wide.text > 8400, wide.text:sub(1, 200))
  local narrow = Tools.run("run", { code = "print(1)\n", output_bytes = 10 }, context)
  assert(narrow.is_error and narrow.text:find("output_bytes is 10: give 1024 to 65536", 1, true) ~= nil, narrow.text)
  assert(#long.text < 9 * 1024, tostring(#long.text))
  local none = Tools.run("run", { code = "local x = 1\nassert(x == 1)\n" }, context)
  assert(not none.is_error and none.text == "(no output)", none.text)
  Worker.close(w)
end

--- A turn the user stops ends the snippet running, and the worker with it.
local function test_a_stopped_turn_ends_the_snippet_and_the_worker()
  local w = set_of_worker()
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
  local w = set_of_worker()
  local bytes = run(w, "print(\"a\\xffb\")\nreturn \"\\xfe\"\n")
  assert(bytes["ok"] == true and bytes["output"] == "a\u{FFFD}b\n" and bytes["value"] == "\u{FFFD}", shown(bytes))
  local nulls = run(w, "local Json = require(\"cosmic.json\")\nreturn Json.array({ 1, Json.null, 2 })\n")
  local list, _ = Json.to_array(nulls["value"])
  assert(list ~= nil and #list == 3 and list[2] == Json.null, shown(nulls))
  local big = run(w, "return string.rep(\"x\", 200000)\n")
  assert(big["ok"] == true and tostring(big["value"]):find("more than an answer holds", 1, true) ~= nil, shown(big))
  local written = 0
  for i = 1, 20000 do written = written + #("line " .. tostring(i)) + 1 end
  local much = run(w, "for i = 1, 20000 do print(\"line \" .. tostring(i)) end\n")
  local output = tostring(much["output"])
  assert(much["cut"] == true and #output <= 64 * 1024 + 64 and output:find("line 20000\n", 1, true) ~= nil and
      output:sub(1, 7) == "line 1\n" and output:find(" cut ...]\n", 1, true) ~= nil and
      much["bytes"] == written, #output)
  -- Past a read's chunk, only the start and the end are held.
  local more = run(w, "print(string.rep(\"y\", 3000000))\nprint(\"the end\")\n")
  local tail = tostring(more["output"])
  assert(more["cut"] == true and #tail <= 64 * 1024 + 64 and tail:sub(-8) == "the end\n" and tail:sub(1, 1) == "y" and
      more["bytes"] == 3000000 + 1 + 8 and tail:find("[... 2934473 bytes cut ...]", 1, true) ~= nil, tail:sub(16380, 16420))
  -- 64KB is whole; a byte more is cut.
  local whole = run(w, "print(string.rep(\"z\", 65535))\n")
  assert(whole["cut"] == nil and #tostring(whole["output"]) == 65536, shown(whole))
  local past = run(w, "print(string.rep(\"z\", 65536))\n")
  assert(past["cut"] == true and tostring(past["output"]):find("[... 1 byte cut ...]", 1, true) ~= nil, #tostring(past["output"]))
  -- The count is of the bytes written, whatever they are, and the start ends at a character's end.
  local bad = run(w, "print(string.rep(\"\\xff\", 69999))\n")
  assert(bad["cut"] == true and tostring(bad["output"]):find("[... 4464 bytes cut ...]", 1, true) ~= nil, #tostring(bad["output"]))
  local split = run(w, "print(string.rep(\"a\", 16383) .. \"\u{e9}\" .. string.rep(\"b\", 70000))\n")
  local split_out = tostring(split["output"])
  assert(split_out:sub(16383, 16384) == "a\n" and split_out:find("\u{FFFD}", 1, true) == nil, split_out:sub(16380, 16420))
  local Fs_take = "local Fs = require(\"cosmic.fs\")\nlocal got, _ = Fs.take(Fs.stdin, 100)\nreturn got == \"\"\n"
  local read = run(w, Fs_take, 10)
  assert(read["ok"] == true and read["value"] == true, shown(read))
  assert(w.started == 1, "one worker answered all")
  Worker.close(w)
end

--- A snippet that prints without end runs to its timeout, the worker read as it writes.
local function test_a_snippet_that_prints_without_end_runs_to_its_timeout()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local answer, why = Worker.run(w, "while true do print(string.rep(\"z\", 4096)) end\n", { cwd = dir, seconds = 2 })
  assert(answer == nil and tostring(why):find("ran past 2 seconds", 1, true) ~= nil, tostring(why))
  Worker.close(w)
end

--- What a program an earlier snippet started writes after that snippet answered is not the next snippet's output,
--- nor is a snippet's end mark another's.
local function test_a_late_write_and_a_snippets_own_mark_are_not_the_next_snippets_output()
  -- macOS has no setsid program, so the shell could leave nothing behind that outlives its group.
  if not assert(Fs.status("/usr/bin/setsid")).exists then
    Test.skip("this host has no /usr/bin/setsid to leave a program in a session of its own")
    return
  end
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  -- The shell leaves a program behind in a session of its own, which outlives the shell's group and writes once the
  -- snippet answered.
  -- The left one runs in the background of the shell, not as a leader of its group, so setsid makes its session at
  -- once with no fork of its own and no -f, which busybox's setsid (Alpine's) has not. Child.run ends what is left of
  -- its group when the shell exits, so the shell waits, up to 5 s, for the left one, past setsid, to say it is up.
  local late = "local Child = require(\"cosmic.child\")\n" ..
    "local _ = assert(Child.run({ \"/bin/sh\", \"-c\", " ..
    "\"/usr/bin/setsid /bin/sh -c 'echo > up; until [ -e go ]; do sleep 0.05; done; echo late; echo late > wrote' & " ..
    "i=0; until [ -e up ] || [ $i -ge 100 ]; do sleep 0.05; i=$((i + 1)); done\" },\n" ..
    "  { stdout = \"inherit\", stderr = \"inherit\", timeout_ns = 10 * 1000000000 }))\n" ..
    "print(\"now\")\n"
  local first = run(w, late, nil, dir)
  assert(first["ok"] == true and first["output"] == "now\n", shown(first))
  -- The left program writes once the snippet answered, when told to.
  assert(Fs.write(dir .. "/go", ""))
  local deadline = Clock.monotonic_ns() + Clock.seconds(5)
  local wrote, _ = Fs.read(dir .. "/wrote")
  -- The shell makes the file before it writes the line, so an empty file is one not yet written.
  while wrote ~= "late\n" and Clock.monotonic_ns() < deadline do
    local _, _ = Clock.sleep_ns(Clock.ms(50))
    local again, _ = Fs.read(dir .. "/wrote")
    wrote = again
  end
  -- Past the file, the echo to the pipe came first.
  local listed, _ = Fs.list(dir)
  assert(wrote == "late\n", "the late program wrote: " .. tostring(wrote) .. " in " ..
      (if listed ~= nil then table.concat(listed, ",") else "?" end))
  local after = run(w, "print(\"next\")\n", nil, dir)
  assert(after["ok"] == true and after["output"] == "next\n", shown(after))
  -- A snippet that prints another request's end mark ends no output but its own.
  local spoof = "local Worker = require(\"cosmic.agent.worker\")\n" ..
    "print(\"a\" .. Worker.mark(\"end\", 99) .. Worker.mark(\"start\", 5) .. \"b\")\n"
  local own = run(w, spoof, nil, dir)
  assert(own["ok"] == true and tostring(own["output"]):sub(1, 1) == "a" and tostring(own["output"]):sub(-2) == "b\n",
    shown(own))
  local last = run(w, "print(\"last\")\n", nil, dir)
  assert(last["ok"] == true and last["output"] == "last\n", shown(last))
  Worker.close(w)
end

--- Calls a snippet makes from tasks of its own are out at once, and the agent serves each in a task of its own: each
--- of the first four calls is held until all four are being served, which only calls served at once can be, and
--- each gets its own reply. Held calls wait for the others, never for a time, so a slow core only slows the test.
local function test_calls_from_a_snippets_tasks_are_served_at_once()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local served = 0
  local held = 0
  local most_held = 0
  local serve: Worker.Serve = function(name: string, args: Json.Value, _: Worker.Budget): (Json.Value) | (nil, Failure)
    served = served + 1
    local n = math.tointeger(args)
    if n ~= nil and n <= 4 then
      held = held + 1
      if held > most_held then most_held = held end
      -- Calls served one at a time would leave this one alone here until its deadline.
      local deadline = Clock.monotonic_ns() + Clock.seconds(20)
      while most_held < 4 and Clock.monotonic_ns() < deadline do
        -- A cancelled task's delay answers at once: stop, rather than spin to the deadline.
        local slept, _ = Poll.delay(Clock.ms(10))
        if not slept then break end
      end
      held = held - 1
    else
      local _, _ = Poll.delay(Clock.ms(500))
    end
    if name == "fail" then return nil, Failure.new("refused " .. tostring(args)) end
    return "napped " .. tostring(args)
  end
  local code = [[
local Host = require("cosmic.agent.host")
local Poll = require("cosmic.poll")
local got: mut {integer: string} = {}
Poll.run(function()
  for i = 1, 4 do
    local _ = Poll.spawn(function()
      local value, why = Host.call(if i == 3 then "fail" else "nap" end, i)
      got[i] = if value ~= nil then tostring(value) else tostring(why) end
    end)
  end
end)
print(got[1], got[2], got[3], got[4])
local after, _ = Host.call("nap", 5)
print(tostring(after))
]]
  local answer = assert(Worker.run(w, code, { cwd = dir, seconds = 30, serve = serve }))
  assert(answer["ok"] == true and answer["output"] == "napped 1\tnapped 2\thost: fail: refused 3\tnapped 4\n" ..
      "napped 5\n", shown(answer))
  assert(served == 5, tostring(served))
  assert(most_held == 4, "the four calls were served at once: at most " .. tostring(most_held) .. " together")
  -- A call a cancelled task left, and one a task closed as another raised, leave the next snippet as it was.
  local left = [[
local Clock = require("cosmic.clock")
local Host = require("cosmic.agent.host")
local Poll = require("cosmic.poll")
Poll.run(function()
  local task = Poll.spawn(function() local _, _ = Host.call("nap", 6) end)
  local _, _ = task:join(Clock.ms(100))
  task:cancel()
end)
local ok, _ = pcall(Poll.run, function()
  local _ = Poll.spawn(function() local _, _ = Host.call("nap", 7) end)
  local _ = Poll.spawn(function() error("boom") end)
end)
print(ok)
]]
  local cut = assert(Worker.run(w, left, { cwd = dir, seconds = 30, serve = serve }))
  assert(cut["ok"] == true and cut["output"] == "false\n", shown(cut))
  local after = assert(Worker.run(w, "local Host = require(\"cosmic.agent.host\")\nlocal v, _ = Host.call(\"nap\", 8)\n" ..
      "print(tostring(v))\n", { cwd = dir, seconds = 30, serve = serve }))
  assert(after["ok"] == true and after["output"] == "napped 8\n" and w.started == 1, shown(after))
  Worker.close(w)
end

--- An answer out of step, one that is no JSON, and a worker that ends are each told, and the worker ended.
local function test_a_worker_that_answers_wrong_or_ends_is_ended_and_told()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local cases: {{string}} = {
    { "read line; echo '{\"id\":99}'; sleep 5", "another request" },
    { "read line; echo 'not json'; sleep 5", "no JSON object" },
    { "read line; echo '{\"id\":99,\"call\":\"history\"}'; sleep 5", "another request" },
    { "read line; echo '{\"id\":1,\"call\":\"history\"}'; read reply; exit 0", "it ended" },
    { "read line; exit 0", "it ended" },
  }
  for _, case in ipairs(cases) do
    local w = Worker.new({ "/bin/sh", "-c", assert(case[1]) })
    local answer, why = Worker.run(w, "return 1\n", { cwd = dir, seconds = 10 })
    assert(answer == nil and tostring(why):find(assert(case[2]), 1, true) ~= nil and w.handle == nil, tostring(why))
  end
end

--- A snippet keeps a value for a later one of its session, in sessions.db, and reads it back; another session reads
--- none of it.
local function test_a_snippet_keeps_a_value_for_a_later_one()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local db = assert(Sessions.open(dir .. "/sessions.db"))
  local id = assert(Sessions.start(db, "/", "m", 0))
  local other = assert(Sessions.start(db, "/", "m", 0))
  local context: Tools.Context = { cwd = dir, worker = w, db = db, session = id }
  local put = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\n" ..
      "Host.store(\"cursor\", { page = 3, seen = { \"a\", \"b\" } })\n" ..
      "local _, why = pcall(Host.store, \"\", 1)\nprint(why)\n" ..
      "local _, big = pcall(Host.store, \"big\", string.rep(\"x\", 300 * 1024))\nprint(big)\n" }, context)
  assert(not put.is_error and put.text:find("a key is a string of 1 to 256 bytes", 1, true) ~= nil, put.text)
  assert(put.text:find("more than the 256KB a key holds", 1, true) ~= nil and Sessions.kept(db, id, "big") == nil, put.text)
  local got = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\nlocal Json = require(\"cosmic.json\")\n" ..
      "local v = assert(Json.object_of(Host.load(\"cursor\").value))\n" ..
      "print(v[\"page\"], assert(Json.array_of(v[\"seen\"]))[2], Host.load(\"none\").value == nil)\n" ..
      "Host.store(\"cursor\")\nprint(Host.load(\"cursor\").value == nil)\n" }, context)
  assert(not got.is_error and got.text:find("3\tb\ttrue\ntrue\n", 1, true) ~= nil, got.text)
  local elsewhere = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\n" ..
      "Host.store(\"cursor\", 1)\n" }, { cwd = dir, worker = w, db = db, session = other })
  assert(not elsewhere.is_error, elsewhere.text)
  assert(Sessions.kept(db, id, "cursor") == nil and Sessions.kept(db, other, "cursor") == "1")
  Worker.close(w)
end

--- A snippet runs the agent's own bash in its sandbox, and reads what it did as values: a command's output and how it
--- ended.
local function test_a_snippet_runs_the_agents_own_bash()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local context: Tools.Context = { cwd = dir, worker = w }
  local ran = Tools.run("run", { code = [[
local Host = require("cosmic.agent.host")
local r = Host.bash("printf 'a\\nb'; exit 3")
print(r.output, r.ok, r.code, r.timed_out, r.cut)
local slow = Host.bash("sleep 5", { timeout = 1 })
print(slow.ok, slow.timed_out)
local killed = Host.bash("kill -9 $$")
print(killed.code == nil, killed.signal)
local _, long = pcall(Host.bash, "true", { timeout = 10000000000 })
print(tostring(long))
]] }, context)
  assert(not ran.is_error and ran.text:find("a\nb\tfalse\t3\tfalse\tfalse\nfalse\ttrue\ntrue\t9\n", 1, true) ~= nil,
    ran.text)
  assert(ran.text:find("timeout is 10000000000: give 1 to", 1, true) ~= nil, ran.text)
  -- The calls the run tool's description shows check as written.
  local described = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\nprint(Host.modules())\n" ..
      "print(Host.docs(\"cosmic.fs\"))\nlocal Fs = require(\"cosmic.fs\")\n" ..
      "assert(Fs.write(\"described.txt\", \"x\"))\nprint(assert(Fs.read(\"described.txt\")), #assert(Fs.list(\".\")))\n" ..
      "print(if #Host.modules() > 0 then \"a\" else \"b\" end)\n" }, context)
  assert(not described.is_error, described.text)
  -- So does the description's example, the end of the description, on a directory of three files.
  local run_tool: Tools.Tool? = nil
  for _, t in ipairs(Tools.all()) do
    if t.name == "run" then run_tool = t end
  end
  local example = assert(assert(run_tool).description:match("For example:\n(.*)$"))
  assert(Fs.write(dir .. "/one.tl", "x\n"))
  assert(Fs.write(dir .. "/notes.txt", "x\n"))
  local shown_example = Tools.run("run", { code = example }, context)
  assert(not shown_example.is_error and shown_example.text:find("^txt 2\ntl 1\n") ~= nil, shown_example.text)
  -- Host, Fs and Json need no require; a snippet's own local of the name is its own, and the lines stay its own.
  local bare = Tools.run("run", { code = "print(#Host.find(\".\"), Json.quote(\"x\"), Fs.basename(\"/a/b\"))" }, context)
  assert(not bare.is_error and bare.text:find("^3\t\"x\"\tb\n") ~= nil, bare.text)
  local own = Tools.run("run", { code = "local Host = 7\nprint(Host + 1)" }, context)
  assert(not own.is_error and own.text:find("^8\n") ~= nil, own.text)
  local wrong = Tools.run("run", { code = "print(Host.find(\".\"))\nlocal n: integer = \"x\"\nprint(n)" }, context)
  assert(wrong.is_error and wrong.text:find(":2:", 1, true) ~= nil, wrong.text)
  -- A name in a string or a comment, a binding of the name, and a first line that begins with `(` all run.
  for code, said in pairs({ ["print(\"Host\") -- Fs.read is slow"] = "^Host\n",
      ["local function Host(): integer return 2 end\nprint(Host())"] = "^2\n",
      ["for _, Fs in ipairs({ 3 }) do print(Fs) end"] = "^3\n", ["(print)(Host.cat(\"one.tl\"))"] = "^x\n\n" }) do
    local r = Tools.run("run", { code = code }, context)
    assert(not r.is_error and r.text:find(said) ~= nil, code .. ": " .. r.text)
  end
  local commented = Tools.run("run", { code = "-- a note\n(print)(Host.cat(\"one.tl\"))" }, context)
  assert(not commented.is_error and commented.text:find("^x\n") ~= nil, commented.text)
  -- A hint that names a snippet's own line-1 local is the snippet's refusal, not the bare one's.
  local typo = Tools.run("run", { code = "local count = Host.wc(\"one.tl\")\nprint(cuont)" }, context)
  assert(typo.is_error and typo.text:find("cuont", 1, true) ~= nil and typo.text:find("`Host`", 1, true) == nil, typo.text)
  -- A `;` before a string or a table would join a call: it is not mended.
  local joined = Tools.run("run", { code = "local t: {string} = { tostring; \"a\" }\nprint(#t)" }, context)
  assert(joined.is_error and joined.text:find("(semicolon)", 1, true) ~= nil, joined.text)
  -- Beside a type error on its line, a `;` is told of with it.
  local both = Tools.run("run", { code = "local n: integer = \"x\"; print(n)" }, context)
  assert(both.is_error and both.text:find("(semicolon)", 1, true) ~= nil and
      both.text:find("(not_assignable)", 1, true) ~= nil, both.text)
  -- A refusal on line 1 tells the snippet's own column, not one the prelude moved.
  local first = Tools.run("run", { code = "local n: integer = Host.cat(\"one.tl\")" }, context)
  assert(first.is_error and first.text:find("run.tl:1:20:", 1, true) ~= nil, first.text)
  local huge = Tools.run("bash", { command = "true", timeout = 10000000000 }, context)
  assert(huge.is_error and huge.text:find("give at most", 1, true) ~= nil, huge.text)
  Worker.close(w)
end

--- A snippet reads sessions.db through the agent (Host.history), which answers it read-only, as the sql tool does, row by row.
local function test_a_snippet_queries_the_sessions_through_the_agent()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local db = assert(Sessions.open(dir .. "/sessions.db"))
  local id = assert(Sessions.start(db, "/", "m", 0))
  local _ = assert(Sessions.output(db, id, { tool = "bash", input = "{}", text = "a\xffb", is_error = false }))
  local context: Tools.Context = { cwd = dir, worker = w, db = db, session = id }
  local code = [[
local Host = require("cosmic.agent.host")
local rows = Host.history("SELECT tool, text, 1.5 AS r, NULL AS z, ?1 AS here FROM outputs")
local row = assert(rows[1])
print(row["tool"], row["text"], row["r"], row["z"] == require("cosmic.json").null, row["here"])
local refused, why = pcall(Host.history, "DELETE FROM outputs")
print(not refused, tostring(why))
local again = Host.history("SELECT count(*) AS n FROM outputs")
return assert(again[1])["n"]
]]
  local ran = Tools.run("run", { code = code }, context)
  assert(not ran.is_error, ran.text)
  assert(ran.text:find("bash\ta\u{FFFD}b\t1.5\ttrue\t" .. tostring(id) .. "\n", 1, true) ~= nil, ran.text)
  assert(ran.text:find("true\thost: history: not authorized", 1, true) ~= nil and ran.text:find("refuses a write", 1, true) ~= nil,
    ran.text)
  assert(ran.text:find("Returned: 1", 1, true) ~= nil, ran.text)
  local big = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\n" ..
      "local _, why = pcall(Host.history, \"SELECT printf('%.1000c', 'x') AS x FROM generate_series(1, 1000)\")\n" ..
      "return tostring(why)\n" }, context)
  assert(big.text:find("narrow the query", 1, true) ~= nil and big.text:find("after 5", 1, true) ~= nil, big.text)
  local other = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\n" ..
      "local _, why = Host.call(\"shell\", { command = \"id\" })\nreturn tostring(why)\n" }, context)
  assert(other.text:find("serves no call", 1, true) ~= nil and other.text:find("it serves history", 1, true) ~= nil, other.text)
  assert(w.started == 1, "one worker answered all")
  Worker.close(w)
  local _, _ = db:close()
end

--- What a query answers is held to JSON and to the reply's limit: no infinity, one column of a name, and control
--- characters counted as their escapes.
local function test_a_snippets_query_answer_is_held_to_json_and_its_limit()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local db = assert(Sessions.open(dir .. "/sessions.db"))
  local id = assert(Sessions.start(db, "/", "m", 0))
  local context: Tools.Context = { cwd = dir, worker = w, db = db, session = id }
  local function returned(query: string): string
    local r = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\n" ..
        "local ok, rows = pcall(Host.history, " .. Json.quote(query) .. ")\n" ..
        "if not ok then return tostring(rows) end\nreturn rows\n" }, context)
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
  Worker.close(w)
  local _, _ = db:close()
end

--- A query past the snippet's time is stopped between its rows, and the worker ended.
local function test_a_snippets_query_is_stopped_at_its_time()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local db = assert(Sessions.open(dir .. "/sessions.db"))
  local id = assert(Sessions.start(db, "/", "m", 0))
  local context: Tools.Context = { cwd = dir, worker = w, db = db, session = id }
  -- A query that runs past the snippet's time is stopped between its rows, and the worker ended.
  local slow = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\n" ..
      "local _, _ = pcall(Host.history, \"SELECT NULL AS n FROM generate_series(1, 1000000000000) WHERE value % 200000 = 0\")\n",
    timeout = 2 }, context)
  assert(slow.is_error and slow.text:find("ran past 2 seconds", 1, true) ~= nil, slow.text)
  Worker.close(w)
  local _, _ = db:close()
end

--- One query step that never ends by itself is stopped at the snippet's time too, and the agent is not held; a
--- worker with no agent to serve it refuses the call.
local function test_a_snippets_endless_query_step_is_stopped_at_its_time()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local db = assert(Sessions.open(dir .. "/sessions.db"))
  local id = assert(Sessions.start(db, "/", "m", 0))
  local context: Tools.Context = { cwd = dir, worker = w, db = db, session = id }
  -- One step that never ends by itself is stopped at the snippet's time too: the agent is not held.
  local began = Clock.monotonic_ns()
  local endless = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\n" ..
      "local _, why = pcall(Host.history, \"WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c\")\n" ..
      "return tostring(why)\n", timeout = 2 }, context)
  assert(endless.is_error or endless.text:find("time limit", 1, true) ~= nil, endless.text)
  assert(Clock.monotonic_ns() - began < Clock.seconds(20), "the query was stopped near the snippet's time")
  local served, _ = Worker.run(w, "local Host = require(\"cosmic.agent.host\")\nlocal _, why = pcall(Host.history, \"SELECT 1\")\n" ..
      "return tostring(why)\n", { cwd = dir, seconds = 30 })
  assert(served ~= nil and tostring(served["value"]):find("serves no call to this worker", 1, true) ~= nil, if served ~= nil then shown(served) else "nil" end)
  Worker.close(w)
  local _, _ = db:close()
end

--- Outside a worker no agent answers a call.
local function test_a_snippet_calls_an_mcp_servers_tools_as_typed_functions()
  local dir = assert(Fs.mkdtemp("agent-worker-mcp-module-"))
  local script = dir .. "/server.tl"
  assert(Fs.write(script, [=[
local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Server = require("cosmic.mcp.server")
return function(_: {string}): integer
  local server = Server.new{
    info = { name = "adder", version = "1" },
    tools = { {
      tool = { name = "twice", description = "Twice n, as a café counts.", inputSchema = Mcp.object_schema({ n = { type = "integer" } }, { "n" }) },
      call = function(args: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        local n = assert(math.tointeger(args["n"]))
        if n < 0 then return Mcp.result({ "n is negative" }, true) end
        return Mcp.result({ tostring(n * 2) })
      end,
    }, {
      tool = {
        name = "sum-up", description = "The sum of values.",
        inputSchema = Mcp.object_schema({ values = { type = "array", items = { type = "integer" } } }),
        outputSchema = Mcp.object_schema({ sum = { type = "integer" }, note = { type = { "string", "null" } } },
          { "sum" }),
      },
      call = function(args: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        local sum = 0
        for _, v in ipairs(Json.array_of(args["values"]) or {}) do sum = sum + assert(math.tointeger(v)) end
        return Mcp.structured({ sum = sum, note = Json.null })
      end,
    }, {
      tool = { name = "sum.up", description = "Files issues about each sum that is wrong. " .. string.rep("And more. ", 20),
        inputSchema = Mcp.object_schema({}) },
      call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        return Mcp.result({ "filed" })
      end,
    } },
  }
  assert(server:serve_stdio())
  return 0
end
]=]))
  local started = this_program.program({ "--standalone", script }, { env = this_program.environment(), timeout_ns = -1 })
  local config = assert(Json.encode({ servers = { adder = { command = Json.array(started.argv), sandbox = "off" } } }))
  assert(Fs.write(dir .. "/mcp.json", config))
  local set = AgentMcp.new(assert(AgentMcp.load(dir .. "/mcp.json")), dir)
  local w = set_of_worker()
  local context: Tools.Context = { cwd = dir, worker = w, mcp = set }
  local code = [[
local adder = require("mcp.adder")
print(adder.twice({ n = 21 }).text)
local _, why = pcall(adder.twice, { n = -1 })
print(tostring(why))
local summed = adder.sum_up({ values = { 1, 2, 3 } })
print(summed.sum, summed.note == nil)
print(adder.sum_up().sum)
print(adder.sum_up({ values = {} }).sum)
]]
  local ran = Tools.run("run", { code = code }, context)
  assert(not ran.is_error, ran.text)
  assert(ran.text:find("42\nmcp: adder.twice: n is negative\n6\ttrue\n0\n0\n", 1, true) ~= nil, ran.text)
  -- A wrong argument is the checker's to refuse, in the same worker, the module kept.
  local wrong = Tools.run("run", { code = "local adder = require(\"mcp.adder\")\nadder.twice({ n = \"x\" })\n" }, context)
  assert(wrong.is_error and wrong.text:find("run.tl:2:", 1, true) ~= nil, wrong.text)
  local missing = Tools.run("run", { code = "local adder = require(\"mcp.adder\")\nadder.twice({})\n" }, context)
  assert(missing.is_error and missing.text:find("run.tl:2:", 1, true) ~= nil, missing.text)
  local declared = Tools.run("run", { code = "return require(\"cosmic.agent.host\").declaration(\"adder\")" }, context)
  assert(declared.text:find("record TwiceInput", 1, true) ~= nil and declared.text:find("sum_up: function(arguments?: " ..
      "SumUpInput): SumUpOutput", 1, true) ~= nil, declared.text)
  -- A search finds a tool by a word of its name or its description, best first, and describe shows its Teal alone.
  local search = [[
local Host = require("cosmic.agent.host")
for _, query in ipairs({ "twice", "sum", "issue", "CAFÉ", "zebra" }) do
  local searched = Host.search(query)
  local names: mut {string} = {}
  for i, f in ipairs(searched.found) do names[i] = f.server .. "." .. f.name .. "=" .. f.tool end
  print(query, table.concat(names, ","), #searched.skipped)
end
local one = Host.search("sum", { limit = 1 }).found
local long = assert(Host.search("issue", { limit = 1 }).found[1])
print(#one, #long.about <= 160, long.about:sub(-3), long.teal:find("sum_up_2", 1, true) ~= nil, assert(one[1]).teal:find("function", 1, true) ~= nil)
local _, empty = pcall(Host.search, "!!")
print(empty)
for _, limit in ipairs({ 0, -1 }) do
  local _, why = pcall(Host.search, "sum", { limit = limit })
  print(why)
end
local _, none = pcall(Host.search, "sum", { server = "nope" })
print(none)
local dup = Host.describe("adder", "sum.up")
local by_name = Host.describe("adder", "sum_up_2")
print(dup == by_name, dup:find("sum_up_2: function", 1, true) ~= nil, dup:find("twice", 1, true) == nil)
local missing = Host.describe("adder", "nope")
print(missing)
]]
  local searched = Tools.run("run", { code = search }, context)
  assert(not searched.is_error, searched.text)
  local text = searched.text
  for _, part in ipairs({
      "twice\tadder.twice=twice\t0\n",
      "issue\tadder.sum_up_2=sum.up\t0\n",
      "CAFÉ\tadder.twice=twice\t0\n",
      "zebra\t\t0\n",
      "1\ttrue\t...\ttrue\ttrue\n",
      "host: search: the query has no word to look for",
      "host: search: limit is 0, below 1",
      "host: search: limit is -1, below 1",
      "host: search: no server listed its tools: nope:",
      "true\ttrue\ttrue\n",
      "host: describe: the server \"adder\" lists no tool \"nope\"",
  }) do
    assert(text:find(part, 1, true) ~= nil, "missing " .. part .. " in:\n" .. text)
  end
  -- Both tools named sum are found, and the one of no such word is not.
  assert(text:find("sum\tadder.sum_up=sum-up,adder.sum_up_2=sum.up\t0\n", 1, true) ~= nil or
      text:find("sum\tadder.sum_up_2=sum.up,adder.sum_up=sum-up\t0\n", 1, true) ~= nil, text)
  -- Tasks of a snippet call one server at once, each answered its own.
  local at_once = [[
local adder = require("mcp.adder")
local Poll = require("cosmic.poll")
local got: mut {integer: string} = {}
Poll.run(function()
  for i = 1, 3 do
    local _ = Poll.spawn(function() got[i] = adder.twice({ n = i }).text end)
  end
end)
print(got[1], got[2], got[3])
]]
  local parallel = Tools.run("run", { code = at_once }, context)
  assert(not parallel.is_error and parallel.text:find("2\t4\t6\n", 1, true) ~= nil, parallel.text)
  local unknown = Tools.run("run", { code = "local nope = require(\"mcp.nope\")\nprint(nope)\n" }, context)
  assert(unknown.is_error and unknown.text:find("require(\"mcp.nope\"): host: mcp.tools: no MCP server \"nope\"", 1,
    true) ~= nil, unknown.text)
  AgentMcp.close(set)
  Worker.close(w)
end

local function test_a_call_outside_a_worker_raises()
  Test.raises(function() Host.history("SELECT 1") end, "no agent answers here")
end

--- An MCP server of the agent, over stdio: a snippet names it, lists its tools and calls one, through the agent.
local function test_a_snippet_calls_an_mcp_server_through_the_agent()
  local dir = assert(Fs.mkdtemp("agent-worker-mcp-"))
  local script = dir .. "/server.tl"
  assert(Fs.write(script, [=[
local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Server = require("cosmic.mcp.server")
return function(_: {string}): integer
  local server = Server.new{
    info = { name = "adder", version = "1" },
    tools = { {
      tool = { name = "twice", description = "twice n", inputSchema = Mcp.object_schema({ n = { type = "integer" } }, { "n" }) },
      call = function(args: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        local n = math.tointeger(args["n"])
        if n == nil then return nil, Failure.new("n must be an integer") end
        return Mcp.result({ tostring(n * 2) })
      end,
    } },
  }
  assert(server:serve_stdio())
  return 0
end
]=]))
  local started = this_program.program({ "--standalone", script }, { env = this_program.environment(), timeout_ns = -1 })
  local config = assert(Json.encode({ servers = { adder = { command = Json.array(started.argv), sandbox = "off",
    description = "adds" } } }))
  assert(Fs.write(dir .. "/mcp.json", config))
  local servers = assert(AgentMcp.load(dir .. "/mcp.json"))
  local set = AgentMcp.new(servers, dir)
  local w = set_of_worker()
  local context: Tools.Context = { cwd = dir, worker = w, mcp = set }
  local code = [[
local Host = require("cosmic.agent.host")
local Json = require("cosmic.json")
local server = assert(Host.servers()[1])
print(server["name"], server["reached"], server["description"])
local tool = assert(Host.tools("adder")[1])
print(tool["name"], tool["description"])
local said = Host.mcp("adder", "twice", { n = 21 })
local content = assert(Json.to_array(said["content"]))
print(assert(Json.to_object(content[1]))["text"])
local failed = Host.mcp("adder", "twice", { n = "x" })
print(failed["isError"])
local _, missing = pcall(Host.mcp, "nope", "twice", {})
print(tostring(missing))
]]
  local ran = Tools.run("run", { code = code }, context)
  assert(not ran.is_error, ran.text)
  assert(ran.text:find("adder\tunsandboxed\tadds\ntwice\ttwice n\n42\n", 1, true) ~= nil, ran.text)
  assert(ran.text:find("\n42\ntrue\n", 1, true) ~= nil, ran.text)
  assert(ran.text:find("no MCP server \"nope\" (the servers: adder)", 1, true) ~= nil, ran.text)
  assert(set.handles["adder"] ~= nil, "the server runs until the session ends")
  AgentMcp.close(set)
  assert(set.handles["adder"] == nil)
  local none = Tools.run("run", { code = "local Host = require(\"cosmic.agent.host\")\n" ..
      "local _, why = pcall(Host.tools, \"adder\")\nreturn tostring(#Host.servers()) .. \" \" .. tostring(why)\n" },
    { cwd = dir, worker = w })
  assert(none.text:find("0 host: mcp.tools: no MCP server is configured", 1, true) ~= nil, none.text)
  Worker.close(w)
end

--- A snippet's request that gets no response raises in the snippet, naming the URL, as one of no http or https URL
--- does. The port is one nothing listens at, so the request fails whether or not the host has a network: a macOS
--- runner's tests may reach the internet, where a Linux one's have no network at all.
local function test_a_failed_fetch_raises_in_the_snippet()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local context: Tools.Context = { cwd = dir, worker = w }
  local ran = Tools.run("run", { code = "local _, none = pcall(Host.fetch, \"http://127.0.0.1:1/\", { timeout = 5 })\n" ..
      "print(tostring(none))\n" ..
      "local _, why = pcall(Host.fetch, \"file:///etc/passwd\")\nprint(tostring(why))\n" }, context)
  assert(not ran.is_error and ran.text:find("^host: fetch: http://127.0.0.1:1/: ") ~= nil, ran.text)
  assert(ran.text:find("give an http or https URL", 1, true) ~= nil, ran.text)
  Worker.close(w)
end

--- A snippet keeps a SQLite file and hashes in its own directory, with no program run.
local function test_a_snippet_uses_sqlite_and_hash()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local context: Tools.Context = { cwd = dir, worker = w }
  local ran = Tools.run("run", { code = "Host.sqlite(\"notes.db\", \"create table t (k text, v integer, n); \" ..\n" ..
      "  \"insert into t values ('a', 1, null)\")\n" ..
      "Host.sqlite(\"notes.db\", \"insert into t values (?1, ?2, ?3)\", { \"b\", 2, true })\n" ..
      "for _, r in ipairs(Host.sqlite(\"notes.db\", \"select k, v, n from t order by k\")) do\n" ..
      "  print(r[\"k\"], r[\"v\"], r[\"n\"] == Json.null)\nend\n" ..
      "Host.write(\"x.txt\", \"abc\")\nprint(Host.sha256(\"x.txt\"))\n" ..
      "local _, why = pcall(Host.sqlite, \"notes.db\", \"select nope from t\")\nprint(tostring(why))\n" }, context)
  assert(not ran.is_error and ran.text:find("^a\t1\ttrue\nb\t2\tfalse\n", 1) ~= nil, ran.text)
  assert(ran.text:find("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", 1, true) ~= nil, ran.text)
  assert(ran.text:find("host: sqlite: ", 1, true) ~= nil and ran.text:find("nope", 1, true) ~= nil, ran.text)
  Worker.close(w)
end

--- JSON of a known shape is read into records, as the run guide shows: a declared record is checked in a snippet
--- as in a file, and a key the record does not name is dropped.
local function test_a_snippet_reads_json_into_records()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local context: Tools.Context = { cwd = dir, worker = w }
  local ran = Tools.run("run", { code = "local Shape = require(\"cosmic.shape\")\n" ..
      "local record Item name: string count: integer end\n" ..
      "local record Page items: {Item} next?: integer end\n" ..
      "local body = '{\"items\": [{\"name\": \"x\", \"count\": 2, \"id\": 7}], \"next\": 2}'\n" ..
      "local page = assert(Shape.decode_into(body, Shape.record_of(\"Page\").spec))\n" ..
      "for _, item in ipairs(page.items) do print(item.name .. tostring(item.count)) end\n" ..
      "if page.next ~= nil then print(\"next \" .. tostring(page.next)) end\n" ..
      "local last = assert(Shape.decode_into('{\"items\": []}', Shape.record_of(\"Page\").spec))\n" ..
      "print(#last.items, last.next == nil)\n" }, context)
  assert(not ran.is_error and ran.text:find("^x2\nnext 2\n0\ttrue\n") ~= nil, ran.text)
  Worker.close(w)
end

--- Host.sort answers a new list the snippet may add to, so a list sorted in place of itself still checks.
local function test_a_snippet_sorts_a_list_into_itself_and_adds_to_it()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local context: Tools.Context = { cwd = dir, worker = w }
  local ran = Tools.run("run", { code = "local rows: mut {string} = { \"b\", \"a\" }\n" ..
      "rows = Host.sort(rows)\nrows[#rows + 1] = \"c\"\nprint(table.concat(rows, \",\"))\n" }, context)
  assert(not ran.is_error and ran.text:find("^a,b,c\n") ~= nil, ran.text)
  Worker.close(w)
end
