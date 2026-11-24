--- `cosmic docs [q...]`: prints what the database says about q. The
--- tree is found as `test` finds it.
---
--- What it looks up:
---
--- - A symbol ([`Fs.read`], `read`).
--- - A module ([`cosmic.fs`], or `fs` for its last name). A module page
---   lists the signature of each function the module offers, ahead of
---   the rest of its prose.
--- - Words to search the documentation for. The first five matches are
---   shown whole, and the rest one a line.
--- - Several qualified names (`Fs.read Fs.write`) are each looked up in
---   turn. Other words are searched for together.
--- - A word that no documentation holds is searched again as the
---   nearest word that one does, as a misspelling of it. The page says
---   which word it searched.
--- - With no q, it lists every module there is, with what it is for.
---   With `cosmic`, it lists the standard library's modules.
---
--- JSON output:
---
--- - `--json` prints one JSON object a line for each entry found, every
---   entry and not only the first five. The keys are query, exact,
---   module, symbol, kind, signature and text, and file, line, verb and
---   respelled where the entry has them.
--- - With no q, or with `cosmic`, it prints each module that the page
---   lists.
--- - It prints no summary on standard error, except the one that a
---   stale result gets (see "Which tree it reads").
--- - To filter the objects, compose with `cosmic sql`, as `cosmic json`
---   does: `cosmic docs --json Fs.read Fs.write | cosmic sql --from
---   docs=- --as ndjson "SELECT symbol, line FROM docs WHERE kind =
---   'function'"`.
---
--- What a doc is:
---
--- - A doc is the run of comment lines directly above a declaration, a
---   record's field or an enum's value. It is the `---` lines where
---   there are any, else the `--` lines, less TODO lines and the build's
---   `--- @` tags.
--- - A trailing comment and a comment inside a table constructor are
---   not docs. A table's entries are documented by the record that types
---   the table.
--- - A function declared as a field of the record that a module
---   returns, and defined as `function Record.f`, shows the field's doc,
---   unless the definition has a `---` doc of its own. Its place is the
---   definition.
---
--- Which tree it reads:
---
--- - Where the build directory holds a working database or a
---   projection, it builds the tree first, as `test` does but with no
---   test run, so it prints the docs of the tree as it stands. Any run
---   that builds or stages there makes them, `todos` and `lsp` among
---   them.
--- - Where the build directory holds neither, it builds nothing and
---   prints cosmic's own docs. It says that the directory has not been
---   built.
--- - Where the tree does not build, or the build is left alone (another
---   run holds it, or the working database is another tool's), it
---   prints the docs of the last build. The summary says so and why, and
---   each `--json` object has `"stale": true`.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
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
}

return command
