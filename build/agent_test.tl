--- `cosmic agent` (build/agent.tl), run in this process against a
--- stand-in Messages API ([`build.agent_fixture`]), its standard streams,
--- environment and data directory stood in for. A run that names no
--- --sandbox runs its tools with none: a sandbox nested in the worker
--- needs the whole system in the test's key, and
--- cosmic/agent/policy_test.tl holds the tools to one already.

local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Clock = require("cosmic.clock")
local Json = require("cosmic.json")
local Test = require("cosmic.test")
local agent = require("build.agent")
local agent_fixture = require("build.agent_fixture")

-- The host programs the tests start, each where hosts keep it: named,
-- not the whole system, so the key holds them alone. /bin/sh is the
-- shell the bash tool falls back to on a host with no bash (Alpine's
-- busybox, which its sleep, seq, head and tr link to as well).
Test.policy{
  grants = {
    { path = "/bin/bash", letters = "r" }, { path = "/usr/bin/bash", letters = "r" },
    { path = "/bin/sh", letters = "r" },
    { path = "/bin/sleep", letters = "r" }, { path = "/usr/bin/sleep", letters = "r" },
  },
  env = { "PATH", "TMPDIR" },
}

local type Api = agent_fixture.Api
local bash_call = agent_fixture.bash_call
local said = agent_fixture.said
local scratch = agent_fixture.scratch
local sent = agent_fixture.sent
local slurp = agent_fixture.slurp
local text_reply = agent_fixture.text_reply

--- What a run printed, and its exit status.
local record Ran
  code: integer
  out: string
  err: string
end

-- The directory that stands in for HOME, and holds the data and cache
-- directories under it: each test's own, made as it starts.
local home = ""

local KEYED <const>: {string: string} = { ANTHROPIC_API_KEY = "k", ANTHROPIC_BASE_URL = "https://api.test" }

--- How a run waits for each line typed: `wait` returns, call by call, whether a line
--- came, and moves `now` on by what it waited.
local record Waited
  answers: {boolean}
  mut now: integer
  mut asked: integer
end

--- Runs `cosmic agent` with `argv`, `env` (and HOME), the API's
--- `replies`, the lines `typed` at each prompt, and the lines
--- `meanwhile` typed while the model works (standard input a terminal
--- where it is given).
local function cli(argv: {string}, env: {string: string}, replies: {Json.Value}, typed?: {string},
                   meanwhile?: {string}, waited?: Waited): Ran, Api
  if home == "" then home = scratch() end
  local a = agent_fixture.api(replies)
  local early: mut {string} = {}
  for _, line in ipairs(meanwhile or {}) do early[#early + 1] = line end
  local out: mut {string} = {}
  local err: mut {string} = {}
  local at = 0
  local full: mut {string} = { "agent" }
  local named, picked = false, false
  for _, word in ipairs(argv) do
    full[#full + 1] = word
    if word == "--sandbox" then named = true end
    if word == "--tools" then picked = true end
  end
  local runs = { ask = true, chat = true, resume = true, rpc = true }
  if not named and runs[argv[1] or ""] == true then full[#full + 1] = "--sandbox=off" end
  -- The scripted replies call every tool, bash among them, which the default leaves out.
  if not picked and runs[argv[1] or ""] == true then full[#full + 1] = "--tools=all" end
  local code = agent.run(full, {
    out = function(line: string) out[#out + 1] = line end,
    err = function(line: string) err[#err + 1] = line end,
    read_line = function(_: string): string?
      at = at + 1
      return (typed or {})[at]
    end,
    read_all = function(): string return "from stdin" end,
    typed = function(): string? return table.remove(early, 1) end,
    hold = function(): agent.Hold
      return { caught = function(): integer return 0 end, release = function() end }
    end,
    tty = function(): boolean return meanwhile ~= nil end,
    wait = if waited == nil then nil else function(ns: integer): boolean
      waited.asked = waited.asked + 1
      local came = waited.answers[waited.asked]
      if came ~= true then waited.now = waited.now + ns end
      return came == true
    end end,
    now = if waited == nil then nil else function(): integer return waited.now end end,
    env = function(name: string): string?
      if name == "HOME" then return home end
      return env[name]
    end,
    send = a.send,
  })
  return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }, a
end

--- While chat waits for a line, a warm request goes out every 4.5
--- minutes, asking for nothing, and none after an hour idle.
local function test_chat_keeps_the_cache_warm_while_it_waits()
  local warm: Json.Value = { id = "msg_w", model = "m", content = Json.array(), stop_reason = "max_tokens",
    usage = { input_tokens = 0, output_tokens = 0, cache_read_input_tokens = 10 } }
  -- The first wait after a turn sees two warm requests, then a line; the
  -- second sees no line, and warm requests stop at the hour: 13 of them.
  local replies: mut {Json.Value} = { text_reply("one"), warm, warm, text_reply("two") }
  for _ = 1, 13 do replies[#replies + 1] = warm end
  local answers: mut {boolean} = { false, false, true }
  for _ = 1, 20 do answers[#answers + 1] = false end
  local waited: Waited = { answers = answers, now = Clock.now_ns(), asked = 0 }
  local r, a = cli({ "chat" }, KEYED, replies, { "first", "second" }, nil, waited)
  assert(r.code == 0 and r.out == "one\ntwo" and r.err == "", r.out .. r.err)
  -- Before the first prompt nothing was sent, so nothing waited.
  assert(#a.sent == 17 and waited.asked == 3 + 14, tostring(#a.sent) .. " " .. tostring(waited.asked))
  for _, i in ipairs({ 2, 3, 5, 17 }) do
    local w = sent(a, i)
    local messages = assert(Json.to_array(w["messages"]))
    assert(w["max_tokens"] == 0 and w["stream"] == false, said(a, i))
    -- To the user's last word: the model's reply is left out.
    assert(#messages == (if i < 4 then 1 else 3 end), said(a, i))
  end
  -- --keep-warm 0 sends none; a value not whole minutes is refused.
  r, a = cli({ "chat", "--keep-warm", "0" }, KEYED, { text_reply("one") }, { "first" }, nil,
    { answers = { false }, now = Clock.now_ns(), asked = 0 })
  assert(r.code == 0 and #a.sent == 1, r.err)
  assert(cli({ "chat", "--keep-warm", "1.5" }, KEYED, {}).code == Flags.REFUSED)
  -- rpc tells each warm request as a request event.
  r, a = cli({ "rpc" }, KEYED, { text_reply("one"), warm }, { '{"type":"prompt","text":"first"}' }, nil,
    { answers = { false, true }, now = Clock.now_ns(), asked = 0 })
  assert(r.code == 0 and #a.sent == 2 and r.out:find('"warm":true', 1, true) ~= nil, r.out .. r.err)
  -- A warm request the API refuses is said, and no more are sent.
  r, a = cli({ "chat" }, KEYED, { text_reply("one"), "400 bad" }, { "first" }, nil,
    { answers = { false, false }, now = Clock.now_ns(), asked = 0 })
  assert(r.code == 0 and #a.sent == 2 and r.err:find("chat: keeping the cache warm: HTTP 400: 400 bad", 1, true) ~= nil,
    r.err)
end

local function test_ask_and_chat()
  home = scratch()
  local r = cli({ "ask", "hello" }, {}, {})
  assert(r.code == Flags.REFUSED and r.err:find("ANTHROPIC_API_KEY") ~= nil, r.err)
  local a: Api
  r, a = cli({ "ask", "--effort", "low", "hello", "there" }, KEYED, {
    { content = { { type = "tool_use", id = "t", name = "bash", input = { command = "true" } } }, stop_reason = "tool_use" },
    text_reply("hi back"),
  })
  assert(r.code == 0 and r.out == "hi back", r.out .. r.err)
  assert(r.err:find("bash true", 1, true) ~= nil, r.err)
  assert(said(a, 1):find('"hello there"', 1, true) ~= nil, said(a, 1))
  r, a = cli({ "ask" }, KEYED, { text_reply("ok") })
  assert(r.code == 0 and said(a, 1):find("from stdin", 1, true) ~= nil)
  r = cli({ "ask", "--effort", "lots", "x" }, KEYED, {})
  assert(r.code == Flags.REFUSED and r.err:find("--effort") ~= nil, r.err)
  r = cli({ "ask", "x" }, KEYED, { text_reply("no", "refusal") })
  assert(r.code == Flags.FAILED and r.err:find("refused") ~= nil, r.err)
  r = cli({ "ask", "x" }, KEYED, { { content = { { type = "tool_use", id = "t", name = "read",
    input = { path = "/no/such/file" } } }, stop_reason = "tool_use" }, text_reply("gone") })
  assert(r.code == 0 and r.err:find("read failed", 1, true) ~= nil, r.err)
  -- --tools shows the model those tools alone, and a name no tool has is refused before any request.
  r, a = cli({ "ask", "--tools", "run,read", "x" }, KEYED, { text_reply("ok") })
  local body = assert(a.bodies[1])
  assert(r.code == 0 and body:find('"name":"read"', 1, true) ~= nil and body:find('"name":"bash"', 1, true) == nil,
    body)
  r, a = cli({ "ask", "--tools", "nope", "x" }, KEYED, {})
  assert(r.code ~= 0 and #a.sent == 0 and r.err:find("--tools: no tool nope", 1, true) ~= nil, r.err)
  r, a = cli({ "chat" }, KEYED, { text_reply("one"), "down", text_reply("three") },
    { "first", "", "second", "third", "/exit", "never" })
  assert(r.code == 0 and r.out == "one\nthree" and r.err:find("HTTP 500") ~= nil, r.out .. r.err)
  assert(#a.sent == 3)
  assert(cli({ "chat", "words" }, KEYED, {}).code == Flags.REFUSED)
  assert(cli({ "chat" }, {}, {}).code == Flags.REFUSED)
end

local function test_json_rpc_and_resume_on_the_command_line()
  home = scratch()
  local r = cli({ "ask", "--json", "hi" }, KEYED, { { content = { bash_call("t", "true") }, stop_reason = "tool_use" },
    text_reply("there") })
  local lines: mut {string} = {}
  for line in (r.out .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  assert(r.code == 0 and assert(lines[1]):find('^{"id":%d+,"type":"session"}$') ~= nil, r.out)
  assert(r.out:find('{"input":{"command":"true"},"name":"bash","type":"tool"}', 1, true) ~= nil, r.out)
  assert(r.out:find('{"is_error":false,"name":"bash","type":"result"}', 1, true) ~= nil, r.out)
  assert(lines[#lines] == '{"ok":true,"type":"end"}', r.out)
  assert(r.out:find('"error":""', 1, true) == nil, r.out)
  assert(r.err == "" and r.out:find('"type":"request"', 1, true) ~= nil, r.err)
  -- A run that fails leaves its turn to resume.
  r = cli({ "ask", "fails" }, KEYED, { "down" })
  assert(r.code == Flags.FAILED)
  local a: Api
  r, a = cli({ "resume" }, KEYED, { text_reply("resumed") })
  assert(r.code == 0 and r.out == "resumed" and said(a, 1):find('"fails"', 1, true) ~= nil, r.out .. r.err)
  r = cli({ "resume" }, KEYED, {})
  assert(r.code == 0 and r.err:find("no unfinished turn") ~= nil, r.err)
  assert(cli({ "resume", "x" }, KEYED, {}).code == Flags.REFUSED)
  -- ask --continue finishes the unfinished turn first.
  assert(cli({ "ask", "fails again" }, KEYED, { "down" }).code == Flags.FAILED)
  r, a = cli({ "ask", "--continue", "next" }, KEYED, { text_reply("one"), text_reply("two") })
  assert(r.code == 0 and r.out == "one\ntwo" and #a.sent == 2, r.out .. r.err)
  -- rpc: commands on stdin, events on stdout.
  r, a = cli({ "rpc" }, KEYED, { { content = { bash_call("t1", "echo a"), bash_call("t2", "echo b") },
    stop_reason = "tool_use" }, text_reply("steered"), text_reply("followed") },
    { '{"type":"prompt","text":"go"}', "", "nonsense", '{"type":"nothing"}' },
    { '{"type":"steer","text":"stop that"}', '{"type":"follow_up","text":"then this"}' })
  assert(r.code == 0 and #a.sent == 3, r.out .. r.err)
  assert(said(a, 2):find('"stop that"', 1, true) ~= nil and said(a, 3):find('"then this"', 1, true) ~= nil)
  assert(r.out:find('"unfinished":false', 1, true) ~= nil and r.out:find("not a JSON object", 1, true) ~= nil)
  assert(r.out:find("not a command", 1, true) ~= nil, r.out)
  r, a = cli({ "rpc" }, KEYED, {}, { '{"type":"prompt","text":" "}' })
  assert(#a.sent == 0 and r.out:find("not a command", 1, true) ~= nil, r.out)
  r, a = cli({ "rpc" }, KEYED, { { content = { bash_call("t1", "echo a"), bash_call("t2", "echo b") },
    stop_reason = "tool_use" } }, { '{"type":"prompt","text":"go"}' }, { '{"type":"abort"}' })
  assert(r.code == 0 and #a.sent == 0 and r.out:find('"error":"stopped by the user","ok":false', 1, true) ~= nil,
    r.out)
  r = cli({ "rpc", "--continue" }, KEYED, { text_reply("x") }, { '{"type":"resume"}' })
  assert(r.out:find('"error":"no unfinished turn"', 1, true) ~= nil, r.out)
  assert(cli({ "rpc", "x" }, KEYED, {}).code == Flags.REFUSED)
  -- chat at a terminal: a line typed meanwhile steers; /later waits for the turn.
  r, a = cli({ "chat" }, KEYED, { { content = { bash_call("t1", "true") }, stop_reason = "tool_use" },
    text_reply("one"), text_reply("two") }, { "first" }, { "steer it", "/later after", "/exit" })
  assert(r.code == 0 and #a.sent == 3, r.out .. r.err)
  assert(said(a, 2):find('"steer it"', 1, true) ~= nil and said(a, 3):find('"after"', 1, true) ~= nil, said(a, 3))
end

local function test_sessions_are_kept_and_go_on()
  home = scratch()
  local r, a = cli({ "ask", "--model", "sonnet", "first" }, KEYED, { text_reply("one") })
  assert(r.code == 0, r.err)
  assert(sent(a, 1)["model"] == "claude-sonnet-5-5" and sent(a, 1)["output_config"] ~= nil)
  r, a = cli({ "ask", "--continue", "second" }, KEYED, { text_reply("two") })
  assert(r.code == 0, r.err)
  local again, _ = Json.to_array(sent(a, 1)["messages"])
  assert(again ~= nil and #again == 3 and said(a, 1):find('"first"', 1, true) ~= nil, said(a, 1))
  local list = cli({ "sessions" }, KEYED, {})
  assert(list.code == 0 and list.out:find("claude%-sonnet%-5%-5%s+4%s+0%s+%$0%.000%s+first") ~= nil, list.out)
  local id = list.out:match("^%s*(%d+)")
  assert(id ~= nil)
  r, a = cli({ "ask", "--session", id, "third" }, KEYED, { text_reply("three") })
  local third, _ = Json.to_array(sent(a, 1)["messages"])
  assert(r.code == 0 and third ~= nil and #third == 5)
  assert(cli({ "ask", "--session", "999", "x" }, KEYED, {}).err:find("no session 999") ~= nil)
  assert(cli({ "ask", "--session", "x", "x" }, KEYED, {}).code == Flags.REFUSED)
  assert(cli({ "ask", "--model", "haiku", "x" }, KEYED, {}).err:find("opus or sonnet") ~= nil)
  assert(cli({ "sessions", "x" }, KEYED, {}).code == Flags.REFUSED)
  -- Every tool's output is kept, and a later session finds it.
  r = cli({ "ask", "run it" }, KEYED, { { content = { { type = "tool_use", id = "t", name = "bash",
    input = { command = "echo kept-output-marker" } } }, stop_reason = "tool_use" }, text_reply("ran") })
  assert(r.code == 0, r.err)
  r, a = cli({ "ask", "find it" }, KEYED, { { content = { { type = "tool_use", id = "t", name = "sql",
    input = { query = "SELECT text FROM outputs_fts WHERE outputs_fts MATCH '\"kept-output\"'" } } },
    stop_reason = "tool_use" }, text_reply("found") })
  assert(r.code == 0 and said(a, 2):find("text\\nkept-output-marker", 1, true) ~= nil, said(a, 2))
end

local function test_the_sandbox_on_the_command_line()
  home = scratch()
  local outside = scratch()
  assert(cli({ "ask", "--grant", "/tmp:rwu", "x" }, KEYED, {}).err:find("letters", 1, true) ~= nil)
  assert(cli({ "ask", "--sandbox", "off", "--network", "x" }, KEYED, {}).err:find("--sandbox off", 1, true) ~= nil)
  local seen = cli({ "policy", "--network", "--grant", outside .. ":rw" }, KEYED, {})
  assert(seen.code == 0 and seen.out:find("network: *:*", 1, true) ~= nil, seen.out .. seen.err)
  assert(seen.out:find("rw    " .. assert(Fs.absolute(outside)), 1, true) ~= nil, seen.out)
  assert(seen.out:find("home: ", 1, true) ~= nil, seen.out)
  assert(cli({ "policy", "--sandbox", "off" }, KEYED, {}).out:find("no sandbox", 1, true) ~= nil)
  assert(cli({ "policy", "what" }, KEYED, {}).code == Flags.REFUSED)
  assert(cli({ "policy", "--json" }, KEYED, {}).code == Flags.REFUSED)
  local cleared = cli({ "policy", "clear-home" }, KEYED, {})
  assert(cleared.code == 0 and cleared.out:find("removed ", 1, true) ~= nil, cleared.out .. cleared.err)
  assert(not assert(Fs.status(home .. "/.cache/cosmic/agent/home")).exists)
  assert(cli({ "ask", "--sandbox", "loose", "x" }, KEYED, {}).code == Flags.REFUSED)
  assert(cli({ "ask", "--grant", "/no/such/path", "x" }, KEYED, {}).err:find("--grant", 1, true) ~= nil)
  -- A working directory that holds the sessions is refused a sandbox, and
  -- starts no session.
  local held = cli({ "policy" }, { XDG_DATA_HOME = assert(Fs.absolute(".")) .. "/data" }, {})
  assert(held.code == Flags.REFUSED and held.err:find("keeps its sessions", 1, true) ~= nil, held.err)
  local before = cli({ "sessions" }, KEYED, {})
  local refused = cli({ "ask", "--grant", "/no/such/path", "x" }, KEYED, {})
  assert(refused.code == Flags.REFUSED and cli({ "sessions" }, KEYED, {}).out == before.out, refused.err)
  local ran, a = cli({ "ask", "--sandbox", "read", "--grant", outside .. ":rwc", "go" }, KEYED, {
    { content = { { type = "tool_use", id = "t", name = "write", input = { path = outside .. "/z", content = "z" } } },
      stop_reason = "tool_use" }, text_reply("done") })
  assert(ran.code == 0 and slurp(outside .. "/z") == "z" and #a.sent == 2, ran.err)
end

local function test_a_job_never_read_is_kept_as_the_session_ends()
  home = scratch()
  local ran = cli({ "ask", "start it" }, KEYED, { { content = { { type = "tool_use", id = "t", name = "bash",
    input = { command = "echo bg-job-marker; sleep 30", background = true } } }, stop_reason = "tool_use" },
    text_reply("started") })
  assert(ran.code == 0, ran.err)
  local a: Api
  ran, a = cli({ "ask", "find it" }, KEYED, { { content = { { type = "tool_use", id = "t", name = "sql",
    input = { query = "SELECT count(*) FROM outputs WHERE tool = 'bash' AND input LIKE '%background%' " ..
        "AND input LIKE '%bg-job-marker%' AND call IS NULL" } } }, stop_reason = "tool_use" }, text_reply("found") })
  assert(ran.code == 0 and said(a, 2):find("count(*)\\n1", 1, true) ~= nil, said(a, 2))
end

local function test_the_command_line_is_refused_where_it_should_be()
  home = scratch()
  local none = cli({}, KEYED, {})
  assert(none.code == Flags.REFUSED and none.err:find("name ask, chat", 1, true) ~= nil, none.err)
  assert(cli({ "nope" }, KEYED, {}).err:find("no subcommand nope", 1, true) ~= nil)
  assert(cli({ "sessions", "--json" }, KEYED, {}).err:find("not an option of sessions", 1, true) ~= nil)
  assert(cli({ "chat", "--json" }, KEYED, {}).code == Flags.REFUSED)
  assert(cli({ "ask", "--chek", "x" }, KEYED, {}).code == Flags.REFUSED)
  local p = cli({ "prompt" }, {}, {})
  assert(p.code == 0 and p.out:find("<cwd>", 1, true) ~= nil and p.out:find("cosmic agent", 1, true) ~= nil, p.out)
  -- By default the model is shown no tool that runs a program.
  assert(p.out:find("- run: ", 1, true) ~= nil and p.out:find("- bash: ", 1, true) == nil and
      p.out:find("- jobs: ", 1, true) == nil, p.out)
  local every = cli({ "prompt", "--tools", "all" }, {}, {})
  assert(every.code == 0 and every.out:find("- bash: ", 1, true) ~= nil, every.out)
  assert(cli({ "prompt", "x" }, {}, {}).code == Flags.REFUSED)
  local shown = cli({ "prompt", "--tools", "run,read" }, {}, {})
  assert(shown.code == 0 and shown.out:find("- run: ", 1, true) ~= nil and shown.out:find("- bash: ", 1, true) == nil,
    shown.out)
  -- The sessions database is the data directory's, its owner's alone.
  assert(cli({ "sessions" }, KEYED, {}).code == 0)
  assert(assert(Fs.stat(home .. "/.local/share/cosmic/agent/sessions.db")).mode & 0x1ff == 0x180)
end
