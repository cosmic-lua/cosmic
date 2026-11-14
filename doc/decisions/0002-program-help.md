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
suggestion for a mistyped command, and a full-text search over the pages.

this record takes as given, as intended work, that [`Flags.Command`] holds a
command's group, its examples and its see-also, and that [`Flags.dispatch`]
suggests the nearest name for a mistyped command or option. today a command
holds `spec`, `about`, `usage` and `run`. the question is what sits on top:
search, and the page model search needs.

that program's help module could not be read for this record. the evidence
is a stand-in, `ledger`: twelve commands in three groups, each with a
paragraph of text, one or two examples and see-also, and the same four
pieces of machinery in 203 lines.

how the tool does it for itself:

- a verb's page is the doc comment of a field of [`cosmic.cli`]'s record, one
  field per verb. the build writes every doc comment to the `docs` table
  and indexes it in `docs_fts`, an FTS5 table that stems its words
  ([`build/schema.tl`]). `cosmic help <verb>` reads that row at run time
  from the databases the tool reads ([`build/dispatch.tl`]).
- `cosmic docs <words>` matches rows that carry every word, less stop words,
  and ranks them by `bm25` with a word in a name weighing ten times one in
  prose, after orderings that are about symbols ([`build/docs.tl`]). where no
  row carries every word, it offers the rows that carry at least half of
  them and at least two, which widens a query of three words or more. a
  misspelled word finds nothing: `cosmic docs reconsile` answers "nothing
  named or documented".
- a program `cosmic build` writes carries its modules, their declarations,
  the error catalog and its index, the time zones, the roots, the bill of
  materials and the files under `static/` ([`build/embed.tl`]). its `docs`,
  `uses` and `examples` tables are empty. FTS5 is in every core, where it
  costs about 222 KB ([`build.zig`]).

three facts decide the question.

1. the build reads source, never values. a comment inside a table
   constructor is no doc, so an index made at build time holds text written
   as doc comments or as Markdown, and cannot hold a field of a
   [`Flags.Command`]. the fields this record takes as given are values.
2. `docs` and `uses` answer "what a builder reads" ([design.md](../design.md),
   "the command line"), said there of a project's code and the standard
   library. this record adds that a program's user is not its builder: the
   help of `ledger add` is for someone who has never seen `ledger`'s source,
   and the doc comment of the function behind it is not.
3. a program runs from more than one database. built, it reads the database
   `cosmic build` gave it. run as `cosmic cmd/ledger/main.tl` it reads the
   project's projection, and under `cosmic test` the store of a test's
   import closure ([`build/closure_store.tl`]).

## decision

what a program tells its users about itself is a value of the program, made
and searched at run time. what a builder reads about code is a row of the
build's index. each kind has one home: a program's help is never written to
the database it carries, and the documentation of its modules is never shown
to its users.

the record rests on principle 5, "the least tree that keeps its promises":
no table, no build step and no second page model are added. it rests on
promise 2, efficiency, for the builder who would write the search and for
the user who cannot find a command. principle 1 has the growth named, below.

so the page of a command is its [`Flags.Command`], and search is a function of
the commands a program hands [`Flags.dispatch`]:

- [`cosmic.flags`] gains one function, sketched here as `Flags.search`, that
  takes the commands and the words asked for and answers the pages that
  match, best first, each with the line that matched.
- it builds an FTS5 table in memory, from the records, each time it is
  asked: a row per command, with the name, `about`, the text and the
  options, and the examples as columns of their own. the tokenizer is
  `porter unicode61`, as `docs_fts` has it, so "importing" finds "import".
  the rule for which words of a query count, stop words and one-letter words
  among them, is the one `cosmic docs` uses, kept once in a module under
  `cosmic.internal` that [`build/docs.tl`] reads too. the prototype does
  not have this rule, and its figures leave it out.
- rank is `bm25` over the columns, a word in the name above one in `about`,
  above one in an example, above one in the text.
- nearest has two meanings, tried in this order when no page carries every
  word. the first is the pages that carry at least half of the words and at
  least two, as `cosmic docs` has it. the second replaces each word no page
  carries with the word of the pages nearest to it, and searches again. the
  distance and its bound are those of the suggestion for a mistyped
  command. the words compared are the pages' own, not their stems. the
  answer says which words it searched for instead.
- [`Flags.dispatch`] answers it through the `help` it already provides:
  `prog help <command>` is that command's page, and `prog help <words>` that
  name no command searches. this is `cosmic docs`' own rule, a name first
  and words after. it adds no command a program's own could collide with,
  and a program that defines `help` itself has opted out, as today. the
  program's index ends with a line saying so. where nothing is found the
  answer is nil and why, `help: no page says "zzzz"`, which a program prints
  and exits 2 on, as it does for any refusal.
- a page that is no command, such as `cosmic help exit`, is a
  [`Flags.Command`] with no `run`, which [`Flags.dispatch`] already describes
  and refuses to run.

what the author of `ledger` writes is the records and the lines every
dispatching program has:

```teal skip=intended
local ran, why = Flags.dispatch(argv, 1, commands, "ledger")
if ran == nil then
  Fs.put(Fs.stderr, "ledger: " .. why .. "\n")
  return 2
end
if ran.help ~= "" then print(ran.help) end
return ran.code
```

what its user sees, for a word that only an example holds, a misspelled
word, a word in another form, and three words of which no page carries
all:

```text
$ ledger help groceries
  ledger add      Records one entry.
      ledger add 2026-05-03 42.10 [groceries] -- spend 42...

$ ledger help reconsile
no page says "reconsile"; nearest is "reconciles":
  ledger check    Reconciles the ledger against a statement.
      [Reconciles] the ledger against a statement.

$ ledger help importing statements
  ledger import   Reads entries from a bank's CSV export.
      ledger [import] --bank triodos may.csv -- a month's statement...

$ ledger help statement csv zzzz
no page says all of "statement csv zzzz"; these say some of it:
  ledger import   Reads entries from a bank's CSV export.
      Reads a [statement] a bank exported and adds each row...
  ledger check    Reconciles the ledger against a statement.
      Compares the entries with a bank [statement] and lists what...
```

measured with a prototype of this search, built `--host` on Linux x86_64,
where starting `/bin/true` takes 1.1 ms:

- start-up. `ledger help` and `ledger add` take 1.5 ms with search in the
  program or without, since the search and [`cosmic.sqlite`] load only when
  search is asked for.
- a search takes 2.4 to 2.7 ms, and one that falls to the nearest word 5.1
  to 5.5 ms, most of it the distance to each word of the pages, in Teal.
- more pages. the same twelve pages indexed ten times over take 6 ms, a
  hundred times over (1,200 pages) 27 ms, and a thousand times over 245 ms.
- memory. a search of 12 or of 1,200 pages adds nothing measurable to the
  peak resident memory of `ledger help`, and one of 12,000 adds 8 MB.
- size. the prototype's search is 109 lines, about 5 KB as a module's
  stored source and bytecode. a program carries the library's modules, so
  the tool and each program grow by about that. no table is added.
- `cosmic build` is unchanged: it writes nothing new.

not measured: the portable artifact, whose database is the one measured
behind three cores in place of one, the macOS cores, and the shared rule
for a query's words.

the search is a pure function of records, so its tests are ordinary tests in
[`cosmic/flags_test.tl`] that declare nothing, and its examples run in
[`cosmic/flags_example.tl`].

of the stand-in's 203 lines of machinery, the work this record takes as
given removes 72: the index, the page, the distance and the suggestion. this
decision removes the other 131: 109 of search, 13 that show the results and
9 that wire them to `help`.

## rejected alternatives

each was run against `ledger` and the same three queries.

- **the pages indexed at build time, searched with the machinery behind
  `cosmic docs`.** the text moves to doc comments on a record with a field
  per command, as [`cosmic.cli`] holds the verbs, and `cosmic build` copies
  those `docs` rows into the program. prototyped: the program grows by 8 KB
  for twelve pages, `cosmic build` takes no longer, and the query takes 0.3
  ms of a search of 3.5 to 4.1 ms, 2 ms of which loads [`cosmic.store`] to
  reach the database. it ranked the same page first for the first and
  third query. two reasons carry its rejection.
  - it is a second page model. the examples, see-also and group are fields
    of [`Flags.Command`]; the text would be a comment on a field of another
    record. a command is then written in two places that a check must hold
    together, and `about` is written twice or read back out of the comment.
    the build cannot read the fields instead: a program makes its commands
    with code, a shared spec or a loop, and the build runs none of it.
  - the rows come from three databases (fact 3), each with its own writer.
    a run-time index is the same in all three.

  two more weigh less. little of [`build/docs.tl`] transfers: its 3,400
  lines rank symbols, by what a function stands in for, a member before a
  field, a module before a member, which database owns a module. a page
  has none of these, and what does transfer the decision shares. and a
  misspelled word costs it the same scan of the pages' words in Teal that
  the decision makes: an FTS5 table's own vocabulary is out of reach, since
  the program's database refused the table that reads it ("not
  authorized").

  this narrows the roadmap's rule that new documentation extends the one
  build-time index: it is read here as a rule for what a builder reads, and
  the roadmap is amended to say so.
- **the same index, holding the doc comments and examples of the program's
  own modules too.** it tells a user of `ledger` about `Pages.Page`, which
  they cannot call, and ships a project's internal notes in every copy.
  prototyped: 24 KB for a project of twelve small modules, growing with the
  source. `cosmic docs` in the project already answers the builder.
- **a scorer in Teal in place of FTS5.** prototyped in 104 lines against
  109, and about 0.5 ms faster. it found the same pages for the three
  queries. it loses because it is a second stemmer and a second ranking to
  keep beside the ones `cosmic docs` uses, four suffixes beside Porter's
  rules and a sum of weights beside `bm25`, with no snippet. FTS5 is already
  paid for in every core.
- **functions only, wired by each program.** `Flags.search` stays public for
  a program that reads its own line, as [`Flags.help`] and
  [`Flags.asks_help`] are. left as the only way, each program writes a
  command and a printer, 22 lines in the stand-in, and programs differ in
  what the search is called.
- **a `search` command of its own from [`Flags.dispatch`].** it takes a
  command name from every program, and a program about films or packages
  wants `search` for itself. the `help` a program already gives up says the
  same thing in one word fewer.
- **no search: pages and suggestions alone.** a user finds a command only by
  its name or its one line in the index. `ledger help groceries` answers "no
  such command: groceries", and the 131 lines stay in each program that
  wants more, shown once in a guide. the reasons above do not defeat this
  alternative by themselves: it stands or falls on open question 1.

## left out

- Markdown pages of a project built into its program, as cosmic's guides
  are built into the tool. a page that is no command covers a topic, and a
  long one waits on a program that needs it.
- the documentation of a program's modules, for its users (above).
- search by meaning ([the semantic search guide](../guides/semantic-search.md)):
  it needs a model, and twelve pages need none.
- `cosmic help <words>` for the tool itself. the tool's verbs are documented
  for builders, in the index, and `cosmic docs` searches them.
- shell completion and manual pages. both are values of the same records,
  and the decision says where they would be made: at run time, from the
  commands.
- a search across the commands of a nested dispatch, which
  [`Flags.dispatch`] does not have.

## consequences

- [`cosmic.flags`] requires [`cosmic.sqlite`], inside the function that
  searches. a program that never searches loads neither the search nor
  SQLite for it.
- two refusals of [`Flags.dispatch`] change, with its doc comment and its
  tests. `prog help <word>` for a word that names no command answers pages
  where it answered "no such command", and `prog help` with several words
  searches where it answered "help: one command at a time". a mistyped
  command after `help` is answered by the nearest word of the pages, which
  includes every command's name, not by the suggestion.
- the tool and a built program hold their pages differently by design:
  [`cosmic.cli`] in doc comments, a program in records.
- a program's help text lives in its records, in its source, as values. it
  is not in `cosmic docs`, and a builder reads it in the file.
- [`cosmic.cli`] keeps its text in doc comments, since `cosmic docs Cli.test`
  must answer it: the tool is a program whose users are builders.
- a program with thousands of pages pays to index them on each search, a
  quarter of a second at 12,000. such a program builds the index once and
  keeps it, which is a later option of `Flags.search`, not a second design.

## open questions

the decision above is the recommendation. each question names where the
owner may hold otherwise.

1. is one program enough? [0001](0001-friction-triage.md) holds that a guide
   suffices until the same code is copied into several apps. the search is
   in one, and this record measured a stand-in for it. the case for an
   exception: the search reads only library records, so no line of it
   varies by program, and its absence is felt by the program's user, whom a
   guide for builders does not reach. the case against: twelve pages may
   need no search, and the given work already answers a mistyped command.
   if the answer is no, the search ships as a guide and this record is
   declined.
2. `prog help <words>`, as decided, or a `search` command, or both?
3. the search in [`cosmic.flags`], as decided, which then loads
   [`cosmic.sqlite`] on demand, or in a module of its own?
4. is the long text of a page a field of [`Flags.Command`], and does the given
   work add it? the search reads `about` and the examples without it, and
   ranks a page poorly that has only those.
5. the suggestion's bound on the nearest word, as decided, or one of its
   own? a long word misspelled twice is common, and a short command name
   misspelled twice is another command.

## the pull requests

each stands alone and starts from main once the one before has merged.

1. the given work: group, examples, see-also and suggestions in
   [`cosmic.flags`]. a prerequisite, not this record's: the record is
   accepted only with it.
2. the rule for a query's words moves from [`build/docs.tl`] to a module
   under `cosmic.internal`, with its tests. no behavior changes. depends on
   nothing.
3. `Flags.search`: the index, the rank, both meanings of nearest, tests and
   examples, and its size on the portable artifact. depends on 1 for the
   fields and the distance, and on 2.
4. `prog help <words>` in [`Flags.dispatch`]: the two refusals that change,
   its doc comment, the index's last line, the roadmap's rule amended, and
   the section of [the command-line guide](../guides/command-line.md) that
   shows a program's help. depends on 3.

[`build.zig`]: ../../build.zig
[`build/closure_store.tl`]: ../../build/closure_store.tl
[`build/dispatch.tl`]: ../../build/dispatch.tl
[`build/docs.tl`]: ../../build/docs.tl
[`build/embed.tl`]: ../../build/embed.tl
[`build/schema.tl`]: ../../build/schema.tl
[`cosmic.cli`]: ../../cosmic/cli.tl
[`cosmic.flags`]: ../../cosmic/flags.tl
[`cosmic.sqlite`]: ../../cosmic/sqlite.tl
[`cosmic.store`]: ../../cosmic/store.tl
[`cosmic/flags_example.tl`]: ../../cosmic/flags_example.tl
[`cosmic/flags_test.tl`]: ../../cosmic/flags_test.tl
[`Flags.asks_help`]: ../../cosmic/flags.tl
[`Flags.Command`]: ../../cosmic/flags.tl
[`Flags.dispatch`]: ../../cosmic/flags.tl
[`Flags.help`]: ../../cosmic/flags.tl
