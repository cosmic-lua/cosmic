# 0002 a built program's help

status: proposed

## context

cosmic's tool documents itself. `cosmic help` lists every verb, `cosmic help
<verb>` prints one verb's page, and `cosmic docs <words>` searches every doc
comment, guide and example. a program built with cosmic has
[`Flags.dispatch`] and [`Flags.help`]: a list of commands, and a usage line,
an `about` and the options of each. a program with many commands writes the
rest itself. one such program carries about 200 lines of it beside its text:
an index by group, a page per command with examples and see-also, a
suggestion for a mistyped command, and a full-text search over the pages
through an FTS5 table it fills each time it runs.

this record takes as given, as intended work, that [`Flags.Command`] holds a
command's group and that [`Flags.dispatch`] suggests the nearest name for a
mistyped command or option. today a command holds `spec`, `about`, `usage`
and `run`. the question is what sits on top: search, and the page model
search needs.

that program's help module could not be read for this record. the evidence
is a stand-in, `ledger`: twelve commands in three groups, each with a
paragraph of text, one or two examples and see-also, and the same four
pieces of machinery in 203 lines, 131 of them the search.

how the tool does it for itself:

- a verb's page is the doc comment of a field of [`cosmic.cli`]'s record, one
  field per verb. a guide is a Markdown file. the build writes every doc
  comment and guide to the `docs` table and indexes it in `docs_fts`, an
  FTS5 table that stems its words ([`build/schema.tl`]).
- `cosmic help <verb>` reads the verb's row at run time, and its options
  from the verb's [`Flags.Command`] ([`build/dispatch.tl`]). `cosmic docs
  <words>` answers a name first and searches when nothing has that name
  ([`build/docs.tl`]). a search matches the rows that carry every word, less
  stop words, ranked by `bm25` with a word in a name weighing ten times one
  in prose. where no row carries every word it offers the rows that carry
  at least half of them and at least two. a misspelled word finds nothing.
- the tool carries the rows of the public standard library alone, and a
  project's own are in its projection, so `cosmic docs` in a project
  answers for both.
- a program `cosmic build` writes carries its modules, their declarations,
  the error catalog and its index, the time zones, the roots, the bill of
  materials and the files under `static/` ([`build/embed.tl`]). its `docs`
  table is there and empty. FTS5 is in every core ([`build.zig`]).
- the lookup, the search and the rendering are in [`build/docs.tl`], and
  `build/` is the tool's alone: no program can call them.

## decision

what a program tells its users is documentation. it is written as the
tree's documentation is written, indexed by the build that indexes the
rest, carried in the program, and answered by the one query path behind
`cosmic docs`. there is one index and one way to ask it, for the tool and
for every program it builds.

this is the roadmap's rule, "new documentation extends the one build-time
index and runtime query path", applied to a program. it rests on principle 8,
"docs are always right": a page in the index is held to what `cosmic fix`
holds every doc to, its links among them. principle 1 has the growth named,
below.

- **the page.** a command's page is a doc comment, on a field named for the
  command in a record, as [`cosmic.cli`] holds the verbs. its first sentence
  is the usage and what the command does, an indented block is an example,
  and a link to another field is see-also. a page that is no command is a
  guide, a Markdown file of the project.
- **what a program carries.** `cosmic build` copies into each program the
  `docs` rows its users read, and the index over them. which rows those
  are is a question of position (principle 2): the modules under the
  program's own `cmd/<name>/`, and the project's guides. the rest of the
  project's doc comments are for its builders and stay in the projection.
- **the query path.** the lookup, the search and the rendering move from
  [`build/docs.tl`] to a public module, `cosmic.doc`, which design.md's core
  tier already names. `cosmic docs` and `cosmic help` call it, and so does a
  program, over the databases it runs from. the verb, its staleness check
  and `cosmic uses` stay in `build/`.
- **help.** [`Flags.dispatch`] answers through the `help` it already
  provides. `prog help <command>` prints that command's page and its
  options, as `cosmic help <verb>` does. `prog help <words>` that name no
  command searches, a name first and words after, as `cosmic docs` does. a
  command with no page keeps the help [`Flags.help`] writes from its record.
  a program that defines `help` itself has opted out, as today.
- **a misspelled word.** the query path gains what it lacks: where a word
  is in no row, it takes the nearest word of the index, by the distance and
  the bound of the suggestion for a mistyped command, and says which word it
  searched for. the build declares a vocabulary table over `docs_fts` for
  it. `cosmic docs` gains the same answer.

what the author of `ledger` writes is the pages, beside the program, and
the lines every dispatching program has:

```teal skip=intended
-- cmd/ledger/pages.tl
local record Pages
  --- `ledger add [options] <date> <amount> <account>`: Records one entry.
  --- The amount is positive for money spent and negative for money
  --- received.
  ---
  ---     ledger add 2026-05-03 42.10 groceries
  ---
  --- Spend 42.10 on food.
  ---
  --- See also [`Pages.edit`], [`Pages.import`].
  add: Flags.Command
end
```

the index answers these pages today, in the project. this is `cosmic docs`
there, for a word only an example holds:

```text
$ cosmic docs groceries
No exact symbol match for 'groceries'; showing related documentation:

cmd.ledger.pages Pages.add (cmd/ledger/pages.tl:17)
  add: Flags.Command
  `ledger add [options] <date> <amount> <account>`: Records one entry. ...

      ledger add 2026-05-03 42.10 groceries

  Spend 42.10 on food.
```

`cosmic docs importing statements` answers `Pages.import` first, by the
stem, and `cosmic docs quarterly` a section of a guide under `doc/guides/`.
`cosmic docs reconsile` answers "nothing named or documented as
'reconsile'". `ledger help groceries` is to print the same row without the
module and the file, which are a builder's.

measured with a prototype, built `--host` on Linux x86_64, where starting
`/bin/true` takes 1.1 ms. the prototype is a change to [`build/embed.tl`]
that copies the rows, and a search in the program that asks `docs_fts`
directly.

- size of the rows. twelve pages add 8 KB to each program.
- size of the code. [`build/docs.tl`] and the seven modules of `build/` its
  queries call are 126 KB of bytecode and 67 KB of stored source. the part
  that moves is less, and each program grows by it: a program of 8.1 MB
  grows by under 195 KB.
- `cosmic build` takes no longer: four programs in 0.2 to 0.4 s with the
  rows or without.
- start-up. `ledger help` and `ledger add` take 1.5 ms. the search loads
  only when it is asked for.
- a search takes 3.5 to 4.1 ms. 2 ms of it loads [`cosmic.store`] to reach
  the program's database, and the query takes 0.3 ms.
- a misspelled word, measured on the tool's own index of 5,598 rows and
  4,101 stems: 6 ms to read the vocabulary and 20 ms to find the nearest in
  Teal. declaring the vocabulary table adds no page to the database.

not measured: the portable artifact, whose database is the one measured
behind three cores in place of one, the macOS cores, and the code that
moves, which the prototype does not have.

of the stand-in's 203 lines of machinery, none is left: the index and the
pages come from the rows, the suggestion from the given work, and the 131
lines of search from the query path. its text is 112 lines of doc comments.

a program's help is tested by an ordinary test. under `cosmic test` the
store of the test's import closure holds the `docs` rows of the modules it
requires ([`build/closure_store.tl`]), so a test that requires the pages
asks the same question a built program does.

## rejected alternatives

each was run against `ledger`, for a word only an example holds, a
misspelled word and a word in another form.

- **an index made at run time from the [`Flags.Command`] records.** the
  stand-in's own way, moved into [`cosmic.flags`]. prototyped: 109 lines,
  about 5 KB a program, a search in 2.4 to 2.7 ms, and 245 ms at 12,000
  pages. it is smaller and it needs nothing from the build. it loses
  because it is a second index and a second query path beside the one the
  roadmap keeps. its pages are values, which `cosmic docs` cannot answer in
  the project, `cosmic fix` cannot hold to the rules of a doc, and a guide
  cannot join.
- **a scorer in Teal over the records.** prototyped in 104 lines, 0.5 ms
  faster than FTS5. the same loss, with a second stemmer and a second
  ranking.
- **every doc comment of the project in the program.** it tells a user of
  `ledger` about records they cannot call, and ships a project's internal
  notes in every copy. prototyped: 24 KB for a project of twelve small
  modules, growing with the source.
- **the query in each program, written against the tables.** the tables
  are not a public surface, and each program would rank its own way. the
  prototype's search is this: it ranks by `bm25` alone and shows a snippet
  with the links' markup in it.
- **a `search` command of its own from [`Flags.dispatch`].** it takes a
  command name from every program, and a program about films or packages
  wants `search` for itself. `help` is already given up.
- **no search: pages and suggestions alone.** a user finds a command only by
  its name or its one line in the index, and each program that wants more
  writes the 131 lines.

## left out

- the examples of a project's `*_example.tl` files, for a program's users:
  they are Teal, and a user's example is a command line in a page.
- `cosmic uses` for a program's users.
- search by meaning ([the semantic search guide](../guides/semantic-search.md)):
  it needs a model, and twelve pages need none.
- shell completion and manual pages. both would read the same rows and the
  same records, and neither is designed here.
- a search across the commands of a nested dispatch, which
  [`Flags.dispatch`] does not have.

## consequences

- `cosmic.doc` is public surface: the lookup, the search and the rendering
  of a row, over databases a caller names. the tables stay private.
- two refusals of [`Flags.dispatch`] change, with its doc comment and its
  tests. `prog help <word>` for a word that names no command answers rows
  where it answered "no such command", and `prog help` with several words
  searches where it answered "help: one command at a time".
- [`cosmic.flags`] requires `cosmic.doc`, inside the function that answers
  help, so a program that asks for no help loads neither it nor SQLite.
- a program's help text is in `cosmic docs` for its builders, and a broken
  link in a page fails `cosmic fix`.
- a program's rows come from three places: its own database when built, the
  projection when run as a file, and the closure's store under `cosmic
  test`. `cosmic.doc` reads whichever the program runs from, and holds its
  answer to the program's own pages in all three.
- the build cannot see which commands a program dispatches, since they are
  values. a page with no command, or a command with no page, is found by a
  test of the program, not by the build.
- every program grows by the query path whether it has pages or not.

## open questions

1. which rows are a program's users'? the decision says position: the
   modules under `cmd/<name>/` and the project's guides. the others are
   every row of the modules the program carries, which is simpler and
   ships the builders' notes, and a mark in the comment, which is a list to
   keep.
2. where does a page sit beside its command? the decision follows
   [`cosmic.cli`]: a record of pages, and the commands in a map beside it,
   joined by name. [writing.md](../writing.md) has a table's entries
   documented by the record that types it, so the commands could be that
   record's value and each field's doc its page. [`Flags.dispatch`] takes a
   map today.
3. examples and see-also: in the page, as decided, or fields of
   [`Flags.Command`], as the given work may have them? in both they are
   written twice. in the record alone the index does not hold them, and a
   search for a word only an example holds finds nothing.
4. how much of [`build/docs.tl`] moves? the decision moves the lookup, the
   search and the rendering. a smaller move takes the search alone and
   leaves a program a plainer page than `cosmic help <verb>` prints.
5. `prog help <words>`, as decided, or a `search` command, or both?

## the pull requests

each stands alone and starts from main once the one before has merged.

1. the given work: groups and suggestions in [`cosmic.flags`]. a
   prerequisite, not this record's.
2. `cosmic.doc`: the lookup, the search and the rendering move out of
   [`build/docs.tl`], which calls them. no behavior changes. depends on
   nothing.
3. the vocabulary table and the nearest word, in `cosmic.doc`, so `cosmic
   docs` answers a misspelled word. depends on 1 for the distance, and on 2.
4. `cosmic build` carries a program's rows, with the rule for which, a test
   on a built program and the growth of the portable artifact. it changes
   `cosmic build`, so it is checked on a tool booted with every core.
   depends on nothing.
5. `prog help <command>` and `prog help <words>` in [`Flags.dispatch`], and
   the section of [the command-line guide](../guides/command-line.md) that
   shows a program's help. depends on 2, 3 and 4.

[`build.zig`]: ../../build.zig
[`build/closure_store.tl`]: ../../build/closure_store.tl
[`build/dispatch.tl`]: ../../build/dispatch.tl
[`build/docs.tl`]: ../../build/docs.tl
[`build/embed.tl`]: ../../build/embed.tl
[`build/schema.tl`]: ../../build/schema.tl
[`cosmic.cli`]: ../../cosmic/cli.tl
[`cosmic.flags`]: ../../cosmic/flags.tl
[`cosmic.store`]: ../../cosmic/store.tl
[`Flags.Command`]: ../../cosmic/flags.tl
[`Flags.dispatch`]: ../../cosmic/flags.tl
[`Flags.help`]: ../../cosmic/flags.tl
