--- What a test module tells `cosmic test` about itself. For now, what
--- its tests read beyond their default inputs, with `needs`:
---
---     local Test = require("cosmic.test")
---     Test.needs { reads = { "testdata/" }, env = { "PATH" } }
---
--- A test's default inputs are its module's import closure, as source
--- files; every fuzz corpus (`testdata/fuzz/`), when that closure holds
--- `build.fuzz`; and the variables `cosmic test` itself pins. What else
--- the tests read, their module declares. `cosmic test --audit` runs
--- every test and names what each read that neither covers, with the
--- `needs` call that would hold it.
---
--- The build reads the declaration from the source, without running
--- the module, so the call is held to one shape: a statement at the
--- top of a test or example module, once, on the name a `local` binds
--- `require("cosmic.test")` to, with one table written out as a literal
--- -- `Test.needs { ... }` or `Test.needs({ ... })`. Anything else -- a
--- value computed, a call inside a function, `needs` passed around
--- under another name -- fails the build, naming its line. When the
--- module runs under `cosmic test`, what the call was handed must be
--- what the build read, or the module fails to load. The call is once a
--- process, whichever module makes it: a test module never requires
--- another test module that calls `needs`. Every string is written
--- plainly, without escapes or long brackets, as the build reads it.
-- TODO: take `confine`, `reads_stat_times` and `environment` from
-- build.filesystem_observations, which a test calls to say what it
-- starts and what it reads of a stat, once each can be read from the
-- source as `needs` is: another project's tests cannot reach build/.

local Errors = require("cosmic.errors")

local record Test
  --- What each field of `Needs` takes; see below.
  fields: {string:string}

  --- What the tests of one module read beyond their default inputs.
  --- Every field is optional.
  record Needs
    --- Paths of the tree, relative to its root, each a file or a
    --- directory and everything beneath it.
    reads: {string}
    --- Absolute paths outside the tree, each a file or a directory and
    --- everything beneath it: the host's own files.
    host: {string}
    --- Environment variables beyond the pinned ones; `"*"` is the
    --- whole environment, which a process started without an `env` of
    --- its own inherits.
    env: {string}
    --- Requests over the network: `true` for any host, or the hosts.
    network: boolean | {string}
    --- Whether the tests start processes no sandbox holds, or hand one
    --- what no observation accounts for: a descriptor, a path of /proc.
    processes: boolean
    --- Whether the tests read the tool itself, `o/bin/cosmic`, or the
    --- program running them.
    tool: boolean
    -- TODO: give each test a store derived from its import closure, and
    -- take `store` for the whole one, once the sandboxed worker (a
    -- later phase of declared inputs) binds one at o/cosmic.db: today a
    -- test reads all of it, declared or not.
    --- Whether the tests open the tree's projection, `o/cosmic.db`,
    --- themselves rather than through `require` and `cosmic.store`.
    store: boolean
  end
end

--- What each field of `Needs` takes: a list of strings ("list"), a
--- boolean ("flag"), or either ("either"). The build holds a declaration
--- in the source to the same table (`build.analyzer`).
Test.fields = {
  reads = "list", host = "list", env = "list", network = "either",
  processes = "flag", tool = "flag", store = "flag",
}

--- What a test runner installed as `__runner` on this module's table
--- -- no part of its type -- to learn what `needs` is handed as the
--- module it runs loads (`build.test_worker`), and to have a call once
--- that module has loaded refused: a table whose `handed` is called with
--- what `needs` was handed, and whose `loaded` the runner sets once the
--- module has loaded. Nil when none is installed.
local function runner_in(module: any): {string:any}
  if module is {string:any} then
    local installed = module.__runner
    if installed is {string:any} then return installed end
  end
  return nil
end

--- Where the one `needs` call came from, once it has come.
local called_at: string = nil

--- Why `value`, handed to `needs`, is no `Needs`, or "" when it is one.
local function trouble_of(value: any): string
  if not value is {any:any} then
    return "takes a table, got " .. type(value)
  end
  for key, field_value in pairs(value) do
    local takes = key is string and Test.fields[key] or nil
    if takes == nil then
      return "has no field " .. tostring(key)
    end
    local wanted = takes == "list" and "a list of strings" or
      takes == "flag" and "true or false" or "true, false or a list of hosts"
    local is_flag = field_value is boolean
    if (is_flag and takes == "list") or (not is_flag and takes == "flag") or
        (not is_flag and not field_value is {any:any}) then
      return tostring(key) .. " takes " .. wanted
    end
    if field_value is {any:any} then
      for i, item in pairs(field_value) do
        if not (math.type(i) == "integer" and item is string) then
          return tostring(key) .. " takes " .. wanted
        end
      end
    end
  end
  return ""
end

--- Where `needs` was called from, as the chunk and line a traceback
--- names -- its frame four up: the trace, this, `needs`, its caller --
--- or "an earlier call".
local function caller(): string
  local trace = Errors.trace(nil, 4)
  return trace:match("\n%s*([^\n]-:%d+):") or "an earlier call"
end

--- Declares what this module's tests read beyond their default inputs
--- (see the module's own doc for the shape the call must have). Raises
--- for a value no `Needs` could be; for a second call in the process,
--- naming where the first was -- so a test module never requires
--- another that calls `needs`; and, under a runner, for a call once the
--- module has loaded, as from inside a test.
function Test.needs(needs: Test.Needs)
  local trouble = trouble_of(needs)
  if trouble ~= "" then
    error("cosmic.test: needs " .. trouble, 2)
  end
  local installed = runner_in(Test)
  if installed ~= nil and installed.loaded == true then
    error("cosmic.test: needs is called at the top of a test module, while it loads", 2)
  end
  if called_at ~= nil then
    error("cosmic.test: needs is called once, and " .. called_at .. " called it already; " ..
      "a test module never requires another that calls it", 2)
  end
  called_at = caller()
  local handed = installed ~= nil and installed.handed or nil
  if handed is function(Test.Needs) then handed(needs) end
end

return Test
