--- `cosmic agent worker` under the sandbox of cosmic agent's tools ([`cosmic.agent.policy`]): a snippet writes in the
--- working directory and reaches nothing outside it.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Policy = require("cosmic.agent.policy")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
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
  -- Under another policy the next run starts a new worker; under the same one it runs on.
  assert(w.started == 1, tostring(w.started))
  local narrower = assert(Policy.of(dir, { mode = "read", network = false, grants = {} }))
  local refused = assert(Worker.run(w, "local Fs = require(\"cosmic.fs\")\nlocal wrote, _ = Fs.write(\"again.txt\", \"no\")\n" ..
      "return wrote == false\n", { cwd = dir, policy = narrower, seconds = 60 }))
  assert(refused["value"] == true and w.started == 2, shown(refused))
  assert(Worker.run(w, "return 1\n", { cwd = dir, policy = narrower, seconds = 60 }))
  assert(w.started == 2, tostring(w.started))
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
  -- Nor may the worker become another program: execve itself is refused, and the worker answers on.
  local exec = "local sys = require(\"cosmic.sys\")\n" ..
    "local done, _, errno = sys.execve(\"/bin/sh\", { \"/bin/sh\", \"-c\", \"echo ran > ran.txt\" }, {})\n" ..
    "return not done and (errno == sys.EPERM or errno == sys.EACCES)\n"
  local refused = assert(Worker.run(w, exec, { cwd = dir, policy = p, seconds = 60, commands = false }))
  local after, _ = Fs.read(dir .. "/ran.txt")
  assert(refused["ok"] == true and refused["value"] == true and after == nil, shown(refused))
  assert(w.started == 1, tostring(w.started))
  Worker.close(w)
end

--- A policy stacked of layers that each grant this program's own file, and name no profile, still starts the worker
--- of no commands, and the grant loses its `x`: the worker cannot run that file.
local function test_layers_that_grant_this_program_start_a_worker_of_no_commands_that_cannot_run_it()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  local own = assert(Proc.executable())
  local base = assert(Policy.of(dir, { mode = "write", network = false, grants = {} }))
  local layer = assert(Sandbox.union(base, { grants = { { path = own, letters = "rx" } } }))
  local p = assert(Sandbox.intersect(layer, layer))
  local granted = false
  for _, grant in ipairs(Sandbox.paths(p)) do
    if grant.path == own and grant.letters:find("x", 1, true) ~= nil then granted = true end
  end
  assert(granted and p.profiles == nil, "the layers grant this program")
  local w = Worker.new()
  local code = "local Proc = require(\"cosmic.proc\")\nlocal sys = require(\"cosmic.sys\")\n" ..
    "local done, _, errno = sys.execve(assert(Proc.executable()), { \"cosmic\", \"--version\" }, {})\n" ..
    "return not done and (errno == sys.EPERM or errno == sys.EACCES)\n"
  local answer = assert(Worker.run(w, code, { cwd = dir, policy = p, seconds = 60, commands = false }))
  assert(answer["ok"] == true and answer["value"] == true, shown(answer))
  Worker.close(w)
end
