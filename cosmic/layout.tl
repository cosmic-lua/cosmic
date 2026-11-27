--- Where a project's files go so cosmic finds them. To write a test, add a
--- `<name>_test.tl` file: tests live in `<name>_test.tl`, examples in
--- `<name>_example.tl`, and modules are named by their path from the
--- project root. Each field below is one
--- convention. A field is named for the file it shapes (`tests`), not
--- for a verb: `cosmic help test` is [`cosmic.cli.test`]'s, the verb.
local record Layout
  --- a worked example: a `<name>_example.tl` file must return a
  --- record literally named `Example`, one field per example --
  --- `function Example.<name>(): ... end`. `<module>_example.tl`
  --- documents `<module>`; `<module>_<topic>_example.tl` does too,
  --- pairing with the longest module its name starts with followed by
  --- `_`, so one module's examples can be split by topic across files
  --- (`json_yaml_example.tl` beside `json_example.tl`). `cosmic test`
  --- runs each one as a test; `cosmic docs <symbol>` shows the ones
  --- whose own code calls that symbol, matched by content, not by the
  --- example's own name
  Example: string
  --- a `<name>_test.tl` file's own top-level `local function test_*`
  --- functions -- direct elements of the file, never inside another
  --- statement -- are discovered and run by `cosmic test`. No return
  --- value and no registration; the name alone is the rule. Its
  --- summary's "N ran, M stood" is [`test.Tally`]: ran counts
  --- tests actually executed this time, stood the ones settled from
  --- an unchanged prior verdict instead. An edit to the test file, a
  --- comment included, runs its tests again; a comment in a module it
  --- imports runs them again only where the test is given that module's
  --- text: doc/testing.md ("the pure store") names every case. Its
  --- top-level `local function bench_*(b: Bench.B)` functions are benches
  --- ([`cosmic.bench`]): `cosmic test` calls each once as a test, and
  --- `cosmic test --bench` times them
  tests: string
  --- a project's own module is named by its path from the project's
  --- root, the working directory: `notes.tl` is `require("notes")`,
  --- `store/db.tl` is `require("store.db")`, and `store/init.tl` is
  --- `require("store")`. No registration and no search path; tests,
  --- examples and cmd/<name>/main.tl require them the same way.
  --- Where a file sits decides who may require it. A file at the root,
  --- or in a top-level directory with no `init.tl` (`store/db.tl`
  --- beside no `store/init.tl`), is public. Any other directory is
  --- closed: from outside it only its own `init.tl` may be required
  --- (`store/sql/init.tl` is `require("store.sql")`, while
  --- `store/sql/query.tl` is for files inside `store/sql/` alone), a
  --- top-level directory that has an `init.tl` is closed the same way,
  --- and a nested directory with no `init.tl` has no entry at all.
  --- A module of a closed directory that holds the line `--- @public`
  --- in the comment that opens it is open to every module; the docs
  --- leave the line out. A module under an `internal/` directory
  --- (`app/internal/db.tl`) may be required only from under that
  --- directory's parent (`app/`), as in Go, in the closed rule's
  --- place, and `--- @public` does not open it. The build refuses a
  --- require that breaks this, and `cosmic docs` marks such a module
  --- in its list, "(private to store/sql/)" or "(internal to app/)".
  --- Split a module that grows into such a package rather than into
  --- flat files of one prefix: doc/guides/project.md ("a package")
  --- shows one. `cosmic.*` is the standard library's, never a project's,
  --- and its closed directories keep their own as a project's do: require
  --- the modules `cosmic docs` lists
  require: string
  --- a guide: a Markdown file directly under doc/guides/, or directly
  --- under doc/guides/internal/, is a test of its own. Each block tagged `teal`
  --- or `lua` is an example that compiles, and runs when a block tagged
  --- `output` after it says what it prints; doc/guides/<name>.md is
  --- `cosmic docs doc.guides.<name>`, and a program built from the
  --- project carries it for its users. One under doc/guides/internal/ is
  --- for those working on the project: `cosmic docs` covers it there,
  --- and no program carries it. A program's own guide,
  --- `cmd/<name>/doc/guides/<guide>.md`, is a test too, and that program
  --- alone carries it, as the guide `<guide>` in place of the project's of
  --- that name. A guide's name holds no dot
  guides: string
  --- a typed template: a `<name>.tmpl` file is a module the build makes
  --- of it ([`cosmic.template`]), imported by its path like a `.tl` file:
  --- `pages/home.tmpl` is `require("pages.home")` and `pages/init.tmpl` is
  --- `require("pages")`, each exporting `render`. Nothing generated is
  --- checked in, and a type error or a template error carries the
  --- template's own line, as `pages/home.tmpl:12:` (its column is the
  --- generated code's). A `.tmpl` and a `.tl`
  --- at one import path are refused like any two files. `cosmic fix` parses
  --- a template and never rewrites it
  templates: string
  --- a static asset: any file under the top-level `static/` directory is
  --- carried verbatim in every executable of the project and served by
  --- [`cosmic.web.static`]. `static/css/app.css` is the asset `css/app.css`.
  --- A file under a program's own `cmd/<name>/static/` is that program's
  --- alone: `cmd/spam/static/css/app.css` is the asset `css/app.css` of
  --- `spam`, which it carries in place of `static/css/app.css`, and no other
  --- program carries it. Run from its source (`cosmic cmd/spam/main.tl`), a
  --- program serves the same files from disk, its own laid over the shared. Such a `static/` directory is never a module
  --- namespace: a `.tl` or `.tmpl` under it is an asset, not a module, so it
  --- is not compiled, tested or required. There is no configuration: a mount's URL is named in the
  --- router, not in the file layout. The build refuses a file past 16 MiB,
  --- a name holding a control byte or any of `\ % ? #`, a path past 255
  --- bytes, two names that differ only in case, and a link that leaves the
  --- project
  static: string
end

local layout: Layout = {
  Example = "Example", tests = "tests", require = "require", guides = "guides",
  templates = "templates", static = "static",
}

return layout
