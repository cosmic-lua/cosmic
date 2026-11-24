--- The MCP config of cosmic agent ([`cosmic.agent.mcp`]): what it takes and what it refuses.
local AgentMcp = require("cosmic.agent.mcp")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local type Failure = require("cosmic.failure")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")

--- A server that never answers, and one that ends saying why: the system's programs.
Test.policy{ profiles = { "system" } }

--- The servers of the config `text`, or why there are none, as a test reads it.
local function loaded(tmp: string, text: string): ({AgentMcp.Server}) | (nil, Failure)
  local path = tmp .. "/mcp.json"
  assert(Fs.write(path, text))
  return AgentMcp.load(path)
end

local function test_a_config_names_servers_over_stdio_and_http_sandboxed_by_default(tmp: string)
  local servers = assert(loaded(tmp, [[{"servers": {
    "notes": {"command": ["/usr/bin/notes-mcp", "--dir", "/n"], "description": "my notes",
              "policy": {"grants": [{"path": "/tmp", "letters": "r"}], "env": ["NOTES_KEY"]}},
    "docs": {"url": "https://docs.example.com/mcp"},
    "mine": {"command": ["/opt/srv"], "sandbox": "off"}
  }}]]))
  assert(#servers == 3)
  local docs, mine, notes = servers[1], servers[2], servers[3]
  assert(docs.name == "docs" and docs.url == "https://docs.example.com/mcp" and docs.policy == nil)
  assert(mine.name == "mine" and mine.policy == nil and assert(mine.command)[1] == "/opt/srv")
  assert(notes.name == "notes" and notes.description == "my notes" and assert(notes.command)[3] == "/n")
  local policy = assert(notes.policy)
  assert(policy.tmp == true and assert(policy.env)[1] == "NOTES_KEY", "the config's policy is merged with the default")
  local granted = false
  for _, grant in ipairs(policy.grants or {}) do
    if grant.path == "/tmp" then granted = true end
  end
  assert(granted and #(policy.grants or {}) > 1, "the system profile's grants are merged in")
  local bare = assert(loaded(tmp, '{"servers": {"plain": {"command": ["/p"]}}}'))
  local held = assert(assert(bare[1]).policy)
  assert(held.tmp == true and (held.connect == nil or #held.connect == 0) and (held.env == nil or #held.env == 0),
    "a server with no policy is held to the default: no host, no key")
  local set = AgentMcp.new(servers, tmp)
  local listed, _ = Json.encode(AgentMcp.listed(set))
  assert(listed == '[{"name":"docs","reached":"http"},{"name":"mine","reached":"unsandboxed"},' ..
      '{"description":"my notes","name":"notes","reached":"sandboxed"}]', listed)
end

local function test_a_config_it_cannot_follow_is_refused_naming_what(tmp: string)
  local cases: {{string}} = {
    { "not json", "mcp config:" },
    { '{"servers": {}, "extra": 1}', "no such key \"extra\"" },
    { '{"servers": []}', "servers: want an object" },
    { '{"servers": {"Bad-Name": {"command": ["x"]}}}', "a name is lower-case" },
    { '{"servers": {"a": {}}}', "give one of command and url" },
    { '{"servers": {"a": {"command": ["x"], "url": "https://x"}}}', "give one of command and url" },
    { '{"servers": {"a": {"command": []}}}', "want a list of strings" },
    { '{"servers": {"a": {"command": ["/x", 1]}}}', "want a list of strings" },
    { '{"servers": {"a": {"url": "ftp://x"}}}', "want an http:// or https:// URL" },
    { '{"servers": {"a": {"url": "https://x", "sandbox": "off"}}}', "takes no policy and no sandbox" },
    { '{"servers": {"a": {"command": ["/x"], "sandbox": "maybe"}}}', "want \"on\" or \"off\"" },
    { '{"servers": {"a": {"command": ["/x"], "sandbox": "off", "policy": {}}}}', "the sandbox off takes no policy" },
    { '{"servers": {"a": {"command": ["/x"], "policy": {"grants": [{"path": "/", "letters": "xr"}]}}}}', "servers.a.policy:" },
    { '{"servers": {"a": {"command": ["/x"], "tools": 1}}}', "no such key \"tools\"" },
  }
  for _, case in ipairs(cases) do
    local text, want = assert(case[1]), assert(case[2])
    local servers, why = loaded(tmp, text)
    assert(servers == nil and tostring(why):find(want, 1, true) ~= nil, text .. " -> " .. tostring(why))
  end
  local none, why = AgentMcp.load(tmp .. "/missing.json")
  assert(none == nil and tostring(why):find("missing.json", 1, true) ~= nil, tostring(why))
end

local function test_a_server_not_configured_is_named_so(tmp: string)
  local set = AgentMcp.new({}, tmp)
  local tools, why = AgentMcp.tools(set, "nope")
  assert(tools == nil and tostring(why):find("none is configured", 1, true) ~= nil, tostring(why))
  local other = AgentMcp.new(assert(loaded(tmp, '{"servers": {"a": {"command": ["/x"]}}}')), tmp)
  local called, called_why = AgentMcp.call(other, "b", "t", {})
  assert(called == nil and tostring(called_why):find("the servers: a", 1, true) ~= nil, tostring(called_why))
  AgentMcp.close(other)
end

--- A program is named by its absolute path, and one in the working directory, which the tools write, is not run.
local function test_a_program_the_tools_could_write_is_not_run(tmp: string)
  for _, program in ipairs({ "./srv", "srv", "bin/srv" }) do
    local servers, why = loaded(tmp, '{"servers": {"a": {"command": ["' .. program .. '"], "sandbox": "off"}}}')
    assert(servers == nil and tostring(why):find("absolute path", 1, true) ~= nil, program .. ": " .. tostring(why))
  end
  local planted = tmp .. "/srv"
  assert(Fs.write(planted, "#!/bin/sh\n"))
  local set = AgentMcp.new(assert(loaded(tmp, '{"servers": {"a": {"command": ["' .. planted .. '"], "sandbox": "off"}}}')),
    tmp)
  local tools, why = AgentMcp.tools(set, "a")
  assert(tools == nil and tostring(why):find("lies in the working directory", 1, true) ~= nil, tostring(why))
  assert(set.handles["a"] == nil)
end

--- A call cut off before its answer (the snippet's time ran out) ends its server, which may be out of step, and the
--- next call starts another, rather than read the answer the first was owed.
local function test_a_call_cut_off_ends_its_server(tmp: string)
  local usr, _ = Fs.status("/usr/bin/sleep")
  local sleep = if usr ~= nil and usr.exists then "/usr/bin/sleep" else "/bin/sleep" end
  local set = AgentMcp.new(assert(loaded(tmp, '{"servers": {"s": {"command": ["' .. sleep .. '", "1000"], ' ..
      '"sandbox": "off"}}}')), tmp)
  local said = "no answer"
  local started = false
  Poll.within(function()
    local task = Poll.spawn(function()
      local _, why = AgentMcp.tools(set, "s")
      said = tostring(why)
    end)
    local _, _ = task:join(Clock.ms(300))
    started = set.handles["s"] ~= nil and set.busy["s"] == true
    task:cancel()
    local _, _ = task:join()
  end)
  assert(started, "the server ran, a call out to it")
  assert(said:find("cancelled", 1, true) ~= nil, said)
  assert(set.handles["s"] == nil and set.sessions["s"] == nil and set.busy["s"] == nil, "the server cut off was ended")
  AgentMcp.close(set)
end

--- It writes much before it ends; only the end is kept and told.
local function test_a_server_that_ends_unanswered_tells_the_end_of_its_standard_error(tmp: string)
  local script = "read line; i=0; while [ $i -lt 8000 ]; do echo noise $i >&2; i=$((i+1)); done; " ..
    "echo 'boom: no token in NOTES_TOKEN' >&2; exit 3"
  local set = AgentMcp.new(assert(loaded(tmp, '{"servers": {"s": {"command": ["/bin/sh", "-c", ' ..
      Json.quote(script) .. '], "sandbox": "off"}}}')), tmp)
  local _, why = AgentMcp.tools(set, "s")
  local said = tostring(why)
  assert(said:find("the end of its standard error: ...", 1, true) ~= nil, said)
  assert(said:find("boom: no token in NOTES_TOKEN\n", 1, true) ~= nil, said)
  assert(#said < 1400, "only the end is told: " .. tostring(#said))
  assert(set.handles["s"] == nil and set.tails["s"] == nil, "the server was ended and its tail let go")
  AgentMcp.close(set)
end
