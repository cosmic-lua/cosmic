--- What runs a file or a built binary: the shape neither `cosmic
--- <file.tl>`'s own `--help` line nor any single function's doc
--- comment states on its own, since no single function IS the rule --
--- `cmd/<name>/main.tl` is a path shape `build/embed.tl` matches, not
--- a symbol of its own. `cosmic docs <word>` finds each field below
--- directly, the same way it finds any other symbol.
local record Entrypoint
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
end

local entrypoint: Entrypoint = {
  tree = "tree", argv = "argv", cmd = "cmd", main = "main",
}

return entrypoint
