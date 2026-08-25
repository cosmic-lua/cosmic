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
--- is mirrored once, up front, into a genuinely process-private
--- staging directory via `fs.temp_dir` (mkdtemp, under `TEST_TMPDIR`/
--- `TMPDIR` when set, `/tmp` otherwise -- never this project's own
--- `o/`, which is root-owned in CI's coverage lane, and never relative
--- to the caller's cwd). mkdtemp guarantees a unique path per run, so
--- two run dirs that share a basename cannot collide. Every later step
--- -- checks, journal parse, results.json -- runs against that copy
--- only, and the copy is removed once scoring finishes.
---
--- `results.json` is written to `--out PATH` when given; otherwise to
--- a default location (independent of both the staging copy, which is
--- removed, and the read-only run dir argument) whose absolute path is
--- printed on the line before the verdict line.
---
--- Exit codes: 0 on PASS; 1 on FAIL or any failure (printed to stderr).
local flags = require("cosmic.flags")
local fs = require("cosmic.fs")
local json = require("cosmic.json")
local proc = require("cosmic.proc")
local shape = require("cosmic.shape")
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
  out: string
  help: boolean
  err: string
end

local USAGE < const > = "usage: score.lua [--out PATH] <run dir>\n"

local SPEC: flags.Spec = {
  name = "score.lua",
  flags = {
    {long = "out", arg = "PATH",
      help = "write results.json to PATH instead of the default location"},
  },
}

--- The base directory temp dirs (staging copies, the default
--- results.json location) are created under -- never this project's
--- own `o/`: CI's coverage lane runs as an unprivileged user against a
--- root-owned `o/`, so writing there fails with EACCES. `TEST_TMPDIR`
--- is the same convention every test in this tree already honors;
--- `TMPDIR` is its non-test equivalent; `/tmp` is the fallback so a
--- bare CLI invocation from any cwd stages to a well-known,
--- OS-reclaimed location instead of littering wherever the caller
--- happened to be standing.
--- @return string The absolute base directory for this run's temp dirs
local function temp_base(): string
  return os.getenv("TEST_TMPDIR") or os.getenv("TMPDIR") or "/tmp"
end

--- Mirror `rundir_arg` into a fresh, genuinely process-private staging
--- directory (via `fs.temp_dir`/mkdtemp) and return that copy's
--- (absolute) path. Every later step -- meta/probe loading, checks,
--- journal parsing -- runs against the copy, so `rundir_arg` is only
--- ever read here, never written to. mkdtemp guarantees a unique path
--- on every call regardless of what `rundir_arg` is named, so two run
--- dirs that happen to share a basename (e.g. two directories both
--- named "run_pass" at different paths) stage into two independent
--- directories -- there is no shared, basename-keyed slot for a second
--- scoring call to collide with. Staging into an ABSOLUTE destination
--- also closes a distinct bug: `cosmic.child` applies `cwd` in the
--- spawned child before exec, so a relative workspace joined into
--- argv[0] would resolve a second time against the child's new cwd and
--- fail with ENOENT; mkdtemp always returns an absolute path, so that
--- double resolution cannot happen. The caller is responsible for
--- removing the returned directory once scoring finishes.
--- @param rundir_arg string The run dir argument, as given on argv
--- @return string|nil The scoring copy's path
--- @return string The error, when the copy could not be staged
local function stage_scoring_copy(rundir_arg: string): string | nil, string
  local dst, terr = fs.temp_dir(fs.join(temp_base(), "cosmic-eval-scored-XXXXXX"))
  if not dst then
    return nil, "create staging dir: " .. tostring(terr)
  end
  local cok, cerr = fs.copy_tree(rundir_arg, dst)
  if not cok then
    local _ok, _err = fs.remove_all(dst)
    return nil, "stage " .. rundir_arg .. " -> " .. dst .. ": " .. tostring(cerr)
  end
  return dst
end

--- The default `results.json` destination when no `--out` is given: a
--- fresh temp file whose lifetime is independent of both the staging
--- copy (removed once scoring finishes) and the read-only run dir
--- argument (score.tl never writes into its input).
--- @return string|nil The absolute path results.json should be written to
--- @return string The error, when the destination could not be created
local function default_results_path(): string | nil, string
  local dir, terr = fs.temp_dir(fs.join(temp_base(), "cosmic-eval-results-XXXXXX"))
  if not dir then
    return nil, "create results dir: " .. tostring(terr)
  end
  return fs.join(dir, "results.json")
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
      a.out = parsed.values.out
    end
  end
  return a
end

--- meta.json's shape: the nine fields stage.tl always writes, plus
--- cosmic_version, which is optional because stage.tl leaves it unset
--- when the staged binary's own version could not be resolved.
---
--- `into` hands back the SAME table it validated, so a meta.json that
--- carries keys beyond these keeps them. That is inert here:
--- probe_output and leaked are filled in by fold_probe either way, and
--- nothing walks a ResultMeta's keys.
local META_SPEC < const > = shape.record({
    timestamp = shape.number,
    suite_version = shape.integer,
    bin = shape.string,
    bin_sha = shape.string,
    os = shape.string,
    isa = shape.string,
    model = shape.string,
    agent_tool = shape.string,
    timeout_secs = shape.integer,
    cosmic_version = shape.optional(shape.string),
  })

--- Load and validate <run dir>/meta.json into the shared ten staged
--- fields; probe_output/leaked are filled in separately by fold_probe.
--- @param run_dir string The run directory
--- @return ResultMeta|nil The parsed metadata (probe fields unset)
--- @return string The error when the file is missing, malformed, or a
--- required field is absent or the wrong type
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
  local meta, serr: eval_types.ResultMeta | nil, string = shape.into(raw, META_SPEC)
  if not meta then
    return nil, path .. ": " .. serr
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

--- Run every scoring step against an already-staged copy: load the
--- manifest and meta, fold the probe, score every task's row, compute
--- the verdict, and write results.json to `out` (or, when `out` is
--- nil/empty, to a fresh default location whose absolute path is
--- printed on the line before the verdict line).
--- @param run_dir string The staged scoring copy (see stage_scoring_copy)
--- @param out string|nil The --out destination for results.json, or
--- nil/"" for the default location
--- @return integer Exit code: 0 on PASS, 1 on FAIL or any failure
local function score_staged(run_dir: string, out: string): integer
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

  local dest = out
  local printed_default = false
  if not dest or dest == "" then
    local dpath, derr = default_results_path()
    if not dpath then
      io.stderr:write("score: " .. tostring(derr) .. "\n")
      return 1
    end
    dest = dpath
    printed_default = true
  end
  local wok, werr = fs.write(dest, encoded)
  if not wok then
    io.stderr:write("score: write results.json: " .. tostring(werr) .. "\n")
    return 1
  end
  if printed_default then
    print(fs.absolute_path(dest))
  end

  if verdict == "PASS" then
    print("eval: PASS")
    return 0
  end
  print("eval: FAIL (" .. table.concat(failing_ids, ", ") .. ")")
  return 1
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
  -- The staging copy is removed unconditionally once scoring is done
  -- -- PASS, FAIL, or an error inside score_staged -- so it never
  -- outlives the run it was created for. score_staged only returns
  -- (it never throws), so this always runs.
  local code = score_staged(run_dir, a.out)
  local _ok, _err = fs.remove_all(run_dir)
  return code
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
end

local M: score_module = {
  main = main,
  parse_args = parse_args,
  load_meta = load_meta,
  score_row = score_row,
  compute_verdict = compute_verdict,
}

return M
