local CacheTrim = require("cosmic_ci.cache_trim")
local Child = require("cosmic.child")
local Compiles = require("cosmic_ci.compiles")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Predicate = require("cosmic_ci.fs_predicate")
local Proc = require("cosmic.proc")
local Seams = require("cosmic_ci.seams")
local Signal = require("cosmic.signal")

--- A count a stand-in keeps.
local record Count
  mut value: integer
end

--- A report as the driver prints it, each member already JSON text (the
--- members a test spoils are written as the spoilt text), `digest` and
--- `fresh` left out where nil.
local record Parts
  mut version: string
  mut digest?: string
  mut fresh?: string
  mut warnings: string
  mut files: {string}
end

--- One file of a report: trimmed, with `kept` rows, or in `state`.
local function file_json(path: string, state: string, kept: integer): string
  return '{"path":' .. Json.quote(path) .. ',"state":' .. Json.quote(state) .. ',"reason":"","kept":' ..
    tostring(kept) .. ',"removed":0,"unknown_tables":[],"unstamped_tables":[],"removed_set_aside":[]}'
end

local function encoded(path: string): Parts
  return { version = "1", digest = Json.quote(string.rep("a", 64)), warnings = "[]",
    files = { file_json(path, "trimmed", 1) } }
end

local function text_of(parts: Parts): string
  local members: mut {string} = { '"version":' .. parts.version, '"warnings":' .. parts.warnings,
    '"files":[' .. table.concat(parts.files, ",") .. "]" }
  local digest, fresh = parts.digest, parts.fresh
  if digest ~= nil then members[#members + 1] = '"digest":' .. digest end
  if fresh ~= nil then members[#members + 1] = '"fresh":' .. fresh end
  return "{" .. table.concat(members, ",") .. "}"
end

--- What [`CacheTrim.run`] came to under a stand-in for the driver: what it
--- said, or why it raised.
local record Tried
  mut ok: boolean
  mut out: string
  mut err: string
end

--- [`CacheTrim.run`] of `request` while the driver answers `payload` (and
--- exits `code`, and says it truncated its report), a raise caught.
local function trying(request: CacheTrim.Request, env: {string:string}, payload: string,
                      code?: integer, truncated?: boolean): Tried
  local seams = Seams.calls()
  local original = seams.child_run
  seams.child_run = function(_argv: {string}, _options?: Child.Options): Child.Result?, string
    return { ok = code == nil or code == 0, code = code or 0, signal = nil, stdout = payload,
      stderr = "diagnostic", truncated = truncated == true, timed_out = false, captured = {} }, ""
  end
  local tried: Tried = { ok = false, out = "", err = "" }
  local ok, raised = pcall(function()
    local said = CacheTrim.run(request, env)
    tried.out, tried.err = said.out, said.err
  end)
  seams.child_run = original
  tried.ok = ok
  if not ok then tried.err = tostring(raised) end
  return tried
end

--- [`trying`], refusing a raise: what the run said.
local function mocked(request: CacheTrim.Request, env: {string:string}, payload: string,
                      code?: integer, truncated?: boolean): string, string
  local tried = trying(request, env, payload, code, truncated)
  assert(tried.ok, tried.err)
  return tried.out, tried.err
end

--- [`Compiles.command`], a raise caught: code -1 and what was raised as its diagnostics.
local function guarded(argv: {string}, env: {string:string}): CacheTrim.Command
  local held: CacheTrim.Command = { code = -1, out = "", err = "" }
  local ok, raised = pcall(function()
    local command = Compiles.command(argv, env)
    held.code, held.out, held.err = command.code, command.out, command.err
  end)
  if not ok then held.err = tostring(raised) end
  return held
end

local function test_invalid_or_incomplete_reports_never_publish_save_keys(tmp: string)
  local path = tmp .. "/cache.db"
  local request: CacheTrim.Request = { family = "compiles", paths = { path }, since_ns = 1, whole = false }
  local cases: mut {Parts} = {}
  local bad = encoded(path)
  bad.version = "2"
  cases[#cases + 1] = bad
  cases[#cases + 1] = encoded(path .. "other")
  bad = encoded(path)
  bad.files = {}
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.files = { file_json(path, "trimmed", 1), file_json(path, "trimmed", 1) }
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.files = { file_json(path, "failed", 1) }
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.files = { file_json(path, "missing", 1) }
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.files = { file_json(path, "trimmed", -1) }
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.digest = Json.quote("bad")
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.fresh = "1"
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.warnings = '["comparison incomplete"]'
  cases[#cases + 1] = bad
  for i, value in ipairs(cases) do
    local output = tmp .. "/output" .. tostring(i)
    local _, err = mocked(request, { GITHUB_OUTPUT = output }, text_of(value))
    assert(err ~= "" and Predicate.absent(output), err)
  end
  for _, text in ipairs({ "not JSON", '{"version":1', '[]', '{}' }) do
    local _, err = mocked(request, { GITHUB_OUTPUT = tmp .. "/invalid" }, text)
    assert(err ~= "" and Predicate.absent(tmp .. "/invalid"))
  end
  local good = text_of(encoded(path))
  for _, code in ipairs({ 1, 2 }) do
    local _, err = mocked(request, { GITHUB_OUTPUT = tmp .. "/failed" }, good, code)
    assert(err ~= "" and Predicate.absent(tmp .. "/failed"))
  end
  local _, err = mocked(request, { GITHUB_OUTPUT = tmp .. "/truncated" }, good, 0, true)
  assert(err:find("truncated", 1, true) and Predicate.absent(tmp .. "/truncated"))
end

local function test_snapshot_cleanup_and_output_errors_remain_best_effort(tmp: string)
  local path, restored = tmp .. "/cache.db", tmp .. "/restored.db"
  assert(Fs.write(restored, "owned"))
  local seams = Seams.calls()
  local original = seams.fs_exists
  seams.fs_exists = function(name: string): boolean?, string
    if name == restored or name == tmp .. "/output" then
      return nil, "injected inaccessible path"
    end
    return original(name)
  end
  local request: CacheTrim.Request = { family = "compiles", paths = { path }, since_ns = 1,
    whole = false, restored = restored }
  local payload = text_of(encoded(path))
  local tried = trying(request, { GITHUB_OUTPUT = tmp .. "/output" }, payload)
  seams.fs_exists = original
  assert(tried.ok and tried.err:find("injected inaccessible path", 1, true) ~= nil, tried.err)
  assert(Fs.read(restored) == "owned" and Predicate.absent(tmp .. "/output"))
  request.restored = nil
  local append = seams.fs_append
  seams.fs_append = function(name: string, _text: string, _mode?: integer): boolean, string
    return false, name .. ": injected output failure"
  end
  tried = trying(request, { GITHUB_OUTPUT = tmp .. "/output" }, payload)
  seams.fs_append = append
  assert(tried.ok and tried.out:find("digest", 1, true) ~= nil, tried.out)
  assert(tried.err == "diagnosticcompiles-trim: " .. tmp .. "/output: injected output failure\n", tried.err)
end

local function test_repeated_commands_do_not_mutate_the_cached_relaunch(tmp: string)
  local start = assert(Proc.relaunch())
  local before = table.concat(start.argv, "\0")
  local path = tmp .. "/cache.db"
  for _ = 1, 2 do
    local command = Compiles.command({ "5" }, { COSMIC_BUILD_CACHE = path })
    assert(command.code == 0 and command.err == "", command.err)
    assert(table.concat(assert(Proc.relaunch()).argv, "\0") == before)
  end
end

local function test_fresh_counts_require_a_complete_compile_comparison(tmp: string)
  local path = tmp .. "/cache.db"
  local request: CacheTrim.Request = { family = "compiles", paths = { path }, since_ns = 1,
    whole = false, restored = tmp .. "/restored.db" }
  local value = encoded(path)
  value.digest, value.fresh = nil, "1"
  local _, err = mocked(request, { GITHUB_OUTPUT = tmp .. "/output" }, text_of(value))
  assert(err:find("unexpected fresh count", 1, true) and Predicate.absent(tmp .. "/output"))
  request.family = "verdicts"
  value.digest = Json.quote(string.rep("a", 64))
  _, err = mocked(request, { GITHUB_OUTPUT = tmp .. "/output" }, text_of(value))
  assert(err:find("unexpected fresh count", 1, true) and Predicate.absent(tmp .. "/output"))
end

local function test_snapshot_identity_failures_retain_snapshot_and_save_nothing(tmp: string)
  local path, restored = tmp .. "/cache.db", tmp .. "/restored.db"
  assert(Fs.write(restored, "owned"))
  local seams = Seams.calls()
  local absolute, exists = seams.fs_absolute, seams.fs_exists
  seams.fs_absolute = function(name: string): string?, string
    if name == path then return nil, "injected identity failure" end
    return absolute(name)
  end
  seams.fs_exists = function(name: string): boolean?, string
    if name == path then return nil, "injected identity failure" end
    return exists(name)
  end
  local command = guarded({ "5", restored },
    { COSMIC_BUILD_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
  seams.fs_absolute, seams.fs_exists = absolute, exists
  assert(command.code == 0 and command.err:find("snapshot retained", 1, true) ~= nil, command.err)
  assert(Fs.read(restored) == "owned" and Predicate.absent(tmp .. "/output"))
end

local function test_failed_launch_cleans_snapshot_without_publishing(tmp: string)
  local path, restored = tmp .. "/cache.db", tmp .. "/restored.db"
  for _, suffix in ipairs({ "", "-wal", "-shm" }) do
    assert(Fs.write(restored .. suffix, "owned"))
  end
  local seams = Seams.calls()
  local original = seams.child_run
  seams.child_run = function(_argv: {string}, _options?: Child.Options): Child.Result?, string
    return nil, "injected start failure"
  end
  local command = guarded({ "5", restored },
    { COSMIC_BUILD_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
  seams.child_run = original
  assert(command.code == 0 and command.err:find("injected start failure", 1, true) ~= nil, command.err)
  for _, suffix in ipairs({ "", "-wal", "-shm" }) do
    assert(Predicate.absent(restored .. suffix))
  end
  assert(Predicate.absent(tmp .. "/output"))
end

local function test_a_guard_failure_cleans_snapshot_without_raising(tmp: string)
  local restored = tmp .. "/restored.db"
  assert(Fs.write(restored, "owned"))
  local seams = Seams.calls()
  local original = seams.signal_guard
  seams.signal_guard = function(): Signal.Guard?, string
    return nil, "injected guard failure"
  end
  local command = guarded({ "5", restored },
    { COSMIC_BUILD_CACHE = tmp .. "/cache.db", GITHUB_OUTPUT = tmp .. "/output" })
  seams.signal_guard = original
  assert(command.code == 0 and command.err:find("injected guard failure", 1, true) ~= nil, command.err)
  assert(Predicate.absent(restored) and Predicate.absent(tmp .. "/output"))
end

local function test_report_file_order_must_match_the_whole_requested_set(tmp: string)
  local a, b = tmp .. "/a.db", tmp .. "/b.db"
  local request: CacheTrim.Request = { family = "verdicts", paths = { a, b }, since_ns = 1, whole = false }
  local value = encoded(a)
  value.files = { file_json(b, "trimmed", 1), file_json(a, "trimmed", 1) }
  local _, err = mocked(request, { GITHUB_OUTPUT = tmp .. "/output" }, text_of(value))
  assert(err:find("another file set", 1, true) and Predicate.absent(tmp .. "/output"))
end

local function test_save_outputs_append_without_replacing_or_reading(tmp: string)
  local path, target, link = tmp .. "/cache.db", tmp .. "/output", tmp .. "/link"
  local prefix = string.rep("earlier=\0value\n", 100000)
  assert(Fs.write(target, prefix, 0x180))
  assert(Fs.symlink(target, link))
  local before = assert(Fs.stat(target))
  local restored = tmp .. "/restored.db"
  local request: CacheTrim.Request = { family = "compiles", paths = { path }, since_ns = 1,
    whole = false, restored = restored }
  assert(Fs.write(restored, "owned snapshot"))
  local value = encoded(path)
  value.fresh = "2"
  local payload = text_of(value)
  local seams = Seams.calls()
  local append = seams.fs_append
  local calls: Count = { value = 0 }
  seams.fs_append = function(name: string, text: string, mode?: integer): boolean, string
    calls.value = calls.value + 1
    assert(Predicate.exists(restored) == false, "snapshot cleanup followed publication")
    assert(name == link and text == "digest=" .. string.rep("a", 64) .. "\nfresh=2\n")
    return append(name, text, mode)
  end
  local tried = trying(request, { GITHUB_OUTPUT = link }, payload)
  seams.fs_append = append
  assert(tried.ok and calls.value == 1 and tried.err == "diagnostic", tried.err)
  assert(tried.out:find("2 compiles", 1, true), tried.out)
  local after = assert(Fs.stat(target))
  assert(before.ino == after.ino and before.mode == after.mode)
  assert(Fs.readlink(link) == target)
  assert(Fs.read(target) == prefix .. "digest=" .. string.rep("a", 64) .. "\nfresh=2\n")
end

local function test_partial_output_failure_keeps_the_report_and_does_not_retry(tmp: string)
  local path, output = tmp .. "/cache.db", tmp .. "/output"
  assert(Fs.write(output, "earlier=value\n"))
  local request: CacheTrim.Request = { family = "compiles", paths = { path }, since_ns = 1, whole = false }
  local payload = text_of(encoded(path))
  local seams = Seams.calls()
  local append = seams.fs_append
  local calls: Count = { value = 0 }
  seams.fs_append = function(name: string, text: string, mode?: integer): boolean, string
    calls.value = calls.value + 1
    assert(append(name, text:sub(1, 3), mode))
    return false, name .. ": injected append failure"
  end
  local tried = trying(request, { GITHUB_OUTPUT = output }, payload)
  seams.fs_append = append
  assert(tried.ok and calls.value == 1 and tried.out:find("digest", 1, true) ~= nil, tried.out)
  assert(tried.err == "diagnosticcompiles-trim: " .. output .. ": injected append failure\n", tried.err)
  assert(Fs.read(output) == "earlier=value\ndig")
end
