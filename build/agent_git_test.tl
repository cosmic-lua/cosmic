--- Under --sandbox write, a snippet's `.git` is read alone ([`cosmic.agent.policy`]): no write of it, by any call,
--- sets a hook, a filter or a config a git program run later would obey. Host.git_add and Host.git_commit still
--- commit, since the agent's own process serves them (cosmic/agent/tools.tl); under --sandbox read they are refused.
local Fs = require("cosmic.fs")
local Git = require("cosmic.git")
local Policy = require("cosmic.agent.policy")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")
local Worker = require("cosmic.agent.worker")

--- This program, which the worker runs, and a root of its own for it, which needs the nest promise.
Test.policy{ profiles = { "cosmic", "system" }, grants = { { path = "o/bin", letters = "rx" }, { calls = "nest" } },
  env = { "PATH", "TMPDIR" }, requires = { "nest" } }

--- A repository at `dir` with one commit of a.txt and b.txt.
local function repository(dir: string)
  assert(Fs.mkdirs(dir .. "/.git/objects"))
  assert(Fs.mkdirs(dir .. "/.git/refs/heads"))
  assert(Fs.mkdirs(dir .. "/.git/hooks"))
  assert(Fs.write(dir .. "/.git/HEAD", "ref: refs/heads/main\n"))
  assert(Fs.write(dir .. "/.git/config", "[core]\n\trepositoryformatversion = 0\n\tbare = false\n" ..
      "[user]\n\tname = Test\n\temail = test@example.com\n"))
  assert(Fs.write(dir .. "/a.txt", "one\n"))
  assert(Fs.write(dir .. "/b.txt", "two\n"))
  local who: Git.Person = { name = "Test", email = "test@example.com", time = 1767225900, tz = "+0000" }
  local repo = assert(Git.open(dir))
  assert(repo:add({ "a.txt", "b.txt" }))
  assert(repo:commit({ message = "first", author = who, committer = who }))
end

local SNIPPET <const> = [[
local Host = require("cosmic.agent.host")
local Fs = require("cosmic.fs")
local wrote_config, _ = Fs.write(".git/config", "[core]\n\thooksPath = /tmp\n")
local wrote_hook, _ = Fs.write(".git/hooks/pre-commit", "#!/bin/sh\n")
Host.write("a.txt", "one\nmore\n")
Host.write("b.txt", "two\nmore\n")
Host.git_add({ "a.txt" })
local oid = Host.git_commit("a: add more")
return { config = wrote_config == true, hook = wrote_hook == true, oid = oid }
]]

local function test_a_snippet_commits_but_cannot_write_dot_git()
  local dir = assert(Fs.mkdtemp("agent-git-"))
  repository(dir)
  local w = Worker.new()
  local context: Tools.Context = { cwd = dir, worker = w,
    policy = assert(Policy.of(dir, { mode = "write", network = false, grants = {} })) }
  local r = Tools.run("run", { code = SNIPPET }, context)
  Worker.close(w)
  assert(not r.is_error, r.text .. " config: " .. Fs.read(dir .. "/.git/config")!)
  assert(r.text:find('"config":false', 1, true) ~= nil and r.text:find('"hook":false', 1, true) ~= nil, r.text)
  assert(Fs.read(dir .. "/.git/config")!:find("hooksPath", 1, true) == nil)
  assert(not Fs.status(dir .. "/.git/hooks/pre-commit")!.exists)
  local repo = assert(Git.open(dir))
  local log = assert(repo:log({ limit = 1 }))
  assert(log[1]!.message == "a: add more\n" and r.text:find(log[1]!.oid, 1, true) ~= nil, r.text)
  local status = assert(repo:status())
  assert(#status.staged == 0 and #status.unstaged == 1 and status.unstaged[1]!.path == "b.txt", "b.txt left alone")
end

local function test_a_read_only_session_commits_nothing()
  local dir = assert(Fs.mkdtemp("agent-git-"))
  repository(dir)
  local w = Worker.new()
  local context: Tools.Context = { cwd = dir, worker = w,
    policy = assert(Policy.of(dir, { mode = "read", network = false, grants = {} })) }
  local r = Tools.run("run", { code = "require(\"cosmic.agent.host\").git_add({ \"a.txt\" })" }, context)
  Worker.close(w)
  assert(r.is_error and r.text:find("read the working directory alone", 1, true) ~= nil, r.text)
end
