local Fs = require("cosmic.fs")
local ZigPrune = require("cosmic_ci.zig_prune")

--- Manifests zig 0.16 wrote, each with the output it made: what a
--- manifest vouches for is zig's to say, so a hash read wrongly here
--- fails these rather than pruning what a build would hit.
local function test_a_manifest_vouches_for_the_output_zig_made()
  local cases: {{string}} = {
    -- A step that read no file (build.zig's targets.tsv).
    { "3d3983ba1978c19c52224be5a1e6decc.txt", "0\n", "26ca864f5afd2cebb5d762f0976c4b93" },
    -- A compile's analysis, of one file of the tree.
    { "e84aa90f22106bea32784581fe6d112c.txt",
      "0\n9519 950868 1790826720911876459 ad42f989e48ea8a9847327fd320352b4 1 core/vfs.c\n",
      "1552f59e485ab27098b322a1a12a3c1f" },
    -- A run step, of two outputs of the cache's own.
    { "08c6f89275274ae49d5eda3093f55744.txt",
      "0\n18163170 2442127 1790826734263877252 5192d54871eb75cd3ffd2c584c32b9a6 2 " ..
      "o/6f91c2131f0673d6b7a02c50554e2aea/coverage-map\n" ..
      "38301664 615460 1790829018072013009 28371f4664bcd70c5042467d755207cd 2 " ..
      "o/27232b1d6a4f014c8396c1c7943e6afe/cosmic-core\n",
      "13c72f998ad0891ee60da6246619e1bb" },
  }
  for _, case in ipairs(cases) do
    local got, trouble = ZigPrune.vouches(case[1], case[2])
    assert(got == case[3], case[1] .. ": " .. tostring(got) .. " " .. trouble)
  end
  -- What is not zig's manifest vouches for nothing.
  assert(ZigPrune.vouches("timestamp", "0\n") == nil)
  assert(ZigPrune.vouches("3d3983ba1978c19c52224be5a1e6decc.txt", "1\n") == nil)
  assert(ZigPrune.vouches("3d3983ba1978c19c52224be5a1e6decc.txt", "0\nnot a file line\n") == nil)
end

--- The known answers above are the pinned zig's: a new pin re-reads
--- std/Build/Cache.zig (its `hasher_init`, `hit`, `final` and the
--- manifest's lines), takes new answers from a cache it wrote, and
--- moves [`ZigPrune.zig_version`].
local function test_the_answers_are_the_pinned_zigs()
  local cwd = assert(Fs.absolute("."))
  local root = assert(cwd:match("^(.*)/[^/]+$"), cwd)
  local pin = assert(Fs.read(root .. "/bin/zig.pin"))
  local version = pin:match("^version (%S+)")
  assert(version == ZigPrune.zig_version, "bin/zig.pin names zig " .. tostring(version) ..
    ", and cosmic_ci/zig_prune.tl reads " .. ZigPrune.zig_version .. "'s caches")
end

--- A cache under `root`, as zig lays one out, with no manifest yet.
local function cache(root: string): ZigPrune.Cache
  assert(Fs.mkdirs(root .. "/h"))
  assert(Fs.mkdirs(root .. "/o"))
  assert(Fs.write(root .. "/h/timestamp", ""))
  return { path = root, prefix = 0 }
end

--- A manifest named `name` (32 hex digits) in `root`, listing `files`
--- (each `<prefix> <path>`, every one given the digest `name` ends
--- in), with the output it vouches for holding `outputs`; the output's
--- name.
local function step(root: string, name: string, files: {string}, outputs: {string}): string
  local lines: {string} = { "0" }
  for i, file in ipairs(files) do
    lines[#lines + 1] = "1 " .. i .. " 1 " .. string.rep(name:sub(-1), 32) .. " " .. file
  end
  local text = table.concat(lines, "\n") .. "\n"
  assert(Fs.write(root .. "/h/" .. name .. ".txt", text))
  local output = assert(ZigPrune.vouches(name .. ".txt", text))
  for _, file in ipairs(outputs) do
    assert(Fs.mkdirs(Fs.dirname(root .. "/o/" .. output .. "/" .. file)))
    assert(Fs.write(root .. "/o/" .. output .. "/" .. file, name))
  end
  return output
end

--- An output no manifest vouches for, named `name`, holding `outputs`.
local function orphan(root: string, name: string, outputs: {string}): string
  for _, file in ipairs(outputs) do
    assert(Fs.mkdirs(Fs.dirname(root .. "/o/" .. name .. "/" .. file)))
    assert(Fs.write(root .. "/o/" .. name .. "/" .. file, name))
  end
  return name
end

local function hex(c: string): string return string.rep(c, 32) end

--- What a queue run leaves after a core change: the copies of the core
--- (a WriteFile step's output) vouched for anew, the old copies an
--- orphan, and the compile and link of each. The old core's compile
--- and link go, with their outputs; the new core's, the global cache's
--- libc they link, and the orphan zig writes with no manifest (the
--- build runner's dependencies.zig) stay, with the runner that lists
--- it.
local function test_a_core_change_prunes_the_old_core_alone(tmp: string)
  local project = cache(tmp .. "/zig-cache")
  project.prefix = 2
  local shared = cache(tmp .. "/zig-global")
  shared.prefix = 3
  local p, g = project.path, shared.path
  local libc = step(g, hex("e"), {}, { "libc.a" })
  local copies = step(p, hex("a"), { "1 core/a.c" }, { "core/a.c" })
  local old_copies = orphan(p, hex("9"), { "core/a.c" })
  local object = step(p, hex("b"), { "2 o/" .. copies .. "/core/a.c" }, { "a.o" })
  local old_object = step(p, hex("c"), { "2 o/" .. old_copies .. "/core/a.c" }, { "a.o" })
  local core = step(p, hex("d"), { "2 o/" .. object .. "/a.o", "3 o/" .. libc .. "/libc.a" },
    { "cosmic-core" })
  local old_core = step(p, hex("1"), { "2 o/" .. old_object .. "/a.o", "3 o/" .. libc .. "/libc.a" },
    { "cosmic-core" })
  local dependencies = orphan(p, hex("8"), { "dependencies.zig" })
  local runner = step(p, hex("2"), { "2 o/" .. dependencies .. "/dependencies.zig", "1 build.zig" },
    { "build" })

  local plan = assert(ZigPrune.plan({ project, shared }))
  local want_manifests = { p .. "/h/" .. hex("1") .. ".txt", p .. "/h/" .. hex("c") .. ".txt" }
  local want_outputs = { p .. "/o/" .. old_copies, p .. "/o/" .. old_object, p .. "/o/" .. old_core }
  table.sort(want_outputs)
  assert(table.concat(plan.manifests, " ") == table.concat(want_manifests, " "),
    table.concat(plan.manifests, " "))
  assert(table.concat(plan.outputs, " ") == table.concat(want_outputs, " "),
    table.concat(plan.outputs, " "))
  assert(plan.orphans == 2 and plan.orphans_kept == 1, plan.orphans .. " " .. plan.orphans_kept)
  assert(plan.manifests_seen == 7 and plan.outputs_seen == 9,
    plan.manifests_seen .. " " .. plan.outputs_seen)

  assert(ZigPrune.apply(plan))
  for _, gone in ipairs(want_outputs) do assert(not Fs.exists(gone), gone) end
  for _, gone in ipairs(want_manifests) do assert(not Fs.exists(gone), gone) end
  for _, kept in ipairs({ p .. "/o/" .. copies .. "/core/a.c", p .. "/o/" .. object .. "/a.o",
      p .. "/o/" .. core .. "/cosmic-core", p .. "/o/" .. dependencies .. "/dependencies.zig",
      p .. "/o/" .. runner .. "/build", g .. "/o/" .. libc .. "/libc.a", p .. "/h/timestamp" }) do
    assert(Fs.exists(kept), kept)
  end
  -- What is left is whole: a second look finds nothing more.
  local again = assert(ZigPrune.plan({ project, shared }))
  assert(#again.manifests == 0 and #again.outputs == 0)
end

--- A manifest not read as zig's, or one whose output is not there, says
--- the format is not the one this reads: nothing at all is removed,
--- though an old core is there to remove, and the command says why.
local function test_nothing_is_removed_where_a_manifest_is_not_understood(tmp: string)
  for _, broken in ipairs({ "header", "missing" }) do
    local root = tmp .. "/" .. broken
    local project = cache(root .. "/zig-cache")
    project.prefix = 2
    local shared = cache(root .. "/zig-global")
    shared.prefix = 3
    local p = project.path
    local old_copies = orphan(p, hex("9"), { "core/a.c" })
    step(p, hex("a"), { "1 core/a.c" }, { "core/a.c" })
    local old_object = step(p, hex("c"), { "2 o/" .. old_copies .. "/core/a.c" }, { "a.o" })
    if broken == "header" then
      assert(Fs.write(p .. "/h/" .. hex("f") .. ".txt", "1\n"))
    else
      assert(Fs.write(p .. "/h/" .. hex("f") .. ".txt", "0\n"))
    end
    local plan, trouble = ZigPrune.plan({ project, shared })
    assert(plan == nil and trouble:find(hex("f"), 1, true), trouble)
    local code, out, err = ZigPrune.command({ COSMIC_ZIG_CACHE_SEED = root,
      COSMIC_ZIG_GLOBAL_CACHE = shared.path })
    assert(code == 0 and out == "" and err:find("^zig%-prune: kept whole: "), err)
    assert(Fs.exists(p .. "/o/" .. old_copies) and Fs.exists(p .. "/o/" .. old_object))
  end
end

--- The command prunes the caches the driver's builds use (the
--- `zig-cache` under COSMIC_ZIG_CACHE_SEED, and COSMIC_ZIG_GLOBAL_CACHE)
--- and never fails: where neither is there it has nothing to do.
local function test_the_command_prunes_the_caches_the_builds_use(tmp: string)
  local code, out, err = ZigPrune.command({})
  assert(code == 0 and out:find("nothing to prune", 1, true) and err == "", out .. err)
  code, out, err = ZigPrune.command({ COSMIC_ZIG_CACHE_SEED = tmp .. "/absent",
    COSMIC_ZIG_GLOBAL_CACHE = tmp .. "/absent/zig-global" })
  assert(code == 0 and out:find("nothing to prune", 1, true) and err == "", out .. err)

  local project = cache(tmp .. "/seed/zig-cache")
  local shared = cache(tmp .. "/seed/zig-global")
  local p = project.path
  local old_copies = orphan(p, hex("9"), { "core/a.c" })
  step(p, hex("a"), { "1 core/a.c" }, { "core/a.c" })
  local old_object = step(p, hex("c"), { "2 o/" .. old_copies .. "/core/a.c" }, { "a.o" })
  code, out, err = ZigPrune.command({ COSMIC_ZIG_CACHE_SEED = tmp .. "/seed",
    COSMIC_ZIG_GLOBAL_CACHE = shared.path })
  assert(code == 0 and err == "", err)
  assert(out == "zig-prune: removed 1 manifest of 2 and 2 outputs of 3 (1 orphan, 0 kept)\n", out)
  assert(not Fs.exists(p .. "/o/" .. old_object) and not Fs.exists(p .. "/o/" .. old_copies))
end
