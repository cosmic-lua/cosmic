--- cosmic's own command-line verbs, one field per verb, so `cosmic
--- docs build` (or fix, db, docs, uses, help) answers with the same
--- text `cosmic help` already shows -- each verb is dispatched by
--- name in `cmd/cosmic/main.tl` rather than being a symbol of its
--- own, so nothing else would otherwise answer for the word.
local record Cli
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

local cli: Cli = {
  build = "build", fix = "fix", db = "db",
  docs = "docs", uses = "uses", help = "help",
}

return cli
