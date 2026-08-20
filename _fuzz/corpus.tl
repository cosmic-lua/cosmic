--- Corpus persistence for the fuzz driver.
--- A property's corpus is the directory of stored regressions
--- `_fuzz/testdata/<property-name>/`, populated when a run set
--- FUZZ_SAVE=1 caught a failure. On subsequent runs the driver
--- replays every corpus entry BEFORE its generated iterations, so a
--- known-failing input becomes a permanent regression the suite
--- catches on every run instead of a seed number a human has to
--- remember to turn into a test by hand.
---
--- Files are content-addressed by sha256(input) — one file per
--- distinct minimized bug, arbitrary binary bytes in the file, no
--- header. Re-triggering the same failure overwrites the same file
--- with identical bytes, so the write is idempotent by
--- construction. FUZZ_CORPUS_DIR overrides the default corpus root
--- so tests can point at TEST_TMPDIR.

local codec = require("cosmic.codec")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")

--- The debug-hook throw the driver's per-iteration budget raises.
--- Kept in sync with `driver.tl`'s BUDGET_MESSAGE so a budget throw
--- caught here formats the same `budget=<n> exceeded` detail the
--- generated loop reports.
local BUDGET_MESSAGE = "_fuzz.driver: instruction budget exceeded"

--- Read an integer from the environment, returning fallback when the
--- variable is unset or unparseable. Kept private here so this
--- module has no dependency on driver.tl's copy of the same helper.
--- @param name string The environment variable to read
--- @param fallback integer The value to use when it is absent or not a number
--- @return integer The parsed value, or `fallback`
local function env_integer(name: string, fallback: integer): integer
  local raw = env.get(name)
  if not raw then
    return fallback
  end
  local parsed = tonumber(raw)
  if not parsed then
    return fallback
  end
  return math.floor(parsed)
end

--- Format a corpus-replay failure. Replay has no seed, no iteration
--- and no draws — those tokens would be zeros invented to fit the
--- driver's `failure()` shape, so replay reports through its own
--- formatter instead. The `corpus=<basename>` and `iteration=`
--- tokens never collide, so grepping either substring never
--- false-hits the other.
--- @param name string The property name
--- @param basename string The corpus file's basename (the sha256 hex)
--- @param input string The corpus entry's bytes
--- @param detail string What the property reported, or the thrown error
--- @return string The failure message
local function corpus_failure(
    name: string, basename: string, input: string, detail: string
  ): string
  return string.format(
    "%s: corpus=%s input(base64)=%s: %s",
    name, basename, codec.encode_base64(input), detail)
end

--- Resolve the corpus directory for one property. FUZZ_CORPUS_DIR
--- overrides the default so tests can point at TEST_TMPDIR; the
--- default colocates the corpus with the fuzz test file that hosts
--- the property (`arg[0]`'s dirname), which works for any project
--- using cosmic.fuzz.
--- @param name string The property name
--- @return string The directory holding corpus files for this property
local function dir_for(name: string): string
  local root = env.get("FUZZ_CORPUS_DIR")
  if not root then
    root = fs.join(fs.dirname(arg[0]), "testdata")
  end
  return fs.join(root, name)
end

--- Format the detail suffix a failing check() call produces, used by
--- both the generated loop and this module's replay pass. `ok` is
--- the pcall status; when false, `held` is the thrown value (a
--- BUDGET throw becomes `budget=<n> exceeded`, any other throw
--- becomes `threw: <text>`). When true, `held` is the check's
--- boolean and `detail` its message.
--- @param ok boolean The pcall status
--- @param held any The pcall's second return
--- @param detail any The pcall's third return
--- @param budget integer The instruction budget in force
--- @return string The detail suffix
local function detail_of(ok: boolean, held: any, detail: any, budget: integer): string
  if not ok then
    local thrown = tostring(held)
    if thrown == BUDGET_MESSAGE then
      return ("budget=%d exceeded"):format(budget)
    end
    return "threw: " .. thrown
  end
  return tostring(detail or "no detail")
end

--- The property, narrowed to what corpus code reads: it is called on
--- every corpus entry.
local type CheckFn = function(input: string): boolean, string

--- Run the corpus replay pass, before the generated iteration loop.
--- Skips silently when no corpus dir exists (the common case: most
--- properties have no corpus yet). Each entry is checked under the
--- same VM instruction hook (`arm`) a generated iteration uses, so
--- a stored regression that stops terminating fails with the same
--- `budget=<n> exceeded` message. Runs entries in sorted basename
--- order for deterministic replay across runs and across sessions.
--- @param name string The property name
--- @param check CheckFn The property predicate to run per corpus entry
--- @param budget integer VM instructions check() may spend per entry
--- @param arm function(integer): boolean Arm the driver's budget hook
--- @param disarm function() Disarm the driver's budget hook
--- @return boolean True when every corpus entry held (or when there is
--- no corpus)
--- @return string The failure message when one entry did not hold
local function replay(
    name: string,
    check: CheckFn,
    budget: integer,
    arm: function(integer): boolean,
    disarm: function()
  ): boolean, string
  local dir = dir_for(name)
  if not fs.is_dir(dir) then
    return true, ""
  end
  local files, ferr = fs.find(dir, {recursive = false, sorted = true})
  if not files then
    return false, corpus_failure(name, "", "",
      "corpus listing failed: " .. ferr)
  end
  for _, path in ipairs(files) do
    local bytes_read, rerr = fs.read(path)
    if not bytes_read then
      return false, corpus_failure(name, fs.basename(path), "",
        "corpus read failed: " .. rerr)
    end
    local armed = arm(budget)
    local ok, held, detail = pcall(check, bytes_read)
    if armed then
      disarm()
    end
    if not ok or not held then
      return false, corpus_failure(name, fs.basename(path), bytes_read,
        detail_of(ok, held, detail, budget))
    end
  end
  return true, ""
end

--- Write a minimized failing input to the corpus, when FUZZ_SAVE=1
--- is set. Content-addressed by sha256(input), so re-triggering the
--- same failure overwrites the same file with identical bytes —
--- idempotent by construction. Write errors are ignored: the
--- property's failure message is the load-bearing output, and a
--- caller who cared about the file would notice it absent.
--- @param name string The property name
--- @param input string The minimized failing input to persist
local function save(name: string, input: string)
  if env_integer("FUZZ_SAVE", 0) ~= 1 then
    return
  end
  local dir = dir_for(name)
  local made, _ = fs.make_dirs(dir)
  if not made then
    return
  end
  local _ok, _err = fs.write(fs.join(dir, hash.sha256_hex(input)), input)
end

local record CorpusModule
  dir_for: function(name: string): string
  replay: function(
  name: string,
  check: CheckFn,
  budget: integer,
  arm: function(integer): boolean,
  disarm: function()
): boolean, string
save: function(name: string, input: string)
end

local M: CorpusModule = {
  dir_for = dir_for,
  replay = replay,
  save = save,
}

return M
