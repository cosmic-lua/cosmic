--- `cosmic help [verb | exit]`: with no word, the guides to start
--- from, an index of every verb, one line each, and where to read
--- more. `cosmic help <verb>`
--- prints that verb's usage, summary, options, examples and full text. `cosmic help
--- exit` prints the exit codes and summary every verb shares.
--- `cosmic <verb> --help` is `cosmic help <verb>`
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "this index, or a verb's full text",
  usage = "[verb]",
  examples = {
    { line = "", about = "the index of verbs" },
    { line = "json", about = "one verb's full text" },
  },
}

return command
