#!/usr/bin/env cosmic
--- Eval journal bundler: collect a staged, agent-run run directory's
--- per-task journals (NOTES.md, final.txt) into one zip, so they
--- survive after the operator's run directory is cleaned up.
---
---   cosmic -- o/_eval/bundle.lua --run-dir DIR --out FILE
---
--- Per task id in the versioned suite (_eval/suite.tl, via
--- _eval.stage's loader -- never a directory listing, since a run dir
--- may hold extra scratch entries), <run-dir>/<id>/NOTES.md and
--- <run-dir>/<id>/final.txt are added to --out when present; a task
--- directory missing both files is skipped, not an error (an
--- incomplete or failed run still bundles what exists).
---
--- Retention naming convention, for a later cadence-wiring child to
--- use verbatim as release-asset names: score.tl's results.json is
--- uploaded unmodified as "eval-results.json"; this tool's output is
--- uploaded as "eval-journals.zip". Fetching either back is
--- `_perf/baseline.tl --repo OWNER/NAME --out PATH --asset <name>` --
--- already generic via --asset (also reused for size.json), so no new
--- fetch code is needed for either asset.
---
--- Verdict line, always the last line printed:
---   eval-bundle: OK <out> (<n> files)   files bundled, exit 0
---   eval-bundle: FAIL (<reason>)        any failure, exit 1

local flags = require("cosmic.flags")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local zip = require("cosmic.zip")
local stage = require("_eval.stage")

local record Args
  run_dir: string
  out: string
  help: boolean
  err: string
end

local SPEC: flags.Spec = {
  name = "bundle.lua",
  flags = {
    {long = "run-dir", arg = "DIR", required = true, help = "staged/run eval run directory"},
    {long = "out", arg = "FILE", required = true, help = "zip file to write journals into"},
  },
}

--- Parse command-line arguments.
--- @param argv {string} Raw arguments
--- @return Args Parsed arguments; Args.err is set on parse failure
local function parse_args(argv: {string}): Args
  local a: Args = {}
  local parsed, perr = flags.parse(SPEC, argv)
  if not parsed then
    a.err = "argument parse failed: " .. tostring(perr)
    return a
  end
  a.run_dir = parsed.values["run-dir"]
  a.out = parsed.values["out"]
  a.help = parsed.help
  return a
end

--- Add one task's journal files to `archive`, opening `out_path` in
--- append mode on the first file found (append creates the archive
--- when it does not yet exist).
--- @param archive Archive|nil The open archive, or nil if none yet
--- @param out_path string Where to open the archive if `archive` is nil
--- @param name string Zip entry name
--- @param source string Path to the file on disk
--- @return Archive|nil The archive to keep using (open or already-open)
--- @return boolean True if the file was added
--- @return string Error message on an open or add failure
local function add_journal_file(archive: zip.Archive, out_path: string, name: string,
    source: string): zip.Archive, boolean, string
  if not fs.is_file(source) then
    return archive, false, nil
  end
  if not archive then
    local opened, oerr = zip.open(out_path, {mode = "append"})
    if not opened then
      return nil, false, "open " .. out_path .. ": " .. tostring(oerr)
    end
    archive = opened
  end
  local ok, aerr = archive:add_file(name, source)
  if not ok then
    return archive, false, "add " .. name .. ": " .. tostring(aerr)
  end
  return archive, true, nil
end

--- Bundle every task's NOTES.md and final.txt (whichever exist) from
--- `run_dir` into a zip at `out_path`.
--- @param run_dir string The staged/run eval run directory
--- @param out_path string Where to write the zip archive
--- @return integer|nil The count of files written
--- @return string Error message on a zip-open or add failure
local function bundle_journals(run_dir: string, out_path: string): integer | nil, string
  local manifest, merr = stage.load_manifest(stage.MANIFEST_PATH)
  if not manifest then
    return nil, tostring(merr)
  end
  local archive: zip.Archive
  local count = 0
  for _, task in ipairs(manifest.tasks) do
    local task_dir = fs.join(run_dir, task.id)
    for _, base in ipairs({"NOTES.md", "final.txt"}) do
      local added: boolean
      local aerr: string
      archive, added, aerr = add_journal_file(archive, out_path,
        task.id .. "/" .. base, fs.join(task_dir, base))
      if aerr then
        if archive then
          local _ok, _cerr = archive:close()
        end
        return nil, aerr
      end
      if added then
        count = count + 1
      end
    end
  end
  if archive then
    local ok, cerr = archive:close()
    if not ok then
      return nil, "close " .. out_path .. ": " .. tostring(cerr)
    end
  end
  return count
end

--- CLI entry point.
--- @param ... string Command-line arguments
--- @return integer Exit code: 0 on success, 1 on any failure
local function main(...: string): integer
  local a = parse_args({...})
  if a.help then
    print(flags.help(SPEC))
    return 0
  end
  if a.err then
    print("eval-bundle: FAIL (" .. a.err .. ")")
    return 1
  end
  local count, berr = bundle_journals(a.run_dir, a.out)
  if not count then
    print("eval-bundle: FAIL (" .. tostring(berr) .. ")")
    return 1
  end
  print("eval-bundle: OK " .. a.out .. " (" .. count .. " files)")
  return 0
end

if proc.is_main() then
  os.exit(main(...))
end

local record bundle
  type Args = Args
  main: function(...: string): integer
  parse_args: function(argv: {string}): Args
  bundle_journals: function(run_dir: string, out_path: string): integer | nil, string
end

local M: bundle = {
  main = main,
  parse_args = parse_args,
  bundle_journals = bundle_journals,
}

return M
