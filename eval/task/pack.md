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
except the `cosmic` binary and scratch files under `$TMPDIR`, which is
yours for anything temporary.

## What to build

A small project, `pack`, in Teal, using cosmic. It is a command-line
archive tool:

- `create <archive> <dir>`: writes every regular file under `<dir>`,
  recursively, into a new archive at `<archive>`, each entry named by
  the file's path relative to `<dir>` with `/` between parts (so
  `<dir>/sub/b.txt` is `sub/b.txt`). The format follows the archive's
  name: `.tar` is an uncompressed tar, `.tar.gz` or `.tgz` a
  gzip-compressed tar, `.zip` a zip. Any other name is an error.
- `list <archive>`: prints one line per file in the archive,
  `<size><TAB><path>`, sorted by path, where size is in bytes. It must
  work out the archive's format from its contents, not its name: a
  `.tar.gz` renamed to `data.bin` still lists.
- `sum <archive>`: like `list`, but each line is
  `<sha256><TAB><path>`, the SHA-256 of the file's contents in
  lowercase hex.
- `extract <archive> <dest>`: recreates the archive's files under
  `<dest>`, creating directories as needed. An entry whose path would
  land outside `<dest>` (an absolute path, or one climbing out with
  `..`) is an error: a message on stderr naming the entry, a non-zero
  exit code, and nothing written outside `<dest>`.
- `help`: prints usage naming every command above, to stdout, and
  exits 0. Run this one with no other arguments; it takes none.
- Any failure (a missing file, an archive that is not one) is a message
  on stderr and a non-zero exit code.
- Use cosmic's own archive, compression and hashing support rather than
  calling other programs.

The project must have all four of these:

1. **Tests** of the project's own code, which cosmic runs and passes.
   Show them passing.
2. **Examples**: worked examples of using the project's own code, in
   whatever form cosmic treats as an example, so that cosmic itself
   checks or runs them.
3. **Formatting**: every Teal source formatted the way cosmic itself
   formats Teal.
4. **A binary**: a single standalone executable named `pack`, produced
   by cosmic from this project, that runs the tool above on its own:
   copied alone into an empty directory and run with an empty
   environment (no `PATH`, no `HOME`, no `cosmic` anywhere), it still
   works. Show it running: `./pack create out.tar.gz somedir`, `./pack list out.tar.gz`.

How cosmic finds tests and examples, formats code, and produces a
binary is for you to find out from the binary.

## Deliverables, all in this directory

1. The project: source, tests, examples, and the produced `notes`
   executable, working as far as you can get them.
2. `JOURNAL.md`, described below.
