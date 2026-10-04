--- To write a test, put top-level `local function test_*` functions in a
--- `<name>_test.tl` file ([`cosmic.layout`]). This module is what such a
--- module tells `cosmic test` about itself: what its tests
--- read beyond their default inputs, with `needs`:
---
---     local Test = require("cosmic.test")
---     Test.needs { reads = { "testdata/" }, env = { "PATH" } }
---
--- A test's default inputs are its module's import closure, as source
--- files; every fuzz corpus (`testdata/fuzz/`), when that closure holds
--- the fuzz module; and the variables `cosmic test` itself pins. What else
--- the tests read, their module declares.
---
--- A test's verdict is keyed by what it declares, and stands until that
--- changes. Where `cosmic test` sandboxes its workers (Linux), a test is
--- given what it declares and nothing else, so a read it does not
--- declare fails. Where it cannot (macOS, or COSMIC_TEST_SANDBOX=0), the
--- run trusts the declaration: an undeclared read works, but its change
--- moves no key, so the verdict stands stale on it. Declare it anyway:
--- a sandboxed run of the same test is what enforces it, where an
--- undeclared read finds nothing and the test fails with its own error.
--- A start or a read that found nothing at an absolute path the
--- sandbox left out -- /bin/sh, say, for a test that does not declare
--- `system` -- says so beneath that error, naming what to declare: a
--- test that starts a host program declares `system = true`.
---
--- The closure is what the build finds `require`d by a literal name,
--- anywhere in the module and in each it requires. Under `cosmic test`,
--- a `require` of any other module of the tree -- a name computed, or
--- handed to `pcall(require, ...)` -- fails, naming the module: require
--- it statically, at the top level. The modules the core itself
--- carries, which no file of the tree is, load as ever.
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
---
--- `policy` is `needs`' successor, being phased in: a module declares
--- one or the other, never both, in the fields of [`cosmic.sandbox`]'s
--- [`Policy`] -- see [`Test.policy`]. Until the policy runs a worker of its
--- own, the harness translates it into the `needs` it stands for, so the
--- test is sandboxed and keyed as that `needs` would have it.
---
--- A test that this host cannot give the sandbox it is about says so
--- with `skip`, as it returns early: the run counts it skipped rather
--- than passed.

-- TODO: take `environment` and `program` from build.this_program, which
-- a test calls to say what a process of this program it starts needs
-- and how to start one past its launcher, once each can be read from the
-- source as `needs` is: another project's tests cannot reach build/.
-- (`confine` stays in build.confine: only the sandbox's own tests nest
-- one sandbox in another.)

-- The core's own `trace`, which cosmic.errors wraps: not cosmic.errors,
-- which would bring cosmic.sqlite and cosmic.store into every worker
-- (build/harness_epoch.tl's `library`).
local errors = require("cosmic.internal.errors")

local record Test
  --- What the tests of one module read beyond their default inputs.
  --- Every field is optional.
  record Needs
    --- Paths of the tree, relative to its root, each a file or a
    --- directory and everything beneath it.
    reads: {string}
    --- Absolute paths outside the tree, each a file of the host's -- or
    --- /proc, or a path beneath it, which every worker is given and no
    --- key could hold by what it holds. A directory is refused: one
    --- written with a "/" after it, or a variable's whole path, fails the
    --- build, naming its line; one that is a directory on the host fails
    --- each test of the module, naming it. Declare the files the tests
    --- read -- a checkout's `$ROOT/o/bin/cosmic`, not `$ROOT`. A path
    --- whose first name is `$NAME` is where the environment variable NAME
    --- says, wherever that is -- `"$PRODUCT/bin/tool"` -- and declares
    --- NAME too. The variable is looked up in the environment the tests
    --- are given: where it is unset, empty or relative, each test of the
    --- module fails, naming it, as it does where any `host` path is the
    --- tree's, or above it. Such a path is keyed by the variable's name
    --- and by what the file holds, not by where it is, so the same
    --- contents elsewhere key the same, and a verdict reached there
    --- stands here: a test must not depend on where the variable says,
    --- as it must not on where the tree is.
    host: {string}
    --- Environment variables beyond the pinned ones; `"*"` is the
    --- whole environment, which a process started without an `env` of
    --- its own inherits.
    env: {string}
    --- The loopback addresses the tests reach, each a dotted quad of
    --- 127/8, `127.a.b.c`, as a request names it: a sandboxed worker
    --- runs offline, with a loopback of its own that answers them, and
    --- is keyed like any other. No test reaches another host: what one
    --- answered, no key could hold, so a test that needs a service
    --- starts its own on 127.0.0.1. `true`, any other name or address
    --- -- `::1` and `localhost` among them, whose answer turns on how
    --- the host sets up IPv6 -- and a spelling no request's host is
    --- (a port, brackets, a leading zero) are refused, naming this
    --- rule, as the build refuses them before the module runs.
    network: {string}
    --- Whether the tests read the tool itself, `o/bin/cosmic`, or the
    --- program running them, or start either: it gives them the program
    --- and nothing else -- not the store beyond their closure (`store`),
    --- nor a root of their own for what they start (`nests`).
    tool: boolean
    --- Whether the tests start this program only to run Lua in it: a
    --- `-e` chunk, past its launcher or by [`Proc.relaunch`] -- and a
    --- file `--standalone` too where they declare `standalone`. Like
    --- `tool`, it lets them run the program -- but not read it by its
    --- name -- and every process they start, and each one those start,
    --- is held as their worker is, whatever environment it is given: it
    --- loads nothing of the program but the tests' import closure and
    --- what `cosmic -e` loads before the chunk runs, and reads no rows
    --- but theirs. So their key holds those, not every module the program
    --- carries, and an edit to another module the program carries runs
    --- them no more than one to a module of the tree outside their
    --- closure. A chunk that requires a module outside them, or a verb
    --- run that way -- `--standalone` among them, unless `standalone` is
    --- declared -- fails, naming this field: require the module at the
    --- top level of the test module, declare `standalone` beside it, or
    --- declare `tool` in its place. It is refused beside `tool`, `store`,
    --- `system` or `caches`: a host program, or a cosmic a cache holds,
    --- could start the program with no hold.
    lua: boolean
    --- Whether the tests, declaring `lua`, also run a file `cosmic
    --- --standalone`: their closure holds what that way loads before the
    --- file runs too -- the checker, the compiler beside it, and what
    --- they require -- so their key moves with those, and their children
    --- may load them. Refused without `lua`.
    standalone: boolean
    --- Whether the tests confine a process in a root of its own: a
    --- `sandbox` that unveils ([`cosmic.child`]), or a `cosmic test` they
    --- start whose workers are sandboxed. A sandboxed worker whose
    --- module does not declare it is held by a Landlock ruleset, under
    --- which the kernel refuses every mount, and a root of its own is
    --- made of mounts: such a start is refused, naming this field, and
    --- the test fails, where otherwise it could pass having confined
    --- nothing. The tests of the sandbox itself declare it. Off the
    --- Linux sandbox -- on macOS, or with COSMIC_TEST_SANDBOX=0 -- no
    --- worker is held, so a test that
    --- confines without it passes there and fails on a Linux leg.
    nests: boolean
    --- Requests private writable scratch at COSMIC_TEST_NOEXEC whose
    --- files cannot execute. Ordinary scratch is unchanged. Reading,
    --- interpreting or copying the bytes elsewhere remains possible.
    --- Unsupported hosts skip these tests; a held-sandbox run fails them.
    noexec: boolean
    --- Whether the tests read the tree's projection, `o/cosmic.db`, or
    --- the rows of modules of the tree outside their import closure.
    --- Without it, a sandboxed worker is given at o/cosmic.db the store
    --- of its module's import closure alone, which its key holds, and a
    --- `require` reaches only that closure; unsandboxed, the worker
    --- attaches that store in the projection's place, though what it
    --- starts reads o/cosmic.db. Every other lookup in the
    --- store is held to the closure too, from the module's load until
    --- the worker ends: [`Store.bytecode`], [`Store.source`] or
    --- [`Store.requires`] of a module outside it, or the store's searcher
    --- called by hand, answers none, and [`Store.databases()`] raises,
    --- sandboxed or not, since such a read would reach rows no key of
    --- the test holds. A test that type-checks a snippet reads
    --- `cosmic.*` sources and declarations this way: a module the
    --- snippet requires goes in the test's closure
    --- (`local type _ = require(...)`), or the test declares `store`.
    --- `tool` lets a test start the program, but not read its database
    --- through the descriptor a portable start keeps on it: that read is
    --- refused, whatever the test declares.
    store: boolean
    -- [`Store.meta`] is not held (the TODO on `hold_store` in
    -- build/test_worker.tl). The descriptor is refused by core/check.h's
    -- `cosmic_checkfd`, and a sandboxed worker that does not declare
    -- `tool` has no name to open the program by.

    --- Whether the tests, or the processes they start, read the system's
    --- own programs and files: /usr, /bin, /sbin, /lib and its kin, and
    --- /etc, as a host program or its dynamic loader needs them -- a
    --- shell, `sleep`, a compiler's headers, the zone database. Without
    --- it a sandboxed worker has none of them, only /proc, the devices a
    --- program takes for granted (/dev/null, /dev/zero, /dev/urandom)
    --- and /dev/full, and its key holds nothing of which packages the
    --- host has installed or which system it says it is: a verdict that
    --- stood on one host stands on another of the same kernel and
    --- processor. A test that starts this program's core directly, past
    --- its launcher, needs none; one that runs the launcher itself
    --- (o/bin/cosmic, `#!/bin/sh`) needs it. One that reads a file or two
    --- of the system rather names them in `host`, which keys a file by
    --- its contents.
    system: boolean
    --- Host caches the tests, or the processes they start, write, by
    --- name: `"zig"` (the pinned zig, and zig's global and project
    --- caches) or `"bootstrap"` (the bootstrap cosmic, and the cores a
    --- portable cosmic extracts); the runner knows where each is on the
    --- host, and another name fails the build. Only for
    --- a cache whose contents never change a result -- content-addressed,
    --- there to save time: what a test reads or writes there enters no
    --- verdict's key. A sandboxed
    --- worker has each writable at its own path, with the variables that
    --- locate it.
    caches: {string}
  end

  --- One path a test may reach, and how: [`cosmic.sandbox`]'s [`Grant`].
  record Grant
    --- A path of the tree, relative to its root (the worker's directory),
    --- or an absolute path of the host's.
    path: string
    --- What the test may do there: letters of "rwxcu". Only "r" takes
    --- effect so far.
    letters: string
    --- The host's path where it differs from `path`. Not yet taken.
    from: string
  end

  --- The resource limits of a policy: [`cosmic.sandbox`]'s [`Limits`]. None
  --- is taken yet.
  record Limits
    --- The most descriptors a process may hold open.
    open_files: integer
    --- The most bytes a process may write to one file.
    file_bytes: integer
    --- The CPU seconds a process may spend.
    cpu_seconds: integer
    --- The most processes and threads of the whole sandbox.
    processes: integer
  end

  --- What the tests of one module are held to: the fields of
  --- [`cosmic.sandbox`]'s [`Policy`], which a test module writes in place
  --- of [`Needs`]. Every field is optional. This module cannot require
  --- cosmic.sandbox -- every worker would load it -- so the record is
  --- written out here, and a test holds it to the same fields.
  record Policy
    --- Named policies to join in: "system" (`system` of [`Needs`]) and
    --- "cosmic" (`tool`).
    profiles: {string}
    --- The paths the tests read: a grant of "r" on a path of the tree is
    --- a read of it, on an absolute path a host file.
    grants: {Grant}
    --- How far the worker is isolated. Not yet taken.
    isolate: {string}
    --- What the tests may do beyond their basics: "nest" is `nests`;
    --- "fork", "jit" and "fattr" are accepted and change nothing yet.
    promises: {string}
    --- The hosts the tests reach. Refused: no test reaches a host but
    --- loopback.
    connect: {string}
    --- The loopback addresses the tests reach: `network` of [`Needs`].
    loopback: {string}
    --- The variables passed through: `env` of [`Needs`].
    env: {string}
    --- The variables set, by name. Not yet taken.
    set_env: {string:string}
    --- Digests of values set. Refused: a digest holds no value to set.
    set_env_digests: {string:string}
    --- Whether the tests have a temporary directory of their own, as
    --- every test has: `false` is not yet taken.
    tmp: boolean
    --- The resources the tests may spend. Not yet taken.
    limits: Limits
  end
end

--- What each field of [`Needs`] takes: a list of strings ("list") or a
--- boolean ("flag"). The build holds a declaration read from the source
--- to the same table (`input_fields` in build/analyzer.tl); what only the
--- build can say of one -- that `network` names loopback addresses alone,
--- which fields `lua` stands beside -- it says before the module runs, so
--- `needs` holds a value to its shape and no more.
local FIELDS <const>: {string:string} = {
  reads = "list", host = "list", env = "list", network = "list",
  tool = "flag", lua = "flag", standalone = "flag", nests = "flag", noexec = "flag", store = "flag",
  system = "flag", caches = "list",
}

--- What a test runner installed as `__runner` on this module's table
--- -- no part of its type -- to learn what `needs` is handed as the
--- module it runs loads, and to have a call once
--- that module has loaded refused: a table whose `handed` is called with
--- what `needs` was handed, whose `loaded` the runner sets once the
--- module has loaded, and whose `skipped` is called with the reason
--- each `skip` is given. Nil when none is installed.
local function runner_in(module: any): {string:any}
  if module is {string:any} then
    local installed = module.__runner
    if installed is {string:any} then return installed end
  end
  return nil
end

--- Where the one `needs` call came from, once it has come.
local called_at: string = nil
--- Which of `needs` and `policy` made it.
local called_by: string = nil

--- Why `value`, handed to `needs`, is no [`Needs`], or "" when it is one.
--
-- TODO: write this as a cosmic.shape spec over [`Needs`] once cosmic.shape and
-- the cosmic.json it requires may be in the harness: each would join
-- build/harness_epoch.tl's `library`, and every edit to either would cost an
-- acknowledged digest line there and possibly an epoch bump. The messages
-- (`$.reads: expected list, got string`) would also differ from the ones
-- cosmic/test_tool_test.tl holds.
local function trouble_of(value: any): string
  if not value is {any:any} then
    return "takes a table, got " .. type(value)
  end
  for key, field_value in pairs(value) do
    local takes = key is string and FIELDS[key] or nil
    if takes == nil then
      return "has no field " .. tostring(key)
    end
    local wanted = takes == "list" and "a list of strings" or "true or false"
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

--- Where `needs` or `policy` was called from, as the chunk and line a
--- traceback names -- its frame four up: this, `declare`, the call, its
--- caller -- or "an earlier call".
local function caller(): string
  local trace = errors.trace(nil, 4)
  return trace:match("\n%s*([^\n]-:%d+):") or "an earlier call"
end

--- Records that this module declared its inputs, by `which` (`needs` or
--- `policy`), and hands `needs` to the runner: the one place both calls
--- are held to being made once, as the module loads.
local function declare(which: string, needs: Test.Needs)
  local installed = runner_in(Test)
  if installed ~= nil and installed.loaded == true then
    error("test: " .. which .. " is called at the top of a test module, while it loads", 3)
  end
  if called_at ~= nil then
    local first = called_by or which
    error("test: " .. which .. " is called once, and " .. called_at .. " called " ..
        (first == which and "it" or first) .. " already; " ..
        (first == which and "a test module never requires another that calls it" or
          "a module declares needs or policy, not both"), 3)
  end
  called_at, called_by = caller(), which
  local handed = installed ~= nil and installed.handed or nil
  if handed is function(Test.Needs) then handed(needs) end
end

--- Declares what this module's tests read beyond their default inputs
--- (see the module's own doc for the shape the call must have). Raises
--- for a value no [`Needs`] could be; for a second call in the process,
--- naming where the first was -- so a test module never requires
--- another that calls `needs`; and, under a runner, for a call once the
--- module has loaded, as from inside a test.
function Test.needs(needs: Test.Needs)
  local trouble = trouble_of(needs)
  if trouble ~= "" then
    error("test: needs " .. trouble, 2)
  end
  declare("needs", needs)
end

--- The fields of [`Policy`] and what each takes: a list of strings
--- ("list"), a table ("map"), a boolean ("flag"), a list of grants
--- ("grants") or the limits ("limits").
local POLICY_FIELDS <const>: {string:string} = {
  profiles = "list", grants = "grants", isolate = "list", promises = "list",
  connect = "list", loopback = "list", env = "list", set_env = "map",
  set_env_digests = "map", tmp = "flag", limits = "limits",
}

local POLICY_FIELD_NAMES <const>: {string} = {
  "connect", "env", "grants", "isolate", "limits", "loopback", "profiles", "promises",
  "set_env", "set_env_digests", "tmp",
}

local LIMIT_FIELDS <const>: {string:boolean} = {
  open_files = true, file_bytes = true, cpu_seconds = true, processes = true,
}

--- The migration this module carries: what [`Test.policy`] refuses today
--- it takes once the policy has a worker of its own.
local NOT_YET <const> = "is not yet taken: a policy runs a worker as a `needs` does " ..
  "(migration step a of the sandbox plan), and this takes effect where the policy's own " ..
  "path runs it (step b)"

--- The profiles a policy joins in, and the `needs` flag each stands for.
local PROFILE_FLAGS <const>: {string:string} = { system = "system", cosmic = "tool" }

--- The promises a policy makes, and whether one has a `needs` field.
local PROMISE_FIELDS <const>: {string:string} = {
  nest = "nests", fork = "", jit = "", fattr = "",
}

--- `value` as a list of strings, or nil and why, naming `field`.
local function strings_of(field: string, value: any): {string} | nil, string
  local out: {string} = {}
  if value is {any:any} then
    local count = 0
    for i, item in pairs(value) do
      if not (i is integer and item is string) then
        return nil, field .. " takes a list of strings"
      end
      count = count + 1
      out[i] = item
    end
    if count == #out then return out, "" end
  end
  return nil, field .. " takes a list of strings"
end

--- `value` as a table of names to strings, or nil and why, naming `field`.
local function names_of(field: string, value: any): {string:string} | nil, string
  local out: {string:string} = {}
  if value is {any:any} then
    for k, v in pairs(value) do
      if not (k is string and v is string) then
        return nil, field .. " takes a table of names to strings"
      end
      out[k] = v
    end
    return out, ""
  end
  return nil, field .. " takes a table of names to strings"
end

--- `value` as a [`Policy`]'s grants, or nil and why.
local function grants_of(value: any): {Test.Grant} | nil, string
  local out: {Test.Grant} = {}
  if not value is {any} then return nil, "grants takes a list of grants" end
  for i, given in ipairs(value) do
    local at = "grants[" .. i .. "]"
    if not given is {any:any} then return nil, at .. " takes a table" end
    local grant: Test.Grant = {}
    for key, field in pairs(given) do
      if not (key == "path" or key == "letters" or key == "from") then
        return nil, at .. " has no field " .. tostring(key) .. "; it has from, letters, path"
      end
      if not field is string then return nil, at .. "." .. tostring(key) .. " takes a string" end
      if key == "path" then
        grant.path = field
      elseif key == "letters" then
        grant.letters = field
      else
        grant.from = field
      end
    end
    out[i] = grant
  end
  return out, ""
end

--- `value` as a [`Policy`]'s limits, or nil and why.
local function limits_of(value: any): Test.Limits | nil, string
  local out: Test.Limits = {}
  if value is {any:any} then
    for key, field in pairs(value) do
      if not (key is string and LIMIT_FIELDS[key] and field is integer) then
        return nil, "limits takes open_files, file_bytes, cpu_seconds and processes, " ..
          "each an integer"
      end
      if key == "open_files" then
        out.open_files = field
      elseif key == "file_bytes" then
        out.file_bytes = field
      elseif key == "cpu_seconds" then
        out.cpu_seconds = field
      else
        out.processes = field
      end
    end
    return out, ""
  end
  return nil, "limits takes a table of limits"
end

--- What was handed to `policy` as a [`Policy`], or nil and why, naming
--- the field.
local function policy_of(given: any): Test.Policy | nil, string
  if not given is {any:any} then
    return nil, "takes a table, got " .. type(given)
  end
  local out: Test.Policy = {}
  for key, value in pairs(given) do
    local takes = key is string and POLICY_FIELDS[key] or nil
    if not (key is string) or takes == nil then
      return nil, "has no field " .. tostring(key) .. "; it has " ..
        table.concat(POLICY_FIELD_NAMES, ", ")
    end
    local why = ""
    if takes == "flag" then
      if value is boolean then out.tmp = value else why = key .. " takes true or false" end
    elseif takes == "grants" then
      out.grants, why = grants_of(value)
    elseif takes == "limits" then
      out.limits, why = limits_of(value)
    elseif takes == "map" then
      if key == "set_env" then
        out.set_env, why = names_of(key, value)
      else
        out.set_env_digests, why = names_of(key, value)
      end
    elseif key == "profiles" then
      out.profiles, why = strings_of(key, value)
    elseif key == "isolate" then
      out.isolate, why = strings_of(key, value)
    elseif key == "promises" then
      out.promises, why = strings_of(key, value)
    elseif key == "connect" then
      out.connect, why = strings_of(key, value)
    elseif key == "loopback" then
      out.loopback, why = strings_of(key, value)
    else
      out.env, why = strings_of(key, value)
    end
    if why ~= "" then return nil, why end
  end
  return out, ""
end

-- TODO: let a policy say what `store`, `caches`, `lua`, `standalone`,
-- `noexec` and a `$NAME` host path say (a grant on the store, a per-user
-- host cache, a writable grant without x, a variable-named grant), once
-- the policy path (step b of the sandbox plan) gives each a field of
-- cosmic.sandbox's [`Policy`]: a module that declares one stays on `needs`.
-- TODO: hand the promises to the runner once the filter runs on every
-- worker (step d of the sandbox plan, which keeps them in the key); until
-- then a promise a test does not make cannot be told from one it does.
--- The `needs` a policy stands for, or nil and why. The test is sandboxed
--- and keyed as that `needs` would have it: reads of the tree, host
--- files, the variables, loopback addresses, the program (profile
--- "cosmic", `tool`), the system (profile "system") and nesting (promise
--- "nest"). What it cannot say is refused, naming the field, rather than
--- accepted as a declaration that moves no key: `isolate`, `set_env`,
--- `limits`, a grant of more than "r" or from another path, `tmp = false`.
--- `connect` and `set_env_digests` are refused outright, since no test
--- reaches a host but loopback and a digest holds no value to set.
--- The promises "fork", "jit" and "fattr" are accepted and change
--- nothing: no worker holds them yet.
---
--- Internal to the harness: it exists so that cosmic/test_policy_test.tl
--- can compare the runtime translation with the analyzer's; a test module
--- declares with [`Test.policy`].
--- @param given any What `policy` was handed, or the build read of it
--- @return Needs|nil The `needs` it stands for
--- @return string Why there is none, naming the field
function Test.needs_of(given: any): Test.Needs | nil, string
  local policy, why = policy_of(given)
  if policy == nil then return nil, why end
  local out: Test.Needs = {}
  local reads: {string} = {}
  local host: {string} = {}
  local flags: {string:boolean} = {}
  for _, profile in ipairs(policy.profiles or {}) do
    local flag = PROFILE_FLAGS[profile]
    if flag == nil then
      return nil, "profiles: no profile " .. profile .. "; the profiles are cosmic, system"
    end
    flags[flag] = true
  end
  for i, grant in ipairs(policy.grants or {}) do
    local at = "grants[" .. i .. "]"
    local path, letters = grant.path, grant.letters
    if path == nil or path == "" then return nil, at .. ".path takes a path" end
    if letters == nil or letters == "" or letters:find("^r?w?x?c?u?$") == nil then
      return nil, at .. ".letters takes letters of rwxcu, in that order"
    end
    if grant.from ~= nil then return nil, at .. ".from " .. NOT_YET end
    if letters ~= "r" then
      return nil, at .. ".letters \"" .. letters .. "\" " .. NOT_YET ..
        "; a test reads, with \"r\", what it declares"
    end
    local list = path:sub(1, 1) == "/" and host or reads
    list[#list + 1] = path
  end
  for _, promise in ipairs(policy.promises or {}) do
    local field = PROMISE_FIELDS[promise]
    if field == nil then
      return nil, "promises: no promise " .. promise .. "; the promises are fattr, fork, jit, nest"
    end
    if field == "nests" then flags.nests = true end
  end
  if #(policy.isolate or {}) > 0 then return nil, "isolate " .. NOT_YET end
  if next(policy.limits or {}) ~= nil then return nil, "limits " .. NOT_YET end
  if next(policy.set_env or {}) ~= nil then return nil, "set_env " .. NOT_YET end
  if next(policy.set_env_digests or {}) ~= nil then
    return nil, "set_env_digests is refused: a digest holds no value to set; " ..
      "a test names the value in set_env"
  end
  if #(policy.connect or {}) > 0 then
    return nil, "connect is refused: no test reaches a host but loopback, whose answer no " ..
      "key holds; declare the addresses in loopback and start the service in the test"
  end
  if policy.tmp == false then
    return nil, "tmp = false " .. NOT_YET .. "; every test has a temporary directory today"
  end
  out.tool, out.system, out.nests = flags.tool, flags.system, flags.nests
  if #reads > 0 then out.reads = reads end
  if #host > 0 then out.host = host end
  for _, name in ipairs(policy.env or {}) do
    if name == "*" then
      return nil, 'env: a policy names each variable it passes through; no wildcard "*" in a policy'
    end
  end
  if #(policy.env or {}) > 0 then out.env = policy.env end
  if #(policy.loopback or {}) > 0 then out.network = policy.loopback end
  return out, ""
end

--- Declares what this module's tests are held to, in the fields of
--- [`cosmic.sandbox`]'s [`Policy`], where `needs` declares what they read
--- beyond their default inputs; a module declares one or the other, never
--- both. The harness translates the policy into the `needs` it stands for
--- ([`Test.needs_of`]), and the test runs, and is keyed, as that `needs`
--- would have it:
---
---     local Test = require("cosmic.test")
---     Test.policy {
---       profiles = { "system" },
---       grants = { { path = "testdata", letters = "r" } },
---       env = { "PATH" },
---       loopback = { "127.0.0.1" },
---     }
---
--- is `Test.needs { system = true, reads = { "testdata" }, env = { "PATH" },
--- network = { "127.0.0.1" } }`. The build reads the call as it does
--- `needs`'s: one table written out as a literal, once, at the top of the
--- module. A grant with a path of the tree is a read of it, an absolute
--- path a read of that host file; the profile "system" is `system`,
--- "cosmic" is `tool`; the promise "nest" is `nests`; `loopback` is
--- `network`. What has no `needs` to stand for -- a grant to write, run
--- or connect to, `isolate`, `limits`, `set_env`, `connect` -- fails the
--- build, naming the field. Raises as `needs` does, for a value no
--- [`Policy`] could be and for a call made twice or after the module has
--- loaded.
function Test.policy(policy: Test.Policy)
  local needs, trouble = Test.needs_of(policy)
  if needs == nil then
    error("test: policy " .. trouble, 2)
  end
  declare("policy", needs)
end

--- Says the running test is skipped: this host cannot check what it
--- exists to check -- a kernel that refuses the sandbox it is about,
--- say -- for `reason`, which the run prints beside its name. It does
--- not end the test: the test goes on, and returns where it would, as
--- in
---
---     if ruleset == nil then
---       Test.skip("no Landlock: " .. trouble)
---       return
---     end
---
--- A test that called it and then passed is counted skipped, not
--- passed, in the run's summary (`N skipped`), and no verdict is kept
--- of it, so it runs again on the next run and stands on no host; one
--- that failed is a failure like any other. A run held to sandboxing
--- (COSMIC_TEST_SANDBOX=1, COSMIC_SANDBOX=must or
--- COSMIC_CI_REQUIRE_SANDBOX=1, as CI's Linux legs are) fails a
--- skipped test, naming its reason: such a run proves the host checked
--- everything. So a test skips only where its platform could give what
--- this host refused (root nests a sandbox only two deep; a container
--- refuses user namespaces); where the platform itself has none -- no
--- user namespaces or Landlock off Linux -- there is nothing to check,
--- and it returns silently, a pass that stands, since the key's kernel
--- part names the platform. Nor does a test skip for a host tool or
--- artifact it lacks. Raises for a reason that is not a string or is empty and,
--- under a runner, for a call as the module loads rather than from a
--- test. Outside a runner it does nothing.
function Test.skip(reason: string)
  if not (reason is string) then error("test: skip's reason is not a string", 2) end
  if reason == "" then error("test: skip's reason is empty", 2) end
  local installed = runner_in(Test)
  if installed == nil then return end
  if installed.loaded ~= true then
    error("test: skip is called from a test as it runs, not as its module loads", 2)
  end
  local skipped = installed.skipped
  if skipped is function(string) then skipped(reason) end
end

return Test
