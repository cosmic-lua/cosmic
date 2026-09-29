--- .github/scripts/leg-host-id.sh, which names a CI leg's host
--- (COSMIC_HOST_ID, and on macOS COSMIC_SYSTEM_ID) and the leg's
--- verdict cache: `verdicts-<leg>-<16 hex of COSMIC_HOST_ID's sha256>-`
--- and the host's features (what .github/scripts/host-features.sh
--- prints, which ci.yml passes it), as ci.yml's restore, lookup and
--- save key it. A Linux leg is named by its container, the macOS leg,
--- which has none, by its runner.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Test = require("cosmic.test")

--- The script, and the system's `sh` and tools, which run it.
Test.needs{ reads = { ".github/scripts/leg-host-id.sh" }, system = true }

-- By its whole path: a process the test starts elsewhere finds it.
local SCRIPT <const> = assert(Fs.absolute(".github/scripts/leg-host-id.sh"))

--- The host's features, as host-features.sh prints them.
local FEATURES <const> = "0123456789abcdef"

--- What the script appends to $GITHUB_ENV and to $GITHUB_OUTPUT, run
--- with `args` and `extra` added to a bare environment, and a `docker`
--- on PATH that names engine 28.0.4; or its status and what it said.
local runs = 0
local function named(tmp: string, args: {string}, extra: {string:string}):
    string, string, integer, string
  runs = runs + 1
  local dir = tmp .. "/run-" .. runs
  assert(Fs.mkdirs(dir .. "/bin"))
  assert(Fs.write(dir .. "/bin/docker", "#!/bin/sh\necho 28.0.4\n"))
  assert(Fs.chmod(dir .. "/bin/docker", 493))
  local env: {string:string} = {
    PATH = dir .. "/bin:" .. (Env.get("PATH") or "/usr/bin:/bin"),
    GITHUB_ENV = dir .. "/env", GITHUB_OUTPUT = dir .. "/output",
  }
  for name, value in pairs(extra) do env[name] = value end
  local argv = { "/bin/sh", SCRIPT }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result = assert(Child.run(argv, { env = env, cwd = dir, stdout = "capture",
    stderr = "capture", timeout_ms = 30000 }))
  return Fs.read(dir .. "/env") or "", Fs.read(dir .. "/output") or "",
    result.code, (result.stdout or "") .. (result.stderr or "")
end

--- The outputs a leg `leg` named by `id` writes.
local function outputs(leg: string, id: string): string
  local prefix = "verdicts-" .. leg .. "-" .. Hash.hex_sha256(id):sub(1, 16) .. "-"
  return "prefix=" .. prefix .. "\nverdicts=" .. prefix .. FEATURES .. "-\n"
end

--- A Linux leg is named by its container: the image, the hash of how it
--- is started, and the engine's version.
local function test_a_linux_leg_is_named_by_its_container(tmp: string)
  local env, output, code, said = named(tmp, { "linux-x86_64", "ghcr.io/c/i@sha256:ab",
    "ubuntu-24.04", "cafe", FEATURES }, { ImageOS = "ubuntu24", ImageVersion = "1" })
  assert(code == 0, said)
  local id = "ghcr.io/c/i@sha256:ab cafe docker-28.0.4"
  assert(env == "COSMIC_HOST_ID=" .. id .. "\n", env)
  assert(output == outputs("linux-x86_64", id), output)
end

--- The macOS leg, with no image, is named by its runner, and names the
--- runner's image version apart (COSMIC_SYSTEM_ID), which only a
--- module given the system's paths is keyed by; it runs no docker.
local function test_the_macos_leg_is_named_by_its_runner(tmp: string)
  local env, output, code, said = named(tmp, { "macos-aarch64", "", "macos-15", "cafe", FEATURES },
    { ImageOS = "macos15", ImageVersion = "20250922.1", PATH = "/usr/bin:/bin" })
  assert(code == 0, said)
  local lines: {string:boolean} = {}
  local count = 0
  for line in env:gmatch("[^\n]+") do lines[line], count = true, count + 1 end
  assert(count == 2 and lines["COSMIC_SYSTEM_ID=macos15 20250922.1"] and
    lines["COSMIC_HOST_ID=macos-15"], env)
  assert(output == outputs("macos-aarch64", "macos-15"), output)
  -- The image's version names no cache of its own: a new one restores
  -- the last and reruns only what is keyed by it.
  local _, again = named(tmp, { "macos-aarch64", "", "macos-15", "beef", FEATURES },
    { ImageOS = "macos15", ImageVersion = "20251006.2", PATH = "/usr/bin:/bin" })
  assert(again == output, again)
end

--- A leg with no image and no runner, or none whose runner names its
--- image (ImageOS, ImageVersion), features that are no digest
--- (host-features.sh failed, which the step's command substitution
--- does not stop for), or the wrong count of words, is refused before
--- anything is written.
local function test_a_leg_named_by_nothing_is_refused(tmp: string)
  local image = { ImageOS = "macos15", ImageVersion = "20250922.1" }
  local mac = { "macos-aarch64", "", "macos-15", "cafe", FEATURES }
  for _, case in ipairs({
    { args = { "macos-aarch64", "", "", "cafe", FEATURES }, env = image },
    { args = { "macos-aarch64", "", "macos-15", "cafe", "" }, env = image },
    { args = { "linux-x86_64", "i", "ubuntu-24.04", "cafe", FEATURES .. "0" }, env = image },
    { args = { "a", "b", "c", "d" }, env = image },
    { args = mac, env = {} },
    { args = mac, env = { ImageOS = "macos15", ImageVersion = "" } },
    { args = mac, env = { ImageOS = "", ImageVersion = "20250922.1" } },
  }) do
    local env, output, code = named(tmp, case.args, case.env)
    assert(code == 2 and env == "" and output == "", table.concat(case.args, " ") .. ": " .. code)
  end
end
