--- `cosmic -e '<chunk>' [args...]`: runs the chunk as the body of a Teal
--- file, against this binary's own standard library, with no tree
--- around it -- nothing staged or built, no build directory written,
--- and no staleness check. The chunk is checked as strictly as a file
--- run `--standalone` is (a warning is refused with an error, but an
--- unused name is let pass), and one
--- the checker refuses does not run: its messages are printed and it
--- exits 4, as a file that does not compile does. It reaches the
--- library as a file does, `require("cosmic.json")`, by a literal
--- name, and the tool's own
--- modules the same way; no module is bound for it, and it is Teal, not
--- Lua (`cosmic -e 'print(1 + "x")'` is refused). The words after the chunk are its `...`, each a
--- `string?`; it prints only what it prints. What it returns is the
--- exit code, as a built program's is: nothing is 0, a whole number
--- from 0 to 255, or text naming one, is itself, a table is printed as
--- JSON and exits 0, and anything else is complained about and exits 2. `cosmic eval '<chunk>' [args...]` is the
--- same.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "run a chunk of Teal, checked",
  usage = "'<chunk>' [args]",
  examples = {
    { line = "'print(1 + 2)'", about = "run a line of Teal" },
    { line = "'print(...)' a b", about = "give it words" },
    { line = "'return { n = 1 }'", about = "print what it returns as JSON" },
  },
}

return command
