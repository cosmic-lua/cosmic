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
--- sandbox left out -- /bin/sh, say, for a test that does not grant it
--- -- says so beneath that error, naming what to declare: a test that
--- starts a host program grants it by its absolute path.
---
--- The closure is what the build finds `require`d by a literal name,
--- or handed to `pcall(require, "<name>")`, anywhere in the module and
--- in each it requires. A name that is computed is refused when the
--- module is compiled; under `cosmic test`, a `require` of any other
--- module of the tree that gets past that (a `require` held in a
--- variable) fails, naming the module: require it by its literal name. The modules the core itself
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

-- The core's own `trace`, which cosmic.errors wraps: not cosmic.errors,
-- which would bring cosmic.sqlite and cosmic.store into every worker
-- (build/harness_epoch.tl's `library`).
local errors = require("cosmic.internal.errors")
-- The policy's terms, which the build's read of one shares: a leaf.
local TestPolicy = require("cosmic.internal.test_policy")
-- What `cosmic` and `environment` take: every worker loads these
-- already, and build/harness_epoch.tl's `library` names each.
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local type Child = require("cosmic.child")

local record Test
  --- What the tests of one module read beyond their default inputs, as
  --- the harness has it from the module's [`Test.policy`]: what
  --- [`Test.needs_of`] makes of one. Every field is optional.
  record Needs
    --- Paths of the tree, relative to its root, each a file or a
    --- directory and everything beneath it.
    mut reads?: {string}
    --- Absolute paths outside the tree, each a file of the host's -- or
    --- /proc, or a path beneath it, which every worker is given and no
    --- key could hold by what it holds. A directory is refused: one
    --- written with a "/" after it fails the build, naming its line; one
    --- that is a directory on the host fails each test of the module,
    --- naming it, as does a path that is the tree's, or above it.
    --- Declare the files the tests read. A program among them the tests
    --- may start, and it comes with what it needs to start: the loader
    --- and shared libraries a dynamic program names, and a script's
    --- interpreter, each keyed by its contents as a file named here is.
    --- What it opens by name once it runs (a name service, a locale,
    --- another program) is named here too, or `system` is declared.
    mut host?: {string}
    --- Environment variables beyond the pinned ones.
    mut env?: {string}
    --- The loopback addresses the tests reach, each a dotted quad of
    --- 127/8, `127.a.b.c`, as a request names it: a sandboxed worker
    --- runs offline, with a loopback of its own that carries them, and
    --- is keyed like any other. No test reaches another host: what one
    --- replied, no key could hold, so a test that needs a service
    --- starts its own on 127.0.0.1. Any other name or address -- `::1`
    --- and `localhost` among them, whose resolution turns on how the host
    --- sets up IPv6 -- and a spelling no request's host is (a port,
    --- brackets, a leading zero) are refused, naming this rule, as the
    --- build refuses them before the module runs.
    mut network?: {string}
    --- What the tests need of the host, as `requires` of [`Policy`]
    --- says.
    mut requires?: {string}
    --- Whether the tests read the tool itself, in the build directory, or the
    --- program running them, or start either: it gives them the program
    --- and nothing else -- not the store beyond their closure (`store`),
    --- nor a root of their own for what they start (`nests`).
    mut tool?: boolean
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
    mut lua?: boolean
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
    mut nests?: boolean
    --- Requests private writable scratch at COSMIC_TEST_NOEXEC whose
    --- files cannot execute. Ordinary scratch is unchanged. Reading,
    --- interpreting or copying the bytes elsewhere remains possible.
    --- Unsupported hosts skip these tests; a held-sandbox run fails them.
    mut noexec?: boolean
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
    --- In a sandboxed run, a test given the pure store (one that declares none of
    --- `store`, `store_text`, `lua` and `tool`) has the checker read the stub of a
    --- `cosmic.*` module it names with a top-level `local type _ = require(...)` (and of
    --- those that stub requires), which its key holds; no other text is kept: a
    --- test whose subject is a module's docs, places or uses declares `store_text`.
    --- `tool` lets a test start the program, but not read its database
    --- through the descriptor a portable start keeps on it: that read is
    --- refused, whatever the test declares.
    mut store?: boolean
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
    --- (a `#!/bin/sh` script) names the shell and the programs the
    --- launcher calls in `host`, as does any that starts programs of the
    --- host's it can name. One that reads a file or two
    --- of the system rather names them in `host`, which keys a file by
    --- its contents.
    mut system?: boolean
    --- Whether the outcome of the tests may turn on the processor's
    --- features. A verdict stands on a host of other features unless the
    --- module declares it, and a key that holds them stands on that
    --- processor's alone. A test that runs code the core itself selects by
    --- a feature ([`cosmic.vector`]'s VNNI int8 dot product) fails without
    --- it, naming the C function. A module may declare it as well where its
    --- subject is a vendored routine that dispatches (AES-NI, SHA-NI,
    --- carry-less multiply), whose output is the same on every path, to
    --- have a bug of one processor's path caught on that processor.
    mut cpu_features?: boolean
    --- Whether the tests read the text-derived rows of their closure's
    --- store: a module's source, the docs, uses, links, examples, catalog
    --- and places rows, the stubs, and the debug information of an
    --- imported module's bytecode (`store_text` of [`Test.policy`]).
    mut store_text?: boolean
    --- Host caches the tests, or the processes they start, write, by
    --- name: `"zig"` (the pinned zig, and zig's global and project
    --- caches) or `"bootstrap"` (the bootstrap cosmic, and the cores a
    --- portable cosmic extracts); the runner knows where each is on the
    --- host, and another name fails the build. Only for
    --- a cache whose contents never change a result -- content-addressed,
    --- there to save time: what a test reads or writes there enters no
    --- verdict's key. A sandboxed
    --- worker has each writable at its own path, with the variables that
    --- locate it. A cache the code under test keeps for itself (a directory
    --- under `out/`, say) is none of these: a sandboxed worker reads only
    --- its grants and writes only its scratch, so that cache is empty in
    --- every test and never hit. That is by design, since a cache that could
    --- change a result would make a verdict turn on what its key does not
    --- name. Give the code a seam instead (the cache's path as a parameter
    --- or an option) and hand each test a directory of its own `tmp`, or run
    --- the code under test with no cache.
    mut caches?: {string}
    --- Files of the project root's parent directory the tests read, each
    --- a path relative to that directory of plain names (none empty, `.` or
    --- `..`, and no `$` anywhere) with no trailing "/": for a project that lives in a directory of
    --- another (the CI driver's `ci/`) and reads that tree's files. A
    --- sandboxed worker has each, read-only, at its fixed place beside
    --- /tree ([`Test.parent`] names it), and its key holds the file's
    --- contents and its relative path, never where the project is. A file
    --- the host lacks fails the module's tests.
    mut parent?: {string}
    --- The most seconds each test of the module may run, where that is more
    --- than the run's own limit: `timeout` of [`Policy`].
    mut timeout?: integer
  end

  --- What the run of a test does that makes the same work cost more than
  --- a plain run does: what [`Test.mode`] returns. A test that holds one
  --- piece of work to a multiple of another ([`lang.speed`]) reads it to
  --- give each mode a limit of its own, since a mode need not slow both
  --- sides alike.
  record Mode
    --- The run checks types as the code runs (`cosmic test
    --- --check-types`): each checked call and narrowing costs more, so
    --- code that makes many costs more against code that makes few.
    types_checked: boolean
  end

  --- One path a test may reach, and how: [`test_policy.Grant`].
  type Grant = TestPolicy.Grant
  --- The resource limits of a policy: [`test_policy.Limits`].
  type Limits = TestPolicy.Limits
  --- What the tests of one module are held to: [`test_policy.Policy`],
  --- which a test module writes in place of [`Needs`].
  type Policy = TestPolicy.Policy

  --- The variables [`Test.environment`] passes on: those a process of
  --- this very program reads to run at all (caches, temporary directory,
  --- PATH, whether it may boot) and those that decide whether a `cosmic
  --- test` it runs sandboxes its workers. Every test's key pins them,
  --- as the runner reads this list: a test reads it and never changes it.
  mut runtime_environment: {string}

  --- How to start this very program ([`Test.cosmic`]): the command
  --- line and the options to hand [`Child.run`] or [`Child.start`].
  record Start
    --- The command line: the program and the words after it.
    mut argv: {string}
    --- The options to start it with.
    options: Child.Options
  end
end

--- What a test runner installed as `__runner` on this module's table
--- -- no part of its type -- to learn what `policy` stands for as the
--- module it runs loads, and to have a call once
--- that module has loaded refused: a table whose `handed` is called with
--- the [`Needs`] the policy stands for, whose `loaded` the runner sets once the
--- module has loaded, and whose `skipped` is called with the reason
--- each `skip` is given and returns the value `skip` raises to end the
--- test (nothing, to let it go on). Its `directory`, where it gives
--- one, is the running test's own directory ([`Test.environment`]).
--- Nil when none is installed.
local function runner_in(module: any): {string:any}?
  if module is {string:any} then -- checked: is_on_record
    local installed = module.__runner -- checked: map_field
    if installed is {string:any} then return installed end
  end
  return nil
end

local record Declared
  --- The files of the parent directory this module's policy declared
  --- ([`Needs.parent`]), by their relative paths.
  mut parents: mut {string:boolean}
  --- Where the one `policy` call came from, once it has come.
  mut called_at?: string
end

local declared: Declared = { parents = {} }

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
  if installed ~= nil and installed.loaded == true then -- checked: map_field
    error("test: policy is called at the top of a test module, while it loads", 3)
  end
  local called_at = declared.called_at
  if called_at ~= nil then
    error("test: policy is called once, and " .. called_at .. " called it already; " ..
        "a test module never requires another that calls it", 3)
  end
  declared.called_at = caller()
  declared.parents = {}
  for _, relative in ipairs(needs.parent or {}) do declared.parents[relative] = true end
  local handed = installed ~= nil and installed.handed or nil -- checked: map_field
  if handed is function(Test.Needs) then handed(needs) end -- untyped: call
end

local LIMIT_FIELDS <const>: {string:boolean} = {
  open_files = true, file_bytes = true, cpu_seconds = true, processes = true,
}

--- `value` as a list of strings, or nil and why, naming `field`.
local function strings_of(field: string, value: any): {string}?, string
  local out: mut {string} = {}
  if value is {any:any} then -- declared: key_type
    local count = 0
    local held: mut {integer:string} = {}
    for i, item in pairs(value) do -- checked: any_use
      if not (i is integer and item is string) then
        return nil, field .. " takes a list of strings"
      end
      count = count + 1
      held[i] = item
    end
    -- A list holds the keys 1 to its count and no others.
    for i = 1, count do
      local item = held[i]
      if item == nil then
        return nil, field .. " takes a list of strings"
      end
      out[#out + 1] = item
    end
    return out, ""
  end
  return nil, field .. " takes a list of strings"
end

--- `value` as a table of names to strings, or nil and why, naming `field`.
local function names_of(field: string, value: any): {string:string}?, string
  local out: mut {string:string} = {}
  if value is {any:any} then -- declared: key_type
    for k, v in pairs(value) do -- checked: any_use
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
local function grants_of(value: any): {Test.Grant}?, string
  local out: mut {Test.Grant} = {}
  if not value is {any} then return nil, "grants takes a list of grants" end -- checked: is_on_record
  for i, given in ipairs(value) do
    local at = "grants[" .. tostring(i) .. "]"
    if not given is {any:any} then return nil, at .. " takes a table" end -- declared: key_type
    local grant: Test.Grant = {}
    for key, field in pairs(given) do -- checked: any_use
      if not (key == "path" or key == "letters" or key == "from" or key == "calls" or key == "connect") then
        return nil, at .. " has no field " .. tostring(key) .. "; it has calls, connect, from, letters, path"
      end
      if not field is string then return nil, at .. "." .. tostring(key) .. " takes a string" end
      if key == "path" then
        grant.path = field
      elseif key == "letters" then
        grant.letters = field
      elseif key == "calls" then
        grant.calls = field
      elseif key == "connect" then
        grant.connect = field
      else
        grant.from = field
      end
    end
    out[i] = grant
  end
  return out, ""
end

--- `value` as a [`Policy`]'s limits, or nil and why.
local function limits_of(value: any): Test.Limits?, string
  local out: Test.Limits = {}
  if value is {any:any} then -- declared: key_type
    for key, field in pairs(value) do -- checked: any_use
      if not (key is string and LIMIT_FIELDS[key] == true and field is integer) then
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
local function policy_of(given: any): Test.Policy?, string
  if not given is {any:any} then -- declared: key_type
    return nil, "takes a table, got " .. type(given)
  end
  local out: Test.Policy = {}
  for key, value in pairs(given) do -- checked: any_use
    local takes = if key is string then TestPolicy.kind_of(key) else nil end
    if not (key is string) or takes == nil then
      return nil, TestPolicy.no_field(tostring(key))
    end
    local why = ""
    if takes == "flag" then
      if not value is boolean then
        why = key .. " takes true or false"
      elseif key == "cpu_features" then
        out.cpu_features = value
      elseif key == "store_text" then
        out.store_text = value
      else
        out.tmp = value
      end
    elseif takes == "id" then
      if not value is integer then
        why = key .. " takes a whole number"
      elseif key == "user" then
        out.user = value
      else
        out.group = value
      end
    elseif takes == "seconds" then
      if value is integer then out.timeout = value else why = TestPolicy.timeout_refused() end
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

-- TODO: hand the calls grants to the runner, which keeps them in the key, once
-- every module that starts a process declares "fork" (and the others it
-- makes): the filter runs on every worker, but until a test says what it
-- makes, a call it does not make cannot be told from one it does. Doing
-- it now would add `{ calls = "fork" }` to hundreds of modules.
--- The `needs` a policy stands for, or nil and why. The test is sandboxed
--- and keyed as that `needs` would have it: reads of the tree, host
--- files, the variables, loopback addresses, the program (profile
--- "cosmic": `lua`, run on a sealed database of the closure; with the grant of o/bin,
--- `tool`, itself), the system (profile "system") and nesting (the grant
--- `{ calls = "nest" }`). What it cannot say is refused, naming the field, rather than
--- accepted as a declaration that moves no key: `isolate`, `set_env`,
--- `limits`, `database`, a grant of more than "r" or from another path, `tmp = false`.
--- A `connect` grant, `set_env_digests`, `user` and `group` are refused outright,
--- since no test reaches a host but loopback, a digest holds no value to
--- set, and the harness chooses a worker's user.
--- The calls "fork", "jit" and "fattr" are accepted and change
--- nothing: no worker holds them yet.
---
--- Internal to the harness: it exists so that cosmic/test_policy_test.tl
--- can compare the runtime translation with the analyzer's; a test module
--- declares with [`Test.policy`].
--- @param given any What `policy` was handed, or the build read of it
--- @return Needs|nil The `needs` it stands for
--- @return string Why there is none, naming the field
function Test.needs_of(given: any): Test.Needs?, string
  local policy, why = policy_of(given)
  if policy == nil then return nil, why end
  local found, trouble = TestPolicy.declared(policy)
  if found == nil then return nil, trouble end
  local function listed(list: {string}): {string}?
    return if #list > 0 then list else nil end
  end
  local function flag(set: boolean): boolean?
    return if set then true else nil end
  end
  return {
    reads = listed(found.reads), host = listed(found.host), env = listed(found.env),
    network = listed(found.network), requires = listed(found.requires), caches = listed(found.caches),
    parent = listed(found.parent), tool = flag(found.tool), lua = flag(found.lua),
    nests = flag(found.nests), noexec = flag(found.noexec), store = flag(found.store),
    system = flag(found.system), cpu_features = flag(found.cpu_features),
    store_text = flag(found.store_text), timeout = found.timeout,
  }, ""
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
--- "cosmic" is `lua`, "proc" is the host path /proc (the grant
--- `{ path = "/proc", letters = "r" }`; on macOS, which has no /proc, a host
--- path not there is given and keyed as none); the grant `{ calls = "nest" }` is `nests`; `loopback` is
--- `network`. Five grants, written exactly so, are the fields they
--- stand for rather than reads: `{ path = "o/cosmic.db", letters = "r" }`
--- is `store = true`, `{ path = "/noexec", letters = "rwc" }` is
--- `noexec = true`, `{ path = "/cache/<name>", letters = "rwxc" }`
--- is `caches = { "<name>" }` for a cache [`Needs.caches`] names (the
--- variables that locate it are passed as they are for `caches`),
--- `{ path = "/parent/<file>", letters = "r" }` is `parent = { "<file>" }`,
--- a file of the project root's parent directory ([`Test.parent`] says where
--- the worker reads it), and
--- `{ path = "o/bin", letters = "rx" }`, the directory the program is in,
--- makes `tool` of the "cosmic" profile and is refused without it, which
--- is `lua` without the grant: refused beside the store, the system or
--- a cache, as `lua` is. Each refuses other letters and a `from`.
--- "/noexec", "/cache/...", "/parent/..." and "o/bin" are paths the test harness
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

--- Where this worker reads `relative`, a file of the project root's parent
--- directory that the module's policy declared with a grant
--- `{ path = "/parent/<relative>", letters = "r" }`: for the project `ci/`
--- of the main tree, `Test.parent(".github/workflows/ci.yml")` is the main
--- tree's workflow. A sandboxed worker has it read-only at a fixed place
--- beside /tree; an unsandboxed one has it in the real parent directory.
--- Raises for a path the module did not declare, which is a mistake of the
--- test, and outside a runner, where no parent is given.
---
---     local Test = require("cosmic.test")
---     Test.policy { grants = { { path = "/parent/bin/zig", letters = "r" } } }
---     local function test_names_the_parents_zig()
---       local path = Test.parent("bin/zig") -- "/tree-up/bin/zig" sandboxed
---     end
--- @param relative the file, as the grant spells it after "/parent/"
--- @return the path the worker reads it at
function Test.parent(relative: string): string
  if not (relative is string) then error("test: parent takes a string", 2) end
  if declared.parents[relative] ~= true then
    error(string.format("test: parent(%q) is not declared; grant " ..
        "{ path = \"/parent/%s\", letters = \"r\" } in Test.policy", relative, relative), 2)
  end
  local installed = runner_in(Test)
  local base = installed ~= nil and installed.parent or nil -- checked: map_field
  if not (base is string) then
    error("test: parent is given by a runner only, and this one gives none", 2)
  end
  return base .. "/" .. relative
end

--- What the run that runs this test does that makes work cost more than
--- in a plain run ([`Mode`]). A run that checks types keeps verdicts of
--- its own, so a verdict stands on the mode it was reached in. Outside a
--- runner, a plain run.
---
---     local Test = require("cosmic.test")
---     local LIMIT <const> = if Test.mode().types_checked then 100 else 50 end
--- @return the run's mode
function Test.mode(): Test.Mode
  local installed = runner_in(Test)
  return { types_checked = installed ~= nil and installed["types_checked"] == true }
end

--- Ends the running test as skipped: this host cannot check what it
--- exists to check -- a kernel that refuses the sandbox it is about,
--- say -- for `reason`, which the run prints beside its name. Under a
--- runner it raises a value the runner takes for a skip rather than a
--- failure, so nothing after the call runs; the checker does not know
--- that, so a `return` follows it where later code needs a value the
--- skip guards, as in
---
---     if ruleset == nil then
---       Test.skip("no Landlock: " .. trouble)
---       return
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
--- lacks it, and run, under a key that holds the result, where it is
--- present. A test that returns silently for a missing host tool or
--- platform feature passes having made no call to `assert`, which
--- `cosmic test` lists as having made no call to `assert` and a held run fails. Raises for an
--- empty reason and, under a runner, for a call as the module loads rather than from a test. Outside a runner it
--- returns and does nothing: no one there takes what it would raise for
--- a skip, so a raise would be a failure of a test that only cannot be
--- checked, and the caller that wants to stop returns itself.
function Test.skip(reason: string)
  if reason == "" then error("test: skip's reason is empty", 2) end
  local installed = runner_in(Test)
  if installed == nil then return end
  if installed.loaded ~= true then -- checked: map_field
    error("test: skip is called from a test as it runs, not as its module loads", 2)
  end
  local skipped = installed.skipped -- checked: map_field
  if skipped is function(string): any then
    local ending = skipped(reason) -- untyped: call
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
--- about skips or declares `requires`. Raises for an empty
--- reason; outside a runner it does nothing.
--- @param reason what the run drew or read that left nothing to check
function Test.passed_unchecked(reason: string)
  if reason == "" then error("test: passed_unchecked's reason is empty", 2) end
  local installed = runner_in(Test)
  if installed == nil then return end
  local deliberate = installed.deliberate -- checked: map_field
  if deliberate is function(string) then deliberate(reason) end -- untyped: call
end

--- Calls `fn` and checks that it raises: returns the message it raised, as
--- text, so a caller can check more of it. The test fails, naming what was
--- expected, when `fn` returns normally or the message lacks `says`, a
--- plain substring (a caller that needs a pattern matches the returned
--- message itself). A raised table is shown by its `tostring`, as `error`
--- would show it. A [`Test.skip`] inside `fn` is caught like any raise. The
--- call counts as a call to `assert`.
---
---     local why = Test.raises(function() Http.open(url, { timeout_ns = -5 }) end, "timeout_ns")
---     assert(why:find("negative", 1, true))
--- @param fn the call that must raise
--- @param says text the message must hold; none checks only that it raised
function Test.raises(fn: function(), says?: string): string
  local ok, err = pcall(fn)
  local wanted = says and (" naming " .. string.format("%q", says)) or ""
  assert(not ok, "test: expected a raise" .. wanted .. ", but the call returned")
  local message = tostring(err)
  assert(says == nil or message:find(says, 1, true) ~= nil,
    "test: expected a raise" .. wanted .. ", but it raised: " .. message)
  return message
end

Test.runtime_environment = {
  "HOME", "XDG_CACHE_HOME", "PATH", "TMPDIR", "COSMIC_PORTABLE_CACHE", "COSMIC_VERDICT_CACHE",
  "COSMIC_BUILD_CACHE", "COSMIC_BUILD_HOME", "COSMIC_AUTO_BOOT", "COSMIC_TEST_SANDBOX", "COSMIC_TEST_HELD",
}

--- The running test's own directory, as the runner names it, or nil
--- outside a runner.
local function test_directory(): string?
  local installed = runner_in(Test)
  local directory = if installed ~= nil then installed["directory"] else nil end
  if directory is string then return directory end
  return nil
end

--- The environment to start a process of this very program with, for a
--- test that would otherwise pass all of its own: each of
--- `runtime_environment` this process has, read by name, so the test
--- reads no more of the environment than these. TMPDIR is the exception
--- while a test runs: it names the test's own directory, so what the
--- process leaves there goes with the test, not into the host's
--- temporary directory. Outside a runner, TMPDIR is this process's own,
--- as the rest are. The core hands a child the directory its
--- coverage goes to whatever environment it is given.
---
---     local env = Test.environment()
---     env["COSMIC_TEST_SANDBOX"] = "0"
---     local started = Test.cosmic({ "test" }, { cwd = root, env = env, timeout_ns = Clock.seconds(60) })
---     local ran = assert(Child.run(started.argv, started.options))
--- @return a fresh table the caller may change
function Test.environment(): mut {string:string}
  local out: mut {string:string} = {}
  local own = test_directory()
  for _, name in ipairs(Test.runtime_environment) do
    if name == "TMPDIR" and own ~= nil then
      out[name] = own
    else
      local value = sys.getenv(name)
      if value ~= nil then out[name] = value end
    end
  end
  return out
end

--- The variables of this process's own start that no process it starts
--- may inherit: the portable startup test's handshake
--- (core/startup_test.tl's launches), which a child would wait on for
--- a signal no one sends it.
local handshake: {string} = {
  "COSMIC_PORTABLE_STARTUP_TEST_READY", "COSMIC_PORTABLE_STARTUP_TEST_GO",
}

--- How to start this very program with `args` after it, skipping its
--- launcher as `cosmic test` starts a worker: the core it runs on,
--- handed its artifact, database and startup contract directly
--- ([`Proc.relaunch`]), so starting it takes no shell and lands on no
--- other core. With no artifact to relaunch, the program is as
--- [`Proc.executable`] names it.
---
--- The options are a copy of `opts`, its tables left as they were except
--- `env` and `fds`. `env` is the caller's variables or, where it gives
--- none, the whole of this process's (a child given none inherits them,
--- and nothing can be added to an inherited environment), with the
--- relaunch's added and the startup test's handshake removed. `fds` is
--- the caller's with the relaunch's descriptors beside them; `opts.fds`
--- naming a number the relaunch hands the child its artifact or core as
--- raises.
---
--- Under `opts.policy` the command line is the one a policy start
--- takes: [`Child.start`] relaunches the program itself, so `argv` is
--- [`Proc.executable`] and `args`, `env` is left unset (the policy's own
--- `env` and `set_env` are the child's whole environment, so `opts.env`
--- beside a policy raises), and `fds` is the caller's alone.
---
--- What the launcher does, a program started this way never sees: it
--- makes no core cache under XDG_CACHE_HOME or HOME, nor checks the one
--- COSMIC_PORTABLE_CACHE names, stamps no core `.verified-`, and needs
--- no PATH, HOME or TMPDIR to start. A test of any of that starts the
--- program itself, by [`Proc.executable`].
---
---     local started = Test.cosmic({ "-e", "print(1)" }, { stdout = "capture", timeout_ns = Clock.seconds(30) })
---     local ran = assert(Child.run(started.argv, started.options))
--- @param args the words after the program's name
--- @param opts the options to start it with; none bounds it by the runner alone
--- @return the command line and options to hand [`Child.run`] or [`Child.start`]
function Test.cosmic(args: {string}, opts?: Child.Options): Test.Start
  -- -1 is Child.FOREVER, which a worker loading this cannot read: cosmic.child
  -- is not in its store before the test runs. A test's runner bounds it.
  local given: Child.Options = opts or { timeout_ns = -1 }
  -- A start with layers is held as one with a policy is.
  local held = given.policy ~= nil or given.layers ~= nil
  if held and given.env ~= nil then
    error("test: cosmic: env beside a policy: the policy's env and set_env are the " ..
        "child's whole environment", 2)
  end
  local relaunch: Proc.Relaunch?
  if not held then
    local found, _ = Proc.relaunch()
    relaunch = found
  end
  local argv: mut {string} = {}
  if relaunch ~= nil then
    for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
  else
    argv[1] = assert(Proc.executable())
  end
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local env: mut {string:string}?
  if not held then
    local fresh: mut {string:string} = {}
    for name, value in pairs(given.env or Env.all()) do fresh[name] = value end
    env = fresh
  end
  local fds: mut {integer:integer | string} = {}
  for number, fd in pairs(given.fds or {}) do fds[number] = fd end
  if relaunch ~= nil and env ~= nil then
    for name, value in pairs(relaunch.env) do env[name] = value end
    for number, fd in pairs(relaunch.fds) do
      if fds[number] ~= nil then
        error("test: cosmic: descriptor " .. tostring(number) ..
            " is the one the relaunch hands the program its artifact or core as", 2)
      end
      fds[number] = fd
    end
  end
  if env ~= nil then
    for _, name in ipairs(handshake) do env[name] = nil end
  end
  -- Field by field: a record has no copy that keeps its type. A field
  -- [`Child.Options`] gains is copied here too.
  return { argv = argv, options = {
    env = env, fds = fds, cwd = given.cwd, stdin = given.stdin, input = given.input,
    stdout = given.stdout, stderr = given.stderr, capture_limit = given.capture_limit,
    process_group = given.process_group, timeout_ns = given.timeout_ns, sandbox = given.sandbox,
    credentials = given.credentials, policy = given.policy, layers = given.layers, relay_log = given.relay_log,
  } }
end

return Test
