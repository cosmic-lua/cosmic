# Task

You have one tool you have never seen before: `cosmic`, a runtime for
command-line programs written in Teal (typed Lua). It is on your PATH.
The binary is the only source of information about it: there is no
documentation, repository, website, or package index for it, and you
must not use skills, plugins, web search, or any prior knowledge of a
project called "cosmic". Treat it as unknown. Anything the binary itself
tells you (help text, error messages, output of any command you can
think of running against it, or inspecting the file itself) is fair game.

Work only inside this directory. Do not read or write anything outside it
except the `cosmic` binary.

## What to build

A small project, `notes`, in Teal, using cosmic. It is a command-line
notes tool:

- `add <text...>`: stores a note made of the remaining arguments joined
  by spaces, and prints its id.
- `list`: prints every note, one per line, as `<id><TAB><text>`, oldest
  first.
- `rm <id>`: deletes one note. An unknown id is an error: a message on
  stderr and a non-zero exit code.
- `search <word>`: prints every note whose text contains `word`, in the
  same format as `list`.
- `help`: prints usage naming every command above, to stdout, and
  exits 0. Run this one with no other arguments; it takes none.
- Notes persist in a SQLite database file: the path in the `NOTES_DB`
  environment variable when it is set, otherwise `notes.db` in the
  current directory. Use cosmic's own SQLite support rather than
  implementing storage another way.

The project must have all three of these:

1. **Tests** that `cosmic test` discovers, runs, and passes.
2. **Examples**: worked examples of using the project's own code, in
   whatever form cosmic treats as an example, so that cosmic itself
   checks or runs them.
3. **A binary**: a single standalone executable named `notes`, produced
   by cosmic from this project, that runs the tool above on its own,
   with no `cosmic` on the PATH and no source files beside it. Show it
   running: `./notes add hello`, `./notes list`.

## Deliverables, all in this directory

1. The project: source, tests, examples, and the produced `notes`
   executable, working as far as you can get them.
2. `JOURNAL.md`, described below.
