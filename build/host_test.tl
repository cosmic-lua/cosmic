--- `build/host.tl`'s mapping from `uname`'s raw names to the host
--- triple `bin/zig.pin` and zig's release tarballs use.

local Host = require("build.host")

local function test_linux_x86_64()
  assert(Host.triple("Linux", "x86_64") == "x86_64-linux")
end

local function test_linux_aarch64()
  assert(Host.triple("Linux", "aarch64") == "aarch64-linux")
end

local function test_darwin_arm64_normalizes_to_aarch64_macos()
  assert(Host.triple("Darwin", "arm64") == "aarch64-macos")
end

local function test_amd64_normalizes_to_x86_64()
  assert(Host.triple("Linux", "amd64") == "x86_64-linux")
end

local function test_unsupported_sysname_fails()
  local triple, trouble = Host.triple("Windows_NT", "x86_64")
  assert(triple == nil)
  assert(trouble:find("Windows_NT", 1, true) ~= nil)
end

local function test_unsupported_machine_fails()
  local triple, trouble = Host.triple("Linux", "riscv64")
  assert(triple == nil)
  assert(trouble:find("riscv64", 1, true) ~= nil)
end

local function test_detect_agrees_with_the_running_host()
  -- No stand-in here: this host really is one `sys.uname` reports, so
  -- detection must succeed and look like a host triple.
  local triple = assert(Host.detect())
  assert(triple:match("^[%w_]+%-[%w_]+$") ~= nil)
end
