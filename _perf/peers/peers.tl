--- The peer registry: cosmic vs. CPython, Node, and Go on the one task
--- every row shares -- spawn a script file that prints exactly
--- "perf-hello", captured through cosmic.child, checked by the same
--- exact-stdout rule every _perf scenario must define. Go's compile
--- happens in setup (`stage`), outside the timed region, the same way
--- cosmic's binary is prebuilt before it is measured. Types, the
--- registry, staging and probing live here; timing and report assembly
--- (which need a clock and more requires) are _perf/peers/measure.tl.
---
--- This is a report, not a gate: a peer missing or broken on the runner
--- becomes an "absent" row, not a failed build -- except cosmic-lua,
--- whose failure IS an error: a table without cosmic in it is not one.

local child = require("cosmic.child")
local fs = require("cosmic.fs")
local str = require("cosmic.string")

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

--- measure() knobs; only, when set, restricts the run to one peer id.
local record MeasureOptions
  bin: string
  samples: integer
  min_sample_secs: number
  only: string
end

--- One rendered row; kind "measured" or "absent" (id/label/reason only).
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

--- The exact-match rule every row is checked against (fair only if
--- identical for every peer).
--- @return boolean Whether out is exactly EXPECT
--- @return string Reason, when it is not
local function check_stdout(out: string): boolean, string
  if out == EXPECT then return true end
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

--- The `-o NAME` output of a build argv, if any.
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

local record peers
  type Peer = Peer
  type MeasureOptions = MeasureOptions
  type Row = Row
  type PeerMeta = PeerMeta
  type Report = Report
  PEERS: {Peer}
  EXPECT: string
  TASK: string
  check_stdout: function(out: string): boolean, string
  probe: function(p: Peer): string | nil, string
  stage: function(dir: string, p: Peer): string | nil, string
end

local M: peers = {
  PEERS = PEERS,
  EXPECT = EXPECT,
  TASK = TASK,
  check_stdout = check_stdout,
  probe = probe,
  stage = stage,
}

return M
