--- `leg-host-id`, which names a CI leg's host: what of it no file on it
--- tells, which every declared-key verdict's key holds (build/declared_key.tl's
--- `host_identity`, through COSMIC_HOST_ID), and the name of the leg's
--- verdict cache, which that and the host's features
--- ([`HostId.features`]) make, as ci.yml's restore, lookup and save
--- key it:
---
---     cosmic-driver cosmic_ci/driver.tl leg-host-id NAME IMAGE RUNNER STARTED
---
--- NAME is the leg's (matrix.name). On a Linux leg, IMAGE is its
--- container's image and STARTED a hash of how the container is started
--- (ci.yml's hashFiles of leg-container.sh, seccomp-profile.sh and the
--- seccomp profile), and COSMIC_HOST_ID is those two and the container
--- engine's version. The macOS leg, which has no container (IMAGE
--- empty), is named by RUNNER, the image label it runs on (macos-15),
--- which names the OS release; its kernel and sealed system volume key
--- themselves (SystemVersion.plist, read by host_identity and by
--- [`HostId.features`]), and what the image installs beside them --
--- Xcode, /opt/homebrew, /usr/local -- goes in COSMIC_SYSTEM_ID as the
--- runner names the image ("$ImageOS $ImageVersion"), which only a key of
--- a module given the system's paths holds (`system_identity`): an image
--- update that moves only those restores the cache and reruns only such
--- modules, and one that moves the OS build names a new cache.
---
--- It appends COSMIC_HOST_ID, and COSMIC_SYSTEM_ID on macOS, to
--- $GITHUB_ENV, and to $GITHUB_OUTPUT `prefix`,
--- verdicts-NAME-<16 hex of COSMIC_HOST_ID's sha256>-, and `verdicts`,
--- that, the features and a `-`: the prefix a restore of the leg's
--- verdicts falls back to. Each defaults to standard output, for a run
--- by hand. A leg with neither IMAGE nor RUNNER, and one with no IMAGE
--- where the runner names no image (ImageOS or ImageVersion unset or
--- empty), is refused, as is a container engine that does not answer,
--- before anything is written.
---
--- Both digests must stay what they were: they name every verdict
--- cache, so a byte that moves renames them all. host_id_test.tl holds
--- them to what the shell scripts this replaced printed, and
--- build/host_features_test.tl holds `declared_key.host_features` to the
--- same vectors (testdata/host_features).
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")

local record HostId
  --- What of the host a name reads, which a test replaces.
  record Facts
    --- The kernel's name and the machine, as `uname -s` and `uname -m`
    --- print them ("" where unknown).
    sysname: string
    machine: string
    --- A file's bytes, nil where it is missing or unreadable.
    read: function(path: string): string | nil
    --- What `sysctl -n NAME` prints on macOS, nil where it fails.
    sysctl: function(name: string): string | nil
    --- What `docker version --format '{{.Server.Version}}'` prints,
    --- the container engine's server version, or nil and why where it
    --- fails.
    docker_version: function(): string | nil, string
  end
  --- The facts of this host, finding its programs on `env`'s PATH.
  live: function(env: {string:string}): Facts
  --- The first 16 hex digits of a sha256 of what of this host every
  --- sandboxed verdict's key holds and differs between runners of one
  --- leg (build/declared_key.tl's `host_identity` and `host_features`,
  --- which answer the same digest): the processor's features, by the
  --- names /proc/cpuinfo lists them under ("flags" on x86, "Features" on
  --- arm), each once, in byte order, a line each, less those a core on
  --- this machine chooses no code by (`keep`) -- on macOS, where there is
  --- no /proc, those of core/syscalls.c's `cpu_features` that sysctl
  --- answers 1 for (`darwin_features`); then the kernel's release and
  --- version, as their files hold them, a missing one as empty -- on
  --- macOS, the system volume's SystemVersion.plist, which names its
  --- build, and nothing. On Linux the key asks the processor itself
  --- (cpuid, the auxiliary vector) where this reads /proc/cpuinfo: the
  --- two differ only where the kernel hides a flag the processor has,
  --- which costs a cache hit, not a verdict.
  features: function(facts: Facts): string
  --- `leg-host-id`'s step in `env` (NAME IMAGE RUNNER STARTED in
  --- `words`) with `facts`; `say` takes what $GITHUB_ENV and
  --- $GITHUB_OUTPUT would where one is unset or empty. It answers the
  --- step's exit status.
  leg_host_id: function(words: {string}, env: {string:string}, facts: Facts,
    say: function(text: string)): integer
  --- `driver.tl leg-host-id`, in the process's environment.
  command: function(argv: {string}): integer
end

-- The features a core on this machine chooses code by, as
-- build/declared_key.tl's `dispatched` lists them, where `host_identity`
-- says which code reads each: a feature added there is added here. A
-- machine no audit has read keeps every feature (nil).
local keep: {string:{string}} = {
  x86_64 = { "aes", "pclmulqdq", "sse4_1", "ssse3" },
  aarch64 = { "aes", "asimd", "crc32", "pmull" },
}

-- Each sysctl name core/syscalls.c's `cpu_features` asks on macOS, by
-- the feature's name.
local darwin_features: {{string}} = {
  { "aes", "hw.optional.arm.FEAT_AES" },
  { "asimd", "hw.optional.AdvSIMD" },
  { "crc32", "hw.optional.armv8_crc32" },
  { "pmull", "hw.optional.arm.FEAT_PMULL" },
}

local darwin_system <const> = "/System/Library/CoreServices/SystemVersion.plist"

--- `text` without the line breaks that end it, as a shell's command
--- substitution leaves it.
local function chomp(text: string): string
  return (text:gsub("\n+$", ""))
end

--- A line's features: what follows "flags" or "Features" and a colon,
--- split at spaces and tabs.
local function listed(text: string): {string}
  local found: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local flags = line:match("^flags%s*:%s*(.*)$") or line:match("^Features%s*:%s*(.*)$")
    for flag in (flags or ""):gmatch("[^ \t]+") do found[#found + 1] = flag end
  end
  return found
end

function HostId.features(facts: HostId.Facts): string
  local found: {string}
  if facts.sysname == "Darwin" then
    found = {}
    for _, pair in ipairs(darwin_features) do
      if chomp(facts.sysctl(pair[2]) or "") == "1" then found[#found + 1] = pair[1] end
    end
  else
    found = listed(facts.read("/proc/cpuinfo") or "")
  end
  table.sort(found)
  local wanted: {string:boolean} | nil
  if keep[facts.machine] ~= nil then
    wanted = {}
    for _, flag in ipairs(keep[facts.machine]) do wanted[flag] = true end
  end
  local parts: {string} = {}
  local last: string | nil
  for _, flag in ipairs(found) do
    if flag ~= last and (wanted == nil or wanted[flag]) then parts[#parts + 1] = flag .. "\n" end
    last = flag
  end
  if facts.sysname == "Darwin" then
    parts[#parts + 1] = facts.read(darwin_system) or ""
  else
    parts[#parts + 1] = facts.read("/proc/sys/kernel/osrelease") or ""
    parts[#parts + 1] = facts.read("/proc/sys/kernel/version") or ""
  end
  return Hash.hex_sha256(table.concat(parts)):sub(1, 16)
end

-- No test runs this: none runs the system's docker or sysctl, and the
-- tests hold every name to the answers given by a recorded host. Where
-- one goes wrong, the step fails or the host names fewer features, which
-- a leg's first run shows.
function HostId.live(env: {string:string}): HostId.Facts
  local names = sys.uname()
  local docker = Proc.find("docker", env.PATH or "")
  return {
    sysname = names ~= nil and names.sysname or "",
    machine = names ~= nil and names.machine or "",
    read = function(path: string): string | nil
      local text, _ = Fs.read(path)
      return text
    end,
    -- By its path: /usr/sbin is not on every shell's default PATH.
    sysctl = function(name: string): string | nil
      local result = Child.run({ "/usr/sbin/sysctl", "-n", name }, { env = env, stdin = "null",
        stdout = "capture", stderr = "null", timeout_ns = Time.seconds(30) })
      if result == nil or not result.ok then return nil end
      return result.stdout or ""
    end,
    docker_version = function(): string | nil, string
      if docker == nil then return nil, "docker: not found" end
      local result = Child.run({ docker, "version", "--format", "{{.Server.Version}}" },
        { env = env, stdin = "null", stdout = "capture", timeout_ns = Time.seconds(120) })
      if result == nil or not result.ok then return nil, "docker version failed" end
      return result.stdout or "", ""
    end,
  }
end

function HostId.leg_host_id(words: {string}, env: {string:string}, facts: HostId.Facts,
                            say: function(text: string)): integer
  local function refuse(why: string, code: integer): integer
    local _, _ = Fs.put(Fs.stderr, "leg-host-id: " .. why .. "\n")
    return code
  end
  if #words ~= 4 then return refuse("usage: leg-host-id NAME IMAGE RUNNER STARTED", 2) end
  local name, image, runner, started = words[1], words[2], words[3], words[4]
  local system_os, system_version = env.ImageOS or "", env.ImageVersion or ""
  if image == "" then
    if runner == "" then return refuse("a leg with no image names no RUNNER", 2) end
    if system_os == "" or system_version == "" then
      return refuse("a leg with no image needs ImageOS and ImageVersion", 2)
    end
  end
  local id: string
  local env_lines: {string} = {}
  if image ~= "" then
    local version, why = facts.docker_version()
    if version == nil then return refuse(why, 1) end
    id = image .. " " .. started .. " docker-" .. chomp(version)
  else
    id = runner
    env_lines[#env_lines + 1] = "COSMIC_SYSTEM_ID=" .. system_os .. " " .. system_version
  end
  env_lines[#env_lines + 1] = "COSMIC_HOST_ID=" .. id
  local prefix = "verdicts-" .. name .. "-" .. Hash.hex_sha256(id):sub(1, 16) .. "-"
  local function write(file: string | nil, lines: {string}): boolean
    local text = table.concat(lines, "\n") .. "\n"
    if file == nil or file == "" then
      say(text)
      return true
    end
    local ok, trouble = Fs.append(file, text)
    if not ok then
      local _, _ = Fs.put(Fs.stderr, "leg-host-id: " .. trouble .. "\n")
    end
    return ok
  end
  if not write(env.GITHUB_ENV, env_lines) then return 1 end
  if not write(env.GITHUB_OUTPUT, { "prefix=" .. prefix,
      "verdicts=" .. prefix .. HostId.features(facts) .. "-" }) then
    return 1
  end
  return 0
end

function HostId.command(argv: {string}): integer
  local words: {string} = {}
  for i = 1, #argv do words[i] = argv[i] end
  local env = Env.all()
  return HostId.leg_host_id(words, env, HostId.live(env), function(text: string)
    local _, _ = Fs.put(Fs.stdout, text)
  end)
end

return HostId
