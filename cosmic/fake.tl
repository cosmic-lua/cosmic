--- Fake programs, for a test that needs an outside program to start:
--- a fake `git`, `zig` or `cosmic`, a process to leave running, a child
--- to sandbox. A fake runs a small script of commands (below) with
--- no system shell. It is a host program of the running core, laid out
--- as `cosmic build --host` lays one out ([`Store.host_program`]): a
--- static executable of the core and a small database, which the kernel
--- runs directly and which reads only itself. A caller that starts it
--- with no environment and no descriptors of its own starts it all the
--- same, where a shell script would need /bin/sh, and a program run from
--- source would need its launcher.
---
---     local Fake = require("cosmic.fake")
---     local program = assert(Fake.build(tmp .. "/fake"))
---     assert(Fake.place(program, tmp .. "/bin/git", "print abc1234"))
---     local ran = assert(Child.run({ tmp .. "/bin/git", "rev-parse", "HEAD" },
---       { stdout = "capture" }))
---     print(ran.stdout) -- abc1234
---
--- A fake can run a module of the tree in place of a script: the test
--- requires it, so it is of the test's import closure, and builds with
--- its name. Each copy reads what `place` gave it with [`Fake.given`].
---
---     -- my.git_fake is a module whose main prints Fake.given() and returns 0
---     local _ = require("my.git_fake")
---     local program = assert(Fake.build(tmp .. "/fake", "my.git_fake"))
---     assert(Fake.place(program, tmp .. "/bin/git", "abc1234"))
---
--- The command language below is going away: new fakes use a module.
---
--- `build` makes one, in a few milliseconds past reading the core, and
--- `place` copies it where a test needs one, with the script it runs
--- or the text its main reads. A
--- test that builds one declares nothing for it in its [`Test.policy`]:
--- the build starts nothing and reads only the running core and the
--- modules the fake carries, which are of every test's import
--- closure that requires this module. It writes `dir`, and a scratch
--- directory of [`Store.seal`]'s under `TMPDIR`, which `cosmic test`
--- points at the test's own directory.
---
--- Its main, the probe, is a module of the binary's own, so it loads
--- trusted as the core loads any `cosmic.*` module: it reaches no raw
--- binding its wrappers do not, since it is none of them.
---
--- The script is `<its path>.do` when that exists. Failing that, it is
--- the body of the file its first argument names, past its first line,
--- where that is a regular file whose first line starts `#!`: a file
--- starting `#!<fake>` and nothing more runs its body, as a shell
--- script does, on every system, however one splits the words after
--- `#!`. Failing both, it is the first argument itself. Its arguments
--- are the rest: every one for a `.do` script, and those after the
--- first otherwise. Commands are split on `;` and newlines, each a verb
--- and its words:
---
---     print T          T and a newline, to stdout
---     eprint T         T and a newline, to stderr
---     write F T        T and a newline, as the whole of file F
---     write-pid F      its own pid and a newline, as the whole of file F
---                      (`signal S @F` then names it)
---     append F T       T and a newline, at the end of file F
---     cat [F]          file F, or stdin to its end, to stdout
---     cat-quiet F      file F to stdout, or nothing where it cannot be read
---     ls D             the names in directory D, sorted, a line each
---     exit N           ends with status N
---     signal S [P]     sends SIGS (TERM, INT, KILL, HUP) to itself, and
---                      waits to end of it -- two seconds at most, after
---                      which it says so and ends with status 4; or to
---                      pid P, negated for a process group, as kill(2)
---                      takes it, or `@F` for the one file F holds, and
---                      goes on. 0 and -1, which name no one process or
---                      group, fail
---     trap N           holds SIGINT and SIGTERM (`Signal.guard`) and ends
---                      with status N once one arrives: checked between
---                      commands and while it sleeps or waits; `trap -`
---                      holds them and goes on, as a shell's `trap ''`
---                      does -- though, caught rather than ignored, not
---                      for a program it starts
---     sleep MS         sleeps MS milliseconds
---     sleep-forever    sleeps until it is ended
---     wait-for F       waits until file F exists
---     exists P N       ends with status N if P exists
---     copy A B         file A's bytes as the whole of file B
---     cwd [F]          its working directory and a newline, to stdout or F
---     mkfifo P         makes a named pipe at P
---     mkdirs D         makes directory D and its parents
---     grep-count F T   how many lines of file F hold T, to stdout
---     status-field K   its line of /proc/self/status that names K
---     run P [T]        starts P, with T its one argument, and waits for
---                      it, as a shell runs one: what P leaves running
---                      runs on, and none of it is adopted here; ends
---                      with P's status where it fails (128 past a
---                      signal), and 127 where P cannot start
---     start-count N P [T]
---                      starts P, with T its one argument, up to N times,
---                      going on as `start` does, and says `started K`,
---                      and ` then` why when one failed to, a line to
---                      stdout
---     start P [T]      starts P, with T its one argument, and goes on
---                      without waiting for it, as a shell's `P &` does:
---                      it outlives the script, which then ends by
---                      `sys.exit`, past what would end it
---     fd-closed N      ends with status 1 unless descriptor N is
---                      closed, and 2 when N names no descriptor
---     sockets-open     `sockets` and how many descriptors from 3 up are
---                      sockets, a line to stdout
---     write-fd N T     T and a newline, to descriptor N
---     env-of NAME      `NAME=` and the variable's value, or `NAME unset`,
---                      and a newline, to stdout: unlike `$NAME`, it
---                      tells an empty variable from an unset one
---     rlimit R         `R soft hard` and a newline, to stdout, for R one of
---                      nofile, fsize, cpu, core, nproc: a limit of none is
---                      math.maxinteger
---     setrlimit R N    sets limit R (as `rlimit` names it) to N, soft and
---                      hard, and says `set`, or fails with why
---     getpgid P        says `pgid` and the process group of process P
---                      (0 for itself), or fails with why
---     present P        fails unless P exists, as `test -e` does
---     connect P        connects to the unix socket file P, waiting five
---                      seconds at most, saying `connected` or why not,
---                      a line to stdout
---     connect-tcp H P  connects to port P of numeric host H, as
---                      `connect` does
---     bind-tcp H P     listens on port P of numeric host H and closes it,
---                      saying `bound` or why not, a line to stdout
---     loopback-tcp H   listens on a port of numeric host H, connects to
---                      it and accepts the connection, saying `connected`
---                      or why not, a line to stdout
---     loopback-unix P  listens on a unix socket file P, connects to it
---                      and accepts the connection, saying `connected`
---                      or why not, a line to stdout; the file is left
---     start-isolated P starts program P under a policy of `isolate`
---                      file, granting P alone, and says `started` or the
---                      start's failure, a line to stdout
---     run-isolated P T runs program P, with T its one argument, under a
---                      policy of `isolate` file granting P alone and the
---                      working directory read-only, waits for it, and
---                      says `exit` and its status, then what it printed
---                      to stdout and stderr, or the start's failure, to
---                      stdout
---     run-looped P T   as `run-isolated`, with a network namespace of its own
---                      and a loopback in it (the policy's `loopback`)
---     writable P       fails unless file P opens to write, appending
---                      and writing nothing, as `: >> P` does, but never
---                      making it
---     mode P           P's permission bits in octal and a newline, to
---                      stdout, as `stat -c %a` prints them
---     create F T       T and a newline, as the whole of the new file F,
---                      made as `open` with O_EXCL makes one: where F is
---                      there already, or F cannot be made, it fails
---     truncate F       empties file F in place, as `: > F` does, but
---                      never makes it
---     truncate-unwritten F
---                      empties file F by an open that writes nothing
---                      (O_RDONLY with O_TRUNC), which a ruleset below
---                      Landlock ABI 3 asks no write right of
---     rm F             removes file F
---     rmdir D          removes the empty directory D
---     rename A B       moves A to B, as `mv A B` does
---     flip A B         swaps A and B, two paths, over and over until it is
---                      ended, so each is at the other's name half the
---                      time and absent for an instant between
---     chmod P M        sets P's permission bits to M, in octal, as
---                      `chmod M P` does
---     find-writable D  each regular file beneath D that opens to write,
---                      as `writable` opens one, a line each: a link is
---                      neither listed nor walked into, as `find D -type
---                      f` walks, and a file is listed only where it
---                      leads to one too, as `test -f` takes it; a
---                      directory it cannot list is passed over
---
--- A verb, its first word and the rest are split at the blanks between
--- them, however many, which go; the rest keeps its own spacing. In a
--- command's words, `$@` is its arguments joined by spaces, `$DIR` the
--- directory it sits in, and `$NAME` the environment variable NAME, empty
--- when unset, each put in once: what is put in is not read for a `$`
--- again. A command written `[w] ...` runs only when its first
--- argument is `w`. A command that fails says why on stderr and ends
--- with status 1; an unknown verb ends with 2. The script's end is
--- status 0.
---
--- Commands chain as a shell's do, left to right, at an `&&` or `||`
--- standing between blanks: `A && B` runs B only where A went on, and
--- `A || B` runs B only where A would have ended the script -- failed,
--- or exited -- and goes on as B does. What a failure a `||` takes up
--- would have said is not said. A chain that ends the script ends it
--- with the status of the last command run.

local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
-- Required, not only named, so the probe and what it requires are of the
-- import closure of every module that requires this one, whose store
-- then holds the rows `build` seals; loading it defines its verbs and
-- nothing more.
local _ = require("cosmic.internal.fake_probe")
-- The same for the reply fake's main ([`Fake.reply`]).
local _ = require("cosmic.internal.fake_reply")
local Json = require("cosmic.json")
-- What the core itself requires of the program it runs, beside its main
-- module: [`cosmic.errors`], for an uncaught error's guidance (core/main.c's
-- `ask_guidance`). Required so it is of the closure too.
local type _ = require("cosmic.errors")

local record Fake
  --- One answer of a reply fake ([`Fake.reply`]): what it writes to
  --- stdout and to stderr, as they are, and the status it ends with (0
  --- when nil).
  record Reply
    --- Written to stdout as it is.
    stdout?: string
    --- Written to stderr as it is.
    stderr?: string
    --- The exit status; 0 when nil.
    code?: integer
  end

  --- The `main` of [`Fake.build`] for a reply fake: build one fake of
  --- it, then give each copy its replies with [`Fake.reply`].
  REPLY: string
end

Fake.REPLY = "cosmic.internal.fake_reply"

--- The fake's program, its main module, which it carries with the
--- modules it requires: the whole of what it runs.
local probe_module <const> = "cosmic.internal.fake_probe"

--- What the fake carries beside `probe_module`'s closure: what the
--- core requires of any program it runs (see the requires above).
local core_requires <const>: {string} = { "cosmic.errors" }

--- Builds a fake under `dir`, made if it is not there, and returns
--- the path of the executable: `dir/probe`, or `dir/` and `main`'s
--- name with a `main`, so one `dir` holds a fake of each. With no
--- `main`, it runs its
--- first argument as its script, with the rest its arguments, or the
--- script `place` wrote beside a copy of it. With `main`, the name of a
--- module this process holds -- one its test requires, so it is of the
--- test's import closure -- it runs that module as a program, as
--- `cosmic build` would make one of it: the module returns a
--- `function(argv: {string}): integer`, given the arguments past the
--- program's name and returning the exit status. Nil and a Failure where
--- `dir` cannot be made or written, `main` is not of the test's closure,
--- or this process has no artifact of its own to take its core from. A
--- `main` that returns no function is not refused here: the fake it
--- makes says so when it starts, and ends with a failing status.
function Fake.build(dir: string, main?: string): (string) | (nil, Failure)
  local made, trouble = Fs.mkdirs(dir)
  if not made then return nil, trouble end
  local runs = main or probe_module
  local roots: mut {string} = { runs }
  for _, name in ipairs(core_requires) do roots[#roots + 1] = name end
  local found, names = pcall(Store.closure, roots)
  if not found then
    local why = tostring(names)
    if main ~= nil and why:find(main, 1, true) ~= nil then
      why = why .. ": require " .. main .. " from the test (a value require, not `local type`), " ..
        "so the test's closure carries it"
    end
    return nil, Failure.new("building the fake: " .. why)
  end
  local name = if main ~= nil then main else "probe" end
  local database = dir .. "/" .. name .. ".db"
  local sealed, seal_trouble = Store.seal(names, database, { main = runs, data = false })
  if sealed == nil then
    return nil, Failure.new("building the fake: " .. tostring(seal_trouble))
  end
  local bytes, read_trouble = Fs.read(database)
  local _, _ = Fs.remove(database)
  if bytes == nil then
    return nil, Failure.new("building the fake: " .. tostring(read_trouble))
  end
  local program, program_trouble = Store.host_program(bytes)
  if program == nil then
    return nil, Failure.new("building the fake: " .. tostring(program_trouble))
  end
  local out = dir .. "/" .. name
  local written, write_trouble = Fs.write(out, program, 0x1ed)
  if not written then return nil, write_trouble end
  return out
end

--- Copies the fake `program` ([`Fake.build`]'s path) to `path`,
--- executable -- a copy, not a symbolic link, since it finds its script
--- beside the path it resolves itself to -- and writes `script`, when one
--- is given, to `path .. ".do"`, for it to run -- or, for a fake built
--- with a `main`, for that main to read by [`Fake.given`]. With no
--- `script` it removes a `.do` an earlier place left there. False and a
--- Failure where either cannot be read or written.
-- TODO: make a hard link to `program` where one can be made (the same
-- file system), falling back to this copy, once cosmic.sys carries
-- link: a checked core's program is 39.5 MB, about 0.2 s a copy.
function Fake.place(program: string, path: string, script?: string): (true) | (false, Failure)
  local bytes, trouble = Fs.read(program)
  if bytes == nil then return false, trouble end
  local written, write_trouble = Fs.write(path, bytes, 0x1ed)
  if not written then return false, write_trouble end
  if script ~= nil then
    local wrote, written_why = Fs.write(path .. ".do", script)
    if not wrote then return false, written_why end
  else
    local _, _ = Fs.remove(path .. ".do")
  end
  return true
end

--- Places a copy of the reply fake `program` (built with
--- [`Fake.REPLY`] as its main) at `path`, answering its first argument
--- with `replies[that argument]`: the key "" stands for no argument, and
--- "*" for any key `replies` lacks. One with no reply for its argument
--- says so on stderr and ends with status 127. False and a Failure where
--- the copy cannot be written.
---
---     local program = assert(Fake.build(tmp .. "/fake", Fake.REPLY))
---     assert(Fake.reply(program, tmp .. "/bin/git", {
---       ["rev-parse"] = { stdout = "abc1234\n" },
---       ["*"] = { stderr = "git: not faked\n", code = 1 },
---     }))
function Fake.reply(program: string, path: string, replies: {string: Fake.Reply}): (true) | (false, Failure)
  local text, trouble = Json.encode_any(replies)
  if text == nil then return false, trouble end
  return Fake.place(program, path, text)
end

--- What [`Fake.place`] wrote beside the copy now running, for a fake
--- built with a `main` to read: its words, a number, a reply to give.
--- It reads the `.do` file beside this process's own executable, so it
--- is nil where `place` wrote nothing for the copy, and for a program
--- that was never placed (its `.do`, if any, is no one's).
function Fake.given(): string?
  local self, _ = Proc.executable()
  if self == nil then return nil end
  local text, _ = Fs.read(self .. ".do")
  return text
end

return Fake
