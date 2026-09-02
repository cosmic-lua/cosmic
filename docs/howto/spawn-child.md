# Spawn cosmic as a child

steps for running another cosmic script in a child process and reading
what it prints, for a reader who knows `cosmic.child`.

## run a script and read its output

1. find the running interpreter with `proc.interpreter()`. it is
   `arg[-1]` resolved. never use `arg[0]`: that is the script path, and
   inside an artifact it is `/zip/main.lua`, a zip member and not a
   file.
2. start the child with `child.start({exe, "worker.tl"})`. the first
   argv entry is the interpreter, the second is the script.
3. read its stdout with `h:read()`. `read` streams up to 65536 bytes per
   call and returns bare nil at end of file.
4. reap the child with `h:wait()`. `wait` returns the `Result` with the
   exit code, and collects stderr on the way.

```teal
local check = require("cosmic.check")
local child = require("cosmic.child")
local proc = require("cosmic.proc")

-- proc.interpreter() is arg[-1] resolved, never arg[0]
local exe = check.must(proc.interpreter())
local h = check.must(child.start({exe, "worker.tl"}))
local out = h:read()
print(out)
check.must(h:wait())
```

`child.run` is the one-shot form. it starts the child, waits, and hands
back the `Result` with stdout and stderr captured:

```teal example=cosmic/child/init_example.tl#Example_run
local check = require("cosmic.check")
local child = require("cosmic.child")
local r = check.must(child.run({"echo", "hello world"}))
io.write(r.stdout)
-- Output:
-- hello world
```

to redirect the child's stdout into a descriptor you own, pass a pipe's
write end as `opts.stdout`. close the write end in the parent before
reading, or the read blocks forever waiting for end of file:

```teal example=cosmic/child/init_example.tl#Example_run_pipe
local check = require("cosmic.check")
local child = require("cosmic.child")
local cfd = require("cosmic.fd")

-- Create a pipe: pp.reader and pp.writer are cosmic.fd Handles.
local pp = check.must(cfd.pipe())

-- Spawn echo, redirecting its stdout into the write end of the pipe.
local h = check.must(child.start({"echo", "from pipe"}, {stdout = pp.writer}))

-- Close the write end in the parent so the reader sees EOF when the child exits.
assert(pp.writer:close())

-- Read all output from the read end.
local out = pp.reader:read()
assert(pp.reader:close())

-- Wait for the child to exit.
local r = check.must(h:wait())

io.write(out)
print("exit:", r.code)
-- Output:
-- from pipe
-- exit:	0
```

## wait for a server child

a server child does not exit, so `wait` is the wrong signal. have the
child print a readiness line, and block on that line.

1. in the child, print `READY <port>` once the socket listens.
   `net.listen_tcp("127.0.0.1", 0)` picks a free port; read it from
   `srv:local_endpoint().port`.
2. in the parent, read the child's stdout until the line arrives. a
   `child.Handle` is a `stream.Reader`, so `stream.lines(h)` is the
   line reader.
3. do not sleep. a sleep is too short on a loaded machine and too long
   everywhere else. the line arrives exactly when the server is ready.

```teal
local check = require("cosmic.check")
local child = require("cosmic.child")
local proc = require("cosmic.proc")
local stream = require("cosmic.stream")

local exe = check.must(proc.interpreter())
local h = check.must(child.start({exe, "server.tl"}))
local next_line = stream.lines(h)
local ready, read_err = next_line()
assert(ready, "server exited before READY: " .. tostring(read_err))
local port = tonumber(ready:match("^READY (%d+)$"))
assert(port, "not a readiness line: " .. ready)
-- talk to 127.0.0.1:<port> here, then stop the server
assert(h:stop())
check.must(h:wait())
```

the server half of this pair is in `cosmic --docs howto.serve-http`. a
test spawns its project's own `o/bin/<name>` the same way: the test
sandbox grants exec and loopback TCP, and binaries are built before
tests run. `cosmic --docs howto.test` has the sandbox's rules.

## supervise many children

to run a queue of commands N at a time with a deadline, compose three
`Handle` methods. `start` launches into a free slot. `try_wait` reaps
whoever finished without blocking, and pumps the pipes so a chatty child
never stalls the loop. `stop` enforces the deadline. output left nil is
captured into each `Result`.

```teal example=cosmic/child/init_example.tl#Example_supervisor
local check = require("cosmic.check")
local child = require("cosmic.child")
local time = require("cosmic.time")

local commands = {
  {"echo", "first"},
  {"sh", "-c", "exit 3"},
  {"sleep", "10"}, -- overruns its deadline; the supervisor kills it
  {"echo", "last"},
}
local max_live = 2
local deadline_ms = 200

local statuses: {string} = {}
local live: {integer: child.Handle} = {}
local started_ms: {integer: integer} = {}
local live_count = 0
local next_command = 1
local done = 0

while done < #commands do
  -- Fill free slots while commands remain.
  while live_count < max_live and next_command <= #commands do
    live[next_command] = check.must(child.start(commands[next_command]))
    started_ms[next_command] = time.monotonic_ms()
    live_count = live_count + 1
    next_command = next_command + 1
  end
  for index, handle in pairs(live) do
    local tw = check.must(handle:try_wait())
    local finished = tw.result -- set exactly when tw.finished
    if not tw.finished and time.monotonic_ms() - started_ms[index] > deadline_ms then
      assert(handle:stop()) -- SIGTERM; wait() below reaps and reports the signal
      finished = check.must(handle:wait())
    end
    if finished is child.Result then
      local status = "fail"
      if finished.ok then
        status = "ok"
      elseif finished.signal then
        status = "timeout"
      end
      statuses[index] = status
      live[index] = nil
      live_count = live_count - 1
      done = done + 1
    end
  end
  assert(time.sleep_ms(5)) -- 5ms between polls: reap, don't spin
end

for index, status in ipairs(statuses) do
  print(index, status)
end
-- Output:
-- 1	ok
-- 2	fail
-- 3	timeout
-- 4	ok
```

`cosmic --docs cosmic.child` and `cosmic --docs cosmic.proc` have the
signatures.
