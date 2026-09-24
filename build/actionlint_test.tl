--- `build/actionlint.tl`'s parts that need no network: pin parsing, the
--- host and its release asset, the arguments actionlint gets, and the
--- install's cache hit and failures, with the download stood in for.

local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local sys = require("cosmic.sys")
local Actionlint = require("build.actionlint")

local function test_read_pin_parses_version_and_hosts()
  local pin = assert(Actionlint.read_pin(
    "version 1.7.12\n" ..
    "x86_64-linux 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 \r\n" ..
    "x86_64-linux def\n"))
  assert(pin.version == "1.7.12")
  assert(pin.shas["x86_64-linux"] ==
    "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8")
  assert(pin.shas["aarch64-macos"] == nil)
  local none, trouble = Actionlint.read_pin("x86_64-linux abc\n")
  assert(none == nil and trouble:find("version", 1, true) ~= nil)
end

local function test_the_pin_names_every_host_ci_and_developers_run_on()
  local text = assert(Fs.read("bin/actionlint.pin"))
  local pin = assert(Actionlint.read_pin(text))
  for _, host in ipairs({ "x86_64-linux", "aarch64-linux", "aarch64-macos" }) do
    assert(pin.shas[host] ~= nil and pin.shas[host]:match("^%x+$") ~= nil and
      #pin.shas[host] == 64, host)
    assert(Actionlint.asset(pin.version, host) ~= nil, host)
  end
end

local function test_host_normalizes_uname()
  assert(Actionlint.host("Linux", "x86_64") == "x86_64-linux")
  assert(Actionlint.host("Linux", "aarch64") == "aarch64-linux")
  assert(Actionlint.host("Darwin", "arm64") == "aarch64-macos")
  local triple, trouble = Actionlint.host("Linux", "riscv64")
  assert(triple == nil and trouble:find("riscv64", 1, true) ~= nil)
  triple, trouble = Actionlint.host("Windows_NT", "x86_64")
  assert(triple == nil and trouble:find("Windows_NT", 1, true) ~= nil)
  local names = assert(sys.uname())
  assert(Actionlint.host(names.sysname, names.machine) ~= nil)
end

local function test_asset_uses_the_release_names()
  assert(Actionlint.asset("1.7.12", "x86_64-linux") == "actionlint_1.7.12_linux_amd64.tar.gz")
  assert(Actionlint.asset("1.7.12", "aarch64-linux") == "actionlint_1.7.12_linux_arm64.tar.gz")
  assert(Actionlint.asset("1.7.12", "aarch64-macos") == "actionlint_1.7.12_darwin_arm64.tar.gz")
  local none, trouble = Actionlint.asset("1.7.12", "riscv64-linux")
  assert(none == nil and trouble:find("riscv64-linux", 1, true) ~= nil)
  assert(Actionlint.url("1.7.12", "a.tar.gz") ==
    "https://github.com/rhysd/actionlint/releases/download/v1.7.12/a.tar.gz")
end

local function test_args_turn_off_host_linters_ahead_of_the_callers()
  local got = Actionlint.args({})
  assert(table.concat(got, " ") == "-shellcheck= -pyflakes=")
  got = Actionlint.args({ "-shellcheck=/x/shellcheck", ".github/workflows/ci.yml" })
  assert(table.concat(got, " ") ==
    "-shellcheck= -pyflakes= -shellcheck=/x/shellcheck .github/workflows/ci.yml")
end

local function test_repo_root_comes_from_the_script_path(tmp: string)
  assert(Fs.mkdirs(tmp .. "/repo/build"))
  assert(Fs.write(tmp .. "/repo/build/actionlint.tl", "-- stand-in"))
  assert(Fs.write(tmp .. "/repo/actionlint.tl", "-- stand-in"))
  local root = assert(Actionlint.repo_root(tmp .. "/repo/build/actionlint.tl"))
  assert(root == assert(Fs.absolute(tmp .. "/repo")))
  local none, trouble = Actionlint.repo_root(tmp .. "/repo/actionlint.tl")
  assert(none == nil and trouble:find("build/actionlint.tl", 1, true) ~= nil)
end

local function test_ensure_installed_is_a_cache_hit_when_the_binary_is_there(tmp: string)
  local install = tmp .. "/cache/1.7.12-x86_64-linux"
  assert(Fs.mkdirs(install))
  assert(Fs.write(install .. "/actionlint", "#!/bin/sh\n", 0x1ed))
  local pin: Actionlint.Pin = { version = "1.7.12", shas = {} }
  local binary = assert(Actionlint.ensure_installed(tmp .. "/cache", install, pin, "x86_64-linux",
    function(_: string, _: string, _: Http.Options): boolean, string
      error("a cache hit reached the network")
    end))
  assert(binary == install .. "/actionlint")
end

local function test_ensure_installed_asks_for_the_pinned_digest_and_cleans_up(tmp: string)
  local cache = tmp .. "/cache"
  local pin: Actionlint.Pin = { version = "1.7.12", shas = { ["aarch64-macos"] = "abc" } }
  local asked: {string} = {}
  local binary, trouble = Actionlint.ensure_installed(cache, cache .. "/1.7.12-aarch64-macos",
    pin, "aarch64-macos",
    function(url: string, path: string, opts: Http.Options): boolean, string
      asked[#asked + 1] = url
      assert(opts.sha256 == "abc")
      assert(opts.connect_timeout_ms > 0 and opts.low_speed_seconds > 0,
        "the download has no stall guard")
      -- Bytes no archive reader accepts: extraction must fail.
      assert(Fs.write(path, "not a tarball"))
      return true, ""
    end)
  assert(binary == nil and trouble ~= "")
  assert(#asked == 1 and asked[1] ==
    "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz",
    asked[1])
  for _, name in ipairs((assert(Fs.list(cache)))) do
    assert(name:match("^%.work") == nil, "a .work directory was left behind")
  end
end

local function test_ensure_installed_refuses_a_host_the_pin_does_not_name(tmp: string)
  local cache = tmp .. "/cache"
  local pin: Actionlint.Pin = { version = "1.7.12", shas = {} }
  local binary, trouble = Actionlint.ensure_installed(cache, cache .. "/1.7.12-x86_64-linux", pin,
    "x86_64-linux", function(_: string, _: string, _: Http.Options): boolean, string
      error("a host without a digest reached the network")
    end)
  assert(binary == nil and trouble:find("x86_64-linux", 1, true) ~= nil)
end

local function test_a_failed_download_is_reported_with_its_url(tmp: string)
  local cache = tmp .. "/cache"
  local pin: Actionlint.Pin = { version = "1.7.12", shas = { ["x86_64-linux"] = "abc" } }
  local binary, trouble = Actionlint.ensure_installed(cache, cache .. "/1.7.12-x86_64-linux", pin,
    "x86_64-linux", function(_: string, _: string, _: Http.Options): boolean, string
      return false, "sha256 mismatch"
    end)
  assert(binary == nil)
  assert(trouble:find("actionlint_1.7.12_linux_amd64.tar.gz", 1, true) ~= nil, trouble)
  assert(trouble:find("sha256 mismatch", 1, true) ~= nil, trouble)
end

local function test_exec_status_is_the_shells()
  assert(Actionlint.exec_status(sys.ENOENT) == 127)
  assert(Actionlint.exec_status(sys.EACCES) == 126)
end
