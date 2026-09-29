--- What a sandboxed test worker's test was refused, for the audit of
--- what it reads undeclared (`build.test`'s `audited`) and the message
--- of a test that failed: a sandbox shows a worker only what its
--- module declares and what the runtime needs, so what a test reads
--- that it does not declare is what the sandbox refused it. A recording
--- (`refusals.start`) notes, as the worker's observations are shaped
--- (`build.filesystem_observations`' `Observation`):
---
--- - each read of a path that failed as a sandbox fails one it does not
---   show, or one it holds from the worker (ENOENT, ENOTDIR, EACCES or
---   EPERM): an open ("o"), a stat, an access or a change of directory
---   ("s"), an lstat ("l"), a readlink ("k"), a realpath ("a"); each
---   listing ("d") and each walk (`sys.tree_digest`, "g" by contents,
---   "j" by stamps) of the tree whatever it answered, since a directory
---   the sandbox made there to hold what it gives beneath it lists only
---   that -- one elsewhere it gives whole, or holds only what every
---   worker is given; and each read of the tree's o/cosmic.db, which a
---   sandbox gives narrowed to the module's import closure, whatever it
---   answered;
--- - each variable read by name that the worker's environment does not
---   hold ("e");
--- - each program a process the test started could not run, the
---   sandbox refusing it (ENOENT, ENOTDIR or EACCES) ("y"), and the
---   interpreter a script's first line names, which a sandbox that does
---   not give it refuses as it refuses the script; and each start
---   refused a root of its own ("x", `confine.nests_note` and the
---   program), both as build.confine's stand-in for `spawn` hears them
---   (`confine.hear`);
--- - each database `cosmic.sqlite` opens ("o"), and each request
---   `cosmic.http` opens or uploads ("x", its URL) but one that
---   connects nowhere (a scripted one, another scheme than http's),
---   whatever it answered: each reads in C, past the syscall table, and
---   a sandbox answers a request to loopback its module does not
---   declare;
--- - what its caller notes (`Recording.note`): each file SQLite itself
---   opened -- one an open named, and one a statement did, an ATTACH or
---   a VACUUM INTO -- which the worker hears from its capture's record
---   of SQLite's opens (`observations.hear_sqlite`).
---
--- A relative path is noted as the absolute one it names from the
--- working directory the call was made in. What was refused is not
--- judged here: the runner puts each path back where the host has it
--- (`test_sandbox.to_host`) and names what the host has there and the
--- module does not declare (`build.test`'s `audited`), as it would a
--- read.
---
--- A recording stands in for those calls on `cosmic.sys`'s shared
--- table, on `cosmic.sqlite`'s, and on `cosmic.http`'s where it is
--- loaded, passing each through as it is; a reference to one taken
--- before the recording began is not held. The harness takes its own
--- calls as it loads (build/harness_epoch.tl), and every module a test
--- loads, loads after the recording begins; a test that took one that
--- way from a module the worker loaded first reads past it.
--- What a program the test starts reads, it reads in a process of its
--- own, past every table here; what it was refused is none of this
--- recording's but where it could not start at all.
-- TODO: note what a program a sandboxed test starts was refused -- a
-- `host` file it looked for and did not find, a variable the sandbox
-- did not pass it -- once the sandbox can hear its processes' calls
-- (seccomp's user notification, from the sandbox's init in
-- core/syscalls.c): today only a program that could not start at all is
-- named, and one that ran without what it looked for is not.
-- TODO: note a request a module's top level makes through
-- `cosmic.http` that the module's own load first loaded, once a
-- recording can stand in as a module loads (a searcher of its own in
-- front of the store's): today its calls are held from the end of the
-- load on, and from its start only where the worker had loaded it.

local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local type observations = require("build.filesystem_observations")

local record refusals
  --- A recording under way (`start`).
  record Recording
    --- Stands in for `cosmic.sqlite`'s and `cosmic.http`'s calls
    --- where the test has loaded either since the recording began, as
    --- `start` does where the worker had.
    watch: function()
    --- Notes what the test was refused, or read that no refusal shows,
    --- as a stand-in here would: `kind`, and `path` as the worker has
    --- it.
    note: function(kind: string, path: string)
    --- Ends the recording, putting back each call it stood in for, and
    --- answers what was refused, each once, in the order it first was.
    stop: function(): {observations.Observation}
  end
end

--- The calls a recording makes of its own, taken as this module loads,
--- ahead of any test that could replace them on the shared table.
local getcwd, open_file, read, close = sys.getcwd, sys.open, sys.read, sys.close
local O_RDONLY, O_NONBLOCK = sys.O_RDONLY, sys.O_NONBLOCK
local stat_path = sys.stat

--- What a read failed with where a sandbox does not show its path or
--- holds it from the worker: the answers a refusal is.
local refused_with: {integer:boolean} = {
  [sys.ENOENT] = true, [sys.ENOTDIR] = true, [sys.EACCES] = true, [sys.EPERM] = true,
}

--- What a start failed with where a sandbox does not show its program,
--- or its interpreter or loader, or holds it from running.
local started_refused: {integer:boolean} = {
  [sys.ENOENT] = true, [sys.ENOTDIR] = true, [sys.EACCES] = true,
}

--- Whether `path` is `dir` or beneath it.
local function within(path: string, dir: string): boolean
  return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

--- A call a recording stands in for: the table it is on, its name
--- there, and what the table had in its place.
local record Replaced
  tbl: {string:any}
  name: string
  was: any
end

--- The kind each call of `cosmic.sys` taking a path first is noted as,
--- and whether it is noted whatever it answered.
local record PathCall
  kind: string
  always: boolean
end
local path_calls: {string:PathCall} = {
  open = { kind = "o" }, stat = { kind = "s" }, access = { kind = "s" },
  chdir = { kind = "s" }, lstat = { kind = "l" }, readlink = { kind = "k" },
  realpath = { kind = "a" }, readdir = { kind = "d", always = true },
  tree_digest = { kind = "g", always = true },
}

--- `path` as the working directory names it now: an absolute one as it
--- is, a relative one after the directory; nil where that cannot be
--- told.
local function absolute(path: string): string | nil
  if path:sub(1, 1) == "/" then return path end
  local here, _ = getcwd()
  if here == nil then return nil end
  return (here == "/" and "" or here) .. "/" .. path
end

--- The interpreter the first line of the script at `path` names, or
--- nil: a regular file alone, since an open of a FIFO would wait for a
--- writer, and one of a device may do what it does.
local function interpreter_of(path: string): string | nil
  local st, _ = stat_path(path)
  if st == nil or st.kind ~= "file" then return nil end
  local fd, _ = open_file(path, O_RDONLY | O_NONBLOCK)
  if fd == nil then return nil end
  local head, _ = read(fd, 256)
  local _, _ = close(fd)
  return (head or ""):match("^#!%s*(/[^%s]+)")
end

--- Whether a request for `url` could connect anywhere: all but one
--- naming a scheme other than http and https, which core/http.c does
--- not let curl speak. curl takes a URL with no scheme for http.
local function reaches(url: string): boolean
  local scheme = url:match("^%s*(%a[%w+.-]*):")
  if scheme == nil then return true end
  scheme = scheme:lower()
  return scheme == "http" or scheme == "https"
end

--- What it is handed: so a call made as its argument is no tail call,
--- and the frame that made it is there to place what the call raises.
local function pass(...: any): any...
  return ...
end

--- How many values `table.pack` packed into `results`.
local function count(results: any): integer
  if results is {string:any} then
    local n = results.n
    if n is integer then return n end
  end
  return 0
end

--- Raises `err` again, what a call a stand-in made raised, where the
--- stand-in was called: a message placed at the stand-in's own line,
--- as a call raises one at its caller's, is placed at its caller's
--- instead, and any other error is raised as it is.
local function raised(err: any)
  if err is string then
    local rest = err:match("^[^\n]-refusals[^:\n]*:%d+: (.*)$")
    if rest ~= nil then error(rest, 3) end
  end
  error(err, 0)
end

--- A call held in a table of calls, or nil where it holds none.
local type Call = function(...: any): any...
local function callable(value: any): Call
  if value is Call then return value end
  return nil
end

--- A module's table, seen as the calls it holds by name: none where
--- it is none.
local function calls_of(value: any): {string:any}
  if value is {string:any} then return value end
  return {}
end

--- Starts a recording of what the test is refused, with `tree` the
--- path the worker has the tree at.
function refusals.start(tree: string): refusals.Recording
  local store = tree .. "/o/cosmic.db"
  local found: {observations.Observation} = {}
  -- Each once: a test that lists or walks its own directory over and
  -- over would otherwise swell its report past what the runner reads.
  local seen: {string:boolean} = {}
  local function note(kind: string, path: string)
    local noted = kind .. "\0" .. path
    if seen[noted] then return end
    seen[noted] = true
    found[#found + 1] = { kind = kind, path = path, answer = "" }
  end
  -- What each table had in place of each call a recording stands in
  -- for, to put back.
  local replaced: {Replaced} = {}
  local function stand_in(tbl: {string:any}, name: string, with: any)
    replaced[#replaced + 1] = { tbl = tbl, name = name, was = tbl[name] }
    tbl[name] = with
  end
  local shared = calls_of(sys)
  -- What a call of `path_calls` taking `given` answered -- its first
  -- value, and its errno -- noted as the table says; `second` is its
  -- second argument, which says how a walk goes.
  local function answered(name: string, given: string, second: any, first: any, errno: any)
    local call = path_calls[name]
    local path = absolute(given)
    if path ~= nil and ((call.always and within(path, tree)) or path == store or
        (not first and errno is integer and refused_with[errno])) then
      local kind = call.kind
      if name == "tree_digest" and not second then kind = "j" end
      note(kind, path)
    end
  end
  -- One stand-in to a call, each calling it by the call's own name, so
  -- that what it raises -- an argument it refuses -- names it, and is
  -- raised again where the stand-in was called (`raised`): as it is
  -- without a recording.
  local open = callable(shared.open)
  if open ~= nil then
    local function called(...: any): any... return pass(open(...)) end
    stand_in(shared, "open", function(...: any): any...
      local results = table.pack(pcall(called, ...))
      if not results[1] then raised(results[2]) end
      local given: any = ...
      if given is string then
        answered("open", given, select(2, ...), results[2], results[4])
      end
      return table.unpack(results, 2, count(results))
    end)
  end
  local stat = callable(shared.stat)
  if stat ~= nil then
    local function called(...: any): any... return pass(stat(...)) end
    stand_in(shared, "stat", function(...: any): any...
      local results = table.pack(pcall(called, ...))
      if not results[1] then raised(results[2]) end
      local given: any = ...
      if given is string then
        answered("stat", given, select(2, ...), results[2], results[4])
      end
      return table.unpack(results, 2, count(results))
    end)
  end
  local access = callable(shared.access)
  if access ~= nil then
    local function called(...: any): any... return pass(access(...)) end
    stand_in(shared, "access", function(...: any): any...
      local results = table.pack(pcall(called, ...))
      if not results[1] then raised(results[2]) end
      local given: any = ...
      if given is string then
        answered("access", given, select(2, ...), results[2], results[4])
      end
      return table.unpack(results, 2, count(results))
    end)
  end
  local chdir = callable(shared.chdir)
  if chdir ~= nil then
    local function called(...: any): any... return pass(chdir(...)) end
    stand_in(shared, "chdir", function(...: any): any...
      local results = table.pack(pcall(called, ...))
      if not results[1] then raised(results[2]) end
      local given: any = ...
      if given is string then
        answered("chdir", given, select(2, ...), results[2], results[4])
      end
      return table.unpack(results, 2, count(results))
    end)
  end
  local lstat = callable(shared.lstat)
  if lstat ~= nil then
    local function called(...: any): any... return pass(lstat(...)) end
    stand_in(shared, "lstat", function(...: any): any...
      local results = table.pack(pcall(called, ...))
      if not results[1] then raised(results[2]) end
      local given: any = ...
      if given is string then
        answered("lstat", given, select(2, ...), results[2], results[4])
      end
      return table.unpack(results, 2, count(results))
    end)
  end
  local readlink = callable(shared.readlink)
  if readlink ~= nil then
    local function called(...: any): any... return pass(readlink(...)) end
    stand_in(shared, "readlink", function(...: any): any...
      local results = table.pack(pcall(called, ...))
      if not results[1] then raised(results[2]) end
      local given: any = ...
      if given is string then
        answered("readlink", given, select(2, ...), results[2], results[4])
      end
      return table.unpack(results, 2, count(results))
    end)
  end
  local realpath = callable(shared.realpath)
  if realpath ~= nil then
    local function called(...: any): any... return pass(realpath(...)) end
    stand_in(shared, "realpath", function(...: any): any...
      local results = table.pack(pcall(called, ...))
      if not results[1] then raised(results[2]) end
      local given: any = ...
      if given is string then
        answered("realpath", given, select(2, ...), results[2], results[4])
      end
      return table.unpack(results, 2, count(results))
    end)
  end
  local readdir = callable(shared.readdir)
  if readdir ~= nil then
    local function called(...: any): any... return pass(readdir(...)) end
    stand_in(shared, "readdir", function(...: any): any...
      local results = table.pack(pcall(called, ...))
      if not results[1] then raised(results[2]) end
      local given: any = ...
      if given is string then
        answered("readdir", given, select(2, ...), results[2], results[4])
      end
      return table.unpack(results, 2, count(results))
    end)
  end
  local tree_digest = callable(shared.tree_digest)
  if tree_digest ~= nil then
    local function called(...: any): any... return pass(tree_digest(...)) end
    stand_in(shared, "tree_digest", function(...: any): any...
      local results = table.pack(pcall(called, ...))
      if not results[1] then raised(results[2]) end
      local given: any = ...
      if given is string then
        answered("tree_digest", given, select(2, ...), results[2], results[4])
      end
      return table.unpack(results, 2, count(results))
    end)
  end
  local getenv = callable(shared.getenv)
  if getenv ~= nil then
    local function called(...: any): any... return pass(getenv(...)) end
    stand_in(shared, "getenv", function(...: any): any...
      local results = table.pack(pcall(called, ...))
      if not results[1] then raised(results[2]) end
      local name: any = ...
      if results[2] == nil and name is string then note("e", name) end
      return table.unpack(results, 2, count(results))
    end)
  end
  local stop_hearing = confine.hear({
    start = function(program: string, cwd: string | nil, errno: integer)
      -- Refused by the sandbox, not by a hold on what the test may
      -- start (`nests`, `must_confine`), which says so itself.
      if not started_refused[errno] then return end
      local path = program
      if path:sub(1, 1) ~= "/" and cwd ~= nil and cwd:sub(1, 1) == "/" then
        path = (cwd == "/" and "" or cwd) .. "/" .. path
      else
        path = absolute(path) or path
      end
      if path:sub(1, 1) ~= "/" then return end
      note("y", path)
      local interpreter = interpreter_of(path)
      if interpreter ~= nil then note("y", interpreter) end
    end,
    nests = function(program: string) note("x", confine.nests_note .. program) end,
  })
  -- `cosmic.sqlite`'s `open`, which this module loads so that it is
  -- held before any module of the test's loads, and `cosmic.http`'s
  -- `open` and `upload`, once each, where loaded: each notes what it was asked, whatever it
  -- answered -- but a request with a script, or a URL no request can
  -- send (a NUL in it), which connects nowhere, as the observation log
  -- leaves them out (core/http.c).
  local watched: {string:boolean} = {}
  local function watch_call(module: string, loaded: {string:any}, name: string, kind: string)
    local was: any = loaded[name]
    if watched[module .. "." .. name] or not was is function(any...): any... then return end
    watched[module .. "." .. name] = true
    stand_in(loaded, name, function(...: any): any...
      local given, options: any, any = ...
      local scripted = options is {string:any} and options.script ~= nil
      if given is string and given ~= "" and given ~= ":memory:" and not scripted and
          not given:find("\0", 1, true) and (kind ~= "x" or reaches(given)) then
        local path = kind == "o" and absolute(given) or given
        if path ~= nil then note(kind, path) end
      end
      return was(...)
    end)
  end
  local function watch()
    watch_call("cosmic.sqlite", calls_of(Sqlite), "open", "o")
    local http = calls_of(package.loaded["cosmic.http"])
    watch_call("cosmic.http", http, "open", "x")
    watch_call("cosmic.http", http, "upload", "x")
  end
  watch()
  return {
    watch = watch,
    note = note,
    stop = function(): {observations.Observation}
      stop_hearing()
      for at = #replaced, 1, -1 do
        local each = replaced[at]
        each.tbl[each.name] = each.was
      end
      replaced = {}
      return found
    end,
  }
end

return refusals
