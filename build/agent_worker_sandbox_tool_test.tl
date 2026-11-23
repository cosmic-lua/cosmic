--- `cosmic agent worker` under the sandbox of cosmic agent's tools ([`cosmic.agent.policy`]): a snippet writes in the
--- working directory and reaches nothing outside it.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Policy = require("cosmic.agent.policy")
local Test = require("cosmic.test")
local Worker = require("cosmic.agent.worker")

--- This program, which the worker runs, and a root of its own for it, which needs the nest promise.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } }, env = { "PATH", "TMPDIR" },
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
