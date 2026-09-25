--- Runs cosmic's command line in this process, for a test that would
--- otherwise start the binary only to see what a verb prints and exits
--- with. A test that starts a process never stands (see `build.test`),
--- while one that runs the verb here is keyed by what the verb read, like
--- any other.
---
--- The run is the binary's own: `build.dispatch`'s `main`, given the
--- command line, in the directory asked for, with descriptors 1 and 2
--- pointed at files for the length of it -- so what C writes, `print`
--- included, is captured too -- and only the binary's own database
--- searched (`Store.alone`), as a started binary searches it: not the
--- test's tree, which its worker attached. An uncaught error is written
--- as the binary writes one's first line, `cosmic: <message>`, and exits
--- 1; a main that returns no exit status from 0 to 255 exits 2, as the
--- core refuses one.
---
--- Where it cannot be the same, the caller gets an error rather than a
--- run that differs: a file run and `--standalone` load a file's modules
--- into the process and are refused before anything runs, and a call
--- that would end this process (`sys.exit`), replace it (`sys.execve`, as
--- a stale tool rebuilding itself does) or attach a database raises
--- through to the caller once everything is put back, however the verb
--- handled it. A test that needs one of those starts the binary.
---
--- What stays shared: a module the verb requires stays loaded after it,
--- and a global `-e` sets stays set, as in any process that runs two
--- chunks; `build.verdict`'s record of a verdict line is set back for
--- each run. The environment given is what a verb reads through
--- `cosmic.env`; C that reads its own (the core's startup, coverage)
--- sees this process's. Nothing times the run out but the test's own
--- limit.

local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local dispatch = require("build.dispatch")
local sys = require("cosmic.sys")
local verdict = require("build.verdict")

local record invoke
  --- How to run.
  record Options
    --- The working directory the command line runs in. Always one of
    --- the caller's own: a verb that checks the tool is fresh stages the
    --- tree it runs in, and a test's own tree is held by the run testing
    --- it.
    cwd: string
    --- The environment it reads, name to value; this process's when nil.
    env: {string:string} | nil
  end

  --- What a run ended with, as a started binary's would be.
  record Result
    code: integer
    stdout: string
    stderr: string
  end
end

--- Whether the first word runs a file, as `build.dispatch` decides it.
local function runs_a_file(first: string | nil): boolean
  if first == nil then return false end
  if first == "--standalone" then return true end
  return first:sub(1, 1) ~= "-" and (first:find("/", 1, true) ~= nil or
    first:match("%.tl$") ~= nil)
end

--- The exit code `value` is as `main`'s answer, as the core's
--- `cosmic_tostatus` reads it, or nil for one it refuses.
local function status_of(value: any): integer | nil
  if value == nil then return 0 end
  local whole: integer | nil = nil
  if value is number or value is string then
    local number = tonumber(value)
    whole = number ~= nil and math.tointeger(number) or nil
  end
  if whole == nil or whole < 0 or whole > 255 then return nil end
  return whole
end

--- Reads the whole of what a run wrote to `fd`.
local function drained(fd: integer): string
  local out: {string} = {}
  local at = 0
  while true do
    local chunk, _ = sys.pread(fd, 65536, at)
    if chunk == nil or chunk == "" then break end
    out[#out + 1] = chunk
    at = at + #chunk
  end
  return table.concat(out)
end

--- Runs `args` -- the words after `cosmic` -- as the binary would, here.
--- Raises for a command line only a process of its own can run, and when
--- a descriptor or the working directory cannot be set up or put back.
--- @param args the command line without the program's own name
--- @param opts where and with what environment to run
--- @return what it exited with and wrote
function invoke.run(args: {string}, opts: invoke.Options): invoke.Result
  if runs_a_file(args[1]) then
    error("invoke: `" .. tostring(args[1]) .. "` runs a file, which loads its " ..
      "modules into the process: start the binary instead", 2)
  end
  local argv: {integer:string} = { [0] = "cosmic" }
  for i, word in ipairs(args) do argv[i] = word end

  local dir = assert(Fs.mkdtemp("cosmic-invoke-"))
  local held: {integer} = {}
  local function release()
    for _, fd in ipairs(held) do local _, _ = sys.close(fd) end
    local _, _ = Fs.remove_tree(dir)
  end
  local function hold(fd: integer | nil, trouble: string, what: string): integer
    if fd == nil then
      release()
      error("invoke: " .. what .. ": " .. trouble, 3)
    end
    held[#held + 1] = fd
    return fd
  end
  local flags = sys.O_RDWR | sys.O_CREAT | sys.O_TRUNC
  local out_fd, out_trouble = sys.open(dir .. "/stdout", flags, 0x180)
  local out = hold(out_fd, out_trouble, "a file for standard output")
  local err_fd, err_trouble = sys.open(dir .. "/stderr", flags, 0x180)
  local err = hold(err_fd, err_trouble, "a file for standard error")
  local saved_out_fd, saved_out_trouble = sys.dup(1)
  local saved_out = hold(saved_out_fd, saved_out_trouble, "standard output")
  local saved_err_fd, saved_err_trouble = sys.dup(2)
  local saved_err = hold(saved_err_fd, saved_err_trouble, "standard error")
  local here, here_trouble = sys.getcwd()
  if here == nil then
    release()
    error("invoke: the working directory: " .. here_trouble, 2)
  end

  local getenv, environ = sys.getenv, sys.environ
  local exit, execve, attach = sys.exit, sys.execve, Store.attach
  local given = verdict.given
  local refused: string | nil = nil
  local function refuse(what: string)
    refused = refused or ("invoke: the command line called " .. what ..
      ", which only a process of its own can: start the binary instead")
    error(refused, 0)
  end

  local code = 1
  local ran, trouble = pcall(function(): string
    assert(sys.dup2(out, 1))
    assert(sys.dup2(err, 2))
    assert(sys.chdir(opts.cwd))
    local env = opts.env
    if env ~= nil then
      local given_env: {string:string} = env
      sys.getenv = function(name: string): string | nil return given_env[name] end
      sys.environ = function(): {string:string}
        local copy: {string:string} = {}
        for name, value in pairs(given_env) do copy[name] = value end
        return copy
      end
    end
    sys.exit = function(_?: integer) refuse("sys.exit") end
    sys.execve = function(_: string, _: {string}, _: {string:string}):
                          boolean, string, integer
      refuse("sys.execve")
      return false, "", 0
    end
    Store.attach = function(_: string): boolean, string
      refuse("Store.attach")
      return false, ""
    end
    verdict.given = false
    Store.alone(function()
      local called, answer = pcall(function(): any return dispatch.main(argv) end)
      if not called then
        -- TODO: write what the core writes after this line for an
        -- uncaught error -- its source position and the catalog's
        -- guidance (core/main.c's `failed`) -- once a binding hands them
        -- to Lua.
        local message = (answer is string or answer is number) and tostring(answer) or "failed"
        local _, _ = Fs.put(Fs.stderr, "cosmic: " .. message .. "\n")
        return
      end
      local status = status_of(answer)
      if status == nil then
        local _, _ = Fs.put(Fs.stderr, "cosmic: the main function returned no exit " ..
          "status from 0 to 255: cmd.cosmic.main\n")
        code = 2
      else
        code = status
      end
    end)
    return ""
  end)

  sys.getenv, sys.environ = getenv, environ
  sys.exit, sys.execve, Store.attach = exit, execve, attach
  verdict.given = given
  local out_back, out_back_trouble = sys.dup2(saved_out, 1)
  local err_back, err_back_trouble = sys.dup2(saved_err, 2)
  local back, back_trouble = sys.chdir(here)
  local result: invoke.Result = { code = code, stdout = drained(out), stderr = drained(err) }
  -- A descriptor that could not be put back is left open: closed, what it
  -- stood for would be gone for good.
  local keep: {integer:boolean} = {}
  if not out_back then keep[saved_out] = true end
  if not err_back then keep[saved_err] = true end
  local closing: {integer} = {}
  for _, fd in ipairs(held) do
    if not keep[fd] then closing[#closing + 1] = fd end
  end
  held = closing
  release()
  if not out_back then
    error("invoke: standard output could not be put back: " .. out_back_trouble)
  end
  if not err_back then
    error("invoke: standard error could not be put back: " .. err_back_trouble)
  end
  if not back then
    error("invoke: the working directory could not be put back: " .. back_trouble)
  end
  if not ran then error(trouble, 0) end
  if refused ~= nil then error(refused, 0) end
  return result
end

return invoke
