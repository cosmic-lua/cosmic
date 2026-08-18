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
--- fallback that has no meaning here). Flag parsing and --bin
--- resolution are _perf/peers/args.tl; the measurement is
--- _perf/peers/measure.tl.
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

local json = require("cosmic.json")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local args = require("_perf.peers.args")
local peers = require("_perf.peers.peers")
local measure = require("_perf.peers.measure")
local report = require("_perf.peers.report")

--- CLI entry point.
--- @param ... string Command-line arguments
--- @return integer Exit code: 0 on OK, 1 on FAIL
local function main(...: string): integer
  local a = args.parse_args({...})
  if a.help then
    print(args.USAGE)
    return 0
  end
  if a.err then
    io.stderr:write(a.err .. "\n" .. args.USAGE)
    return 1
  end
  local bin = args.find_bin(a.bin)
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

  local rep, rerr = measure.measure({
      bin = bin, samples = a.samples, min_sample_secs = a.min_secs, only = a.only,
    })
  if rep == nil then
    print("peers: FAIL (" .. tostring(rerr) .. ")")
    return 1
  end

  local md = report.format_markdown(rep)
  if a.out then
    local pok, perr = args.ensure_parent(a.out)
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
    local pok, perr = args.ensure_parent(a.md)
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
end

local M: run = {
  main = main,
}

return M
