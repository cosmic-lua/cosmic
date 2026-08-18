--- The peer registry and measurement: cosmic vs. CPython, Node, and Go on
--- the one task every row shares -- spawn a script file that prints
--- exactly "perf-hello", captured through cosmic.child, timed by
--- _perf.harness.run_scenario, checked by the same exact-stdout rule
--- every _perf scenario must define. Go's compile happens in setup
--- (`stage`), outside the timed region, the same way cosmic's binary is
--- prebuilt before it is measured.
---
--- This is a report, not a gate: a peer missing or broken on the runner
--- becomes an "absent" row, not a failed build -- except cosmic-lua,
--- whose failure IS an error: a table without cosmic in it is not one.

local child = require("cosmic.child")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local env = require("cosmic.env")
local csys = require("cosmic.sys")
local time = require("cosmic.time")
local proc = require("cosmic.proc")
local str = require("cosmic.string")
local harness = require("_perf.harness")
local pt = require("_perf.perf_types")

local EXPECT < const > = "perf-hello"

--- How to check, stage, and run one peer.
local record Peer
  id: string
  label: string
  exe: string -- executable name (PATH-resolved) or "" for cosmic-lua
  probe_argv: {string} -- argv that prints a version line
  script: string -- filename the source is staged under
  source: string -- the hello-world source; must print EXPECT
  build_argv: {string} | nil -- compiled in setup when set (see: go)
  run_argv: function(exe: string, target: string): {string} -- the timed argv
end

--- measure() knobs. only, when set, restricts the run to the one peer
--- whose id matches it exactly.
local record MeasureOptions
  bin: string
  samples: integer
  min_sample_secs: number
  only: string
end

--- One rendered row. kind is "measured" or "absent"; absent rows carry
--- only id/label/reason.
local record Row
  id: string
  label: string
  kind: string
  reason: string
  version: string
  exe: string
  exe_bytes: integer
  provenance: string
  argv: {string}
  probe_argv: {string}
  wall_ns: number
  min_ns: number
  max_ns: number
  spread_pct: number
  iterations: integer
end

local record PeerMeta
  timestamp: number
  os: string
  isa: string
  nproc: number
  samples: integer
  min_sample_secs: number
  runner: string
  cosmic_bin: string
  cosmic_bin_sha: string
  cosmic_version: string
end

local record Report
  meta: PeerMeta
  task: string
  rows: {Row}
end

local TASK < const > =
'spawn a script file that prints exactly "perf-hello", captured via ' ..
"cosmic.child.run, timed by _perf.harness.run_scenario"

local GO_SOURCE < const > = [[
package main

import "fmt"

func main() {
	fmt.Println("perf-hello")
}
]]

local function same_argv(exe: string, target: string): {string}
  return {exe, target}
end

local PEERS < const >: {Peer} = {
  {id = "cosmic-lua", label = "cosmic-lua", exe = "", probe_argv = {"--version"},
    script = "hello.lua", source = 'print("perf-hello")\n', build_argv = nil,
    run_argv = same_argv},
  {id = "cpython", label = "cpython", exe = "python3",
    probe_argv = {"python3", "--version"}, script = "hello.py",
    source = 'print("perf-hello")\n', build_argv = nil, run_argv = same_argv},
  {id = "node", label = "node", exe = "node", probe_argv = {"node", "--version"},
    script = "hello.js", source = 'console.log("perf-hello")\n', build_argv = nil,
    run_argv = same_argv},
  {id = "go", label = "go", exe = "go", probe_argv = {"go", "version"},
    script = "hello.go", source = GO_SOURCE,
    build_argv = {"go", "build", "-o", "hello", "hello.go"},
    run_argv = function(_: string, target: string): {string} return {target} end},
}

--- The exact-match rule every row is checked against: the task is only
--- fair if the check verifying it is identical for every peer.
--- @return boolean Whether out is exactly EXPECT
--- @return string Reason, when it is not
local function check_stdout(out: string): boolean, string
  if out == EXPECT then
    return true
  end
  return false, ("expected %q, got %q"):format(EXPECT, out)
end

--- Run a peer's version probe.
--- @return string | nil First line of stdout (falling back to stderr), trimmed
--- @return string Reason, on a spawn failure or nonzero exit
local function probe(p: Peer): string | nil, string
  local r, rerr = child.run(p.probe_argv)
  if r == nil then
    return nil, tostring(rerr)
  end
  if not r.ok then
    return nil, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr)
  end
  local text = r.stdout
  if text == nil or text == "" then
    text = r.stderr
  end
  local first = (text or ""):match("^[^\n]*") or ""
  return str.trim(first)
end

--- The `-o NAME` output of a build argv, if it has one.
local function build_output(build_argv: {string}): string | nil
  for i, a in ipairs(build_argv) do
    if a == "-o" and build_argv[i + 1] then
      return build_argv[i + 1]
    end
  end
  return nil
end

--- Write a peer's source under dir and build it, if it has a build step.
--- @return string | nil Path of the artifact to spawn
--- @return string Reason, on a write or build failure
local function stage(dir: string, p: Peer): string | nil, string
  local path = fs.join(dir, p.script)
  local wok, werr = fs.write(path, p.source)
  if not wok then
    return nil, "write " .. path .. ": " .. tostring(werr)
  end
  if p.build_argv == nil then
    return path
  end
  local r, rerr = child.run(p.build_argv, {cwd = dir})
  if r == nil then
    return nil, "build: " .. tostring(rerr)
  end
  if not r.ok then
    return nil, "build exit " .. tostring(r.code) .. ": " .. tostring(r.stderr)
  end
  local out_name = build_output(p.build_argv)
  if out_name == nil then
    return nil, "build_argv " .. table.concat(p.build_argv, " ") .. " has no -o output"
  end
  return fs.join(dir, out_name)
end

--- The pt.Scenario the harness times: spawn p.run_argv(exe, target),
--- checked with check_stdout. Same shape as startup_bench.tl's
--- spawn_capture.
local function scenario(p: Peer, exe: string, target: string): pt.Scenario
  return {
    name = p.id,
    fn = function(_: any): any
      local r, rerr = child.run(p.run_argv(exe, target))
      assert(r ~= nil, tostring(rerr))
      assert(r.ok, "exit code " .. tostring(r.code) .. ": " .. tostring(r.stdout))
      return (r.stdout:gsub("%s+$", ""))
    end,
    check = function(_: any, res: any): boolean, string
      if not (res is string) then
        return false, p.id .. ": result is not a string"
      end
      return check_stdout(res)
    end,
  }
end

--- A copy of the cosmic-lua peer with exe/probe_argv resolved to the
--- binary under test -- unknown at registration time, so PEERS carries
--- only a placeholder for this one row.
local function with_bin(p: Peer, bin: string): Peer
  return {
    id = p.id, label = p.label, exe = bin, probe_argv = {bin, "--version"},
    script = p.script, source = p.source, build_argv = p.build_argv,
    run_argv = p.run_argv,
  }
end

--- Probe, stage, and time one peer.
local function measure_row(p: Peer, dir: string, hopts: pt.Options): Row
  local version, perr = probe(p)
  if version == nil then
    return {id = p.id, label = p.label, kind = "absent", reason = perr}
  end
  local target, serr = stage(dir, p)
  if target == nil then
    return {id = p.id, label = p.label, kind = "absent", reason = serr}
  end

  local exe_path = p.exe
  local provenance: string
  if p.id == "cosmic-lua" then
    provenance = "prebuilt (--bin)"
  elseif p.build_argv then
    provenance = "compiled at setup: " .. table.concat(p.build_argv, " ")
    exe_path = target
  else
    local resolved, werr = proc.which(p.exe)
    if resolved == nil then
      return {id = p.id, label = p.label, kind = "absent",
        reason = "which " .. p.exe .. ": " .. tostring(werr)}
    end
    exe_path = resolved
    provenance = "prebuilt, on PATH"
  end

  local st, sterr = fs.stat(exe_path)
  if st == nil then
    return {id = p.id, label = p.label, kind = "absent",
      reason = "stat " .. exe_path .. ": " .. tostring(sterr)}
  end

  local m = harness.run_scenario(scenario(p, exe_path, target), hopts)
  if m.error then
    return {id = p.id, label = p.label, kind = "absent", reason = m.error}
  end
  return {
    id = p.id, label = p.label, kind = "measured", version = version,
    exe = exe_path, exe_bytes = st:size(), provenance = provenance,
    argv = p.run_argv(exe_path, target), probe_argv = p.probe_argv,
    wall_ns = m.wall_ns, min_ns = m.min_ns, max_ns = m.max_ns,
    spread_pct = m.spread_pct, iterations = m.iterations,
  }
end

--- Measure every selected peer. cosmic-lua is never optional: a failure
--- to probe, stage, or pass its check aborts the whole run instead of
--- becoming an absent row.
--- @return Report | nil The table
--- @return string Reason, on a cosmic-lua failure or a bad --only
local function measure(opts: MeasureOptions): Report | nil, string
  local samples = opts.samples or harness.DEFAULT_SAMPLES
  local min_secs = opts.min_sample_secs or harness.DEFAULT_MIN_SAMPLE_SECS
  local base = os.getenv("TEST_TMPDIR") or os.getenv("TMPDIR") or "/tmp"
  local dir, derr = fs.temp_dir(fs.join(base, "perf-peers-XXXXXX"))
  if dir == nil then
    return nil, "mkdtemp: " .. tostring(derr)
  end

  local selected: {Peer} = {}
  for _, p in ipairs(PEERS) do
    if opts.only == nil or opts.only == "" or opts.only == p.id then
      selected[#selected + 1] = p.id == "cosmic-lua" and with_bin(p, opts.bin) or p
    end
  end
  if #selected == 0 then
    local _ok, _err = fs.remove_all(dir)
    return nil, "no peer matches --only " .. tostring(opts.only)
  end

  local hopts: pt.Options = {samples = samples, min_sample_secs = min_secs}
  local rows: {Row} = {}
  local cosmic_version = ""
  for _, p in ipairs(selected) do
    local row = measure_row(p, dir, hopts)
    if p.id == "cosmic-lua" then
      if row.kind ~= "measured" then
        local _ok, _err = fs.remove_all(dir)
        return nil, "cosmic row: " .. tostring(row.reason)
      end
      cosmic_version = row.version
    end
    rows[#rows + 1] = row
  end
  local _ok, _err = fs.remove_all(dir)

  local cosmic_sha = ""
  local bytes = fs.read(opts.bin)
  if bytes then
    cosmic_sha = hash.sha256_hex(bytes)
  end

  local meta: PeerMeta = {
    timestamp = time.now(), os = csys.host_os(), isa = csys.host_isa(),
    nproc = csys.nproc(), samples = samples, min_sample_secs = min_secs,
    runner = env.get("ImageOS") or "local", cosmic_bin = opts.bin,
    cosmic_bin_sha = cosmic_sha, cosmic_version = cosmic_version,
  }
  return {meta = meta, task = TASK, rows = rows}
end

local record peers
  type Peer = Peer
  type MeasureOptions = MeasureOptions
  type Row = Row
  type PeerMeta = PeerMeta
  type Report = Report
  PEERS: {Peer}
  EXPECT: string
  check_stdout: function(out: string): boolean, string
  probe: function(p: Peer): string | nil, string
  stage: function(dir: string, p: Peer): string | nil, string
  scenario: function(p: Peer, exe: string, target: string): pt.Scenario
  measure: function(opts: MeasureOptions): Report | nil, string
end

local M: peers = {
  PEERS = PEERS,
  EXPECT = EXPECT,
  check_stdout = check_stdout,
  probe = probe,
  stage = stage,
  scenario = scenario,
  measure = measure,
}

return M
