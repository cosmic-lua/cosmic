--- [`Proc.find`]'s search of a path list. The cases that start this
--- program or ask for its path are in cosmic/proc_tool_test.tl.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

--- [`Proc.find`] searches a path list as a shell does: the first
--- executable wins, a name with a slash is taken as it is, and what is
--- missing or not executable says which.
local function test_find_searches_a_path_as_a_shell_does(dir: string)
  assert(Fs.mkdirs(dir .. "/a") and Fs.mkdirs(dir .. "/b") and Fs.mkdirs(dir .. "/c"))
  assert(Fs.write(dir .. "/a/tool", "not executable\n", 0x1a4))
  assert(Fs.write(dir .. "/b/tool", "#!/bin/sh\n", 0x1ed))
  assert(Fs.write(dir .. "/c/tool", "#!/bin/sh\n", 0x1ed))
  assert(Fs.mkdirs(dir .. "/d/tool"))
  local path = dir .. "/d:" .. dir .. "/a:" .. dir .. "/b:" .. dir .. "/c"
  local found, trouble = Proc.find("tool", path)
  assert(found == dir .. "/b/tool" and trouble == "", tostring(found))
  found, trouble = Proc.find("tool", dir .. "/a")
  assert(found == nil and trouble == dir .. "/a/tool: not executable", trouble)
  found, trouble = Proc.find("tool", dir .. "/d:" .. dir .. "/nowhere")
  assert(found == nil and trouble == "tool: not found", trouble)
  found, trouble = Proc.find("./anything", "")
  assert(found == "./anything" and trouble == "")
end

--- Whether this process holds CAP_DAC_OVERRIDE, as /proc/self/status
--- says of its effective capabilities: root does, but not root in a
--- sandbox (a sandboxed `cosmic test` worker), which gives them up.
local function overrides_permissions(): boolean
  local status = Fs.read("/proc/self/status") or ""
  local effective = status:match("\nCapEff:%s*(%x+)")
  if effective == nil then return sys.getuid() == 0 end -- no /proc: root's are root's
  local bits = math.tointeger(tonumber(effective:sub(-8), 16)) or 0
  return bits & 2 ~= 0
end

--- A file only others may run is not one this process may, unless it
--- may override a file's permissions, as root may, which may run any
--- file with an execute bit at all.
local function test_find_passes_over_a_file_only_others_may_run(dir: string)
  assert(Fs.write(dir .. "/tool", "#!/bin/sh\n", 0x189))
  local found, trouble = Proc.find("tool", dir)
  if overrides_permissions() then
    assert(found == dir .. "/tool", trouble)
  else
    assert(found == nil and trouble == dir .. "/tool: not executable", trouble)
  end
end

--- An empty entry in the list -- the whole list empty, or one before,
--- between or after others -- is the working directory, and a name
--- found there comes back relative to it.
local function test_find_takes_an_empty_entry_as_the_working_directory(dir: string)
  assert(Fs.write(dir .. "/tool", "#!/bin/sh\n", 0x1ed))
  local before = assert(sys.getcwd())
  assert(sys.chdir(dir))
  local answers: {string} = {}
  local nowhere, elsewhere = dir .. "/nowhere", dir .. "/elsewhere"
  for _, path in ipairs({ "", ":", nowhere .. ":", nowhere .. "::" .. elsewhere }) do
    answers[#answers + 1] = tostring((Proc.find("tool", path)))
  end
  assert(sys.chdir(before))
  assert(table.concat(answers, " ") == "./tool ./tool ./tool ./tool", table.concat(answers, " "))
end

local function test_find_refuses_an_empty_name()
  local ok, why: boolean, any = pcall(Proc.find, "")
  assert(not ok and tostring(why):find("proc: find's name is empty", 1, true), tostring(why))
  ok, why = pcall(Proc.exec, {})
  assert(not ok and tostring(why):find("proc: argv is empty", 1, true), tostring(why))
end

--- Failure keeps the first denied regular file, while a later runnable
--- candidate wins over both denied files and directories.
local function test_find_result_classifies_the_selected_candidate(dir: string)
  for _, name in ipairs({ "first", "second", "last", "directory/tool" }) do
    assert(Fs.mkdirs(dir .. "/" .. name))
  end
  assert(Fs.write(dir .. "/first/tool", "", 0x180))
  assert(Fs.write(dir .. "/second/tool", "", 0x180))
  assert(Fs.write(dir .. "/last/tool", "", 0x1c0))
  local path = dir .. "/directory:" .. dir .. "/first:" .. dir .. "/second"
  local denied = Proc.find_result("tool", path)
  assert(denied.kind == "not_executable")
  assert(denied.path == dir .. "/first/tool")
  assert(denied.reason == dir .. "/first/tool: not executable", denied.reason)
  local found = Proc.find_result("tool", path .. ":" .. dir .. "/last")
  assert(found.kind == "resolved" and found.path == dir .. "/last/tool" and found.reason == "")
  assert(denied.kind == "not_executable" and denied.path == dir .. "/first/tool",
    "a later lookup changed an earlier result")
  local missing = Proc.find_result("tool", dir .. "/directory:" .. dir .. "/missing")
  assert(missing.kind == "not_found" and missing.path == nil and missing.reason == "tool: not found")
end

--- Explicit spellings bypass inspection, even for a missing path, a
--- directory or a regular file with no execute bits.
local function test_find_result_resolves_explicit_paths_without_inspecting_them(dir: string)
  assert(Fs.write(dir .. "/plain", "", 0x180))
  for _, name in ipairs({ "./missing", dir, dir .. "/plain", dir .. "/missing" }) do
    local found = Proc.find_result(name, "")
    assert(found.kind == "resolved" and found.path == name and found.reason == "", name)
    local legacy, trouble = Proc.find(name, "")
    assert(legacy == name and trouble == "", trouble)
  end
end

--- A directory the process cannot search reveals no regular candidate;
--- permission override, where available, still sees its executable file.
local function test_find_result_preserves_stat_refusal(dir: string)
  local hidden = dir .. "/hidden"
  assert(Fs.mkdirs(hidden))
  assert(Fs.write(hidden .. "/tool", "", 0x1c0))
  assert(Fs.chmod(hidden, 0))
  local result = Proc.find_result("tool", hidden)
  local legacy, trouble = Proc.find("tool", hidden)
  assert(Fs.chmod(hidden, 0x1c0))
  if overrides_permissions() then
    assert(result.kind == "resolved" and result.path == hidden .. "/tool" and result.reason == "")
    assert(legacy == result.path and trouble == "")
  else
    assert(result.kind == "not_found" and result.path == nil and result.reason == "tool: not found")
    assert(legacy == nil and trouble == result.reason)
  end
end

local function test_find_result_refuses_an_empty_name()
  local ok, why: boolean, any = pcall(Proc.find_result, "")
  assert(not ok and tostring(why):find("proc: find_result's name is empty", 1, true), tostring(why))
end
