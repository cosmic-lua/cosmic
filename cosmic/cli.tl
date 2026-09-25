--- cosmic's own command-line verbs -- `cosmic test`, `cosmic build`
--- and the rest -- one field per verb, so `cosmic docs test` (or build,
--- fix, db, sql, docs, uses, todos, help, run, standalone, eval,
--- version) answers
--- with what that verb does. This is not an argument parser for a
--- project's own command line: a project's cmd/<name>/main.tl gets its
--- arguments as a plain array, and `Flags.parse(argv, 1, spec)` from
--- cosmic.flags reads its options, or `Flags.dispatch(argv, 1,
--- commands)` its commands -- see argv.
---
--- `cosmic help` is generated from these fields (`build/dispatch.tl`'s
--- `verb_help`), in the order `order` gives, rather than keeping a
--- second, hand-written copy of the same wording, and each verb's
--- options beneath its prose from `options`, the spec the verb parses
--- its command line with.

local Flags = require("cosmic.flags")

--- One field per verb, each the verb's own line of `cosmic help`.
local record Cli
  --- `cosmic <file.tl>`: builds the tree the file sits in -- the
  --- working directory when the file is under it, so a file of a
  --- project reaches the rest of it; the file's own directory
  --- otherwise -- then runs it: requires the file, and if what it
  --- returns is a function, calls it with one argument -- see argv --
  --- and exits with the integer it returns, or 0
  run: string
  --- `cosmic --standalone <file.tl>`: runs one file against this
  --- binary's own standard library, with no tree around it -- nothing
  --- staged or built, nothing under o/ written, and no staleness
  --- check, so it runs the same whatever state the working directory
  --- is in. The file may require `cosmic.*` modules only; it is
  --- checked and compiled in memory (a clean compile is cached under
  --- $XDG_CACHE_HOME/cosmic/standalone), then called as `run` calls
  --- one -- see argv -- with a record's `main` field standing for a
  --- returned function
  standalone: string
  --- `cosmic -e '<chunk>' [args...]`: runs the chunk as Lua, the way
  --- `lua -e` does, against this binary's own standard library, with no
  --- tree around it -- nothing staged or built, nothing under o/
  --- written, and no staleness check. The words after the chunk are its
  --- `...`; it prints only what it prints. What it returns is the exit
  --- code, as a built program's is: nothing is 0, a whole number from 0
  --- to 255 is itself, and anything else is complained about and exits 2
  eval: string
  --- `cosmic --version`: prints `cosmic <hex>`, the SHA-256 of the file
  --- this binary runs from -- the digest a release's SHA256SUMS names
  --- it by and its notes cite -- with nothing built or checked
  version: string
  --- `cosmic test [options] [path...]`: builds the tree in the working
  --- directory, then runs every test it defines -- see test, Example --
  --- which `cosmic docs` also shows under every symbol an example
  --- calls. Each test runs in a process of its own, and fails if it
  --- runs past its timeout; what a failing test printed is shown
  --- beneath it
  test: string
  --- `cosmic fix [options] [path...]`: rewrites every Teal source in
  --- the working directory structurally, then writes it back out as
  --- canonical text, in place: run it after editing rather than
  --- formatting by hand -- checking along the way that rendering it
  --- again would change nothing further, and refusing a file it does
  --- not. It also builds the tree and parenthesizes every `assert(...)`
  --- the type checker says passes on more values than its place can
  --- take -- `(assert(...))` keeps only the first
  fix: string
  --- `cosmic build [options] [path...]`: builds the tree in the working
  --- directory, then writes one executable under o/bin/ for each
  --- cmd/<name>/main.tl it holds -- or only those under the paths --
  --- o/bin/<name>, which runs on its own, with nothing beside it -- see
  --- cmd. It runs on every supported system
  build: string
  --- `cosmic db [path...]`: what the two databases under o/ hold,
  --- table by table -- rows, pages, bytes -- how the last few builds
  --- went, and the slowest tests. Paths narrow it to the rows about the
  --- sources under them -- a row whose file, module or source hash is
  --- one under a path -- counted per table (coverage counting every run
  --- kept, not only the latest), and the slowest of those tests. Pages,
  --- bytes and builds are not per source, so a narrowed report leaves
  --- them out
  db: string
  --- `cosmic sql [--db <path> | --build | --store] <statement>`: runs
  --- one SQL statement read-only -- SQLite itself refuses a write --
  --- against o/cosmic.db, or the binary's own database when there is
  --- none, or the one database an option names. o/ is looked for in
  --- the working directory only, never above it. The
  --- first line names the columns (a statement without any prints
  --- none); each row after is one line of
  --- tab-separated cells: NULL as \N, a blob as X'<hex>',
  --- and in text a backslash, tab, newline or return as \\, \t, \n or
  --- \r and any other control byte as \xHH. The verdict line comes
  --- after the rows, as every verb's last line. Exits 0 when the
  --- statement ran, rows or none; 1 when the
  --- database or the statement failed, a write among them; 2 for a
  --- command line it cannot read. Nothing is built or staged.
  sql: string
  --- `cosmic docs [q]`: what the database says about q -- a symbol
  --- (Fs.read, read), a module (cosmic.fs), or words to search the
  --- documentation for; with no q, every module there is, with what
  --- it is for
  docs: string
  --- `cosmic uses <sym> [path...]`: every place that refers to a
  --- symbol, as file:line -- only those under the paths, when given
  uses: string
  --- `cosmic todos [options] [path | words...]`: every `TODO:` comment
  --- in the tree, as file:line, with the date and commit git blames its
  --- first line on, indexed into o/build.db so only a file that moved
  --- is blamed again. An argument that names a path narrows it to that
  --- path; the rest are words to search the TODOs' text for, best match
  --- first, in FTS5's own syntax ("a phrase", OR, prefix*) when they
  --- parse as that
  todos: string
  --- `cosmic help [verb]`: prints the whole discovery surface -- every
  --- verb, one line of prose each -- or, given a verb, only its line
  help: string
end

local record Module
  fields: Cli
  --- Each verb's options, by verb, as `Flags.parse` reads a spec: what
  --- the verb parses its command line with, and what `cosmic help`
  --- lists beneath its prose, so the two cannot drift apart. A verb
  --- that is absent takes none.
  options: {string: {string:boolean | Flags.Option}}
  --- The order `verb_help` prints these in, matching `cosmic help`'s
  --- own historical layout -- record field declaration order is not
  --- itself queryable at runtime, so this is spelled out once more.
  order: {string}
end

local module: Module = {
  fields = {
    run = "run", standalone = "standalone", eval = "eval", version = "version", test = "test", fix = "fix", build = "build",
    db = "db", sql = "sql", docs = "docs", uses = "uses", todos = "todos", help = "help",
  },
  options = {
    test = {
      ["--jobs"] = { value = "n", about = "run n tests at once; one per processor by default" },
      ["--timeout"] = { value = "seconds",
        about = "fail a test that runs longer (COSMIC_TEST_TIMEOUT, else 30)" },
    },
    fix = {
      ["--check"] = { about = "write nothing; name what a fix would change, and fail if any" },
    },
    build = {
      ["--host"] = { about = "this system's native executable: no launcher, runs only here" },
    },
    sql = {
      ["--db"] = { value = "path", about = "run against this file" },
      ["--build"] = { about = "run against o/build.db" },
      ["--store"] = { about = "run against the binary's own; only PRAGMA data_version" },
    },
    todos = {
      ["--oldest"] = { about = "list the oldest first, even when searching" },
    },
  },
  order = { "run", "standalone", "eval", "version", "test", "fix", "build", "db", "sql", "docs", "uses", "todos",
    "help" },
}

return module
