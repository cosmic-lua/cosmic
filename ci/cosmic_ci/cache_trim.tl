--- CI policy around the running driver's build-free cache maintenance.
--- The driver owns formats; incomplete reports withhold save outputs.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Plural = require("cosmic_ci.plural")
local Shape = require("cosmic.shape")

local record CacheTrim
  enum Family
    "compiles"
    "verdicts"
  end
  record Request
    family: Family
    paths: {string}
    since_ns: integer | nil
    whole: boolean
    restored: string | nil
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
  kept: integer | nil
  removed: integer | nil
  before_bytes: integer | nil
  after_bytes: integer | nil
  reached: boolean | nil
  unknown_tables: {string}
  unstamped_tables: {string}
  removed_set_aside: {string}
end
local record Report
  version: integer
  files: {File}
  digest: string | nil
  fresh: integer | nil
  warnings: {string}
end
local REPORT <const> = Shape.record_of("Report")
--- A report is bounded metadata, not cache contents. Truncation fails closed.
local report_limit <const> = 4 * 1024 * 1024

local function report(text: string, request: CacheTrim.Request): Report | nil, string
  local paths = request.paths
  local value, why = REPORT:decode_into(text)
  if value == nil then return nil, why end
  if value.version ~= 1 then return nil, "unsupported cache report version" end
  if #value.files ~= #paths then return nil, "cache report names another file set" end
  if #value.warnings > 0 then return nil, "cache report says maintenance was incomplete: " .. table.concat(value.warnings, "; ") end
  local present = false
  for i, file in ipairs(value.files) do
    if file.path ~= paths[i] then return nil, "cache report names another file set" end
    if file.state == "failed" then return nil, file.path .. ": " .. file.reason end
    present = present or file.state ~= "missing"
    for _, n in ipairs({ file.kept or 0, file.removed or 0, file.before_bytes or 0, file.after_bytes or 0 }) do
      if n < 0 then return nil, "cache report has a negative count" end
    end
  end
  if value.digest ~= nil and not present then return nil, "cache report digests no existing file" end
  if value.fresh ~= nil and (value.digest == nil or request.family ~= "compiles" or request.restored == nil) then
    return nil, "cache report has an unexpected fresh count"
  end
  if value.fresh ~= nil and value.fresh < 0 then return nil, "cache report has a negative fresh count" end
  if value.digest ~= nil and (#value.digest ~= 64 or not value.digest:match("^[0-9a-f]+$")) then
    return nil, "cache report has an invalid digest"
  end
  return value, ""
end

--- Normalize absent names too; resolve existing parents before comparing.
local function spelling(path: string): string | nil, string
  local resolved, trouble = Fs.absolute(path)
  if resolved ~= nil then return resolved, "" end
  local exists, why = Fs.exists(path)
  if exists ~= false then return nil, exists == nil and why or trouble end
  local parent, parent_trouble = spelling(Fs.dirname(path))
  if parent == nil then return nil, parent_trouble end
  local parts: {string} = {}
  for part in (parent .. "/" .. Fs.basename(path)):gmatch("[^/]+") do
    if part == ".." then table.remove(parts)
    elseif part ~= "." then parts[#parts + 1] = part end
  end
  return "/" .. table.concat(parts, "/"), ""
end

--- Snapshot cleanup must not name the live cache or any live sidecar,
--- through its spelling, a symlink or an existing hard link. An inspection
--- failure cannot establish ownership, so it retains the snapshot too.
function CacheTrim.snapshot_safe(live: string, restored: string): boolean | nil, string
  for _, left in ipairs({ "", "-wal", "-shm" }) do
    for _, right in ipairs({ "", "-wal", "-shm" }) do
      local a, b = live .. left, restored .. right
      local ca, why = spelling(a)
      if ca == nil then return nil, why end
      local cb, trouble = spelling(b)
      if cb == nil then return nil, trouble end
      if ca == cb then return false, "RESTORED aliases the live cache or its sidecars" end
      local sa, a_trouble = Fs.stat(a)
      if sa == nil and Fs.exists(a) ~= false then return nil, a_trouble end
      local sb, b_trouble = Fs.stat(b)
      if sb == nil and Fs.exists(b) ~= false then return nil, b_trouble end
      if sa ~= nil and sb ~= nil and sa.dev == sb.dev and sa.ino == sb.ino then
        return false, "RESTORED aliases the live cache or its sidecars"
      end
    end
  end
  return true, ""
end

local function remove_snapshot(path: string): string
  local failures: {string} = {}
  for _, suffix in ipairs({ "", "-wal", "-shm" }) do
    local name = path .. suffix
    local exists, trouble = Fs.exists(name)
    if exists == nil then failures[#failures + 1] = name .. ": " .. trouble
    elseif exists then
      local ok, why = Fs.remove(name)
      if not ok then failures[#failures + 1] = name .. ": " .. why end
    end
  end
  return table.concat(failures, "\n")
end

local function output(env: {string:string}, values: string): string
  local path = env.GITHUB_OUTPUT or ""
  if path == "" or values == "" then return "" end
  local ok, why = Fs.append(path, values)
  return ok and "" or why
end

local function invoke(request: CacheTrim.Request): Report | nil, string
  local start, why = Proc.relaunch()
  if start == nil then return nil, why end
  local argv: {string} = {}
  for i, word in ipairs(start.argv) do argv[i] = word end
  for _, word in ipairs({ "cache", "trim", request.family }) do argv[#argv + 1] = word end
  for _, path in ipairs(request.paths) do argv[#argv + 1] = path end
  if request.whole then argv[#argv + 1] = "--whole"
  else
    argv[#argv + 1] = "--since-ns"
    argv[#argv + 1] = tostring(request.since_ns)
  end
  if request.restored ~= nil then
    argv[#argv + 1], argv[#argv + 2] = "--restored", request.restored
  end
  argv[#argv + 1] = "--json"
  local env = Env.all()
  for name, value in pairs(start.env) do env[name] = value end
  local fds: {integer:integer | string} = {}
  for fd, given in pairs(start.fds) do fds[fd] = given end
  local result, trouble = Child.run(argv, { env = env, fds = fds,
    stdout = "capture", stderr = "capture", capture_limit = report_limit })
  if result == nil then return nil, trouble end
  if result.truncated then return nil, "cache maintenance report was truncated" end
  if not result.ok then
    return nil, "cache maintenance ended " .. tostring(result.code or result.signal) .. ": " ..
      (result.stderr or "")
  end
  local decoded, decode_trouble = report(result.stdout or "", request)
  if decoded == nil then return nil, decode_trouble end
  return decoded, result.stderr or ""
end

--- Cleans the owned snapshot before Child.run's signal is redelivered,
--- and publishes save outputs only from a complete validated report.
function CacheTrim.run(request: CacheTrim.Request, env: {string:string}): string, string
  local verb = request.family .. "-trim"
  local opened, guard_trouble = Child.guard()
  if opened == nil then
    local cleanup = request.restored ~= nil and remove_snapshot(request.restored) or ""
    return "", verb .. ": " .. guard_trouble .. (cleanup ~= "" and "\n" .. cleanup or "") .. "\n"
  end
  local guard <close> = opened
  local value: Report = nil
  local trouble = ""
  if #request.paths > 0 then
    local ok, answer, why = pcall(invoke, request)
    if ok then value, trouble = answer as Report, why else trouble = tostring(answer) end
  end
  if request.restored ~= nil then
    local why = remove_snapshot(request.restored)
    if why ~= "" then value = nil; trouble = trouble .. "\n" .. why end
  end
  if guard:cancelled() ~= 0 then return "", verb .. ": maintenance cancelled\n" end
  if value == nil then return "", trouble == "" and "" or verb .. ": " .. trouble .. "\n" end
  local lines: {string} = {}
  for _, file in ipairs(value.files) do
    local line = verb .. ": " .. file.path .. ": " .. file.state
    if file.kept ~= nil then line = line .. "; kept " .. file.kept end
    if file.removed ~= nil then line = line .. ", removed " .. file.removed end
    if file.before_bytes ~= nil and file.after_bytes ~= nil then
      line = line .. "; " .. file.before_bytes .. " -> " .. Plural.count(file.after_bytes, "byte")
    end
    lines[#lines + 1] = line .. "\n"
    if #file.removed_set_aside > 0 then
      lines[#lines + 1] = verb .. ": removed set aside files: " .. table.concat(file.removed_set_aside, ", ") .. "\n"
    end
    for _, names in ipairs({ file.unknown_tables, file.unstamped_tables }) do
      if #names > 0 then trouble = trouble .. verb .. ": " .. file.path .. ": kept tables: " .. table.concat(names, ", ") .. "\n" end
    end
  end
  for _, warning in ipairs(value.warnings) do trouble = trouble .. verb .. ": " .. warning .. "\n" end
  local values = ""
  if value.digest ~= nil then
    values = "digest=" .. value.digest .. "\n"
    lines[#lines + 1] = verb .. ": digest " .. value.digest .. "\n"
  end
  if value.fresh ~= nil then
    values = values .. "fresh=" .. value.fresh .. "\n"
    lines[#lines + 1] = verb .. ": " .. value.fresh .. " compiles not in what was restored\n"
  end
  local unsaid = output(env, values)
  if unsaid ~= "" then trouble = trouble .. verb .. ": " .. unsaid .. "\n" end
  return table.concat(lines), trouble
end

--- SINCE as nanoseconds, checked before multiplication can overflow.
function CacheTrim.since(argv: {string}): integer | nil
  local since = math.tointeger(tonumber(argv[1] or ""))
  if since == nil or since < 0 or since > math.maxinteger // 1000000000 then return nil end
  return since * 1000000000
end

return CacheTrim
