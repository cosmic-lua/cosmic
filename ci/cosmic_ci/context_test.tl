local Context = require("cosmic_ci.context")
local Fs = require("cosmic.fs")
local Seams = require("cosmic_ci.seams")

--- A number a stand-in keeps.
local record Count
  mut value: integer
end

--- `Context.summarize(text)` with GITHUB_STEP_SUMMARY naming `path`: whether it
--- came back, and what it raised if not.
local function summarize(path: string, text: string): boolean, string
  local seams = Seams.calls()
  local get = seams.env_get
  seams.env_get = function(name: string): string?
    if name == "GITHUB_STEP_SUMMARY" then return path end
    return get(name)
  end
  local ok, why = pcall(function()
    Context.summarize(text)
  end)
  seams.env_get = get
  return ok, if ok then "" else tostring(why) end
end

local function test_summary_appends_through_a_link_without_replacing_or_reading(tmp: string)
  local target, link = tmp .. "/target", tmp .. "/summary"
  assert(Fs.write(target, "earlier\n", 0x180))
  assert(Fs.symlink(target, link))
  local before = assert(Fs.stat(target))
  local ok, why = summarize(link, "next\n")
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
  local seams = Seams.calls()
  local append = seams.fs_append
  local calls: Count = { value = 0 }
  seams.fs_append = function(name: string, text: string, mode?: integer): boolean, string
    calls.value = calls.value + 1
    assert(append(name, text:sub(1, 2), mode))
    return false, name .. ": injected append failure"
  end
  local ok, reason = summarize(path, "next\n")
  seams.fs_append = append
  local first, last = reason:find(path .. ": injected append failure", 1, true)
  assert(not ok and calls.value == 1 and first ~= nil, reason)
  assert(not reason:find(path, (last or 0) + 1, true), reason)
  assert(Fs.read(path) == "earlier\nne")
end

local function test_summary_without_a_file_writes_stdout()
  local seams = Seams.calls()
  local put = seams.fs_put
  local calls: Count = { value = 0 }
  seams.fs_put = function(fd: integer, text: string): boolean, string
    calls.value = calls.value + 1
    assert(fd == Fs.stdout and text == "summary\n")
    return true, ""
  end
  local ok, why = summarize("", "summary\n")
  seams.fs_put = put
  assert(ok and calls.value == 1, why)
end
