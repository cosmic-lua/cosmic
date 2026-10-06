--- Native mount guarantees for declared noexec scratch. The harness
--- skips this module where it cannot grant the capability. Copying bytes to ordinary scratch is allowed.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local stand_in = require("build.stand_in")
local type raw_process = require("cosmic.internal.process")

--- The declared scratch, and permission to create the root the unveiled
--- child's sandbox is.
Test.policy{
  grants = { { path = "/noexec", letters = "rwc" } },
  promises = { "nest" },
}

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
