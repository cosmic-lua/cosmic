--- `leg-host-id`, which names a CI leg's host: what of it no file on it
--- tells, which every declared-key verdict's key holds (build/declared_key.tl's
--- `host_identity`, through COSMIC_HOST_ID), and the name of the leg's
--- verdict cache, which that and the host's kernel
--- ([`HostId.kernel`]) make, as ci.yml's restore, lookup and save
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
--- [`HostId.kernel`]), and what the image installs beside them --
--- Xcode, /opt/homebrew, /usr/local -- goes in COSMIC_SYSTEM_ID as the
--- runner names the image ("$ImageOS $ImageVersion"), which only a key of
--- a module given the system's paths holds (`system_identity`): an image
--- update that moves only those restores the cache and reruns only such
--- modules, and one that moves the OS build names a new cache.
---
--- It appends COSMIC_HOST_ID, and COSMIC_SYSTEM_ID on macOS, to
--- $GITHUB_ENV, and to $GITHUB_OUTPUT `prefix`,
--- verdicts-NAME-<16 hex of COSMIC_HOST_ID's sha256>-, and `verdicts`,
--- that, the kernel and a `-`: the prefix a restore of the leg's
--- verdicts falls back to. The processor's features are no part of the
--- name, so runners of other processors restore one cache; a key holds
--- them only for a module that declares `cpu_features`
--- (build/declared_key.tl's `host_cpu`). Each defaults to standard
--- output, for a run by hand. The step also says, on standard error, what
--- it hashed and read of the host ([`HostId.describe`]): the kernel's
--- release and version and the processor's features a core chooses code
--- by, which CI's logs then show to differ between runners. A leg with
--- neither IMAGE nor RUNNER, and one with no IMAGE where the runner names
--- no image (ImageOS or ImageVersion unset or empty), is refused, as is a
--- container engine that does not answer, before anything is written.
---
--- Both digests must stay what they were: they name every verdict
--- cache, so a byte that moves renames them all. host_id_test.tl holds
--- them to vectors recorded from the original shell implementation, and
--- build/host_features_test.tl holds `declared_key.host_kernel` to the
--- same vectors (testdata/host_features), as it holds the features
--- `describe` lists to `declared_key.host_cpu`'s.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")
local sys = require("cosmic.sys")

local record HostId
  --- What of the host a name reads, which a test replaces.
  record Facts
    --- The kernel's name and the machine, as `uname -s` and `uname -m`
    --- print them ("" where unknown).
    sysname: string
    machine: string
    --- A file's bytes, nil where it is missing or unreadable.
    read: function(path: string): string?
    --- What `sysctl -n NAME` prints on macOS, nil where it fails.
    sysctl: function(name: string): string?
    --- What `docker version --format '{{.Server.Version}}'` prints,
    --- the container engine's server version, or nil and why where it
    --- fails.
    docker_version: function(): string?, string
  end
  --- The facts of this host, finding its programs on `env`'s PATH.
  live: function(env: {string:string}): Facts
  --- The first 16 hex digits of a sha256 of what of this host every
  --- sandboxed verdict's key holds and differs between runners of one
  --- leg (build/declared_key.tl's `host_identity` and `host_kernel`,
  --- which answer the same digest): the kernel's release and version, as
  --- their files hold them, a missing one as empty -- on macOS, the
  --- system volume's SystemVersion.plist, which names its build, and
  --- nothing. The processor's features are not part of it.
  kernel: function(facts: Facts): string
  --- The processor's features a key holds for a module that declares
  --- `cpu_features` (build/declared_key.tl's `host_cpu`), by the names
  --- /proc/cpuinfo lists them under ("flags" on x86, "Features" on arm),
  --- each once, in byte order, less those a core on this machine chooses
  --- no code by (`keep`) -- on macOS, where there is no /proc, those of
  --- core/syscalls.c's `cpu_features` that sysctl answers 1 for
  --- (`darwin_features`). On Linux the key asks the processor itself
  --- (cpuid, the auxiliary vector) where this reads /proc/cpuinfo: the
  --- two differ only where the kernel hides a flag the processor has,
  --- which costs a cache hit, not a verdict.
  cpu_flags: function(facts: Facts): {string}
  --- What a step logs of the host: the kernel's release and version as
  --- `kernel` hashes them, the processor's model, the features a key
  --- holds ([`cpu_flags`]) and those a core chooses code by that this
  --- processor lacks, a line each, ending in a line break.
  describe: function(facts: Facts): string
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
  x86_64 = { "aes", "avx512_vnni", "avx512f", "avx512vl", "avx_vnni", "pclmulqdq", "sha_ni", "sse4_1",
    "ssse3" },
  aarch64 = { "aes", "asimd", "crc32", "pmull", "sha2", "sha512" },
}

-- Each sysctl name core/syscalls.c's `cpu_features` asks on macOS, by
-- the feature's name.
local record DarwinFeature
  name: string
  sysctl: string
end

local darwin_features: {DarwinFeature} = {
  { name = "aes", sysctl = "hw.optional.arm.FEAT_AES" },
  { name = "asimd", sysctl = "hw.optional.AdvSIMD" },
  { name = "crc32", sysctl = "hw.optional.armv8_crc32" },
  { name = "pmull", sysctl = "hw.optional.arm.FEAT_PMULL" },
  { name = "sha2", sysctl = "hw.optional.arm.FEAT_SHA256" },
  { name = "sha512", sysctl = "hw.optional.armv8_2_sha512" },
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
  local found: mut {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local flags = line:match("^flags%s*:%s*(.*)$") or line:match("^Features%s*:%s*(.*)$")
    for flag in (flags or ""):gmatch("[^ \t]+") do found[#found + 1] = flag end
  end
  return found
end

function HostId.cpu_flags(facts: HostId.Facts): {string}
  local found: mut {string} = {}
  if facts.sysname == "Darwin" then
    for _, feature in ipairs(darwin_features) do
      if chomp(facts.sysctl(feature.sysctl) or "") == "1" then found[#found + 1] = feature.name end
    end
  else
    for _, flag in ipairs(listed(facts.read("/proc/cpuinfo") or "")) do found[#found + 1] = flag end
  end
  table.sort(found)
  local wanted: {string:boolean}?
  local kept = keep[facts.machine]
  if kept ~= nil then
    local set: mut {string:boolean} = {}
    for _, flag in ipairs(kept) do set[flag] = true end
    wanted = set
  end
  local out: mut {string} = {}
  local last: string?
  for _, flag in ipairs(found) do
    if flag ~= last and (wanted == nil or wanted[flag] == true) then out[#out + 1] = flag end
    last = flag
  end
  return out
end

--- The kernel's release and version as `facts` holds them, which
--- [`HostId.kernel`] hashes: macOS's alone is the system volume's
--- SystemVersion.plist.
local function kernel_parts(facts: HostId.Facts): {string}
  if facts.sysname == "Darwin" then return { facts.read(darwin_system) or "" } end
  return { facts.read("/proc/sys/kernel/osrelease") or "", facts.read("/proc/sys/kernel/version") or "" }
end

function HostId.kernel(facts: HostId.Facts): string
  return Hash.hex_sha256(table.concat(kernel_parts(facts))):sub(1, 16)
end

function HostId.describe(facts: HostId.Facts): string
  local lines: mut {string} = {}
  local release, version = table.unpack(kernel_parts(facts))
  lines[#lines + 1] = "kernel " .. HostId.kernel(facts)
  lines[#lines + 1] = "  release " .. string.format("%q", chomp(release or ""))
  if version ~= nil then lines[#lines + 1] = "  version " .. string.format("%q", chomp(version)) end
  local model = (facts.read("/proc/cpuinfo") or ""):match("\n?model name%s*:%s*([^\n]*)") or
    (facts.read("/proc/cpuinfo") or ""):match("\n?Model%s*:%s*([^\n]*)")
  lines[#lines + 1] = "cpu " .. facts.machine .. " " .. string.format("%q", chomp(model or ""))
  local flags = HostId.cpu_flags(facts)
  lines[#lines + 1] = "  keyed features " .. table.concat(flags, " ")
  local have: mut {string:boolean} = {}
  for _, flag in ipairs(flags) do have[flag] = true end
  local lacking: mut {string} = {}
  for _, flag in ipairs(keep[facts.machine] or {}) do
    if have[flag] ~= true then lacking[#lacking + 1] = flag end
  end
  lines[#lines + 1] = "  dispatched features absent " .. table.concat(lacking, " ")
  return table.concat(lines, "\n") .. "\n"
end

-- No test runs this: none runs the system's docker or sysctl, and the
-- tests hold every name to the answers given by a recorded host. Where
-- one goes wrong, the step fails or the host names fewer features, which
-- a leg's first run shows.
function HostId.live(env: {string:string}): HostId.Facts
  local names, _ = sys.uname()
  local sysname, machine = "", ""
  if names ~= nil then sysname, machine = names.sysname, names.machine end
  local docker, _ = Proc.find("docker", env["PATH"] or "")
  return {
    sysname = sysname,
    machine = machine,
    read = function(path: string): string?
      local text, _ = Fs.read(path)
      return text
    end,
    -- By its path: /usr/sbin is not on every shell's default PATH.
    sysctl = function(name: string): string?
      local result, _ = Child.run({ "/usr/sbin/sysctl", "-n", name }, { env = env, stdin = "null",
        stdout = "capture", stderr = "null", timeout_ns = Clock.seconds(30) })
      if result == nil or not result.ok then return nil end
      return result.stdout or ""
    end,
    docker_version = function(): string?, string
      if docker == nil then return nil, "docker: not found" end
      local result, _ = Child.run({ docker, "version", "--format", "{{.Server.Version}}" },
        { env = env, stdin = "null", stdout = "capture", stderr = Fs.stderr,
          timeout_ns = Clock.seconds(120) })
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
  local name, image, runner, started = words[1], words[2], words[3], words[4]
  if #words ~= 4 or name == nil or image == nil or runner == nil or started == nil then
    return refuse("usage: leg-host-id NAME IMAGE RUNNER STARTED", 2)
  end
  local system_os, system_version = env["ImageOS"] or "", env["ImageVersion"] or ""
  if image == "" then
    if runner == "" then return refuse("a leg with no image names no RUNNER", 2) end
    if system_os == "" or system_version == "" then
      return refuse("a leg with no image needs ImageOS and ImageVersion", 2)
    end
  end
  local id: string
  local env_lines: mut {string} = {}
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
  local function write(file: string?, lines: {string}): boolean
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
  if not write(env["GITHUB_ENV"], env_lines) then return 1 end
  if not write(env["GITHUB_OUTPUT"], { "prefix=" .. prefix,
      "verdicts=" .. prefix .. HostId.kernel(facts) .. "-" }) then
    return 1
  end
  local _, _ = Fs.put(Fs.stderr, "leg-host-id: " .. name .. " host\n" .. HostId.describe(facts))
  return 0
end

function HostId.command(argv: {string}): integer
  local words: mut {string} = {}
  for _, word in ipairs(argv) do words[#words + 1] = word end
  local env = Env.all()
  return HostId.leg_host_id(words, env, HostId.live(env), function(text: string)
    local _, _ = Fs.put(Fs.stdout, text)
  end)
end

return HostId
