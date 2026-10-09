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

--- A command line of the driver that is already running, past its
--- launcher where it has one, with `words` after it, and the environment
--- and descriptors to start it with.
local function driver(words: {string}, values: {string:string}):
    {string}, {string:string}, {integer:integer | string}
  local argv: {string} = {}
  local env: {string:string} = {}
  local fds: {integer:integer | string} = {}
  for name, value in pairs(values) do env[name] = value end
  local relaunch = Proc.relaunch()
  if relaunch then
    for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
    for name, value in pairs(relaunch.env) do env[name] = value end
    for number, fd in pairs(relaunch.fds) do fds[number] = fd end
  else
    argv[1] = assert(Proc.executable())
  end
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  return argv, env, fds
end

--- Where the running driver builds the project at `root`, which a
--- `cosmic test` it runs there reads what is placed for it from: its own
--- build.paths' answer, or `root`/o for a driver that carries none.
-- TODO: take this from build.paths alone, and drop the o/ of a driver that
-- carries none, once ci/cosmic-driver.pin names a release that carries
-- build/paths.tl and puts the build directory outside the project.
function BuildPaths.driven(root: string): string
  local argv, env, fds = driver({ "-e", [[
local Store = require("cosmic.store")
if Store.source("build.paths") ~= nil then print(require("build.paths").required(...)) end
]], root }, Env.all())
  local answer, why = Child.run(argv,
    { env = env, fds = fds, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  assert(answer, why)
  assert(answer.ok, "build directory: " .. (answer.stderr or ""))
  local said = answer.stdout or ""
  if said == "" then return root .. "/o" end
  return (assert(said:match("^(/[^\n]+)\n$"), "the driver named no build directory: " .. said))
end

--- The generated directory for `root` under `environment`. `source`
--- names the checkout whose resolver applies when root is an application
--- project, which does not contain the build system itself.
function BuildPaths.directory(root: string, environment?: {string:string}, source?: string): string
  local values = environment or Env.all()
  local resolver = (source or root) .. "/build/paths.tl"
  local parts = { resolver, root }
  for _, name in ipairs({ "COSMIC_BUILD_HOME", "XDG_CACHE_HOME", "HOME" }) do
    parts[#parts + 1] = name .. "=" .. (values[name] or "")
  end
  local key = Hash.hex_sha256(table.concat(parts, "\0"))
  if directories[key] then return directories[key] end
  local argv, env, fds = driver({ "--standalone", resolver, root }, values)
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

return BuildPaths
