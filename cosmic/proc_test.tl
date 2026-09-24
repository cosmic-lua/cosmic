local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")

--- The public wrapper and annotated syscall name the same directly executable
--- logical program. Native mode preserves the physical executable answer;
--- portable coverage supplies the artifact answer in identity_test.tl.
local function test_executable_wraps_the_public_syscall()
  local direct = assert(sys.executable())
  local wrapped = assert(Proc.executable())
  assert(wrapped == direct)
  assert(wrapped:sub(1, 1) == "/")
end

--- A relaunched child is this exact program: the same core image and
--- runtime identity, the same logical artifact, reached without the
--- launcher, and its startup accepts the contract it is handed.
local function test_relaunch_starts_this_same_program(tmp: string)
  local relaunch = Proc.relaunch()
  if relaunch == nil then return end -- a native start has nothing to relaunch
  assert(Proc.relaunch() == relaunch, "the relaunch description is kept")
  local script = tmp .. "/identity.tl"
  assert(Fs.write(script, [[
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
return function(): integer
  print(Store.meta("host_image"), Store.meta("runtime"), (Proc.executable()))
  return 0
end
]]))
  local argv: {string} = {}
  for i, value in ipairs(relaunch.argv) do argv[i] = value end
  argv[#argv + 1] = script
  local env = Env.all()
  for name, value in pairs(relaunch.env) do env[name] = value end
  local fds: {integer:integer | string} = {}
  for number, fd in pairs(relaunch.fds) do fds[number] = fd end
  local r = assert(Child.run(argv, { env = env, fds = fds, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(r.ok, tostring(r.stderr))
  local expected = table.concat({ assert(Store.meta("host_image")),
    assert(Store.meta("runtime")), (assert(Proc.executable())) }, "\t") .. "\n"
  assert(r.stdout == expected, tostring(r.stdout) .. " ~= " .. expected)
end

--- A program this one becomes starts with SIGPIPE at its default, as a
--- child it spawns does, even when this one ignored it: exec hands on
--- an ignored signal, and a pipeline downstream of it would never end.
local function test_exec_hands_on_sigpipe_at_its_default(tmp: string)
  local relaunch = Proc.relaunch()
  if relaunch == nil then return end -- a native start has nothing to relaunch
  if not Fs.exists("/proc/self/status") then return end -- nothing to ask
  -- The case is a process that ignored SIGPIPE itself. One started with
  -- it already ignored hands that on, as its parent chose, and so does
  -- everything it starts: a runner that ignores SIGPIPE has no case here.
  local own = assert(assert(Fs.read("/proc/self/status")):match("SigIgn:%s*(%x+)"))
  local own_mask = math.tointeger(tonumber(own, 16)) or 0
  if own_mask & (1 << (sys.SIGPIPE - 1)) ~= 0 then return end
  local script = tmp .. "/becomes.tl"
  assert(Fs.write(script, [[
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
return function(): integer
  assert(sys.ignore_sigpipe())
  local _, trouble = Proc.exec("/bin/sh", { "sh", "-c", "grep SigIgn /proc/self/status" }, {})
  print(trouble)
  return 1
end
]]))
  local argv: {string} = {}
  for i, value in ipairs(relaunch.argv) do argv[i] = value end
  argv[#argv + 1] = script
  local env = Env.all()
  for name, value in pairs(relaunch.env) do env[name] = value end
  local fds: {integer:integer | string} = {}
  for number, fd in pairs(relaunch.fds) do fds[number] = fd end
  local r = assert(Child.run(argv, { env = env, fds = fds, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(r.ok, tostring(r.stdout) .. tostring(r.stderr))
  local ignored = assert(assert(r.stdout):match("SigIgn:%s*(%x+)"), r.stdout)
  local mask = math.tointeger(tonumber(ignored, 16)) or 0
  assert(mask & (1 << (sys.SIGPIPE - 1)) == 0, "SIGPIPE arrived ignored: " .. ignored)
end

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

--- An empty entry in the list -- the whole list empty, or one before,
--- between or after others -- is the working directory, and a name
--- found there comes back relative to it.
local function test_find_takes_an_empty_entry_as_the_working_directory(dir: string)
  assert(Fs.write(dir .. "/tool", "#!/bin/sh\n", 0x1ed))
  local before = assert(sys.getcwd())
  assert(sys.chdir(dir))
  local answers: {string} = {}
  for _, path in ipairs({ "", ":", "/nowhere:", "/nowhere::/elsewhere" }) do
    answers[#answers + 1] = tostring((Proc.find("tool", path)))
  end
  assert(sys.chdir(before))
  assert(table.concat(answers, " ") == "./tool ./tool ./tool ./tool", table.concat(answers, " "))
end

local function test_find_refuses_an_empty_name()
  assert(not pcall(Proc.find, ""))
end
