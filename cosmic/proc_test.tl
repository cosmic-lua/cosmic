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
