---
name: comments
description: The standard for comments in cosmic's code -- what a comment is for, what it leaves out, with examples -- and how to audit a part of the tree against it. Use when writing or reviewing comments, or when asked to audit them.
argument-hint: "[<paths>]"
---

# Comments

A comment says what the code cannot: why it is this way, what it
guarantees, what it assumes, what would break if it changed. A reader
who has the code in front of them should learn something from each
comment, and nothing from it should be wrong.

This holds for every comment in the tree: Teal and Lua (`--`, and `---`
doc comments), C and Zig (`//`, `/* */`, `///`), shell and YAML (`#`).
`vendor/` is not ours and is never edited. Prose documents (`doc/`,
`AGENTS.md`, READMEs) follow `doc/meta.md` instead.

## The standard

1. **Correct.** It matches the code as it is. A comment that disagrees
   with the code is a bug: fix whichever is wrong, and if it is the
   code, that is a separate change with a test, not a comment edit.
   Check every name, path, flag, count and cross-reference it gives.
2. **Necessary.** It explains what the code does not show: a reason, an
   invariant, a contract, a non-obvious consequence, a hazard, a
   platform quirk, a reference to the rule it enforces. A comment that
   restates the code goes.
3. **Clear.** One reading is enough. One idea per sentence, a verb in
   each, the plain word (`doc/meta.md`'s language rules). Name the
   thing, not a pronoun three clauses back. Break a chain of dashes,
   colons and semicolons into sentences.
4. **Concise.** As long as the idea, no longer. Cut a clause that
   repeats the one before it, a second sentence that says the first
   again, and qualifications the reader does not need to act.
5. **No narrative.** A comment describes the code now, not how it came
   to be: no "used to", "previously", "now", "no longer", "we changed",
   no PR or issue numbers as history, no story of a debugging session.
   A regression test says what failure it guards against, in the
   present or conditional ("an open with O_TRUNC would follow ..."),
   not what the code once did. A `TODO:` is not narrative: it names a
   gap and what it waits on (AGENTS.md), and stays.
6. **Refactor before explaining.** When a comment exists because the
   code is hard to follow, prefer clearer code -- a better name, an
   extracted function, a named constant, a simpler branch -- and drop
   the comment it made unnecessary. Keep such refactors small, local
   and behavior-preserving; a larger one is its own change.

Doc comments (`---` in Teal, `///` in Zig, the block above a public C
function) are the reference `cosmic docs` shows, so they say what a
caller needs: what the function takes and returns, how it fails, what
it guarantees. They do not describe the implementation unless the
caller must know it. A module's leading `---` block says what the
module is for and the rules that hold across it.

## Examples

Restates the code:

```lua
-- Close the descriptor and return the error.
sys.close(fd)
return nil, trouble
```

Delete it. When a line needs its reason, give only the reason:

```lua
-- Before anything can fail: `finish` measures from it.
job.started_ns = Time.monotonic_ns()
```

Repeats itself:

```lua
--- Writes all bytes, replacing the path. This is the whole-file alternative
--- to io.open/io.write. Replaces a file atomically for readers, and leaves the old contents in
--- place if anything before the rename fails. This provides atomic visibility,
--- not crash durability: neither the file nor its directory is synchronized.
```

"Replacing", "replaces" and "atomic" each appear twice. One pass:

```lua
--- Writes `data` to `path` through a temporary file and a rename: a
--- reader sees the old contents or the new, never a mix, and a failure
--- before the rename leaves the old file. Nothing is synced, so a crash
--- can still lose the write.
```

Narrative in a regression test:

```lua
local function test_download_never_writes_through_a_planted_part_file(tmp: string)
  -- it used to open path .. ".part" with O_TRUNC, following a symlink
  -- someone else put there, and sharing it with a concurrent download
```

Say what the test guards against:

```lua
local function test_download_never_writes_through_a_planted_part_file(tmp: string)
  -- Opening path .. ".part" with O_TRUNC would follow a symlink planted
  -- there and share the file with a concurrent download.
```

Too dense to read once:

```lua
--- Whether the running binary's database was compiled or written by
--- other code than it carries: a stale tool rebuilding itself compiles
--- the tree and writes the new tool's database with its own compiler and
--- writer, and when either is not the tree's (`work.Identities`), the new
--- tool compiles and writes it again itself, once, so the tool a rebuild
--- leaves is the one a boot writes. A tool whose database names neither
--- was written by a binary from before they did, and is unsettled too.
```

Split the answer from the reason, one idea per sentence:

```lua
--- Whether the running binary's database was compiled or written by
--- code other than the compiler and writer it carries
--- (`work.Identities`). A rebuild uses the stale tool's compiler and
--- writer, so the rebuilt tool compiles and writes its database once
--- more itself; then it matches what a boot writes. A database that
--- records neither identity is unsettled too.
```

A comment standing in for a name:

```c
if (n > 4096) /* longer than a page: read it in chunks */
```

Name the constant and the comment is not needed:

```c
enum { page_size = 4096 };
if (n > page_size)
```

Kept as is -- it says why, which the code cannot:

```lua
-- A regular file says how big it is, so its bytes come in one read
-- into one string of that size; chunks follow only for whatever it
-- holds past that, or for a file that does not say (a pipe, /proc).
```

## Auditing

1. Work in a worktree of its own, per AGENTS.md, and boot it.
2. Read each file whole: a comment is judged against the code around it,
   and a cross-reference against what it names (`o/bin/cosmic docs`,
   `o/bin/cosmic uses`, grep).
3. Fix what fails the standard. Leave a comment that meets it alone:
   the audit is not a rewrite into one voice, and churn costs reviewers.
4. A comment that turns out wrong because the code is wrong is a bug
   report, not a comment fix: leave the comment, add a `TODO:` naming
   the defect, and list it in the PR.
5. `o/bin/cosmic fix <changed-paths>`, then `timeout 30 o/bin/cosmic
   test`. A comment edit in a harness module (`build/harness_epoch.tl`)
   moves its digest: set the lines `build/harness_epoch_test.tl` prints,
   and do not bump `epoch`, since no pass or fail moves. Before pushing,
   `o/bin/cosmic fix --check .`.
6. One PR per coherent part of the tree, titled `<area>: audit comments`.
   Its description gives the kinds of change made, with a few examples,
   any refactor, and any defect found.
