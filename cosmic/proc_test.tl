--- `Proc.find`'s search of a path list. The cases that start this
--- program or ask for its path are in cosmic/proc_tool_test.tl.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

--- `Proc.find` searches a path list as a shell does: the first
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
  assert(not pcall(Proc.find, ""))
end
