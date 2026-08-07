--- Shared record types for cosmic.child: the Result a finished child
--- reports, try_wait's TryWait answer, and the start/run Options.
--- Same pattern as cosmic.fs.types — records here, methods in init —
--- so child/init.tl stays under the 500-line cap. cosmic.child
--- re-exports each of these as `child.Result`/`child.TryWait`/
--- `child.Options`; require this module directly only from inside
--- cosmic.child.
local cfd = require("cosmic.fd")
local childio = require("cosmic.child.io")

--- Exactly one of `code`/`signal` is set: `code` when the child
--- exited, `signal` when a signal ended it. `ok` is true only on zero.
--- A Result exists only for a child that RAN — a start that failed is
--- run's `nil, string`, not a Result (was the `spawn_error` field).
local record Result
  code: integer -- exit status; nil if signaled
  signal: integer -- terminating signal; nil if exited
  ok: boolean -- code == 0, and no io_error
  stdout: string
  stderr: string
  io_error: string -- a read/write/poll failure while pumping I/O; nil if none
end

--- try_wait's answer, one record instead of a nil-shaped tuple:
--- result is set exactly when finished is true.
local record TryWait
  finished: boolean
  result: Result
end

--- Options for starting a process.
--- Leave stdout/stderr nil (the default) and the output is captured for
--- you: wait/run drain the child and return the bytes in Result.stdout
--- and Result.stderr. Set these fields only to send a stream somewhere
--- else. stdout/stderr Handles (cosmic.fd) become the child's fd 1/2
--- (the matching Result field is then ""); start does not take
--- ownership — the child gets its own copy, so close your end when done
--- (see Example_run_pipe). Raw integer fds are not part of this surface
--- (api-review-2); wrap one with fd.wrap() first. "inherit" writes to
--- THIS process's fd 1/2 so output streams as it runs; Result stays "".
local record Options
  stdin: string | cfd.Handle -- string piped to stdin, or Handle -> fd 0
  stdout: cfd.Handle | childio.StdioMode -- child's fd 1, or "inherit"
  stderr: cfd.Handle | childio.StdioMode -- child's fd 2, or "inherit"
  --- the child's exact environment as "KEY=VALUE" entries (nil
  --- inherits); build edited copies with env.list({drop=..., set=...})
  env: {string}
  cwd: string
end

local record ChildTypes
  type Result = Result
  type TryWait = TryWait
  type Options = Options
end

local M: ChildTypes = {}

return M
