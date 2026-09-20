--- cosmic's own command-line verbs, one field per verb, in the order
--- `cosmic help` prints them. `cosmic help` itself is generated from
--- these fields (`cmd/cosmic/main.tl`'s `verb_help`) rather than
--- keeping a second, hand-written copy of the same wording -- each
--- verb is dispatched by name in `cmd/cosmic/main.tl` rather than
--- being a symbol of its own, so nothing else would otherwise answer
--- for the word either, and `cosmic docs build` (or fix, db, docs,
--- uses, help, run, test) finds it here directly.
local record Cli
  --- `cosmic <file.tl>`: builds the tree the file sits in -- the
  --- working directory when the file is under it, so a file of a
  --- project reaches the rest of it; the file's own directory
  --- otherwise -- then runs it: requires the file, and if what it
  --- returns is a function, calls it with one argument -- see argv --
  --- and exits with the integer it returns, or 0
  run: string
  --- `cosmic test`: builds the tree in the working directory, then
  --- runs every test it defines -- see test, Example -- which
  --- `cosmic docs` also shows under every symbol an example calls
  test: string
  --- `cosmic fix`: rewrites every Teal source in the working
  --- directory structurally, then writes it back out as canonical
  --- text, in place. `cosmic fix --check` does the same, writing
  --- nothing: names the files a fix would change, and fails if there
  --- are any
  fix: string
  --- `cosmic build`: builds the tree in the working directory, then
  --- writes one executable under o/bin/ for each cmd/<name>/main.tl
  --- it holds -- o/bin/<name>, which runs on its own, with nothing
  --- beside it -- see cmd
  build: string
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

local record Module
  fields: Cli
  --- The order `verb_help` prints these in, matching `cosmic help`'s
  --- own historical layout -- record field declaration order is not
  --- itself queryable at runtime, so this is spelled out once more.
  order: {string}
end

local module: Module = {
  fields = {
    run = "run", test = "test", fix = "fix", build = "build",
    db = "db", docs = "docs", uses = "uses", help = "help",
  },
  order = { "run", "test", "fix", "build", "db", "docs", "uses", "help" },
}

return module
