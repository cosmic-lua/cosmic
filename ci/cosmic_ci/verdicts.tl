--- The test verdicts a Linux leg keeps from one run to the next: the
--- directory of the file COSMIC_VERDICT_CACHE names
--- (build/shared_verdicts.tl in the candidate), which ci.yml restores
--- before the leg's suites and saves after them -- `verdicts.db`, the
--- native suite's, and the checked suite's on the one leg that runs it
--- (COSMIC_CI_CHECKED_SUITE), and `portable.db` beside it, the portable
--- suite's (cosmic_ci/orchestration.tl's `portable_verdicts`).
---
--- A file bounds itself at 8192 rows and thirty days, some 3 KB a row
--- (the lines each test hit, deflated, most of it), and SQLite keeps
--- the pages its bound frees: 32 MB where it is full. A row is keyed by
--- everything its test was given, the harness and the runtime among
--- them, which every change to build/ moves, so most of what a file
--- holds is under keys no later run reaches, and a leg's save of both
--- carried some 42 MB compressed each main push into the repository's
--- cache, which holds 10 GB for every entry, the zig caches among them.
--- So a leg that passed keeps only the verdicts its own run relied on
--- or reached (`trim`): the keys a later run of the same tree reaches
--- again, and no more. A run's suites stamp each row they stood on or
--- wrote with the time (`used_ns`), and take out a row whose test
--- failed.
---
--- A file none of whose rows the run reached -- the portable suite's,
--- on a run that has none -- keeps them all: that is no sign they are
--- dead. Like the suites, which never fail over the cache, a trim that
--- cannot read it never fails the leg (cosmic_ci/cache_trim.tl).

local CacheTrim = require("cosmic_ci.cache_trim")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")

local record Verdicts
end

--- The tables of build/shared_verdicts.tl's formats: `declared_v<n>`,
--- and the `verdicts_v<n>` observation-keyed runs shared, which no
--- run of today's tool stamps, so they go wherever the file is trimmed.
local tables: CacheTrim.Tables = { patterns = { "declared_v[0-9]*", "verdicts_v[0-9]*" },
  whole_unless_reached = true }

--- The caches in `dir`, each a `.db` file: not their logs, nor what
--- was set aside beside them, which `CacheTrim.file` removes.
local function caches(dir: string): {string}
  local listed, _ = Fs.list(dir)
  local out: {string} = {}
  for _, entry in ipairs(listed or {}) do
    if entry:sub(-3) == ".db" then out[#out + 1] = dir .. "/" .. entry end
  end
  table.sort(out)
  return out
end

--- `driver.tl verdicts-trim SINCE` in `env`: its exit status, and what
--- it says on standard output and on standard error. It trims every
--- cache in the directory of the file `env.COSMIC_VERDICT_CACHE` names
--- -- the directory ci.yml saves -- to the verdicts used since SINCE, in
--- Unix seconds (`CacheTrim.file`); nothing to do where the variable
--- names no file. Only a SINCE that is no count of seconds fails it
--- (2): a cache it cannot trim is said so, on standard error, and left,
--- or removed where it is no database.
function Verdicts.command(argv: {string}, env: {string:string}): integer, string, string
  local since = CacheTrim.since(argv)
  if since == nil then
    return 2, "", "verdicts-trim: SINCE must be Unix seconds\n"
  end
  local path = env.COSMIC_VERDICT_CACHE or ""
  if path:sub(1, 1) ~= "/" then
    return 0, "verdicts-trim: COSMIC_VERDICT_CACHE names no file ('" .. path ..
      "'); nothing to trim\n", ""
  end
  local found = caches(Fs.dirname(path))
  if #found == 0 then
    return 0, "verdicts-trim: " .. Fs.dirname(path) .. " holds no cache; nothing to trim\n", ""
  end
  local outs, errs: {string}, {string} = {}, {}
  for _, cache in ipairs(found) do
    local out, err = CacheTrim.file("verdicts-trim", cache, since, tables)
    outs[#outs + 1], errs[#errs + 1] = out, err
  end
  return 0, table.concat(outs), table.concat(errs)
end

--- `driver.tl verdicts-trim SINCE`, in the driver's environment
--- (`command`).
function Verdicts.trim_command(argv: {string}): integer
  local code, out, err = Verdicts.command(argv, Env.all())
  if out ~= "" then local _, _ = Fs.put(Fs.stdout, out) end
  if err ~= "" then local _, _ = Fs.put(Fs.stderr, err) end
  return code
end

return Verdicts
