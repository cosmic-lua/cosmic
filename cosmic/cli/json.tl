--- `cosmic json [options] [path] [file|-]`: settles a quick question about
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
--- - `--exists` prints nothing, and tells only by its exit status: 0
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
--- is found. It exits 2 for a command line or a path it cannot read, and
--- 5 for a file that is missing or not JSON, or a write that failed.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
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
}

return command
