--- CI policy around the running driver's build-free cache maintenance.
--- The driver owns formats; incomplete reports withhold save outputs.
local Fs = require("cosmic.fs")
local Maps = require("cosmic_ci.maps")
local Proc = require("cosmic.proc")
local Seams = require("cosmic_ci.seams")
local Plural = require("cosmic_ci.plural")
local Signal = require("cosmic.signal")
local Shape = require("cosmic.shape")

local record CacheTrim
  enum Family
    "compiles"
    "verdicts"
  end
  record Request
    mut family: Family
    paths: {string}
    since_ns?: integer
    whole: boolean
    mut restored?: string
  end
  --- What a trim said: standard output and the diagnostics.
  record Said
    out: string
    err: string
  end
  --- What a command of the driver came to: its exit status and what it said.
  record Command
    mut code: integer
    mut out: string
    mut err: string
  end
  --- Whether cleaning a snapshot is safe.
  enum Ownership
    "owned"
    "aliased"
    "unknown"
  end
  --- [`CacheTrim.snapshot_safe`]'s answer: `owned` where the snapshot is nobody else's,
  --- `aliased` where it names the live cache, `unknown` where it could not be told.
  record Snapshot
    ownership: Ownership
    why: string
  end
end
local enum State
  "trimmed"
  "kept"
  "missing"
  "failed"
end
local record File
  path: string
  state: State
  reason: string
  kept?: integer
  removed?: integer
  before_bytes?: integer
  after_bytes?: integer
  reached?: boolean
  unknown_tables: {string}
  unstamped_tables: {string}
  removed_set_aside: {string}
end
local record Report
  version: integer
  files: {File}
  digest?: string
  fresh?: integer
  warnings: {string}
end
local REPORT <const> = Shape.record_of("Report")
--- A report is bounded metadata, not cache contents. Truncation fails closed.
local report_limit <const> = 4 * 1024 * 1024

local function report(text: string, request: CacheTrim.Request): Report?, string
  local paths = request.paths
  local value, why = REPORT:decode_into(text)
  if value == nil then return nil, why end
  if value.version ~= 1 then return nil, "unsupported cache report version" end
  if #value.files ~= #paths then return nil, "cache report names another file set" end
  if #value.warnings > 0 then
    return nil, "cache report says maintenance was incomplete: " .. table.concat(value.warnings, "; ")
  end
  local present = false
  for i, file in ipairs(value.files) do
    if file.path ~= paths[i] then return nil, "cache report names another file set" end
    if file.state == "failed" then return nil, file.path .. ": " .. file.reason end
    present = present or file.state ~= "missing"
    for _, n in ipairs({ file.kept or 0, file.removed or 0, file.before_bytes or 0, file.after_bytes or 0 }) do
      if n < 0 then return nil, "cache report has a negative count" end
    end
  end
  if value.digest ~= nil and not present then
    return nil, "cache report digests no existing file"
  end
  if value.fresh ~= nil and (value.digest == nil or request.family ~= "compiles" or request.restored == nil) then
    return nil, "cache report has an unexpected fresh count"
  end
  local fresh = value.fresh
  if fresh ~= nil and fresh < 0 then
    return nil, "cache report has a negative fresh count"
  end
  local digest = value.digest
  if digest ~= nil and (#digest ~= 64 or not digest:match("^[0-9a-f]+$")) then
    return nil, "cache report has an invalid digest"
  end
  return value, ""
end

--- Normalize absent names too; resolve existing parents before comparing.
local function spelling(path: string): string?, string
  local seams = Seams.calls()
  local resolved, trouble = seams.fs_absolute(path)
  if resolved ~= nil then return resolved, "" end
  local exists, why = seams.fs_exists(path)
  if exists == nil then return nil, why end
  if exists ~= false then return nil, trouble end
  local parent, parent_trouble = spelling(Fs.dirname(path))
  if parent == nil then return nil, parent_trouble end
  local parts: mut {string} = {}
  for part in (parent .. "/" .. Fs.basename(path)):gmatch("[^/]+") do
    if part == ".." then
      table.remove(parts)
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return "/" .. table.concat(parts, "/"), ""
end

--- Snapshot cleanup must not name the live cache or any live sidecar,
--- through its spelling, a symlink or an existing hard link. An inspection
--- failure cannot establish ownership, so it retains the snapshot too.
function CacheTrim.snapshot_safe(live: string, restored: string): CacheTrim.Snapshot
  local seams = Seams.calls()
  for _, left in ipairs({ "", "-wal", "-shm" }) do
    for _, right in ipairs({ "", "-wal", "-shm" }) do
      local a, b = live .. left, restored .. right
      local ca, why = spelling(a)
      if ca == nil then return { ownership = "unknown", why = why } end
      local cb, trouble = spelling(b)
      if cb == nil then return { ownership = "unknown", why = trouble } end
      if ca == cb then
        return { ownership = "aliased", why = "RESTORED aliases the live cache or its sidecars" }
      end
      local sa, a_trouble = Fs.stat(a)
      if sa == nil then
        local there, _ = seams.fs_exists(a)
        if there ~= false then return { ownership = "unknown", why = a_trouble } end
      end
      local sb, b_trouble = Fs.stat(b)
      if sb == nil then
        local there, _ = seams.fs_exists(b)
        if there ~= false then return { ownership = "unknown", why = b_trouble } end
      end
      if sa ~= nil and sb ~= nil and sa.dev == sb.dev and sa.ino == sb.ino then
        return { ownership = "aliased", why = "RESTORED aliases the live cache or its sidecars" }
      end
    end
  end
  return { ownership = "owned", why = "" }
end

local function remove_snapshot(path: string): string
  local failures: mut {string} = {}
  for _, suffix in ipairs({ "", "-wal", "-shm" }) do
    local name = path .. suffix
    local exists, trouble = Seams.calls().fs_exists(name)
    if exists == nil then
      failures[#failures + 1] = name .. ": " .. trouble
    elseif exists then
      local ok, why = Fs.remove(name)
      if not ok then failures[#failures + 1] = name .. ": " .. why end
    end
  end
  return table.concat(failures, "\n")
end

local function output(env: {string:string}, values: string): string
  local path = env["GITHUB_OUTPUT"] or ""
  if path == "" or values == "" then return "" end
  local ok, why = Seams.calls().fs_append(path, values)
  return if ok then "" else why end
end

--- What [`invoke`] answered, kept where the function that runs it under `pcall` can read it.
local record Invoked
  mut report?: Report
  mut trouble: string
end

--- Runs the driver's trim of `request`'s files and reads its report.
local function invoke(request: CacheTrim.Request): Invoked
  local start, why = Proc.relaunch()
  if start == nil then return { trouble = why } end
  local argv: mut {string} = {}
  for _, word in ipairs(start.argv) do argv[#argv + 1] = word end
  for _, word in ipairs({ "cache", "trim", request.family }) do argv[#argv + 1] = word end
  for _, path in ipairs(request.paths) do argv[#argv + 1] = path end
  if request.whole then
    argv[#argv + 1] = "--whole"
  else
    argv[#argv + 1] = "--since-ns"
    argv[#argv + 1] = tostring(request.since_ns)
  end
  local restored = request.restored
  if restored ~= nil then
    argv[#argv + 1] = "--restored"
    argv[#argv + 1] = restored
  end
  argv[#argv + 1] = "--json"
  local env = Maps.with(Seams.calls().env_all(), start.env)
  local fds: mut {integer:integer | string} = {}
  for fd, given in pairs(start.fds) do fds[fd] = given end
  local result, trouble = Seams.calls().child_run(argv, { env = env, fds = fds,
    stdout = "capture", stderr = "capture", capture_limit = report_limit })
  if result == nil then return { trouble = trouble } end
  if result.truncated then return { trouble = "cache maintenance report was truncated" } end
  if not result.ok then
    return { trouble = "cache maintenance ended " .. tostring(result.code or result.signal) .. ": " ..
        (result.stderr or "") }
  end
  local decoded, decode_trouble = report(result.stdout or "", request)
  if decoded == nil then return { trouble = decode_trouble } end
  return { report = decoded, trouble = result.stderr or "" }
end

--- The body of [`CacheTrim.run`] while `guard` holds the signals.
local function trim(guard: Signal.Guard, request: CacheTrim.Request, env: {string:string}, verb: string): string, string
  local value: Report? = nil
  local trouble = ""
  if #request.paths > 0 then
    local invoked: Invoked = { trouble = "" }
    local ok, raised = pcall(function()
      local answered = invoke(request)
      invoked.report, invoked.trouble = answered.report, answered.trouble
    end)
    if ok then value, trouble = invoked.report, invoked.trouble else trouble = tostring(raised) end
  end
  local restored = request.restored
  if restored ~= nil then
    local why = remove_snapshot(restored)
    if why ~= "" then
      value = nil
      trouble = trouble .. "\n" .. why
    end
  end
  if guard:cancelled() ~= 0 then return "", verb .. ": maintenance cancelled\n" end
  if value == nil then
    if trouble == "" then return "", "" end
    return "", verb .. ": " .. trouble .. "\n"
  end
  local lines: mut {string} = {}
  for _, file in ipairs(value.files) do
    local line = verb .. ": " .. file.path .. ": " .. file.state
    local kept = file.kept
    if kept ~= nil then line = line .. "; kept " .. tostring(kept) end
    local removed = file.removed
    if removed ~= nil then line = line .. ", removed " .. tostring(removed) end
    local after_bytes = file.after_bytes
    local before_bytes = file.before_bytes
    if before_bytes ~= nil and after_bytes ~= nil then
      line = line .. "; " .. tostring(before_bytes) .. " -> " .. Plural.count(after_bytes, "byte")
    end
    lines[#lines + 1] = line .. "\n"
    if #file.removed_set_aside > 0 then
      lines[#lines + 1] = verb .. ": removed set aside files: " .. table.concat(file.removed_set_aside, ", ") .. "\n"
    end
    for _, names in ipairs({ file.unknown_tables, file.unstamped_tables }) do
      if #names > 0 then
        trouble = trouble .. verb .. ": " .. file.path .. ": kept tables: " .. table.concat(names, ", ") .. "\n"
      end
    end
  end
  for _, warning in ipairs(value.warnings) do
    trouble = trouble .. verb .. ": " .. warning .. "\n"
  end
  local values = ""
  local digest = value.digest
  if digest ~= nil then
    values = "digest=" .. digest .. "\n"
    lines[#lines + 1] = verb .. ": digest " .. digest .. "\n"
  end
  local fresh = value.fresh
  if fresh ~= nil then
    local count = tostring(fresh)
    values = values .. "fresh=" .. count .. "\n"
    lines[#lines + 1] = verb .. ": " .. count .. " compiles not in what was restored\n"
  end
  local unsaid = output(env, values)
  if unsaid ~= "" then trouble = trouble .. verb .. ": " .. unsaid .. "\n" end
  return table.concat(lines), trouble
end

--- Cleans the owned snapshot before Child.run's signal is redelivered,
--- and publishes save outputs only from a complete validated report.
function CacheTrim.run(request: CacheTrim.Request, env: {string:string}): CacheTrim.Said
  local verb = request.family .. "-trim"
  local opened, guard_trouble = Seams.calls().signal_guard()
  if opened == nil then
    local restored = request.restored
    local cleanup = ""
    if restored ~= nil then cleanup = remove_snapshot(restored) end
    if cleanup ~= "" then cleanup = "\n" .. cleanup end
    return { out = "", err = verb .. ": " .. guard_trouble .. cleanup .. "\n" }
  end
  local guard <close> = opened
  local lines, trouble = trim(guard, request, env, verb)
  return { out = lines, err = trouble }
end

--- SINCE as nanoseconds, checked before multiplication can overflow.
function CacheTrim.since(argv: {string}): integer?
  local since = math.tointeger(tonumber(argv[1] or ""))
  if since == nil or since < 0 or since > math.maxinteger // 1000000000 then return nil end
  return since * 1000000000
end

return CacheTrim
