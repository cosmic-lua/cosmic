--- Fake programs, for a test that needs an outside program to start:
--- a fake `git`, `zig` or `cosmic`, a process to leave running, a child
--- to sandbox. A fake runs a module of the tree, its main, with no
--- system shell. It is a host program of the running core, laid out as
--- `cosmic build --host` lays one out ([`Store.host_program`]): a static
--- executable of the core and a small database, which the kernel runs
--- directly and which reads only itself. A caller that starts it with no
--- environment and no descriptors of its own starts it all the same,
--- where a shell script would need /bin/sh, and a program run from
--- source would need its launcher.
---
--- The main is a module of the test's import closure -- the test
--- requires it -- that returns a `function(argv: {string}): integer`, as
--- a module `cosmic build` makes a program of does. `build` makes the
--- fake and `place` copies it where a test needs one, with text the copy
--- reads by [`Fake.given`]:
---
---     -- my.git_fake is a module whose main prints Fake.given() and returns 0
---     local Fake = require("cosmic.fake")
---     local _ = require("my.git_fake")
---     local program = assert(Fake.build(tmp .. "/fake", "my.git_fake"))
---     assert(Fake.place(program, tmp .. "/bin/git", "abc1234"))
---     local ran = assert(Child.run({ tmp .. "/bin/git", "rev-parse", "HEAD" },
---       { stdout = "capture" }))
---     print(ran.stdout) -- abc1234
---
--- A fake that only answers its first argument needs no module of its
--- own: [`Fake.reply`] places the reply fake, [`Fake.REPLY`], with a
--- table of answers. A main that does more is made of the steps of
--- [`cosmic.fake.steps`]: read a file, write one, start a child, test a
--- descriptor.
---
--- `build` takes a few milliseconds past reading the core. A test that
--- builds one declares nothing for it in its [`Test.policy`]: the build
--- starts nothing and reads only the running core and the modules the
--- fake carries, which are of the test's import closure. It writes
--- `dir`, and a scratch directory of [`Store.seal`]'s under `TMPDIR`,
--- which `cosmic test` points at the test's own directory.

local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
-- Required, not only named, so the reply fake's main ([`Fake.reply`])
-- and what it requires are of the import closure of every module that
-- requires this one, whose store then holds the rows `build` seals.
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

--- What the fake carries beside its main's closure: what the core
--- requires of any program it runs (see the requires above).
local core_requires <const>: {string} = { "cosmic.errors" }

--- Builds a fake of `main` under `dir`, made if it is not there, and
--- returns the path of the executable, `dir/` and `main`'s name, so one
--- `dir` holds a fake of each. `main` names a module this process holds
--- -- one its test requires, so it is of the test's import closure --
--- and the fake runs it as a program, as `cosmic build` would make one
--- of it: the module returns a `function(argv: {string}): integer`,
--- given the arguments past the program's name and returning the exit
--- status. Nil and a Failure where
--- `dir` cannot be made or written, `main` is not of the test's closure,
--- or this process has no artifact of its own to take its core from. A
--- `main` that returns no function is not refused here: the fake it
--- makes says so when it starts, and ends with a failing status.
function Fake.build(dir: string, main: string): (string) | (nil, Failure)
  local made, trouble = Fs.mkdirs(dir)
  if not made then return nil, trouble end
  local roots: mut {string} = { main }
  for _, name in ipairs(core_requires) do roots[#roots + 1] = name end
  local found, names = pcall(Store.closure, roots)
  if not found then
    local why = tostring(names)
    if why:find(main, 1, true) ~= nil then
      why = why .. ": require " .. main .. " from the test (a value require, not `local type`), " ..
        "so the test's closure carries it"
    end
    return nil, Failure.new("building the fake: " .. why)
  end
  local database = dir .. "/" .. main .. ".db"
  local sealed, seal_trouble = Store.seal(names, database, { main = main, data = false })
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
  local out = dir .. "/" .. main
  local written, write_trouble = Fs.write(out, program, 0x1ed)
  if not written then return nil, write_trouble end
  return out
end

--- Copies the fake `program` ([`Fake.build`]'s path) to `path`,
--- executable -- a copy, not a symbolic link, since it finds what it was
--- given beside the path it resolves itself to -- and writes `text`, when
--- one is given, to `path .. ".do"`, for its main to read by
--- [`Fake.given`]. With no `text` it removes a `.do` an earlier place
--- left there. False and a
--- Failure where either cannot be read or written.
-- TODO: make a hard link to `program` where one can be made (the same
-- file system), falling back to this copy, once cosmic.sys carries
-- link: a checked core's program is 39.5 MB, about 0.2 s a copy.
function Fake.place(program: string, path: string, text?: string): (true) | (nil, Failure)
  local bytes, trouble = Fs.read(program)
  if bytes == nil then return nil, trouble end
  local written, write_trouble = Fs.write(path, bytes, 0x1ed)
  if not written then return nil, write_trouble end
  if text ~= nil then
    local wrote, written_why = Fs.write(path .. ".do", text)
    if not wrote then return nil, written_why end
  else
    local _, _ = Fs.remove(path .. ".do")
  end
  return true
end

--- Places a copy of the reply fake `program` (built with
--- [`Fake.REPLY`] as its main) at `path`, answering its first argument
--- with `replies[that argument]`: the key "" stands for no argument at
--- all, and "*" for any key `replies` lacks. One with no reply for its
--- argument says so on stderr and ends with status 127, as one whose
--- code is outside 0 to 255 does. The replies travel as JSON, so their
--- text must be UTF-8. False and a Failure where a reply's text is not
--- UTF-8 or the copy cannot be written.
---
---     local program = assert(Fake.build(tmp .. "/fake", Fake.REPLY))
---     assert(Fake.reply(program, tmp .. "/bin/git", {
---       ["rev-parse"] = { stdout = "abc1234\n" },
---       ["*"] = { stderr = "git: not faked\n", code = 1 },
---     }))
function Fake.reply(program: string, path: string, replies: {string: Fake.Reply}): (true) | (nil, Failure)
  local text, trouble = Json.encode_any(replies)
  if text == nil then return nil, trouble end
  return Fake.place(program, path, text)
end

--- What [`Fake.place`] wrote beside the copy now running, for a fake
--- to read: its words, a number, a reply to give.
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
