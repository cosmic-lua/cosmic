--- `build/actionlint.tl`'s parts that need no network: pin parsing, the
--- host and its release asset, the arguments actionlint gets, and the
--- install's cache hit and failures, with the download stood in for.

local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Tar = require("cosmic.tar")
local Test = require("cosmic.test")
local Actionlint = require("build.actionlint")

--- The pin bin/actionlint fetches by, which a test holds to every host.
Test.needs{ reads = { "bin/actionlint.pin" } }

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
  for _, host in ipairs({ "x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos" }) do
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
  assert(Fs.write(install .. "/actionlint.sha256", Hash.hex_sha256("#!/bin/sh\n") .. "\n"))
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

local function test_names_files_tells_a_file_or_stdin_from_flags()
  assert(not Actionlint.names_files({}))
  assert(not Actionlint.names_files({ "-oneline", "-format={{json .}}", "-verbose" }))
  assert(Actionlint.names_files({ "-oneline", ".github/workflows/ci.yml" }))
  assert(Actionlint.names_files({ "-" }))
end

--- A stand-in for Http.download that writes, as the release tarball, a
--- gzip-compressed tar holding `binary` as `actionlint` (mode 0755)
--- beside the release's other files, and counts its calls.
local function serving(binary: string, calls: {string}): Actionlint.Download
  return function(url: string, path: string, opts: Http.Options): boolean, string
    assert(opts.sha256 == "abc")
    calls[#calls + 1] = url
    local tar = path .. ".tar"
    local tw = Tar.writer((assert(Stream.create(tar))))
    assert(tw:add_file("LICENSE.txt", "MIT\n"))
    assert(tw:add_file("actionlint", binary, { mode = 0x1ed }))
    assert(tw:close())
    local gz = assert(Compress.deflater("gzip"))
    local body = assert(gz:update((assert(Fs.read(tar)))))
    assert(Fs.write(path, body .. assert(gz:finish())))
    local _, _ = Fs.remove(tar)
    return true, ""
  end
end

local function test_ensure_installed_unpacks_the_release_into_the_cache(tmp: string)
  local cache = tmp .. "/cache"
  local install = cache .. "/1.7.12-x86_64-linux"
  local pin: Actionlint.Pin = { version = "1.7.12", shas = { ["x86_64-linux"] = "abc" } }
  local calls: {string} = {}
  local binary = assert(Actionlint.ensure_installed(cache, install, pin, "x86_64-linux",
    serving("#!/bin/sh\necho stand-in\n", calls)))
  assert(binary == install .. "/actionlint")
  assert(assert(Fs.read(binary)) == "#!/bin/sh\necho stand-in\n")
  local st = assert(sys.stat(binary))
  assert(st.mode & 0x40 ~= 0, "the installed binary is not executable")
  assert(#calls == 1)
  assert(table.concat(assert(Fs.list(cache)), " ") == "1.7.12-x86_64-linux")
  assert(assert(Fs.read(binary .. ".sha256")) ==
    Hash.hex_sha256("#!/bin/sh\necho stand-in\n") .. "\n")
  -- The second run is a cache hit.
  assert(Actionlint.ensure_installed(cache, install, pin, "x86_64-linux",
    serving("other", calls)) == binary)
  assert(#calls == 1)
end

local function test_ensure_installed_replaces_an_empty_or_unexecutable_cached_binary(tmp: string)
  local cache = tmp .. "/cache"
  local install = cache .. "/1.7.12-x86_64-linux"
  local pin: Actionlint.Pin = { version = "1.7.12", shas = { ["x86_64-linux"] = "abc" } }
  local calls: {string} = {}
  local cached: {{string:string | integer}} = {
    { body = "", mode = 0x1ed },
    { body = "#!/bin/sh\n", mode = 0x1a4 },
  }
  for _, c in ipairs(cached) do
    assert(Fs.mkdirs(install))
    assert(Fs.write(install .. "/actionlint", c.body as string, c.mode as integer))
    -- A matching record, so only the size or the mode is wrong.
    assert(Fs.write(install .. "/actionlint.sha256", Hash.hex_sha256(c.body as string) .. "\n"))
    local binary = assert(Actionlint.ensure_installed(cache, install, pin, "x86_64-linux",
      serving("#!/bin/sh\necho fresh\n", calls)))
    assert(assert(Fs.read(binary)) == "#!/bin/sh\necho fresh\n")
    assert(Fs.remove_tree(install))
  end
  assert(#calls == 2)
end

local function test_install_name_carries_the_pins_digest()
  local sha = "8ACA8DB96F1B94770F1B0D72B6DDDCB1EBB8123CB3712530B08CC387B349A3D8"
  local pin: Actionlint.Pin = { version = "1.7.12", shas = { ["x86_64-linux"] = sha } }
  assert(Actionlint.install_name(pin, "x86_64-linux") == "1.7.12-x86_64-linux-8aca8db96f1b9477")
  local none, trouble = Actionlint.install_name(pin, "aarch64-macos")
  assert(none == nil and trouble:find("aarch64-macos", 1, true) ~= nil)
  pin.shas["aarch64-macos"] = "abc"
  none, trouble = Actionlint.install_name(pin, "aarch64-macos")
  assert(none == nil and trouble:find("64 hex", 1, true) ~= nil)
end

local function test_ensure_installed_replaces_a_binary_its_record_does_not_match(tmp: string)
  local cache = tmp .. "/cache"
  local install = cache .. "/1.7.12-x86_64-linux"
  local pin: Actionlint.Pin = { version = "1.7.12", shas = { ["x86_64-linux"] = "abc" } }
  local calls: {string} = {}
  -- A record that names other bytes, and none at all.
  local records: {string | boolean} = { Hash.hex_sha256("#!/bin/sh\necho verified\n"), false }
  for _, record in ipairs(records) do
    assert(Fs.mkdirs(install))
    assert(Fs.write(install .. "/actionlint", "#!/bin/sh\necho swapped\n", 0x1ed))
    if record is string then
      assert(Fs.write(install .. "/actionlint.sha256", record .. "\n"))
    end
    local binary = assert(Actionlint.ensure_installed(cache, install, pin, "x86_64-linux",
      serving("#!/bin/sh\necho fresh\n", calls)))
    assert(assert(Fs.read(binary)) == "#!/bin/sh\necho fresh\n")
    assert(Fs.remove_tree(install))
  end
  assert(#calls == 2)
end
