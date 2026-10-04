--- Native mount guarantees for declared noexec scratch. The harness
--- skips this module where it cannot grant the capability; held runs
--- fail that skip. Copying bytes to ordinary scratch is allowed.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local stand_in = require("build.stand_in")
local type raw_process = require("cosmic.internal.process")

--- The mount, native stand-in and nested remount helpers need the
--- declared scratch, system programs and permission to create a root.
Test.needs{ noexec = true, nests = true, system = true }

local function executable(tmp: string): string, string
  local ordinary = tmp .. "/ordinary"
  assert(stand_in.place(assert(stand_in.build(tmp .. "/stand-in")), ordinary))
  local noexec = assert(Env.get("COSMIC_TEST_NOEXEC"))
  assert(noexec == "/noexec" and noexec ~= Env.get("TMPDIR"))
  local path = noexec .. "/program"
  local bytes = assert(Fs.read(ordinary))
  assert(Fs.write(path, bytes, 0x1c0))
  assert(Fs.read(path) == bytes)
  return ordinary, path
end

local function refused(path: string)
  -- If exec unexpectedly succeeds, the native stand-in exits without
  -- a worker report; the test fails instead of losing the assertion.
  local ok, trouble, errno = sys.execve(path, { path, "exit 97" }, {})
  assert(not ok and errno == sys.EACCES, trouble)
end

local function test_noexec_files_and_symlink_aliases_refuse_native_exec(tmp: string)
  local ordinary, path = executable(tmp)
  refused(path)
  assert(Fs.symlink(path, tmp .. "/alias"))
  refused(tmp .. "/alias")
  local fd = assert(sys.open(path, sys.O_RDONLY))
  refused("/proc/self/fd/" .. tostring(fd))
  assert(sys.close(fd))
  local result = assert(Child.run({ ordinary, "exit 0" }, { timeout_ns = Clock.seconds(10) }))
  assert(result.ok)
  local copied = tmp .. "/copied"
  assert(Fs.write(copied, assert(Fs.read(path)), 0x1c0))
  result = assert(Child.run({ copied, "exit 0" }, { timeout_ns = Clock.seconds(10) }))
  assert(result.ok)
end

local function test_nested_bind_preserves_noexec_and_cannot_clear_it(tmp: string)
  local _, path = executable(tmp)
  local mount = assert(Proc.find("mount"))
  local unshare = assert(Proc.find("unshare"))
  local shell = assert(Proc.find("sh"))
  local alias = tmp .. "/bound"
  assert(Fs.mkdirs(alias))
  local script = [[
set -eu
mount_program=$1
noexec=$2
alias=$3
"$mount_program" -o bind "$noexec" "$alias"
if "$mount_program" -o remount,bind,exec "$alias"; then
  echo 'nested bind cleared noexec' >&2
  exit 91
fi
if "$alias/program" 'exit 0'; then
  echo 'nested alias executed' >&2
  exit 92
fi
]]
  local result, trouble = Child.run({ unshare, "-U", "-r", "-m", "--",
    shell, "-c", script, "noexec-bind", mount, "/noexec", alias },
    { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(10) })
  assert(result ~= nil, trouble)
  assert(result.ok, result.stderr or "nested bind failed")
  refused(path)
end

local function test_noexec_is_inherited_through_an_explicit_child_sandbox(tmp: string)
  local ordinary, path = executable(tmp)
  local result, trouble = Child.run({ ordinary, "cat " .. path }, {
    cwd = "/",
    sandbox = { unveil = { reads = { ordinary, "/noexec", "/proc", "/dev/null" },
      writes = { tmp } }, offline = true },
    stdout = "null", stderr = "capture", timeout_ns = Clock.seconds(10),
  })
  assert(result ~= nil, trouble)
  assert(result.ok, result.stderr)
  local raw: raw_process = nil
  for _, searcher in ipairs(package.searchers) do
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then raw = extra as raw_process end -- cast: the table core/process.h declares
  end
  assert(raw ~= nil)
  local pid, why, errno = raw.spawn(path, { path, "exit 0" }, nil, "/", nil, nil, nil,
    false, nil, { unveil = { reads = { "/noexec", "/proc", "/dev/null" } }, offline = true })
  if pid ~= nil then local _, _ = raw.waitpid(pid, false) end
  assert(pid == nil and errno == sys.EACCES, why)
end
