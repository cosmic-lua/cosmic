--- `cosmic compile [--errors] [--root dir] [-o dir] file.tl...`: the Lua
--- source of each `.tl` file, one text per file, written by this binary's
--- own new checker for the tree's Lua, as it writes the tree's own modules. It reads the files named and the
--- `cosmic.*` modules the binary carries, never the tree around them, so
--- any release runs it in any directory. One file's Lua goes to standard
--- output; several need `-o dir`, which gets `<name>.lua` for each (two
--- files of one name are refused: compile them in two runs). A file is
--- checked as the module its path below `--root` (the working directory)
--- names, [`lang/flow.tl`] as [`lang.flow`], and a `require` of
--- another named file gets its text; a path outside the
--- root is refused. A `.d.tl` file is skipped with a note, and types a
--- `require` of it. The Lua is raw: no wrapper, nothing joining files.
--- A type error is reported and the Lua is written anyway: standard
--- error gets a count per file, and with `--errors` each error as
--- `file:line:column: message`. Only a syntax error refuses: each is
--- named as `file:line:column: message`, no file is written, and the
--- exit is 4.
--- With a `.d.tl` file named, the files named are the whole program, the
--- globals are those the `.d.tl` files declare, and a `cosmic.*` module
--- no file named is the module of is typed `invalid` and reported. With
--- none named, each file is checked as `cosmic --standalone` checks it:
--- the binary's own globals and `cosmic.*` modules, and what a standalone
--- run refuses besides type errors, its warnings and the project
--- refusals (`package`, `_G`); all are listed and
--- counted as type errors, and none stops the Lua. After a
--- non-zero exit do not use the `-o` directory: it may hold files of an
--- earlier run. It prints no summary; exits 0 when the Lua is written,
--- 2 for a command line it refuses, 4 for a syntax error or a `.d.tl`
--- whose text a build refuses, and 5 for a file it cannot read or write.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "Teal to Lua, even with type errors",
  usage = "[options] <file.tl>...",
  examples = {
    { line = "file.tl", about = "print the Lua a Teal file compiles to" },
    { line = "-o out a.tl b.tl", about = "write out/a.lua and out/b.lua" },
  },
  spec = {
    ["-o"] = { value = "dir", about = "write <name>.lua for each file in this directory" },
    ["--errors"] = { about = "list each type error, warning and refusal, not only the count" },
    ["--root"] = { value = "dir", about = "the directory module names are relative to (default: here)" },
  },
}

return command
