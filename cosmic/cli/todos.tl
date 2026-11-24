--- `cosmic todos [options] [path | words...]`: every `TODO:` comment
--- in the tree, as file:line, with the date and commit git blames its
--- first line on -- in a git repository only: elsewhere git is not
--- started, and each is listed with none -- indexed into its build.db so
--- only a file that moved is blamed again. A TODO is a comment on a line
--- of its own whose text opens with `TODO:`, and the lines that carry on
--- its paragraph: not one after code on its line. In Markdown a line
--- opening with `#`, `##` or `*` is read as such a comment, and a line of
--- prose or an HTML comment is none. A
--- comment that opens with a near miss (`TODO(tag):`, `FIXME:`, a `TODO`
--- with no colon) is not listed, and the summary counts those, naming
--- the spelling that is. An argument that names a path narrows it to that
--- path; the rest are words to search the TODOs' text for, best match
--- first, in FTS5's own syntax ("a phrase", OR, prefix*) when they
--- parse as that: `^perf` finds those whose text opens with `perf`, the tag
--- of a `TODO: perf: ...`, and `data:` searches for a word that also names
--- a path. Listing nothing is no failure, though a search that matches
--- none is (exit 1, as `cosmic help exit` says). The tree is found as
--- `test` finds it
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "every TODO, with its date and commit",
  usage = "[path | words...]",
  examples = {
    { line = "", about = "every TODO of the tree" },
    { line = "--oldest", about = "the oldest first" },
  },
  spec = {
    ["--oldest"] = { about = "list the oldest first, even when searching" },
  },
}

return command
