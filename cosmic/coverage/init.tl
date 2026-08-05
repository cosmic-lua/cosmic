--- Line coverage collection for cosmic programs.
--- Counts executed (source, line) pairs via a line hook and dumps the
--- counts as a Lua-serialized .cov file for `cosmic --coverage-report`
--- to merge and render. When the runtime carries the C collector
--- (cosmo.cov), the hook runs in C at a small fraction of the per-line
--- cost; otherwise a Lua debug hook does the same accounting.
---
--- The CLI arms collection automatically when the COSMIC_COVERAGE
--- environment variable names a directory: the hook starts before the
--- script loads and a .cov file is written there when the script
--- finishes (including via os.exit). `cosmic --test` rewrites the
--- variable to a per-test directory, so `cosmic --make coverage` gets one
--- .cov file per process, safe under parallel make.
---
--- start/stop nest: a script that exercises coverage itself while
--- running under coverage leaves the outer collection running.
local codec = require("cosmic.codec")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local time = require("cosmic.time")

--- The runtime's C line-hit collector (require("cosmo.cov")), when
--- this runtime carries one. Same attribution as the Lua hook below —
--- chunks keyed by their debug source, values line -> hit count — at a
--- small fraction of the per-line cost.
local record CCov
  start: function()
  stop: function()
  running: function(): boolean
  arm: function(thread: thread)
  snapshot: function(): {string: {integer: integer}}
  reset: function()
end

--- Detected through package.preload, where the interpreter registers
--- its modules at boot: a runtime without the binding never pays a
--- searcher walk for it, and the require below then resolves from
--- preload without touching the filesystem. Dynamic (not
--- require("cosmo.cov") spelled out) because the generated cosmo.*
--- types come from the PINNED runtime, which may predate the binding.
--- @return CCov | nil The C collector, or nil on an older runtime
local function find_ccov(): CCov
  local preload = package.preload as {string: any} -- cast: untyped stdlib table
  if preload["cosmo.cov"] == nil then
    return nil
  end
  local req = require as function(string): any -- cast: bypass static module resolution
  return req("cosmo.cov") as CCov -- cast: binding newer than the pinned types
end

local ccov: CCov = find_ccov()

--- Executed line counts, keyed by chunk source (as reported by
--- debug.getinfo, e.g. "@o/cosmic/fs/init.lua"). Used by the Lua
--- fallback hook; with the C collector the counts live on its side and
--- this table stays empty.
local counts: {string: {integer: integer}} = {}

local depth = 0
local default_dir: string = nil
local dump_name: string = nil
local wrappers_installed = false
local sealed = false

-- cache of the table for the chunk the hook saw last, so consecutive
-- lines in the same chunk cost one table index instead of two
local cur_src: string = nil
local cur: {integer: integer} = nil

local function on_line(_event: string, line: integer)
  local info = debug.getinfo(2, "S")
  local src = info.source
  if src ~= cur_src then
    cur_src = src
    local t = counts[src]
    if not t then
      t = {}
      counts[src] = t
    end
    cur = t
  end
  cur[line] = (cur[line] or 0) + 1
end

--- Wrap coroutine.create/wrap and os.exit exactly once per process.
--- Lua hooks are per-thread, so new coroutines must arm the hook
--- themselves; os.exit must flush a .cov file before the process dies.
local function install_wrappers(do_dump: function())
  if wrappers_installed then
    return
  end
  wrappers_installed = true

  local co = coroutine as {string: any} -- cast: patch stdlib table
  local raw_create = co["create"] as function(any): any -- cast: from any
  local function arm(thread: any)
    if ccov then
      ccov.arm(thread as thread) -- cast: from any
    else
      debug.sethook(thread as thread, on_line, "l") -- cast: from any
    end
  end
  co["create"] = function(f: any): any
    local thread = raw_create(f)
    if depth > 0 then
      arm(thread)
    end
    return thread
  end
  co["wrap"] = function(f: any): any
    local thread = raw_create(f)
    if depth > 0 then
      arm(thread)
    end
    return function(...: any): any ...
      -- cast: from any
      local results = table.pack(coroutine.resume(thread as thread, ...))
      if not results[1] then
        error(results[2], 0)
      end
      return table.unpack(results, 2, results.n as integer) -- cast: from any
    end
  end

  local os_mod = os as {string: any} -- cast: patch stdlib table
  local raw_exit = os_mod["exit"] as function(any, any) -- cast: from any
  os_mod["exit"] = function(code: any, close: any)
    do_dump()
    raw_exit(code, close)
  end
end

--- Check whether collection is active.
--- @return boolean
local function running(): boolean
  return depth > 0
end

--- Begin collecting line hits (nestable).
--- The first start installs the line hook; nested starts only increment
--- the nesting depth, so libraries and tests can bracket their own
--- collection without tearing down an outer one.
local function start()
  depth = depth + 1
  if depth == 1 then
    if ccov then
      ccov.start()
    else
      debug.sethook(on_line, "l")
    end
  end
end

--- Stop collecting line hits (nestable).
--- Removes the line hook when the last nested start is balanced.
--- Collected counts are kept; use reset() to discard them.
local function stop()
  if depth == 0 then
    return
  end
  depth = depth - 1
  if depth == 0 then
    if ccov then
      ccov.stop()
    else
      local clear_hook = debug.sethook as function() -- cast: function shape
      clear_hook()
    end
  end
end

--- Return a copy of the collected counts.
--- Keys are chunk sources as reported by debug.getinfo (e.g.
--- "@o/cosmic/fs/init.lua"), values map line number to hit count.
--- @return {string: {integer: integer}}
local function snapshot(): {string: {integer: integer}}
  if ccov then
    return ccov.snapshot()
  end
  local out: {string: {integer: integer}} = {}
  for src, lines in pairs(counts) do
    local t: {integer: integer} = {}
    for line, n in pairs(lines) do
      t[line] = n
    end
    out[src] = t
  end
  return out
end

--- Discard all collected counts.
local function reset()
  if ccov then
    ccov.reset()
  end
  counts = {}
  cur_src = nil
  cur = nil
end

--- Write collected counts as a .cov file into a directory.
--- The filename is stable per process (pid plus start timestamp), so
--- repeated dumps from one process overwrite instead of double-counting;
--- concurrent processes never collide.
--- @param dir string? Directory to write into (default: the enable() directory)
--- @return boolean True on success, false on failure
--- @return string? Error message if the write failed
local function dump(dir?: string): boolean, string
  if sealed then
    return false, "coverage: sealed (a sandbox wrapper flushed already)"
  end
  local d = dir or default_dir
  if not d then
    return false, "coverage: no output directory"
  end
  local ok, err = fs.makedirs(d)
  if not ok then
    return false, "coverage: " .. (err or "cannot create " .. d)
  end
  if not dump_name then
    local secs, nanos = time.now()
    dump_name = string.format("%d-%d%09d.cov",
      math.floor(proc.getpid()), math.floor(secs), math.floor(nanos))
  end
  local hits = counts
  if ccov then
    hits = ccov.snapshot()
  end
  local body, enc_err = codec.encode_lua({version = 1, hits = hits})
  if not body then
    return false, "coverage: " .. (enc_err or "encode failed")
  end
  local wok, werr = fs.write(fs.join(d, dump_name), body)
  if not wok then
    return false, "coverage: " .. (werr or "write failed")
  end
  return true
end

--- Flush collected counts now and prevent every later dump.
--- The pledge/unveil/landlock wrappers call this before dropping
--- rights: after the sandbox lands, a dump would fail — and under
--- pledge the write attempt would kill the process. Lines executed
--- after sealing are still collected but never reported.
local function seal()
  if not sealed and default_dir then
    dump()
  end
  sealed = true
end

--- Arm collection for this process, dumping into dir on exit.
--- Used by the CLI when COSMIC_COVERAGE names a directory; also wraps
--- os.exit so early exits (like a test skip) still flush their counts.
--- A nested enable never re-targets an outer one's directory.
--- @param dir string Directory to write the .cov file into
local function enable(dir: string)
  if depth == 0 then
    default_dir = dir
  end
  install_wrappers(function()
      if default_dir then
        dump()
      end
    end)
  start()
end

--- Read the coverage directory from the COSMIC_COVERAGE variable.
--- Boolean-ish values ("", "0", "1", "true", "false") mean coverage is
--- requested or off but name no directory, so they return nil; anything
--- else is the directory to dump into.
--- @return string | nil The dump directory, or nil when not configured
local function dir_from_env(): string | nil
  local val = env.get("COSMIC_COVERAGE")
  if not val or val == "" or val == "0" or val == "1"
  or val == "true" or val == "false" then
    return nil
  end
  return val
end

--- Arm collection from the COSMIC_COVERAGE variable, if it names a
--- directory. The CLI calls this before running a script.
--- @return function() | nil A dump callback when armed, nil otherwise
local function enable_from_env(): function() | nil
  local dir = dir_from_env()
  if not dir then
    return nil
  end
  enable(dir)
  return function()
    -- A dump that FAILS says so. Discarding `dump`'s status instead
    -- makes the one failure mode that matters — collection armed,
    -- work done, and the result unwritable — indistinguishable from
    -- code that never ran. The symptom surfaces much later and
    -- somewhere else: a ratchet reporting a file at 14% because the
    -- processes that exercise it could not record what they did.
    --
    -- A warning, not a failure: the process has already done its real
    -- work by the time this runs, and losing its measurement is not a
    -- reason to fail it.
    local ok, err = dump()
    if not ok then
      io.stderr:write("coverage: cannot write to " .. dir .. ": " ..
        (err or "unknown error") .. "\n")
    end
  end
end

--- Merge and render .cov files; the --coverage-report CLI entry point.
--- @param paths {string} .cov files, directories to scan for them, and
--- source directories to include as zero-coverage candidates
--- @return integer Exit code (0 on success, 1 when no data was found)
local function report(paths: {string}): integer
  local rep = require("cosmic.coverage.report")
  return rep.report(paths)
end

-- The ratchet half, re-exported here so build tooling outside cosmic/
-- reaches it through the PUBLIC module (the visibility rule forbids
-- requiring the cosmic.coverage.baseline shard from outside cosmic/).
local baseline_mod = require("cosmic.coverage.baseline")

local record CoverageModule
  start: function()
  stop: function()
  running: function(): boolean
  snapshot: function(): {string: {integer: integer}}
  reset: function()
  dump: function(dir?: string): boolean, string
  seal: function()
  enable: function(dir: string)
  dir_from_env: function(): string | nil
  enable_from_env: function(): function() | nil
  report: function(paths: {string}): integer

  --- Ratchet a run against a committed baseline file (exit-code result).
  gate: function(baseline_path: string, only: string, paths: {string}): integer
  --- Render fresh baseline text from .cov dirs (+ previous floor).
  baseline_text: function(paths: {string}, previous?: string): string | nil, string
  --- Rows a fresh baseline lowers relative to the committed one.
  baseline_lowered: function(before: string, after: string): {string}
end

local M: CoverageModule = {
  start = start,
  stop = stop,
  running = running,
  snapshot = snapshot,
  reset = reset,
  dump = dump,
  seal = seal,
  enable = enable,
  dir_from_env = dir_from_env,
  enable_from_env = enable_from_env,
  report = report,
  gate = baseline_mod.gate,
  baseline_text = baseline_mod.text_for,
  baseline_lowered = baseline_mod.lowered,
}

return M
