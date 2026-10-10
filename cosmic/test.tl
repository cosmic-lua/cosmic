--- To write a test, put top-level `local function test_*` functions in a
--- `<name>_test.tl` file ([`cosmic.layout`]). This module is what such a
--- module tells `cosmic test` about itself: what its tests
--- are held to, and read beyond their default inputs, with `policy`:
---
---     local Test = require("cosmic.test")
---     Test.policy {
---       grants = { { path = "testdata/", letters = "r" } },
---       env = { "PATH" },
---     }
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
--- -- `Test.policy { ... }` or `Test.policy({ ... })`. Anything else -- a
--- value computed, a call inside a function, `policy` passed around
--- under another name -- fails the build, naming its line. When the
--- module runs under `cosmic test`, what the call was handed must be
--- what the build read, or the module fails to load. The call is once a
--- process, whichever module makes it: a test module never requires
--- another test module that calls `policy`. Every string is written
--- plainly, without escapes or long brackets, as the build reads it.
---
--- A policy is written in the fields of [`cosmic.sandbox`]'s [`Policy`]
--- -- see [`Test.policy`]. The harness translates it into the
--- [`Needs`] it stands for, which is what sandboxes the test and keys its
--- verdict.
---
--- A test that this host cannot give the sandbox it is about says so
--- with `skip`, which ends it: the run counts it skipped rather than
--- passed. What the host must have for the module to run at all is
--- declared as `requires` in a policy.

-- TODO: take `environment` and `program` from build.this_program, which
-- a test calls to say what a process of this program it starts needs
-- and how to start one past its launcher, once each can be read from the
-- source as `policy` is: another project's tests cannot reach build/.
-- (`confine` stays in build.confine: only the sandbox's own tests nest
-- one sandbox in another.)

-- The core's own `trace`, which cosmic.errors wraps: not cosmic.errors,
-- which would bring cosmic.sqlite and cosmic.store into every worker
-- (build/harness_epoch.tl's `library`).
local errors = require("cosmic.internal.errors")

local record Test
  --- What the tests of one module read beyond their default inputs, as
  --- the harness has it from the module's [`Test.policy`]: what
  --- [`Test.needs_of`] makes of one. Every field is optional.
  record Needs
    --- Paths of the tree, relative to its root, each a file or a
    --- directory and everything beneath it.
    reads: {string}
    --- Absolute paths outside the tree, each a file of the host's -- or
    --- /proc, or a path beneath it, which every worker is given and no
    --- key could hold by what it holds. A directory is refused: one
    --- written with a "/" after it fails the build, naming its line; one
    --- that is a directory on the host fails each test of the module,
    --- naming it, as does a path that is the tree's, or above it.
    --- Declare the files the tests read.
    host: {string}
    --- Environment variables beyond the pinned ones.
    env: {string}
    --- The loopback addresses the tests reach, each a dotted quad of
    --- 127/8, `127.a.b.c`, as a request names it: a sandboxed worker
    --- runs offline, with a loopback of its own that answers them, and
    --- is keyed like any other. No test reaches another host: what one
    --- answered, no key could hold, so a test that needs a service
    --- starts its own on 127.0.0.1. Any other name or address -- `::1`
    --- and `localhost` among them, whose answer turns on how the host
    --- sets up IPv6 -- and a spelling no request's host is (a port,
    --- brackets, a leading zero) are refused, naming this rule, as the
    --- build refuses them before the module runs.
    network: {string}
    --- What the tests need of the host, as `requires` of [`Policy`]
    --- says.
    requires: {string}
    --- Whether the tests read the tool itself, in the build directory, or the
    --- program running them, or start either: it gives them the program
    --- and nothing else -- not the store beyond their closure (`store`),
    --- nor a root of their own for what they start (`nests`).
    tool: boolean
    --- Whether the tests start this program only to run Lua in it: a
    --- `-e` chunk, past its launcher or by [`Proc.relaunch`] -- and a
    --- file `--standalone` too, where the test module requires at its top
    --- level the module that runs one. Like `tool`, it lets them run the
    --- program -- but not read it by its name -- and what a sandboxed
    --- worker runs is not the program but an artifact of the tests' import
    --- closure and what `cosmic -e` loads before the chunk runs, which
    --- every process they start, and each one those start, runs too: it
    --- carries no other module of the program, and no rows but theirs. So
    --- their key holds those, not every module the program carries, and
    --- an edit to another module the program carries runs them no more
    --- than one to a module of the tree outside their closure. A chunk
    --- that requires a module outside them, or a verb run that way --
    --- `--standalone` among them, unless the test module requires the
    --- module that runs it -- fails to find it: require the module at the
    --- top level of the test module, or declare `tool` in its place.
    --- Unsandboxed, nothing gives a worker that artifact, so what the
    --- program carries is not held to the closure. It is refused beside
    --- `tool`, `store`, `system` or `caches`: a host program, or a cosmic
    --- a cache holds, could start a program of its own.
    lua: boolean
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
    --- Whether the tests read the tree's projection, `cosmic.db` in its
    --- build directory (`o/cosmic.db`, as a grant names it), or
    --- the rows of modules of the tree outside their import closure.
    --- Without it, a sandboxed worker is given there the store
    --- of its module's import closure alone, which its key holds, and a
    --- `require` reaches only that closure; unsandboxed, the worker
    --- attaches that store in the projection's place, though what it
    --- starts reads the projection. A test that type-checks a snippet reads
    --- `cosmic.*` sources and declarations from that store: a module the
    --- snippet requires goes in the test's closure
    --- (`local type _ = require(...)`), or the test declares `store`.
    --- `tool` lets a test start the program, but not read its database
    --- through the descriptor a portable start keeps on it: that read is
    --- refused, whatever the test declares.
    store: boolean
    -- The descriptor is refused by core/check.h's `cosmic_checkfd`, and a
    -- sandboxed worker that does not declare `tool` has no name to open the
    -- program by.

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
    --- (a `#!/bin/sh` script) needs it. One that reads a file or two
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
    --- Named policies to join in: "system" (`system` of [`Needs`]),
    --- "cosmic" (`lua`; `tool` with the grant of o/bin beside it) and
    --- "proc" (the host file /proc, read, in `host` of [`Needs`]: the
    --- process information a stand-in or the runtime finds itself by).
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
    --- The user the tests run as. Refused: the harness chooses a worker's.
    user: integer
    --- The group the tests run as. Refused, as `user` is.
    group: integer
    --- The database the tests' program runs on. Refused: every worker runs
    --- on the sealed database the harness gives it.
    database: string
    --- What the tests need of the host that no other field says, by name
    --- from a closed table: `portable`, `root`, `unix_socket` (Unix stream
    --- socket creation), `path:<absolute path>` and
    --- `program:<name>`, and the Linux-class `sandbox`, `landlock:N`, `userns`,
    --- `nest`, `own_proc` and `proc`. The runner asks the host
    --- once, before any worker starts, and a module whose requirement is
    --- absent is not run: its tests are counted n/a where the platform never
    --- has it and skipped where this host lacks it. Nothing is inferred from
    --- the other fields. A name the table does not have or one written twice
    --- fails the build. A `path:` needs a `host` grant of that
    --- path and a `program:` the profile "system" and the variable PATH in
    --- `env`, so the worker can see what the runner found.
    requires: {string}
  end
end

--- What a test runner installed as `__runner` on this module's table
--- -- no part of its type -- to learn what `policy` stands for as the
--- module it runs loads, and to have a call once
--- that module has loaded refused: a table whose `handed` is called with
--- the [`Needs`] the policy stands for, whose `loaded` the runner sets once the
--- module has loaded, and whose `skipped` is called with the reason
--- each `skip` is given and answers the value `skip` raises to end the
--- test (nothing, to let it go on). Nil when none is installed.
local function runner_in(module: any): {string:any}
  if module is {string:any} then
    local installed = module.__runner
    if installed is {string:any} then return installed end
  end
  return nil
end

--- Where the one `policy` call came from, once it has come.
local called_at: string = nil

--- Where `policy` was called from, as the chunk and line a
--- traceback names -- its frame four up: this, `declare`, the call, its
--- caller -- or "an earlier call".
local function caller(): string
  local trace = errors.trace(nil, 4)
  return trace:match("\n%s*([^\n]-:%d+):") or "an earlier call"
end

--- Records that this module declared its policy, and hands the `needs` it
--- stands for to the runner: the place `policy` is held to being called once,
--- as the module loads.
local function declare(needs: Test.Needs)
  local installed = runner_in(Test)
  if installed ~= nil and installed.loaded == true then
    error("test: policy is called at the top of a test module, while it loads", 3)
  end
  if called_at ~= nil then
    error("test: policy is called once, and " .. called_at .. " called it already; " ..
        "a test module never requires another that calls it", 3)
  end
  called_at = caller()
  local handed = installed ~= nil and installed.handed or nil
  if handed is function(Test.Needs) then handed(needs) end
end

--- The fields of [`Policy`] and what each takes: a list of strings
--- ("list"), a table ("map"), a boolean ("flag"), a list of grants
--- ("grants") or the limits ("limits").
local POLICY_FIELDS <const>: {string:string} = {
  profiles = "list", grants = "grants", isolate = "list", promises = "list",
  connect = "list", loopback = "list", env = "list", set_env = "map",
  set_env_digests = "map", tmp = "flag", limits = "limits", user = "id", group = "id",
  database = "string", requires = "list",
}

local POLICY_FIELD_NAMES <const>: {string} = {
  "connect", "database", "env", "grants", "group", "isolate", "limits", "loopback", "profiles",
  "promises", "requires", "set_env", "set_env_digests", "tmp", "user",
}

local LIMIT_FIELDS <const>: {string:boolean} = {
  open_files = true, file_bytes = true, cpu_seconds = true, processes = true,
}

--- Why what [`Test.policy`] refuses today is refused: nothing holds a test to
--- it, so a declaration of it would claim more than the test is held to.
local NOT_YET <const> = "is not yet taken: a worker is held to, and a key made of, what a " ..
  "policy's paths, profiles and variables say, and nothing holds a test to this"

--- The three grants a policy writes for what [`Needs`] says as a field: the
--- store the worker is given, the private noexec scratch, and a host
--- cache written at its own name. [`Test.needs_of`] and the build's read
--- of a policy both take them as the field, and refuse other letters or
--- a `from` on their paths.
---
--- `o/` in a grant is a name of the policy language for the tree's build
--- directory, not a path in the tree: the harness gives what it names
--- from wherever build/paths.tl puts that directory, the sandbox at its
--- own fixed place. It stays `o/` for good: every module that declares
--- `store` or `tool` spells it, and every verdict key holds it, so
--- another name would move every such key and every such declaration for
--- no change in what a test is given.
local STORE_PATH <const> = "o/cosmic.db"
local NOEXEC_PATH <const> = "/noexec"
local STORE_FORM <const> = ".path o/cosmic.db is the store, granted " ..
  "{ path = \"o/cosmic.db\", letters = \"r\" } with no from"
local NOEXEC_FORM <const> = ".path /noexec is the private scratch the harness gives, " ..
  "granted { path = \"/noexec\", letters = \"rwc\" }: writable, never executable, with no from"
local CACHE_FORM <const> = ".path /cache/<name> is a host cache, granted " ..
  "{ path = \"/cache/<name>\", letters = \"rwxc\" } with no from"

--- The grant that turns the profile "cosmic" from `lua` into `tool`: the
--- directory o/bin the program is in, read and run.
local BIN_PATH <const> = "o/bin"
local BIN_FORM <const> = ".path o/bin is the directory the program is in, granted " ..
  "{ path = \"o/bin\", letters = \"rx\" } with no from, beside the profile \"cosmic\""

--- Why the profile "cosmic" alone, which is `lua`, is refused beside the
--- store, the system or a cache: a host program, or a cosmic a cache holds,
--- could start the program with no hold on what it loads.
local LUA_BESIDE <const> = "profiles: \"cosmic\" without the grant of o/bin holds the " ..
  "program to what the module requires, which is refused beside "
local LUA_FIX <const> = "; grant { path = \"o/bin\", letters = \"rx\" } beside the profile to " ..
  "run the program itself, whose key holds every module it carries"

--- The profiles a policy joins in, and the flag each stands for: "system"
--- is `system`; "cosmic" is `lua`, the program run from an artifact of the module's closure,
--- and `tool`, the program itself, where the grant of o/bin is made beside;
--- "proc" is the host path /proc, as the grant of it by hand is.
local PROFILE_FLAGS <const>: {string:string} = { system = "system", cosmic = "cosmic", proc = "proc" }

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
    elseif takes == "id" then
      if not value is integer then
        why = key .. " takes a whole number"
      elseif key == "user" then
        out.user = value
      else
        out.group = value
      end
    elseif takes == "string" then
      if value is string then out.database = value else why = key .. " takes a path" end
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
    elseif key == "requires" then
      out.requires, why = strings_of(key, value)
    else
      out.env, why = strings_of(key, value)
    end
    if why ~= "" then return nil, why end
  end
  return out, ""
end

-- TODO: hand the promises to the runner, which keeps them in the key, once
-- every module that starts a process declares "fork" (and the others it
-- makes): the filter runs on every worker, but until a test says what it
-- makes, a promise it does not make cannot be told from one it does. Doing
-- it now would add `promises = { "fork" }` to hundreds of modules.
--- The `needs` a policy stands for, or nil and why. The test is sandboxed
--- and keyed as that `needs` would have it: reads of the tree, host
--- files, the variables, loopback addresses, the program (profile
--- "cosmic": `lua`, run on a sealed database of the closure; with the grant of o/bin,
--- `tool`, itself), the system (profile "system") and nesting (promise
--- "nest"). What it cannot say is refused, naming the field, rather than
--- accepted as a declaration that moves no key: `isolate`, `set_env`,
--- `limits`, `database`, a grant of more than "r" or from another path, `tmp = false`.
--- `connect`, `set_env_digests`, `user` and `group` are refused outright,
--- since no test reaches a host but loopback, a digest holds no value to
--- set, and the harness chooses a worker's user.
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
  local caches: {string} = {}
  local flags: {string:boolean} = {}
  local bin = false
  for _, profile in ipairs(policy.profiles or {}) do
    local flag = PROFILE_FLAGS[profile]
    if flag == nil then
      return nil, "profiles: no profile " .. profile .. "; the profiles are cosmic, proc, system"
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
    local named = path:match("^/cache/(.*)$")
    if path == STORE_PATH then
      if letters ~= "r" or grant.from ~= nil then return nil, at .. STORE_FORM end
      out.store = true
    elseif path == BIN_PATH then
      if letters ~= "rx" or grant.from ~= nil then return nil, at .. BIN_FORM end
      bin = true
    elseif path == NOEXEC_PATH then
      if letters ~= "rwc" or grant.from ~= nil then return nil, at .. NOEXEC_FORM end
      out.noexec = true
    elseif named ~= nil then
      if letters ~= "rwxc" or grant.from ~= nil then return nil, at .. CACHE_FORM end
      if named == "" then return nil, at .. ".path /cache/ names no cache" end
      caches[#caches + 1] = named
    else
      if grant.from ~= nil then return nil, at .. ".from " .. NOT_YET end
      if letters ~= "r" then
        return nil, at .. ".letters \"" .. letters .. "\" " .. NOT_YET ..
          "; a test reads, with \"r\", what it declares"
      end
      local list = path:sub(1, 1) == "/" and host or reads
      list[#list + 1] = path
    end
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
  -- A module's own `database` is a limit decided for good: no test needs
  -- one, and the only coherent meaning is an overlay on the sealed database
  -- the harness gives every worker, which the core's `--database` cannot
  -- layer (doc/roadmap.md holds the shape, should one be wanted).
  if policy.database ~= nil then
    return nil, "database is refused: every worker runs on the sealed database the " ..
      "harness gives it, which a module cannot replace or add to"
  end
  if policy.tmp == false then
    return nil, "tmp = false " .. NOT_YET .. "; every test has a temporary directory today"
  end
  if policy.user ~= nil or policy.group ~= nil then
    return nil, (policy.user ~= nil and "user" or "group") .. " is refused: the harness " ..
      "chooses the user a worker runs as"
  end
  if bin and not flags.cosmic then
    return nil, "grants: .path o/bin is the program's directory, " ..
      "granted only beside the profile \"cosmic\"; add the profile, or drop the grant"
  end
  out.tool = flags.cosmic and bin or nil
  out.lua = flags.cosmic and not bin or nil
  if out.lua then
    local beside = out.store and "o/cosmic.db" or flags.system and "system" or
      #caches > 0 and "/cache/" .. caches[1] or nil
    if beside ~= nil then return nil, LUA_BESIDE .. beside .. LUA_FIX end
  end
  out.system, out.nests = flags.system, flags.nests
  if flags.proc then host[#host + 1] = "/proc" end
  if #reads > 0 then out.reads = reads end
  if #host > 0 then out.host = host end
  if #caches > 0 then out.caches = caches end
  for _, name in ipairs(policy.env or {}) do
    if name == "*" then
      return nil, 'env: a policy names each variable it passes through; no wildcard "*" in a policy'
    end
  end
  if #(policy.env or {}) > 0 then out.env = policy.env end
  if #(policy.loopback or {}) > 0 then out.network = policy.loopback end
  -- Only as written: which names are known and allowed is the build's to say
  -- (build.host_names, which this module cannot require), and the runner's to probe.
  if #(policy.requires or {}) > 0 then out.requires = policy.requires end
  return out, ""
end

--- Declares what this module's tests are held to and read beyond their
--- default inputs, in the fields of [`cosmic.sandbox`]'s [`Policy`]. The
--- harness translates the policy into the [`Needs`] it stands for
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
--- is the `needs` `{ system = true, reads = { "testdata" }, env = { "PATH" },
--- network = { "127.0.0.1" } }`. The build reads the call as data: one
--- table written out as a literal, once, at the top of the module. A
--- grant with a path of the tree is a read of it, an absolute
--- path a read of that host file; the profile "system" is `system`,
--- "cosmic" is `lua`, "proc" is the host file /proc (what the grant
--- `{ path = "/proc", letters = "r" }` is, and none on macOS, which has no
--- /proc: a host path not there is given and keyed as none); the promise "nest" is `nests`; `loopback` is
--- `network`. Four grants, written exactly so, are the fields they
--- stand for rather than reads: `{ path = "o/cosmic.db", letters = "r" }`
--- is `store = true`, `{ path = "/noexec", letters = "rwc" }` is
--- `noexec = true`, `{ path = "/cache/<name>", letters = "rwxc" }`
--- is `caches = { "<name>" }` for a cache [`Needs.caches`] names (the
--- variables that locate it are passed as they are for `caches`), and
--- `{ path = "o/bin", letters = "rx" }`, the directory the program is in,
--- makes `tool` of the "cosmic" profile and is refused without it, which
--- is `lua` without the grant: refused beside the store, the system or
--- a cache, as `lua` is. Each refuses other letters and a `from`.
--- "/noexec", "/cache/..." and "o/bin" are paths the test harness
--- reserves: no other grant is made at them. What
--- has no `needs` to stand for -- any other grant to write, run or
--- connect to, `isolate`, `limits`, `set_env`, `connect` -- fails the
--- build, naming the field. `requires` names what the host must have, which
--- the runner asks once before any worker starts; the build refuses a name
--- the table does not have and one written twice,
--- and a `path:` with no host grant of its path or a `program:`
--- without the profile "system" and `env = { "PATH" }`. Raises for a value no
--- [`Policy`] could be, for a second call in the process, naming where the
--- first was -- so a test module never requires another that calls `policy` --
--- and, under a runner, for a call once the module has loaded, as from
--- inside a test.
function Test.policy(policy: Test.Policy)
  local needs, trouble = Test.needs_of(policy)
  if needs == nil then
    error("test: policy " .. trouble, 2)
  end
  declare(needs)
end

--- Ends the running test as skipped: this host cannot check what it
--- exists to check -- a kernel that refuses the sandbox it is about,
--- say -- for `reason`, which the run prints beside its name. It raises
--- a value the runner takes for a skip rather than a failure, so
--- nothing after the call runs, as in
---
---     if ruleset == nil then
---       Test.skip("no Landlock: " .. trouble)
---     end
---     use(ruleset)
---
--- Code that catches errors around a call that may skip (`pcall`, a
--- coroutine's `resume`) must raise what it caught again where it is
--- not the test's own failure, or the test goes on past its skip: the
--- reason is recorded as the call is made, so a test that went on and
--- passed is still counted skipped, but one that went on and failed is
--- a failure. A test that skipped is counted skipped, not passed, in the
--- run's summary (`N skipped`), and no verdict is kept of it, so it runs
--- again on the next run and stands on no host. A test skips for what only
--- the running test can learn (a spawn the kernel refused with EPERM), or
--- where what it checks is not built yet, naming what it waits on in a
--- comment beside the skip. What a fact of the host alone says is no skip
--- and no early return: a module declares it as `requires` in its
--- [`Test.policy`] (`nest`, `proc`, `program:jq`, ...), and the runner
--- decides before a worker starts: the tests are counted not applicable
--- (`N n/a`) where the platform never has it, skipped where this host
--- lacks it, and run, under a key that holds the answer, where it is
--- present. A test that returns silently for a missing host tool or
--- platform feature passes having made no call to `assert`, which
--- `cosmic test` lists as having made no call to `assert` and a held run fails. Raises for a reason
--- that is not a string or is empty and, under a runner, for a call as
--- the module loads rather than from a test. Outside a runner it
--- returns and does nothing: no one there takes what it would raise for
--- a skip, so a raise would be a failure of a test that only cannot be
--- checked, and the caller that wants to stop returns itself.
function Test.skip(reason: string)
  if not (reason is string) then error("test: skip's reason is not a string", 2) end
  if reason == "" then error("test: skip's reason is empty", 2) end
  local installed = runner_in(Test)
  if installed == nil then return end
  if installed.loaded ~= true then
    error("test: skip is called from a test as it runs, not as its module loads", 2)
  end
  local skipped = installed.skipped
  if skipped is function(string): any then
    local ending = skipped(reason)
    if ending ~= nil then error(ending, 0) end
  end
end

--- Says that the running test passes having deliberately not checked,
--- for a reason of the run it can name (a fuzz property whose
--- `FUZZ_ITERS=0` draws no input): the test goes on, and `cosmic test`
--- counts it apart from a test that merely made no call to `assert`, which a
--- held run fails. Unlike a skip it keeps its verdict, since the pass is a
--- function of what its key holds. Reserved for the fuzz runner, which
--- `cosmic fix --check .` holds it to; a test that cannot check what it is
--- about skips or declares `requires`. Raises for a reason that is not a
--- string or is empty; outside a runner it does nothing.
--- @param reason what the run drew or read that left nothing to check
function Test.passed_unchecked(reason: string)
  if not (reason is string) then error("test: passed_unchecked's reason is not a string", 2) end
  if reason == "" then error("test: passed_unchecked's reason is empty", 2) end
  local installed = runner_in(Test)
  if installed == nil then return end
  local deliberate = installed.deliberate
  if deliberate is function(string) then deliberate(reason) end
end

return Test
