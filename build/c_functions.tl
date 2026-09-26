--- Every C function of the core that a test must enter: each one
--- `Coverage.native_functions` names in a `core/*.c` file. Every core
--- cosmic ships and tests with observes its own C, so a whole test run of
--- cosmic's own tree -- locally, on the release core, and in CI, on the
--- sanitized one too -- fails for any function no test enters, in its own
--- process or in one it starts (see `Coverage.children`), unless `exempt`
--- names it with the reason no test can, or `exempt_on` does for the
--- host the run is on.
---
--- A header's `static inline` helper is left out: every file that uses it
--- compiles its own copy and inlines it where it is small, so whether one
--- remaining copy's first line runs says nothing about the tests.

local Coverage = require("cosmic.coverage")
local Fs = require("cosmic.fs")
local String = require("cosmic.string")

local record c_functions
  --- How a run's hits measure up against every C function.
  record Tally
    --- The functions no test entered and none exempts, by `key_of`, sorted.
    unentered: {string}
    --- How many were entered.
    entered: integer
    --- How many are exempt and were not entered.
    exempted: integer
    --- How many functions there are.
    total: integer
    --- The exempt functions a test entered after all, by `key_of`, sorted:
    --- this core no longer needs their exemption, though another may.
    stale: {string}
  end
end

local read_only <const> = "the store's VFS is read-only: SQLite never writes, syncs, locks or sizes sectors through it"
local sandbox_only <const> =
  "runs only in a sandboxed child that made a user namespace and mapped its ids, which a host refusing unprivileged ones never starts"
local maps_ids <const> =
  "runs only in a sandboxed child that made a user namespace: where unshare is refused it is never entered, though on a " ..
  "host that lets unshare(CLONE_NEWUSER) through and refuses the uid_map write (AppArmor's restriction) it is"

--- The C functions no test can enter, by `key_of`, and why.
local exempt: {string: string} = {
  ["core/vfs.c:file_write"] = read_only,
  ["core/vfs.c:file_truncate"] = read_only,
  ["core/vfs.c:file_sync"] = read_only,
  ["core/vfs.c:file_lock"] = read_only,
  ["core/vfs.c:file_unlock"] = read_only,
  ["core/vfs.c:file_check_reserved"] = read_only,
  ["core/vfs.c:file_sector_size"] = read_only,
  ["core/syscalls.c:write_whole"] = maps_ids,
  ["core/syscalls.c:make_parents"] = sandbox_only,
  ["core/syscalls.c:make_link"] = sandbox_only,
  -- mirrored_mode is inlined into it on every core, so has no entry of
  -- its own; the checked core keeps this one out of line.
  ["core/syscalls.c:make_mirrored"] = sandbox_only,
  ["core/store.c:die_unreadable"] = "the store's own database cannot be read, and the process ends",
  ["core/crypto.c:mbedtls_psa_external_get_random"] = "mbedtls asks for randomness only to make keys, which the core never does",
  ["core/vfs_wrap.c:forward_access"] =
    "the observed VFS answers xAccess itself, and SQLite never asks the store's read-only one",
  ["core/vfs_wrap.c:forward_randomness"] =
    "SQLite seeds its randomness through the default VFS, never a wrapping one",
  ["core/sqlite.c:observed_sector_size"] =
    "the default VFS's files overwrite safely on power loss, so SQLite never asks their sector size; only a URI's psow=0 would, and no connection takes a URI",
  ["core/compress.c:bz_internal_error"] =
    "libbzip2 calls it only when one of its own internal assertions fails, which no input reaches",
  ["core/strnlen.c:strnlen"] = "a host libc's own strnlen can win the link; bin/zig build boot's strnlen check covers the core's",
}

--- The C functions no test can enter on one kind of host, by its
--- uname(2) sysname and then by `key_of`, and why: another host's run
--- still holds them to being entered.
local exempt_on: {string: {string: string}} = {
  Darwin = {
    -- TODO: drop these once Darwin's child starts through posix_spawn
    -- (the TODO at core/syscalls.c's fork), or once a child's hits reach
    -- the parent some other way, such as its own report before exec.
    ["core/syscalls.c:spawn_child"] = "Darwin's child is a fork, so the flags it sets land in its own copy of the " ..
      "parent's memory, which it never reports; Linux's clone(CLONE_VM) child's reach the parent",
    ["core/syscalls.c:report_child_error"] = "called only from spawn_child, whose child's hits never reach the parent " ..
      "on macOS (see spawn_child)",
  },
}

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
function c_functions.tally(functions: {Coverage.Function}, hits: Coverage.Hits,
                           sources?: {string: {string}}, sysname?: string): c_functions.Tally
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
                                     total = #keys, stale = {} }
  for _, key in ipairs(keys) do
    if entered[key] then
      tally.entered = tally.entered + 1
      if exempts(key) then
        tally.stale[#tally.stale + 1] = key
      end
    elseif exempts(key) then
      tally.exempted = tally.exempted + 1
    else
      tally.unentered[#tally.unentered + 1] = key
    end
  end
  return tally
end

return c_functions
