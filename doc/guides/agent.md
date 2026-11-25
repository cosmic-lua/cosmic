# a first session with cosmic agent

`cosmic agent` is a small coding agent: Claude, with tools that read,
edit and write the files of one directory, held to a sandbox. This
guide takes you from no setup to a fixed project: an API key, a first
question, a real change, and the flags that limit what the agent can
do and spend.

## an API key

The agent calls the Claude API directly, so it needs a credential for
it, most simply an Anthropic API key. A Claude.ai subscription alone
does not give API access.

1. Sign in at [console.anthropic.com](https://console.anthropic.com).
2. Add credits, and set a monthly spend limit. That limit is the hard
   cap on what any key can spend.
3. Under API keys, make a key. It starts with `sk-ant-`, and the
   console shows it once.
4. Keep it in a file of its own, and read it into your shell:

```text
mkdir -p ~/.config/anthropic && chmod 700 ~/.config/anthropic
# paste the key into ~/.config/anthropic/key, then:
chmod 600 ~/.config/anthropic/key
export ANTHROPIC_API_KEY="$(cat ~/.config/anthropic/key)"
```

Add the `export` line to `~/.bashrc` or `~/.zshrc` to keep it. With no
key, the agent stops before it sends anything, and exits 2:

```text
$ cosmic agent ask 'hi'
cosmic: agent: ask: no credential: set ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, or federation's variables (cosmic docs cosmic.agent.auth)
```

`cosmic docs cosmic.agent.auth` lists the other ways to sign in: an
OAuth token, or Workload Identity Federation for CI with no stored key.
The tools do not get your key from the environment: the sandbox passes
them only `LANG`, `LC_ALL` and `TERM` (and `SSL_CERT_FILE` with
`--network`). Keep the key file out of the directory you work in.

## a first question

Go to the directory to work in. The tools can read and change that
directory and a home of their own. Outside it they read only what a
program needs, such as `/usr`, and change nothing. Then ask:

```text
$ cd ~/src/tidy
$ cosmic agent ask 'what does this repository do? keep it short'
run
    for _, p in ipairs(Host.find(".")) do if not p:match("^%./%.git/") then print(p) end end
run
    print(Host.cat("README.md")) print(Host.cat("docs/usage.md"))
**tidy** is a command-line tool that sorts the files in a folder into subfolders by type: `images/`, `documents/`, `archives/` and `other/`. For example, `tidy ~/Downloads` does this to your Downloads folder. Adding `--dry-run` shows the moves without making them, and you can change the folder names in the configuration. It's MIT licensed.

This repo contains only documentation (`README.md`, `docs/`) and the `LICENSE`. There is no source code in it.

One broken link: `README.md` points to `docs/config.md`, but the file is called `docs/configuration.md`.
```

The tool calls go to standard error. `run` is the agent's main tool.
Each call is a short program in the cosmic environment. The agent checks
it, then runs it in the sandbox. [`Host.find`], [`Host.cat`],
[`Host.grep`] and the like work much as the commands they are named
for, but give values in place of text. The answer goes to standard
output, so `cosmic agent ask '...' > answer.md` keeps only the answer.

## a change

`ask` goes on with the newest session in the directory, so the model
still knows what it found. It says so on standard error. `--new`
starts a fresh session. `--session <id>` goes on with any session.
`--fork` goes on in a copy of the newest session, or of the one
`--session` names.

```text
$ cosmic agent ask 'fix the broken links with the edit tool'
cosmic: agent: going on with session 1 (6 messages, claude-opus-5-5); --new starts a fresh one
run
    for _, p in ipairs({"docs/configuration.md","docs/faq.md","docs/install.md"}) do print("== "..p) print(Host.cat(p)) end
edit README.md
    @@
    -(docs/config.md)
    +(docs/configuration.md)
edit docs/faq.md
    @@
    -(instal.md)
    +(install.md)
I fixed two broken links:
- `README.md`: `docs/config.md` → `docs/configuration.md`
- `docs/faq.md`: `instal.md` → `install.md`

One link is still broken: `docs/faq.md` points to `usage.md#undo`, but `docs/usage.md` has no Undo section.
```

Each edit shows as diff lines. `@@` starts each replacement, `-` marks
what it takes out, and `+` what it puts in. A line that starts with a
space is unchanged context. Read the answer as a colleague's report: ask again to check
the work (`now check every link`), or look with your own tools
(`git diff`).

Each session is kept in `sessions.db`, in `$XDG_DATA_HOME/cosmic/agent`
(by default `~/.local/share/cosmic/agent`). After the change, the list
shows:

```text
$ cosmic agent sessions
  id  started              model              msgs  context     cost  first prompt
   1  2026-11-24 18:00:55  claude-opus-5-5      12     5.8k   $0.053  what does this repository do? keep it short
```

A tool output too long to show is cut, and a note under it names the
output's id. In a `run` program, `Host.output(id)` reads that output
back from this database, and `Host.history(query)` runs one read-only
SQL statement on it. The agent uses them to find output it saw before.

## limits

`cosmic agent policy` prints what the tools may reach here, path by
path, before you run anything. These flags change what they reach:

- `--sandbox read`: the tools change nothing in the directory. The
  model is offered no edit or write, unless a `--grant` lets it write
  somewhere. Use it for advice.
- `--network`: the tools may reach the network ([`Host.fetch`]). There is
  none by default.
- `--grant path[:rwxc]`: one more path, read alone unless the letters
  say more.
- `--with bash,jobs`: offer bash and its background jobs. Bash runs
  your programs (`git`, `make`, the project's tests). On Linux, the
  default tools run no program; on macOS a `run` program still may.
- `--without write`: take a tool out of what the model is offered.

These flags limit what a turn spends. A turn is all the work for one
prompt.

- `--budget cost=0.25,turns=10,time=5m,tokens=200000`: the most one
  turn may spend. `turns` counts requests to the API, not prompts. The
  model reads the limits with the prompt, and the first one reached
  ends the turn:

```text
$ cosmic agent ask --new --budget turns=2 'document the [ignore] table in docs/configuration.md: it lists file names tidy never moves'
run
    print(Host.cat("docs/configuration.md"))
    for _, g in ipairs(Host.grep("ignore", Host.find(".", ""), true)) do print(g.path .. ":" .. tostring(g.line) .. ": " ...
cosmic: agent: ask: the turn's budget is spent: 2 requests, of 2; go on with `cosmic agent ask --session 2 'go on'` and a larger --budget
```

- `--model sonnet` costs less than the default, opus. A session keeps
  the model it used last, until `--model` names another.

## next

- `cosmic agent chat` takes one prompt a line until `/exit`. A line
  typed while the model works steers it.
- `cosmic agent ask --json` prints each event as a line of JSON, with
  the tokens and cost of each request, for scripts. `cosmic agent rpc`
  runs a session for another program.
- `cosmic help agent` lists every option. [`cosmic.agent.policy`] says
  what the sandbox holds, [`cosmic.agent.sessions`] what is kept, and
  [`cosmic.agent.host`] what the model's programs can call.
- [`cosmic.agent`] runs the loop in a program of your own, with its own
  tools and its own `before` and `after` hooks.

[`cosmic.agent.host`]: ../../cosmic/agent/host.tl
[`cosmic.agent.policy`]: ../../cosmic/agent/policy.tl
[`cosmic.agent.sessions`]: ../../cosmic/agent/sessions.tl
[`cosmic.agent`]: ../../cosmic/agent/init.tl
[`Host.cat`]: ../../cosmic/agent/host.tl
[`Host.fetch`]: ../../cosmic/agent/host.tl
[`Host.find`]: ../../cosmic/agent/host.tl
[`Host.grep`]: ../../cosmic/agent/host.tl
