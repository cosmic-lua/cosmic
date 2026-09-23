--- `build/zig_lib.tl`'s non-network parts: pin parsing, argument
--- rewriting, root detection, and the cache-hit path of
--- `Zig.ensure_installed`, which must never reach the network when an
--- install is already there.

local Fs = require("cosmic.fs")
local Zig = require("build.zig_lib")

local function test_read_pin_parses_version_and_hosts()
  local pin = assert(Zig.read_pin(
    "version 0.16.0\n" ..
    "x86_64-linux 70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00\n" ..
    "aarch64-macos b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489\n"))
  assert(pin.version == "0.16.0")
  assert(pin.shas["x86_64-linux"] ==
    "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00")
  assert(pin.shas["aarch64-macos"] ==
    "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489")
  assert(pin.shas["aarch64-linux"] == nil)
end

local function test_read_pin_requires_a_version_line()
  local pin, trouble = Zig.read_pin("x86_64-linux abc\n")
  assert(pin == nil)
  assert(trouble:find("version", 1, true) ~= nil)
end

local function test_build_args_adds_cache_flags_only_for_build()
  local got = Zig.build_args("/repo", { [1] = "build", [2] = "-Doptimize=ReleaseFast" })
  assert(#got == 8)
  assert(got[1] == "build")
  assert(got[2] == "--cache-dir")
  assert(got[3] == "/repo/o/zig-cache")
  assert(got[4] == "--global-cache-dir")
  assert(got[5] == "/repo/o/zig-global")
  assert(got[6] == "--prefix")
  assert(got[7] == "/repo/o")
  assert(got[8] == "-Doptimize=ReleaseFast")
end

local function test_build_args_inserts_flags_before_callers_own_args()
  local got = Zig.build_args("/repo", { [1] = "build", [2] = "boot" })
  assert(got[8] == "boot")
end

local function test_build_args_passes_other_subcommands_through()
  local got = Zig.build_args("/repo", { [1] = "version" })
  assert(#got == 1)
  assert(got[1] == "version")
end

local function test_repo_root_from_the_scripts_own_path(tmp: string)
  assert(Fs.mkdirs(tmp .. "/repo/build"))
  assert(Fs.write(tmp .. "/repo/build/zig.tl", "-- stand-in"))
  local root = assert(Zig.repo_root(tmp .. "/repo/build/zig.tl"))
  assert(root == assert(Fs.absolute(tmp .. "/repo")))
end

local function test_ensure_installed_is_a_cache_hit_when_zig_is_already_there(tmp: string)
  local install = tmp .. "/cache/0.16.0-x86_64-linux"
  assert(Fs.mkdirs(install))
  assert(Fs.write(install .. "/zig", "#!/bin/sh\necho stand-in\n", 0x1ed))

  -- A pin with no matching sha at all: if this reached the network
  -- path, it would fail loudly rather than silently succeed, so a pass
  -- here means the cache hit really did skip fetching.
  local pin: Zig.Pin = { version = "0.16.0", shas = {} }
  local zig = assert(Zig.ensure_installed(tmp .. "/cache", install, pin, "x86_64-linux"))
  assert(zig == install .. "/zig")
end
