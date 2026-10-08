--- Uses the candidate's resolver on the driver that is already running,
--- before boot has produced any candidate executable or database.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")

local record BuildPaths
end

local directories: {string:string} = {}

--- The generated directory for `root` under `environment`. `source`
--- names the checkout whose resolver applies when root is an application
--- project, which does not contain the build system itself.
local function resolved(root: string, environment?: {string:string}, source?: string,
                        program?: string, prepare?: boolean): string
  local values = environment or Env.all()
  local resolver = (source or root) .. "/build/paths.tl"
  local parts = { resolver, root, program or "" }
  for _, name in ipairs({ "COSMIC_BUILD_HOME", "XDG_CACHE_HOME", "HOME" }) do
    parts[#parts + 1] = name .. "=" .. (values[name] or "")
  end
  local key = Hash.hex_sha256(table.concat(parts, "\0"))
  if not prepare and directories[key] then return directories[key] end
  local argv: {string} = {}
  local env: {string:string} = {}
  local fds: {integer:integer | string} = {}
  for name, value in pairs(values) do env[name] = value end
  local relaunch = program == nil and Proc.relaunch() or nil
  if relaunch then
    for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
    for name, value in pairs(relaunch.env) do env[name] = value end
    for number, fd in pairs(relaunch.fds) do fds[number] = fd end
  else
    argv[1] = program or assert(Proc.executable())
  end
  argv[#argv + 1], argv[#argv + 2] = "--standalone", resolver
  if prepare then argv[#argv + 1] = "--prepare" end
  argv[#argv + 1] = root
  local answer, why = Child.run(argv,
    { env = env, fds = fds, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  assert(answer, why)
  assert(answer.ok, "build directory: " .. (answer.stderr or "") ..
      " (status " .. tostring(Child.shell_status(answer)) .. ")")
  local directory = assert((answer.stdout or ""):match("^([^\n]+)\n$"),
    "build directory resolver did not print one path")
  assert(directory:sub(1, 1) == "/", "build directory is not absolute: " .. directory)
  directories[key] = directory
  return directory
end

function BuildPaths.directory(root: string, environment?: {string:string}, source?: string,
                              program?: string): string
  return resolved(root, environment, source, program)
end

--- Creates and verifies the selected private output directory before
--- placing a seed executable into it.
function BuildPaths.prepare(root: string, environment?: {string:string}, source?: string,
                            program?: string): string
  return resolved(root, environment, source, program, true)
end

return BuildPaths
