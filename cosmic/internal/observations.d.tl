--- What core/store.c's `open_observations` hands only
--- `build.filesystem_observations` when it loads from the binary's own
--- tree: the raw tables whose calls it stands in for or drains.

local type process = require("cosmic.internal.process")
local type sqlite = require("cosmic.internal.sqlite")
local type sys = require("cosmic.sys")

local record observations
  --- What one observed call was asked and answered, as the binding
  --- logged it while `observe` had it on (core/observed.h).
  record Call is {any}
    --- The call's name: "getcwd", "executable", "lstat", "readlink",
    --- "realpath", "open", "stat", "readdir", "getenv", "environ",
    --- "mkdir" or "mkdtemp" of `cosmic.sys`; "spawn", the process
    --- table's own, called past the stand-in for it; or "http",
    --- cosmic.http's `open` of a request that is not scripted.
    call: string
    --- What a call that takes one was given: a path absolute -- a
    --- relative one after the working directory it was made in -- or
    --- as given when that could not be told; the variable `getenv`
    --- asked for, the program `spawn` started, the URL `http` asked
    --- for, as given; for `mkdtemp`, the directory it made. Nil for one
    --- that takes none, or given no string.
    path: string | nil
    --- What an absolute path an open, a stat, a listing, a realpath, an
    --- lstat or a readlink was given resolved to as the call was made
    --- (see `resolve`), "" where it resolved to nothing, where
    --- `resolving` asked for it; nil otherwise.
    resolved: string | nil
    --- How many values it answered, each at its index from 1: none of
    --- a call noted before it acted, or that made a directory.
    n: integer
    --- True when one of its answers held what no record can, and is
    --- nil here or left out of its table.
    partial: boolean | nil
  end

  --- The syscall table's log of what its calls were asked and
  --- answered, and those calls themselves, past the log.
  record Syscalls
    --- Turns on or off logging, whoever calls them, what the observed
    --- calls (see `Call`) are asked and answer. A query whose record
    --- cannot be kept fails as memory does, having changed nothing; a
    --- call that acts fails so before it acts, or takes back the
    --- directory it made. What is logged stays until `observed` drains
    --- it.
    observe: function(on: boolean)
    --- Says which paths a record resolves as its call is made, from here
    --- on: nil none, and a directory every absolute one outside it or
    --- climbing with "..", which for "" is every one.
    resolving: function(tree: string | nil)
    --- Every call logged since the last drain, in the order made, but
    --- one the same as the one before it. Forgets them.
    observed: function(): {Call}
    --- What an absolute path resolves to now, links and all: realpath
    --- of it, or, when it is not there, of its nearest existing
    --- ancestor with the missing names after it as written. Given
    --- `link`, only as far as its last name, as lstat and readlink
    --- read it -- unless that name is "." or "..", or the path ends in
    --- "/". "" for a relative path, or one that resolves to nothing.
    resolve: function(path: string, link?: boolean): string
    getcwd: function(): string | nil, string, integer
    executable: function(): string | nil, string, integer
    lstat: function(path: string): sys.Stat | nil, string, integer
    readlink: function(path: string): string | nil, string, integer
    realpath: function(path: string): string | nil, string, integer
    stat: function(path: string): sys.Stat | nil, string, integer
    readdir: function(path: string): {string:string} | nil, string, integer
    getenv: function(name: string): string | nil
    environ: function(): {string:string}
    spawn: function(path: string, argv: {string}, environment?: {string:string},
                    cwd?: string, stdin?: integer, stdout?: integer, stderr?: integer,
                    process_group?: boolean, fds?: {integer:integer},
                    sandbox?: process.Sandbox): integer | nil, string, integer
  end

  --- The process table, whose `spawn` it stands in for to confine
  --- each child a test starts, and note it.
  process: process
  --- SQLite's table, whose record of the files SQLite opens it drains.
  sqlite: sqlite
  --- The syscall table's log of what its calls answered, which it
  --- drains, and those calls, which log nothing, for its own questions.
  syscalls: Syscalls
end

return observations
