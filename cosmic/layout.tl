--- Where a project's files go so cosmic finds them. To write a test, add a
--- `<name>_test.tl` file: tests live in `<name>_test.tl`, examples in
--- `<name>_example.tl`, and modules are named by their path from the
--- project root. Each field below is one
--- convention. A field is named for the file it shapes (`tests`), not
--- for a verb: `cosmic docs test` is [`cosmic.cli`]'s, the verb.
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
  --- verdict line's "N ran, M stood" is [`test.Tally`]: ran counts
  --- tests actually executed this time, stood the ones answered from
  --- an unchanged prior verdict instead
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
  --- and a nested directory with no `init.tl` cannot be reached from
  --- outside at all. The build refuses a require that breaks this.
  --- `cosmic.*` is the standard library's, never a project's
  require: string
  --- a guide: a Markdown file directly under doc/guides/ (not in a
  --- directory below it) is a test of its own. Each block tagged `teal`
  --- or `lua` is an example that compiles, and runs when a block tagged
  --- `output` after it says what it prints; doc/guides/<name>.md is
  --- `cosmic docs doc.guides.<name>`
  guides: string
  --- a typed template: a `<name>.tmpl` file is a module the build makes
  --- of it ([`cosmic.template`]), imported by its path like a `.tl` file:
  --- `pages/home.tmpl` is `require("pages.home")` and `pages/init.tmpl` is
  --- `require("pages")`, each exporting `render`. Nothing generated is
  --- checked in, and a type error or a template error names the
  --- template's own line, as `pages/home.tmpl:12:`. A `.tmpl` and a `.tl`
  --- at one import path are refused like any two files. `cosmic fix` parses
  --- a template and never rewrites it
  templates: string
end

local layout: Layout = {
  Example = "Example", tests = "tests", require = "require", guides = "guides",
  templates = "templates",
}

return layout
