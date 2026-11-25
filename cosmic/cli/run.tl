--- `cosmic <file.tl> [args...]`: builds the file's tree into the tree's
--- build directory, then runs the file. The tree is the working directory when
--- the file is under it, so a file of a project reaches the rest of the
--- project. Otherwise the tree is the file's own directory. `cosmic run
--- <file.tl> [args...]` is the same, and `cosmic run --standalone
--- [--check] <file.tl> [args...]` is `cosmic --standalone`. `cosmic -`
--- and `cosmic run -` run the Teal standard input holds, as `cosmic -e`
--- runs a chunk.
---
--- Running the file requires it. If it returns a function, cosmic calls
--- that function with the words after the file's path (`argv[1]` on; its
--- own path is `argv[0]`), and exits with the status the function
--- returns:
---
--- - nothing: 0;
--- - a whole number from 0 to 255, or text that holds one: that number;
--- - anything else: an error, and exit 2.
---
--- The file's top level finds the same words in the global `arg`. Its
--- `...` is what `require` gives a module: its own name. Every word after
--- the file is the file's, "--" too: no option of cosmic comes after the
--- file. [`Flags.parse`] from `argv[1]` reads "--" as the end of the
--- options, so `cosmic f.tl -- --help` gives the file the word "--help"
--- and no option.
---
---     return function(argv: {string}): integer
---       print("from " .. argv[1] .. " to " .. argv[2])
---       return 0
---     end
---
--- A file that requires only `cosmic.*` modules, each by a literal
--- name, needs no tree, and runs as `cosmic --standalone` runs it: no
--- tree is built and nothing is written but the compile cache. A
--- program's `cmd/<name>/main.tl`, a `_test.tl` and a file of cosmic's
--- own checkout build the tree whatever they require, and
--- COSMIC_STANDALONE=0 makes any file build it.
---
--- A file of the tree that does not parse or type-check stops the run
--- only when the file requires it, itself or through another module. A
--- broken file that it does not require is left out with a warning that
--- names it and why, and the file runs. A check of the whole tree (a
--- global, a cycle of imports) stops every run. `cosmic test` and
--- `cosmic fix` build the whole tree, and refuse a broken file anywhere.
---
--- A tree's build directory is outside the tree, and belongs to this
--- user: `$XDG_CACHE_HOME/cosmic/trees/<key>` (`~/.cache/cosmic/trees/<key>`),
--- where `<key>` is the SHA-256 of the tree's canonical path. When
--- COSMIC_BUILD_HOME is set, it replaces that base: the build directory
--- is `$COSMIC_BUILD_HOME/<key>`, and a path that is not absolute is an
--- error. So a tree that this user cannot write, such as another
--- user's checkout, builds as any other does.
---
--- With COSMIC_STANDALONE=1, cosmic runs the file as `--standalone`
--- does: it builds nothing and writes no build directory. A program that
--- `cosmic sandbox --cosmic` runs has COSMIC_STANDALONE=1 unless
--- `--set-env` says otherwise.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "build the tree around a file and run it",
  usage = "<file.tl|-> [args]",
  examples = {
    { line = "hello.tl", about = "build the tree around hello.tl and run it" },
    { line = "cmd/tally/main.tl words.txt", about = "run a program from its source, with its words" },
  },
}

return command
