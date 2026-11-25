# cosmic agent

<!-- policy: profiles = { "cosmic" } -->

`cosmic agent` is a small coding agent. It is Claude, with one tool
that runs programs to read, edit and write the files of one directory,
held to a sandbox.
This guide shows how it works, from an API key to a fixed project.

What it gives you:

- **Checked programs in place of shell commands.** The one tool,
  `run`, takes a short program in the cosmic environment. The agent
  type-checks it before it runs it. A refused program runs nothing,
  and the refusal says how to fix it.
- **No shell by default.** A program reads, edits and writes files
  through `Host` and cosmic's modules. On Linux, under the sandbox, it
  runs no other program. [`Host.bash`] runs one only with `--commands`.
- **A sandbox the kernel holds.** The tools change only the working
  directory and a home of their own. They get no network, and none of
  your environment but `LANG`, `LC_ALL` and `TERM`, so not your API
  key.
- **Everything is kept.** Each session's messages, each tool's whole
  output and each request's cost go to a SQLite database. A later
  prompt goes on with the same session.
- **Limits per turn.** `--budget` caps the cost, requests, time or
  tokens of one prompt.

The examples use `tidy`, a folder of five Markdown files that
document a file-sorting tool. Three of its links are broken, and one
table is not documented yet. Each transcript is the output of a real
run with `--model haiku`, which the commands below leave out. A line
`...` marks text cut from this guide.

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

## a first question

Go to the directory to work in, and ask:

```sh
cosmic agent ask 'what does this repository do? keep it short'
```

> ```teal
> for _, p in ipairs(Host.find(".")) do print(p) end
> for _, n in ipairs({ "README.md", "readme.md", "README" }) do
>   if Host.exists(n) then
>     print(Host.read(n):sub(1, 2000))
>     break
>   end
> end
> ```
> ```output
> .git/COMMIT_EDITMSG
> .git/HEAD
> .git/config
> .git/description
> .git/hooks/applypatch-msg.sample
> .git/hooks/commit-msg.sample
> ... 45 more lines
> ```
> `tidy` sorts the files in a folder into subfolders by file type. It uses the IANA media types list to decide each file's type. Docs are in `docs/`, and it's MIT licensed.

The output is Markdown, so a Markdown viewer shows it as above. Each
tool call goes to standard error, in a code fence:

- `teal`: a `run` program, laid out as `cosmic fix` lays out a file.
  The fence names the language, so a viewer colors it.
- `console`: a `bash` command of an older session, behind `$ `.
- `output`: the first 6 lines of what `run` printed.
- `error`: the first 12 lines of what a call that failed said.
- `diff`: each [`Host.edit`] a `run` program made, after its output
  and a line `edit <path>` (an older session's `edit` calls show the
  same way). `@@` starts each replacement, `-` marks what it takes
  out, `+` what it puts in, and a line that starts with a space is
  unchanged context.

Each [`Host.write`] a program made shows one line after its output,
not in a fence, such as `write notes.md (12 lines)`. The view keeps
about 64 KB of a program's changes, with the lines both sides share
taken out; a line `... N more changes not shown` counts the rest.

The `teal`, `console` and `diff` fences show 12 lines at most. A line
`... N more lines` says how many more there are. An older session's
`read` and `write` show one line, such as `read README.md`. A fence is longer than any
run of backticks inside it, so no line closes it early. Control bytes
but tab and newline are taken out of all of it, so nothing moves the
cursor or sends escape sequences to your terminal. A line and column
in an error count in the program as the model wrote it, not as shown.

The answer goes to standard output, so
`cosmic agent ask '...' > answer.md` keeps only the answer. What a
call printed shows on standard error, so a secret a call reads shows
there too.

## a change

`ask` goes on with the newest session in the directory, so the model
still knows what it found. It says so on standard error.

```sh
cosmic agent ask 'fix the broken links. for the #undo link, add a short Undo section to usage.md that says what the FAQ already says.'
```

> cosmic: agent: going on with session 1 (4 messages, claude-haiku-5-5); --new starts a fresh one
> ```teal
> for _, h in ipairs(Host.grep("%]%(", Host.find(".", ".md"), false)) do
>   print(h.path .. ":" .. tostring(h.line) .. ": " .. h.text)
> end
> print("----usage")
> print(Host.read("docs/usage.md"))
> print("----faq")
> print(Host.read("docs/faq.md"))
> ```
> ```output
> README.md:5: - [Install](docs/install.md)
> README.md:6: - [Usage](docs/usage.md)
> README.md:7: - [Configuration](docs/config.md)
> README.md:8: - [FAQ](docs/faq.md)
> README.md:10: tidy is MIT licensed: see [LICENSE](LICENSE).
> README.md:12: The file types come from [the IANA media types list](https://www.iana.org/assignments/media-types/media...
> ... 30 more lines
> ```
> ```teal
> Host.edit("README.md", { { old = "(docs/config.md)", new = "(docs/configuration.md)" } })
> Host.edit("docs/faq.md", { { old = "[Install](instal.md)", new = "[Install](install.md)" } })
> Host.edit("docs/usage.md", { { old = "See the [FAQ](faq.md).\n", new = "See the [FAQ](faq.md).\n\n## Undo\n\ntidy onl...
> print(Host.read("docs/usage.md"))
> ```
> ```output
> # Usage
>
>     tidy ~/Downloads
>
> tidy moves each file into a folder named for its type: `images/`,
> `documents/`, `archives/` and `other/`.
> ... 9 more lines
> ```
> edit README.md
> ```diff
> @@
> -(docs/config.md)
> +(docs/configuration.md)
> ```
> edit docs/faq.md
> ```diff
> @@
> -[Install](instal.md)
> +[Install](install.md)
> ```
> edit docs/usage.md
> ```diff
> @@
> +
> +## Undo
> +
> +tidy only moves files, it never deletes them. Undo a run with `tidy --undo`.
> ```
> Fixed two broken links and added the Undo section:
>
> - `README.md`: `docs/config.md` → `docs/configuration.md`
> - `docs/faq.md`: `instal.md` → `install.md`
> - `docs/usage.md`: new `## Undo` section saying tidy only moves files and that `tidy --undo` reverses a run. The FAQ's `usage.md#undo` link now resolves.
>
> I didn't check the links with a link checker, only by reading the files.

To check the work, ask again, or look with your own tools
(`git diff`). A program the checker refuses runs nothing, and the
refusal goes back to the model as an error:

```sh
cosmic agent ask 'now check every relative link in every .md file, including #anchors, and list any that are still broken'
```

> cosmic: agent: going on with session 1 (10 messages, claude-haiku-5-5); --new starts a fresh one
> ```teal
> local function slug(h: string): string
>   local s = h:lower():gsub("[^%w%- _]", ""):gsub(" ", "-")
>   return s
> end
> local function anchors(path: string): {string: boolean}
>   local set: mut {string: boolean} = {}
>   local text = Host.read(path)
>   for line in text:gmatch("[^\n]+") do
>     local h = line:match("^#+%s+(.-)%s*$")
>     if h ~= nil then set[slug(h)] = true end
>   end
>   return set
> ... 34 more lines
> ```
> ```error
> The checker refused the snippet, so it did not run:
> run.tl:30:43: `goto continue` is not in the grammar (label_or_goto): write `continue`
> run.tl:31:37: `goto continue` is not in the grammar (label_or_goto): write `continue`
> run.tl:40:7: the label `::continue::` is not in the grammar (label_or_goto): delete the label, and write `continue` w...
> ```
> ...
> ```teal
> local function slug(h: string): string
> ...
> ```
> ```output
> checked 13 relative links
> none broken
> ```
> No broken relative links remain. I checked 13 relative links across all `.md` files, including the `#anchor` fragments, and every target file and heading exists.
>
> The anchor check uses a simplified version of GitHub's heading-slug rules, so an unusual heading could be misjudged.

## the tools

The model is offered one tool, `run`: a program in the cosmic
environment, in a worker kept for the session. One program does the
work of many tool calls and prints only what the model needs. The
agent type-checks it first: a refusal runs nothing and names the fix.

A `run` program reaches the directory through [`Host`]. Its calls do
as the commands they are named for, but give values in place of text,
and raise where they fail:

- `Host.find(dir, suffix?)`: every file under `dir`, sorted.
- [`Host.read`], [`Host.edit`] (exact replacements, `{ { old = "...", new = "..." } }`, each old text in the file once), [`Host.lines`], [`Host.wc`], [`Host.exists`], [`Host.write`].
- `Host.grep(pattern, paths, plain?)`: the lines that hold a pattern,
  each as `{path, line, text}`.
- `Host.sed(path, pattern, replacement)`: replaces every match.
- [`Host.sort`], [`Host.uniq`], [`Host.top`]: lists and counts.
- `Host.fetch(url, options?)`: an HTTP request to a public address
  with `--network`, or to a `--connect` target. It follows no
  redirect.
- `Host.sqlite(path, statement, values?)`: SQL on a SQLite file.
- `Host.output(id)` and `Host.history(query)`: what the sessions
  database keeps (see "sessions" below).
- [`Host.modules()`] lists the `cosmic.*` modules a program may require,
  and `Host.docs(name)` shows one.

`--commands` adds one call:

- `Host.bash(command)`: a shell command in the directory, under the
  same sandbox, as `{output, ok, code}`.

`cosmic agent prompt` prints the system prompt the model reads.

Without `--commands`, the model does with `Host` and cosmic's modules
what a program would. With it, the model runs your programs (`git`,
`make`, the project's tests), so the sandbox is its only fence. The
same prompt, both ways:

```sh
cosmic agent ask --new 'write a one-line commit message for the uncommitted changes'
```

Here the model reads the docs of [`cosmic.child`] and tries to start
`git` with it. The checker
refuses three of its programs, and it fixes each one. Then the sandbox
refuses to start `git`, and the model asks for the diff:

> ```output
> fail child: start: Operation not permitted
> fail child: start: Operation not permitted
> ```
> ...
> I can't see the uncommitted changes, so I can't write the message yet. The sandbox refuses to start `git` here (`child: start: Operation not permitted`), and I haven't found an earlier `git diff` output in the session history to work from.
>
> ...

This takes 6 programs and $0.002.

```sh
cosmic agent ask --new --commands 'write a one-line commit message for the uncommitted changes'
```

> ```teal
> local r = Host.bash("git status --short && echo --- && git diff HEAD --stat && echo --- && git diff HEAD")
> print(r[1])
> ```
> ```error
> The checker refused the snippet, so it did not run:
> run.tl:2:7: `1` is `integer`, which names no field of `Host.Ran`: a record is not a map (record_index): write the fie...
> run.tl: 1 error of record_index in its bodies on line 2; follow the fix above
> ```
> ```teal
> local r = Host.bash("git status --short && echo --- && git diff HEAD --stat && echo --- && git diff HEAD")
> print(r.output)
> ```
> ```output
>  M README.md
>  M docs/configuration.md
>  M docs/faq.md
>  M docs/usage.md
> ---
>  README.md             | 2 +-
> ... 55 more lines
> ```
> Suggested commit message:
>
> `docs: fix broken links, document [ignore] table and undo`
>
> This covers the four modified docs: the README link to configuration.md, the install link in the FAQ, the new `[ignore]` section, and the new Undo section in usage.md.

This takes 2 programs, 1 of them refused and fixed, and $0.001.

## the sandbox

`cosmic agent policy` prints what the tools may reach here, path by
path, with the same flags, before you run anything. Here, paths in
your home are shown as `~`:

```text
$ cosmic agent policy
programs: none run without --commands: the sandbox lets no file but cosmic's own run, whatever x the grants below give
home: ~/.cache/cosmic/agent/home, kept between sessions, 0.0 KB (cosmic agent policy clear-home empties it)
network: none
grants (r reads, w writes, x runs, c creates and removes):
  rx    /bin
  rw    /dev/null
  r     /etc/ssl
  ...
  rwxc  ~/.cache/cosmic/agent/home
  rwxc  ~/src/tidy
  rx    /usr
  ...
tmp: a fresh /tmp for each command, removed after it
...
processes: at most 512
env passed on: LANG LC_ALL TERM
...
```

What the default sandbox holds:

- **Files.** The tools read, write and create in the working
  directory and in their home. They read and run the system's
  programs (`/usr`, `/bin`, the directories on `PATH`), and read the
  files programs need, such as `/etc/ssl`. Nothing else is there. In a
  git worktree, its git directories are granted too.
- **Programs.** Without `--commands`, on Linux, no file but cosmic's
  own may run. On macOS, a `run` program still may run one.
- **Home.** The commands get a home of their own, not yours, kept
  from one session to the next. Every session shares it, so keep
  nothing secret in it. `cosmic agent policy clear-home` empties it.
- **Environment.** A command gets `PATH`, `LANG`, `LC_ALL` and `TERM`
  from yours, and its own `HOME`, `TMPDIR` and the like. No other
  variable of yours is passed, so no key of yours reaches it.
- **Network.** There is none.

The kernel holds it. On Linux, a command runs in a root of its own,
where what was not granted is not there, in its own pid namespace. On
macOS it runs under Seatbelt. A `run` program runs in a worker held
to the same grants.
[`cosmic.agent.policy`] holds the details.

These flags change it:

- `--sandbox read`: the tools change nothing. Use it for advice.
- `--network`: the tools may reach public addresses. `SSL_CERT_FILE`
  goes with it, so a proxy that signs with its own root is trusted.
- `--connect host:port`: one more target. An address written out may
  be loopback or private (`--connect 127.0.0.1:8123`).
- `--grant path[:rwxc]`: one more path, read alone unless the letters
  say more.
- `--sandbox off`: no sandbox. The tools get your user's rights and
  environment, your API key included.

With no network, a fetch fails, and the model says so:

```sh
cosmic agent ask --new 'do the external (http) links in the docs still work?'
```

> ...
> ```teal
> local r = Host.fetch("https://www.iana.org/assignments/media-types/media-types.xhtml", { method = "HEAD", any_status ...
> print("status " .. tostring(r.status))
> for k, v in pairs(r.headers) do
>   if k:lower() == "location" then print("location: " .. tostring(v)) end
> end
> ```
> ```error
> (no output)
> Error: run.tl:1: host: fetch: https://www.iana.org/assignments/media-types/media-types.xhtml: Could not resolve host:...
> ```
> I checked the docs, but I couldn't confirm the link works because this sandbox has no network access.
>
> ...

With `--network`, the same session goes on:

```sh
cosmic agent ask --network 'ok, try again'
```

> cosmic: agent: going on with session 4 (8 messages, claude-haiku-5-5); --new starts a fresh one
> ...
> ```teal
> local url = "https://www.iana.org/assignments/media-types/media-types.xhtml"
> local r = Host.fetch(url, { method = "HEAD", any_status = true })
> print("status " .. tostring(r.status))
> for k, v in pairs(r.headers) do
>   if k:lower() == "location" then print("location: " .. tostring(v)) end
> end
> ```
> ```output
> status 302
> location: /assignments/media-types
> ```
> ...
> The link now works, but it redirects. `https://www.iana.org/assignments/media-types/media-types.xhtml` returns a 302 to `/assignments/media-types`, which returns 200. This is the link in `README.md` line 12.
>
> ...

## budgets

`--budget` caps what one turn may spend. A turn is all the work for one
prompt. It takes any of `cost=USD`, `turns=N`, `time=N[s|m|h]` and
`tokens=N`. `turns` counts requests to the API, not prompts. The model
reads the limits with the prompt, and the first limit reached ends the
turn:

```sh
cosmic agent ask --new --budget turns=2 'document the [ignore] table in docs/configuration.md: it lists file names tidy never moves. keep it short.'
```

> ```teal
> local doc = Host.read("docs/configuration.md")
> print(doc)
> print("-----")
> for _, h in ipairs(Host.grep("ignore", Host.find("src", ".tl"), true)) do
>   print(h.path .. ":" .. tostring(h.line) .. ": " .. h.text)
> end
> for _, h in ipairs(Host.grep("ignore", Host.find(".", ".toml"), true)) do
>   print(h.path .. ":" .. tostring(h.line) .. ": " .. h.text)
> end
> ```
> ```error
> # Configuration
>
> tidy reads `~/.config/tidy/rules.toml` if it is there.
>
>     [images]
>     folder = "pictures"
>
> TODO: document the [ignore] table.
>
> Back to [Usage](usage.md) or the [README](../README.md).
>
> -----
> ... 1 more line
> ```
> cosmic: agent: ask: the turn's budget is spent: 2 requests, of 2; go on with `cosmic agent ask --session 3 'go on'` and a larger --budget

It exits 1. To go on, send a prompt with a larger budget:

```sh
cosmic agent ask --budget turns=6 'go on'
```

> cosmic: agent: going on with session 3 (5 messages, claude-haiku-5-5); --new starts a fresh one
> ...
> ```teal
> local n = Host.edit("docs/configuration.md", { { old = "TODO: document the [ignore] table.\n", new = "## `[ignore]`\n...
> print("edits: " .. tostring(n))
> print(Host.read("docs/configuration.md"))
> ```
> ```output
> edits: 1
> # Configuration
>
> tidy reads `~/.config/tidy/rules.toml` if it is there.
>
>     [images]
> ... 8 more lines
> ```
> edit docs/configuration.md
> ```diff
> @@
> -TODO: document the [ignore] table.
> +## `[ignore]`
> +
> +The `[ignore]` table in `rules.toml` lists file names that tidy never moves.
> ```
> I replaced the TODO in `docs/configuration.md` with a short `[ignore]` section:
>
> > ## `[ignore]`
> >
> > The `[ignore]` table in `rules.toml` lists file names that tidy never moves.
>
> This repo has no tidy source, so I couldn't check the table's key format or whether names are matched exactly or by pattern. The section says only what you told me. If you want an example block, send me the format and I'll add one.

`--model sonnet` costs less than the default, `opus`, and `--model haiku`
costs least: its list price is a twentieth of sonnet's. A session keeps
the model it used last, until `--model` names another. `--effort low`
to `max` sets how hard the model thinks (default `medium`).

## sessions

Each session is kept in `sessions.db`, in `$XDG_DATA_HOME/cosmic/agent`
(by default `~/.local/share/cosmic/agent`): each message, each tool's
whole output, and each request with its tokens and cost. It is
written before it is shown.

```text
$ cosmic agent sessions
  id  started              model              msgs  context     cost  first prompt
   6  2026-11-25 21:32:20  claude-haiku-5-5      6     7.3k   $0.001  write a one-line commit message for the uncommitted changes
   5  2026-11-25 21:32:11  claude-haiku-5-5     14    13.0k   $0.002  write a one-line commit message for the uncommitted changes
   4  2026-11-25 21:32:02  claude-haiku-5-5     16     7.9k   $0.002  do the external (http) links in the docs still work?
   3  2026-11-25 21:31:52  claude-haiku-5-5     11     8.7k   $0.002  document the [ignore] table in docs/configuration.md: it lists file names tid...
   2  2026-11-25 21:31:45  claude-haiku-5-5      6     7.4k   $0.001  how would you document the [ignore] table in docs/configuration.md? it lists ...
   1  2026-11-25 21:31:26  claude-haiku-5-5     20    13.1k   $0.004  what does this repository do? keep it short
```

- `ask` and `chat` go on with the newest session in the directory.
  `--new` starts a fresh one, `--session <id>` goes on with any
  session, and `--fork` goes on in a copy.
- A tool output too long to give the model is cut, and a note atop it
  names the output's id. In a `run` program, `Host.output(id)` reads
  it back as the database keeps it, and `Host.history(query)` runs one
  read-only SQL statement on the database. Both see every session.
- A run that ends in the middle of a turn, by a crash or a kill,
  loses nothing: `cosmic agent resume` finishes the turn. Ctrl-C
  stops the turn, and there is nothing to resume.

## other ways in

- A word `-` in `ask`'s prompt stands for all of standard input, and
  `ask` with no words reads its whole prompt there:
  `cosmic agent ask 'summarize this:' - < notes.txt`, or
  `(echo 'read this:'; cat notes.txt) | cosmic agent ask -`.
- `cosmic agent chat` takes one prompt a line until `/exit`. A line
  typed while the model works steers it.
- `cosmic agent ask --json` prints each event as a line of JSON, with
  the tokens and cost of each request, for scripts.
- `cosmic agent rpc` runs a session for another program, with JSON
  commands on standard input and events on standard output.
- [`cosmic.agent`] runs the loop in a program of your own, with tools
  of its own and its own `before` and `after` hooks.
  [`cosmic.agent.show`] shows its events as the verb does, with a
  layout of run's code given.
- `cosmic help agent` lists every option.

[`cosmic.agent.policy`]: ../../cosmic/agent/policy.tl
[`cosmic.agent.show`]: ../../cosmic/agent/show.tl
[`cosmic.agent`]: ../../cosmic/agent/init.tl
[`cosmic.child`]: ../../cosmic/child.tl
[`Host.bash`]: ../../cosmic/agent/host.tl
[`Host.edit`]: ../../cosmic/agent/host.tl
[`Host.exists`]: ../../cosmic/agent/host.tl
[`Host.lines`]: ../../cosmic/agent/host.tl
[`Host.modules()`]: ../../cosmic/agent/host.tl
[`Host.read`]: ../../cosmic/agent/host.tl
[`Host.sort`]: ../../cosmic/agent/host.tl
[`Host.top`]: ../../cosmic/agent/host.tl
[`Host.uniq`]: ../../cosmic/agent/host.tl
[`Host.wc`]: ../../cosmic/agent/host.tl
[`Host.write`]: ../../cosmic/agent/host.tl
[`Host`]: ../../cosmic/agent/host.tl
