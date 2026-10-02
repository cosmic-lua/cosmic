local Context = require("cosmic_ci.context")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")

local function summarize(path: string, text: string): boolean, any
  local get = Env.get
  Env.get = function(name: string): string | nil
    if name == "GITHUB_STEP_SUMMARY" then return path end
    return get(name)
  end
  local ok, why = pcall(function(): boolean
    Context.summarize(text)
    return true
  end)
  Env.get = get
  return ok, why
end

local function test_summary_appends_through_a_link_without_replacing_or_reading(tmp: string)
  local target, link = tmp .. "/target", tmp .. "/summary"
  assert(Fs.write(target, "earlier\n", 0x180))
  assert(Fs.symlink(target, link))
  local before = assert(Fs.stat(target))
  local read = Fs.read
  Fs.read = function(path: string): string | nil, string
    assert(path ~= link and path ~= target, "summary reread its existing bytes")
    return read(path)
  end
  local ok, why = summarize(link, "next\n")
  Fs.read = read
  assert(ok, why)
  local after = assert(Fs.stat(target))
  assert(before.ino == after.ino and before.mode == after.mode)
  assert(Fs.readlink(link) == target and Fs.read(target) == "earlier\nnext\n")
  assert(summarize(tmp .. "/new", "created\n"))
  assert(Fs.read(tmp .. "/new") == "created\n")
end

local function test_summary_reports_one_failure_and_keeps_a_partial_append(tmp: string)
  local path = tmp .. "/summary"
  assert(Fs.write(path, "earlier\n"))
  local append, calls = Fs.append, 0
  Fs.append = function(name: string, text: string, mode?: integer): boolean, string
    calls = calls + 1
    assert(append(name, text:sub(1, 2), mode))
    return false, name .. ": injected append failure"
  end
  local ok, why = summarize(path, "next\n")
  Fs.append = append
  local reason = tostring(why)
  local first, last = reason:find(path .. ": injected append failure", 1, true)
  assert(not ok and calls == 1 and first ~= nil, reason)
  assert(not reason:find(path, (last or 0) + 1, true), reason)
  assert(Fs.read(path) == "earlier\nne")
end

local function test_summary_without_a_file_writes_stdout()
  local put, calls = Fs.put, 0
  Fs.put = function(fd: integer, text: string): boolean, string
    calls = calls + 1
    assert(fd == Fs.stdout and text == "summary\n")
    return true, ""
  end
  local ok, why = summarize("", "summary\n")
  Fs.put = put
  assert(ok and calls == 1, why)
end
