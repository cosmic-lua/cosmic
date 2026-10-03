local CacheTrim = require("cosmic_ci.cache_trim")
local Child = require("cosmic.child")
local Compiles = require("cosmic_ci.compiles")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")

local record Payload
  version: any
  digest: any
  fresh: any
  warnings: any
  files: {{string:any}}
end

local function encoded(path: string): Payload
  local files: {{string:any}} = { { path = path, state = "trimmed", reason = "", kept = 1, removed = 0,
    unknown_tables = Json.array({}), unstamped_tables = Json.array({}), removed_set_aside = Json.array({}) } }
  Json.array(files)
  return { version = 1, digest = string.rep("a", 64), warnings = Json.array({}), files = files }
end

local function mocked(request: CacheTrim.Request, env: {string:string}, payload: string,
    code?: integer, truncated?: boolean): string, string
  local original = Child.run
  Child.run = function(_argv: {string}, _options?: Child.Options): Child.Result | nil, string
    return { ok = code == nil or code == 0, code = code or 0, stdout = payload, stderr = "diagnostic",
      truncated = truncated == true, timed_out = false, captured = {} }, ""
  end
  local ok, out, err = pcall(CacheTrim.run, request, env)
  Child.run = original
  assert(ok, out)
  return out as string, err
end

local function test_invalid_or_incomplete_reports_never_publish_save_keys(tmp: string)
  local path = tmp .. "/cache.db"
  local request: CacheTrim.Request = { family = "compiles", paths = { path }, since_ns = 1, whole = false }
  local cases: {Payload} = {}
  local bad = encoded(path)
  bad.version = 2
  cases[#cases + 1] = bad
  bad = encoded(path .. "other")
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.files = {}
  Json.array(bad.files)
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.files = { encoded(path).files[1], encoded(path).files[1] }
  Json.array(bad.files)
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.files[1].state = "failed"
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.files[1].state = "missing"
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.files[1].kept = -1
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.digest = "bad"
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.fresh = 1
  cases[#cases + 1] = bad
  bad = encoded(path)
  bad.warnings = Json.array({ "comparison incomplete" })
  cases[#cases + 1] = bad
  for i, value in ipairs(cases) do
    local output = tmp .. "/output" .. i
    local _, err = mocked(request, { GITHUB_OUTPUT = output }, (assert(Json.encode(value))))
    assert(err ~= "" and Fs.stat(output) == nil, err)
  end
  for _, text in ipairs({ "not JSON", '{"version":1', '[]', '{}' }) do
    local _, err = mocked(request, { GITHUB_OUTPUT = tmp .. "/invalid" }, text)
    assert(err ~= "" and Fs.stat(tmp .. "/invalid") == nil)
  end
  local good = assert(Json.encode(encoded(path)))
  for _, code in ipairs({ 1, 2 }) do
    local _, err = mocked(request, { GITHUB_OUTPUT = tmp .. "/failed" }, good, code)
    assert(err ~= "" and Fs.stat(tmp .. "/failed") == nil)
  end
  local _, err = mocked(request, { GITHUB_OUTPUT = tmp .. "/truncated" }, good, 0, true)
  assert(err:find("truncated", 1, true) and Fs.stat(tmp .. "/truncated") == nil)
end

local function test_snapshot_cleanup_and_output_errors_remain_best_effort(tmp: string)
  local path, restored = tmp .. "/cache.db", tmp .. "/restored.db"
  assert(Fs.write(restored, "owned"))
  local original = Fs.exists
  Fs.exists = function(name: string): boolean | nil, string
    if name == restored or name == tmp .. "/output" then
      return nil, "injected inaccessible path"
    end
    return original(name)
  end
  local request: CacheTrim.Request = { family = "compiles", paths = { path }, since_ns = 1,
    whole = false, restored = restored }
  local payload: string = assert(Json.encode(encoded(path)))
  local ok, _, err = pcall(mocked, request, { GITHUB_OUTPUT = tmp .. "/output" }, payload)
  Fs.exists = original
  assert(ok and err:find("injected inaccessible path", 1, true), err)
  assert(Fs.read(restored) == "owned" and Fs.stat(tmp .. "/output") == nil)
  request.restored = nil
  local append = Fs.append
  Fs.append = function(name: string, _text: string, _mode?: integer): boolean, string
    return false, name .. ": injected output failure"
  end
  local out: any
  ok, out, err = pcall(mocked, request, { GITHUB_OUTPUT = tmp .. "/output" }, payload)
  Fs.append = append
  assert(ok and tostring(out):find("digest", 1, true), out)
  assert(err == "diagnosticcompiles-trim: " .. tmp .. "/output: injected output failure\n", err)
end

local function test_repeated_commands_do_not_mutate_the_cached_relaunch(tmp: string)
  local start = assert(Proc.relaunch())
  local before = table.concat(start.argv, "\0")
  local path = tmp .. "/cache.db"
  for _ = 1, 2 do
    local code, _, err = Compiles.command({ "5" }, { COSMIC_BUILD_CACHE = path })
    assert(code == 0 and err == "", err)
    assert(table.concat(assert(Proc.relaunch()).argv, "\0") == before)
  end
end

local function test_fresh_counts_require_a_complete_compile_comparison(tmp: string)
  local path = tmp .. "/cache.db"
  local request: CacheTrim.Request = { family = "compiles", paths = { path }, since_ns = 1,
    whole = false, restored = tmp .. "/restored.db" }
  local value = encoded(path)
  value.digest, value.fresh = nil, 1
  local _, err = mocked(request, { GITHUB_OUTPUT = tmp .. "/output" }, (assert(Json.encode(value))))
  assert(err:find("unexpected fresh count", 1, true) and Fs.stat(tmp .. "/output") == nil)
  request.family = "verdicts"
  value.digest = string.rep("a", 64)
  _, err = mocked(request, { GITHUB_OUTPUT = tmp .. "/output" }, (assert(Json.encode(value))))
  assert(err:find("unexpected fresh count", 1, true) and Fs.stat(tmp .. "/output") == nil)
end

local function test_snapshot_identity_failures_retain_snapshot_and_save_nothing(tmp: string)
  local path, restored = tmp .. "/cache.db", tmp .. "/restored.db"
  assert(Fs.write(restored, "owned"))
  local absolute, exists = Fs.absolute, Fs.exists
  Fs.absolute = function(name: string): string | nil, string
    if name == path then return nil, "injected identity failure" end
    return absolute(name)
  end
  Fs.exists = function(name: string): boolean | nil, string
    if name == path then return nil, "injected identity failure" end
    return exists(name)
  end
  local called, code, _, err = pcall(Compiles.command, { "5", restored },
    { COSMIC_BUILD_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
  Fs.absolute, Fs.exists = absolute, exists
  assert(called and code == 0 and err:find("snapshot retained", 1, true), err)
  assert(Fs.read(restored) == "owned" and Fs.stat(tmp .. "/output") == nil)
end

local function test_failed_launch_cleans_snapshot_without_publishing(tmp: string)
  local path, restored = tmp .. "/cache.db", tmp .. "/restored.db"
  for _, suffix in ipairs({ "", "-wal", "-shm" }) do
    assert(Fs.write(restored .. suffix, "owned"))
  end
  local original = Child.run
  Child.run = function(_argv: {string}, _options?: Child.Options): Child.Result | nil, string
    return nil, "injected start failure"
  end
  local called, code, _, err = pcall(Compiles.command, { "5", restored },
    { COSMIC_BUILD_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
  Child.run = original
  assert(called and code == 0 and err:find("injected start failure", 1, true), err)
  for _, suffix in ipairs({ "", "-wal", "-shm" }) do assert(Fs.stat(restored .. suffix) == nil) end
  assert(Fs.stat(tmp .. "/output") == nil)
end

local function test_a_guard_failure_cleans_snapshot_without_raising(tmp: string)
  local restored = tmp .. "/restored.db"
  assert(Fs.write(restored, "owned"))
  local original = Child.guard
  Child.guard = function(): Child.Guard | nil, string return nil, "injected guard failure" end
  local called, code, _, err = pcall(Compiles.command, { "5", restored },
    { COSMIC_BUILD_CACHE = tmp .. "/cache.db", GITHUB_OUTPUT = tmp .. "/output" })
  Child.guard = original
  assert(called and code == 0 and err:find("injected guard failure", 1, true), err)
  assert(Fs.stat(restored) == nil and Fs.stat(tmp .. "/output") == nil)
end

local function test_report_file_order_must_match_the_whole_requested_set(tmp: string)
  local a, b = tmp .. "/a.db", tmp .. "/b.db"
  local request: CacheTrim.Request = { family = "verdicts", paths = { a, b }, since_ns = 1, whole = false }
  local value = encoded(a)
  value.files = { encoded(b).files[1], encoded(a).files[1] }
  Json.array(value.files)
  local _, err = mocked(request, { GITHUB_OUTPUT = tmp .. "/output" }, (assert(Json.encode(value))))
  assert(err:find("another file set", 1, true) and Fs.stat(tmp .. "/output") == nil)
end

local function test_save_outputs_append_without_replacing_or_reading(tmp: string)
  local path, target, link = tmp .. "/cache.db", tmp .. "/output", tmp .. "/link"
  local prefix = string.rep("earlier=\0value\n", 100000)
  assert(Fs.write(target, prefix, 0x180))
  assert(Fs.symlink(target, link))
  local before = assert(Fs.stat(target))
  local request: CacheTrim.Request = { family = "compiles", paths = { path }, since_ns = 1,
    whole = false, restored = tmp .. "/restored.db" }
  assert(Fs.write(request.restored, "owned snapshot"))
  local value = encoded(path)
  value.fresh = 2
  local payload = assert(Json.encode(value))
  local read, append, calls = Fs.read, Fs.append, 0
  Fs.append = function(name: string, text: string, mode?: integer): boolean, string
    calls = calls + 1
    assert(Fs.exists(request.restored) == false, "snapshot cleanup followed publication")
    assert(name == link and text == "digest=" .. string.rep("a", 64) .. "\nfresh=2\n")
    return append(name, text, mode)
  end
  Fs.read = function(name: string): string | nil, string
    assert(name ~= link and name ~= target, "output reread its existing bytes")
    return read(name)
  end
  local ok, out, err = pcall(mocked, request, { GITHUB_OUTPUT = link }, payload)
  Fs.read, Fs.append = read, append
  assert(ok and calls == 1 and err == "diagnostic", err)
  assert(tostring(out):find("2 compiles", 1, true), out)
  local after = assert(Fs.stat(target))
  assert(before.ino == after.ino and before.mode == after.mode)
  assert(Fs.readlink(link) == target)
  assert(Fs.read(target) == prefix .. "digest=" .. string.rep("a", 64) .. "\nfresh=2\n")
end

local function test_partial_output_failure_keeps_the_report_and_does_not_retry(tmp: string)
  local path, output = tmp .. "/cache.db", tmp .. "/output"
  assert(Fs.write(output, "earlier=value\n"))
  local request: CacheTrim.Request = { family = "compiles", paths = { path }, since_ns = 1, whole = false }
  local payload = assert(Json.encode(encoded(path)))
  local append, calls = Fs.append, 0
  Fs.append = function(name: string, text: string, mode?: integer): boolean, string
    calls = calls + 1
    assert(append(name, text:sub(1, 3), mode))
    return false, name .. ": injected append failure"
  end
  local ok, out, err = pcall(mocked, request, { GITHUB_OUTPUT = output }, payload)
  Fs.append = append
  assert(ok and calls == 1 and tostring(out):find("digest", 1, true), out)
  assert(err == "diagnosticcompiles-trim: " .. output .. ": injected append failure\n", err)
  assert(Fs.read(output) == "earlier=value\ndig")
end
