--- The measurement half of the peer table: probe, stage, time, and
--- assemble one Report from the peers.peers registry. Split out of
--- _perf/peers/peers.tl to keep that file to the registry and its pure
--- checks -- this is everything that needs a process, a clock, or a
--- filesystem to do its job.

local child = require("cosmic.child")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local env = require("cosmic.env")
local csys = require("cosmic.sys")
local time = require("cosmic.time")
local proc = require("cosmic.proc")
local harness = require("_perf.harness")
local pt = require("_perf.perf_types")
local peers = require("_perf.peers.peers")

local type Peer = peers.Peer
local type MeasureOptions = peers.MeasureOptions
local type Row = peers.Row
local type PeerMeta = peers.PeerMeta
local type Report = peers.Report

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
      return peers.check_stdout(res)
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
  local version, perr = peers.probe(p)
  if version == nil then
    return {id = p.id, label = p.label, kind = "absent", reason = perr}
  end
  local target, serr = peers.stage(dir, p)
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
  for _, p in ipairs(peers.PEERS) do
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
  return {meta = meta, task = peers.TASK, rows = rows}
end

local record measure_module
  measure: function(opts: MeasureOptions): Report | nil, string
end

local M: measure_module = {
  measure = measure,
}

return M
