#!/usr/bin/env cosmic
--- The peer table CLI: one command that measures cosmic-lua, cpython,
--- node and go on the identical spawn-and-print task and renders a
--- markdown table plus a JSON results file.
---
---   cosmic -- o/_perf/peers/run.lua [--bin PATH] [--out FILE] [--md FILE]
---     [--samples N] [--min-secs S] [--only ID]
---
--- --bin: the cosmic binary to measure. Default PERF_BIN, then the
--- running interpreter (arg[-1]) -- the same precedence
--- startup_bench.tl's find_bin uses, minus TEST_BIN (a test-suite-only
--- fallback that has no meaning here).
---
--- --only: an EXACT peer id, not a substring. An id that matches no peer
--- fails before any measurement runs.
---
--- Prints the rendered markdown, then the verdict line, always last:
---   peers: OK 4/4 measured
---   peers: OK 3/4 measured (absent: go)   -- an absent peer is a pass
---   peers: FAIL (<reason>)                -- only a broken cosmic-lua
---                                             row, or a bad --only, fails
---
--- No threshold, no comparison: this table reports standing, it never
--- gates.

local flags = require("cosmic.flags")
local json = require("cosmic.json")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local harness = require("_perf.harness")
local peers = require("_perf.peers.peers")
local report = require("_perf.peers.report")

local USAGE = [[
usage: run.lua [--bin PATH] [--out FILE] [--md FILE] [--samples N]
               [--min-secs S] [--only ID]
]]

local SPEC: flags.Spec = {
  name = "run.lua",
  flags = {
    {long = "bin", arg = "PATH",
      help = "cosmic binary to measure (default: PERF_BIN, else the running interpreter)"},
    {long = "out", arg = "FILE", help = "write JSON results here"},
    {long = "md", arg = "FILE", help = "write the rendered markdown table here"},
    {long = "samples", arg = "N", help = "samples per peer"},
    {long = "min-secs", arg = "S", help = "minimum sample duration"},
    {long = "only", arg = "ID", help = "measure only the peer with this exact id"},
  },
}

local record Args
  bin: string
  out: string
  md: string
  samples: integer
  min_secs: number
  only: string
  help: boolean
  err: string
end

--- Parse command-line arguments.
--- @param argv {string} Raw arguments
--- @return Args Parsed arguments; Args.err is set on parse failure
local function parse_args(argv: {string}): Args
  local a: Args = {
    samples = harness.DEFAULT_SAMPLES,
    min_secs = harness.DEFAULT_MIN_SAMPLE_SECS,
  }
  local parsed, perr = flags.parse(SPEC, argv)
  if not parsed then
    a.err = "argument parse failed: " .. tostring(perr)
    return a
  end
  a.bin = parsed.values["bin"]
  a.out = parsed.values["out"]
  a.md = parsed.values["md"]
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
  a.help = parsed.help
  return a
end

--- Locate the cosmic binary to measure. --bin wins; then PERF_BIN; then
--- the interpreter running this script (arg[-1]).
--- @param explicit string The --bin flag's value, if given
--- @return string | nil Path to the binary, or nil if none was found
local function find_bin(explicit: string): string | nil
  if explicit and #explicit > 0 then
    return explicit
  end
  local envbin = os.getenv("PERF_BIN")
  if envbin and #envbin > 0 then
    return envbin
  end
  local last = rawget(arg, -1)
  if last is string then
    return last
  end
  return nil
end

--- Create the parent directory of `path`, if it does not already exist.
--- @param path string A file path about to be written
--- @return boolean Success
--- @return string Reason, on failure
local function ensure_parent(path: string): boolean, string
  local dir = fs.dirname(path)
  if dir == "" or fs.is_dir(dir) then
    return true
  end
  return fs.make_dirs(dir)
end

--- CLI entry point.
--- @param ... string Command-line arguments
--- @return integer Exit code: 0 on OK, 1 on FAIL
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
  local bin = find_bin(a.bin)
  if bin == nil or #bin == 0 then
    print("peers: FAIL (cannot locate cosmic binary; pass --bin or set PERF_BIN)")
    return 1
  end
  if a.only and a.only ~= "" then
    local found = false
    for _, p in ipairs(peers.PEERS) do
      if p.id == a.only then
        found = true
      end
    end
    if not found then
      print("peers: FAIL (--only " .. a.only .. " matched nothing)")
      return 1
    end
  end

  local rep, rerr = peers.measure({
      bin = bin, samples = a.samples, min_sample_secs = a.min_secs, only = a.only,
    })
  if rep == nil then
    print("peers: FAIL (" .. tostring(rerr) .. ")")
    return 1
  end

  local md = report.format_markdown(rep)
  if a.out then
    local pok, perr = ensure_parent(a.out)
    if not pok then
      print("peers: FAIL (write " .. a.out .. ": " .. tostring(perr) .. ")")
      return 1
    end
    local encoded, eerr = json.encode(rep)
    if encoded == nil then
      print("peers: FAIL (encode results: " .. tostring(eerr) .. ")")
      return 1
    end
    local wok, werr = fs.write(a.out, encoded)
    if not wok then
      print("peers: FAIL (write " .. a.out .. ": " .. tostring(werr) .. ")")
      return 1
    end
  end
  if a.md then
    local pok, perr = ensure_parent(a.md)
    if not pok then
      print("peers: FAIL (write " .. a.md .. ": " .. tostring(perr) .. ")")
      return 1
    end
    local wok, werr = fs.write(a.md, md .. "\n")
    if not wok then
      print("peers: FAIL (write " .. a.md .. ": " .. tostring(werr) .. ")")
      return 1
    end
  end

  print(md)
  local v = report.verdict(rep)
  print(v)
  if v:sub(1, 9) == "peers: OK" then
    return 0
  end
  return 1
end

if proc.is_main() then
  os.exit(main(...))
end

local record run
  main: function(...: string): integer
  parse_args: function(argv: {string}): Args
  find_bin: function(explicit: string): string | nil
end

local M: run = {
  main = main,
  parse_args = parse_args,
  find_bin = find_bin,
}

return M
