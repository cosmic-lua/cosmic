--- `cosmic uses <sym> [path...]`: every place that refers to a
--- symbol, as file:line -- only those under the paths, when given --
--- each link to it, in a comment or a Markdown file, marked `link`.
--- A place is a read or a call of a member, through its module, an
--- alias of it, or a value the checker gave its type; one through `any`,
--- a union or a value whose type failed is not seen. A member a record
--- takes from an interface is a use of the interface's, and of the
--- record's own too where the record declares it again. The code the
--- build writes for a call ([`Shape.record_of`]) reads at the call's
--- line. An assignment to a member and a key of a table literal are not
--- places.
--- The symbol may be a file's path instead (doc/writing.md, or
--- doc/writing.md#heading for one heading), which only links name. It
--- builds the tree first, as `docs` does, and its summary says where it
--- reads the last build instead. The
--- tree is found as `test` finds it
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "every place that refers to a symbol",
  usage = "<symbol> [path...]",
  examples = {
    { line = "Fs.read", about = "every place that refers to Fs.read" },
  },
}

return command
