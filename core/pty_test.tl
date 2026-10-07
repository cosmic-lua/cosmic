local sys = require("cosmic.sys")

local function value_failure(value: any, trouble: string, errno: integer)
  assert(value == nil)
  assert(trouble ~= "")
  assert(errno > 0)
end

local function effect_failure(value: boolean, trouble: string, errno: integer)
  assert(value == false)
  assert(trouble ~= "")
  assert(errno > 0)
end

local function test_terminal_failures_keep_their_declared_shapes()
  value_failure(sys.tcgetattr(-1))
  value_failure(sys.winsize(-1))
  effect_failure(sys.tcraw(-1))
  effect_failure(sys.tcflush(-1))
  effect_failure(sys.setwinsize(-1, 24, 80))
  effect_failure(sys.controlling_terminal(-1))
end

local function test_terminal_degenerate_arguments_raise()
  assert(not pcall(sys.tcsetattr, -1, ""))
  assert(not pcall(sys.setwinsize, -1, -1, 80))
  assert(not pcall(sys.setwinsize, -1, 24, 65536))
  assert(not pcall(sys.tcgetattr, 0x100000000))
  assert(not pcall(sys.tcraw, 0x100000000))
  assert(not pcall(sys.tcflush, 0x100000000))
  assert(not pcall(sys.winsize, 0x100000000))
  assert(not pcall(sys.setwinsize, 0x100000000, 24, 80))
  assert(not pcall(sys.controlling_terminal, 0x100000000))
end

local function test_non_terminal_is_refused_without_changing_session(tmp: string)
  local fd = assert(sys.open(tmp .. "/ordinary", sys.O_CREAT | sys.O_RDWR, 384))
  local group = assert(sys.getpgid(0))
  value_failure(sys.tcgetattr(fd))
  value_failure(sys.winsize(fd))
  effect_failure(sys.tcraw(fd))
  effect_failure(sys.tcflush(fd))
  effect_failure(sys.setwinsize(fd, 24, 80))
  effect_failure(sys.controlling_terminal(fd))
  assert(sys.getpgid(0) == group)
  assert(sys.close(fd))
end

-- Successful pty preparation is a trusted caller operation, before a
-- policy holds it. The CI driver's unsandboxed self-driven fixture checks
-- its round trips; here the worker may instead refuse access to devices.
local function test_openpty_returns_owned_descriptors_or_a_runtime_refusal()
  local pty, trouble, errno = sys.openpty()
  if pty == nil then
    value_failure(pty, trouble, errno)
  else
    assert(pty.master ~= pty.slave)
    assert(sys.isatty(pty.master) and sys.isatty(pty.slave))
    assert(sys.fd_flags(pty.master) & sys.FD_CLOEXEC ~= 0)
    assert(sys.fd_flags(pty.slave) & sys.FD_CLOEXEC ~= 0)
    assert(sys.close(pty.slave))
    assert(sys.close(pty.master))
  end
end

local function test_ttyname_names_a_slave_and_refuses_a_descriptor_that_is_none(tmp: string)
  local fd = assert(sys.open(tmp .. "/ordinary", sys.O_CREAT | sys.O_RDWR, 384))
  value_failure(sys.ttyname(fd))
  assert(sys.close(fd))
  assert(not pcall(sys.ttyname, 0x100000000))
  local pty = sys.openpty()
  if pty ~= nil then
    local name = assert(sys.ttyname(pty.slave))
    assert(name:sub(1, 5) == "/dev/", name)
    local again = assert(sys.open(name, sys.O_RDWR | sys.O_NOCTTY))
    assert(sys.isatty(again))
    assert(sys.close(again))
    assert(sys.close(pty.slave))
    assert(sys.close(pty.master))
  end
end
