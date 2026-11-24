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
--- - The error for a missing column or table names the ones there are.
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
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "read-only SQL on a database or data files",
  usage = "[options] ['<statement>']",
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
}

return command
