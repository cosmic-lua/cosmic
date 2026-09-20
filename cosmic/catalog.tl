--- Hand-authored guidance for cosmic's own runtime and tooling: a
--- message an uncaught error can raise, or a word `cosmic docs` can
--- be asked about, matched to a hint already known for it.
---
--- Nothing here runs. `build/writer.tl` reads `Catalog.rows` at build
--- time to seed the `catalog` table every project's own database
--- carries; a catalog row is then read two ways -- reactively, the
--- moment an uncaught error's message matches one (`core/main.c`'s
--- `catalog_guidance`), and proactively, by symbol or by searching its
--- text (`build/docs.tl`'s `named_catalog`/`searched_catalog`). This
--- module lives in `cosmic.*`, not `build.*`, because the type is the
--- generalizable part: a future kind of row -- a deprecated symbol's
--- own replacement, say -- belongs here too, once something extracts
--- it automatically (a doc comment's `@deprecated` tag, most likely)
--- rather than requiring a row by hand the way every row below still
--- does.
local record Catalog
  --- One row: the message `catalog_guidance` matches an uncaught
  --- error against (verbatim, or by shared words), the guidance
  --- already known for it, the synthetic module a `cosmic docs`
  --- lookup shows it under, and where it comes from.
  record Row
    module: string
    symbol: string
    message: string
    hint: string
    file: string
    line: integer
  end

  rows: {Row}
end

--- Hand-authored catalog rows, seeded ahead of the extracted ones, in
--- three groups:
---
--- The errno rows carry guidance for the handful of `strerror()`
--- messages cosmic's own syscalls can plausibly raise --
--- `core/fail.h`'s `cosmic_fail` returns `nil, strerror(errno), errno`,
--- and a stdlib wrapper like `cosmic/fs.tl`'s `path .. ": " .. trouble`
--- stitches that literal text straight into what a program sees, so
--- it is exactly as matchable as an authored message. Each needs its
--- `message` set to that raw text: `catalog_guidance` matches on
--- message alone, and `cosmic docs` finds these by symbol regardless.
---
--- The removed-global rows carry this module's only copy of
--- `core/surface.c`'s `replacements[]` hints, for `cosmic docs
--- os`/`io`/`debug` to answer proactively what today only shows up
--- reactively, the moment a script touches one of these names. Their
--- `message` is deliberately left empty: the hint IS the exact text
--- `core/surface.c` raises, so a `catalog_guidance` match would only
--- ever print the one line the script already got, twice. Leaving
--- `message` empty is not "no message", the general rule above --
--- `cosmic docs` still finds them, by symbol (`named_catalog`) or by
--- searching `text` (`searched_catalog`, `catalog_fts` indexing both
--- columns); only the reactive path needs `message` set, and these
--- rows opt out of it on purpose.
---
--- The convention rows carry cosmic's own vocabulary and file-layout
--- rules that no single function's doc comment states on its own,
--- because no single function IS the rule -- `Example` is a name
--- `build/positions.tl` compares literally, `cmd/<name>/main.tl` is a
--- path shape `build/embed.tl` matches, and so on. Fresh-agent eval
--- runs kept re-deriving these from other modules' already-written
--- examples rather than being told outright, and separately kept
--- naming these exact words (`tree`, `argv`, `cmd`, `main`, `Example`)
--- among what `cosmic docs` answered worst: nothing named them, so a
--- search fell through to whichever unrelated module's prose happened
--- to share the word, `cosmic.coverage`'s most often. An exact match
--- here answers the word directly and short-circuits that fallback
--- (`docs.lookup` never reaches `searched`/`searched_examples` once
--- `named`/`named_catalog` found something). `message` stays empty,
--- the same as the removed-global rows and for the same reason: none
--- of these name a real error `catalog_guidance` would ever be asked
--- to explain.
---
--- No group is generated; all three are small and rarely change, kept
--- in sync by hand with the source named in each row's own `file`.
Catalog.rows = {
  { module = "(errno)", symbol = "ENOENT",
    message = "No such file or directory",
    hint = "the path does not exist -- check it is spelled right, and " ..
           "that every parent directory already exists; cosmic.fs " ..
           "creates no parent directories on its own",
    file = "core/fail.h", line = 0 },
  { module = "(errno)", symbol = "EACCES",
    message = "Permission denied",
    hint = "the process does not have permission for this path -- " ..
           "check its ownership and mode, cosmic.fs.stat's own fields",
    file = "core/fail.h", line = 0 },
  { module = "(errno)", symbol = "EEXIST",
    message = "File exists",
    hint = "something is already at this path -- cosmic.fs.remove it " ..
           "first, or use a call that tolerates an existing target",
    file = "core/fail.h", line = 0 },
  { module = "(errno)", symbol = "ENOTDIR",
    message = "Not a directory",
    hint = "a path segment that should be a directory is a plain file " ..
           "instead -- check every component up to the last",
    file = "core/fail.h", line = 0 },
  { module = "(errno)", symbol = "EISDIR",
    message = "Is a directory",
    hint = "the path names a directory where a file was expected -- " ..
           "reading or writing needs a file path, not a directory",
    file = "core/fail.h", line = 0 },
  { module = "(errno)", symbol = "ENOSPC",
    message = "No space left on device",
    hint = "the filesystem holding this path is full",
    file = "core/fail.h", line = 0 },
  { module = "(errno)", symbol = "EMFILE",
    message = "Too many open files",
    hint = "this process already has too many files open -- close ones " ..
           "no longer needed before opening more",
    file = "core/fail.h", line = 0 },
  { module = "(removed)", symbol = "io", message = "",
    hint = "io is not available: files are cosmic.fs, and the " ..
           "standard streams are cosmic.fs.stdout, .stderr and .stdin",
    file = "core/surface.c", line = 21 },
  { module = "(removed)", symbol = "os", message = "",
    hint = "os is not available: time is cosmic.time, the " ..
           "environment is cosmic.env, and processes are cosmic.proc",
    file = "core/surface.c", line = 23 },
  { module = "(removed)", symbol = "debug", message = "",
    hint = "debug is not available: a traceback is cosmic.errors.trace",
    file = "core/surface.c", line = 25 },
  { module = "(removed)", symbol = "dofile", message = "",
    hint = "dofile is not available: a module comes from require, " ..
           "and a file's bytes come from cosmic.fs.read",
    file = "core/surface.c", line = 26 },
  { module = "(removed)", symbol = "loadfile", message = "",
    hint = "loadfile is not available: a module comes from require, " ..
           "and a file's bytes come from cosmic.fs.read",
    file = "core/surface.c", line = 28 },
  { module = "(convention)", symbol = "tree", message = "",
    hint = "the tree: a project's own working directory and everything " ..
           "under it, once a verb stages it. `cosmic <file.tl>` builds " ..
           "the tree the file sits in -- the working directory when the " ..
           "file is under it, the file's own directory otherwise; " ..
           "`cosmic test` and `cosmic build` always build the tree in " ..
           "the working directory",
    file = "cmd/cosmic/main.tl", line = 124 },
  { module = "(convention)", symbol = "argv", message = "",
    hint = "the file's own entry point -- what `require`ing it returns, " ..
           "when that is a function -- is called with one argument: an " ..
           "array of the arguments after the file's own path on the " ..
           "command line, indexed from 1 like any ordinary Lua array, " ..
           "so #argv and ipairs(argv) see exactly those. The file's own " ..
           "path is at argv[0] too, for a caller that wants it, but " ..
           "nothing ordinary reaches it: no length or loop starts before 1",
    file = "cmd/cosmic/main.tl", line = 166 },
  { module = "(convention)", symbol = "cmd", message = "",
    hint = "a binary is cmd/<name>/main.tl, its own directory under " ..
           "cmd/. `cosmic build` writes o/bin/<name> for each one a " ..
           "tree holds, requiring the file and calling what it returns " ..
           "-- see argv -- with the tree built the same way `cosmic " ..
           "test` builds it",
    file = "build/embed.tl", line = 127 },
  { module = "(convention)", symbol = "main", message = "",
    hint = "cmd/<name>/main.tl is a binary's own file: `cosmic build` " ..
           "writes o/bin/<name> from it -- see cmd -- and if what it " ..
           "returns is a function, that function is the entry point " ..
           "called with the command line -- see argv",
    file = "build/embed.tl", line = 127 },
  { module = "(convention)", symbol = "Example", message = "",
    hint = "a worked example: a `<name>_example.tl` file must return a " ..
           "record literally named `Example`, one field per example -- " ..
           "`function Example.<name>(): ... end`. `cosmic test` runs " ..
           "each one as a test; `cosmic docs <symbol>` shows the ones " ..
           "whose own code calls that symbol, matched by content, not " ..
           "by the example's own name",
    file = "build/positions.tl", line = 438 },
  { module = "(convention)", symbol = "test", message = "",
    hint = "a `<name>_test.tl` file's own top-level `local function " ..
           "test_*` functions -- direct elements of the file, never " ..
           "inside another statement -- are discovered and run by " ..
           "`cosmic test`. No return value and no registration; the " ..
           "name alone is the rule",
    file = "build/positions.tl", line = 928 },
  { module = "(convention)", symbol = "build", message = "",
    hint = "`cosmic build`: builds the tree in the working directory, " ..
           "then writes one executable under o/bin/ for each " ..
           "cmd/<name>/main.tl it holds -- o/bin/<name>, which runs " ..
           "on its own, with nothing beside it -- see cmd",
    file = "build/embed.tl", line = 365 },
  { module = "(convention)", symbol = "fix", message = "",
    hint = "`cosmic fix`: rewrites every Teal source in the working " ..
           "directory structurally, then writes it back out as " ..
           "canonical text, in place. `cosmic fix --check` does the " ..
           "same, writing nothing: names the files a fix would " ..
           "change, and fails if there are any",
    file = "build/fix/init.tl", line = 199 },
  { module = "(convention)", symbol = "db", message = "",
    hint = "`cosmic db`: what the two databases under o/ hold, table " ..
           "by table -- rows, pages, bytes -- and how the last few " ..
           "builds went",
    file = "build/databases.tl", line = 98 },
  { module = "(convention)", symbol = "docs", message = "",
    hint = "`cosmic docs <q>`: what the database says about q -- a " ..
           "symbol (Fs.read, read), a module (cosmic.fs), or words to " ..
           "search the documentation for",
    file = "build/docs.tl", line = 638 },
  { module = "(convention)", symbol = "uses", message = "",
    hint = "`cosmic uses <sym>`: every place that refers to a symbol, " ..
           "as file:line",
    file = "build/docs.tl", line = 676 },
  { module = "(convention)", symbol = "help", message = "",
    hint = "`cosmic help`: prints the whole discovery surface -- every " ..
           "verb, one line of prose each",
    file = "cmd/cosmic/main.tl", line = 289 },
}

return Catalog
