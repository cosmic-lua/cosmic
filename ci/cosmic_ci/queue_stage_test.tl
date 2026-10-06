--- `driver.tl queue-stage`, which keeps in a merge queue run's leg what
--- main would have saved, under the keys it would have saved it under:
--- the copies and keys, the zig build outputs' tar and the `seed` job's
--- read of the keys, which ci.yml holds and this reads as it stands.
local Archive = require("cosmic.archive")
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local QueueStage = require("cosmic_ci.queue_stage")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

local SHA <const> = "0123456789abcdef0123456789abcdef01234567"

local runs = 0

--- A [`QueueStage.Host`] that keeps what it is told, and archives with
--- `archive`, the real one unless the test gives another.
local record Fake
  host: QueueStage.Host
  printed: {string}
  warned: {string}
end

local function fake(archive?: function(parent: string, name: string, to: string): boolean, string): Fake
  local f: Fake = { printed = {}, warned = {} }
  f.host = {
    print = function(text: string) f.printed[#f.printed + 1] = text end,
    warn = function(line: string) f.warned[#f.warned + 1] = line end,
    archive = archive or QueueStage.archive_tree,
  }
  return f
end

--- What `stage` keeps under $RUNNER_TEMP/seed, run with `env` and, where
--- `marker`, a passing driver check's marker (holding `marker_key`, or
--- a key of no shape), and its seed.keys. The zig build outputs hold a
--- program, whose mode their seed keeps.
local function stage(tmp: string, env: {string: string}, marker: boolean, marker_key?: string,
                     archive?: function(parent: string, name: string, to: string): boolean, string): string, string, Fake
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
  local full: {string: string} = { RUNNER_TEMP = temp }
  for name, value in pairs(env) do full[name] = value end
  local f = fake(archive)
  local code = QueueStage.stage(full, f.host)
  assert(code == 0, table.concat(f.warned, "\n"))
  local keys = assert(Fs.read(temp .. "/seed/seed.keys"))
  assert(table.concat(f.printed) == keys, "the keys printed are the keys written")
  return temp .. "/seed", keys, f
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

--- The tree of `root`, a line for each path below it: what it is, its
--- permission bits, and its bytes, link target or modification time.
local function tree(root: string): {string: string}
  local lines: {string: string} = {}
  local function visit(path: string, rel: string)
    local st = assert(sys.lstat(path))
    -- A directory's mode is read from the archive instead: the extractor
    -- makes every directory 0755.
    -- TODO: compare a directory's mode here once cosmic.archive's
    -- `extract` applies the mode a directory entry names.
    local what = st.kind .. (st.kind == "dir" and "" or string.format(" %o", st.mode & 0xfff))
    if st.kind == "file" then
      what = what .. " " .. assert(Fs.read(path)) .. string.format(" %d", st.mtime)
    elseif st.kind == "link" then
      what = what .. " -> " .. assert(Fs.readlink(path))
    elseif st.kind == "dir" then
      what = what .. string.format(" %d", st.mtime)
      for _, name in ipairs((assert(Fs.list(path)))) do
        visit(path .. "/" .. name, rel .. "/" .. name)
      end
    end
    lines[rel] = what
  end
  visit(root, "")
  return lines
end

--- `tar` laid out under `dir` by cosmic's own reader.
local function unpacked(tar: string, dir: string): string
  assert(Fs.mkdirs(dir))
  assert(Archive.extract(tar, dir, { links = "create" }))
  return dir .. "/zig-build"
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
    local program = unpacked(zig_tar(seed), tmp .. "/unpacked-" .. i) .. "/zig-project/o/abc/build"
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
--- the stage goes on to keep the rest: the outputs save only time. A
--- partial file the archiver left is removed, and the step says so.
local function test_a_failing_zig_tar_keeps_the_rest(tmp: string)
  local seed, keys, f = stage(tmp, {
    VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d1", VERDICTS_RESTORED = "",
    ZIG_BUILD_KEY = CORE .. "9-1", ZIG_BUILD_EXACT = CORE, ZIG_BUILD_RESTORED = "",
  }, true, nil, function(_parent: string, _name: string, to: string): boolean, string
    assert(Fs.write(to, "partial"))
    return false, "refused"
  end)
  assert(keys == "verdicts=verdicts-leg-h-f-d1\ndriver-checked=driver-checked-v2-leg-x\n", keys)
  assert(not Fs.exists(zig_tar(seed)), "a failed tar is kept")
  assert(Fs.read(seed .. "/verdicts/verdicts.db") == "v")
  assert(f.warned[#f.warned] == "warning: the zig build outputs could not be kept: none seeded",
    table.concat(f.warned, "\n"))
  assert(f.warned[1] == "queue-stage: refused", f.warned[1])
end

--- A tree holding what a zig cache holds, and more: a program, a
--- read-only file, an empty file and directory, a path and a link
--- target past a ustar name's 100 bytes, a link, and a mode on a
--- directory. Its tar, laid out again, is the tree it was, mode,
--- bytes, target and modification time for each path.
local function test_the_zig_tar_lays_out_the_tree_it_archived(tmp: string)
  local parent = tmp .. "/round"
  local root = parent .. "/zig-build"
  local deep = root .. "/" .. string.rep("d", 60) .. "/" .. string.rep("e", 60)
  assert(Fs.mkdirs(deep))
  assert(Fs.mkdirs(root .. "/empty"))
  assert(Fs.write(root .. "/program", "#!/bin/sh\n", 493))
  assert(Fs.chmod(root .. "/program", 493))
  assert(Fs.write(root .. "/readonly", "r"))
  assert(Fs.chmod(root .. "/readonly", 292))
  assert(Fs.write(root .. "/blank", ""))
  assert(Fs.write(deep .. "/" .. string.rep("f", 80), "far"))
  assert(Fs.write(root .. "/big", string.rep("0123456789abcdef", 100000)))
  assert(Fs.symlink("program", root .. "/link"))
  assert(Fs.symlink(string.rep("d", 60) .. "/" .. string.rep("e", 60) .. "/" .. string.rep("f", 80),
    root .. "/long-link"))
  assert(Fs.chmod(root .. "/empty", 0x1e8))
  for _, path in ipairs({ "program", "readonly", "blank", "big" }) do
    assert(Fs.set_mtime(root .. "/" .. path, 1700000000))
  end
  assert(QueueStage.archive_tree(parent, "zig-build", parent .. "/zig-build.tar"))
  local back = unpacked(parent .. "/zig-build.tar", tmp .. "/round-back")
  local was, now = tree(root), tree(back)
  for path, what in pairs(was) do
    assert(now[path] == what, path .. ": " .. what .. " / " .. tostring(now[path]))
  end
  for path in pairs(now) do assert(was[path] ~= nil, "extra " .. path) end
  local modes: {string: integer} = {}
  for _, member in ipairs((assert(Archive.list(parent .. "/zig-build.tar")))) do
    modes[member.path] = member.mode
  end
  assert(modes["zig-build/empty/"] == 0x1e8 and modes["zig-build/program"] == 493 and
      modes["zig-build/readonly"] == 292, "the archive holds another mode than the tree's")
end

--- A tree holding a device, a socket or a named pipe is refused, whole,
--- with its path, and leaves no file at the archive's path.
local function test_the_zig_tar_refuses_what_it_cannot_keep(tmp: string)
  local parent = tmp .. "/refuse"
  assert(Fs.mkdirs(parent .. "/zig-build"))
  assert(Fs.write(parent .. "/zig-build/file", "x"))
  local fifo = parent .. "/zig-build/pipe"
  assert(sys.mkfifo(fifo, 0x1a4))
  local ok, why = QueueStage.archive_tree(parent, "zig-build", parent .. "/zig-build.tar")
  assert(not ok and why:find("pipe", 1, true) ~= nil, why)
  assert(not Fs.exists(parent .. "/zig-build.tar"))
end

--- ci.yml, decoded.
local function workflow(): {string: {string: any}}
  local text = assert(Fs.read("../.github/workflows/ci.yml"))
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
    for key, template in pairs(step_of(steps, nil, "queue-stage").env as {string: string}) do
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
