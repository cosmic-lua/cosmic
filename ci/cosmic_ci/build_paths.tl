--- Uses the candidate's resolver on the driver that is already running,
--- before boot has produced any candidate executable or database.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Project = require("cosmic.project")

local record BuildPaths
  --- How to start the running driver: its command line, environment and descriptors.
  record Driver
    argv: {string}
    env: {string:string}
    fds: {integer:integer | string}
  end
end

local directories: mut {string:string} = {}

--- A command line of the driver that is already running, past its
--- launcher where it has one, with `words` after it, and the environment
--- and descriptors to start it with (`values` added to the launcher's).
--- `words` never begin `--standalone`: a file run standalone by the driver's own path is no check
--- of bin/cosmic-bootstrap's, so the two callers that do it ([`BuildPaths.directory`], and check-islands, which
--- type-checks what the list names) append it themselves.
function BuildPaths.driver(words: {string}, values: {string:string}): BuildPaths.Driver
  assert(words[1] ~= "--standalone", "BuildPaths.driver does not run a file standalone; see its comment")
  local argv: mut {string} = {}
  local env: mut {string:string} = {}
  local fds: mut {integer:integer | string} = {}
  for name, value in pairs(values) do env[name] = value end
  local relaunch, _why = Proc.relaunch()
  if relaunch then
    for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
    for name, value in pairs(relaunch.env) do env[name] = value end
    for number, fd in pairs(relaunch.fds) do fds[number] = fd end
  else
    argv[#argv + 1] = assert(Proc.executable())
  end
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  return { argv = argv, env = env, fds = fds }
end

--- Where the running driver builds the project at `root`, which a
--- `cosmic test` it runs there reads what is placed for it from: its
--- cosmic.project's answer, which its build.paths gives too.
function BuildPaths.driven(root: string): string
  local location, trouble = Project.directory(root)
  assert(location, "build directory: " .. trouble)
  assert(location.none == "", "build directory: " .. location.none)
  return location.directory
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
  local known = directories[key]
  if known ~= nil then return known end
  -- The resolver is build/paths.tl of a checkout, which ci/bootstrap-files.txt lists (check-islands holds that); this is
  -- the one run of a file standalone by the driver's own path in this module.
  local driver = BuildPaths.driver({}, values)
  local argv: mut {string} = {}
  for _, word in ipairs(driver.argv) do argv[#argv + 1] = word end
  for _, word in ipairs({ "--standalone", resolver, root }) do argv[#argv + 1] = word end
  local answer, why = Child.run(argv,
    { env = driver.env, fds = driver.fds, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
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
