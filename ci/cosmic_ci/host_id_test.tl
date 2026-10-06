--- `leg-host-id`, which names a CI leg's host (COSMIC_HOST_ID, and on
--- macOS COSMIC_SYSTEM_ID) and the leg's verdict cache:
--- `verdicts-<leg>-<16 hex of COSMIC_HOST_ID's sha256>-` and the host's
--- features, as ci.yml's restore, lookup and save key it. A Linux leg is
--- named by its container, the macOS leg, which has none, by its runner.
--- It runs against recorded hosts, whose digests and names are vectors
--- recorded from the original shell implementation: a byte that moves
--- renames every verdict cache.
local Fs = require("cosmic.fs")
local HostId = require("cosmic_ci.host_id")
local Json = require("cosmic.json")
local Test = require("cosmic.test")

--- The recorded hosts, which build/host_features_test.tl holds
--- `declared_key.host_features` to as well.
Test.policy{
  grants = { { path = "testdata/host_features", letters = "r" } },
}

local record Vector
  name: string
  sysname: string
  machine: string
  cpuinfo: string | nil
  osrelease: string | nil
  version: string | nil
  sysctl: {string:string} | nil
  digest: string
end

local function vectors(): {Vector}
  local text = assert(Fs.read("testdata/host_features/vectors.json"))
  local found = assert(Json.decode_array(text))
  local out: {Vector} = {}
  for i, entry in ipairs(found) do out[i] = entry as Vector end
  return out
end

--- The facts of the recorded host `vector`, where `docker` answers the
--- engine's version (nil: it fails).
local function facts_of(vector: Vector, docker?: string): HostId.Facts
  local files: {string:string} = {}
  if vector.sysname == "Darwin" then
    files["/System/Library/CoreServices/SystemVersion.plist"] = vector.osrelease
  else
    files["/proc/cpuinfo"] = vector.cpuinfo
    files["/proc/sys/kernel/osrelease"] = vector.osrelease
    files["/proc/sys/kernel/version"] = vector.version
  end
  return {
    sysname = vector.sysname,
    machine = vector.machine,
    read = function(path: string): string | nil return files[path] end,
    sysctl = function(name: string): string | nil
      local answer = (vector.sysctl or {})[name]
      return answer ~= nil and answer .. "\n" or nil
    end,
    docker_version = function(): string | nil, string
      if docker == nil then return nil, "Cannot connect" end
      return docker, ""
    end,
  }
end

local function vector_named(name: string): Vector
  for _, vector in ipairs(vectors()) do
    if vector.name == name then return vector end
  end
  error("no recorded host " .. name)
end

--- Every recorded host is named as its vector says: x86_64,
--- aarch64 and a machine no audit has read; spaces, tabs, CRLF, no final
--- line break, bytes beyond ASCII; a host with no cpuinfo or no kernel
--- files; and macOS, which asks sysctl.
local function test_every_recorded_host_is_named_as_the_script_named_it()
  local count = 0
  for _, vector in ipairs(vectors()) do
    local named = HostId.features(facts_of(vector))
    assert(named == vector.digest, vector.name .. ": " .. named .. ", the script " .. vector.digest)
    count = count + 1
  end
  assert(count >= 20, "the recorded hosts are gone")
end

--- The features of a host move with what a core on it chooses code by,
--- the kernel's release and its version, and with nothing else.
local function test_what_moves_the_features_of_a_host()
  local x86 = vector_named("x86")
  local function features(cpuinfo: string, osrelease: string, version: string): string
    return HostId.features(facts_of({ name = "", sysname = "Linux", machine = "x86_64",
      cpuinfo = cpuinfo, osrelease = osrelease, version = version, digest = "" }))
  end
  local start = features("flags : aes pclmulqdq sse4_1 ssse3\n", "6.17.0-1022-azure\n", "#22-Ubuntu SMP\n")
  -- Features no core chooses code by, and their order, name no new host.
  assert(features("flags : sse4_1 aes ssse3 pclmulqdq avx512f\n", "6.17.0-1022-azure\n",
    "#22-Ubuntu SMP\n") == start)
  assert(features("flags : aes pclmulqdq sse4_1\n", "6.17.0-1022-azure\n", "#22-Ubuntu SMP\n") ~= start)
  assert(features("flags : aes pclmulqdq sse4_1 ssse3\n", "6.17.0-1023-azure\n", "#22-Ubuntu SMP\n") ~= start)
  assert(features("flags : aes pclmulqdq sse4_1 ssse3\n", "6.17.0-1022-azure\n", "#23-Ubuntu SMP\n") ~= start)
  assert(HostId.features(facts_of(x86)) == x86.digest)
end

--- Where the host's files are missing, or the machine is no x86 or arm
--- one, the digest is still a name.
local function test_a_host_with_no_files_is_still_named()
  local bare: HostId.Facts = {
    sysname = "", machine = "",
    read = function(_path: string): string | nil return nil end,
    sysctl = function(_name: string): string | nil return nil end,
    docker_version = function(): string | nil, string return nil, "" end,
  }
  -- sha256 of nothing, 16 hex digits.
  assert(HostId.features(bare) == "e3b0c44298fc1c14", HostId.features(bare))
end

local runs = 0

--- What the command appends to $GITHUB_ENV and to $GITHUB_OUTPUT (nil
--- where `files` is false: unset), what it said and wrote to standard
--- output, and its status, run with `words` and `env` on the recorded
--- host `host`, whose engine answers `docker`.
local function named(tmp: string, host: string, words: {string}, env: {string:string}, docker?: string):
    string | nil, string | nil, string, integer
  runs = runs + 1
  local dir = tmp .. "/run-" .. runs
  assert(Fs.mkdirs(dir))
  local merged: {string:string} = { GITHUB_ENV = dir .. "/env", GITHUB_OUTPUT = dir .. "/output" }
  for name, value in pairs(env) do merged[name] = value end
  local said: {string} = {}
  local code = HostId.leg_host_id(words, merged, facts_of(vector_named(host), docker),
    function(text: string) said[#said + 1] = text end)
  local env_text, _ = Fs.read(dir .. "/env")
  local output, _ = Fs.read(dir .. "/output")
  return env_text, output, table.concat(said), code
end

local LINUX <const> = "x86"
local LINUX_FEATURES <const> = "e709205be4810032"
local IMAGE <const> = "ghcr.io/cosmic-lua/cosmic-ci-ubuntu@sha256:" ..
  "947fe8ea3f96e963d1e922113e55324276db1d6a92908d8c79094f29a23c8d4a"
local STARTED <const> = ("a"):rep(64)

--- A Linux leg is named by its container: the image, the hash of how it
--- is started, and the engine's version.
local function test_a_linux_leg_is_named_by_its_container(tmp: string)
  local env, output, said, code = named(tmp, LINUX, { "linux-x86_64", "ghcr.io/c/i@sha256:ab",
    "ubuntu-24.04", "cafe" }, { ImageOS = "ubuntu24", ImageVersion = "1" }, "28.0.4")
  assert(code == 0 and said == "", said)
  assert(env == "COSMIC_HOST_ID=ghcr.io/c/i@sha256:ab cafe docker-28.0.4\n", env)
  assert(output == "prefix=verdicts-linux-x86_64-4a1d76e5ec7ac3c6-\n" ..
      "verdicts=verdicts-linux-x86_64-4a1d76e5ec7ac3c6-" .. LINUX_FEATURES .. "-\n", output)
end

--- The names ci.yml's three steps give: the platform job's, the checked
--- job's, and the light run's, which keeps no COSMIC_HOST_ID
--- (GITHUB_ENV=/dev/null) and keys by the platform job's.
local function test_the_workflows_legs_are_named_as_the_script_named_them(tmp: string)
  local _, platform = named(tmp, "this", { "linux-x86_64", IMAGE, "ubuntu-24.04", STARTED }, {}, "28.0.4")
  assert(platform == "prefix=verdicts-linux-x86_64-cd38a6c7ffd72fed-\n" ..
      "verdicts=verdicts-linux-x86_64-cd38a6c7ffd72fed-76038305182e5556-\n", platform)
  local env, checked = named(tmp, "this", { "linux-x86_64-checked", IMAGE, "ubuntu-24.04", STARTED }, {}, "28.0.4")
  assert(env == "COSMIC_HOST_ID=" .. IMAGE .. " " .. STARTED .. " docker-28.0.4\n", env)
  assert(checked == "prefix=verdicts-linux-x86_64-checked-cd38a6c7ffd72fed-\n" ..
      "verdicts=verdicts-linux-x86_64-checked-cd38a6c7ffd72fed-76038305182e5556-\n", checked)
  local none, light = named(tmp, "this", { "linux-x86_64", IMAGE, "ubuntu-24.04", STARTED },
    { GITHUB_ENV = "/dev/null" }, "28.0.4")
  assert(none == nil, "the environment file is /dev/null's")
  assert(light == platform, light)
  local _, arm = named(tmp, "arm", { "linux-aarch64", "ghcr.io/c/arm@sha256:cd", "ubuntu-24.04-arm", "beef" },
    {}, "28.0.4")
  assert(arm == "prefix=verdicts-linux-aarch64-5d5805cd0d3eb351-\n" ..
      "verdicts=verdicts-linux-aarch64-5d5805cd0d3eb351-69879e047aa11846-\n", arm)
  -- A leg with no runner is named by its container alone, and a name
  -- is taken as given.
  local _, odd = named(tmp, "this", { "a b", "i", "r", "s" }, {}, "28.0.4")
  assert(odd == "prefix=verdicts-a b-561229c72f9f67eb-\nverdicts=verdicts-a b-561229c72f9f67eb-" ..
      "76038305182e5556-\n", odd)
  local _, bare = named(tmp, "this", { "alpine-x86_64", "img", "", "abc" }, {}, "28.0.4")
  assert(bare == "prefix=verdicts-alpine-x86_64-2b06a98f2cd61c3a-\nverdicts=verdicts-alpine-x86_64-" ..
      "2b06a98f2cd61c3a-76038305182e5556-\n", bare)
end

--- The macOS leg, with no image, is named by its runner, and names the
--- runner's image version apart (COSMIC_SYSTEM_ID), which only a
--- module given the system's paths is keyed by; it runs no docker.
local function test_the_macos_leg_is_named_by_its_runner(tmp: string)
  local env, output, said, code = named(tmp, "darwin-all", { "macos-aarch64", "", "macos-15", "cafe" },
    { ImageOS = "macos15", ImageVersion = "20250922.1" })
  assert(code == 0 and said == "", said)
  assert(env == "COSMIC_SYSTEM_ID=macos15 20250922.1\nCOSMIC_HOST_ID=macos-15\n", env)
  assert(output == "prefix=verdicts-macos-aarch64-76f4af51eb54ac60-\n" ..
      "verdicts=verdicts-macos-aarch64-76f4af51eb54ac60-d86f880ad83e73ad-\n", output)
  -- The image's version names no cache of its own: a new one restores
  -- the last and reruns only what is keyed by it.
  local _, again = named(tmp, "darwin-all", { "macos-aarch64", "", "macos-15", "beef" },
    { ImageOS = "macos15", ImageVersion = "20251006.2" })
  assert(again == output, again)
end

--- What the engine prints, less the line breaks that end it, names the
--- host; an engine that fails refuses the leg, and writes nothing.
local function test_the_engines_version_is_taken_as_printed(tmp: string)
  local env = named(tmp, LINUX, { "linux-x86_64", "img", "r", "s" }, {}, "28.0.4\n\n\n")
  assert(env == "COSMIC_HOST_ID=img s docker-28.0.4\n", tostring(env))
  local failed_env, failed_output, _, code = named(tmp, LINUX, { "linux-x86_64", "img", "r", "s" }, {})
  assert(code == 1 and failed_env == nil and failed_output == nil, tostring(code))
  -- The macOS leg asks no engine.
  local _, _, _, mac = named(tmp, "darwin-all", { "macos-aarch64", "", "macos-15", "beef" },
    { ImageOS = "macos15", ImageVersion = "1" })
  assert(mac == 0)
end

--- With no $GITHUB_ENV or $GITHUB_OUTPUT, or empty ones, the lines go to
--- standard output, the environment's first, for a run by hand.
local function test_unset_files_say_their_lines_instead(tmp: string)
  local _, _, said, code = named(tmp, LINUX, { "linux-x86_64", "img", "r", "s" },
    { GITHUB_ENV = "", GITHUB_OUTPUT = "" }, "28.0.4")
  assert(code == 0)
  assert(said == "COSMIC_HOST_ID=img s docker-28.0.4\n" ..
      "prefix=verdicts-linux-x86_64-2e4dd1599b5fdb64-\n" ..
      "verdicts=verdicts-linux-x86_64-2e4dd1599b5fdb64-" .. LINUX_FEATURES .. "-\n", said)
  local _, _, mac = named(tmp, "darwin-all", { "macos-aarch64", "", "macos-15", "cafe" },
    { GITHUB_ENV = "", GITHUB_OUTPUT = "", ImageOS = "macos15", ImageVersion = "1" })
  assert(mac == "COSMIC_SYSTEM_ID=macos15 1\nCOSMIC_HOST_ID=macos-15\n" ..
      "prefix=verdicts-macos-aarch64-76f4af51eb54ac60-\n" ..
      "verdicts=verdicts-macos-aarch64-76f4af51eb54ac60-d86f880ad83e73ad-\n", mac)
end

--- A leg with no image and no runner, or with no image and a runner that
--- names no image (ImageOS, ImageVersion), or the wrong count of words,
--- is refused before anything is written.
local function test_a_leg_named_by_nothing_is_refused(tmp: string)
  local image = { ImageOS = "macos15", ImageVersion = "20250922.1" }
  local mac = { "macos-aarch64", "", "macos-15", "cafe" }
  for _, case in ipairs({
      { args = { "macos-aarch64", "", "", "cafe" }, env = image },
      { args = { "a", "b", "c" }, env = image },
      { args = { "a", "b", "c", "d", "e" }, env = image },
      { args = mac, env = {} },
      { args = mac, env = { ImageOS = "macos15", ImageVersion = "" } },
      { args = mac, env = { ImageOS = "", ImageVersion = "20250922.1" } },
  }) do
    local env, output, said, code = named(tmp, "darwin-all", case.args, case.env, "28.0.4")
    assert(code == 2 and env == nil and output == nil and said == "",
      table.concat(case.args, " ") .. ": " .. code)
  end
end
