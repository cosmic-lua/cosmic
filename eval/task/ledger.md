# Task

You have one tool you have never seen before: `cosmic`, a runtime for
command-line programs written in Teal (typed Lua). It is on your PATH.
The binary is the only source of information about it: there is no
documentation, repository, website, or package index for it, and you
must not use skills, plugins, web search, or any prior knowledge of a
project called "cosmic". Treat it as unknown. Anything the binary itself
tells you (help text, error messages, output of any command you can
think of running against it, or inspecting the file itself) is fair game.

Work only inside this directory. Do not read or write anything outside it
except the `cosmic` binary and scratch files under `$TMPDIR`, which is
yours for anything temporary.

## What to build

A small project, `ledger`, in Teal, using cosmic. It is a command-line
tool that summarizes a CSV file of transactions as JSON:

- `report <file>` reads `<file>`, a CSV file (RFC 4180: fields may be
  quoted, and a quoted field may hold commas, doubled quotes and line
  breaks) whose first line is the header `when,amount,category,note`:
  - `when` is an RFC 3339 timestamp with an offset, such as
    `2026-01-31T23:30:00-05:00`;
  - `amount` is a decimal number of currency units with at most two
    decimal places, possibly negative (`12`, `-3.5`, `0.25`);
  - `category` is a word; `note` is free text and is ignored.
- It prints one JSON object to stdout:
  `{"months": [...], "rows": <n>, "skipped": <n>}`. `months` holds one
  object per calendar month that has transactions, in ascending order:
  `{"month": "YYYY-MM", "total_cents": <integer>, "categories":
  {"<category>": <integer cents>, ...}}`. `rows` counts the
  transactions included, `skipped` every record that was refused,
  whatever its date. A transaction outside `--from`/`--to` (below) is
  neither: it is not in `rows` and not in `skipped`.
- Options, which may come before or after `<file>`:
  - `--zone <name>`: an IANA time zone name such as `America/New_York`.
    Months, and the dates below, are calendar dates in that zone; the
    default is UTC. An unknown zone is an error.
  - `--from <YYYY-MM-DD>` and `--to <YYYY-MM-DD>`: include only
    transactions on or after, and on or before, that date in the zone.
- A record whose `when` or `amount` cannot be read is skipped, and a
  line on stderr says so, `line <n>: <reason>`, where `<n>` is the line
  of the file the record starts on (the header is line 1; a quoted
  field with line breaks in it makes a record span several lines). A
  skipped record does not change the exit code.
- A missing file, a file that is not CSV, a header other than the one
  above, or a bad option is an error: a message on stderr and a
  non-zero exit code.
- `help`: prints usage naming `report` and every option above, to
  stdout, and exits 0. Run this one with no other arguments.
- Use cosmic's own CSV, JSON and time support rather than writing your
  own parsers or calendar arithmetic.

The project's library module is named `ledger`, `require("ledger")`,
and exports at least this API, which the project's own program uses and
which is checked through these names and types:

- `ledger.Transaction`, a record of one transaction read: `line:
  integer` (the line its record starts on), `at: integer` (its `when`
  as whole seconds since the Unix epoch), `cents: integer`,
  `category: string` and `note: string`.
- `ledger.Skip`, a record of one record refused: `line: integer` and
  `reason: string`.
- `ledger.Parsed`, a record: `transactions: {ledger.Transaction}` and
  `skipped: {ledger.Skip}`, each in file order.
- `ledger.parse(text: string): ledger.Parsed | nil, string`: the CSV
  text read, or nil and why it is no such file (not CSV, the wrong
  header).
- `ledger.Options`, a record: `zone: string` (nil for UTC), `from:
  string` and `to: string` (`YYYY-MM-DD`, nil for no bound).
- `ledger.Month`, a record: `month: string`, `total_cents: integer`
  and `categories: {string: integer}`, as in the JSON above.
- `ledger.Report`, a record: `months: {ledger.Month}` in ascending
  order, and `rows: integer`.
- `ledger.summarize(transactions: {ledger.Transaction}, options:
  ledger.Options): ledger.Report | nil, string`: the months and rows
  `report` prints for those transactions, or nil and why for an
  unknown zone or a malformed date.

The project must have all four of these:

1. **Tests** of the project's own code, which cosmic runs and passes.
   Show them passing.
2. **Examples**: worked examples of using the project's own code, in
   whatever form cosmic treats as an example, so that cosmic itself
   checks or runs them.
3. **Formatting**: every Teal source formatted the way cosmic itself
   formats Teal.
4. **A binary**: a single standalone executable named `ledger`, produced
   by cosmic from this project, that runs the tool above on its own:
   copied alone into an empty directory and run with an empty
   environment (no `PATH`, no `HOME`, no `cosmic` anywhere), it still
   works. Show it running: `./ledger report some.csv --zone Europe/Berlin`.

How cosmic finds tests and examples, formats code, and produces a
binary is for you to find out from the binary.

## Deliverables, all in this directory

1. The project: source, tests, examples, and the produced `ledger`
   executable, working as far as you can get them.
2. `JOURNAL.md`, described below.
