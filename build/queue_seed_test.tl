--- .github/scripts/queue-seed.sh, which keeps in a merge queue run's leg
--- what main would have saved, under the keys it would have saved it
--- under (`stage`). The queue's lookups it once held (`find`, `ahead`)
--- are the driver's, tested in ci/cosmic_ci/queue_seed_test.tl.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Test = require("cosmic.test")
local Time = require("cosmic.time")

--- The script, and the system's `sh` and tools, which run it; and
--- ci.yml, whose keys `stage` is run with and whose `seed` job reads.
Test.policy{
  profiles = { "system" },
  grants = {
    { path = ".github/scripts/queue-seed.sh", letters = "r" },
    { path = ".github/workflows/ci.yml", letters = "r" },
  },
}

--- The script, by its whole path: a process the test starts elsewhere
--- finds it.
local SCRIPT <const> = assert(Fs.absolute(".github/scripts/queue-seed.sh"))
local SHA <const> = "0123456789abcdef0123456789abcdef01234567"

local runs = 0

--- What `stage` keeps under $RUNNER_TEMP/seed, run with `env` and, where
--- `marker`, a passing driver check's marker (holding `marker_key`, or
--- a key of no shape), and its seed.keys. The zig build outputs hold a
--- program, whose mode their seed keeps.
local function stage(tmp: string, env: {string: string}, marker: boolean, marker_key?: string): string, string
  runs = runs + 1
  local temp = tmp .. "/stage-" .. runs
  assert(Fs.mkdirs(temp .. "/zig-build/zig-project/o/abc"))
  assert(Fs.write(temp .. "/zig-build/zig-project/o/abc/build", "z"))
  assert(Fs.chmod(temp .. "/zig-build/zig-project/o/abc/build", 493))
  assert(Fs.mkdirs(temp .. "/verdicts"))
  assert(Fs.write(temp .. "/verdicts/verdicts.db", "v"))
  assert(Fs.mkdirs(temp .. "/build-cache"))
  assert(Fs.write(temp .. "/build-cache/cache.db", "c"))
  if marker then
    assert(Fs.mkdirs(temp .. "/driver-checked"))
    assert(Fs.write(temp .. "/driver-checked/key", (marker_key or "driver-checked-v2-leg-x") .. "\n"))
  end
  local full: {string: string} = { PATH = Env.get("PATH") or "/usr/bin:/bin", RUNNER_TEMP = temp }
  for name, value in pairs(env) do full[name] = value end
  local result = assert(Child.run({ "/bin/sh", SCRIPT, "stage" }, { env = full, cwd = temp,
    stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) }))
  assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
  return temp .. "/seed", Fs.read(temp .. "/seed/seed.keys") or ""
end

--- Each cache is kept, under its prefix and digest, where the run moved
--- it from the entry it restored, and the driver check's marker where
--- the check ran; nothing else is kept.
local function test_stage_keeps_what_main_would_save(tmp: string)
  local seed, keys = stage(tmp, {
    VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d1", VERDICTS_RESTORED = "verdicts-leg-h-f-d0",
    COMPILES_PREFIX = "compiles-leg-", COMPILES_DIGEST = "e1", COMPILES_RESTORED = "",
  }, true)
  assert(keys == "verdicts=verdicts-leg-h-f-d1\ncompiles=compiles-leg-e1\n" ..
      "driver-checked=driver-checked-v2-leg-x\n", keys)
  assert(Fs.read(seed .. "/verdicts/verdicts.db") == "v" and Fs.read(seed .. "/build-cache/cache.db") == "c")
  assert(Fs.read(seed .. "/driver-checked/key") == "driver-checked-v2-leg-x\n")

  seed, keys = stage(tmp, {
    VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d0", VERDICTS_RESTORED = "verdicts-leg-h-f-d0",
    COMPILES_PREFIX = "compiles-leg-", COMPILES_DIGEST = "",
  }, false)
  assert(keys == "", keys)
  assert(not Fs.exists(seed .. "/verdicts") and not Fs.exists(seed .. "/build-cache") and
      not Fs.exists(seed .. "/driver-checked"))

  -- A job that keeps no compiles (ci.yml's `checked`) names none.
  seed, keys = stage(tmp, {
    VERDICTS_PREFIX = "verdicts-leg-checked-h-f-", VERDICTS_DIGEST = "d2", VERDICTS_RESTORED = "",
  }, false)
  assert(keys == "verdicts=verdicts-leg-checked-h-f-d2\n", keys)
  assert(Fs.read(seed .. "/verdicts/verdicts.db") == "v" and not Fs.exists(seed .. "/build-cache"))
end

--- The verdicts are kept under the commit too (`verdicts-sha`), the key
--- main's push saves them under for a branch based on it. That copy is
--- kept even where their digest names the entry the run restored, which
--- main saves under no key of its own; a run whose trim named no digest
--- keeps none.
local function test_stage_keeps_the_verdicts_under_the_commit(tmp: string)
  local seed, keys = stage(tmp, {
    VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d0", VERDICTS_RESTORED = "verdicts-leg-h-f-d0",
    SHA = SHA,
  }, false)
  assert(keys == "verdicts-sha=verdicts-leg-h-f-sha-" .. SHA .. "\n", keys)
  assert(Fs.read(seed .. "/verdicts/verdicts.db") == "v")

  seed, keys = stage(tmp, {
    VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d1", VERDICTS_RESTORED = "verdicts-leg-h-f-d0",
    SHA = SHA,
  }, true)
  assert(keys == "verdicts=verdicts-leg-h-f-d1\nverdicts-sha=verdicts-leg-h-f-sha-" .. SHA ..
      "\ndriver-checked=driver-checked-v2-leg-x\n", keys)
  assert(Fs.read(seed .. "/verdicts/verdicts.db") == "v")

  seed, keys = stage(tmp, { VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "", SHA = SHA }, false)
  assert(keys == "" and not Fs.exists(seed .. "/verdicts"), keys)
end

local ZIG <const> = "zig-build-leg-v1-"
local CORE <const> = ZIG .. "full-c1-"

--- The tar `stage` kept the zig build outputs in, beside the seed in an
--- artifact of their own.
local function zig_tar(seed: string): string
  return seed .. "-zig/zig-build.tar"
end

--- The program the tar `stage` kept the zig build outputs in lays out,
--- under `dir`.
local function unpacked(seed: string, dir: string): string
  assert(Fs.mkdirs(dir))
  local result = assert(Child.run({ "/bin/sh", "-c", 'tar -xf "$1" -C "$2"', "sh", zig_tar(seed), dir },
    { stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) }))
  assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
  return dir .. "/zig-build/zig-project/o/abc/build"
end

--- The zig build outputs are kept, with their modes, under the key the
--- run's restore named, where it restored no entry of this core and
--- vendor part: another core's, another vendor part's, or none. The
--- prefix of such an entry goes with them, for main's lookup.
local function test_stage_keeps_the_zig_build_outputs_of_a_new_core(tmp: string)
  for i, restored in ipairs({ ZIG .. "full-c0-8-1", ZIG .. "light-c1-8-1", "zig-build-leg-v0-full-c1-8-1", "" }) do
    local seed, keys = stage(tmp, { ZIG_BUILD_KEY = CORE .. "9-1", ZIG_BUILD_EXACT = CORE,
      ZIG_BUILD_RESTORED = restored }, false)
    assert(keys == "zig-build=" .. CORE .. "9-1\nzig-build-exact=" .. CORE .. "\n", restored .. ": " .. keys)
    assert(not Fs.exists(seed .. "/zig-build.tar"), "the zig build outputs are kept in the seed itself")
    local program = unpacked(seed, tmp .. "/unpacked-" .. i)
    assert(Fs.read(program) == "z" and assert(Fs.stat(program)).mode & 0x1ff == 493,
      restored .. ": the zig build outputs lost a file or its mode")
  end
end

--- An entry of this core and vendor part restored answers already, so
--- nothing of zig's is kept; nor where the job names no key (the
--- checked job).
local function test_stage_keeps_no_zig_build_outputs_an_entry_holds(tmp: string)
  local seed, keys = stage(tmp, { ZIG_BUILD_KEY = CORE .. "9-1", ZIG_BUILD_EXACT = CORE,
    ZIG_BUILD_RESTORED = CORE .. "8-1" }, false)
  assert(keys == "" and not Fs.exists(zig_tar(seed)), keys)
  seed, keys = stage(tmp, { VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d2" }, false)
  assert(keys == "verdicts=verdicts-leg-h-f-d2\n" and not Fs.exists(zig_tar(seed)), keys)
end

--- A tar that fails keeps none of zig's and names no key for it, and
--- the stage goes on to keep the rest: the outputs save only time.
local function test_a_failing_zig_tar_keeps_the_rest(tmp: string)
  local bin = tmp .. "/failing-tar"
  assert(Fs.mkdirs(bin))
  assert(Fs.write(bin .. "/tar", "#!/bin/sh\necho partial > \"$2\"\nexit 1\n"))
  assert(Fs.chmod(bin .. "/tar", 493))
  local seed, keys = stage(tmp, {
    PATH = bin .. ":" .. (Env.get("PATH") or "/usr/bin:/bin"),
    VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d1", VERDICTS_RESTORED = "",
    ZIG_BUILD_KEY = CORE .. "9-1", ZIG_BUILD_EXACT = CORE, ZIG_BUILD_RESTORED = "",
  }, true)
  assert(keys == "verdicts=verdicts-leg-h-f-d1\ndriver-checked=driver-checked-v2-leg-x\n", keys)
  assert(not Fs.exists(zig_tar(seed)), "a failed tar is kept")
  assert(Fs.read(seed .. "/verdicts/verdicts.db") == "v")
end

--- ci.yml, decoded.
local function workflow(): {string: {string: any}}
  local text = assert(Fs.read(".github/workflows/ci.yml"))
  return (assert(Json.decode_object(text, { json5 = true, hash_comments = true }))) as {string: {string: any}}
end

--- The step of `steps` whose `id` is `id`, or whose `run` holds `text`.
local function step_of(steps: {{string: any}}, id?: string, text?: string): {string: any}
  for _, step in ipairs(steps) do
    local script = step.run
    if (id ~= nil and step.id == id) or
        (text ~= nil and script is string and script:find(text, 1, true) ~= nil) then
      return step
    end
  end
  error("no step " .. tostring(id or text))
end

local HEX64 <const> = "95301174f75ffeb84a42bb8a48da9110e55de69d2379ca686f538663fe25529d"

--- Whether leg `leg` runs in a container (its matrix `image`), in ci.yml's
--- platform matrix: an entry of its name, else the entry that names
--- none (alpine-x86_64's, which adds to every leg).
local function in_container(leg: string): boolean
  local platform = (workflow().jobs as {string: {string: any}}).platform
  local image: string
  for _, entry in ipairs(((platform.strategy as {string: any}).matrix as {string: any}).include as {{string: any}}) do
    if entry.name == leg then return (entry.image as string) ~= "" end
    if entry.name == nil then image = entry.image as string end
  end
  assert(image ~= nil, "no platform leg " .. leg)
  return image ~= ""
end

--- Each runner image a leg's run names, `<ImageOS>-<ImageVersion>` as
--- ci.yml's "name the zig build cache" step writes it: linux-aarch64's
--- as run 36730873187 named it (ImageOS ubuntu24-arm64, whose `-` the
--- seed's key read once refused), the others in the runners' shapes.
local IMAGES <const>: {string: string} = {
  ["linux-x86_64"] = "ubuntu24-20260920.130.1",
  ["linux-aarch64"] = "ubuntu24-arm64-20260920.129.1",
  ["macos-aarch64"] = "macos15-20260915.0138",
  ["alpine-x86_64"] = "ubuntu24-20260920.130.1",
}

--- `template` with each `${{ ... }}` in it the value a run of leg `leg`
--- gives it, in the shape the step that writes it writes: hashFiles
--- a sha256, a digest one too, a restore's matched key none (nothing
--- restored, so everything is kept). An expression it does not know
--- fails, so a key built of something new is read here first.
local function expand(template: string, leg: string, steps: {{string: any}}): string
  local host = "verdicts-" .. leg .. "-3a9f8d7b94f5492e-"
  local values: {string: string} = {
    ["matrix.name"] = leg,
    ["github.sha"] = SHA,
    ["github.run_id"] = "36730873187",
    ["github.run_attempt"] = "1",
    ["steps.host-id.outputs.prefix"] = host,
    ["steps.host-id.outputs.verdicts"] = host .. "bfd3e88dc72aaf8f-",
    ["steps.names.outputs.image"] = IMAGES[leg],
    ["steps.names.outputs.vendor"] = "zig-build-" .. leg .. "-" .. HEX64 .. "-",
    ["steps.names.outputs.core"] = HEX64,
    ["steps.verdicts-trim.outputs.digest"] = HEX64,
    ["steps.compiles-trim.outputs.digest"] = HEX64,
    ["steps.verdicts-restore.outputs.cache-matched-key"] = "",
    ["steps.compiles-restore.outputs.cache-matched-key"] = "",
    ["steps.zig-cache-restore.outputs.cache-matched-key"] = "",
  }
  return (template:gsub("%${{ (.-) }}", function(expression: string): string
    if expression:match("^hashFiles%(") then return HEX64 end
    if expression == "matrix.image && 'container' || steps.names.outputs.image" then
      return in_container(leg) and "container" or IMAGES[leg]
    end
    if expression == "steps.zig-cache-restore.outputs.cache-primary-key" then
      return expand((step_of(steps, "zig-cache-restore").with as {string: string}).key, leg, steps)
    end
    local value = values[expression]
    assert(value ~= nil, "a key holds an expression the test gives no value: " .. expression)
    return value
  end))
end

--- Runs the `seed` job (of `ci`, ci.yml's jobs)'s key read for leg `leg`
--- over `keys` (a seed.keys), and answers what it wrote to
--- $GITHUB_OUTPUT.
local function read_keys(tmp: string, ci: {string: {string: any}}, leg: string, keys: string): string
  runs = runs + 1
  local dir = tmp .. "/read-" .. runs
  assert(Fs.mkdirs(dir))
  assert(Fs.write(dir .. "/seed.keys", keys))
  assert(Fs.write(dir .. "/output", ""))
  local seed = ci.seed
  local script = step_of(seed.steps as {{string: any}}, "keys").run as string
  script = script:gsub("%${{ matrix%.name }}", leg):gsub("%${{ github%.sha }}", SHA)
  assert(not script:find("${{", 1, true), "the key read holds an expression the test gives no value: " .. script)
  local result = assert(Child.run({ "/bin/sh", "-e", "-c", script }, {
    env = { PATH = Env.get("PATH") or "/usr/bin:/bin", RUNNER_TEMP = dir, GITHUB_OUTPUT = dir .. "/output" },
    cwd = dir, stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) }))
  assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
  return Fs.read(dir .. "/output") or ""
end

--- Every key a leg's `stage` names, run as ci.yml runs it on that leg
--- (its env, and the driver check's marker under the key ci.yml builds
--- for it), `seed` reads back on that leg's own runner, and no other
--- leg's: linux-aarch64's driver marker, whose image holds a third
--- `-`-joined part, was once dropped, so each of its queue legs ran the
--- driver check again.
local function test_seed_reads_every_key_each_leg_stages(tmp: string)
  local ci = workflow().jobs as {string: {string: any}}
  local platform, checked = ci.platform, ci.checked
  local platform_steps = platform.steps as {{string: any}}
  local checked_steps = checked.steps as {{string: any}}
  local legs = ((ci.seed.strategy as {string: any}).matrix as {string: any}).include as {{string: any}}
  local staged: {string: string} = {}
  for _, leg in ipairs(legs) do
    local name = leg.name as string
    local steps = leg.checked and checked_steps or platform_steps
    local env: {string: string} = {}
    for key, template in pairs(step_of(steps, nil, "queue-seed.sh stage").env as {string: string}) do
      env[key] = expand(template, name, steps)
    end
    local marker: string
    if not leg.checked then
      marker = expand((step_of(steps, "driver-check-restore").with as {string: string}).key, name, steps)
      -- A container leg's marker names its container (in the host's
      -- prefix), not the runner's image, which a mixed fleet varies;
      -- macOS's, on the runner's own userland, names the image.
      if in_container(name) then
        assert(marker:find("-container-verdicts-" .. name .. "-", 1, true) and
            not marker:find(IMAGES[name], 1, true), marker)
      else
        assert(marker:find("-" .. IMAGES[name] .. "-verdicts-" .. name .. "-", 1, true), marker)
      end
    end
    local _, keys = stage(tmp, env, marker ~= nil, marker)
    -- Each cache the leg saves is named: the verdicts twice, and where
    -- the leg is a platform one its compiles, zig outputs and marker.
    local _, count = keys:gsub("\n", "")
    assert(count == (leg.checked and 2 or 6), name .. ": " .. keys)
    local read = read_keys(tmp, ci, name, keys)
    assert(read == keys, name .. " reads back only some of its keys:\n" .. keys .. "read:\n" .. read)
    staged[name] = keys
  end
  -- A leg reads none of another's, nor of one whose name begins its own.
  for name, keys in pairs(staged) do
    for other in pairs(staged) do
      if other ~= name then
        local read = read_keys(tmp, ci, other, keys)
        assert(read == "", other .. " reads " .. name .. "'s keys: " .. read)
      end
    end
  end
end
