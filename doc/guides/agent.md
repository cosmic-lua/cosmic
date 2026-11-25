# cosmic agent

<!-- policy: profiles = { "cosmic" } -->

`cosmic agent` is a small coding agent. It is Claude, with tools that
read, edit and write the files of one directory, held to a sandbox.
This guide shows how it works, from an API key to a fixed project.

What it gives you:

- **Checked programs in place of shell commands.** The main tool,
  `run`, takes a short program in the cosmic environment. The agent
  type-checks it before it runs it. A refused program runs nothing,
  and the refusal says how to fix it.
- **No shell by default.** The default tools are `run`, `read`,
  `edit` and `write`. On Linux, they run no program. `bash` and
  background jobs come only with `--with bash,jobs`.
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
run with the default model, Opus. A line `...` marks text cut from
this guide.

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
> for _, p in ipairs(Host.find(".")) do
>   if not p:match("^%./%.git/") then print(p) end
> end
> for _, p in ipairs(Host.find(".")) do
>   if p:lower():match("readme") then print(Host.cat(p):sub(1, 1500)) end
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
> **tidy** is a tool that sorts the files in a folder into subfolders by file type. It works out the types from the IANA media types list, and it's MIT licensed.
>
> The repo only has documentation: `README.md`, `LICENSE`, and `docs/` (install, usage, configuration, FAQ). There's no source code in it.
>
> One thing I noticed: the README links to `docs/config.md`, but the file is actually `docs/configuration.md`, so that link is broken.

The output is Markdown, so a Markdown viewer shows it as above. Each
tool call goes to standard error, in a code fence:

- `teal`: a `run` program, laid out as `cosmic fix` lays out a file.
  The fence names the language, so a viewer colors it.
- `console`: a `bash` command, behind `$ `.
- `diff`: an `edit`, after a line `edit <path>`. `@@` starts each
  replacement, `-` marks what it takes out, `+` what it puts in, and a
  line that starts with a space is unchanged context.
- `output`: the first 6 lines of what `run` or `bash` printed.
- `error`: the first 12 lines of what a call that failed said.

The `teal`, `console` and `diff` fences show 12 lines at most. A line
`... N more lines` says how many more there are. `read` and `write`
show one line, such as `read README.md`. A fence is longer than any
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

> cosmic: agent: going on with session 1 (4 messages, claude-opus-5-5); --new starts a fresh one
> ```teal
> for _, p in ipairs(Host.find("docs")) do
>   print("=== " .. p)
>   print(Host.cat(p))
> end
> ```
> ```output
> === docs/configuration.md
> # Configuration
>
> tidy reads `~/.config/tidy/rules.toml` if it is there.
>
>     [images]
> ... 37 more lines
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
> -(instal.md)
> +(install.md)
> ```
> edit docs/usage.md
> ```diff
> @@
>  Use `--dry-run` to see the moves first. See the [FAQ](faq.md).
> +
> +## Undo
> +
> +tidy never deletes files, it only moves them. To undo the moves, run
> +`tidy --undo`.
> ```
> I fixed the three broken links:
>
> - **`README.md`**: `docs/config.md` now points to `docs/configuration.md`.
> - **`docs/faq.md`**: `instal.md` now points to `install.md`.
> - **`docs/faq.md`**: the `usage.md#undo` link was broken because `docs/usage.md` had no Undo section. I added one that repeats what the FAQ says:
>
> ...
>
> I checked the other links in the docs by reading them, including `install.md` → `faq.md#macos-says-the-file-is-damaged`, and their targets all exist. I didn't run a link checker.

To check the work, ask again, or look with your own tools
(`git diff`). A program the checker refuses runs nothing, and the
refusal goes back to the model as an error:

```sh
cosmic agent ask 'now check every relative link in every .md file, including #anchors, and list any that are still broken'
```

> cosmic: agent: going on with session 1 (10 messages, claude-opus-5-5); --new starts a fresh one
> ```teal
> local function dirname(p: string): string
>   return p:match("^(.*)/[^/]*$") or "."
> end
> local function normalize(p: string): string
>   local parts: mut {string} = {}
>   for seg in p:gmatch("[^/]+") do
>     if seg == ".." then
>       if #parts > 0 and parts[#parts] ~= ".." then
>         table.remove(parts)
>       else
>         parts[#parts + 1] = ".."
>       end
> ... 63 more lines
> ```
> ```error
> The checker refused the snippet, so it did not run:
> run.tl:50:14: `resolved:match("%.md$") and anchors(resolved)[frag] == nil` is `boolean?`: nil and false would not be ...
> run.tl: 1 error of condition_type in its bodies on line 50; follow the fix above
> ```
> ```teal
> local function dirname(p: string): string
> ...
> ```
> ```output
> 13 relative links checked, 0 broken; files: README.md, docs/configuration.md, docs/faq.md, docs/install.md, docs/usag...
> ```
> No relative links are broken now. I checked all 13 relative links in the 5 `.md` files (`README.md` and the four in `docs/`).
>
> ...

## the tools

The model is offered these tools by default:

- `run`: a program in the cosmic environment, in a worker kept for the
  session. One program does the work of many tool calls and prints
  only what the model needs. The agent type-checks it first: a
  refusal runs nothing and names the fix.
- `read`: a file's text, from a line, cut to a size.
- `edit`: exact text replacements in one file, several in one call.
- `write`: a new file, or a whole file again.

A `run` program reaches the directory through [`Host`]. Its calls do
as the commands they are named for, but give values in place of text,
and raise where they fail:

- `Host.find(dir, suffix?)`: every file under `dir`, sorted.
- [`Host.cat`], [`Host.lines`], [`Host.wc`], [`Host.exists`], [`Host.write`].
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

These tools are offered only when you ask for them:

- `bash`: a shell command in the directory, under the same sandbox.
- `jobs`: commands that run in the background, each in a sandbox of
  its own.

`--with bash,jobs` adds tools, `--without write` takes one out, and
`--tools run,read` names all of them. `cosmic agent prompt` prints the
system prompt the model reads.

Without bash, the model does with `Host` and cosmic's modules what a
program would. With bash, it runs your programs (`git`, `make`, the
project's tests), so the sandbox is its only fence. The same prompt,
both ways:

```sh
cosmic agent ask --new 'write a one-line commit message for the uncommitted changes'
```

The model reads `.git` itself. It lists the modules, reads the docs of
[`cosmic.compress`], and decodes git's objects with it. This takes 7
programs, 2 of them refused and fixed, and $0.09.

```sh
cosmic agent ask --new --with bash,jobs 'write a one-line commit message for the uncommitted changes'
```

> ```console
> $ git status --short && git diff HEAD --stat && git diff HEAD | head -300
> ```
> ```output
>  M README.md
>  M docs/configuration.md
>  M docs/faq.md
>  M docs/usage.md
>  README.md             | 2 +-
>  docs/configuration.md | 5 ++++-
> ... 54 more lines
> ```
> Here's a commit message based on `git diff HEAD`:
>
> ```
> docs: fix broken links, add Undo section and document the [ignore] table
> ```
>
> ...

This takes 1 command and $0.03.

## the sandbox

`cosmic agent policy` prints what the tools may reach here, path by
path, with the same flags, before you run anything. Here, paths in
your home are shown as `~`:

```text
$ cosmic agent policy
programs: none run, since no tool offered is bash: the sandbox lets no file but cosmic's own run, whatever x the grants below give (--with bash runs them)
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
- **Programs.** With the default tools, on Linux, no file but cosmic's
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
macOS it runs under Seatbelt. `read`, `write` and `edit` run in the
agent itself and check each path against the same grants.
[`cosmic.agent.policy`] holds the details.

These flags change it:

- `--sandbox read`: the tools change nothing, and the model is offered
  no `edit` or `write`. Use it for advice.
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
> ```output
> README.md:12: The file types come from [the IANA media types list](https://www.iana.org/assignments/media-types/media...
> fetch failed: host: fetch: https://www.iana.org/assignments/media-types/media-types.xhtml: Could not resolve host: ww...
> ```
> I couldn't check whether the link works, because this sandbox has no network access. The fetch failed with "Could not resolve host: www.iana.org (Could not contact DNS servers)".
>
> ...

With `--network`, the same session goes on:

```sh
cosmic agent ask --network 'ok, try again'
```

> cosmic: agent: going on with session 4 (10 messages, claude-opus-5-5); --new starts a fresh one
> ```teal
> local ok, r = pcall(Host.fetch, "https://www.iana.org/assignments/media-types/media-types.xhtml", { method = "HEAD" })
> if ok then
>   print(r.status, r.headers["location"] or "")
> else
>   print("fetch failed: " .. tostring(r))
> end
> ```
> ```output
> 302	/assignments/media-types
> ```
> ...
> The link still works, but it now redirects.
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
> print(Host.cat("docs/configuration.md"))
> for _, g in ipairs(Host.grep("ignore", Host.find(".", ""), true)) do
>   print(g.path .. ":" .. tostring(g.line) .. ": " .. g.text)
> end
> ```
> ```output
> # Configuration
>
> tidy reads `~/.config/tidy/rules.toml` if it is there.
>
>     [images]
>     folder = "pictures"
> ... 9 more lines
> ```
> cosmic: agent: ask: the turn's budget is spent: 2 requests, of 2; go on with `cosmic agent ask --session 1 'go on'` and a larger --budget

It exits 1. To go on, send a prompt with a larger budget:

```sh
cosmic agent ask --budget turns=6 'go on'
```

> cosmic: agent: going on with session 1 (5 messages, claude-opus-5-5); --new starts a fresh one
> edit docs/configuration.md
> ```diff
> @@
> -The [ignore] table is not documented yet.
> +## [ignore]
> +
> +The `[ignore]` table lists file names that tidy never moves.
> +
> +    [ignore]
> +    names = ["README.md", "todo.txt"]
> ```
> I added a short `## [ignore]` section to `docs/configuration.md`, in place of the "not documented yet" line. It says the table lists file names tidy never moves, and gives an example:
>
> ```toml
> [ignore]
> names = ["README.md", "todo.txt"]
> ```
>
> The key name `names` is my guess. I searched the repo and found no code that reads `[ignore]`, so I couldn't check what tidy actually expects. Please change `names` to the real key, or tell me what it is and I'll update the doc.

`--model sonnet` costs less than the default, `opus`. A session keeps
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
   6  2026-11-25 02:28:43  claude-opus-5-5       4     5.3k   $0.034  write a one-line commit message for the uncommitted changes
   5  2026-11-25 02:28:22  claude-opus-5-5      12    11.6k   $0.091  write a one-line commit message for the uncommitted changes
   4  2026-11-25 02:28:00  claude-opus-5-5      16     6.6k   $0.064  do the external (http) links in the docs still work?
   3  2026-11-25 02:27:48  claude-opus-5-5       9     4.8k   $0.026  document the [ignore] table in docs/configuration.md: it lists file names tid...
   2  2026-11-25 02:27:37  claude-opus-5-5       6     4.4k   $0.040  how would you document the [ignore] table in docs/configuration.md? it lists ...
   1  2026-11-25 02:27:04  claude-opus-5-5      16     8.7k   $0.122  what does this repository do? keep it short
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
[`cosmic.compress`]: ../../cosmic/compress.tl
[`Host.cat`]: ../../cosmic/agent/host.tl
[`Host.exists`]: ../../cosmic/agent/host.tl
[`Host.lines`]: ../../cosmic/agent/host.tl
[`Host.modules()`]: ../../cosmic/agent/host.tl
[`Host.sort`]: ../../cosmic/agent/host.tl
[`Host.top`]: ../../cosmic/agent/host.tl
[`Host.uniq`]: ../../cosmic/agent/host.tl
[`Host.wc`]: ../../cosmic/agent/host.tl
[`Host.write`]: ../../cosmic/agent/host.tl
[`Host`]: ../../cosmic/agent/host.tl
