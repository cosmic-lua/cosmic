#!/usr/bin/env cosmic
--- Perf harness CLI: run scenario benchmarks or compare two results files.
---
--- Run mode (writes JSON results and prints one line per scenario):
---   cosmic -- o/_perf/run.lua [--out FILE] [--samples N] [--min-secs S]
---     [--only SUBSTRING] [MODULE...]
--- where MODULE is a bench module name such as perf.bench.json_bench
--- (resolved via LUA_PATH). With no MODULE, every module under
--- _perf/bench/ runs.
---
--- Compare mode (exits nonzero on regression/error/missing):
---   cosmic -- o/_perf/run.lua --compare BASE.json CUR.json
---     [--threshold PCT]
---
--- Exit codes: 0 all scenarios ok / no regressions; 1 failure.

local cosmic = require("cosmic")
local flags = require("cosmic.flags")
local json = require("cosmic.json")
local csys = require("cosmic.sys")
local time = require("cosmic.time")
local proc = require("cosmic.proc")
local harness = require("_perf.harness")
local compare = require("_perf.compare")
local pt = require("_perf.perf_types")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")

local record Args
  out: string
  samples: integer
  min_secs: number
  only: string
  compare_mode: boolean
  threshold: number
  selfcheck_a: string
  selfcheck_b: string
  help: boolean
  positional: {string}
  err: string
end

local USAGE = [[
usage: run.lua [--out FILE] [--samples N] [--min-secs S] [--only SUB] [MODULE...]
         (no MODULE runs every module under _perf/bench/)
       run.lua --compare BASE.json CUR.json [--threshold PCT]
         [--selfcheck-a AA.json --selfcheck-b AB.json]
]]

--- Parse command-line arguments.
--- @param argv {string} Raw arguments
--- @return Args Parsed arguments; Args.err is set on parse failure
local SPEC: flags.Spec = {
  name = "run.lua",
  flags = {
    {long = "out", arg = "FILE", help = "write JSON results here"},
    {long = "samples", arg = "N", help = "samples per scenario"},
    {long = "min-secs", arg = "S", help = "minimum sample duration"},
    {long = "only", arg = "SUB", help = "run scenarios matching SUB"},
    {long = "compare", help = "compare two results files"},
    {long = "threshold", arg = "PCT", help = "regression threshold"},
    {long = "selfcheck-a", arg = "FILE", help = "A/A noise floor, first"},
    {long = "selfcheck-b", arg = "FILE", help = "A/A noise floor, second"},
  },
}

local function parse_args(argv: {string}): Args
  local a: Args = {
    samples = harness.DEFAULT_SAMPLES,
    min_secs = harness.DEFAULT_MIN_SAMPLE_SECS,
    threshold = compare.DEFAULT_THRESHOLD_PCT,
    positional = {},
  }
  local parsed, perr = flags.parse(SPEC, argv)
  if not parsed then
    a.err = "argument parse failed: " .. tostring(perr)
    return a
  end
  a.out = parsed.values["out"]
  if parsed.values["samples"] then
    local n = math.tointeger(tonumber(parsed.values["samples"]))
    if n == nil or n < 1 then
      a.err = "--samples requires a positive integer, got: "
      .. tostring(parsed.values["samples"])
    else
      a.samples = n
    end
  end
  if parsed.values["min-secs"] then
    local secs = tonumber(parsed.values["min-secs"])
    if secs == nil or secs <= 0 then
      a.err = "--min-secs requires a positive number, got: "
      .. tostring(parsed.values["min-secs"])
    else
      a.min_secs = secs
    end
  end
  a.only = parsed.values["only"]
  a.compare_mode = parsed.switches["compare"]
  if parsed.values["threshold"] then
    local t = tonumber(parsed.values["threshold"])
    if t == nil or t < 0 then
      a.err = "--threshold requires a non-negative number, got: "
      .. tostring(parsed.values["threshold"])
    else
      a.threshold = t
    end
  end
  a.selfcheck_a = parsed.values["selfcheck-a"]
  a.selfcheck_b = parsed.values["selfcheck-b"]
  a.help = parsed.help
  for _, pos in ipairs(parsed.args) do
    table.insert(a.positional, pos)
  end
  return a
end

--- Collect environment metadata for a results file.
--- @param samples integer Samples per scenario used for this run
--- @param min_secs number Minimum sample duration used for this run
--- @return Meta The metadata record
local function collect_meta(samples: integer, min_secs: number): pt.Meta
  local meta: pt.Meta = {
    timestamp = time.now(),
    samples = samples,
    min_sample_secs = min_secs,
    os = csys.host_os(),
    isa = csys.host_isa(),
    nproc = csys.nproc(),
  }
  -- cast: from any
  meta.bin = os.getenv("PERF_BIN") or rawget(arg, -1) as string or "unknown"
  -- The name is not the identity: two runs forty commits apart both say
  -- `o/bin/cosmic`, so a comparison across them cannot tell it read two
  -- different binaries. The hash is what a gate can check.
  --
  -- A file that cannot name its subject is left visibly incomplete --
  -- no `bin_sha` at all -- rather than filled in with a word like
  -- `unknown`, which reads as an answer and compares equal to the next
  -- run that could not name its subject either.
  local bytes = fs.read(meta.bin)
  if bytes then
    meta.bin_sha = hash.sha256_hex(bytes)
  else
    io.stderr:write("perf: cannot read " .. meta.bin ..
      " to hash it; this results file cannot name the binary it measured\n")
  end
  local v = cosmic.version_info()
  if v then
    meta.cosmic_version = v.cosmic
    meta.cosmos_version = v.cosmos
  end
  return meta
end

--- Load a bench module by name and validate its interface.
--- @param name string Module name, e.g. "_perf.bench.json_bench"
--- @return BenchModule The module, or nil on error
--- @return string Error message on failure
local function load_module(name: string): pt.BenchModule, string
  local ok, mod = pcall(require, name)
  if not ok then
    return nil, "require " .. name .. ": " .. tostring(mod)
  end
  local bm = mod as pt.BenchModule -- cast: from any
  if bm == nil or bm.scenarios == nil then
    return nil, name .. ": not a bench module (missing scenarios())"
  end
  return bm
end

local BENCH_DIR < const > = "_perf/bench"

--- Discover every bench module under _perf/bench, for runs that name
--- none. Resolved against the working tree, so it works exactly where
--- `--make run` runs it (bare scripts in an embedded copy get the
--- error, which names the fix).
--- @return {string} Module names, or nil when none were found
--- @return string Error message on failure
local function discover_benches(): {string}, string
  local found = fs.find(BENCH_DIR,
    {glob = "*_bench.tl", recursive = false, sorted = true})
  if found == nil or #found == 0 then
    return nil, "no bench modules given and none found under " .. BENCH_DIR ..
    " (run from the repo root, through `--make run`)"
  end
  local names: {string} = {}
  for _, path in ipairs(found) do
    names[#names + 1] = (path:gsub("%.tl$", ""):gsub("/", "."))
  end
  return names
end

--- Run all scenarios from the named bench modules.
--- @param a Args Parsed arguments (positional = module names)
--- @return integer Exit code: 0 on success, 1 on any failure
local function run_benches(a: Args): integer
  local names = a.positional
  if #names == 0 then
    local derr: string
    names, derr = discover_benches()
    if not names then
      io.stderr:write(tostring(derr) .. "\n" .. USAGE)
      return 1
    end
  end
  -- Every module is loaded and validated before any scenario runs, and
  -- the --out directory is created now: a typo'd later module (or a
  -- missing o/perf on a fresh tree) used to surface only after the
  -- earlier modules had already spent their minutes of measurement.
  local mods: {pt.BenchModule} = {}
  for _, name in ipairs(names) do
    local mod, merr = load_module(name)
    if mod == nil then
      io.stderr:write(merr .. "\n")
      return 1
    end
    mods[#mods + 1] = mod
  end
  if a.out then
    local outdir = fs.dirname(a.out)
    if outdir ~= "" and not fs.is_dir(outdir) then
      local mok, mkerr = fs.make_dirs(outdir)
      if not mok then
        io.stderr:write("write " .. a.out .. ": " .. tostring(mkerr) .. "\n")
        return 1
      end
    end
  end
  local opts: pt.Options = {samples = a.samples, min_sample_secs = a.min_secs}
  local all: {pt.Measurement} = {}
  local failed = false
  local matched = 0
  for mi, mod in ipairs(mods) do
    local name = names[mi]
    local scenarios, serr = mod.scenarios()
    if scenarios == nil then
      -- A module that fails to build its scenario list is exactly as
      -- unusable as one that fails to require() -- both abort the run
      -- rather than silently skipping the module and reporting on
      -- whatever else happened to load.
      io.stderr:write(name .. ": scenarios: " .. tostring(serr) .. "\n")
      if mod.cleanup then
        pcall(mod.cleanup)
      end
      return 1
    end
    for _, s in ipairs(scenarios) do
      -- SUBSTRING, plainly. A scenario name is `hash_sha256_small`,
      -- `startup_run_*`, `net_ip_*` -- full of characters a Lua
      -- pattern reads as syntax, so `--only startup_run_*` as a
      -- pattern silently means "startup_ru" followed by any number of
      -- `n`, and matches things the user did not ask for while
      -- looking like it worked.
      if a.only == nil or s.name:find(a.only, 1, true) then
        matched = matched + 1
        local m = harness.run_scenario(s, opts)
        print(harness.format_line(m))
        table.insert(all, m)
        if m.error then
          failed = true
        end
      end
    end
    if mod.cleanup then
      pcall(mod.cleanup)
    end
  end
  if a.only and matched == 0 then
    -- A typo'd --only that matches nothing used to exit 0 with an empty
    -- results file -- a silently-empty comparison later, not an error
    -- now.
    io.stderr:write("--only " .. a.only .. " matched nothing\n")
    return 1
  end
  if a.out then
    local payload: pt.Results = {
      meta = collect_meta(a.samples, a.min_secs),
      results = all,
    }
    local encoded, eerr = json.encode(payload)
    if encoded == nil then
      io.stderr:write("encode results: " .. tostring(eerr) .. "\n")
      return 1
    end
    local wok, werr = fs.write(a.out, encoded)
    if not wok then
      io.stderr:write("write " .. a.out .. ": " .. tostring(werr) .. "\n")
      return 1
    end
    print("wrote " .. a.out)
  end
  if failed then
    io.stderr:write("perf: one or more scenarios failed\n")
    return 1
  end
  return 0
end

--- Compare two results files and report.
--- @param a Args Parsed arguments (positional = baseline path, current path)
--- @return integer Exit code: 0 when clean, 1 on regression/error/missing
local function run_compare(a: Args): integer
  if #a.positional ~= 2 then
    io.stderr:write("--compare needs exactly two results files\n" .. USAGE)
    return 1
  end
  local base, berr = compare.load_results(a.positional[1])
  if base == nil then
    io.stderr:write(berr .. "\n")
    return 1
  end
  local cur, cerr = compare.load_results(a.positional[2])
  if cur == nil then
    io.stderr:write(cerr .. "\n")
    return 1
  end
  -- Given files, so this is where the by-hand slip lands: two runs of
  -- the same binary compared against each other.
  local refusal = compare.identity_refusal(a.positional[1], base,
    a.positional[2], cur, false)
  if refusal then
    io.stderr:write(refusal .. "\n")
    return 1
  end
  local deltas: {pt.Delta}
  local failures: integer
  if a.selfcheck_a and a.selfcheck_b then
    -- A/A triage: reclassify regressions the current binary can't
    -- reproduce against itself as "noise" rather than failures.
    local na, naerr = compare.load_results(a.selfcheck_a)
    if na == nil then
      io.stderr:write(naerr .. "\n")
      return 1
    end
    local nb, nberr = compare.load_results(a.selfcheck_b)
    if nb == nil then
      io.stderr:write(nberr .. "\n")
      return 1
    end
    deltas, failures = compare.triage(base, cur, na, nb, a.threshold)
  else
    deltas, failures = compare.diff(base, cur, a.threshold)
  end
  print(compare.format(deltas))
  if failures > 0 then
    io.stderr:write("perf: " .. failures .. " scenario(s) regressed, errored, or went missing\n")
    return 1
  end
  return 0
end

--- CLI entry point.
--- @param ... string Command-line arguments
--- @return integer Exit code
local function main(...: string): integer
  local a = parse_args({...})
  if a.help then
    print(USAGE)
    return 0
  end
  if a.err then
    io.stderr:write(a.err .. "\n" .. USAGE)
    return 1
  end
  if a.compare_mode then
    return run_compare(a)
  end
  return run_benches(a)
end

if proc.is_main() then
  os.exit(main(...))
end

local record run
  main: function(...: string): integer
  parse_args: function(argv: {string}): Args
  collect_meta: function(samples: integer, min_secs: number): pt.Meta
  load_module: function(name: string): pt.BenchModule, string
  discover_benches: function(): {string}, string
end

local M: run = {
  main = main,
  parse_args = parse_args,
  collect_meta = collect_meta,
  load_module = load_module,
  discover_benches = discover_benches,
}

return M
