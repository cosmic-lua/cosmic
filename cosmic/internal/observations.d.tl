--- What core/store.c's `open_observations` hands only
--- `build.filesystem_observations` when it loads from the binary's own
--- tree: the raw tables whose calls it stands in for or drains.

local type process = require("cosmic.internal.process")
local type sqlite = require("cosmic.internal.sqlite")
local type sys = require("cosmic.sys")

local record observations
  --- What one call of `cosmic.sys` was asked and answered, as the
  --- syscall table's dispatch logged it while `observe` had it on.
  record Call is {any}
    --- The call's name: "getcwd", "executable", "lstat", "readlink" or
    --- "realpath".
    call: string
    --- The path a call that takes one was given, absolute -- a relative
    --- one after the working directory it was made in -- or as given
    --- when that could not be told. Nil for one that takes none, or
    --- given no string.
    path: string | nil
    --- How many values it answered, each at its index from 1.
    n: integer
    --- True when one of its answers held what no record can, and is
    --- nil here or left out of its table.
    partial: boolean | nil
  end

  --- The syscall table's log of what its queries answered, and those
  --- calls themselves, past the log.
  record Syscalls
    --- Turns on or off logging, whoever calls them, what `getcwd`,
    --- `executable`, `lstat`, `readlink` and `realpath` of `cosmic.sys`
    --- are asked and answer. A call whose record cannot be kept fails
    --- as memory does, having changed nothing. What is logged stays
    --- until `observed` drains it.
    observe: function(on: boolean)
    --- Every call logged since the last drain, in the order made, but
    --- one the same as the one before it. Forgets them.
    observed: function(): {Call}
    getcwd: function(): string | nil, string, integer
    executable: function(): string | nil, string, integer
    lstat: function(path: string): sys.Stat | nil, string, integer
    readlink: function(path: string): string | nil, string, integer
    realpath: function(path: string): string | nil, string, integer
  end

  --- The process table, whose `spawn` it stands in for to note each
  --- child a test starts.
  process: process
  --- SQLite's table, whose record of the files SQLite opens it drains.
  sqlite: sqlite
  --- The syscall table's log of what its queries answered, which it
  --- drains, and those calls, which log nothing, for its own questions.
  syscalls: Syscalls
end

return observations
