# writing

how prose is written here: docs, doc comments, line comments, and the
instructions in `AGENTS.md`. the rules in the first section hold for
all of it. the sections after add what docs, comments and links need.

## the rules

1. **correct.** it matches the code as it is. check every name, path,
   flag, count and cross-reference it gives. when prose and code
   disagree, one is a bug: see "docs are always right" for a doc and
   "comments" for a comment.
2. **necessary.** it says what the code does not show: a reason, an
   invariant, a contract, a hazard. prose that restates the code goes.
3. **clear.** one reading is enough. see "the language".
4. **concise.** as long as the idea, no longer. cut a clause that
   repeats the one before it and any qualification the reader does not
   need to act.
5. **no history.** prose describes the thing now, not how it got that
   way: no "used to", "previously", "no longer", "we changed", no
   commit, PR or issue numbers, no story of a debugging session. a
   `TODO:` is not history: it names a gap and what it waits on
   ([`AGENTS.md`]), and stays.

## docs are always right

a doc describes either the current state or an intended one. either
way, when the code and the doc disagree, the code is wrong and the
code changes. a doc is never edited to match a bug.

intended behavior that is not yet built is labeled as intended. an
example that cannot run yet uses `skip=intended`.

## every example runs

a doc includes examples. every example is compiled by the build, and
run when it says what it prints. there is no third kind, other than
an explicit skip with a reason.

an example is the shape Go gave it: a function-sized unit with its
own scope, compiled every time, run when it declares its output. a
doc compiles to one Teal file, the same shape as a hand-written test
file and discovered the same way; each example inside it becomes its
own function, never a chunk shared with the others, so a `return` at
an example's end is an ordinary function return and two examples
declaring the same local name never collide. nothing else is
different: the compiled file is a test file, run by the same runner,
under the same assertion and the same eventual isolation, with no
doctest machinery of its own.

- a fenced block tagged `teal` or `lua` opens an example, becoming a
  function's first statements, or joins the one before it when
  tagged `teal continue`, adding more statements to that same
  function. it compiles under the checker.
- a block tagged `teal file=<path>` is a file in that example's
  project rather than a statement in its function; a multi-file
  guide is one example with several files and one entry, the block
  without a `file=`. the entry's own code runs with a `tmp` variable
  in scope, naming the fresh directory holding those files, so it
  reads one back with a path like `tmp .. "/<path>"`.
- a block tagged `output` that follows an example is what the entry
  prints, captured and asserted line by line as that function's own
  assertion. an example with no `output` block compiles and does
  not run.
- a block tagged `teal skip=<reason>` produces no function at all,
  only a comment carrying the reason. `skip=intended` marks an
  example that waits on work not yet done; `skip=network` marks one
  that needs a host the build does not have. a shebang line, real
  only as a file's first line, is always a skip, shown for reading,
  never run.
- a block tagged `text` is prose in a box. nothing runs.
- a line `<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->`, alone and outside any
  fence, is what the doc's examples are held to and read beyond their
  default inputs, as a test module's `Test.policy { ... }` declares it
  ([`cosmic.test`]).
  it renders as nothing, and a doc has one at most.

the build keys each example by content hash like any test and
records its verdict beside the tests. a doc whose example fails is a
failing gate. a skip that no longer needs to be one is a lint
finding.

## docs are short and stand alone

a doc says one thing. a reader gets what they need from that doc
without opening another, except by a link they choose to follow.
prefer a second short doc to a long one.

a doc states what something is for and the details a reader needs to
use it.

## the language

clear technical English in the spirit of a simplified style, not
under its rules. concretely:

- one idea per sentence. short sentences. a verb in each.
- say the thing, not a name for the thing. expand an acronym once.
- prefer the plain word: `use` over `utilize`, `before` over `prior
  to`, `if` over `in the event that`.
- state facts. "the build fails" not "the build should fail".
- an example is worth a paragraph of description. in a doc it runs.
- name the thing, not a pronoun three clauses back.
- break a chain of dashes, colons and semicolons into sentences.

## comments

a comment says what the code cannot: why it is this way, what it
guarantees, what it assumes, what would break if it changed. a reader
who has the code in front of them learns something from each comment.

this holds for every comment in the tree: Teal and Lua (`--` and `---`),
C and Zig (`//`, `/* */`, `///`), shell and YAML (`#`). `vendor/` is not
ours and is never edited.

a comment that disagrees with the code is a bug: fix whichever is wrong.
if the code is wrong, that is a separate change with a test, not a
comment edit.

a regression test's comment says what failure it guards against, in the
present or conditional, not what the code once did.

when a comment exists because the code is hard to follow, prefer clearer
code (a better name, an extracted function, a named constant, a simpler
branch) and drop the comment it made unnecessary. keep such a refactor
small, local and behavior-preserving. a larger one is its own change.

### doc comments

a doc comment (`---` in Teal, `///` in Zig, the block above a public C
function) is the reference `cosmic docs` shows. it says what a caller
needs: what the function takes and returns, how it fails, what it
guarantees. it does not describe the implementation unless the caller
must know it. a module's leading `---` block says what the module is
for and the rules that hold across it.

### examples

a comment that restates the code:

```text
-- Close the descriptor and return the error.
sys.close(fd)
return nil, trouble
```

delete it. when a line needs its reason, give only the reason:

```text
-- Before anything can fail: `finish` measures from it.
job.started_ns = Time.monotonic_ns()
```

a comment that repeats itself:

```text
--- Writes all bytes, replacing the path. This is the whole-file alternative
--- to io.open/io.write. Replaces a file atomically for readers, and leaves the old contents in
--- place if anything before the rename fails. This provides atomic visibility,
--- not crash durability: neither the file nor its directory is synchronized.
```

"replacing", "replaces" and "atomic" each appear twice. one pass:

```text
--- Writes `data` to `path` through a temporary file and a rename: a
--- reader sees the old contents or the new, never a mix, and a failure
--- before the rename leaves the old file. Nothing is synced, so a crash
--- can still lose the write.
```

narrative in a regression test:

```text
local function test_download_never_writes_through_a_planted_part_file(tmp: string)
  -- it used to open path .. ".part" with O_TRUNC, following a symlink
  -- someone else put there, and sharing it with a concurrent download
```

say what the test guards against:

```text
local function test_download_never_writes_through_a_planted_part_file(tmp: string)
  -- Opening path .. ".part" with O_TRUNC would follow a symlink planted
  -- there and share the file with a concurrent download.
```

too dense to read once:

```text
--- Whether the running binary's database was compiled or written by
--- other code than it carries: a stale tool rebuilding itself compiles
--- the tree and writes the new tool's database with its own compiler and
--- writer, and when either is not the tree's (`work.Identities`), the new
--- tool compiles and writes it again itself, once, so the tool a rebuild
--- leaves is the one a boot writes. A tool whose database names neither
--- was written by a binary from before they did, and is unsettled too.
```

split the answer from the reason, one idea per sentence:

```text
--- Whether the running binary's database was compiled or written by
--- code other than the compiler and writer it carries
--- (`work.Identities`). A rebuild uses the stale tool's compiler and
--- writer, so the rebuilt tool compiles and writes its database once
--- more itself; then it matches what a boot writes. A database that
--- records neither identity is unsettled too.
```

a comment standing in for a name:

```text
if (n > 4096) /* longer than a page: read it in chunks */
```

name the constant and the comment is not needed:

```text
enum { page_size = 4096 };
if (n > page_size)
```

a comment kept as it is, because it says why, which the code cannot:

```text
-- A regular file says how big it is, so its bytes come in one read
-- into one string of that size; chunks follow only for whatever it
-- holds past that, or for a file that does not say (a pipe, /proc).
```

## links

a comment or a Markdown file links to what it names with `` [`x`] ``,
`[text](target)`, or `[text][label]` and a `[label]: target` line.
`cosmic fix` fails a link that does not resolve. it also rewrites a code
span that names one symbol or file in full into a link, and
`fix --check` fails on each it would rewrite. a name in backticks that
names nothing, and brackets in any other shape, are prose. a name with
no `.` or `:` resolves only to a declaration of its own file, the Lua
standard library or a file: write another module's symbol in full
([`cosmic.fs.read`]). a shortcut that matches two things fails, so spell
it in full. [`build/links.tl`] holds the rules, the order of
resolution and what counts as prose.

```text
--- Reads the file whole with [`Fs.read`]; the store is described in
--- [the design](doc/design.md#the-database).
```

## auditing

1. work in a worktree of its own and boot it
   ([`doc/contributing.md`]).
2. read each file whole. judge a comment against the code around it,
   and a cross-reference against what it names (`bin/cosmic docs`,
   `bin/cosmic uses`, grep).
3. fix what fails the standard. leave a comment that meets it alone:
   an audit is not a rewrite into one voice, and churn costs reviewers.
4. a comment that is wrong because the code is wrong is a bug report,
   not a comment fix. leave the comment, add a `TODO:` naming the
   defect, and list it in the PR.
5. a comment edit in a harness module ([`build/harness_epoch.tl`]) moves
   its digest. set the lines [`build/harness_epoch_test.tl`] prints and
   do not bump `epoch`: no pass or fail moves.
6. one PR per coherent part of the tree, titled `<area>: audit
   comments`. its description gives the kinds of change made with a few
   examples, any refactor, and any defect found.

[`AGENTS.md`]: ../AGENTS.md
[`build/harness_epoch.tl`]: ../build/harness_epoch.tl
[`build/harness_epoch_test.tl`]: ../build/harness_epoch_test.tl
[`build/links.tl`]: ../build/links.tl
[`cosmic.fs.read`]: ../cosmic/fs.tl
[`cosmic.test`]: ../cosmic/test.tl
[`doc/contributing.md`]: contributing.md
