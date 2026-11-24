--- `cosmic build [options] [path...]`: builds the tree in the working
--- directory, then writes one executable for each cmd/<name>/main.tl
--- that the tree holds, or only for those under the paths (see cmd). The
--- tree is found as `test` finds it.
---
--- Where it writes:
---
--- - Each executable is bin/<name> in the build directory. Its path
---   prints on a line of its own on standard output.
--- - The build directory is `$XDG_CACHE_HOME/cosmic/trees/<key>` (or
---   `~/.cache/cosmic/trees/<key>`). `<key>` is the SHA-256 of the
---   project root's canonical path.
--- - `COSMIC_BUILD_HOME=/absolute/path` puts the `<key>` directories
---   there instead.
---
--- The executable:
---
--- - That one file is the whole program. Copied alone to a host with no
---   cosmic, it runs with an empty environment (`env -i ./name`) on
---   every supported system.
--- - It is a /bin/sh launcher with a core for each system, and the
---   program appended. The launcher calls uname, stat and the like from
---   the PATH (the shell's default when none is set).
--- - A host's first run copies its core into a private cache:
---   `$COSMIC_PORTABLE_CACHE`, else `$XDG_CACHE_HOME/cosmic/cores`, else
---   the home directory's cache, else `$TMPDIR` or /tmp, under
---   cosmic-cores-<uid>.
--- - The launcher `exec`s the core once ready, so the process you start
---   is the program's own and signals reach it directly.
--- - `--host` writes this cosmic's own core and the program alone, which
---   the kernel runs directly, with no shell, PATH or cache. It runs only
---   on this system and processor. Use it for a container with no
---   /bin/sh, or a host with nowhere to write. It writes the same
---   bin/<name>, and replaces a launcher build of it (and the other way
---   round).
---
--- Certificates and time zones:
---
--- - Each executable carries every CA root that this cosmic does. Its
---   requests trust the minimal roots ([`Http.default_roots`]), unless
---   `--roots mozilla` makes them trust every root. COSMIC_CA_ROOTS
---   picks the roots in the same way when the program runs.
--- - Both kinds of executable carry this binary's CA roots, the
---   certificates it refuses as revoked, and time zones. To get newer
---   ones later, `cosmic refresh --binary <path> -o <copy>` writes a
---   copy.
---
--- In cosmic's own tree, the program is the tool itself, which
--- `bin/zig build boot` builds. There, `build` rebuilds a stale tool and
--- prints the tool's path. `--out` writes a copy to dir/cosmic, which
--- runs any project as a release does, with the cores that boot built.
--- It takes no other option and no path.
---
--- Failures:
---
--- - A file that does not compile (a test among them) holds back only
---   the programs that need it. The other programs are written, the old
---   executable of each program held back is removed, and the exit
---   status is 4.
--- - An import cycle, a `global` in a declaration file, or a source that
---   cannot be read stops the whole tree, and nothing is written.
--- - A failure to write exits 1, and the refusal is still named.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "write an executable per cmd/<name>/main.tl",
  usage = "[path...]",
  examples = {
    { line = "", about = "write an executable per program" },
    { line = "--host cmd/tally", about = "write one program, native to this system" },
  },
  spec = {
    ["--host"] = { about = "this system's native executable: no launcher, runs only here" },
    ["--out"] = { value = "dir", about = "also write each executable to dir/<name>, made if missing; a program " ..
        "not built leaves none there or in bin/" },
    ["--roots"] = { value = "set", about = "the CA roots its requests trust by default: minimal (the default) " ..
        "or mozilla; every root goes along either way" },
  },
}

return command
