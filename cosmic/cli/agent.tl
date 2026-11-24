--- `cosmic agent <ask|chat|resume|rpc|sessions|prompt|policy> ...`: a
--- small coding agent, after pi. It is Claude, with tools that read,
--- write and edit files, run commands in the foreground or as background
--- jobs, check and run snippets of Teal in a worker kept for the session,
--- and query what the agent has kept. Every tool is held to a sandbox.
---
--- To start, go to the directory to work in and set `ANTHROPIC_API_KEY`
--- (for other credentials, see `cosmic docs cosmic.agent.auth`):
---
---     cosmic agent ask 'what does this repository do?'
---     cosmic agent chat                      a conversation, a prompt a line
---     cosmic agent sessions                  what was kept, newest first
---     cosmic agent ask --continue 'and now?' go on with the newest session
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
--- - `sessions` lists the newest sessions in this directory.
--- - `prompt` prints the system prompt that the model reads.
--- - `policy` prints, path by path, the sandbox that the tools would run
---   under here. `policy clear-home` empties the commands' kept home.
--- - `worker` is the worker's process, which runs the snippets. The agent
---   starts it.
---
--- Model and session:
---
--- - `--model opus|sonnet` picks the latest of each (default opus).
--- - `--effort low|medium|high|xhigh|max` sets how hard it thinks
---   (default medium).
--- - `--continue` goes on with the newest session in the directory.
---   `--session <id>` goes on with any session.
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
--- - `--sandbox read` lets them change nothing.
--- - `--sandbox off` runs them with your user's rights and environment,
---   your API key included.
--- - `--network` lets the tools reach the network: Host.fetch, and bash
---   where it is offered.
--- - `--grant path[:rwxc]` adds a path.
---
--- Output and sessions:
---
--- - The model's words go to standard output, and each tool call to
---   standard error.
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

local command: Flags.Command = {
  about = "a coding agent, Claude, held to a sandbox",
  usage = "<ask|chat|resume|rpc|sessions|prompt|policy> [options] [words...]",
  examples = {
    { line = "ask 'what does this repository do?'", about = "ask Claude about this directory" },
    { line = "chat", about = "a conversation, a prompt a line" },
    { line = "sessions", about = "list the kept sessions" },
  },
  spec = {
    ["--model"] = { value = "name", about = "ask, chat, resume, rpc: opus or sonnet, the latest of each (default opus)" },
    ["--effort"] = { value = "level", about = "ask, chat, resume, rpc: low, medium, high, xhigh or max (default medium)" },
    ["--continue"] = { about = "ask, chat, rpc: go on with the newest session in this directory" },
    ["--session"] = { value = "id", about = "ask, chat, resume, rpc: go on with the session of this id" },
    ["--json"] = { about = "ask: print each event as a line of JSON, not the model's words" },
    ["--sandbox"] = { value = "mode", about = "write (the default), read or off: what the tools may change" },
    ["--network"] = { about = "let bash and snippets (Host.fetch, cosmic.http) reach the network" },
    ["--grant"] = { value = "path[:rwxc]", about = "let the tools reach this path too, read alone unless letters say more" },
    ["--mcp"] = { value = "file", about = "ask, chat, resume, rpc: the MCP servers snippets may call (default ~/.config/cosmic/mcp.json; see cosmic.agent.mcp)" },
    ["--tools"] = { value = "names", about = "ask, chat, resume, rpc, prompt: the tools the model is shown, such as run,read,edit,write,bash, all, or default (every tool but bash and jobs, which run no program)" },
  },
}

return command
