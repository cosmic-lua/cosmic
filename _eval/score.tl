#!/usr/bin/env cosmic
--- Eval scoring CLI: turn a staged, agent-run run directory into
--- results.json and a PASS/FAIL verdict.
---
---   cosmic -- o/_eval/score.lua <run dir>
---
--- Reads the versioned suite (_eval/suite.tl, via _eval.stage's
--- loader) and the run dir's meta.json (written by stage.tl) and
--- probe.txt (operator-written after staging). Per task, if the
--- workspace itself is missing the row is "error"; if its built
--- artifact is missing the row is "incomplete" (not a silent bug);
--- otherwise the task's committed functional check runs against the
--- produced artifact -- never the agent's claims -- and the journal
--- (NOTES.md, final.txt) is best-effort parsed for the fields that
--- have no other source.
---
--- Never writes into `<run dir>` itself: the argument is a caller-owned
--- path (sometimes a committed fixture) and checks materialize their
--- own pinned inputs into the workspace they check, so the whole tree
--- is mirrored once, up front, into `o/_eval/scored/<basename>` (this
--- project's own build-output root) and every later step -- checks,
--- journal parse, results.json -- runs against that copy only. See
--- `out_dir_for` for the exact destination a caller can look up.
---
--- Exit codes: 0 on PASS; 1 on FAIL or any failure (printed to stderr).
local flags = require("cosmic.flags")
local fs = require("cosmic.fs")
local json = require("cosmic.json")
local proc = require("cosmic.proc")
local str = require("cosmic.string")
local eval_types = require("_eval.eval_types")
local journal = require("_eval.journal")
local stage = require("_eval.stage")

--- Every task's binary path, relative to its workspace -- the
--- "./cosmic --make build produces an executable o/bin/<name>" fact
--- every brief states, pinned here once rather than derived from the
--- task id at runtime (module-tests' binary is "slug", not
--- "module-tests").
local TASK_BIN < const >: {string: string} = {
  ["json-cli"] = "o/bin/jstat",
  ["module-tests"] = "o/bin/slug",
  ["sqlite-indexer"] = "o/bin/findex",
  ["child-tcp"] = "o/bin/echotrip",
  ["text-report"] = "o/bin/logreport",
  ["multi-module-build"] = "o/bin/wordbag",
  ["contained-task"] = "o/bin/copybox",
}

--- Every task's functional check, keyed the same way as TASK_BIN.
--- Shared with checks_test.tl via _eval.checks.registry, the one place
--- that wires id to implementation, so the two lists cannot drift.
local CHECKS < const > = require("_eval.checks.registry").CHECKS

local record Args
  rundir: string
  help: boolean
  err: string
end

local USAGE < const > = "usage: score.lua <run dir>\n"

local SPEC: flags.Spec = {
  name = "score.lua",
  flags = {},
}

--- Build-output root scoring copies are staged into -- never the run
--- dir argument itself, which score.tl must leave untouched. `o/` is
--- this project's own build-output convention.
local OUT_ROOT < const > = "o/_eval/scored"

--- Where `stage_scoring_copy` stages a scoring copy of `rundir_arg` and
--- where results.json ends up -- one basename-keyed slot under
--- OUT_ROOT, so a caller that needs to inspect results.json (a test,
--- an operator) can find it without re-deriving the naming rule.
--- @param rundir_arg string The run dir argument, as given on argv
--- @return string The scoring copy's path (always absolute)
local function out_dir_for(rundir_arg: string): string
  local abs = fs.absolute_path(rundir_arg)
  return fs.absolute_path(fs.join(OUT_ROOT, fs.basename(abs)))
end

--- Mirror `rundir_arg` into its `out_dir_for` slot and return that
--- copy's (absolute) path. Every later step -- meta/probe loading,
--- checks, journal parsing, results.json -- runs against the copy, so
--- `rundir_arg` is only ever read here, never written to. Staging into
--- an ABSOLUTE destination also closes a distinct bug: `cosmic.child`
--- applies `cwd` in the spawned child before exec, so a relative
--- workspace joined into argv[0] would resolve a second time against
--- the child's new cwd and fail with ENOENT; every workspace built from
--- this copy is absolute, so that double resolution cannot happen.
--- @param rundir_arg string The run dir argument, as given on argv
--- @return string|nil The scoring copy's path
--- @return string The error, when the copy could not be staged
local function stage_scoring_copy(rundir_arg: string): string | nil, string
  local dst = out_dir_for(rundir_arg)
  local rok, rerr = fs.remove_all(dst)
  if not rok then
    return nil, "clear " .. dst .. ": " .. tostring(rerr)
  end
  local cok, cerr = fs.copy_tree(rundir_arg, dst)
  if not cok then
    return nil, "stage " .. rundir_arg .. " -> " .. dst .. ": " .. tostring(cerr)
  end
  return dst
end

--- Parse command-line arguments: exactly one positional, the run dir.
--- @param argv {string} Raw arguments
--- @return Args Parsed arguments; Args.err is set on parse failure
local function parse_args(argv: {string}): Args
  local a: Args = {}
  local parsed, perr = flags.parse(SPEC, argv)
  if not parsed then
    a.err = "argument parse failed: " .. tostring(perr)
    return a
  end
  a.help = parsed.help
  if not a.help then
    if #parsed.args ~= 1 then
      a.err = "expected exactly one argument: the run directory, got " ..
      #parsed.args
    else
      a.rundir = parsed.args[1]
    end
  end
  return a
end

--- meta.json fields required to be present. cosmic_version is
--- deliberately excluded -- stage.tl itself leaves it unset when the
--- staged binary's own version could not be resolved.
local REQUIRED_META_FIELDS < const >: {string} = {
  "timestamp", "suite_version", "bin", "bin_sha",
  "os", "isa", "model", "agent_tool", "timeout_secs",
}

--- Load and validate <run dir>/meta.json into the shared ten staged
--- fields; probe_output/leaked are filled in separately by fold_probe.
--- @param run_dir string The run directory
--- @return ResultMeta|nil The parsed metadata (probe fields unset)
--- @return string The error when the file is missing, malformed, or a
--- required field is absent
local function load_meta(run_dir: string): eval_types.ResultMeta | nil, string
  local path = fs.join(run_dir, "meta.json")
  local body, rerr = fs.read(path)
  if not body then
    return nil, "read " .. path .. ": " .. tostring(rerr)
  end
  local raw, jerr = json.decode_object(body)
  if not raw then
    return nil, path .. ": " .. tostring(jerr)
  end
  for _, field in ipairs(REQUIRED_META_FIELDS) do
    if raw[field] == nil then
      return nil, path .. ": missing field " .. field
    end
  end
  local meta: eval_types.ResultMeta = {
    timestamp = raw.timestamp as number, -- cast: from any
    suite_version = math.tointeger(raw.suite_version as number), -- cast: from any
    bin = raw.bin as string, -- cast: from any
    bin_sha = raw.bin_sha as string, -- cast: from any
    os = raw.os as string, -- cast: from any
    isa = raw.isa as string, -- cast: from any
    model = raw.model as string, -- cast: from any
    agent_tool = raw.agent_tool as string, -- cast: from any
    timeout_secs = math.tointeger(raw.timeout_secs as number), -- cast: from any
  }
  if raw.cosmic_version ~= nil then
    meta.cosmic_version = raw.cosmic_version as string -- cast: from any
  end
  return meta
end

--- Whether a probe reply is exactly the READY/NONE pair the probe
--- prompt asks for (see stage.tl's probe_command), ignoring blank
--- lines around it. Anything else -- a quoted leak, extra prose, a
--- missing reply -- is not clean.
--- @param probe string probe.txt's raw contents
--- @return boolean True iff the reply is exactly READY then NONE
local function probe_is_clean(probe: string): boolean
  local non_empty: {string} = {}
  for _, line in ipairs(str.lines(probe)) do
    local trimmed = str.trim(line)
    if trimmed ~= "" then
      non_empty[#non_empty + 1] = trimmed
    end
  end
  return #non_empty == 2 and non_empty[1] == "READY" and non_empty[2] == "NONE"
end

--- Fold <run dir>/probe.txt into a loaded ResultMeta's probe fields.
--- Missing probe.txt reads as an empty, un-clean probe -- never as
--- "leaked = false", which would be a guess this instrument does not
--- make.
--- @param run_dir string The run directory
--- @param meta ResultMeta The metadata to fill in, mutated in place
local function fold_probe(run_dir: string, meta: eval_types.ResultMeta)
  local probe = fs.read(fs.join(run_dir, "probe.txt")) or ""
  meta.probe_output = probe
  meta.leaked = not probe_is_clean(probe)
end

--- Score one task's row: workspace presence, then artifact presence,
--- then (only once both hold) the task's functional check and the
--- journal parse.
--- @param run_dir string The run directory
--- @param task Task The manifest task to score
--- @return Row The scored row
local function score_row(run_dir: string, task: eval_types.Task): eval_types.Row
  local row: eval_types.Row = {
    task = task.id,
    journal_path = task.id,
    friction = {},
    silent_bugs = 0,
  }
  local workspace = fs.join(run_dir, task.id)
  if not fs.is_dir(workspace) then
    row.status = "error"
    return row
  end

  local j = journal.parse(workspace)
  row.self_report_clean = j.self_report_clean
  row.friction = j.friction
  row.attempts_first_build = j.attempts_first_build
  row.attempts_green_ci = j.attempts_green_ci

  local bin_path = fs.join(workspace, TASK_BIN[task.id])
  if not fs.is_file(bin_path) or not fs.is_accessible(bin_path, fs.X_OK) then
    row.status = "incomplete"
    return row
  end

  local count, findings = CHECKS[task.id](workspace)
  row.status = "completed"
  row.silent_bugs = count
  if #findings > 0 then
    io.stderr:write("score: " .. task.id .. ": " .. count .. " finding(s)\n")
    for _, f in ipairs(findings) do
      io.stderr:write("  - " .. f .. "\n")
    end
  end
  return row
end

--- The verdict rule: PASS iff every PROVEN task's row is "completed"
--- AND the sum of silent_bugs over proven tasks is 0. An incomplete or
--- errored proven task fails the gate on its own -- an unrun suite is
--- not a clean window -- regardless of what the bug sum says. A "new"
--- task's bugs are recorded in its row but never gate: the first run
--- establishes its baseline.
--- @param manifest Manifest The suite (task.status names proven/new)
--- @param rows {Row} The scored rows, one per manifest task
--- @return string "PASS" or "FAIL"
--- @return {string} The ids of proven tasks that fail the gate -- not
--- "completed", or "completed" with silent_bugs > 0 -- in manifest
--- order; empty exactly when the verdict is PASS.
local function compute_verdict(manifest: eval_types.Manifest,
    rows: {eval_types.Row}): string, {string}
  local by_id: {string: eval_types.Row} = {}
  for _, row in ipairs(rows) do
    by_id[row.task] = row
  end
  local failing_ids: {string} = {}
  for _, task in ipairs(manifest.tasks) do
    if task.status == "proven" then
      local row = by_id[task.id]
      if row == nil or row.status ~= "completed" or row.silent_bugs > 0 then
        failing_ids[#failing_ids + 1] = task.id
      end
    end
  end
  if #failing_ids == 0 then
    return "PASS", failing_ids
  end
  return "FAIL", failing_ids
end

--- CLI entry point.
--- @param ... string Command-line arguments
--- @return integer Exit code: 0 on PASS, 1 on FAIL or any failure
local function main(...: string): integer
  local a = parse_args({...})
  if a.help then
    print(USAGE)
    return 0
  end
  if a.err then
    io.stderr:write("score: " .. a.err .. "\n" .. USAGE)
    return 1
  end
  if not fs.is_dir(a.rundir) then
    io.stderr:write("score: no such run directory: " .. a.rundir .. "\n")
    return 1
  end
  local run_dir, sterr = stage_scoring_copy(a.rundir)
  if not run_dir then
    io.stderr:write("score: " .. tostring(sterr) .. "\n")
    return 1
  end
  local manifest, merr = stage.load_manifest(stage.MANIFEST_PATH)
  if not manifest then
    io.stderr:write("score: " .. tostring(merr) .. "\n")
    return 1
  end
  local meta, meerr = load_meta(run_dir)
  if not meta then
    io.stderr:write("score: " .. tostring(meerr) .. "\n")
    return 1
  end
  fold_probe(run_dir, meta)

  local rows: {eval_types.Row} = {}
  for _, task in ipairs(manifest.tasks) do
    rows[#rows + 1] = score_row(run_dir, task)
  end

  local verdict, failing_ids = compute_verdict(manifest, rows)
  local results: eval_types.EvalResults = {
    meta = meta,
    rows = rows,
    verdict = verdict,
  }
  local encoded, eerr = json.encode(results, {pretty = true})
  if not encoded then
    io.stderr:write("score: encode results.json: " .. tostring(eerr) .. "\n")
    return 1
  end
  local wok, werr = fs.write(fs.join(run_dir, "results.json"), encoded)
  if not wok then
    io.stderr:write("score: write results.json: " .. tostring(werr) .. "\n")
    return 1
  end

  if verdict == "PASS" then
    print("eval: PASS")
    return 0
  end
  print("eval: FAIL (" .. table.concat(failing_ids, ", ") .. ")")
  return 1
end

if proc.is_main() then
  os.exit(main(...))
end

local record score_module
  main: function(...: string): integer
  parse_args: function(argv: {string}): Args
  load_meta: function(run_dir: string): eval_types.ResultMeta | nil, string
  score_row: function(run_dir: string, task: eval_types.Task): eval_types.Row
  compute_verdict: function(manifest: eval_types.Manifest, rows: {eval_types.Row}):
  string, {string}
  out_dir_for: function(rundir_arg: string): string
end

local M: score_module = {
  main = main,
  parse_args = parse_args,
  load_meta = load_meta,
  score_row = score_row,
  compute_verdict = compute_verdict,
  out_dir_for = out_dir_for,
}

return M
