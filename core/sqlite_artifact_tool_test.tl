--- Run actual held test workers through portable and host tools. Their
--- databases contain more modules than their declared import closures.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local artifact = require("build.artifact")
local this_program = require("build.this_program")

--- Repackages this tool's database and trusted host core, then starts both
--- formats. The portable launcher and the worker's hard-link helper use sh/ln.
Test.needs{ tool = true, store = true, system = true }

local probe <const> = [==[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
Test.needs{ tool = true, system = true }
local function test_held_worker_cannot_inspect_its_program(tmp: string)
  assert(not pcall(Store.databases), "the worker has no held store")
  local source, reason = Store.bytecode("hidden")
  assert(source == nil and reason ~= "", "the omitted module was readable")
  local program = assert(Proc.executable())
  local function denied(path: string)
    local a, why = Sqlite.artifact(path)
    assert(a == nil and why:find("running artifact", 1, true), path .. ": " .. tostring(why))
  end
  denied(program)
  assert(sys.symlink(program, tmp .. "/symlink"))
  denied(tmp .. "/symlink")
  local linked = assert(Child.run({ assert(Proc.find("ln")), program, tmp .. "/hardlink" }, { stderr = "capture" }))
  assert(linked.ok, linked.stderr)
  denied(tmp .. "/hardlink")
  local relaunch = Proc.relaunch()
  if relaunch ~= nil and relaunch.env.COSMIC_PORTABLE_ARTIFACT_FD ~= nil then
    local slot = assert(math.tointeger(tonumber(relaunch.env.COSMIC_PORTABLE_ARTIFACT_FD)))
    local alias = "/proc/self/fd/" .. relaunch.fds[slot]
    if sys.stat(alias) then denied(alias) end
  end
  local path = tmp .. "/plain.db"
  local plain = assert(Sqlite.open(path, { writable = true }))
  assert(plain:exec("CREATE TABLE t(v)"))
  assert(plain:close())
  local db = assert(Sqlite.open(path, { immutable = true }))
  local escaped = program:gsub("[^%w/%-%._~]", function(c: string): string
    return string.format("%%%02X", c:byte())
  end)
  for _ = 1, 2 do
    assert(not db:exec("ATTACH 'file:" .. escaped .. "?vfs=cosmic&mode=ro&immutable=1' AS replay"))
  end
  assert(db:exec("ATTACH '" .. path .. "' AS ordinary"))
  assert(db:exec("SELECT * FROM ordinary.t"))
  assert(db:close())
  -- A tool already has authority to read these bytes. An independent copy
  -- is an ordinary authorized file, not the retained runtime descriptor.
  local copy = tmp .. "/copy"
  assert(Fs.write(copy, (assert(Fs.read(program)))))
  local external = assert(Sqlite.artifact(copy))
  local inspected = assert(external:open())
  assert(inspected:exec("SELECT path FROM modules LIMIT 1"))
  assert(inspected:close())
  assert(external:close())
  assert(not pcall(Store.databases), "inspection changed the held store")
end
]==]

local function test_both_formats_deny_held_store_reopening_and_aliases(tmp: string)
  local bytes = assert(Fs.read((assert(Proc.executable()))))
  local parts = assert(artifact.split(bytes))
  local host = assert(artifact.host_program(assert(artifact.trusted_core()), parts.database))
  for name, image in pairs({ portable = bytes, host = host }) do
    local root = tmp .. "/" .. name
    assert(Fs.mkdirs(root))
    local program = root .. "/cosmic"
    assert(Fs.write(program, image, 0x1ed))
    assert(Fs.write(root .. "/probe_test.tl", probe))
    assert(Fs.write(root .. "/hidden.tl", 'return "omitted"\n'))
    local env = this_program.environment()
    -- This test is about a worker's Store.hold, also enforced without a
    -- kernel sandbox; CI separately runs the outer test sandboxed.
    env.COSMIC_TEST_SANDBOX = "0"
    local result = assert(Child.run({ program, "test", "probe_test.tl" }, {
      cwd = root, env = env, stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) }))
    assert(result.ok, name .. ": " .. tostring(result.stderr) .. tostring(result.stdout))
  end
end
