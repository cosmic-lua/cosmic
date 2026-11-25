--- `cosmic sandbox [options] [--] program [args...]`: runs a program, and
--- everything it starts, held to what the options grant and nothing more:
--- the paths it reads, runs, writes and creates, the system calls it makes,
--- the environment it sees and the resources it spends. What is not granted
--- does not work. When this host cannot enforce the whole policy, nothing
--- runs: the start fails and names what is missing.
---
--- The program is the first word that is not an option, or the word after
--- `--`. Every word after the program is its own argument, also a word
--- that looks like an option. The program is found on the PATH. The
--- start grants the program and its loader to run, and nothing else:
--- `--system` grants the libraries and files a host's programs read,
--- and `--programs` lets the program run the host's programs in turn (a
--- shell's commands).
---
---     cosmic sandbox --system --read . -- ls -l
---     cosmic sandbox --system --programs --read . --promise fork -- sh -c 'ls | wc -l'
---     cosmic sandbox --system --programs --path rwxc:. --tmp --promise fork \
---       --isolate file -- make
---
--- Each option is one field of the policy, and each number is a whole
--- number. `cosmic docs cosmic.sandbox` lists the policy's fields.
---
--- Paths:
---
--- - `--read`, `--run` and `--write` grant a path as `r`, `rx` and `rwc`.
---   `--path` gives the letters itself, from `rwxcu` in that order, each
---   once (`rwxc:.`).
--- - A path is relative to the working directory, and must exist. `--cwd`
---   names the working directory, as if you ran `cd` there first; without
---   it, the directory is this process's own.
--- - Paths and `--set-env` values must be UTF-8, because they are written
---   as JSON.
---
--- Running cosmic in a sandbox:
---
--- This program runs as its core directly, past its launcher, with no
--- grant of its file: it needs no shell, cache or promise to start, and
--- no `--system` unless what it runs needs one. When this
--- process is root, the program's user runs a copy of the core that every
--- user may run, made once in /run/cosmic-sandbox-cores.
---
---     cosmic sandbox --read . -- cosmic run.tl IN OUT
---
--- A file that it runs is run as `--standalone` (COSMIC_STANDALONE=1). So
--- a grant to read the file is enough, and no build directory is written
--- (another run's user would own it). The file may then require only
--- `cosmic.*` modules. `--set-env COSMIC_STANDALONE=0` builds the tree
--- around the file instead: that finds the tree's own modules, and needs a
--- grant to write the build directory.
---
--- A sealed database of modules:
---
--- `--database`, `--modules` and `--closure` run this program on a
--- database that holds the modules it may load and no others. A `require`
--- of any other module fails, and no part of this program's own file is
--- read or granted. The program is this program (`cosmic`) or nothing,
--- which is the same, and the words after it are the main's arguments.
---
--- - `--database PATH` runs a file that [`Store.seal`] wrote. Its main is
---   what runs.
--- - `--modules a,b,...` seals exactly the names given, from this
---   program's own store, and follows no requires. The first name is the
---   main: a module that returns a function, which gets the arguments and
---   returns the status. The other names are what the main may load.
--- - `--closure` runs a script, given as the program's first argument. It
---   compiles the script here, as a file run does, and seals it as the
---   main with the `cosmic.*` modules that it requires by a literal name,
---   and the modules that those require.
---
---     cosmic sandbox --closure -- cosmic run.tl IN OUT
---
--- For `--closure`, a `pcall(require, "<name>")` is followed as a
--- `require` is, so a name that no store holds is refused there too. A
--- name computed at run time is refused when the script is compiled. A
--- `require` of a module outside this program's store (a project module
--- beside the script) is refused before anything starts.
---
--- The three options exclude each other, because each one names the
--- database. `--system` fails the start when
--- this program is installed under a directory that `--system` grants.
--- The database is written in a directory of the run's own, which the
--- program's user can search, and is removed when the run ends. A command
--- line that these options refuse, a module that no store holds, or a
--- `--database` file that is not there exits 2. A script that cannot be
--- read or compiled exits 125, as a seal that cannot be written does.
---
--- The network:
---
--- `--connect HOST:PORT` grants a host and port, and may be repeated.
--- A relay that the start runs connects the program to it: on Linux, in the program's own
--- network; on macOS, on the host's loopback, behind a token drawn for the
--- run. The proxy variables (`HTTPS_PROXY`, `ALL_PROXY` and the others)
--- tell the program about the relay, and carry the token. So a program
--- that uses them reaches exactly the granted hosts, and the relay
--- resolves the names it grants, never the program. A program that ignores them
--- reaches nothing.
---
--- The relay writes one line to this process's standard error for each
--- connection that it allows or refuses. A refusal names the option that
--- would allow it (`not granted: --connect api.github.com:443`). When this
--- process's `https_proxy` is set, the relay connects through it, and says
--- so once, when it starts.
---
--- `cosmic sandbox connect HOST PORT`, with `connect` as the first word
--- after `sandbox`, is not a sandbox. It is the relay's client, for a
--- program that takes a command to reach a host through, such as ssh's
--- ProxyCommand. Inside a sandbox with `--connect`, it asks the relay
--- (`ALL_PROXY` must name the relay) for HOST and PORT, and copies its
--- standard input and output to the connection. When the relay refuses,
--- it exits 1 and says what the relay's reply means. ssh runs it as a
--- program of its own, so the sandbox also needs `--system` (for ssh, its
--- libraries and a shell for the ProxyCommand), `--promise fork`,
--- `--run` of this program's file, which the shell runs, and `--env PATH`
--- so that the shell finds `cosmic` (or the ProxyCommand gives its absolute path):
---
---     cosmic sandbox --system --run "$(command -v cosmic)" --env PATH --promise fork --read ~/.ssh \
---       --connect github.com:22 -- ssh -o ProxyCommand='cosmic sandbox connect %h %p' git@github.com
---
--- To run a program that is named `connect`, put it after `--`:
--- `cosmic sandbox -- connect`.
---
--- What holds it:
---
--- `--explain` prints the kernel layers the start would hold the program
--- to, read from the plan the start hands its spawn, and starts nothing
--- ([`Child.layers`]). A line each: the first Landlock ruleset's grants
--- with their letters (`landlock`), the start's own `rx` on the program or
--- this program's core among them; the ruleset a cosmic program's core
--- applies to itself at boot (`boot`), the policy alone; the system calls
--- allowed beyond the basics; whether execve is refused (no `x` in the last
--- ruleset); the socket families, the namespaces and root of its own, the
--- relay's hosts, the declared loopback addresses and the rlimits. It
--- checks the policy and the program as a start does, but not what a start
--- checks at the spawn itself (the descriptors handed over, the relay's
--- start, the kernel's support), so a start may still fail where it
--- answers. It exits 0, 2 for a command line or policy it refuses, and 125
--- for a start that would be refused, or on macOS, where a Seatbelt profile
--- holds the program.
---
---     cosmic sandbox --explain --system --read . -- ls -l
---
--- The user, the streams and the terminal:
---
--- `--user` gives the user and group that the program runs as, by number.
--- The group is the user's number unless you give one. Only a root caller
--- chooses a user, and gets the same one each run, instead of a fresh one
--- of its own for each run. Any other caller may name only itself.
---
--- The program's standard streams are this program's own. It gets no
--- other descriptor except those that `--fd` names. Each standard
--- stream that is a terminal is given to the program as a terminal of
--- its own, a pty (a pipe or a file is given as it is):
---
--- - What the program writes reaches the terminal as text and as the
---   sequences that draw a screen (colors, cursor movement, erasing, the
---   alternate screen). A title, clipboard or other control sequence does
---   not reach it.
--- - `cosmic sandbox` replies to its terminal queries itself.
--- - The window's size, SIGINT and SIGTERM are passed on.
--- - This terminal is put back as it was when the program ends.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "run a program held to what you grant it",
  usage = "[options] [--] <program> [args...]",
  examples = {
    { line = "--system --read . -- ls -l", about = "run ls, able to read this directory and what a host program needs" },
    { line = "--read . -- cosmic convert.tl", about = "run a script of yours the same way" },
  },
  spec = {
    ["--read"] = { value = "path", about = "grant a path to read (r)" },
    ["--run"] = { value = "path", about = "grant a path to read and run (rx)" },
    ["--write"] = { value = "path", about = "grant a path to read, write and create in (rwc)" },
    ["--path"] = { value = "letters:path", about = "grant a path the letters of rwxcu, in that order" },
    ["--system"] = { about = "the libraries and files a host's programs read" },
    ["--programs"] = { about = "run the host's programs from the program, as a shell does" },
    ["--database"] = { value = "path", about = "run this program on a sealed database: only its modules load",
      dash = "input" },
    ["--modules"] = { value = "a,b,...", about = "seal these modules (the first the main) and run on that" },
    ["--closure"] = { about = "seal a script and the modules it requires, and run it on that" },
    ["--isolate"] = { value = "file|proc", about = "a root of its own, or a process space of its own" },
    ["--promise"] = { value = "name", about = "a system call it may make: fork, jit, fattr or nest" },
    ["--connect"] = { value = "host:port", about = "a host it may reach, through a relay (Linux only)" },
    ["--loopback"] = { value = "addr", about = "an address of 127/8 it uses in its own network" },
    ["--env"] = { value = "name", about = "pass this variable through from the environment" },
    ["--set-env"] = { value = "name=value", about = "set this variable" },
    ["--tmp"] = { about = "a fresh temporary directory of its own, named by TMPDIR" },
    ["--open-files"] = { value = "n", about = "the most descriptors a process holds open" },
    ["--file-bytes"] = { value = "n", about = "the most bytes a process writes to one file" },
    ["--cpu-seconds"] = { value = "n", about = "the CPU seconds a process may spend" },
    ["--processes"] = { value = "n", about = "the most processes and threads of the whole sandbox" },
    ["--user"] = { value = "uid[:gid]", about = "run it as this user and group (a root caller's choice)" },
    ["--fd"] = { value = "n", about = "hand it descriptor n (3 to 255), as the same number" },
    ["--timeout"] = { value = "seconds", about = "end it after this many whole seconds" },
    ["--cwd"] = { value = "dir", about = "start it in this directory, which relative paths are taken from" },
    ["--explain"] = { about = "print the kernel layers the options give, and run nothing" },
  },
}

return command
