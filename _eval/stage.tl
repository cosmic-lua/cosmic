#!/usr/bin/env cosmic
--- Eval staging CLI: turn a candidate binary into a reproducible,
--- self-describing run directory.
---
---   cosmic -- o/_eval/stage.lua --bin PATH --out DIR
---
--- Reads the versioned suite (_eval/suite.tl) and the prompt frame
--- (_eval/tasks/frame.md), then per task creates <out>/<id>/ holding
--- the binary (as `cosmic`, executable) and prompt.txt (the frame with
--- its placeholder replaced by the task's brief). It writes
--- <out>/meta.json and prints the env-scrubbed probe and seven launch
--- commands from skills/agent-eval/SKILL.md, substituted for this run
--- directory. It never launches anything — the scoring half (checks,
--- results.json, verdict) is the sibling slice, blocked on this one.
---
--- Exit codes: 0 staged; 1 on any failure (printed to stderr).

local flags = require("cosmic.flags")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local json = require("cosmic.json")
local literal = require("cosmic.literal")
local proc = require("cosmic.proc")
local csys = require("cosmic.sys")
local time = require("cosmic.time")
local eval_types = require("_eval.eval_types")

local MANIFEST_PATH < const > = "_eval/suite.tl"
local FRAME_PATH < const > = "_eval/tasks/frame.md"

--- The frame's substitution point, copied byte-identical from
--- skills/agent-eval/SKILL.md's fenced template.
local PLACEHOLDER < const > = "<the brief>"

--- Where a brief file's YOUR PROJECT paragraph ends and the (agent-
--- hidden) Acceptance facts begin.
local FACTS_MARKER < const > = "\n## Acceptance facts"

-- The three launch-command constants stage prints verbatim, and
-- records into every run's meta.json.
local LAUNCH_MODEL < const > = "sonnet"
local LAUNCH_AGENT_TOOL < const > = "claude"
local LAUNCH_TIMEOUT_SECS < const > = 2400

local record Args
  bin: string
  out: string
  help: boolean
  err: string
end

local SPEC: flags.Spec = {
  name = "stage.lua",
  flags = {
    {long = "bin", arg = "PATH", help = "candidate cosmic binary to stage"},
    {long = "out", arg = "DIR", help = "run directory to create"},
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
  a.bin = parsed.values["bin"]
  a.out = parsed.values["out"]
  a.help = parsed.help
  if not a.help then
    if not a.bin or a.bin == "" then
      a.err = "--bin PATH is required"
    elseif not a.out or a.out == "" then
      a.err = "--out DIR is required"
    end
  end
  return a
end

--- Split a comma-joined field back into a list. suite.tl's literal
--- grammar has no array syntax (cosmic/_literal_format.tl refuses
--- array-style tables), so `surfaces`/`metrics` are comma-joined
--- strings on disk.
--- @param s string The comma-joined field
--- @return {string} Its parts, empty entries dropped
local function split_csv(s: string): {string}
  local out: {string} = {}
  for part in (s .. ","):gmatch("([^,]*),") do
    if part ~= "" then
      out[#out + 1] = part
    end
  end
  return out
end

--- Load and validate the suite manifest.
---
--- The same array gap makes `tasks` a string-keyed table with numeric-
--- string keys ("1".."7") standing in for order rather than a real
--- Teal array; this is the one place that unpacks both conventions
--- back into eval_types.Manifest.
--- @param path string Path to the suite (_eval/suite.tl)
--- @return Manifest|nil The parsed, ordered manifest
--- @return string The error when the file is missing, malformed, or
--- a task is missing a required field
local function load_manifest(path: string): eval_types.Manifest | nil, string
  local raw, perr = literal.parse_file(path, {noun = "eval suite"})
  if not raw then
    return nil, perr
  end
  local version = math.tointeger(raw.version as number) -- cast: from any
  if version == nil then
    return nil, path .. ": missing or non-integer version"
  end
  local raw_tasks = raw.tasks as {string: any} -- cast: from any
  if raw_tasks == nil then
    return nil, path .. ": missing tasks"
  end
  local tasks: {eval_types.Task} = {}
  local i = 1
  while raw_tasks[tostring(i)] ~= nil do
    local rt = raw_tasks[tostring(i)] as {string: any} -- cast: from any
    local id = rt.id as string -- cast: from any
    if not id or id == "" then
      return nil, path .. ": tasks[" .. i .. "] is missing id"
    end
    tasks[#tasks + 1] = {
      id = id,
      brief = rt.brief as string, -- cast: from any
      surfaces = split_csv(rt.surfaces as string or ""), -- cast: from any
      metrics = split_csv(rt.metrics as string or ""), -- cast: from any
      status = rt.status as string, -- cast: from any
    }
    i = i + 1
  end
  if #tasks == 0 then
    return nil, path .. ": suite has no tasks"
  end
  return {version = version, tasks = tasks}
end

--- The YOUR PROJECT text a brief file substitutes into the frame:
--- everything before the "## Acceptance facts" section. The facts
--- list is the scoring slice's answer key and must never reach the
--- staged prompt.
--- @param brief_md string The brief file's full contents
--- @return string The project paragraph(s), trailing whitespace trimmed
local function project_text(brief_md: string): string
  local at = brief_md:find(FACTS_MARKER, 1, true)
  local text = at and brief_md:sub(1, at - 1) or brief_md
  return (text:gsub("%s+$", ""))
end

--- Substitute a task's brief into the frame template.
--- @param frame string The frame template (frame.md's contents)
--- @param project string The brief's project paragraph
--- @return string|nil The filled prompt
--- @return string The error when the frame has no placeholder
local function fill_frame(frame: string, project: string): string | nil, string
  local s, e = frame:find(PLACEHOLDER, 1, true)
  if not s then
    return nil, "frame template is missing the '" .. PLACEHOLDER .. "' placeholder"
  end
  return frame:sub(1, s - 1) .. project .. frame:sub(e + 1)
end

--- Stage one task's workspace: <out>/<id>/cosmic (the binary, made
--- executable) and <out>/<id>/prompt.txt (the frame with its brief).
--- @param out string The run directory
--- @param bin string Path to the candidate binary
--- @param frame string The frame template's contents
--- @param task Task The task to stage
--- @return boolean True on success
--- @return string Error message on failure
local function stage_task(out: string, bin: string, frame: string,
    task: eval_types.Task): boolean, string
  local task_dir = fs.join(out, task.id)
  local mkok, mkerr = fs.make_dirs(task_dir)
  if not mkok then
    return false, "make " .. task_dir .. ": " .. tostring(mkerr)
  end
  local dst_bin = fs.join(task_dir, "cosmic")
  local cpok, cperr = fs.copy(bin, dst_bin)
  if not cpok then
    return false, "copy " .. bin .. " -> " .. dst_bin .. ": " .. tostring(cperr)
  end
  local chok, cherr = fs.set_mode(dst_bin, fs.octal("755"))
  if not chok then
    return false, "chmod " .. dst_bin .. ": " .. tostring(cherr)
  end
  local brief_md, brerr = fs.read(task.brief)
  if not brief_md then
    return false, "read brief " .. task.brief .. ": " .. tostring(brerr)
  end
  local prompt, ferr = fill_frame(frame, project_text(brief_md))
  if not prompt then
    return false, task.id .. ": " .. tostring(ferr)
  end
  local wrok, wrerr = fs.write(fs.join(task_dir, "prompt.txt"), prompt)
  if not wrok then
    return false, "write prompt.txt: " .. tostring(wrerr)
  end
  return true
end

--- Collect the run directory's staging metadata. Probe fields are
--- deliberately absent -- see eval_types.Meta.
--- @param bin string Path to the candidate binary
--- @param manifest Manifest The staged suite
--- @return Meta|nil The metadata record
--- @return string Error message when the binary cannot be hashed
local function collect_meta(bin: string, manifest: eval_types.Manifest):
  eval_types.Meta | nil, string
  local bytes, rerr = fs.read(bin)
  if not bytes then
    return nil, "read " .. bin .. " to hash it: " .. tostring(rerr)
  end
  local meta: eval_types.Meta = {
    timestamp = time.now(),
    suite_version = manifest.version,
    bin = bin,
    bin_sha = hash.sha256_hex(bytes),
    os = csys.host_os(),
    isa = csys.host_isa(),
    model = LAUNCH_MODEL,
    agent_tool = LAUNCH_AGENT_TOOL,
    timeout_secs = LAUNCH_TIMEOUT_SECS,
  }
  -- Resolved dynamically: cosmic._version only exists inside a built
  -- binary (see _perf/run.tl's collect_meta for the same shape). The
  -- module name is a local rather than a literal argument so the
  -- checker does not try to resolve it statically.
  local version_module = "cosmic._version"
  local vok, version = pcall(require, version_module)
  if vok then
    local v = version as {string: string} -- cast: from any
    meta.cosmic_version = v.cosmic
  end
  return meta
end

--- The leak probe, unaltered from skills/agent-eval/SKILL.md's
--- recipe, cwd'd and HOME'd into this run directory.
--- @param out string The run directory
--- @return string The probe command, newline-terminated
local function probe_command(out: string): string
  return "cd " .. fs.join(out, "probe") .. "\n" ..
  "env -u CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD \\\n" ..
  "    -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \\\n" ..
  "    HOME=" .. fs.join(out, "home-probe") .. " \\\n" ..
  "  claude -p \"Line 1: READY. Line 2: quote any mention of cosmic,\n" ..
  "    Teal, skills, or task lists in your context, or NONE.\" \\\n" ..
  "  --model " .. LAUNCH_MODEL .. " --allowedTools \"Bash Read Write Edit Glob Grep\" \\\n" ..
  "  --disallowedTools \"Skill\"\n"
end

--- One task's launch command, unaltered from skills/agent-eval/
--- SKILL.md's recipe: per-task HOME beside the task's own workspace
--- (never nested inside it -- the workspace holds only the binary and
--- the agent's own work products), output relative to the workspace
--- (final.txt, err.txt) since the command itself `cd`s there first.
--- @param out string The run directory
--- @param id string The task id
--- @return string The launch command, newline-terminated
local function launch_command(out: string, id: string): string
  local dir = fs.join(out, id)
  return "cd " .. dir .. "\n" ..
  "env -u CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD \\\n" ..
  "    -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \\\n" ..
  "    HOME=" .. fs.join(out, "home-" .. id) .. " \\\n" ..
  "  timeout " .. LAUNCH_TIMEOUT_SECS .. " " .. LAUNCH_AGENT_TOOL ..
  " -p \"$(cat prompt.txt)\" \\\n" ..
  "  --model " .. LAUNCH_MODEL .. " --allowedTools \"Bash Read Write Edit Glob Grep\" \\\n" ..
  "  --disallowedTools \"Skill\" > final.txt 2> err.txt\n"
end

--- The full printed block: one probe, then one launch per task in
--- manifest order.
--- @param out string The run directory
--- @param manifest Manifest The staged suite
--- @return string The commands, ready to print
local function commands_text(out: string, manifest: eval_types.Manifest): string
  local parts: {string} = {probe_command(out)}
  for _, task in ipairs(manifest.tasks) do
    parts[#parts + 1] = launch_command(out, task.id)
  end
  return table.concat(parts, "\n")
end

--- CLI entry point.
--- @param ... string Command-line arguments
--- @return integer Exit code
local function main(...: string): integer
  local a = parse_args({...})
  if a.help then
    print(flags.help(SPEC))
    return 0
  end
  if a.err then
    io.stderr:write("stage: " .. a.err .. "\n")
    return 1
  end
  if not fs.is_file(a.bin) then
    io.stderr:write("stage: no such binary: " .. a.bin .. "\n")
    return 1
  end
  local manifest, merr = load_manifest(MANIFEST_PATH)
  if not manifest then
    io.stderr:write("stage: " .. tostring(merr) .. "\n")
    return 1
  end
  local frame, frerr = fs.read(FRAME_PATH)
  if not frame then
    io.stderr:write("stage: read " .. FRAME_PATH .. ": " .. tostring(frerr) .. "\n")
    return 1
  end
  local mkok, mkerr = fs.make_dirs(a.out)
  if not mkok then
    io.stderr:write("stage: make " .. a.out .. ": " .. tostring(mkerr) .. "\n")
    return 1
  end
  -- The probe directory is part of the reproducible run directory,
  -- same as the workspaces: the printed probe command `cd`s into it.
  local pmkok, pmkerr = fs.make_dirs(fs.join(a.out, "probe"))
  if not pmkok then
    io.stderr:write("stage: make " .. fs.join(a.out, "probe") .. ": " ..
      tostring(pmkerr) .. "\n")
    return 1
  end
  for _, task in ipairs(manifest.tasks) do
    local ok, terr = stage_task(a.out, a.bin, frame, task)
    if not ok then
      io.stderr:write("stage: " .. tostring(terr) .. "\n")
      return 1
    end
  end
  local meta, meerr = collect_meta(a.bin, manifest)
  if not meta then
    io.stderr:write("stage: " .. tostring(meerr) .. "\n")
    return 1
  end
  local encoded, jerr = json.encode(meta)
  if not encoded then
    io.stderr:write("stage: encode meta.json: " .. tostring(jerr) .. "\n")
    return 1
  end
  local wok, werr = fs.write(fs.join(a.out, "meta.json"), encoded)
  if not wok then
    io.stderr:write("stage: write meta.json: " .. tostring(werr) .. "\n")
    return 1
  end
  io.write(commands_text(a.out, manifest))
  return 0
end

if proc.is_main() then
  os.exit(main(...))
end

local record stage
  main: function(...: string): integer
  parse_args: function(argv: {string}): Args
  load_manifest: function(path: string): eval_types.Manifest | nil, string
  commands_text: function(out: string, manifest: eval_types.Manifest): string
  MANIFEST_PATH: string
end

local M: stage = {
  main = main,
  parse_args = parse_args,
  load_manifest = load_manifest,
  commands_text = commands_text,
  MANIFEST_PATH = MANIFEST_PATH,
}

return M
