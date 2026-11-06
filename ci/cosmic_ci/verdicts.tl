--- The test verdicts a leg keeps from one run to the next: the
--- directory of the file COSMIC_VERDICT_CACHE names
--- (build/shared_verdicts.tl in the candidate), which ci.yml restores
--- before the leg's suites and saves after them. It holds `verdicts.db`,
--- the native suite's and the portable suite's alike;
--- `fixtures.db`, the sandboxed fixtures' (cosmic_ci/orchestration.tl's
--- `sandboxed_fixtures`); or, in ci.yml's checked jobs, which run no
--- other suite, `checked.db` alone, the checked suite's
--- (COSMIC_CI_CHECKED_SUITE; cosmic_ci/orchestration.tl's
--- `suite_verdicts`).
---
--- A file bounds itself at 32768 rows and thirty days, some 3.8 KB a
--- row live (the lines each test hit, deflated, most of it), and SQLite
--- keeps the pages its bound frees: 125 to 150 MB where it is full. A
--- leg's file, trimmed to what its run used, is not: some 8600 rows on
--- aarch64 and macOS, 12800 on alpine and 17000 on linux-x86_64 on a
--- push to main, which runs the whole portable suite. Locally nothing
--- trims but age and the bound (`cosmic cache trim verdicts PATH`). A row is keyed by
--- everything its test was given, the harness and the runtime among
--- them, which every change to build/ moves. So most of what a file
--- holds is under keys no later run reaches, and a leg's save of both
--- carried some 42 MB compressed each main push into the repository's
--- cache, which holds 10 GB in all, the zig caches among them. A leg
--- that passed therefore keeps only the verdicts its own run relied on
--- or reached (`trim`): the keys a later run of the same tree reaches
--- again, and no more. A run's suites stamp each row they stood on or
--- wrote with the time (`used_ns`), and take out a row whose test
--- failed.
---
--- A file none of whose rows the run reached (the fixtures', on a run
--- whose scope runs none) keeps them all: that is no sign they are dead.
--- Like the suites, which never fail over the cache, a trim that
--- cannot read it never fails the leg (cosmic_ci/cache_trim.tl).

local CacheTrim = require("cosmic_ci.cache_trim")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")

local record Verdicts
end

--- The caches in `dir`, each a `.db` file: not their logs, nor what
--- was set aside beside them, which the maintenance command removes.
local function caches(dir: string): {string}
  local listed, _ = Fs.list(dir)
  local out: mut {string} = {}
  for _, entry in ipairs(listed or {}) do
    if entry:sub(-3) == ".db" then out[#out + 1] = dir .. "/" .. entry end
  end
  table.sort(out)
  return out
end

--- Trims the sorted save set through the running driver. Any incomplete
--- file withholds the aggregate key; unreadable active files stay put.
function Verdicts.command(argv: {string}, env: {string:string}): CacheTrim.Command
  local whole = argv[1] == "whole"
  local since = CacheTrim.since(argv)
  if since == nil and not whole then
    return { code = 2, out = "", err = "verdicts-trim: SINCE must be bounded Unix seconds, or whole\n" }
  end
  local path = env["COSMIC_VERDICT_CACHE"] or ""
  if path:sub(1, 1) ~= "/" then
    return { code = 0, out = "verdicts-trim: COSMIC_VERDICT_CACHE names no file; nothing to trim\n", err = "" }
  end
  if path:find("\0", 1, true) then
    return { code = 2, out = "", err = "verdicts-trim: cache path contains NUL\n" }
  end
  local found = caches(Fs.dirname(path))
  if #found == 0 then
    return { code = 0, out = "verdicts-trim: no cache; nothing to trim\n", err = "" }
  end
  local trimmed = CacheTrim.run({ family = "verdicts", paths = found,
    since_ns = since, whole = whole }, env)
  return { code = 0, out = trimmed.out, err = trimmed.err }
end

--- Writes what a command said, and answers its status.
local function said(command: CacheTrim.Command): integer
  if command.out ~= "" then local _, _ = Fs.put(Fs.stdout, command.out) end
  if command.err ~= "" then local _, _ = Fs.put(Fs.stderr, command.err) end
  return command.code
end

--- `driver.tl verdicts-trim SINCE|whole`, in the driver's environment
--- (`command`).
function Verdicts.trim_command(argv: {string}): integer
  return said(Verdicts.command(argv, Env.all()))
end

return Verdicts
