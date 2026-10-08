--- Every C function of the core that a test must enter: each one
--- [`Coverage.native_functions`] names in a `core/*.c` file. Every core
--- cosmic ships and tests with observes its own C, so a whole test run of
--- cosmic's own tree -- locally, on the release core, and in CI, on the
--- sanitized one too -- fails for any function no test enters, in its own
--- process or in one it starts (see [`Coverage.children`]), unless `exempt`
--- names it with the reason no test can, or `exempt_on` does for the
--- host the run is on. A function whose named prerequisite the runner
--- found absent is reported unavailable on that host alone.
---
--- A header's `static inline` helper is left out: every file that uses it
--- compiles its own copy and inlines it where it is small, so whether one
--- remaining copy's first line runs says nothing about the tests.

local Coverage = require("cosmic.coverage")
local Fs = require("cosmic.fs")
local String = require("cosmic.string")
local host_names = require("build.host_names")
local type host_requires = require("build.host_requires")

local record c_functions
  --- How a run's hits measure up against every C function.
  record Tally
    --- The functions no test entered and none exempts, by [`key_of`], sorted.
    unentered: {string}
    --- How many were entered.
    entered: integer
    --- How many are exempt and were not entered.
    exempted: integer
    --- How many functions there are.
    total: integer
    --- The exempt functions a test entered after all, by [`key_of`], sorted:
    --- this core no longer needs their exemption, though another may.
    stale: {string}
    --- The functions this host cannot enter, each with its missing
    --- requirement and the probe's reason. An entered function stays entered.
    unavailable: {string}
  end
end

local read_only <const> = "the store's VFS is read-only: SQLite never writes, syncs, locks or sizes sectors through it"
local forwarded <const> = "passes to the base VFS a call SQLite never makes on the store's read-only database"
local sandbox_only <const> =
  "runs only in a sandboxed child that made a user namespace and mapped its ids, which a host refusing unprivileged ones never starts"
local sandbox_started <const> =
  "runs only in the parent of a sandboxed child that started, which a host refusing unprivileged user namespaces " ..
  "never starts"
local init_only <const> =
  "runs only as a sandbox's init, pid 1 of an unveiled child's pid namespace, which the core executes afresh with " ..
  "an empty environment, so with no directory to report its coverage to"
local maps_ids <const> =
  "runs only in a sandboxed child that made a user namespace: where unshare is refused it is never entered, though on a " ..
  "host that lets unshare(CLONE_NEWUSER) through and refuses the uid_map write (AppArmor's restriction) it is"
local connector_only <const> =
  "runs only in the native connector, whose filter forbids coverage files and whose inherited descriptors are " ..
  "closed: the connector's live kernel probes and TCP handoff tests enter it, but it cannot report coverage"

--- The C functions no test can enter, by [`key_of`], and why.
local exempt: {string: string} = {
  ["core/connector.c:connector_attack"] = connector_only,
  ["core/connector.c:connector_attack_scratch"] = connector_only,
  ["core/connector.c:connector_begin"] = connector_only,
  ["core/connector.c:connector_decode"] = connector_only,
  ["core/connector.c:connector_public_allowed"] = connector_only,
  ["core/connector.c:connector_public_connect"] = connector_only,
  ["core/connector.c:connector_serve"] = connector_only,
  ["core/connector.c:connector_settle"] = connector_only,
  ["core/connector.c:connector_within"] = connector_only,
  ["core/connector.c:connector_connect"] = connector_only,
  ["core/connector.c:connector_hold"] = connector_only,
  ["core/connector.c:connector_loop"] = connector_only,
  ["core/connector.c:connector_now"] = connector_only,
  ["core/connector.c:connector_reply"] = connector_only,
  ["core/vfs.c:file_write"] = read_only,
  ["core/vfs.c:file_truncate"] = read_only,
  ["core/vfs.c:file_sync"] = read_only,
  ["core/vfs.c:file_lock"] = read_only,
  ["core/vfs.c:file_unlock"] = read_only,
  ["core/vfs.c:file_check_reserved"] = read_only,
  ["core/vfs.c:file_sector_size"] = read_only,
  ["core/syscalls.c:write_whole"] = maps_ids,
  ["core/syscalls.c:map_ids"] = maps_ids,
  ["core/syscalls.c:make_parents"] = sandbox_only,
  ["core/syscalls.c:make_link"] = sandbox_only,
  ["core/syscalls.c:loopback_up"] = sandbox_only,
  ["core/syscalls.c:drop_capabilities"] = sandbox_only,
  ["core/syscalls.c:place_proc"] = sandbox_only,
  ["core/syscalls.c:build_root"] = sandbox_only,
  ["core/syscalls.c:raise_descriptor"] = sandbox_only,
  ["core/syscalls.c:start_init"] = sandbox_only,
  ["core/syscalls.c:start_program"] = sandbox_only,
  ["core/syscalls.c:end_sandbox_init"] = sandbox_started,
  ["core/syscalls.c:cosmic_sandbox_init"] = init_only,
  ["core/syscalls.c:descriptor_kind"] = init_only,
  -- mirrored_mode is inlined into it on every core, so has no entry of
  -- its own; the checked core keeps this one out of line.
  ["core/syscalls.c:make_mirrored"] = sandbox_only,
  ["core/syscalls.c:cosmic_mountinfo_local_flock"] = "a release core calls it only for a file on NFS, which no " ..
    "test's host has; the checked core's testing table reaches it (`mountinfo_local_flock`), and its run enters it",
  ["core/store.c:die_unreadable"] = "the store's own database cannot be read, and the process ends",
  ["core/crypto.c:mbedtls_psa_external_get_random"] = "mbedtls asks for randomness only to make keys, which the core never does",
  ["core/vfs.c:vfs_delete"] = forwarded,
  ["core/vfs.c:vfs_access"] = forwarded,
  ["core/vfs.c:vfs_randomness"] = "SQLite seeds its randomness through the default VFS, never a wrapping one",
  ["core/vfs.c:vfs_sleep"] = forwarded,
  ["core/vfs.c:vfs_last_error"] = forwarded,
  ["core/compress.c:bz_internal_error"] =
    "libbzip2 calls it only when one of its own internal assertions fails, which no input reaches",
}

--- The C functions no test can enter on one kind of host, by its
--- uname(2) sysname and then by [`key_of`], and why: another host's run
--- still holds them to being entered.
local exempt_on: {string: {string: string}} = {
  Linux = {},
  Darwin = {
    -- Every Linux core, the checked one too, is static musl, whose printf
    -- measures each `%s` with the core's strnlen, so a Linux run holds it.
    ["core/strnlen.c:strnlen"] = "libSystem's printf measures a `%s` with its own strnlen, never the core's, " ..
      "leaving the core's to c-ares's ares_strnlen, which no test need reach; bin/zig build boot's strnlen " ..
      "check covers it",
    ["core/promises.c:cosmic_promises_apply"] = "Darwin has no seccomp: spawn_program refuses a start with " ..
      "promises, ENOSYS, before any child could install a filter; a Linux run enters it " ..
      "(core/promises_child_test.tl)",
  },
}

--- The host requirement without which a function's body cannot be
--- reached. Unlike an exemption, this keeps its obligation on every
--- host where the requirement is present or cannot be determined.
local prerequisites: {string: string} = {
  ["core/socket.c:reach_from"] = "unix_socket",
  ["core/store.c:cosmic_store_holds_descriptor"] = "path:/proc/thread-self/children",
  ["core/syscalls.c:first_child"] = "path:/proc/thread-self/children",
  ["core/syscalls.c:plan_limit"] = "path:/proc/thread-self/children",
  ["core/syscalls.c:thread_count"] = "path:/proc/thread-self/children",
  ["core/syscalls.c:unaccounted_descriptor"] = "path:/proc/thread-self/children",
}

--- Each function's required host name, copied so a caller cannot change
--- the obligations [`tally`] holds. The runner probes them before workers
--- start, and the whole-tree check requires a CI leg to promise each.
function c_functions.prerequisites(): {string: string}
  local out: {string: string} = {}
  for key, name in pairs(prerequisites) do out[key] = name end
  return out
end

--- Known absent prerequisites, with their reasons. `promises` is the
--- held run's list, nil for an unheld one: no promised absence, refused
--- name or failed probe can remove a function's obligation.
function c_functions.unavailable(answers: {host_requires.Answer}, promises?: {string}): {string: string}
  local out: {string: string} = {}
  for _, answer in ipairs(answers) do
    if (answer.kind == "skipped" or answer.kind == "na") and
        (promises == nil or not host_names.promised(promises, answer.name)) then
      out[answer.name] = "requires " .. answer.name .. ": " .. answer.why
    end
  end
  return out
end

--- How `function` is named in `exempt` and in a failure.
local function key_of(fn: Coverage.Function): string
  return fn.path .. ":" .. fn.name
end

--- Whether `here`, one file's hits, holds a line from `first` up to but
--- not including `stop` (nil for the end of the file).
local function hit_between(here: {integer: boolean}, first: integer, stop: integer | nil): boolean
  for line in pairs(here) do
    if line >= first and (stop == nil or line < stop) then return true end
  end
  return false
end

--- The line after the one a function beginning on `first` ends on, in
--- `lines`, its file's source: the tree's C layout closes a function
--- with a `}` alone at the start of a line, or on its first line when
--- that line opens and closes it. Nil when no such line follows.
local function after_end(lines: {string}, first: integer): integer | nil
  local text = lines[first]
  if text ~= nil and text:match("^%S.*{.*}%s*$") ~= nil then return first + 1 end
  for at = first + 1, #lines do
    if lines[at]:match("^}") ~= nil then return at + 1 end
  end
  return nil
end

--- The line `name` is defined on in `lines`, its file's source, or nil:
--- the tree's C layout starts a definition at the start of a line and
--- writes `name (`, and a declaration that reaches `;` before `{` is only
--- a prototype.
local function definition(lines: {string}, name: string): integer | nil
  local spaced = " " .. name .. " ("
  local pointed = "*" .. name .. " ("
  for at, text in ipairs(lines) do
    if text:match("^[%a_]") ~= nil and
        (text:find(spaced, 1, true) ~= nil or text:find(pointed, 1, true) ~= nil) then
      for ahead = at, #lines do
        local rest = lines[ahead]
        if rest:find("{", 1, true) ~= nil then return at end
        if rest:match(";%s*$") ~= nil then break end
      end
    end
  end
  return nil
end

--- The lines of each C file `functions` names, read under `root`, by
--- path; a file that cannot be read is left out.
function c_functions.sources(root: string, functions: {Coverage.Function}): {string: {string}}
  local sources: {string: {string}} = {}
  for _, fn in ipairs(functions) do
    if sources[fn.path] == nil and fn.path:match("%.c$") ~= nil then
      local text, _ = Fs.read(root .. "/" .. fn.path)
      if text ~= nil then
        local lines: {string} = {}
        for line in String.lines(text) do lines[#lines + 1] = line end
        sources[fn.path] = lines
      end
    end
  end
  return sources
end

--- Measures `hits`, a run's hits, against `functions`, every C function
--- of the core. A function was entered when a hit lands anywhere in its
--- body: where the compiler inlines a call, the body runs without the
--- function's own first block, so its first line alone would miss it.
---
--- `sources` holds each file's lines, by path, which say where a body
--- begins and ends: its definition, found by name, through its closing
--- brace. The line `functions` gives is where the function's first
--- instruction came from, which is a helper's when the helper was
--- inlined at the top of it. Without a file's source, a body is taken to
--- run from that line up to the next function's, which overreaches when
--- the function after it was inlined everywhere and so is not among
--- `functions` at all.
---
--- `sysname`, the host's uname(2) sysname, adds that host's own
--- exemptions (`exempt_on`) to those every host shares.
--- `unavailable` holds only prerequisites actually found absent, with
--- their reasons: never an unknown answer or one a held run promised.
function c_functions.tally(functions: {Coverage.Function}, hits: Coverage.Hits,
                           sources?: {string: {string}}, sysname?: string,
                           unavailable?: {string: string}): c_functions.Tally
  local here_exempt = sysname ~= nil and exempt_on[sysname] or {}
  local function exempts(key: string): boolean
    return exempt[key] ~= nil or here_exempt[key] ~= nil
  end
  local starts: {string: {integer}} = {}
  for _, fn in ipairs(functions) do
    local lines = starts[fn.path]
    if lines == nil then
      lines = {}
      starts[fn.path] = lines
    end
    lines[#lines + 1] = fn.line
  end
  for _, lines in pairs(starts) do table.sort(lines) end
  local entered: {string: boolean} = {}
  for _, fn in ipairs(functions) do
    if fn.path:match("%.c$") ~= nil then
      local key = key_of(fn)
      local here = hits[fn.path]
      local source = sources ~= nil and sources[fn.path] or nil
      local first = fn.line
      local stop: integer | nil = nil
      if source ~= nil then
        first = definition(source, fn.name) or fn.line
        stop = after_end(source, first)
      else
        for _, line in ipairs(starts[fn.path]) do
          if line > fn.line then
            stop = line
            break
          end
        end
      end
      entered[key] = entered[key] == true or
        (here ~= nil and hit_between(here, first, stop))
    end
  end
  local keys: {string} = {}
  for key in pairs(entered) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local tally: c_functions.Tally = { unentered = {}, entered = 0, exempted = 0,
    total = #keys, stale = {}, unavailable = {} }
  for _, key in ipairs(keys) do
    if entered[key] then
      tally.entered = tally.entered + 1
      if exempts(key) then
        tally.stale[#tally.stale + 1] = key
      end
    elseif exempts(key) then
      tally.exempted = tally.exempted + 1
    elseif prerequisites[key] ~= nil and unavailable ~= nil and unavailable[prerequisites[key]] ~= nil then
      tally.unavailable[#tally.unavailable + 1] = key .. ": " .. unavailable[prerequisites[key]]
    else
      tally.unentered[#tally.unentered + 1] = key
    end
  end
  return tally
end

return c_functions
