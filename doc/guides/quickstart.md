# quickstart

<!-- needs: processes = true, tool = true -->

cosmic is one executable: the Lua runtime, the Teal compiler, and a
standard library, `cosmic.*`, for the everyday things a script needs.
This guide uses several of those modules and shows what they do.

## hashing bytes

`cosmic.hash` turns a string into its SHA-256 digest, as 64 lowercase
hex characters.

```teal
local Hash = require("cosmic.hash")

print(Hash.hex_sha256("cosmic"))
```

```output
01307b41e7ff0bb31cca03fb7ff5bea9fdb3dd83afaca63d588a0c07e7ae98b8
```

## reading a file back

`cosmic.fs` reads and writes files. This example is two pieces: a
companion file, `notes.txt`, and the entry code that reads it.

```teal file=notes.txt
hello from notes.txt
```

```teal
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")

local content, trouble = Fs.read(tmp .. "/notes.txt")
if content == nil then
  error(trouble)
end
print(content)
print(Hash.hex_sha256(content))
```

```output
hello from notes.txt
568a78ac9be8ab08ce84c90363cef53bab5d6aecf684e83cd44193dbad50cca6
```

## below cosmic.fs

`cosmic.fs` is built on `cosmic.sys`, the syscall table: one C function
per call, the same on Linux and on macOS. A call no module wraps, such
as `lstat`, is there. A failure returns nil, the error, and the errno.
`cosmic docs cosmic.sys` lists every call.

```teal
local syscalls = require("cosmic.sys")

assert(syscalls.mkdir(tmp .. "/made"))
local stat = assert(syscalls.lstat(tmp .. "/made"))
print(stat.kind)
```

```output
dir
```

## running another cosmic program

`cosmic.child` starts an executable from an exact path; it does not search
`PATH`. Its result reports how the process ended. Output is inherited unless
you redirect it to a caller-owned file descriptor, as this example does.

```teal file=greeter.tl
return function(argv: {string}): integer
  print("hello, " .. argv[1])
  return 0
end
```

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

local output = tmp .. "/child-output"
local fd = assert(Fs.open_write(output))
-- This very cosmic, started past its launcher as `cosmic test` starts
-- a worker: the core it runs on, with what the launcher would hand it.
-- `{ Proc.executable(), ... }` starts it through the launcher instead,
-- which takes a shell.
local relaunch = assert(Proc.relaunch())
local argv = { table.unpack(relaunch.argv) }
argv[#argv + 1] = tmp .. "/greeter.tl"
argv[#argv + 1] = "cosmic"
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
local result, trouble = Child.run(argv,
  { env = env, fds = relaunch.fds, stdout = fd, timeout_ms = 5000 })
assert(Fs.close(fd))
if result == nil then error(trouble) end
local finished = assert(result)
assert(finished.ok and finished.code == 0)

local content = assert(Fs.read(output))
print(content:sub(1, -2))
print("exit " .. tostring(finished.code))
```

```output
hello, cosmic
exit 0
```

`Child.start` hands back a running child instead, and `Child.wait_any`
waits for the first of several to finish. When its timeout passes first it
answers `nil` and `""`: nothing finished, and nothing failed. A reason other
than `""` is a failure to report, never a message to read for its meaning.
The child's own `wait` then waits for it to finish, and answers how it
ended.

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")

-- This cosmic again, past its launcher, running a chunk that sleeps
-- for half a second and exits 3.
local relaunch = assert(Proc.relaunch())
local argv = { table.unpack(relaunch.argv) }
argv[#argv + 1] = "-e"
argv[#argv + 1] = "require('cosmic.time').sleep_ns(500000000) return 3"
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
local sleeper <close> = assert(Child.start(argv, { env = env, fds = relaunch.fds }))
local done, trouble = Child.wait_any({ sleeper }, 10)
if done == nil and trouble ~= "" then error(trouble) end
print(done == nil and "still running" or "finished")
local ended = assert(sleeper:wait())
print("exit " .. tostring(ended.code))
```

```output
still running
exit 3
```

## ending early

A program's entry returns its exit status. Where returning is awkward,
`Proc.exit` ends the process at once with a status: it runs no finalizers
and never returns. This example declares no output, so it compiles and does
not run: running it would end the test that runs this guide.

```teal
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

local config, trouble = Fs.read(tmp .. "/app.conf")
if config == nil then
  local _, _ = Fs.put(Fs.stderr, trouble .. "\n")
  Proc.exit(2)
end
```

## a number that starts at zero

Teal infers `integer` for `local peak = 0`, so a later `peak = peak + 1.5`
(or `peak = peak / 2`) is refused with `got number, expected integer`, and the
compiler's message names the fix. Write `local peak = 0.0`, or annotate
`local peak: number = 0`, for a variable that holds floats. A function declared
`: number` may still `return 0`: an integer is a number.
