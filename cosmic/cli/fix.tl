--- `cosmic fix [options] [path...]`: lays out every Teal source in the
--- working directory as canonical text, in place. Run it after editing,
--- instead of formatting by hand. The tree is found as `test` finds it.
---
--- What it does:
---
--- - It rewrites each Teal file from its parsed tree, then checks that a
---   second rendering would change nothing further. It refuses a file
---   that fails this check.
--- - It builds the tree, and fails where the build refuses it, with the
---   compiler's reasons.
--- - It puts parentheses around each `assert(...)` that the type checker
---   says passes on more values than its place can take.
---   `(assert(...))` keeps only the first value.
--- - It fails a link in a comment or a Markdown file (`` [`x`] ``,
---   `[text](target)` or `[text][label]`) that names nothing, or more
---   than one thing.
--- - It makes a link of a plain `` `x` `` that names one top-level
---   declaration of its own file, one file, or, written in full
---   (`module.member`), one symbol. In Markdown it also writes, at the
---   file's end, the definitions GitHub needs to show the link.
---
--- Links and their definitions are all that it writes to a Markdown or
--- Zig file: it never reflows or re-indents one. `--check` is the dry
--- run: it writes nothing and reports what a run would change.
---
--- What it reads:
---
--- - A path that the tree's own .gitignore files ignore, and anything
---   under a `node_modules/`, is not checked, rewritten or linked to. The
---   user's global excludes do not count. Where git cannot say (no git,
---   no repository), only `node_modules/` is left alone.
--- - A Teal file that the build does not read (under `bin/` or a hidden
---   directory, or outside the tree), named or under a named directory,
---   is type-checked alone, as `cosmic --standalone` checks a file.
---   cosmic's own tree is an exception.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "format source files and check the tree",
  usage = "[path...]",
  examples = {
    { line = "tally.tl", about = "lay out a file and check the tree" },
    { line = "--check .", about = "change nothing; fail if a fix would change anything" },
  },
  spec = {
    ["--check"] = { about = "write nothing; name what a fix would change, and fail if any (a Teal file that is " ..
        "not laid out, or that the formatter refuses, fails it)" },
    ["--changed"] = { about = "in cosmic's own tree, lay out only the paths named, which " ..
        "changed since the whole tree passed; what spans files still covers it all" },
  },
}

return command
