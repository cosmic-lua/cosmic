--- cosmic's own vocabulary: a word or a verb with no single function's
--- doc comment to answer for it, because no single function IS the
--- rule -- `Example` is a name `build/positions.tl` compares
--- literally, `cmd/<name>/main.tl` is a path shape `build/embed.tl`
--- matches, and a verb like `build`/`fix` is dispatched by name in
--- `cmd/cosmic/main.tl` rather than being a symbol of its own.
--- `cosmic docs <word>` finds each field below directly, the same way
--- it finds any other symbol.
local record Glossary
  --- the tree: a project's own working directory and everything
  --- under it, once a verb stages it. `cosmic <file.tl>` builds the
  --- tree the file sits in -- the working directory when the file is
  --- under it, the file's own directory otherwise; `cosmic test` and
  --- `cosmic build` always build the tree in the working directory
  tree: string
  --- the file's own entry point -- what `require`ing it returns, when
  --- that is a function -- is called with one argument: an array of
  --- the arguments after the file's own path on the command line,
  --- indexed from 1 like any ordinary Lua array, so #argv and
  --- ipairs(argv) see exactly those. The file's own path is at
  --- argv[0] too, for a caller that wants it, but nothing ordinary
  --- reaches it: no length or loop starts before 1
  argv: string
  --- a binary is cmd/<name>/main.tl, its own directory under cmd/.
  --- `cosmic build` writes o/bin/<name> for each one a tree holds,
  --- requiring the file and calling what it returns -- see argv --
  --- with the tree built the same way `cosmic test` builds it
  cmd: string
  --- cmd/<name>/main.tl is a binary's own file: `cosmic build` writes
  --- o/bin/<name> from it -- see cmd -- and if what it returns is a
  --- function, that function is the entry point called with the
  --- command line -- see argv
  main: string
  --- a worked example: a `<name>_example.tl` file must return a
  --- record literally named `Example`, one field per example --
  --- `function Example.<name>(): ... end`. `cosmic test` runs each
  --- one as a test; `cosmic docs <symbol>` shows the ones whose own
  --- code calls that symbol, matched by content, not by the
  --- example's own name
  Example: string
  --- a `<name>_test.tl` file's own top-level `local function test_*`
  --- functions -- direct elements of the file, never inside another
  --- statement -- are discovered and run by `cosmic test`. No return
  --- value and no registration; the name alone is the rule
  test: string
  --- `cosmic build`: builds the tree in the working directory, then
  --- writes one executable under o/bin/ for each cmd/<name>/main.tl
  --- it holds -- o/bin/<name>, which runs on its own, with nothing
  --- beside it -- see cmd
  build: string
  --- `cosmic fix`: rewrites every Teal source in the working
  --- directory structurally, then writes it back out as canonical
  --- text, in place. `cosmic fix --check` does the same, writing
  --- nothing: names the files a fix would change, and fails if there
  --- are any
  fix: string
  --- `cosmic db`: what the two databases under o/ hold, table by
  --- table -- rows, pages, bytes -- and how the last few builds went
  db: string
  --- `cosmic docs <q>`: what the database says about q -- a symbol
  --- (Fs.read, read), a module (cosmic.fs), or words to search the
  --- documentation for
  docs: string
  --- `cosmic uses <sym>`: every place that refers to a symbol, as
  --- file:line
  uses: string
  --- `cosmic help`: prints the whole discovery surface -- every verb,
  --- one line of prose each
  help: string
end

local glossary: Glossary = {
  tree = "tree", argv = "argv", cmd = "cmd", main = "main",
  Example = "Example", test = "test", build = "build", fix = "fix",
  db = "db", docs = "docs", uses = "uses", help = "help",
}

return glossary
