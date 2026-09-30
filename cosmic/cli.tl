--- Help for the `cosmic` verbs: `cosmic help` prints an index of them
--- and `cosmic help <verb>` one verb's full text, generated from one
--- field per verb (`cosmic docs test`, `build`, `fix`, ... answer with
--- the same text, ahead of the module of that name when there is one).
--- This is not an argument parser for a project's own command line: a
--- project's cmd/<name>/main.tl gets its arguments as a plain array, and
--- `Flags.parse(argv, 1, spec)` from cosmic.flags reads its options, or
--- `Flags.dispatch(argv, 1, commands)` its commands -- see argv.
---
--- The index comes from `usage`, `summary` and `groups`, a verb's page
--- from its field and `options`, in the order `order` gives.

local Flags = require("cosmic.flags")

--- One field per verb: the full text of `cosmic help <verb>`.
local record Cli
  --- `cosmic <file.tl>`: builds the tree the file sits in -- the
  --- working directory when the file is under it, so a file of a
  --- project reaches the rest of it; the file's own directory
  --- otherwise -- then runs it: requires the file, and if what it
  --- returns is a function, calls it with one argument -- see argv --
  --- and exits with what it returns, as `eval` does: nothing is 0, a
  --- whole number from 0 to 255, or text naming one, is itself, and
  --- anything else is complained about and exits 2
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
  --- to 255, or text naming one, is itself, and anything else is
  --- complained about and exits 2
  eval: string
  --- `cosmic --version`: prints `cosmic <hex>`, the SHA-256 of the file
  --- this binary runs from -- the digest a release's SHA256SUMS names
  --- it by and its notes cite -- with nothing built or checked
  version: string
  --- `cosmic test [options] [selector...]`: builds the tree in the working
  --- directory, then runs every test it defines (`cosmic docs
  --- cosmic.layout` says where tests and examples live). `cosmic docs`
  --- shows an example under every symbol it calls. A selector narrows
  --- the run to the modules it names, a file, a module name, or a
  --- directory; `<file or module>:<name>` to the
  --- one test of that name, `test_*` or an example's, and one no test
  --- there has is refused. Each test runs
  --- in a process of its own, and fails if it runs past its timeout;
  --- what a failing test printed is shown beneath it. A test whose
  --- verdict still stands is not run again: one this checkout reached,
  --- in o/build.db, or one any checkout of the same content did, which
  --- every sandboxed run shares through $XDG_CACHE_HOME/cosmic/verdicts
  --- (~/.cache/cosmic/verdicts): COSMIC_VERDICT_CACHE names another
  --- file, and COSMIC_VERDICT_CACHE=0 turns it off. A run whose workers
  --- are not sandboxed (COSMIC_TEST_SANDBOX=0, or macOS) shares only
  --- through a file COSMIC_VERDICT_CACHE names. A module is not
  --- compiled again either, nor a source parsed, where any checkout
  --- compiled or parsed the same, through $XDG_CACHE_HOME/cosmic/build
  --- (~/.cache/cosmic/build): COSMIC_BUILD_CACHE names another file, and
  --- COSMIC_BUILD_CACHE=0 turns it off. The tree is the working directory,
  --- unless that has no o/cosmic.db and an ancestor below the home
  --- directory has one whose build staged the working directory: then it
  --- is that ancestor, named on stderr, and paths are read from the
  --- working directory. COSMIC_TREE=<dir> names the tree outright, `.`
  --- for the working directory
  test: string
  --- `cosmic fix [options] [path...]`: rewrites every Teal source in
  --- the working directory structurally, then writes it back out as
  --- canonical text, in place: run it after editing rather than
  --- formatting by hand -- checking along the way that rendering it
  --- again would change nothing further, and refusing a file it does
  --- not. It also builds the tree and parenthesizes every `assert(...)`
  --- the type checker says passes on more values than its place can
  --- take -- `(assert(...))` keeps only the first. It fails a link in a
  --- comment or a Markdown file -- `` [`x`] ``, `[text](target)` or
  --- `[text][label]` -- that names nothing, or more than one thing, and
  --- makes a link of a plain `` `x` `` that names one top-level
  --- declaration of its own file, one file, or, written in full
  --- (`module.member`), one symbol; in Markdown it also
  --- writes the definitions GitHub needs to show one, at the file's
  --- end. It never lays out a Markdown or Zig file. The tree is found
  --- as `test` finds it
  fix: string
  --- `cosmic build [options] [path...]`: builds the tree in the working
  --- directory, then writes one executable under o/bin/ for each
  --- cmd/<name>/main.tl it holds -- or only those under the paths --
  --- o/bin/<name>, which runs on its own, with nothing beside it -- see
  --- cmd. It runs on every supported system, and carries this binary's
  --- CA roots and time zones: `cosmic refresh --binary o/bin/<name> -o
  --- <copy>` writes a copy with newer ones later. The tree is found as
  --- `test` finds it
  build: string
  --- `cosmic db [path...]`: what the three databases under o/ hold,
  --- table by table -- rows, pages, bytes -- how the last few builds
  --- went, and the slowest tests. Paths narrow it to the rows about the
  --- sources under them -- a row whose file, module or source hash is
  --- one under a path -- counted per table (coverage counting every run
  --- kept, not only the latest), and the slowest of those tests. Pages,
  --- bytes and builds are not per source, so a narrowed report leaves
  --- them out. The tree is found as `test` finds it
  db: string
  --- `cosmic sql [--db <path> | --build | --store] <statement>`: runs
  --- one SQL statement read-only -- SQLite itself refuses a write --
  --- against o/cosmic.db, or the binary's own database when there is
  --- none, or the one database an option names. o/ is looked for in
  --- the working directory only, never above it. `cosmic sql --from
  --- <file> ['<statement>']` asks it of a data file instead, to count,
  --- filter, join and sum where `cosmic json` only looks up (`cosmic sql
  --- --from accounts.json 'SELECT type, sum(balance) FROM accounts GROUP
  --- BY type'`): each `--from` is loaded as a table of an in-memory
  --- database, named for the file's stem (`--from name=file` names it,
  --- and `-` reads standard input), read as JSON, as JSON Lines for
  --- `.jsonl` and `.ndjson`, as CSV for `.csv` and as TSV for `.tsv` and
  --- `.tab`; `--as json|ndjson|csv|tsv` overrides the extension, and
  --- standard input needs it. `--as`, `--at '<path>'` and `--raw` apply
  --- to the `--from` before them, and `--at` reads the rows from
  --- the array at a path, as `cosmic json` reads one (a CSV or TSV has
  --- no path). A CSV or TSV (RFC 4180, quotes and all) has a header
  --- line naming the columns, in that order, and a row per record; a record with more
  --- or fewer fields than the header is refused, naming its line, and a
  --- blank line is skipped, except in a one-column file, where one before
  --- the last record is an empty cell (blank lines at the end are dropped, so a final empty cell is written `""` to be kept). Its
  --- cells are typed by one rule: a cell that is plainly a number (an
  --- optional `-`, digits, an optional fraction or exponent; no `+`, no
  --- leading zero, no spaces) is an integer or a real, an empty cell is
  --- NULL, and anything else, `007` and ZIP codes included, is text;
  --- `--raw` keeps every cell text, the empty one `''`. An array of
  --- objects is a table of them, with a column per key, an array of
  --- scalars a `value` column, and any other value one row; a nested
  --- object or array is JSON text for `json_extract`, a boolean is 0 or
  --- 1, `_json` is the whole row, and a key that would collide (`A` with
  --- `a`, or `_json`, `rowid`) is renamed `_2`. With no statement it prints each
  --- table's row count, columns with the types stored, and a sample row.
  --- A missing column or table is answered with the ones there are.
  --- Exit codes as below, 1 for a file it cannot read or load. The
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
  --- `cosmic json [options] [path] [file|-]`: the answer to a quick
  --- question about a JSON file -- is there a key `x` in this export,
  --- what is under `users[1]` -- with no script to write. It reads the
  --- file, or standard input when the file is `-` or absent, and prints
  --- the value at the path as JSON, indented, or on one line with
  --- `--compact`; a string prints as its text with `-r`. A path reads
  --- as the paths the JSON messages print: `$` is the document, then
  --- `.key` or `["a key"]` and `[1]`, counted from 1 as [`Json.get`]
  --- counts (`$.users[1].name`); with a file after it, a first key
  --- needs no dot (`a.b`), and whitespace in a path is part of a key.
  --- `*` (`.*` or `[*]`) is every member of an object or element of an
  --- array, and `..key` or `..[n]` that key or index at any depth, the
  --- current level included (`$..id`, `$.users[*].name`): such a path
  --- prints each match as a `path = value` line, the value as compact
  --- JSON (`$.users[1].name = "ann"`), in document order (arrays by
  --- index, keys sorted); with `-r`, the raw values alone, one to a line
  --- (a string prints as its text, so one with a newline in it spans
  --- lines; without `-r`, or with `--flat`, every line is one JSON value);
  --- with `--exists`, nothing, and 0 when at least one matches. A key
  --- named `*` is `["*"]`. JSONPath's filters, slices and unions are
  --- left out on purpose: this is a lookup, not a query language.
  --- `--flat` prints every leaf under the path (the whole document with
  --- none) as such lines, in the same order, an empty object or array
  --- as `{}` or `[]`; the path of each line is exactly one this command
  --- takes, so `cosmic json --flat export.json | grep -i email` finds a
  --- leaf and its path pastes back into `cosmic json '$.users[2].email'
  --- export.json`. Quote a path in single quotes in a shell
  --- (`'$.users[1]'`), which would expand `$` and `[1]`. With one word,
  --- it is the path when it begins `$`, `.` or `[` (and not `./` or
  --- `../`), else the file; a file named `.data.json` is `./.data.json`,
  --- and after `--` the words are `[path] file` whatever they begin
  --- with. The value is printed as [`Json.encode`] writes it, not echoed
  --- byte for byte: `1e2` prints as `100.0` and a big integer loses
  --- precision. `--exists` prints
  --- nothing and only answers by its exit status; `--keys` lists an
  --- object's keys, sorted, one per line, or an array's length;
  --- `--shape` prints [`Json.describe`] of the value, and neither takes a
  --- pattern, which can match many values. Only a lookup: no
  --- filter, no transform; to count or sum, use `cosmic sql --from`.
  --- Exits 0 when the path is found (a pattern:
  --- when something matches), 1 when it is not, with the message
  --- [`Json.get`] gives on standard error (a pattern that matches nothing:
  --- `<pattern>: no match`; a `null` value is found), 2 for a command line
  --- it cannot read, a pattern too deep to walk, or a
  --- file that is missing or not JSON. It prints no verdict line, which
  --- would be in the data a pipe reads
  json: string
  --- `cosmic hash [options] [file|-]...`: the digest of each file, or of
  --- standard input for `-` or no file, printed as `sha256sum` prints
  --- it, `<hex>  <name>`, the same on every platform. The algorithm is
  --- `--sha256` (the default), `--sha512`, `--sha384`, `--sha224`,
  --- `--sha1`, `--md5`, or `--sha3-224`, `--sha3-256`, `--sha3-384`,
  --- `--sha3-512`: those [`cosmic.hash`] has. Every file streams in a
  --- chunk at a time, so its size does not matter to memory. A name with
  --- a backslash or a newline is written as GNU writes it: the line
  --- begins `\` and the name has `\\`, `\n` and `\r` (all three read back). A file named `-` is
  --- `./-`. `--json` prints an array of `{path, algorithm, digest}`
  --- instead. `--check <sums>` (or `-` for standard input) verifies a
  --- sums file in that format, with the text and `*` binary markers,
  --- escaped names, and blank and `#` lines skipped; the digest sizes
  --- follow the algorithm option, so name it for a non-SHA-256 file.
  --- Each file prints `name: OK`, `name: FAILED`, or `name: FAILED open
  --- or read`, its name escaped as above; `--quiet` prints only the
  --- failures. BSD `SHA256 (file) = hex` lines and one-space separators
  --- are refused as malformed, and a malformed line makes the exit 2
  --- even when every entry is OK (GNU only warns, without `--strict`);
  --- a CRLF sums file leaves the CR in each name. The listed paths are
  --- opened as given, so `--check` refuses a path that is not a regular
  --- file (`FAILED open or read`), and a sums file you do not trust can
  --- still make it read any regular file you can. `--hmac <key>` makes
  --- each digest an HMAC under the key, and `--hmac-file <path>` reads
  --- the key from a file (its bytes exactly, a trailing newline
  --- included, with a warning: write it with `printf %s`). Prefer the file: a key on the
  --- command line shows in `ps` and the shell's history. Every
  --- algorithm has an HMAC, and it streams too; `--json` names it
  --- `hmac-sha256` and the like, and `--check` verifies HMACs when
  --- given a key. It prints no verdict line: its output is data. Exits 0
  --- when all is well, 1 when a check failed or a listed file could not
  --- be read, 2 for a command line, a file to hash, a sums file (a
  --- malformed line among them) or a write to standard output it cannot
  --- use, with `cosmic: hash: ...` on standard error
  hash: string
  --- `cosmic archive list|extract|create`: the zip and tar files a
  --- release ships, with no script. `list <file>|-` prints one entry
  --- per line -- path (a symlink's `path -> target`), size, mode in
  --- octal, and type, tab-separated, control bytes escaped -- or, with
  --- `--json`, an array of objects (path, type, size, mode as the same
  --- octal string, mtime and a symlink's linkpath) for `cosmic json`.
  --- `extract <file>|- [-C dir] [member...]` unpacks into dir (the
  --- working directory by default) and prints the paths written; a
  --- member is a path in the archive and takes what is under it. The
  --- format -- zip, tar, or tar under gzip, xz or bzip2 -- is read from
  --- the file's first bytes, not its name. An absolute path, a `..`,
  --- or a symlink out of the target is refused ([`Archive.extract`]), and
  --- so is replacing an existing path unless `--force` is given. Only
  --- that refusal and a member not in the archive write nothing: an
  --- unsafe entry stops the extraction after the entries before it,
  --- which stay written. `create <out> <path>...` packs the paths and what is under
  --- them, sorted by name, as a zip or a gzip tar, by the extension of
  --- out (`.zip`, `.tar.gz`, `.tgz`); `--reproducible` fixes every
  --- modification time (tar 0, zip 1980) so the same tree packs to the
  --- same bytes; file modes are kept, not normalised. `.tar.xz` and `.tar.bz2` are refused: there is no
  --- encoder for either. Paths must be relative and stay under the
  --- working directory; a symlink cannot go in a zip, and a fifo,
  --- socket or device is refused, named, wherever it is found. Prints no verdict
  --- line, its output being data for a pipe. Exits 0 when done, 1 for a
  --- member or a path that is not there or files it would overwrite, 2
  --- for a command line, an archive it cannot read or one it refuses
  --- to unpack. See also `cosmic json`
  archive: string
  --- `cosmic rand <uuid|token|int|pick|shuffle> [options]`: an id, a
  --- token, a number or a shuffled list, with no script to write.
  --- `uuid [--v4|--v7] [-n N]` prints N UUIDs (default one, version 4);
  --- version 7 (RFC 9562) leads with the millisecond clock, then a
  --- 12-bit counter (the RFC's method 3, section 6.2: the clock's
  --- fraction of the millisecond, bumped by one where a draw would not
  --- sort after the last), then entropy, so one run's values sort as
  --- drawn; a clock that steps far back leaves them ahead of real time
  --- for the rest of the run. `-n` is at most 10000000 (a refusal past
  --- it, exit 2); ten million UUIDs take about 40 seconds, ten million
  --- integers about 15. `token
  --- [--bytes N] [--hex|--base64url]` prints N random bytes (default
  --- 32, at most 1048576) as base64url without padding, or as hex.
  --- `int [-n N] <lo> <hi>` prints N integers (default one) uniform over
  --- lo..hi inclusive, drawn by rejection so no value is likelier;
  --- bounds may be negative (`int -5 5`), and lo above hi is refused.
  --- `pick [-n N] [file|-]` prints N distinct lines, and `shuffle
  --- [file|-]` all of them, in an order drawn by Fisher-Yates; a line
  --- ends at a newline, a carriage return before it is dropped (CRLF
  --- input reads as LF), and an empty input has none. Asking `pick` for
  --- more lines than there are is refused, exit 2, with nothing
  --- printed. Everything secret-grade -- uuid, token, and the rest
  --- without `--seed` -- comes from the operating system's entropy
  --- source ([`Rand.entropy`]), never from a seeded generator. `--seed
  --- N` (int, pick, shuffle only) draws from `Rand.new(N)` instead, so
  --- a test or a script can replay it: that output is NOT secret, and
  --- `--seed` is refused with uuid and token. Its standard output is
  --- data and ends in no verdict line. Exits 0 when it printed,
  --- 1 when the entropy source failed, 2 for a command line, a file or a
  --- request it refuses, or a failed write to standard output
  rand: string
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
  --- civil fields. It prints no verdict line, as `json` does: exit 0
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
  --- input is read at once. It prints no verdict line, which would be in
  --- the data a pipe reads; exits 0 when done, 2 for a command line, an
  --- input or a write it cannot honor
  codec: string
  --- `cosmic fetch <url[#sha256=hex]> [-o file] [--sha256 hex] [--sha512 hex] [--allow-downgrade] [--head [--json]]`: one
  --- GET, a small curl. With no `-o` the body goes to standard output, so
  --- `cosmic fetch <url> | cosmic json '.items'` reads it; with `-o` it is
  --- written to a temporary file beside the target and renamed into place
  --- only once it is all in and matches `--sha256`, `--sha512` or the digest
  --- the URL's fragment carries (`<url>#sha256=<hex>`, or `#sha256sum=`,
  --- `#sha512=`, `#sha512sum=`; the fragment is never sent or printed, and
  --- an unrecognized one is dropped, but one that looks like a
  --- checksum this verb does not check, such as `sha1=` or `SHA256=`, is exit 2; a bad digest, or a flag and fragment
  --- for one algorithm that differ, exits 2 before any request; for
  --- different algorithms both must match), so a failed digest
  --- leaves nothing at the target. `--sha256` with standard output holds
  --- the whole body in memory and writes it only once the digest
  --- matches, since bytes already on a pipe cannot be taken back; on a
  --- mismatch it exits 1 and names both digests. A status outside 2xx
  --- fails (exit 1, the status on standard error), as `curl -f` does,
  --- and nothing turns that off, so an error page never reaches a pipe;
  --- `--head` prints `HTTP <status>` and the headers, names lowercased
  --- and sorted, or with `--json` an object of `status`, `url` and
  --- `headers`, and then fails on a non-2xx too. Redirects are followed,
  --- up to 10, as [`cosmic.http`] follows them, but from an https URL a
  --- redirect to http is refused (exit 1), unlike curl's default;
  --- `--allow-downgrade` follows it, best with `--sha256`. Header
  --- values print with control bytes as `\xNN`, and a URL's userinfo prints as
  --- `***`. Streaming to standard output can leave partial bytes sent before a
  --- failure (exit 1); a digest there buffers the whole body, uncapped. Certificates are always
  --- verified: there is no option that turns it off. GET only, by
  --- design: for a header, a body or another method write the script
  --- with [`cosmic.http`]. It prints no verdict line, which would be in
  --- the body a pipe reads. Exits 0 when the body was delivered, 1 when
  --- the fetch failed (no connection, a bad status, a digest that does
  --- not match, a body that broke off, an `-o` write that failed), 2 for a command line, a URL or
  --- a write to standard output it cannot use
  fetch: string
  --- `cosmic docs [q]`: what the database says about q -- a symbol
  --- (Fs.read, read), a module (cosmic.fs, or fs for its last name),
  --- or words to search the documentation for; a module lists the
  --- signature of each function it offers, ahead of the rest of its
  --- prose; with no q, every module there is, with what it is for. The
  --- tree is found as `test` finds it
  docs: string
  --- `cosmic uses <sym> [path...]`: every place that refers to a
  --- symbol, as file:line -- only those under the paths, when given --
  --- each link in a comment to it marked `link`. The symbol may be a
  --- file's path instead (doc/meta.md, or doc/meta.md#heading for one
  --- heading), which only links name. The tree is found as `test`
  --- finds it
  uses: string
  --- `cosmic todos [options] [path | words...]`: every `TODO:` comment
  --- in the tree, as file:line, with the date and commit git blames its
  --- first line on -- in a git repository only: elsewhere git is not
  --- started, and each is listed with none -- indexed into o/build.db so
  --- only a file that moved is blamed again. An argument that names a path narrows it to that
  --- path; the rest are words to search the TODOs' text for, best match
  --- first, in FTS5's own syntax ("a phrase", OR, prefix*) when they
  --- parse as that. The tree is found as `test` finds it
  todos: string
  --- `cosmic bom [--licenses | --json <path>]`: the bill of materials
  --- this binary ships under -- every third-party component its cores
  --- and database carry, one line each: name, version, license, and
  --- how many patches cosmic applies to it -- or, for data (the CA
  --- roots, the time zones), that `cosmic refresh` updates it. `--licenses` prints the
  --- notices those licenses ask a copy to travel with; `--json` writes
  --- the list as a CycloneDX document instead. An executable `cosmic
  --- build` writes carries the same rows
  bom: string
  --- `cosmic refresh -o <path> [--binary <path>] [--<dataset> <file>...]
  --- [dataset...]`: the way to update the CA certificates a binary
  --- trusts and the time zone database it carries when they go out of
  --- date, with no rebuild. It writes to path a copy of this binary -- or
  --- of the
  --- one --binary names, a program `cosmic build` wrote, say -- whose
  --- data is replaced with a newer release: the CA roots it trusts
  --- (cacert, Mozilla's bundle as curl publishes it) and the time zones
  --- it carries (tzdata, as PyPI's tzdata sdist holds them). Each named
  --- dataset is fetched upstream, its newest release; one given a file is
  --- read from it, with no network; with neither, every dataset is
  --- fetched. Every row is checked before anything is written, the
  --- bill of materials records the release each came from, and the
  --- binary it reads is never written
  refresh: string
  --- `cosmic help [verb | exit]`: with no word, an index of every verb,
  --- one line each, and where to read more. `cosmic help <verb>`
  --- prints that verb's full text, options and exit codes. `cosmic help
  --- exit` prints the verdict lines and exit codes every verb shares.
  --- `cosmic <verb> --help` is `cosmic help <verb>`
  help: string
end

local record Module
  --- One field per verb, named for it: the text `cosmic help <verb>`
  --- prints, as [`Cli`] documents it.
  fields: Cli
  --- Each verb's options, by verb, as [`Flags.parse`] reads a spec: what
  --- the verb parses its command line with, and what `cosmic help`
  --- lists beneath its prose, so the two cannot drift apart. A verb
  --- that is absent takes none.
  options: {string: {string:boolean | Flags.Option}}
  --- The command line of each verb, as its line in the index shows it.
  usage: {string:string}
  --- What each verb does, as one short phrase for the index.
  summary: {string:string}
  --- The index's sections, each a title and the verbs under it, in
  --- order. Together they name every verb once.
  groups: {{string}}
  --- The order `verb_help` prints these in. A record's field order is
  --- not queryable at runtime, so it is spelled out here.
  order: {string}
end

local module: Module = {
  fields = {
    run = "run", standalone = "standalone", eval = "eval", version = "version", test = "test", fix = "fix", build = "build",
    db = "db", sql = "sql", json = "json", hash = "hash", codec = "codec", archive = "archive", fetch = "fetch", time = "time", rand = "rand", docs = "docs", uses = "uses", todos = "todos", bom = "bom",
    refresh = "refresh", help = "help",
  },
  options = {
    test = {
      ["--all"] = { about = "run every test, whatever verdict stands for it, in this " ..
        "checkout or another (COSMIC_TEST_ALL=1)" },
      ["--no-shared"] = { about = "stand on no verdict another checkout reached; what " ..
        "this run reaches is still shared (COSMIC_TEST_NO_SHARED=1)" },
      ["--census"] = { about = "say the digests every key of the run holds, and where none " ..
        "stood on the shared cache, how many rows it holds, even in a checkout " ..
        "that ran before" },
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
      ["--from"] = { value = "file", about = "load a data file (`-` for standard input) as a table " ..
        "named for its stem, or `name=file`; repeat for a join" },
      ["--as"] = { value = "format", about = "read the --from before it as json, ndjson, csv " ..
        "or tsv, rather than by its extension" },
      ["--raw"] = { about = "keep every cell of the csv or tsv --from before it as text: " ..
        "no number is read, an empty cell is '' not NULL" },
      ["--at"] = { value = "path", about = "read the --from before it from the array at this " ..
        "path ($.rows), not the document" },
    },
    json = {
      ["--compact"] = { about = "print the value on one line" },
      ["-r"] = { about = "print a string as its text, without quotes; a pattern's matches as bare values" },
      ["--raw"] = { about = "print a string as its text, without quotes; a pattern's matches as bare values" },
      ["--flat"] = { about = "print every leaf under the path as a `path = value` line" },
      ["--exists"] = { about = "print nothing; exit 0 when the path exists, 1 when not" },
      ["--keys"] = { about = "list an object's keys, sorted, or an array's length" },
      ["--shape"] = { about = "print the value's shape (Json.describe), not the value" },
    },
    hash = {
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
    archive = {
      ["--json"] = { about = "list: print an array of objects, not lines" },
      ["-C"] = { value = "dir", about = "extract: unpack into dir (default: the working directory)" },
      ["--force"] = { about = "extract: replace existing files" },
      ["--reproducible"] = { about = "create: fix every modification time, so the same tree packs alike" },
    },
    rand = {
      ["--v4"] = { about = "uuid: version 4, random (the default)" },
      ["--v7"] = { about = "uuid: version 7, time-ordered within a run" },
      ["-n"] = { value = "n", about = "uuid, int, pick: how many to draw (default 1)" },
      ["--bytes"] = { value = "n", about = "token: bytes of entropy, 1 to 1048576 (default 32)" },
      ["--hex"] = { about = "token: lowercase hex" },
      ["--base64url"] = { about = "token: unpadded base64url (the default)" },
      ["--seed"] = { value = "n", about = "int, pick, shuffle: replayable, NOT secret; refused for uuid and token" },
    },
    codec = {
      ["-d"] = { about = "decode text to bytes, ignoring whitespace" },
      ["--decode"] = { about = "decode text to bytes, ignoring whitespace" },
      ["--wrap"] = { value = "n", about = "wrap encoded text at n columns; no wrapping by default" },
      ["--lenient"] = { about = "with -d, accept missing base64 padding, or base64url padding" },
    },
    fetch = {
      ["-o"] = { value = "file", about = "write the body to file, renamed into place once complete and verified" },
      ["--sha256"] = { value = "hex", about = "fail unless the body has this sha256; on stdout, buffer until verified" },
      ["--sha512"] = { value = "hex", about = "fail unless the body has this sha512 (also checked with --sha256)" },
      ["--allow-downgrade"] = { about = "follow a redirect from https to http, which is refused by default" },
      ["--head"] = { about = "print the status and headers, not the body" },
      ["--json"] = { about = "with --head, print them as a JSON object" },
    },
    time = {
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
    bom = {
      ["--licenses"] = { about = "print each component's license notices" },
      ["--json"] = { value = "path", about = "write a CycloneDX document to path" },
    },
    refresh = {
      ["-o"] = { value = "path", about = "write the refreshed binary here" },
      ["--binary"] = { value = "path", about = "refresh this binary rather than the running one" },
      ["--cacert"] = { value = "file", about = "read the CA roots from this PEM bundle" },
      ["--tzdata"] = { value = "file", about = "read the time zones from this tzdata sdist" },
    },
    todos = {
      ["--oldest"] = { about = "list the oldest first, even when searching" },
    },
  },
  usage = {
    run = "cosmic <file.tl> [args]", standalone = "cosmic --standalone <file.tl>",
    eval = "cosmic -e '<chunk>' [args]", version = "cosmic --version",
    test = "cosmic test [selector...]", fix = "cosmic fix [path...]",
    build = "cosmic build [path...]", db = "cosmic db [path...]",
    sql = "cosmic sql <statement>", json = "cosmic json <path> [file]",
    hash = "cosmic hash [file...]", codec = "cosmic codec <encoding> [file]",
    archive = "cosmic archive <command> ...", fetch = "cosmic fetch <url>",
    time = "cosmic time <command> ...", rand = "cosmic rand <command> ...",
    docs = "cosmic docs [words...]", uses = "cosmic uses <symbol> [path...]",
    todos = "cosmic todos [path | words...]", bom = "cosmic bom",
    refresh = "cosmic refresh -o <path>", help = "cosmic help [verb]",
  },
  summary = {
    run = "build the tree around a file and run it",
    standalone = "run one file with no tree around it",
    eval = "run a Lua chunk",
    version = "print this binary's digest",
    test = "build the tree and run its tests",
    fix = "format source files and check the tree",
    build = "write o/bin/<name> per cmd/<name>/main.tl",
    db = "what the databases under o/ hold",
    sql = "read-only SQL on a database or data files",
    json = "look up a path in a JSON file",
    hash = "digest files, or check a sums file",
    codec = "encode or decode base64, hex and the like",
    archive = "list, extract or create tar and zip files",
    fetch = "GET a URL, verifying what it keeps",
    time = "show, convert and calculate with times",
    rand = "uuids, tokens, integers, picks",
    docs = "a symbol's or module's docs, or a search",
    uses = "every place that refers to a symbol",
    todos = "every TODO, with its date and commit",
    bom = "third-party components in this binary",
    refresh = "update a binary's CA roots and time zones",
    help = "this index, or a verb's full text",
  },
  groups = {
    { "Running code", "run", "standalone", "eval", "version" },
    { "Project", "test", "fix", "build", "db" },
    { "Quick tools", "sql", "json", "hash", "codec", "archive", "fetch", "time", "rand" },
    { "Lookup", "docs", "uses", "todos", "help" },
    { "This binary", "bom", "refresh" },
  },
  order = { "run", "standalone", "eval", "version", "test", "fix", "build", "db", "sql", "json", "hash", "codec", "archive", "fetch", "time", "rand", "docs", "uses", "todos",
    "bom", "refresh", "help" },
}

return module
