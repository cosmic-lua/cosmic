--- `cosmic agent <ask|chat|policy|prompt|resume|rpc|sessions|worker> ...`: a
--- small coding agent, after pi. It is Claude, with tools that read,
--- write and edit files, run commands in the foreground or as background
--- jobs, check and run snippets in the cosmic environment in a worker kept for the session,
--- and query what the agent has kept. Every tool is held to a sandbox.
---
--- To start, go to the directory to work in and set `ANTHROPIC_API_KEY`
--- (for other credentials, see `cosmic docs cosmic.agent.auth`):
---
---     cosmic agent ask 'what does this repository do?'
---     cosmic agent chat                      a conversation, a prompt a line
---     cosmic agent sessions                  what was kept, newest first
---     cosmic agent ask 'and now?'            go on with the newest session here
---     cosmic agent ask --new 'start over'    a fresh session
---
--- Commands:
---
--- - `ask [prompt...]` runs one prompt to the end. The prompt is the
---   words, else all of standard input.
--- - `chat` takes one prompt a line until `/exit`. A line typed at a
---   terminal while the model works steers it. `/later <prompt>` waits
---   for the turn to end. A failed turn does not end the chat.
--- - `resume` finishes the turn that a run left unfinished.
--- - `rpc` runs one session for another program. It reads commands as
---   JSON lines on standard input and writes events on standard output.
---   A failed turn does not end the session.
--- - While `chat` or `rpc` waits for a line, it sends the last request
---   again every 4.5 minutes, asking for no reply, for up to an hour
---   (`--keep-warm`). The API then keeps the conversation in its cache:
---   each such request costs 0.05x of the conversation's input price, and
---   the cache miss it saves costs 1.25x. rpc tells each as a request
---   event, with `"warm": true`.
--- - `sessions` lists the newest sessions in this directory.
--- - `prompt` prints the system prompt that the model reads.
--- - `policy` prints, path by path, the sandbox that the tools would run
---   under here. `policy clear-home` empties the commands' kept home.
--- - `worker` (internal) is the worker's process, which runs the
---   snippets. The agent starts it.
---
--- Model and session:
---
--- - `--model opus|sonnet` picks the latest of each (default opus).
--- - `--effort low|medium|high|xhigh|max` sets how hard it thinks
---   (default medium).
--- - `--budget tokens=N,cost=USD,turns=N,time=N[s|m|h]` caps what each
---   turn may spend, any of the four; turns counts requests. The model
---   reads the limits with the prompt. The first limit reached ends the
---   turn for good, and the agent says which.
--- - `ask` and `chat` go on with the newest session in the directory,
---   and say so on standard error. `--new` starts a fresh one,
---   `--session <id>` goes on with any session, and `--fork` copies the
---   newest (or `--session`'s) and goes on in the copy. `rpc` goes on
---   with one only when told (`--continue`).
--- - The default tools are run, read, edit, write and sql, which run no
---   program. `--with bash,jobs` adds bash and its background jobs,
---   `--without sql` takes a tool out, and `--tools run,read` names them
---   all.
---
--- Events and rpc commands:
---
--- `rpc` and `ask --json` print events. Each event is one JSON object on
--- a line, printed once what it tells of is kept:
---
--- - `{"type":"session","id":7}` names the session. rpc adds
---   `unfinished`.
--- - `message`: a message joined the conversation, in the form the API
---   takes.
--- - `tool`: a call starts (`name`, `input`).
--- - `result`: a call ended (`name`, `is_error`).
--- - `request`: a request ended (its model, status, ms, tokens and cost).
--- - `end`: the turn ended (`ok`, and `error` when `ok` is false).
--- - `error`: a command was refused.
---
--- The rpc commands are:
---
--- - `{"type":"prompt","text":"..."}` runs a turn.
--- - `steer` goes to the model after the running tool, and skips the
---   calls after it.
--- - `follow_up` runs after the turn.
--- - `abort` stops the turn at its next step.
--- - `resume` finishes an unfinished turn.
---
--- Between turns, `steer` and `follow_up` run as prompts.
---
--- The sandbox (`cosmic docs cosmic.agent.policy`):
---
--- - The tools can read and change the working directory. They have a
---   home of their own, which outlives each command. They reach nothing
---   else, not even the network.
--- - With the default tools (no bash), no program runs: on Linux the
---   sandbox refuses every file but cosmic's own the right to run.
---   On macOS, or with `--sandbox off`, a snippet may still run one.
--- - `--sandbox read` lets them change nothing, and offers no edit or
---   write.
--- - `--sandbox off` runs them with your user's rights and environment,
---   your API key included.
--- - `--network` lets the tools reach the network: Host.fetch, and bash
---   where it is offered. Your SSL_CERT_FILE goes with it (and with
---   `--connect`), so a proxy that signs with its own root is trusted.
--- - `--connect host:port` lets them reach one more target. An address
---   written out, loopback or private too (`--connect 127.0.0.1:8123`),
---   is reached directly; a name reaches only public addresses, as
---   `--network` does. A port of `*` opens every port of the host.
---   Behind an `https_proxy`, an address `no_proxy` does not name is
---   asked of the proxy, which reaches its own host's loopback.
--- - `--grant path[:rwxc]` adds a path.
---
--- Output and sessions:
---
--- - The turn's answer goes to standard output. Each tool call (run's
---   code, edit's changes as a diff), and what the model says on the way,
---   go to standard error.
--- - Everything is kept in sessions.db, in `$XDG_DATA_HOME/cosmic/agent`
---   (or `~/.local/share/cosmic/agent`), before it is shown: each
---   message, each tool's whole output, and each request with its usage
---   and cost (`cosmic docs cosmic.agent.sessions`). The model reads it
---   with its sql tool.
--- - A run that ends mid-turn loses nothing: `cosmic agent resume` takes
---   the turn up again (`cosmic docs cosmic.agent`).
--- - A program runs the loop itself with [`cosmic.agent`].
--- @public

local Flags = require("cosmic.flags")

local model: Flags.Option = { value = "name", about = "the latest of opus or sonnet (default opus, or the session's own)",
  choices = { "opus", "sonnet" } }
local effort: Flags.Option = { value = "level", about = "how hard it thinks (default medium, as cosmic.agent sets it)",
  choices = { "low", "medium", "high", "xhigh", "max" } }
local continue_: Flags.Option = { about = "go on with the newest session in this directory " ..
    "(ask and chat do unless --new)" }
local new: Flags.Option = { about = "start a fresh session, not the newest one here" }
local fork: Flags.Option = { about = "copy the newest session here, or --session's, " ..
    "and go on in the copy" }
local session: Flags.Option = { value = "id", about = "go on with the session of this id" }
local sandbox: Flags.Option = { value = "mode", about = "what the tools may change",
  choices = { "write", "read", "off" }, default = "write" }
local network: Flags.Option = { about = "let bash and snippets (Host.fetch, cosmic.http) reach the network" }
local connect: Flags.Option = { value = "host:port", about = "let the tools reach this target too: an address " ..
    "written out may be loopback or private (127.0.0.1:8123); a port of * opens every port" }
local grant: Flags.Option = { value = "path[:rwxc]",
  about = "let the tools reach this path too, read alone unless letters say more" }
local tools: Flags.Option = { value = "names", about = "the tools the model is shown, such as run,read " ..
    "(default: run, read, edit, write and sql, which run no program)" }
local with: Flags.Option = { value = "names", about = "offer these tools too, such as bash,jobs " ..
    "(bash runs programs, jobs its background ones)" }
local without: Flags.Option = { value = "names", about = "do not offer these tools, such as sql,write" }
local budget: Flags.Option = { value = "limits",
  about = "the most each turn may spend, such as tokens=200000,cost=0.50,turns=20,time=10m; the first reached ends it" }
local mcp: Flags.Option = { value = "file",
  about = "the MCP servers snippets may call (default ~/.config/cosmic/mcp.json; see cosmic.agent.mcp)" }

--- The options of a command that runs a session.
local function session_spec(): mut {string: Flags.Option}
  return {
    ["--model"] = model, ["--effort"] = effort, ["--continue"] = continue_, ["--session"] = session,
    ["--new"] = new, ["--fork"] = fork,
    ["--sandbox"] = sandbox, ["--network"] = network, ["--connect"] = connect, ["--grant"] = grant, ["--mcp"] = mcp,
    ["--tools"] = tools, ["--with"] = with, ["--without"] = without, ["--budget"] = budget,
  }
end

--- The options of a session that waits for its next prompt: chat's and rpc's.
local function waiting_spec(): mut {string: Flags.Option}
  local spec = session_spec()
  spec["--keep-warm"] = { value = "minutes",
    about = "keep the conversation in the API's cache this long while idle (default 60; 0 for never)" }
  return spec
end

local ask_spec = session_spec()
ask_spec["--json"] = { about = "print each event as a line of JSON, not the model's words" }

local command: Flags.Command = {
  about = "a coding agent, Claude, held to a sandbox",
  usage = "<ask|chat|policy|prompt|resume|rpc|sessions|worker> ...",
  examples = {
    { line = "ask 'what does this repository do?'", about = "ask Claude about this directory" },
    { line = "chat", about = "a conversation, a prompt a line" },
    { line = "sessions", about = "list the kept sessions" },
  },
  subcommands = {
    ask = { about = "run one prompt to the end: the words, else all of standard input",
      usage = "[options] [prompt...]", spec = ask_spec },
    chat = { about = "a conversation, a prompt a line, until /exit", spec = waiting_spec() },
    resume = { about = "finish the turn a run left unfinished", spec = session_spec() },
    rpc = { about = "one session for another program, as JSON lines", spec = waiting_spec() },
    sessions = { about = "the newest sessions in this directory" },
    prompt = { about = "the system prompt the model reads",
      spec = { ["--tools"] = tools, ["--with"] = with, ["--without"] = without } },
    policy = { about = "the sandbox the tools would run under here; clear-home empties their kept home",
      usage = "[options] [clear-home]",
      spec = { ["--sandbox"] = sandbox, ["--network"] = network, ["--connect"] = connect, ["--grant"] = grant,
        ["--tools"] = tools, ["--with"] = with, ["--without"] = without } },
    worker = { about = "the process that runs the snippets; the agent starts it" },
  },
}

return command
