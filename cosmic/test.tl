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
  --- What each field of `Needs` takes; see below.
  fields: {string:string}
  --- What `network_trouble` says of `network = true`.
  any_host_refusal: string

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
    --- rule (`network_trouble`).
    network: {string}
    --- Whether the tests hand a process they start what no observation
    --- accounts for: a descriptor, a path of /proc. Starting one needs no
    --- declaration: a sandboxed worker holds every process it starts to
    --- what the module declares, and where a worker runs unsandboxed
    --- (macOS, a host refusing user namespaces) a test that starts one
    --- never stands, and the audit asks nothing of it.
    -- TODO: audit what a process an unsandboxed worker starts reads, once
    -- a host without spawn's sandbox (macOS: core/process.h's `unveil` is
    -- Linux's alone) can observe it: today such a read is seen by no
    -- audit but a sandboxed run's, where it finds nothing.
    processes: boolean
    --- Whether the tests read the tool itself, `o/bin/cosmic`, or the
    --- program running them, or start either: it gives them the program
    --- and nothing else -- not the store beyond their closure (`store`),
    --- nor a root of their own for what they start (`nests`).
    tool: boolean
    --- Whether the tests confine a process in a root of its own: a
    --- `sandbox` that unveils (`cosmic.child`), or a `cosmic test` they
    --- start whose workers are sandboxed. A sandboxed worker whose
    --- module does not declare it is held by a Landlock ruleset, under
    --- which the kernel refuses every mount, and a root of its own is
    --- made of mounts: such a start is refused, naming this field, and
    --- the test fails, where otherwise it could pass having confined
    --- nothing. The tests of the sandbox itself declare it. Off the
    --- Linux sandbox -- on macOS, or unsandboxed under
    --- COSMIC_TEST_KEY=declared -- no worker is held, so a test that
    --- confines without it passes there and fails on a Linux leg.
    nests: boolean
    --- Whether the tests read the tree's projection, `o/cosmic.db`, or
    --- the rows of modules of the tree outside their import closure.
    --- Without it, a sandboxed worker is given at o/cosmic.db the store
    --- of its module's import closure alone, which its key holds, and
    --- a `require` reaches only that closure; and unless the module
    --- declares `store`, every other lookup in the store is
    --- held to it too (`build.test_worker`'s `hold_store`), from the
    --- module's load until the worker ends: `Store.bytecode`,
    --- `Store.source` or `Store.requires` of a module of the tree
    --- outside the closure, or the store's searcher called by hand,
    --- answers none, and `Store.databases()`, whose handles read every
    --- module's rows, raises -- sandboxed or not, since without the
    --- hold such a read reaches the program's own database, or the
    --- whole projection, which no key of the test holds. Among them
    --- are the `Store.source` reads of `cosmic.*` sources and
    --- declarations that build/teal.tl's `standard` makes when a test
    --- type-checks a snippet: a module the snippet requires goes in the
    --- test's closure (`local type _ = require(...)`) or the test
    --- declares `store`. `Store.meta` is not held (the TODO on
    --- `hold_store`). The descriptor a portable start keeps on the
    --- program is refused to every binding (core/check.h's
    --- `cosmic_checkfd`), and a sandboxed worker that does not declare
    --- `tool` has no name to open the program by.
    store: boolean
    --- Whether the tests, or the processes they start, read the system's
    --- own programs and files: /usr, /bin, /sbin, /lib and its kin, and
    --- /etc, as a host program or its dynamic loader needs them -- a
    --- shell, `sleep`, a compiler's headers, the zone database. Without
    --- it a sandboxed worker has none of them, only /proc and the
    --- devices every program takes for granted (/dev/null, /dev/zero,
    --- /dev/urandom), and its key holds nothing of which packages the
    --- host has installed or which system it says it is: a verdict that
    --- stood on one host stands on another of the same kernel and
    --- processor. A test that starts this program only past its launcher
    --- -- its core, relaunched (build.this_program's
    --- `program`) -- needs none; one that runs the launcher itself
    --- (o/bin/cosmic, `#!/bin/sh`) needs it. One that reads a file or two
    --- of the system rather names them in `host`, which keys a file by
    --- its contents.
    system: boolean
    --- Host caches the tests, or the processes they start, write, by
    --- name: `"zig"` (the pinned zig, and zig's global and project
    --- caches) or `"bootstrap"` (the bootstrap cosmic, and the cores a
    --- portable cosmic extracts); the runner knows where each is on the
    --- host (`build.caches`), and another name (`build.cache_names`)
    --- fails the build. Only for
    --- a cache whose contents never change a result -- content-addressed,
    --- there to save time: what a test reads or writes there enters no
    --- verdict's key, and the audit asks nothing more of it. A sandboxed
    --- worker has each writable at its own path, with the variables that
    --- locate it.
    caches: {string}
  end
end

--- What each field of `Needs` takes: a list of strings ("list") or a
--- boolean ("flag"). The build holds a declaration in the source to the
--- same table (`build.analyzer`).
Test.fields = {
  reads = "list", host = "list", env = "list", network = "list",
  processes = "flag", tool = "flag", nests = "flag", store = "flag", system = "flag",
  caches = "list",
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

--- The rule a `network` declaration is held to, as a refusal names it.
local LOOPBACK_ONLY <const> = "network takes loopback addresses 127.a.b.c only: no test " ..
  "reaches another host, whose answer no key holds (::1 and localhost included), so one " ..
  "that needs a service starts its own on 127.0.0.1"

Test.any_host_refusal = "network = true: " .. LOOPBACK_ONLY

--- Why `host` may not be declared in `network`, or "" when it may: a
--- dotted quad of 127/8, `127.a.b.c`, each part decimal, 0 to 255,
--- with no leading zero. Strict: a name a lookup might answer
--- elsewhere, `localhost` or `::1`, a shortened or octal spelling,
--- `0.0.0.0`, a range or `*` is none; nor is a spelling no request's
--- host is (`127.0.0.1:8080`, whose port a request's host leaves out).
function Test.network_trouble(host: string): string
  local refused = string.format("network %q: %s", host, LOOPBACK_ONLY)
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a ~= "127" then return refused end
  for _, part in ipairs({ b, c, d }) do
    if #part > 3 or (#part > 1 and part:sub(1, 1) == "0") or tonumber(part) > 255 then
      return refused
    end
  end
  return ""
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
    if key == "network" and field_value == true then return Test.any_host_refusal end
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
        if key == "network" and item is string then
          local refused = Test.network_trouble(item)
          if refused ~= "" then return refused end
        end
      end
    end
  end
  return ""
end

--- Where `needs` was called from, as the chunk and line a traceback
--- names -- its frame three up: this, `needs`, its caller -- or "an
--- earlier call".
local function caller(): string
  local trace = errors.trace(nil, 3)
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
