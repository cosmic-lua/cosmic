--- Help for the `cosmic` verbs: `cosmic help` prints an index of them
--- and `cosmic help <verb>` one verb's full text, generated from one
--- field per verb (`cosmic docs Cli.test`, [`Cli.build`], ... answer with
--- the same text). Where a module has the verb's name (`json`, `test`),
--- `cosmic docs json` shows the module and ends with a line pointing here.
--- This is not an argument parser for a project's own command line: a
--- project's cmd/<name>/main.tl gets its arguments as a plain array, and
--- `Flags.parse(argv, 1, spec)` from cosmic.flags reads its options, or
--- `Flags.dispatch(argv, 1, commands, name)` its commands -- see argv.
---
--- The index comes from each verb's `usage` and `about` and from `groups`,
--- a verb's page from its field and its `spec`, in the order `order`
--- gives.

local Flags = require("cosmic.flags")

--- One field per verb: the full text of `cosmic help <verb>`.
local record Cli
  --- `cosmic <file.tl> [args...]`: builds the file's tree into the tree's
  --- build directory, then runs the file. The tree is the working directory when
  --- the file is under it, so a file of a project reaches the rest of the
  --- project. Otherwise the tree is the file's own directory.
  ---
  --- Running the file requires it. If it returns a function, cosmic calls
  --- that function with the words after the file's path (`argv[1]` on; its
  --- own path is `argv[0]`), and exits with the status the function
  --- returns:
  ---
  --- - nothing: 0;
  --- - a whole number from 0 to 255, or text that holds one: that number;
  --- - anything else: an error, and exit 2.
  ---
  --- The file's top level finds the same words in the global `arg`. Its
  --- `...` is what `require` gives a module: its own name. Every word after
  --- the file is the file's, "--" too: no option of cosmic comes after the
  --- file. [`Flags.parse`] from `argv[1]` reads "--" as the end of the
  --- options, so `cosmic f.tl -- --help` gives the file the word "--help"
  --- and no option.
  ---
  ---     return function(argv: {string}): integer
  ---       print("from " .. argv[1] .. " to " .. argv[2])
  ---       return 0
  ---     end
  ---
  --- A file that requires only `cosmic.*` modules, each by a literal
  --- name, needs no tree, and runs as `cosmic --standalone` runs it: no
  --- tree is built and nothing is written but the compile cache. A
  --- program's `cmd/<name>/main.tl`, a `_test.tl` and a file of cosmic's
  --- own checkout build the tree whatever they require, and
  --- COSMIC_STANDALONE=0 makes any file build it.
  ---
  --- A file of the tree that does not parse or type-check stops the run
  --- only when the file requires it, itself or through another module. A
  --- broken file that it does not require is left out with a warning that
  --- names it and why, and the file runs. A check of the whole tree (a
  --- global, a cycle of imports) stops every run. `cosmic test` and
  --- `cosmic fix` build the whole tree, and refuse a broken file anywhere.
  ---
  --- A tree's build directory is outside the tree, and belongs to this
  --- user: `$XDG_CACHE_HOME/cosmic/trees/<key>` (`~/.cache/cosmic/trees/<key>`),
  --- where `<key>` is the SHA-256 of the tree's canonical path. When
  --- COSMIC_BUILD_HOME is set, it replaces that base: the build directory
  --- is `$COSMIC_BUILD_HOME/<key>`, and a path that is not absolute is an
  --- error. So a tree that this user cannot write, such as another
  --- user's checkout, builds as any other does.
  ---
  --- With COSMIC_STANDALONE=1, cosmic runs the file as `--standalone`
  --- does: it builds nothing and writes no build directory. A program that
  --- `cosmic sandbox --cosmic` runs has COSMIC_STANDALONE=1 unless
  --- `--set-env` says otherwise.
  run: string
  --- `cosmic --standalone <file.tl> [args...]`: runs one file against this
  --- binary's own standard library, with no tree around it -- nothing
  --- staged or built, no build directory written, and no staleness
  --- check, so it runs the same whatever state the working directory
  --- is in. The file may require `cosmic.*` modules only; it is
  --- checked and compiled in memory (a clean compile is cached under
  --- $XDG_CACHE_HOME/cosmic/standalone), then called as `run` calls
  --- one -- its words in `arg` and the returned function's `argv` --
  --- with a record's `main` field standing for a returned function.
  --- `cosmic --standalone --check <file.tl>` only checks the file, as
  --- a run does, and never calls it: it prints the refusals and exits 1,
  --- or exits 0 when there are none.
  --- COSMIC_STANDALONE=1 makes `cosmic <file.tl>` run so
  standalone: string
  --- `cosmic -e '<chunk>' [args...]`: runs the chunk as the body of a Teal
  --- file, against this binary's own standard library, with no tree
  --- around it -- nothing staged or built, no build directory written,
  --- and no staleness check. The chunk is checked as strictly as a file
  --- run `--standalone` is (a warning is refused with an error), and one
  --- the checker refuses does not run: its messages are printed and it
  --- exits 1. It reaches the library as a file does,
  --- `require("cosmic.json")`, by a literal name, and the tool's own
  --- modules the same way; no module is bound for it, and it is Teal, not
  --- Lua (`cosmic -e 'print(1 + "x")'` is refused). The words after the chunk are its `...`, each a
  --- `string?`; it prints only what it prints. What it returns is the
  --- exit code, as a built program's is: nothing is 0, a whole number
  --- from 0 to 255, or text naming one, is itself, and anything else is
  --- complained about and exits 2
  eval: string
  --- `cosmic --version`: prints `cosmic <hex>`, the SHA-256 of the file
  --- this binary runs from -- the digest a release's SHA256SUMS names
  --- it by and its notes cite -- with nothing built or checked
  version: string
  --- `cosmic test [options] [selector...]`: builds the tree in the
  --- working directory, then runs every test it defines. A test is one
  --- of three things (`cosmic docs cosmic.layout` says where each lives):
  ---
  --- - a top-level `local function test_*` of a `<name>_test.tl` file,
  ---   which fails when it raises an error, so `assert` is enough;
  --- - a function of the record named `Example` that a
  ---   `<name>_example.tl` file returns, which `cosmic docs` also shows
  ---   under every symbol it calls;
  --- - a block tagged `teal` or `lua` in a guide, doc/guides/<name>.md,
  ---   which compiles, and runs when a block tagged `output` after it
  ---   says what it prints.
  ---
  --- Beside `tally.tl`, say, a file `tally_test.tl`:
  ---
  ---     local Tally = require("tally")
  ---
  ---     local function test_words()
  ---       assert(Tally.words("a b  c") == 3)
  ---     end
  ---
  --- `cosmic test tally_test.tl` runs that file's tests, and `cosmic test
  --- tally_test.tl:test_words` runs that one test. A selector narrows the
  --- run to the modules it names: a file, a module name (`tally_test`) or a
  --- directory. `<file or module>:<name>` narrows it to the one test of that
  --- name, a `test_*` or an example's, and a name that no test there has is
  --- refused.
  ---
  --- Each test runs in a process of its own. It fails when it runs past its
  --- timeout (`--timeout`; a module's `Test.policy { timeout = n }` makes it
  --- longer). What a failing test printed is shown beneath it, and
  --- `--show-output` shows what a passing test printed too.
  ---
  --- Each run reports its line coverage, and coverage alone never fails a
  --- run. `--min PCT` and `--min-file PCT` hold a whole run to a floor, for
  --- the tree and for each file. A run below the floor fails (status 1) and
  --- names what fell short. Each run writes its line coverage to the
  --- `coverage` table of build.db, which `cosmic sql --build` reads.
  ---
  --- A test function is given a fresh directory, `<scratch>/tmp`. TMPDIR is
  --- its scratch directory, `<scratch>`, so [`Fs.mkdtemp`] makes a sibling of
  --- it. The scratch directory is removed after a pass. After a failure of
  --- an unsandboxed test, it is kept.
  ---
  --- The sandbox:
  ---
  --- Where the kernel can sandbox (Linux), each test runs sandboxed. It
  --- is given its module's import closure and what the module declares
  --- with [`Test.policy`]
  --- (`cosmic docs cosmic.test`), and nothing else of the tree or the host.
  --- A test that starts a host program, such as /bin/sh or `sleep`, grants
  --- it by its absolute path. When a test fails because its sandbox left out
  --- something at an absolute path (a program it started, a file it read),
  --- the report beneath it says so and names what to declare. It does the
  --- same for a test that read a file of the tree by a relative path without
  --- a grant.
  ---
  --- What runs again:
  ---
  --- A test whose verdict still stands is not run again. A verdict stands
  --- when this checkout reached it (in its build directory's build.db), or
  --- when any checkout of the same content did. Every sandboxed run shares
  --- verdicts through `$XDG_CACHE_HOME/cosmic/verdicts`
  --- (`~/.cache/cosmic/verdicts`). COSMIC_VERDICT_CACHE names another file,
  --- and COSMIC_VERDICT_CACHE=0 turns off only that shared cache: a verdict
  --- of this checkout still stands, and only `--all` runs its test again. A
  --- run whose workers are not sandboxed (COSMIC_TEST_SANDBOX=0, or macOS)
  --- shares verdicts only through a file that COSMIC_VERDICT_CACHE names.
  ---
  --- An edit to a test file, including to a comment, runs its tests again. A
  --- comment in a module that the test imports runs them again only when
  --- the test is given that module's text: a test that declares
  --- `store_text` or `store`, starts the program, or runs unsandboxed.
  --- doc/testing.md ("the pure store") lists every case.
  ---
  --- A module is not compiled again, and a source is not parsed again, when
  --- any checkout compiled or parsed the same text. They are shared through
  --- `$XDG_CACHE_HOME/cosmic/build` (`~/.cache/cosmic/build`).
  --- COSMIC_BUILD_CACHE names another file, and COSMIC_BUILD_CACHE=0 turns
  --- the cache off.
  ---
  --- The tree:
  ---
  --- The tree is the working directory, with one exception. When no build
  --- of the working directory has written its projection (cosmic.db in its
  --- build directory, as `run` names it), and an ancestor below the home
  --- directory has one whose build staged the working directory, the tree
  --- is that ancestor. Then the tree is named on stderr, and paths are read
  --- from the working directory. COSMIC_TREE=<dir> names the tree outright,
  --- with `.` for the working directory.
  test: string
  --- `cosmic fix [options] [path...]`: rewrites every Teal source in
  --- the working directory structurally, then writes it back out as
  --- canonical text, in place: run it after editing rather than
  --- formatting by hand -- checking along the way that rendering it
  --- again would change nothing further, and refusing a file it does
  --- not. It also builds the tree, failing where the build refuses it,
  --- with the compiler's reasons, and parenthesizes every `assert(...)`
  --- the type checker says passes on more values than its place can
  --- take -- `(assert(...))` keeps only the first. It fails a link in a
  --- comment or a Markdown file -- `` [`x`] ``, `[text](target)` or
  --- `[text][label]` -- that names nothing, or more than one thing, and
  --- makes a link of a plain `` `x` `` that names one top-level
  --- declaration of its own file, one file, or, written in full
  --- (`module.member`), one symbol; in Markdown it also
  --- writes the definitions GitHub needs to show one, at the file's
  --- end. That is all it writes to a Markdown or Zig file: it never
  --- reflows or re-indents one. `--check` writes nothing and reports
  --- what a run would change, the dry run. A path the tree's own
  --- .gitignore files ignore (not the user's global excludes), and
  --- anything under a `node_modules/`, is neither checked, rewritten
  --- nor linked to; where git cannot say (no git, no repository) only
  --- `node_modules/` is left alone. A Teal file the
  --- build does not read (under `bin/` or a hidden directory, or
  --- outside the tree), named or under a named directory, is
  --- type-checked alone, as `cosmic --standalone` checks a file;
  --- cosmic's own tree is excepted. The tree is found as `test` finds it
  fix: string
  --- `cosmic build [options] [path...]`: builds the tree in the working
  --- directory, then writes one executable in its build directory's
  --- bin/ for each cmd/<name>/main.tl it holds -- or only those under
  --- the paths -- bin/<name>, whose path it prints on a line of its own
  --- on stdout -- see cmd. The build directory is
  --- $XDG_CACHE_HOME/cosmic/trees/<key> (the
  --- home directory's .cache/cosmic/trees/<key>), <key> the SHA-256 of
  --- the project root's canonical path, so the file is
  --- <that>/bin/<name>; COSMIC_BUILD_HOME=/absolute/path puts the
  --- <key> directories there instead. That one file is the whole program: copied
  --- alone to a host with no cosmic, it runs with an empty environment
  --- (`env -i ./name`) on every supported system. It is a /bin/sh
  --- launcher with a core for each system and the program appended;
  --- the launcher calls uname, stat
  --- and the like from the PATH (the shell's default when none is set),
  --- and a host's first run copies its core into a private cache:
  --- $COSMIC_PORTABLE_CACHE, else $XDG_CACHE_HOME/cosmic/cores, else
  --- the home directory's cache, else $TMPDIR, or /tmp, under
  --- cosmic-cores-<uid>. `--host` writes this cosmic's own core and the
  --- program alone, which the kernel runs directly -- no shell, PATH or
  --- cache -- but only on this system and processor: the choice for a
  --- container with no /bin/sh or a host with nowhere to write. It
  --- writes the same bin/<name>, replacing a launcher build of it (and
  --- the other way round). The launcher `exec`s the core once ready, so
  --- the process you start is the program's own and signals reach it
  --- directly. Every executable carries every CA root this cosmic does,
  --- and its requests trust the minimal ones ([`Http.default_roots`])
  --- unless `--roots mozilla` makes it all of them, as COSMIC_CA_ROOTS
  --- does when it runs. Either
  --- carries this binary's CA roots, the certificates it refuses as
  --- revoked, and time zones: `cosmic refresh --binary <path> -o <copy>`
  --- writes a copy with newer ones
  --- later. The tree is found as `test` finds it. In cosmic's own
  --- tree the program is the tool itself, which `bin/zig build boot`
  --- builds: `build` prints the tool's path there, a stale tool
  --- rebuilt first, and `--out` writes a copy to dir/cosmic, which
  --- runs any project as a release does with the cores that boot
  --- built; it takes no other option and no path.
  ---
  --- A file that does not compile (a test among them) holds back only
  --- the programs that need it. The other programs are written, the
  --- old executable of each program held back is removed, and the
  --- exit status is 4. An import cycle, a `global` in a declaration
  --- file, or a source that cannot be read stops the whole tree, and
  --- nothing is written. A failure to write exits 1, and the refusal
  --- is still named.
  build: string
  --- `cosmic db [path...]`: what the three databases in the build
  --- directory hold, each named by its path,
  --- table by table -- rows, pages, bytes -- how the last few builds
  --- went, and the slowest tests. Paths narrow it to the rows about the
  --- sources under them -- a row whose file, module or source hash is
  --- one under a path -- counted per table (coverage counting every run
  --- kept, not only the latest), and the slowest of those tests. Pages,
  --- bytes and builds are not per source, so a narrowed report leaves
  --- them out. The tree is found as `test` finds it
  db: string
  --- `cosmic lsp [--stdio] [--listen [host:]port] [--socket path]`: a
  --- Language Server Protocol server for Teal, which an editor starts.
  --- It publishes the checker's errors and warnings as a document is
  --- opened, changed or saved, checked in memory as the editor holds it
  --- and as a build checks it, with a project's `require` answered as a
  --- build names modules, from open documents, then the modules a build
  --- stages of the workspace's root, staged again when the editor says a
  --- file changed on disk, then the binary's `cosmic.*`; it answers hover
  --- with a symbol's docs, as `cosmic docs`, answers go to definition
  --- with where a name is declared, and formats a document as
  --- `cosmic fix` does. It serves one editor over standard input and
  --- output, or, with `--listen` (a numeric IPv4 host or a bracketed
  --- IPv6 one, the loopback when only a port is given) or `--socket`,
  --- each editor that connects until SIGINT or SIGTERM. Whoever reaches
  --- a listener reads the files below the root it names, unasked who it
  --- is: it warns on standard error when it listens beyond the loopback.
  --- `--stdio` takes neither of the others. Over standard input and
  --- output it exits 0 after the editor's `shutdown`, at `exit` or the
  --- stream's end, and 1 at an `exit` or an end with no `shutdown`
  --- before it or a stream that breaks; a listener exits 0 when a signal
  --- stops it and 1 when it cannot listen, as at a socket file already
  --- there, which it leaves for a person to remove; 2 for a command line
  --- it refuses
  lsp: string
  --- `cosmic sql [--db <path> | --build | --store] [--to csv|ndjson] <statement>`: runs
  --- one SQL statement, read-only (SQLite itself refuses a write). By
  --- default it runs against the projection in the build directory, or the
  --- binary's own database when there is none. An option names another
  --- database. The build directory is the working directory's only, never
  --- that of a project above it.
  ---
  --- Nothing is built or staged. The projection is what the last run that
  --- builds wrote: `cosmic test`, `build`, `fix`, `docs`, `uses`, or running
  --- a file (`cosmic <file.tl>`). The working database that `--build` reads
  --- is what the last run that stages left: those runs, `todos` and `lsp`.
  --- So run one of them first to ask about the tree as it is now.
  ---
  --- - A statement that starts with `.` (`.tables`) is a sqlite3 shell
  ---   command, not SQL. `SELECT name FROM sqlite_schema WHERE type='table'`
  ---   lists the tables, and `cosmic db` says what each database of the
  ---   build directory holds.
  --- - A statement that starts with an SQL comment, `--`, is read as an
  ---   option unless `--` comes before it.
  ---
  --- Data files:
  ---
  --- `cosmic sql --from <file> ['<statement>']` asks the question of a data
  --- file instead. Use it to count, filter, join and sum, where `cosmic json`
  --- only looks values up:
  ---
  ---     cosmic sql --from accounts.json 'SELECT type, sum(balance) FROM accounts GROUP BY type'
  ---
  --- Each `--from` is loaded as a table of an in-memory database, named for
  --- the file's stem. `--from name=file` gives the name, and `-` reads
  --- standard input.
  ---
  --- - The file is read as JSON; as JSON Lines for `.jsonl` and `.ndjson`;
  ---   as CSV for `.csv`; as TSV for `.tsv` and `.tab`. `--as
  ---   json|ndjson|csv|tsv` overrides the extension, and standard input
  ---   needs it.
  --- - `--as`, `--at '<path>'` and `--raw` apply to the `--from` before
  ---   them. `--at` reads the rows from the array at a path: a JSONPath
  ---   query that names one value, as `cosmic json` reads it
  ---   (`--at '$.data.rows'`, indices from 0). A CSV or TSV has no path.
  --- - With no statement, it prints each table's row count, its columns
  ---   with the types stored, and a sample row.
  --- - A missing column or table is answered with the ones there are.
  ---
  --- A CSV or TSV file (RFC 4180, with quotes) has a header line that names
  --- the columns, in order, and one row per record. A record with more or
  --- fewer fields than the header is refused, and its line is named. A
  --- blank line is skipped, except in a one-column file, where a blank line
  --- before the last record is an empty cell. Blank lines at the end are
  --- dropped, so write a final empty cell as `""` to keep it.
  ---
  --- Cells are typed by one rule. A cell that is plainly a number (an
  --- optional `-`, digits, an optional fraction or exponent; no `+`, no
  --- leading zero, no spaces) is an integer or a real. An empty cell is
  --- NULL. Anything else, including `007` and ZIP codes, is text. `--raw` keeps
  --- every cell as text, and an empty cell as `''`.
  ---
  --- JSON becomes rows like this:
  ---
  --- - An array of objects is a table of them, with a column for each key.
  --- - An array of scalars is a `value` column.
  --- - Any other value is one row.
  --- - A nested object or array is JSON text, for `json_extract`. A boolean
  ---   is 0 or 1.
  --- - `_json` is the whole row.
  --- - A key that would collide (`A` with `a`, or `_json`, `rowid`) is
  ---   renamed with `_2`.
  ---
  --- `SELECT *` returns the file's columns, then `_json` last. Name the
  --- columns (`SELECT a, b`) to get only the file's.
  ---
  --- Output:
  ---
  --- The rows are TSV. The first line names the columns (a statement that
  --- returns no columns prints none). Each row after it is one line of
  --- cells separated by tabs: NULL is \N, and a blob is X'<hex>'. In text, a
  --- backslash, tab, newline or carriage return is \\, \t, \n or \r, and
  --- any other control byte is \xHH. The summary goes to stderr.
  ---
  --- `--to` writes the rows as CSV or NDJSON instead. It needs a statement,
  --- not the description that no statement gives.
  ---
  --- - `--to csv` quotes as RFC 4180 does, and ends each record with LF.
  ---   A header of the column names comes first. NULL is an empty field and
  ---   '' is a quoted empty field, so a one-column NULL is a blank line,
  ---   which a CSV reader may drop. A blob's bytes are written as they are.
  ---   A field that begins with a byte order mark is quoted, so a reader
  ---   keeps it.
  --- - `--to ndjson` writes one JSON object per row, with the columns as
  ---   its members, in order. A repeated name gets `_2`. A result of one
  ---   column named `_json`, as `--from` gives for each row, is written as
  ---   that object's text, which holds the row's members with its keys in
  ---   byte order. A blob, an infinity, text or a name that is not UTF-8,
  ---   or a `_json` that is not an object's text on one line fails the statement, and the row
  ---   is named.
  ---
  --- It exits 0 when the statement ran, with rows or none. It exits 1 when
  --- the database or the statement failed (a write too), or when a `--from`
  --- file cannot be read or loaded. It exits 2 for a command line it cannot
  --- read.
  sql: string
  --- `cosmic json [options] [path] [file|-]`: answers a quick question about
  --- a JSON file, with no script to write: is there a key `x` in this
  --- export, what is under `users[0]`. It reads the file, or standard input
  --- when the file is `-` or absent. It prints the value at the path as
  --- indented JSON, or on one line with `--compact`. With `-r`, a string
  --- prints as its text.
  ---
  --- Paths:
  ---
  --- A path is a JSONPath query (RFC 9535), in the subset that
  --- [`Json.query`] reads. Put it in single quotes, because a shell expands
  --- `$` and `[0]`: `cosmic json '$.users[0].name' export.json`.
  ---
  --- - `$` is the document, and comes first.
  --- - `.key` is a key that is a word. `["a key"]` (a JSON string) or
  ---   `['a key']` is any key.
  --- - `[0]` is an index counted from 0, and `[-1]` counts from the end.
  --- - A key that holds `'` is written `["it's"]`. Inside a shell's single
  ---   quotes, its `'` is `'\''`: `cosmic json '$["it'\''s"]'`.
  --- - `*` (`.*` or `[*]`) is every member of an object or every element of
  ---   an array. `..key`, `..[n]` and `..*` match that selector at any
  ---   depth, the current level too (`$..id`, `$.users[*].name`).
  --- - Filters, slices and unions are refused by name: this is a lookup,
  ---   not a query language. To count or sum, use `cosmic sql --from`.
  ---
  --- A query that can match many values prints each match as a
  --- `path = value` line, with the value as compact JSON
  --- (`$.users[0].name = "ann"`). The order is the one RFC 9535 gives
  --- (arrays by index, keys in byte order), and a value reached twice
  --- prints once. With `-r`, it prints only the raw values, one to a line;
  --- a string prints as its text, so a string with a newline spans lines.
  --- Without `-r`, or with `--flat`, every line is one JSON value.
  ---
  --- With one word, the word is the path when it begins with `$`, and the
  --- file otherwise. Give a file named `$x.json` as `./$x.json`. After `--`,
  --- the words are `[path] file`, whatever they begin with.
  ---
  --- The value is printed as [`Json.encode`] writes it, not copied byte for
  --- byte: `1e2` prints as `100.0`, and a big integer loses precision.
  ---
  --- Other outputs:
  ---
  --- - `--exists` prints nothing, and answers only by its exit status: 0
  ---   when the path is found, or when at least one value of a many-value
  ---   query matches.
  --- - `--keys` lists an object's keys, sorted, one per line, or prints an
  ---   array's length.
  --- - `--shape` prints a summary of the value's shape
  ---   (`{ids: [2 x number], ok: boolean}`).
  --- - `--keys` and `--shape` do not take a query with `*` or `..`, which
  ---   can match many values.
  --- - `--flat` prints every leaf under the path (the whole document when
  ---   there is no path) as `path = value` lines, and an empty object or
  ---   array as `{}` or `[]`. Each path is in a shorthand form that this
  ---   command reads back (`$.users[1].email`, `$["a key"][0]`). So
  ---   `cosmic json --flat export.json | grep -i email` finds a leaf, and
  ---   you can paste its path into `cosmic json '$.users[1].email' export.json`.
  ---
  --- It prints no summary: its output is the data that a pipe reads. It
  --- exits 0 when the path is found (for a many-value query, when something
  --- matches). It exits 1 when the path is not found, with a message on
  --- standard error. The message names, by its JSON Pointer, the first place
  --- that is not there (`no value at pointer "/users/4"`); for a many-value
  --- query that matches nothing, it is `<query>: no match`. A `null` value
  --- is found. It exits 2 for a command line or a path it cannot read, or a
  --- file that is missing or not JSON.
  json: string
  --- `cosmic hash [options] [file|-]...`: prints the digest of each file,
  --- or of standard input for `-` or no file. The line is
  --- `<hex>  <name>`, as `sha256sum` prints it, on every platform. Each
  --- input, a file or standard input, is read a chunk at a time, so its
  --- size does not change the memory used. `--json` prints an array of
  --- `{path, algorithm, digest}` instead of the lines.
  ---
  --- The algorithm options are those [`cosmic.hash`] has: `--sha256` (the
  --- default), `--sha512`, `--sha384`, `--sha224`, `--sha1`, `--md5`,
  --- `--sha3-224`, `--sha3-256`, `--sha3-384` and `--sha3-512`.
  ---
  --- Names are written as GNU writes them. A name with a backslash, a newline
  --- or a carriage return starts its line with `\` and has `\\`, `\n` and `\r` in
  --- it; all three read back. To hash a file named `-`, give it as `./-`.
  ---
  --- `--check <sums>` (`-` for standard input) verifies a sums file in
  --- that format: text and `*` binary markers, escaped names, and blank
  --- and `#` lines skipped. The digest size follows the algorithm option,
  --- so name the algorithm for a file that is not SHA-256. Each file
  --- prints `name: OK`, `name: FAILED`, or `name: FAILED open or read`,
  --- with its name escaped as above. `--quiet` prints only the failures.
  ---
  --- - BSD lines (`SHA256 (file) = hex`) and one-space separators are
  ---   malformed. A malformed line makes the exit 2, even when every
  ---   entry is OK. (GNU only warns, without `--strict`.)
  --- - A CRLF sums file leaves the CR in each name.
  --- - Each listed path is opened as given. A path that is not a regular
  ---   file is `FAILED open or read`. A sums file you do not trust can
  ---   still make it read any regular file you can read.
  ---
  --- `--hmac <key>` makes each digest an HMAC under the key.
  --- `--hmac-file <path>` reads the key from a file: its bytes exactly, a
  --- trailing newline too, with a warning (write the file with
  --- `printf %s`). Use the file: a key on the command line shows in `ps`
  --- and in the shell's history. Every algorithm has an HMAC, which also
  --- streams. `--json` names it `hmac-sha256` and so on, and `--check`
  --- verifies HMACs when it is given a key.
  ---
  --- `cosmic hash` prints no summary: its output is data. It exits 0 when
  --- all is well, and 1 when a check failed or a listed file could not be
  --- read. It exits 2, with `cosmic: hash: ...` on standard error, for a command
  --- line, a file to hash, a sums file (a malformed line too) or a write to
  --- standard output that it cannot use.
  hash: string
  --- `cosmic compile [--errors] [--root dir] [-o dir] file.tl...`: the Lua
  --- source of each `.tl` file, one text per file, written by this binary's
  --- own new checker for the tree's Lua, as it writes the tree's own modules. It reads the files named and the
  --- `cosmic.*` modules the binary carries, never the tree around them, so
  --- any release runs it in any directory. One file's Lua goes to standard
  --- output; several need `-o dir`, which gets `<name>.lua` for each (two
  --- files of one name are refused: compile them in two runs). A file is
  --- checked as the module its path below `--root` (the working directory)
  --- names, [`lang/flow.tl`] as [`lang.flow`], and a `require` of
  --- another named file is answered with its text; a path outside the
  --- root is refused. A `.d.tl` file is skipped with a note, and types a
  --- `require` of it. The Lua is raw: no wrapper, nothing joining files.
  --- A type error is reported and the Lua is written anyway: standard
  --- error gets a count per file, and with `--errors` each error as
  --- `file:line:column: message`. Only a syntax error refuses: each is
  --- named as `file:line:column: message`, no file is written, and the
  --- exit is 2, as for a command line or a file it cannot use.
  --- With a `.d.tl` file named, the files named are the whole program, the
  --- globals are those the `.d.tl` files declare, and a `cosmic.*` module
  --- no file named is the module of is typed `invalid` and reported. With
  --- none named, each file is checked as `cosmic --standalone` checks it:
  --- the binary's own globals and `cosmic.*` modules, and what a standalone
  --- run refuses besides type errors, its warnings and the project
  --- refusals (`package`, `_G`); all are listed and
  --- counted as type errors, and none stops the Lua. After a
  --- non-zero exit do not use the `-o` directory: it may hold files of an
  --- earlier run. It prints no summary; exits 0 when the Lua is written
  compile: string
  --- `cosmic cache trim compiles PATH --since-ns N` keeps supported compile
  --- and parse rows last used at or after N, a Unix nanosecond timestamp.
  --- `trim verdicts PATH... --since-ns N` keeps an unreached cache whole;
  --- `--whole` instead preserves all active verdict rows without vacuuming.
  --- Paths are explicit and absolute. This running binary owns the formats
  --- and never discovers, stages or rebuilds the candidate project.
  --- Unknown schemas and unreadable files are retained. `--restored PATH`
  --- compares retained compile keys against a pre-run snapshot without
  --- deleting that snapshot. `--json` prints one versioned report with
  --- per-file results, a complete canonical save digest when available,
  --- and the fresh compile count when requested and established.
  --- Writers must remain stopped through maintenance and the caller's save.
  --- An incomplete WAL checkpoint, read or write suppresses the save digest.
  --- Exit 0 means complete, 1 incomplete maintenance, and 2 a refused command
  --- line. Diagnostics go to stderr; no summary is printed.
  cache: string
  --- `cosmic archive list|extract|create`: the zip and tar files a
  --- release ships, with no script. `list <file>|-` prints one entry
  --- per line -- path (a symlink's `path -> target`), size, mode in
  --- octal, and type, tab-separated, control bytes escaped -- or, with
  --- `--json`, an array of objects (path, type, size, mode as the same
  --- octal string, mtime and a symlink's linkpath) for `cosmic json`.
  --- `extract <file>|- [-C dir] [member...]` unpacks into dir (the
  --- working directory by default) and prints the paths written; a
  --- member is a path in the archive and takes what is under it. The
  --- format -- zip, tar, or tar under gzip, xz, bzip2 or zstd -- is read from
  --- the file's first bytes, not its name. An absolute path, a `..`,
  --- or a symlink out of the target is refused ([`Archive.extract`]), and
  --- so is replacing an existing path unless `--force` is given. Only
  --- that refusal and a member not in the archive write nothing: an
  --- unsafe entry, or a file past the default size limits of
  --- [`Archive.extract`] (1 GiB a file, 8 GiB in all), stops the
  --- extraction after the entries before it, which stay written; the
  --- refused file itself is not left. `create <out> <path>...` packs the
  --- paths and what is under them, sorted by name, as a zip, a gzip, xz, bzip2 or zstd tar or a plain tar, by the
  --- extension of out (`.zip`, `.tar.gz`, `.tgz`, `.tar.xz`, `.txz`, `.tar.bz2`, `.tbz2`, `.tbz`, `.tar.zst`, `.tzst`, `.tar`) ([`Archive.create`]); `--reproducible` fixes every
  --- modification time (tar 0, zip 1980) so the same tree packs to the
  --- same bytes; file modes are kept, not normalised. Paths must be relative and stay under the
  --- working directory; a fifo, socket or device is refused, named,
  --- wherever it is found. A symlink is stored as a link in both
  --- formats; a zip tool that ignores Unix attributes extracts the
  --- target's text as a file. Prints no summary, its output being data
  --- for a pipe. Exits 0 when done, 1 for a
  --- member or a path that is not there or files it would overwrite, 2
  --- for a command line, an archive it cannot read or one it refuses
  --- to unpack. See also `cosmic json`
  archive: string
  --- `cosmic rand <uuid|token|int|pick|shuffle|normal|gamma> [options]`: prints
  --- an id, a token, a number, a shuffled list, or a normal or gamma draw,
  --- with no script to write.
  ---
  --- - `uuid [--v4|--v7] [-n N]` prints N UUIDs (default one, version 4).
  ---   Version 7 (RFC 9562) starts with the millisecond clock, then a 12-bit
  ---   counter, then entropy, so one run's values sort in the order they
  ---   were drawn. The counter is the RFC's method 3 (section 6.2): the
  ---   clock's fraction of the millisecond, increased by one where a draw
  ---   would not sort after the last. A clock that steps far back leaves
  ---   the values ahead of real time for the rest of the run.
  --- - `token [--bytes N] [--hex|--base64url]` prints N random bytes
  ---   (default 32, at most 1048576) as base64url without padding, or as hex.
  --- - `int [-n N] <lo> <hi>` prints N integers (default one), uniform over
  ---   lo..hi inclusive. It draws by rejection, so no value is more likely
  ---   than another. The bounds may be negative (`int -5 5`); lo above hi is
  ---   refused.
  --- - `pick [-n N] [file|-]` prints N distinct lines, and
  ---   `shuffle [file|-]` prints all of them, in an order drawn by
  ---   Fisher-Yates. A line ends at a newline, and a carriage return before
  ---   the newline is dropped (CRLF input reads as LF). An empty input has
  ---   no lines. Asking `pick` for more lines than there are is refused
  ---   (exit 2), and nothing is printed.
  --- - `normal [-n N] [--mean M] [--stddev SD]` prints N draws (default one)
  ---   from the normal distribution: mean 0 and standard deviation 1 unless
  ---   given. SD may be 0, but not negative.
  --- - `gamma [-n N] --shape K [--scale T]` prints N draws from the gamma
  ---   distribution of shape K, which is required, and scale T (default 1).
  ---   The mean is K * T, and both must be above 0.
  ---
  --- `-n` is at most 10000000; more is refused (exit 2). Ten million UUIDs
  --- take about 40 seconds, and ten million integers about 15.
  ---
  --- A parameter is a finite decimal number (`-5`, `.5`, `1e-3`). `inf`,
  --- `nan`, hexadecimal and a value too large for a double are refused
  --- (exit 2). Each float prints on a line as `%.17g`, which reads back as
  --- the same double. A gamma draw can print 0 for a tiny shape, and a draw
  --- can print inf where it overflows.
  ---
  --- Randomness:
  ---
  --- Everything secret-grade comes from the operating system's entropy
  --- source ([`Rand.entropy`]), never from a seeded generator: uuid, token,
  --- and the other commands without `--seed`. `--seed N` (int, pick,
  --- shuffle, normal, gamma) draws from `Rand.new(N)` instead, so a test or
  --- a script can replay it. A float draw agrees across targets only as far
  --- as their `log` and `pow` do. Seeded output is NOT secret, and `--seed`
  --- is refused with uuid and token.
  ---
  --- Its standard output is data, and it prints no summary. It exits 0 when
  --- it printed, and 1 when the entropy source failed. It exits 2 for a
  --- command line, a file or a request that it refuses, or a failed write
  --- to standard output.
  rand: string
  --- `cosmic qr [options] [text...]`: prints the QR code of a text, to show
  --- an address to a phone with nothing installed. The text is the words,
  --- joined by spaces. With no words, it is standard input, less one newline
  --- at its end. A text that starts with `-` goes after `--`
  --- (`cosmic qr -- -x`).
  ---
  ---     cosmic qr https://example.com/
  ---     echo https://example.com/ | cosmic qr --invert
  ---     cosmic qr --svg code.svg --level H https://example.com/
  ---
  --- Drawing:
  ---
  --- - It prints the code for the terminal in half blocks (`▀`, `▄`, `█`),
  ---   two rows of modules on each line, with the standard's quiet zone of
  ---   four modules (`--quiet N`, 0 to 16).
  --- - By default the blocks show the light modules, for light text on a
  ---   dark background, which is the common terminal. `--invert` draws the
  ---   dark modules instead, for a light background or paper. A reader
  ---   needs dark modules on light, so if a phone does not read the code,
  ---   try the other one.
  --- - `--ascii` draws each module as `##` or two spaces, one line for each
  ---   row, for a font with no block characters.
  --- - `--svg <file|->` writes an SVG image to the file, or prints it. It is
  ---   8 pixels for each module (`--scale N`, 1 to 1000), with a `viewBox`,
  ---   so it shows at a size and scales without blur. `--title T` says what
  ---   it shows, for a screen reader.
  --- - `--level L|M|Q|H` is the error correction (default M: 15% of the code
  ---   can be lost). `--max-version N` refuses a text that needs a code
  ---   larger than version N (1 to 40, default 40), to keep the code small
  ---   enough to scan.
  ---
  --- Reading:
  ---
  --- `--read [file|-]` reads a code back from the file or standard input,
  --- and prints what it holds and a newline (`cosmic qr hello | cosmic qr
  --- --read` prints `hello`). It reads the text or SVG that `cosmic qr`
  --- drew, either way round and with any quiet zone, and mends what its
  --- level allows. It reads those drawings only, not photos or other
  --- programs' images. A program draws and reads its own codes with
  --- [`cosmic.qr`].
  ---
  --- Its standard output is the code, or the text that it read, and it
  --- prints no summary. It exits 0 when it printed or wrote. It exits 1
  --- when the text is too large for a code of the allowed versions at the
  --- level, or when a drawing holds no code that it can read. It exits 2
  --- for a command line or an input that it refuses, or a failed write.
  qr: string
  --- `cosmic acme <key|issue> ...`: a TLS certificate from an ACME
  --- certificate authority (RFC 8555) such as Let's Encrypt. `key
  --- [--rsa [--bits N]] <file|->` writes a new private key as PEM, P-256
  --- by default, in a new file of mode 0600; a file that is there is
  --- refused. `issue --account <file> --key <file> <name>...` asks for a
  --- certificate for the DNS names under the account key, made into an
  --- account on the first issue (`--agree-tos` accepts the server's
  --- terms; `--contact mailto:...`, once or more), and prints the chain
  --- as PEM, or writes it to `--out <file>`. A key file is PEM as `key`
  --- writes it, or as OpenSSL does (SEC 1, PKCS #1 or PKCS #8). It takes
  --- one way to prove each name: `--webroot <dir>` writes the http-01
  --- response under `<dir>/.well-known/acme-challenge/`, which the web
  --- server for the name serves on port 80; `--dns-hook <program>`
  --- answers dns-01, which a wildcard needs, by running `<program> present
  --- <record> <value>`, which puts the TXT record and exits 0 once the
  --- zone serves it, and `<program> cleanup <record> <value>` after. The
  --- directory is Let's Encrypt's production one; `--staging` takes its
  --- staging one, and `--directory <url>` another server. Examples:
  --- `cosmic acme key account.pem`, then `cosmic acme issue --account
  --- account.pem --key site.pem --webroot /var/www --agree-tos --out
  --- chain.pem example.com`. A program asks for its own with
  --- [`cosmic.acme`]. It prints no summary. Exits 0 when it wrote, 1 when
  --- the server or a challenge refused the issue or a request failed, 2
  --- for a command line, a key file or a write it refuses
  acme: string
  --- `cosmic tailscale <status|whois|cert|ping|file> ...`: the machine's own
  --- Tailscale node, asked through tailscaled's LocalAPI with no
  --- `tailscale` binary. `status` prints this node and each peer, a line
  --- each: its address, MagicDNS name, owner or tags, OS and how traffic
  --- reaches it, and exits 1 for a node that is not running. `whois
  --- <address|name>` prints the node an address of the
  --- tailnet belongs to, its user and the capabilities the policy's grants
  --- give it here. `cert [domain]` writes the certificate of one of the
  --- node's names (the first by default) to `<domain>.crt` and its key to
  --- `<domain>.key`, mode 0600, or to `--cert-file` and `--key-file` (`-`
  --- for standard output); `--min-validity 30d` has the daemon renew one
  --- that expires sooner first. `ping <address|name>` prints the round trip and
  --- the path it took (`--kind disco|ICMP|TSMP|peerapi`). `--json` prints
  --- the answer as JSON; `--socket <path>` names the daemon's socket.
  --- `file` is Taildrop: `file targets` lists the nodes a file can go to,
  --- `file send <file|-> <target>` sends one to a node by name, address or
  --- stable id (`--name` renames it), `file list` lists the files that wait
  --- here, and `file get <dir>` writes each into the directory and drops
  --- it from the daemon (`--keep` leaves it; `--wait` waits for one;
  --- `--conflict skip|overwrite|rename` for a name already taken, skip by
  --- default).
  --- Examples: `cosmic tailscale status`, `cosmic tailscale whois
  --- 100.101.102.103`, `cosmic tailscale cert`. A program asks the daemon
  --- with [`cosmic.tailscale`]. It prints no summary. Exits 0 when it
  --- answered, 1 when the daemon could not be asked or refused, the node
  --- is not running, or no node has the address or name, 2 for a command
  --- line or a write it refuses
  tailscale: string
  --- `cosmic mcp <action> ... [--url URL | -- program args...]`: asks a
  --- Model Context Protocol server, revision 2026-07-28, and prints its
  --- answer as one line of JSON. The server is a program it starts and
  --- speaks to over stdio, the words after `--` (a `.tl` file first is
  --- run by this program), or one at `--url` over Streamable HTTP, with
  --- the bearer token in the variable `--token-env NAME` names. The
  --- actions: `discover`, `tools`, `resources`, `templates`, `prompts`,
  --- `call <tool> [json]`, `read <uri>` and `prompt <name> [json]`.
  --- `--timeout` bounds each request over HTTP, and a program's whole
  --- run (30 seconds). A plain `http://` URL takes a token only to a
  --- loopback host. A word of the action that starts with `-` is read
  --- as an option. Examples: `cosmic mcp tools
  --- -- server.tl`, `cosmic mcp call add '{"a":1,"b":2}' -- server.tl`.
  --- A program serves with [`cosmic.mcp.server`] and asks with
  --- [`cosmic.mcp.client`]. It prints no summary. Exits 0 when it
  --- answered, 1 when the server failed or refused or a tool's result is
  --- an error, 2 for a command line or a write it refuses
  mcp: string
  --- `cosmic time <now|convert|between|add> ...`: the clock and calendar
  --- the same on every host, where GNU and BSD `date` differ. Zones are
  --- the IANA names of the tz database the binary carries. `now` prints
  --- the time (RFC 3339 in the host's zone, or `--zone`; `--format`
  --- rfc3339, date, http or epoch); `convert <time>` writes a time in
  --- `--to`'s zone; `between <a> <b>` is `1y2mo3d4h5m6s` from a to b, or
  --- with `--days`, `--months` or `--seconds` one number; `add <time>
  --- <duration>` moves a time by `1y2mo3d4h5m6s` (negative with a leading
  --- `-`, which follows the time: `add 2026-03-31 -1d`). A time is RFC 3339
  --- (`2026-09-25T04:09:21Z`, with an optional `[Zone]` suffix), a date,
  --- a local `2026-09-25T04:09[:21]` read in `--from` (or `--zone`), or
  --- `@<epoch seconds>`. A local time a zone skipped (a spring-forward
  --- gap) or has twice (an overlap) is read as `--disambiguate` says:
  --- "compatible" by default, a gap landing after the gap and an overlap
  --- taking the earlier moment; "earlier", "later" or "reject" (which fails)
  --- choose otherwise. `add` moves years and months first, keeping the
  --- day of the month, then days on the calendar, then hours, minutes and
  --- seconds exactly; a day the month lacks (January 31 plus 1mo) is an
  --- error, exit 1, unless `--clamp` takes the month's last day. `between`'s
  --- duration reads months as `--clamp` does, on `--zone`'s calendar or the
  --- first time's own; `--seconds` is elapsed time.
  --- `--json` prints one record: epoch, rfc3339, zone, offset and the
  --- civil fields. It prints no summary, as `json` does: exit 0
  --- done, 1 an `add` with no answer, 2 a command line, time, duration
  --- or zone it cannot read
  time: string
  --- `cosmic codec <hex|base64|base64url> [-d] [--wrap N] [--lenient] [file|-]`:
  --- bytes to text and back, for a token or a checksum, with no script
  --- to write. It reads the file, or standard input when the file is `-`
  --- or absent, and writes the encoding on one line and a newline; with
  --- `-d` it writes the bytes the text spells, and no newline. The
  --- encodings are those of [`cosmic.codec`] and no others; `-d` is the
  --- one spelling of decode, `base64 -d` and `-D` differing between
  --- platforms. Encoding does not wrap unless `--wrap N` gives the
  --- columns, unlike GNU base64, which wraps at 76. Decoding ignores
  --- ASCII whitespace, and is otherwise strict: an invalid character,
  --- misplaced padding, a bad length or nonzero trailing bits exits 2
  --- and names the byte offset, from 0, in the input as given. base64
  --- must be padded with `=` and base64url must not be, as each is
  --- written; `--lenient` accepts the other spelling (missing padding on
  --- base64, `=` padding on base64url) and is refused for hex. The whole
  --- input is read at once. It prints no summary: its output is the data
  --- a pipe reads; exits 0 when done, 2 for a command line, an
  --- input or a write it cannot honor
  codec: string
  --- `cosmic fetch <url[#sha256=hex]> [-o file] [--sha256 hex] [--sha512 hex] [--allow-downgrade] [--head [--json]]
  --- [--roots set] [--cacert file] [--pin pin]`: makes one GET, like a small
  --- curl. GET is the only method, by design: for a header, a body or
  --- another method, write a script with [`cosmic.http`].
  ---
  --- Without `-o`, the body goes to standard output, so
  --- `cosmic fetch <url> | cosmic json '$.items'` reads it. With `-o`, the
  --- body is written to a temporary file beside the target. The file is
  --- renamed into place only when the whole body is in and its digest
  --- matches. So a failed digest leaves nothing at the target.
  ---
  --- Digests:
  ---
  --- - `--sha256` or `--sha512` gives the digest. The URL's fragment can
  ---   also carry it: `<url>#sha256=<hex>`, or `#sha256sum=`, `#sha512=`,
  ---   `#sha512sum=`. The fragment is never sent or printed.
  --- - An unknown fragment is dropped. A fragment that looks like a
  ---   checksum this verb does not check, such as `sha1=` or `SHA256=`,
  ---   exits 2.
  --- - A bad digest, or an option and a fragment for one algorithm that
  ---   differ, exits 2 before any request. For different algorithms, both
  ---   must match.
  --- - A digest (`--sha256`, `--sha512` or a fragment) with standard output
  ---   holds the whole body in memory, with no limit, and writes it only
  ---   when the digest matches, because bytes already on a pipe cannot be
  ---   taken back. On a mismatch it exits 1 and names both digests.
  --- - Without a digest, streaming to standard output can leave partial
  ---   bytes sent before a failure (exit 1).
  ---
  --- Status and redirects:
  ---
  --- - A status outside 2xx fails (exit 1, with the status on standard
  ---   error), as `curl -f` does. Nothing turns this off, so an error page
  ---   never reaches a pipe.
  --- - `--head` prints `HTTP <status>` and the headers, with names
  ---   lowercased and sorted. With `--json` it prints an object of `status`,
  ---   `url` and `headers`. It also fails on a status outside 2xx.
  --- - Redirects are followed, up to 10, as [`cosmic.http`] follows them.
  ---   From an https URL, a redirect to http is refused (exit 1), unlike
  ---   curl's default. `--allow-downgrade` follows it; use it with
  ---   `--sha256`.
  --- - Header values print with control bytes as `\xNN`, and a URL's
  ---   userinfo prints as `***`.
  ---
  --- Certificates:
  ---
  --- Certificates are always verified: no option turns this off.
  ---
  --- - `--roots` chooses the CA roots to verify against, as
  ---   [`Http.Options`]'s `roots` does: `minimal`, `none`, or digests
  ---   joined by commas.
  --- - `--cacert` also trusts a file's certificates.
  --- - `--pin` holds the server's key to a public key pin
  ---   ([`Http.public_key_pin`]).
  --- - A value of the wrong shape, or a `--cacert` file it cannot read,
  ---   exits 2 before any request.
  ---
  --- It prints no summary: its output is the body that a pipe reads. It
  --- exits 0 when the body was delivered. It exits 1 when the fetch failed:
  --- no connection, a bad status, a digest that does not match, a body that
  --- broke off, or an `-o` write that failed. It exits 2 for a command line,
  --- a URL or a write to standard output that it cannot use.
  fetch: string
  --- `cosmic docs [q...]`: what the database says about q -- a symbol
  --- (Fs.read, read), a module (cosmic.fs, or fs for its last name),
  --- or words to search the documentation for, the first five matches
  --- shown whole and the rest a line each; a module lists the
  --- signature of each function it offers, ahead of the rest of its
  --- prose. Several qualified names (Fs.read Fs.write) are each looked
  --- up in turn; any other words are searched for together. A word no
  --- documentation holds is searched again as the nearest word one does,
  --- a misspelling of it, and the page says which it searched. With no q,
  --- every module there is, with what it is for; with `cosmic`, the
  --- standard library's. `--json` prints one JSON object per entry
  --- found, every one and not the first five, a line each (query, exact,
  --- module, symbol, kind, signature, text, and file, line, verb and
  --- respelled where it has them), with no summary on standard error but the one
  --- a stale answer gets (below); with no q,
  --- or `cosmic`, each module the page lists. Filter it by composing,
  --- as `cosmic json` does: `cosmic docs --json Fs.read Fs.write |
  --- cosmic sql --from docs=- --as ndjson "SELECT symbol, line FROM
  --- docs WHERE kind = 'function'"`. A doc is the run of comment
  --- lines directly above a declaration, a record's field or an
  --- enum's value: its `---` lines where it has any, else its `--`
  --- lines, less TODO lines and the build's `--- @` tags. A
  --- trailing comment and a comment inside a table constructor are
  --- none, so a table's entries are documented by the record that
  --- types it. A function declared as a field of the record a module
  --- returns, and defined as `function Record.f`, shows the field's
  --- doc unless the definition has a `---` doc of its own, and is
  --- placed at the definition. Where the build directory holds a working
  --- database or a projection (any run that builds or stages there made
  --- it, `todos` and `lsp` among them), it builds the tree first, as
  --- `test` does but running no test, so it answers for the tree as it
  --- stands; where it holds neither, it builds nothing and answers from
  --- cosmic's own docs, saying the directory has not been built. Where the
  --- tree does not build, or the build is left alone (another run holds
  --- it, the working database is another tool's), it answers from the
  --- last build, and the summary says so and why, as each `--json` object
  --- does with `"stale": true`. The tree is found as `test` finds it
  docs: string
  --- `cosmic uses <sym> [path...]`: every place that refers to a
  --- symbol, as file:line -- only those under the paths, when given --
  --- each link to it, in a comment or a Markdown file, marked `link`.
  --- A place is a read or a call of a member, through its module, an
  --- alias of it, or a value the checker gave its type; one through `any`,
  --- a union or a value whose type failed is not seen. A member a record
  --- takes from an interface is a use of the interface's, and of the
  --- record's own too where the record declares it again. The code the
  --- build writes for a call ([`Shape.record_of`]) reads at the call's
  --- line. An assignment to a member and a key of a table literal are not
  --- places.
  --- The symbol may be a file's path instead (doc/writing.md, or
  --- doc/writing.md#heading for one heading), which only links name. It
  --- builds the tree first, as `docs` does, and its summary says where it
  --- answers from the last build instead. The
  --- tree is found as `test` finds it
  uses: string
  --- `cosmic todos [options] [path | words...]`: every `TODO:` comment
  --- in the tree, as file:line, with the date and commit git blames its
  --- first line on -- in a git repository only: elsewhere git is not
  --- started, and each is listed with none -- indexed into its build.db so
  --- only a file that moved is blamed again. A TODO is a comment on a line
  --- of its own whose text opens with `TODO:`, and the lines that carry on
  --- its paragraph: not one after code on its line. In Markdown a line
  --- opening with `#`, `##` or `*` is read as such a comment, and a line of
  --- prose or an HTML comment is none. A
  --- comment that opens with a near miss (`TODO(tag):`, `FIXME:`, a `TODO`
  --- with no colon) is not listed, and the summary counts those, naming
  --- the spelling that is. An argument that names a path narrows it to that
  --- path; the rest are words to search the TODOs' text for, best match
  --- first, in FTS5's own syntax ("a phrase", OR, prefix*) when they
  --- parse as that: `^perf` finds those whose text opens with `perf`, the tag
  --- of a `TODO: perf: ...`, and `data:` searches for a word that also names
  --- a path. Listing nothing is no failure, though a search that matches
  --- none is (exit 1, as `cosmic help exit` says). The tree is found as
  --- `test` finds it
  todos: string
  --- `cosmic bom [--licenses | --json <path>]`: the bill of materials
  --- this binary ships under -- every third-party component its cores
  --- and database carry, one line each: name, version, license, and
  --- how many patches cosmic applies to it, or the files of the tree that
  --- stand in for it (`modified:`) -- or, for data (the CA
  --- roots, the time zones), that `cosmic refresh` updates it. `--licenses` prints the
  --- notices those licenses ask a copy to travel with; `--json` writes
  --- the list as a CycloneDX document instead. An executable `cosmic
  --- build` writes carries the same rows
  bom: string
  --- `cosmic refresh -o <path> [--binary <path>] [--<dataset> <file>...]
  --- [dataset...]`: the way to update the CA certificates a binary
  --- trusts, the certificates it refuses as revoked, and the time zone
  --- database it carries when they go out of date, with no rebuild. It
  --- writes to path a copy of this binary -- or of the one --binary
  --- names, a program `cosmic build` wrote, say -- whose
  --- data is replaced with a newer release: the CA roots it trusts
  --- (cacert, Mozilla's root store as NSS's newest release holds it in
  --- certdata.txt, with the dates after which it trusts a root for no
  --- server certificate issued; a file may be that or a PEM bundle, which
  --- names no dates) and the time zones
  --- it carries (tzdata, as PyPI's tzdata sdist holds them), and the
  --- certificates it refuses as revoked (onecrl, Mozilla's OneCRL, as its
  --- remote settings feed serves it). Each named
  --- dataset is fetched upstream, its newest release; one given a file is
  --- read from it, with no network; with neither, every dataset is
  --- fetched. Every row is checked before anything is written, the
  --- bill of materials records the release each came from, and the
  --- binary it reads is never written
  refresh: string
  --- `cosmic release [--commit hex] [--until time] [--list [-n count] | -o file | --cache] [--pin file | --launcher file] [--json]`:
  --- finds cosmic's own releases, picks one and verifies it. The releases
  --- are the `YYYYMMDD-<commit>` prereleases of cosmic-lua/cosmic on GitHub
  --- (older ones are `next-<commit>`).
  ---
  --- Finding a release:
  ---
  --- Releases are found by their tags and main's history, newest commit
  --- first, because the API's list of releases serves only 1000, and not by
  --- time.
  ---
  --- - With no criterion, it picks the release of the latest commit on main
  ---   that has one.
  --- - `--commit` picks the release whose commit starts with the hex (7 to
  ---   40 digits). It reads only the releases of the tags whose commit
  ---   starts with that prefix, and refuses a prefix that matches more than
  ---   10.
  --- - `--until` picks the latest release published at or before an RFC
  ---   3339 time, or by the end of a date in UTC.
  --- - `--commit` and `--until` may be given together.
  ---
  --- A release is verified first: its SHA256SUMS must give one digest for
  --- cosmic, and its source.json the same commit and digest.
  ---
  --- What it does with the release:
  ---
  --- - With nothing more, it prints the release as the three lines of
  ---   ci/cosmic-driver.pin (commit, URL, sha256), or as an object with
  ---   `--json`. It downloads no binary.
  --- - `--list` prints the matches instead, latest commit first, up to `-n`
  ---   (default 20, one request each): the time each was published and its
  ---   commit, or an array with `--json`. It verifies none of them.
  --- - `-o` writes the binary to a file. `--cache` writes it where
  ---   bin/cosmic-bootstrap caches the pin's binary
  ---   (`$XDG_CACHE_HOME/cosmic/bootstrap/cosmic-<sha256>`), and prints that
  ---   path. Each renames the file into place only when its sha256 is the
  ---   release's digest.
  --- - `--pin` writes the three pin lines to a file after the binary's bytes
  ---   are verified.
  --- - `--launcher` sets up a project to run on the release. It writes the
  ---   pin as `<file>.pin`, and at the file a shell script, a project's
  ---   bin/cosmic, that runs the release the pin names with the arguments
  ---   given. The script downloads the release once, runs it only when its
  ---   sha256 is the pin's, and caches it where `--cache` does.
  ---   COSMIC_TOOL=<path> makes the script run another cosmic instead, such
  ---   as one that `cosmic build` printed in a checkout of cosmic. To move
  ---   the pin later, run `cosmic release --pin <file>.pin` alone.
  ---
  --- GH_TOKEN goes with the API's requests when it is set, and every
  --- redirect must stay on https.
  ---
  --- It prints no summary. It exits 0 when it did what was asked. It exits
  --- 1 when it could not: no connection, no matching release, a release
  --- that fails verification, or a write that failed. It exits 2 for a
  --- command line that it refused.
  release: string
  --- `cosmic sandbox [options] [--] program [args...]`: runs a program, and
  --- everything it starts, held to what the options grant and nothing more:
  --- the paths it reads, runs, writes and creates, the system calls it makes,
  --- the environment it sees and the resources it spends. What is not granted
  --- does not work. When this host cannot enforce the whole policy, nothing
  --- runs: the start fails and names what is missing.
  ---
  --- The program is the first word that is not an option, or the word after
  --- `--`. Every word after the program is its own argument, also a word
  --- that looks like an option. The program is found on the PATH. Its own
  --- file and its loader must be granted for it to run: `--system` grants
  --- what a host's programs need to start, and `--cosmic` grants this
  --- program's own file.
  ---
  ---     cosmic sandbox --system --read . -- ls -l
  ---     cosmic sandbox --system --read . --promise fork -- sh -c 'ls | wc -l'
  ---     cosmic sandbox --system --path rwxc:. --tmp --promise fork \
  ---       --isolate file -- make
  ---
  --- Each option is one field of the policy, and each number is a whole
  --- number. `cosmic docs cosmic.sandbox` lists the policy's fields.
  ---
  --- Paths:
  ---
  --- - `--read`, `--run` and `--write` grant a path as `r`, `rx` and `rwc`.
  ---   `--path` gives the letters itself, from `rwxcu` in that order, each
  ---   once (`rwxc:.`).
  --- - A path is relative to the working directory, and must exist. `--cwd`
  ---   names the working directory, as if you ran `cd` there first; without
  ---   it, the directory is this process's own.
  --- - Paths and `--set-env` values must be UTF-8, because they are written
  ---   as JSON.
  ---
  --- Running cosmic in a sandbox:
  ---
  --- `--cosmic` grants this program's file, which then runs as its core
  --- directly, past its launcher. It needs no shell, cache or promise to
  --- start, and no `--system` unless what it runs needs one. When this
  --- process is root, the program's user runs a copy of the core that every
  --- user may run, made once in /run/cosmic-sandbox-cores.
  ---
  ---     cosmic sandbox --cosmic --read . -- cosmic run.tl IN OUT
  ---
  --- A file that it runs is run as `--standalone` (COSMIC_STANDALONE=1). So
  --- a grant to read the file is enough, and no build directory is written
  --- (another run's user would own it). The file may then require only
  --- `cosmic.*` modules. `--set-env COSMIC_STANDALONE=0` builds the tree
  --- around the file instead: that finds the tree's own modules, and needs a
  --- grant to write the build directory.
  ---
  --- A sealed database of modules:
  ---
  --- `--database`, `--modules` and `--closure` run this program on a
  --- database that holds the modules it may load and no others. A `require`
  --- of any other module fails, and no part of this program's own file is
  --- read or granted. The program is this program (`cosmic`) or nothing,
  --- which is the same, and the words after it are the main's arguments.
  ---
  --- - `--database PATH` runs a file that [`Store.seal`] wrote. Its main is
  ---   what runs.
  --- - `--modules a,b,...` seals exactly the names given, from this
  ---   program's own store, and follows no requires. The first name is the
  ---   main: a module that returns a function, which gets the arguments and
  ---   returns the status. The other names are what the main may load.
  --- - `--closure` runs a script, given as the program's first argument. It
  ---   compiles the script here, as a file run does, and seals it as the
  ---   main with the `cosmic.*` modules that it requires by a literal name,
  ---   and the modules that those require.
  ---
  ---     cosmic sandbox --closure -- cosmic run.tl IN OUT
  ---
  --- For `--closure`, a `pcall(require, "<name>")` is followed as a
  --- `require` is, so a name that no store holds is refused there too. A
  --- name computed at run time is refused when the script is compiled. A
  --- `require` of a module outside this program's store (a project module
  --- beside the script) is refused before anything starts.
  ---
  --- The three options exclude each other, because each one names the
  --- database. `--cosmic` adds nothing beside `--database` or `--modules`,
  --- and is refused beside `--closure`. `--system` fails the start when
  --- this program is installed under a directory that `--system` grants.
  --- The database is written in a directory of the run's own, which the
  --- program's user can search, and is removed when the run ends. A command
  --- line that these options refuse, a module that no store holds, or a
  --- `--database` file that is not there exits 2. A script that cannot be
  --- read or compiled exits 125, as a seal that cannot be written does.
  ---
  --- The network:
  ---
  --- `--connect HOST:PORT` grants a host and port, and may be repeated.
  --- A relay that the start runs connects the program to it: on Linux, in the program's own
  --- network; on macOS, on the host's loopback, behind a token drawn for the
  --- run. The proxy variables (`HTTPS_PROXY`, `ALL_PROXY` and the others)
  --- tell the program about the relay, and carry the token. So a program
  --- that uses them reaches exactly the granted hosts, and the relay
  --- resolves the names it grants, never the program. A program that ignores them
  --- reaches nothing.
  ---
  --- The relay writes one line to this process's standard error for each
  --- connection that it allows or refuses. A refusal names the option that
  --- would allow it (`not granted: --connect api.github.com:443`). When this
  --- process's `https_proxy` is set, the relay connects through it, and says
  --- so once, when it starts.
  ---
  --- `cosmic sandbox connect HOST PORT`, with `connect` as the first word
  --- after `sandbox`, is not a sandbox. It is the relay's client, for a
  --- program that takes a command to reach a host through, such as ssh's
  --- ProxyCommand. Inside a sandbox with `--connect`, it asks the relay
  --- (`ALL_PROXY` must name the relay) for HOST and PORT, and copies its
  --- standard input and output to the connection. When the relay refuses,
  --- it exits 1 and says what the relay's reply means. ssh runs it as a
  --- program of its own, so the sandbox also needs `--system` (for ssh, its
  --- libraries and a shell for the ProxyCommand), `--promise fork`,
  --- `--cosmic` for this program, and `--env PATH` so that the shell finds
  --- `cosmic` (or the ProxyCommand gives its absolute path):
  ---
  ---     cosmic sandbox --system --cosmic --env PATH --promise fork --read ~/.ssh \
  ---       --connect github.com:22 -- ssh -o ProxyCommand='cosmic sandbox connect %h %p' git@github.com
  ---
  --- To run a program that is named `connect`, put it after `--`:
  --- `cosmic sandbox -- connect`.
  ---
  --- The user, the streams and the terminal:
  ---
  --- `--user` gives the user and group that the program runs as, by number.
  --- The group is the user's number unless you give one. Only a root caller
  --- chooses a user, and gets the same one each run, instead of a fresh one
  --- of its own for each run. Any other caller may name only itself.
  ---
  --- The program's standard streams are this program's own. It gets no
  --- other descriptor except those that `--fd` names. Each standard
  --- stream that is a terminal is given to the program as a terminal of
  --- its own, a pty (a pipe or a file is given as it is):
  ---
  --- - What the program writes reaches the terminal as text and as the
  ---   sequences that draw a screen (colors, cursor movement, erasing, the
  ---   alternate screen). A title, clipboard or other control sequence does
  ---   not reach it.
  --- - Its queries are answered here.
  --- - The window's size, SIGINT and SIGTERM are passed on.
  --- - This terminal is put back as it was when the program ends.
  sandbox: string
  --- `cosmic agent <ask|chat|resume|rpc|sessions|prompt|policy> ...`: a
  --- small coding agent, after pi: Claude, with tools to read, write and
  --- edit files, run commands, in the foreground or as background jobs,
  --- and query what it has kept, every tool held to a sandbox. A first
  --- session, in the directory to work in, with `ANTHROPIC_API_KEY` set
  --- (or another credential, `cosmic docs cosmic.agent.auth`):
  ---
  ---     cosmic agent ask 'what does this repository do?'
  ---     cosmic agent chat                      a conversation, a prompt a line
  ---     cosmic agent sessions                  what was kept, newest first
  ---     cosmic agent ask --continue 'and now?' go on with the newest session
  ---
  --- `ask [prompt...]` runs one prompt to the end: the words, else all of
  --- standard input. `chat` takes a prompt a line until `/exit`; a line
  --- typed at a terminal while the model works steers it, and `/later
  --- <prompt>` waits for the turn to end. `resume` finishes the turn a
  --- run left unfinished. `rpc` runs one session for another program:
  --- commands as JSON lines on standard input, events on standard output
  --- (`ask --json` prints the events too). `sessions` lists the newest sessions here, `prompt` prints the
  --- system prompt the model reads, and `policy` the sandbox the tools
  --- would run under here, path by path; `policy clear-home` empties the
  --- commands' kept home.
  ---
  --- Each event is one JSON object on a line, printed once what it tells
  --- of is kept: `{"type":"session","id":7}` (rpc adds `unfinished`),
  --- `message` (a message joined the conversation, as the API takes it),
  --- `tool` (a call starts: `name`, `input`), `result` (it ended:
  --- `name`, `is_error`), `request` (a request ended: its model, status,
  --- ms, tokens and cost), `end` (the turn ended: `ok`, and `error` when
  --- it is false) and `error` (a command was refused). rpc's commands
  --- are `{"type":"prompt","text":"..."}`, which runs a turn; `steer`,
  --- which goes to the model after the tool running and skips the calls
  --- after it; `follow_up`, which runs after the turn; `abort`, which
  --- stops the turn at its next step; and `resume`. Between turns, steer
  --- and follow_up run as prompts.
  ---
  --- `--model opus|sonnet` picks the latest of each
  --- (opus by default), `--effort low|medium|high|xhigh|max` how hard it
  --- thinks (medium). `--continue` goes on with the newest session in the
  --- directory, `--session <id>` with any.
  ---
  --- The tools run in a sandbox (`cosmic docs cosmic.agent.policy`): the
  --- working directory is theirs to read and change, the host's programs
  --- run, a home of their own outlives each command, and nothing else is
  --- there, the network included. `--sandbox read` changes nothing,
  --- `--sandbox off` runs them with your user's rights and environment,
  --- your API key included, `--network` lets
  --- bash reach the network, and `--grant path[:rwxc]` adds a path. The
  --- model's words go to standard output, and each tool call to standard
  --- error.
  ---
  --- Everything is kept in sessions.db, in `$XDG_DATA_HOME/cosmic/agent`
  --- (or `~/.local/share/cosmic/agent`), before it is shown: each message,
  --- each tool's whole output, each request with its usage and cost
  --- (`cosmic docs cosmic.agent.sessions`). The model reads it with its
  --- sql tool, and a run that ends mid-turn loses nothing: `cosmic agent
  --- resume` takes the turn up again (`cosmic docs cosmic.agent`). A
  --- program runs the loop itself with [`cosmic.agent`]. It prints no
  --- summary. Exits 0 when it did what was asked, 1 when an ask or resume
  --- turn failed (chat and rpc go on past one) or
  --- the sessions database could not be opened, 2 for a command line it
  --- refuses or a session it cannot start
  agent: string
  --- `cosmic help [verb | exit]`: with no word, the guides to start
  --- from, an index of every verb, one line each, and where to read
  --- more. `cosmic help <verb>`
  --- prints that verb's usage, summary, options, examples and full text. `cosmic help
  --- exit` prints the exit codes and summary every verb shares.
  --- `cosmic <verb> --help` is `cosmic help <verb>`
  help: string
end

local record Module
  --- One field per verb, named for it: the text `cosmic help <verb>`
  --- prints, as [`Cli`] documents it. Help and `cosmic docs` read that
  --- text from each field's doc; the value is always nil.
  fields?: Cli
  --- Each verb as [`Flags.Command`] records it, by verb. Its `spec` is the
  --- verb's options, as [`Flags.parse`] reads a spec: what the verb parses
  --- its command line with, and what `cosmic help` lists beneath its
  --- prose, so the two cannot drift apart; a verb with none leaves it
  --- out. Its `about` is what the verb does, as one short phrase for the
  --- index, and its `usage` what follows the verb's name on its line
  --- there. The four typed as no word of their own -- `cosmic <file.tl>`,
  --- `--standalone`, `-e` and `--version` -- have the `usage` that follows
  --- what is typed instead. No verb's `run` is set: the prose is all this
  --- module holds.
  verbs: {string: Flags.Command}
  --- The index's sections, each a title and the verbs under it, in
  --- order. Together they name every verb once, and set its place.
  groups: {{string}}
  --- Every verb, in the order of [`Module.groups`]: the order help
  --- prints them in.
  order: {string}
end

local GROUPS <const>: {{string}} = {
  { "Running code", "run", "standalone", "eval", "version", "sandbox", "agent" },
  { "Project", "test", "fix", "build", "db", "lsp" },
  { "Quick tools", "sql", "cache", "json", "hash", "codec", "archive", "fetch", "time", "rand", "qr", "acme", "tailscale", "mcp", "compile" },
  { "Lookup", "docs", "uses", "todos", "help" },
  { "This binary", "bom", "refresh", "release" },
}

--- The verbs of `groups` in turn: slot 1 of a group is its title, and
--- its verbs follow.
local function order_of(groups: {{string}}): {string}
  local out: mut {string} = {}
  for _, group in ipairs(groups) do
    for slot = 2, #group do out[#out + 1] = group[slot] end
  end
  return out
end

local module: Module = {
  verbs = {
    run = {
      about = "build the tree around a file and run it",
      usage = "<file.tl> [args]",
      examples = {
        { line = "hello.tl", about = "build the tree around hello.tl and run it" },
        { line = "cmd/tally/main.tl words.txt", about = "run a program from its source, with its words" },
      },
    },
    standalone = {
      about = "run one file with no tree around it",
      usage = "[--check] <file.tl> [args]",
      examples = {
        { line = "script.tl", about = "run a file alone, against the standard library" },
        { line = "--check script.tl", about = "only check it" },
      },
    },
    eval = {
      about = "run a chunk of Teal, checked",
      usage = "'<chunk>' [args]",
      examples = {
        { line = "'print(1 + 2)'", about = "run a line of Teal" },
        { line = "'print(...)' a b", about = "give it words" },
      },
    },
    version = {
      about = "print this binary's digest",
      usage = "",
      examples = {
        { line = "", about = "print this binary's digest" },
      },
    },
    test = {
      about = "build the tree and run its tests",
      usage = "[selector...]",
      examples = {
        { line = "", about = "run every test of the tree" },
        { line = "tally_test.tl", about = "run one file's tests" },
        { line = "tally_test.tl:test_words", about = "run one test" },
      },
      spec = {
        ["--all"] = { about = "run every test, whatever verdict stands for it (COSMIC_TEST_ALL=1); " ..
            "COSMIC_VERDICT_CACHE=0 turns off only the shared verdict cache" },
        ["--show-output"] = { about = "also list what a passing test printed, beneath it; a test " ..
            "that stands is not run and prints nothing (--all runs it)" },
        ["--no-shared"] = { about = "stand on no verdict another checkout reached; what " ..
            "this run reaches is still shared (COSMIC_TEST_NO_SHARED=1)" },
        ["--bail"] = { about = "start no test after the first failure; those already running " ..
            "finish, the tests not started keep no verdict, and the run fails " ..
            "(COSMIC_TEST_BAIL=1)" },
        ["--census"] = { about = "say the digests every key of the run holds, and where none " ..
            "stood on the shared cache, how many rows it holds, even in a checkout " ..
            "that ran before" },
        ["--check-types"] = { about = "compile the tree with a run-time check of each declared " ..
            "parameter, return value and record field write against its type's kind, run every " ..
            "test, and report the values that fail one; a parameter declared under cosmic/ also " ..
            "fails the test that passes it (COSMIC_TEST_CHECK_TYPES=1)" },
        ["--jobs"] = { value = "n", about = "run n tests at once; by default one for each processor and one more" },
        ["--min"] = { value = "pct", about = "fail the run, as a failing test does (status 1), when the " ..
            "tree's line coverage, C included, is under pct percent; a run on standing verdicts " ..
            "has the lines they hit; needs a whole run (no selector, no --shard)" },
        ["--min-file"] = { value = "pct", about = "fail the run when any one file's line coverage is " ..
            "under pct percent, naming each file with its percentage; needs a whole run" },
        ["--shard"] = { value = "i/n", about = "run only the i-th of n shares of the chosen " ..
            "tests, dealt in turn in sorted order, so n runs, i = 1 to n, run each test once" },
        ["--timeout"] = { value = "seconds",
          about = "fail a test that runs longer (COSMIC_TEST_TIMEOUT, else 30); a module's " ..
            "Test.policy { timeout = n } lengthens it for that module" },
      },
    },
    fix = {
      about = "format source files and check the tree",
      usage = "[path...]",
      examples = {
        { line = "tally.tl", about = "lay out a file and check the tree" },
        { line = "--check .", about = "change nothing; fail if a fix would change anything" },
      },
      spec = {
        ["--check"] = { about = "write nothing; name what a fix would change, and fail if any (a Teal file that is " ..
            "not laid out, or that the formatter refuses, fails it)" },
        ["--changed"] = { about = "in cosmic's own tree, lay out only the paths named, which " ..
            "changed since the whole tree passed; what spans files still covers it all" },
      },
    },
    build = {
      about = "write an executable per cmd/<name>/main.tl",
      usage = "[path...]",
      examples = {
        { line = "", about = "write an executable per program" },
        { line = "--host cmd/tally", about = "write one program, native to this system" },
      },
      spec = {
        ["--host"] = { about = "this system's native executable: no launcher, runs only here" },
        ["--out"] = { value = "dir", about = "also write each executable to dir/<name>, made if missing; a program " ..
            "not built leaves none there or in bin/" },
        ["--roots"] = { value = "set", about = "the CA roots its requests trust by default: minimal (the default) " ..
            "or mozilla; every root goes along either way" },
      },
    },
    db = {
      about = "what the build directory's databases hold",
      usage = "[path...]",
      examples = {
        { line = "", about = "what the build directory's databases hold" },
        { line = "tally.tl", about = "only the rows about one source" },
      },
    },
    lsp = {
      about = "a language server for editors",
      usage = "[--stdio] [--listen [host:]port] [--socket path]",
      examples = {
        { line = "", about = "serve one editor over standard input and output" },
      },
      spec = {
        ["--stdio"] = { about = "serve one editor over standard input and output (the default)" },
        ["--listen"] = { value = "[host:]port",
          about = "serve each editor that connects to this TCP port" },
        ["--socket"] = { value = "path",
          about = "serve each editor that connects to this socket file" },
      },
    },
    sql = {
      about = "read-only SQL on a database or data files",
      usage = "<statement>",
      examples = {
        { line = "--from sales.csv 'SELECT region, sum(amount) FROM sales GROUP BY region'", about = "query a CSV file" },
        { line = "--from accounts.json", about = "list a file's columns and a sample row" },
        { line = "--build 'SELECT count(*) FROM modules'", about = "query the build database" },
      },
      spec = {
        ["--db"] = { value = "path", about = "run against this file" },
        ["--build"] = { about = "run against the build directory's build.db" },
        ["--store"] = { about = "run against the binary's own; only PRAGMA data_version" },
        ["--from"] = { value = "file", about = "load a data file (`-` for standard input) as a table " ..
            "named for its stem, or `name=file`; repeat for a join" },
        ["--as"] = { value = "format", about = "read the --from before it as json, ndjson, csv " ..
            "or tsv, rather than by its extension" },
        ["--raw"] = { about = "keep every cell of the csv or tsv --from before it as text: " ..
            "no number is read, an empty cell is '' not NULL" },
        ["--at"] = { value = "path", about = "read the --from before it from the array at this " ..
            "JSONPath ($.data.rows), not the document" },
        ["--to"] = { value = "format", about = "write the rows as csv or ndjson" },
      },
    },
    cache = {
      about = "trim the shared caches named",
      usage = "trim compiles|verdicts PATH...",
      examples = {
        { line = "trim compiles --since-ns 1700000000000000000 /var/cache/cosmic/compiles.db", about = "drop compile rows last used before that time" },
      },
      spec = {
        ["--since-ns"] = { value = "N", about = "keep rows used at or after this Unix nanosecond timestamp" },
        ["--whole"] = { about = "keep verdict rows whole, without vacuuming" },
        ["--restored"] = { value = "PATH", about = "compare retained compile keys with this snapshot" },
        ["--json"] = { about = "print one versioned JSON maintenance report" },
      },
    },
    json = {
      about = "look up a path in a JSON file",
      usage = "<path> [file]",
      examples = {
        { line = "'$.users[0].name' export.json", about = "print one value" },
        { line = "--flat export.json", about = "print every value with its path" },
        { line = "--keys export.json", about = "list the top-level keys" },
      },
      spec = {
        ["--compact"] = { about = "print the value on one line" },
        ["-r"] = { about = "print a string as its text, without quotes; a query's matches as bare values" },
        ["--raw"] = { about = "print a string as its text, without quotes; a query's matches as bare values" },
        ["--flat"] = { about = "print every leaf under the path as a `path = value` line" },
        ["--exists"] = { about = "print nothing; exit 0 when the path exists, 1 when not" },
        ["--keys"] = { about = "list an object's keys, sorted, or an array's length" },
        ["--shape"] = { about = "print a summary of the value's shape, not the value" },
      },
    },
    hash = {
      about = "digest files, or check a sums file",
      usage = "[file...]",
      examples = {
        { line = "notes.txt", about = "the SHA-256 of a file" },
        { line = "--sha512 notes.txt", about = "another algorithm" },
        { line = "--check SHA256SUMS", about = "verify a sums file" },
      },
      spec = {
        ["--md5"] = { about = "digest with MD5" },
        ["--sha1"] = { about = "digest with SHA-1" },
        ["--sha224"] = { about = "digest with SHA-224" },
        ["--sha256"] = { about = "digest with SHA-256 (the default)" },
        ["--sha384"] = { about = "digest with SHA-384" },
        ["--sha512"] = { about = "digest with SHA-512" },
        ["--sha3-224"] = { about = "digest with SHA3-224" },
        ["--sha3-256"] = { about = "digest with SHA3-256" },
        ["--sha3-384"] = { about = "digest with SHA3-384" },
        ["--sha3-512"] = { about = "digest with SHA3-512" },
        ["--json"] = { about = "print an array of {path, algorithm, digest}" },
        ["--check"] = { value = "sums", about = "verify a sums file, or - for standard input" },
        ["--quiet"] = { about = "with --check, print only the failures" },
        ["--hmac"] = { value = "key", about = "make each digest an HMAC under key (visible in ps)" },
        ["--hmac-file"] = { value = "path", about = "make each digest an HMAC under the bytes of a file" },
      },
    },
    codec = {
      about = "encode or decode base64, hex and the like",
      usage = "<encoding> [file]",
      examples = {
        { line = "base64 notes.txt", about = "encode a file" },
        { line = "base64 -d notes.b64", about = "decode it" },
      },
      spec = {
        ["-d"] = { about = "decode text to bytes, ignoring whitespace" },
        ["--decode"] = { about = "decode text to bytes, ignoring whitespace" },
        ["--wrap"] = { value = "n", about = "wrap encoded text at n columns; no wrapping by default" },
        ["--lenient"] = { about = "with -d, accept missing base64 padding, or base64url padding" },
      },
    },
    archive = {
      about = "list, extract or create tar and zip files",
      usage = "<command> ...",
      examples = {
        { line = "list release.tar.gz", about = "list what an archive holds" },
        { line = "extract release.zip -C out", about = "unpack it into out" },
        { line = "create out.tar.gz dir --reproducible", about = "pack a directory" },
      },
      spec = {
        ["--json"] = { about = "list: print an array of objects, not lines" },
        ["-C"] = { value = "dir", about = "extract: unpack into dir (default: the working directory)" },
        ["--force"] = { about = "extract: replace existing files" },
        ["--reproducible"] = { about = "create: fix every modification time, so the same tree packs alike" },
      },
    },
    fetch = {
      about = "GET a URL, verifying what it keeps",
      usage = "<url>",
      examples = {
        { line = "https://example.com/", about = "print the body" },
        { line = "-o tool.tgz https://example.com/tool.tgz --sha256 2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae", about = "save it, if it has this digest" },
      },
      spec = {
        ["-o"] = { value = "file", about = "write the body to file, renamed into place once complete and verified" },
        ["--sha256"] = { value = "hex", about = "fail unless the body has this sha256; on stdout, buffer until verified" },
        ["--sha512"] = { value = "hex", about = "fail unless the body has this sha512 (also checked with --sha256)" },
        ["--allow-downgrade"] = { about = "follow a redirect from https to http, which is refused by default" },
        ["--head"] = { about = "print the status and headers, not the body" },
        ["--json"] = { about = "with --head, print them as a JSON object" },
        ["--roots"] = { value = "set", about = "trust these CA roots: minimal (the default), mozilla, none, " ..
            "or root sha256 digests joined by commas" },
        ["--cacert"] = { value = "file", about = "also trust the certificates in this PEM or DER file; " ..
            "with --roots none, only them" },
        ["--pin"] = { value = "pin", about = "fail unless the server's key hashes to this sha256//<base64>; " ..
            "repeat for more than one" },
      },
    },
    time = {
      about = "show, convert and calculate with times",
      usage = "<command> ...",
      examples = {
        { line = "now --zone Asia/Tokyo", about = "the time in a zone" },
        { line = "convert 2026-03-08T12:00Z --to America/New_York", about = "convert a time" },
        { line = "between 2026-01-01 2026-09-28 --days", about = "count the days between two dates" },
      },
      spec = {
        ["--zone"] = { value = "IANA", about = "the zone to show, or to run the calendar in (default: the host's)" },
        ["--from"] = { value = "IANA", about = "the zone a local time is read in (default: the host's)" },
        ["--to"] = { value = "IANA", about = "the zone to write in (default: the host's)" },
        ["--format"] = { value = "form", about = "rfc3339 (default), date, http or epoch" },
        ["--days"] = { about = "between: whole calendar days" },
        ["--months"] = { about = "between: whole calendar months" },
        ["--seconds"] = { about = "between: whole seconds" },
        ["--clamp"] = { about = "add: a day the month lacks takes its last day, not an error" },
        ["--disambiguate"] = { value = "how", about = "a local time in a gap or overlap: " ..
            "compatible (default), earlier, later or reject" },
        ["--json"] = { about = "print a record: epoch, rfc3339, zone, offset and the civil fields" },
      },
    },
    rand = {
      about = "uuids, tokens, integers, picks and draws",
      usage = "<command> ...",
      examples = {
        { line = "uuid", about = "a random UUID" },
        { line = "token", about = "a 32-byte token" },
        { line = "int 1 6", about = "roll a die" },
      },
      spec = {
        ["--v4"] = { about = "uuid: version 4, random (the default)" },
        ["--v7"] = { about = "uuid: version 7, time-ordered within a run" },
        ["-n"] = { value = "n", about = "uuid, int, pick, normal, gamma: how many to draw (default 1)" },
        ["--bytes"] = { value = "n", about = "token: bytes of entropy, 1 to 1048576 (default 32)" },
        ["--hex"] = { about = "token: lowercase hex" },
        ["--base64url"] = { about = "token: unpadded base64url (the default)" },
        ["--seed"] = { value = "n", about = "int, pick, shuffle, normal, gamma: replayable, NOT secret; refused for uuid and token" },
        ["--mean"] = { value = "m", about = "normal: the mean (default 0)" },
        ["--stddev"] = { value = "sd", about = "normal: the standard deviation, not negative (default 1)" },
        ["--shape"] = { value = "k", about = "gamma: the shape, above 0 (required)" },
        ["--scale"] = { value = "t", about = "gamma: the scale, above 0 (default 1)" },
      },
    },
    qr = {
      about = "draw a QR code, or read one back",
      usage = "[options] [text...]",
      examples = {
        { line = "https://example.com/", about = "a QR code in the terminal" },
        { line = "--svg code.svg https://example.com/", about = "an SVG image" },
        { line = "--read code.svg", about = "read one back" },
      },
      spec = {
        ["--level"] = { value = "L|M|Q|H", about = "the error correction level (default M)" },
        ["--max-version"] = { value = "n", about = "the largest code, 1 to 40 (default 40)" },
        ["--quiet"] = { value = "n", about = "the light border in modules, 0 to 16 (default 4)" },
        ["--invert"] = { about = "draw the dark modules, for a light terminal or paper" },
        ["--ascii"] = { about = "draw with `##` and spaces, not block characters" },
        ["--color"] = { about = "paint it black on white with ANSI escapes, clear on a terminal of either theme" },
        ["--svg"] = { value = "file|-", about = "write an SVG image to the file, or print it" },
        ["--scale"] = { value = "n", about = "svg: pixels a module, 1 to 1000 (default 8)" },
        ["--title"] = { value = "text", about = "svg: what it shows, for a screen reader" },
        ["--read"] = { about = "read back a code `cosmic qr` drew, from a file or standard input" },
      },
    },
    acme = {
      about = "a certificate from Let's Encrypt",
      usage = "<key|issue> [options] [names...]",
      examples = {
        { line = "key account.pem", about = "make a key" },
        { line = "issue --account account.pem --key site.pem --webroot /var/www --agree-tos --out chain.pem example.com", about = "get a certificate" },
      },
      spec = {
        ["--rsa"] = { about = "key: an RSA key, not P-256" },
        ["--bits"] = { value = "n", about = "key: the RSA key's bits, 2048, 3072 or 4096 (default 2048)" },
        ["--account"] = { value = "file", about = "issue: the account key, as PEM" },
        ["--key"] = { value = "file", about = "issue: the certificate key, as PEM" },
        ["--webroot"] = { value = "dir", about = "issue: answer http-01 from this web root" },
        ["--dns-hook"] = { value = "program", about = "issue: answer dns-01 by running this program" },
        ["--staging"] = { about = "issue: Let's Encrypt's staging server" },
        ["--directory"] = { value = "url", about = "issue: another ACME server's directory" },
        ["--contact"] = { value = "url", about = "issue: a contact for the account, such as mailto:ops@example.com" },
        ["--agree-tos"] = { about = "issue: accept the server's terms of service" },
        ["--out"] = { value = "file", about = "issue: write the chain here, not to standard output" },
      },
    },
    tailscale = {
      about = "this machine's Tailscale node, and Taildrop",
      usage = "<status|whois|cert|ping|file> [options] [words...]",
      examples = {
        { line = "status", about = "this node and its peers" },
        { line = "whois 100.101.102.103", about = "who an address is" },
        { line = "file send report.pdf laptop", about = "send a file with Taildrop" },
      },
      spec = {
        ["--socket"] = { value = "path", about = "the daemon's socket, where it is not where it is looked for" },
        ["--json"] = { about = "status, whois, ping, file targets, file list: the answer as JSON" },
        ["--cert-file"] = { value = "file", about = "cert: write the chain here (default <domain>.crt; -: standard output)" },
        ["--key-file"] = { value = "file", about = "cert: write the key here (default <domain>.key; -: standard output)" },
        ["--min-validity"] = { value = "duration", about = "cert: renew first one that expires within this, such as 30d" },
        ["--kind"] = { value = "kind", about = "ping: disco (default), ICMP, TSMP or peerapi" },
        ["--name"] = { value = "name", about = "file send: the name the file goes under (default: its own)" },
        ["--wait"] = { about = "file get: wait for a file when none waits" },
        ["--conflict"] = { value = "how", about = "file get: skip (default), overwrite or rename a name already taken" },
        ["--keep"] = { about = "file get: leave each file waiting in the daemon too" },
      },
    },
    mcp = {
      about = "ask an MCP server, or run its tools",
      usage = "<action> [words...] [-- program...]",
      spec = {
        ["--url"] = { value = "url", about = "the server's Streamable HTTP endpoint, not a program" },
        ["--token-env"] = { value = "name", about = "url: the variable that holds the bearer token" },
        ["--timeout"] = { value = "seconds", about = "the most a request over --url, or a program's run, may take (default 30)" },
      },
      examples = {
        { line = "tools -- server.tl", about = "list the tools of a server this program runs from server.tl" },
        { line = "call add '{\"a\":2,\"b\":5}' -- server.tl", about = "call its tool add" },
        { line = "tools --url https://example.com/mcp --token-env MCP_TOKEN", about = "ask a server over HTTP, its token in $MCP_TOKEN" },
      },
    },
    docs = {
      about = "a symbol's or module's docs, or a search",
      usage = "[words...]",
      examples = {
        { line = "Fs.read", about = "one symbol's docs and examples" },
        { line = "cosmic.fs", about = "a module" },
        { line = "read a file", about = "search by words" },
      },
      spec = {
        ["--json"] = { about = "print one JSON object per entry found (ndjson), not the page" },
      },
    },
    uses = {
      about = "every place that refers to a symbol",
      usage = "<symbol> [path...]",
      examples = {
        { line = "Fs.read", about = "every place that refers to Fs.read" },
      },
    },
    todos = {
      about = "every TODO, with its date and commit",
      usage = "[path | words...]",
      examples = {
        { line = "", about = "every TODO of the tree" },
        { line = "--oldest", about = "the oldest first" },
      },
      spec = {
        ["--oldest"] = { about = "list the oldest first, even when searching" },
      },
    },
    bom = {
      about = "third-party components in this binary",
      usage = "",
      examples = {
        { line = "", about = "the components this binary carries" },
        { line = "--licenses", about = "with their licenses" },
      },
      spec = {
        ["--licenses"] = { about = "print each component's license notices" },
        ["--json"] = { value = "path", about = "write a CycloneDX document to path" },
      },
    },
    refresh = {
      about = "update a binary's certificates and time zones",
      usage = "-o <path>",
      examples = {
        { line = "-o cosmic.new", about = "a copy with newer CA roots, revocations and time zones" },
      },
      spec = {
        ["-o"] = { value = "path", about = "write the refreshed binary here" },
        ["--binary"] = { value = "path", about = "refresh this binary rather than the running one" },
        ["--cacert"] = { value = "file", about = "read the CA roots from this certdata.txt (NSS's) or PEM bundle" },
        ["--onecrl"] = { value = "file", about = "read the revoked certificates from this OneCRL changeset" },
        ["--tzdata"] = { value = "file", about = "read the time zones from this tzdata sdist" },
      },
    },
    release = {
      about = "find, verify and download a release",
      usage = "[--commit <hex>] [--until <time>] [--list [-n <count>] | -o <file> | --cache] [--pin <file> | --launcher <file>] [--json]",
      examples = {
        { line = "--list", about = "list the recent releases" },
        { line = "-o cosmic", about = "download and verify the latest" },
      },
      spec = {
        ["--commit"] = { value = "hex", about = "the release whose commit starts with this, 7 to 40 hex digits" },
        ["--until"] = { value = "time", about = "the newest published at or before this RFC 3339 time, or by the end of this date (UTC)" },
        ["--list"] = { about = "print the matching releases, newest first, verifying none" },
        ["-n"] = { value = "count", about = "with --list, print at most this many (default 20)" },
        ["--json"] = { about = "print the release, or with --list the releases, as JSON" },
        ["-o"] = { value = "file", about = "write the verified binary here, mode 0755" },
        ["--cache"] = { about = "write the verified binary into bin/cosmic-bootstrap's cache and print its path" },
        ["--pin"] = { value = "file", about = "write the release as ci/cosmic-driver.pin's three lines, once verified" },
        ["--launcher"] = { value = "file", about = "write a project's launcher here, mode 0755, and the release as its pin, <file>.pin" },
      },
    },
    agent = {
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
        ["--network"] = { about = "let bash reach the network" },
        ["--grant"] = { value = "path[:rwxc]", about = "let the tools reach this path too, read alone unless letters say more" },
      },
    },
    sandbox = {
      about = "run a program held to what you grant it",
      usage = "[options] [--] <program> [args...]",
      examples = {
        { line = "--system --read . -- ls -l", about = "run ls, able to read this directory and what a host program needs" },
        { line = "--cosmic --read . -- cosmic convert.tl", about = "run a script of yours the same way" },
      },
      spec = {
        ["--read"] = { value = "path", about = "grant a path to read (r)" },
        ["--run"] = { value = "path", about = "grant a path to read and run (rx)" },
        ["--write"] = { value = "path", about = "grant a path to read, write and create in (rwc)" },
        ["--path"] = { value = "letters:path", about = "grant a path the letters of rwxcu, in that order" },
        ["--system"] = { about = "what a host's programs need to start" },
        ["--database"] = { value = "path", about = "run this program on a sealed database: only its modules load" },
        ["--modules"] = { value = "a,b,...", about = "seal these modules (the first the main) and run on that" },
        ["--closure"] = { about = "seal a script and the modules it requires, and run it on that" },
        ["--cosmic"] = { about = "this program's own file, which then runs as its core" },
        ["--isolate"] = { value = "file|proc", about = "a root of its own, or a process space of its own" },
        ["--promise"] = { value = "name", about = "a system call it may make: fork, jit, fattr or nest" },
        ["--connect"] = { value = "host:port", about = "a host it may reach, through a relay (Linux only)" },
        ["--loopback"] = { value = "addr", about = "an address of 127/8 it uses in its own network" },
        ["--env"] = { value = "name", about = "pass this variable through from the environment" },
        ["--set-env"] = { value = "name=value", about = "set this variable" },
        ["--tmp"] = { about = "a fresh temporary directory of its own, named by TMPDIR" },
        ["--open-files"] = { value = "n", about = "the most descriptors a process holds open" },
        ["--file-bytes"] = { value = "n", about = "the most bytes a process writes to one file" },
        ["--cpu-seconds"] = { value = "n", about = "the CPU seconds a process may spend" },
        ["--processes"] = { value = "n", about = "the most processes and threads of the whole sandbox" },
        ["--user"] = { value = "uid[:gid]", about = "run it as this user and group (a root caller's choice)" },
        ["--fd"] = { value = "n", about = "hand it descriptor n (3 to 255), as the same number" },
        ["--timeout"] = { value = "seconds", about = "end it after this many whole seconds" },
        ["--cwd"] = { value = "dir", about = "start it in this directory, which relative paths are taken from" },
      },
    },
    compile = {
      about = "Teal to Lua, even with type errors",
      usage = "[options] <file.tl>...",
      examples = {
        { line = "file.tl", about = "print the Lua a Teal file compiles to" },
        { line = "-o out a.tl b.tl", about = "write out/a.lua and out/b.lua" },
      },
      spec = {
        ["-o"] = { value = "dir", about = "write <name>.lua for each file in this directory" },
        ["--errors"] = { about = "list each type error, warning and refusal, not only the count" },
        ["--root"] = { value = "dir", about = "the directory module names are relative to (default: here)" },
      },
    },
    help = {
      about = "this index, or a verb's full text",
      usage = "[verb]",
      examples = {
        { line = "", about = "the index of verbs" },
        { line = "json", about = "one verb's full text" },
      },
    },
  },
  groups = GROUPS,
  order = order_of(GROUPS),
}

return module
