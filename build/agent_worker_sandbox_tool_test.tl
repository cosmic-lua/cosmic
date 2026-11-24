--- `cosmic agent worker` under the sandbox of cosmic agent's tools ([`cosmic.agent.policy`]): a snippet writes in the
--- working directory and reaches nothing outside it.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Policy = require("cosmic.agent.policy")
local Test = require("cosmic.test")
local Worker = require("cosmic.agent.worker")

--- This program, which the worker runs, and a root of its own for it, which needs the nest promise.
Test.policy{ profiles = { "cosmic", "system" }, grants = { { path = "o/bin", letters = "rx" } }, env = { "PATH", "TMPDIR" },
  promises = { "nest" }, requires = { "nest" } }

--- `answer` as JSON text, for an assertion's message.
local function shown(answer: Worker.Answer): string
  local text, _ = Json.encode(answer)
  return text or "?"
end

--- Under the agent's sandbox a snippet writes in the working directory and reaches nothing outside it.
local function test_a_snippet_is_held_to_the_sandbox_of_the_tools()
  local dir, outside = assert(Fs.mkdtemp("agent-worker-")), assert(Fs.mkdtemp("agent-worker-outside-"))
  assert(Fs.write(outside .. "/secret", "no"))
  local p = assert(Policy.of(dir, { mode = "write", network = false, grants = {} }))
  local w = Worker.new()
  local wrote = assert(Worker.run(w, "local Fs = require(\"cosmic.fs\")\nlocal wrote, _ = Fs.write(\"made.txt\", \"yes\")\nreturn wrote\n",
    { cwd = dir, policy = p, seconds = 60 }))
  local made, _ = Fs.read(dir .. "/made.txt")
  assert(wrote["value"] == true and made == "yes", shown(wrote))
  local read = assert(Worker.run(w, "local Fs = require(\"cosmic.fs\")\nlocal body, _ = Fs.read(\"" .. outside ..
      "/secret\")\nreturn body == nil\n", { cwd = dir, policy = p, seconds = 60 }))
  assert(read["value"] == true, shown(read))
  Worker.close(w)
end

--- With no commands, a snippet starts no process and runs no file: Host.bash and Child.run fail, and the snippet
--- itself still runs.
local function test_a_snippet_of_no_commands_runs_no_program()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  -- A grant of `x` alone, which holds nothing with no commands, does not keep the worker from starting.
  local p = assert(Policy.of(dir, { mode = "write", network = false, grants = { { path = "/usr/bin", letters = "x" } } }))
  local w = Worker.new()
  local code = "local Host = require(\"cosmic.agent.host\")\nlocal Child = require(\"cosmic.child\")\n" ..
    "local bashed, _ = pcall(Host.bash, \"echo ran > ran.txt\")\n" ..
    "local res, _ = Child.run({ \"/bin/sh\", \"-c\", \"echo ran > ran.txt\" }, { timeout_ns = 10000000000 })\n" ..
    "return { bashed = bashed, ran = res ~= nil and res.ok }\n"
  -- With commands, the same snippet runs both, so it is the policy that holds the one without.
  local free = Worker.new()
  local with = assert(Worker.run(free, code, { cwd = dir, policy = p, seconds = 60 }))
  local both, _ = Json.to_object(with["value"])
  assert(both ~= nil and both["bashed"] == true and both["ran"] == true, shown(with))
  Worker.close(free)
  assert(Fs.remove(dir .. "/ran.txt"))
  local answer = assert(Worker.run(w, code, { cwd = dir, policy = p, seconds = 60, commands = false }))
  local value, _ = Json.to_object(answer["value"])
  assert(value ~= nil, shown(answer))
  local ran, _ = Fs.read(dir .. "/ran.txt")
  assert(answer["ok"] == true and value["bashed"] == false and value["ran"] == false and ran == nil, shown(answer))
  Worker.close(w)
end
