--- The native line-coverage collector provided by core/coverage.c. Lua's
--- `debug` library is never opened. A shipped runtime exposes this module
--- through the store searcher's trusted-module gate; boot preloads it for
--- the trusted source-tree bridge.

local record native
  --- Every source line hit while collecting was on, by the module's
  --- own import path: the chunk's full source identifier with its
  --- leading `@` removed. Other source identifiers are kept verbatim.
  --- A core built with native coverage adds its own C files here too.
  type Hits = {string: {integer: boolean}}

  --- One of the core's own C functions: its file by repository path, the
  --- line it begins on, and its name.
  record Function
    path: string
    line: integer
    name: string
  end

  --- Installs the line hook and begins a fresh, empty collection,
  --- discarding anything collected before. With `watched`, which maps C
  --- functions to names, calls are hooked too, and each one called is
  --- named by `called`.
  start: function(watched?: {any: string})

  --- Removes the line hook and returns everything hit since the
  --- matching `start`.
  stop: function(): Hits

  --- A copy of everything hit so far, without touching the hook or the
  --- collection -- safe to call while collection keeps running, unlike
  --- `stop`. Empty when no `start` has run.
  snapshot: function(): Hits

  --- The name of every watched function called since `start`.
  called: function(): {string: boolean}

  --- Every line of the core's own C that a hit could land on, keyed by
  --- repository path (core/syscalls.c) the way hits on it are. Empty in
  --- a core built without native coverage.
  lines: function(): Hits

  --- The line each of the core's own C functions begins on, keyed the
  --- same way: a function was entered when its line is hit. Empty in a
  --- core built without native coverage.
  entries: function(): Hits

  --- Every process started from now on, and every one those start,
  --- writes the core's C it ran into `directory` as it exits: one file
  --- a process, each line a repository path, a tab, and a line number.
  children: function(directory: string)

  --- Every one of the core's own C functions. Empty in a core built
  --- without native coverage.
  functions: function(): {Function}
end

return native
