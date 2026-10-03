local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local ZigPrune = require("cosmic_ci.zig_prune")

--- Manifests zig 0.17 wrote, each with the output it made: what a
--- manifest vouches for is zig's to say, so a hash read wrongly here
--- fails these rather than pruning what a build would hit.
local function test_a_manifest_vouches_for_the_output_zig_made()
  local cases: {{string}} = {
    -- A step that read no file.
    { "0e9f1edc8959b359682157069501abb6", "\x00", "89af20b2482bc6827ca7dbe2a5af4028" },
    -- A compile's analysis, of one file of the project cache.
    { "71f3cc44bf6c4ed887751ef3be920bd0",
      "\xd5.\x00\x00\x00\x00\x00\x00q\xc8\x09\x00\x00\x00\x00\x00Vz\x93\xda" ..
        "\x8d\xdf\xda\x18p\xd1\xf1\x93\xe2R\xc0\xd2\xdeZ\x1b\xbb\xa1*\xa6\x0a" ..
        "\x08cosmic-vendor/cares-f159dbcc3d49893fb5f9a28c6d4caee36f8d8a86f34072" ..
        "fd3ea7c308ebd2f5db/src/lib/ares_sysconfig_mac.c\x00\x00",
      "9f1d104adad6a05512d52bab36bb854a" },
    -- A run step, of two outputs of the cache's own.
    { "20846e46d0063433728d69b15ed4801d",
      "M\x8c\x12\x01\x00\x00\x00\x00f\x01\x0a\x00\x00\x00\x00\x00\xa50q<\xd7" ..
        "\xdf\xda\x18\x9a\xbe\xc5pd\x88HHG\xf9\x5cG t\xc5\xc2\x08o/04bbf2e4d047" ..
        "d5cadb88df8d955afa9f/coverage-map\x00\xf8B`\x00\x00\x00\x00\x00\x18" ..
        "\xa2\x0a\x00\x00\x00\x00\x00\xbc\x06\x97c\xef\xdf\xda\x18$I\xc5F\x9b^W" ..
        "\x89\xdb\xefX\xe3\xf9\x9d\x0b\xd7\x08o/4e24a4c3b4892d00b4f4b1f52e3b5ca" ..
        "d/cosmic-core\x00\x00",
      "60b2f3b2be10737eb5f6979227bf0540" },
  }
  for _, case in ipairs(cases) do
    local got, trouble = ZigPrune.vouches(case[1], case[2])
    assert(got == case[3], case[1] .. ": " .. tostring(got) .. " " .. trouble)
  end
  -- What is not zig's manifest vouches for nothing.
  assert(ZigPrune.vouches("timestamp", "\0") == nil)
  assert(ZigPrune.vouches("0e9f1edc8959b359682157069501abb6.txt", "0\n") == nil)
  assert(ZigPrune.vouches("0e9f1edc8959b359682157069501abb6", "") == nil)
  assert(ZigPrune.vouches("0e9f1edc8959b359682157069501abb6", "\0\0") == nil)
  assert(ZigPrune.vouches("0e9f1edc8959b359682157069501abb6", string.rep("\1", 41) .. "a") == nil)
  -- An input may be a prefix's own root, an empty path.
  assert(ZigPrune.vouches("0e9f1edc8959b359682157069501abb6",
    string.rep("\0", 40) .. "\8\0\0") ~= nil)
end

--- The known answers above are the pinned zig's: a new pin re-reads
--- std/Build/Cache.zig (its `hasher_init`, `checkProgressless`,
--- `finalDigest` and `Manifest.File`), takes new answers from a cache
--- it wrote, and moves [`ZigPrune.zig_version`].
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
  local records: {string} = {}
  for i, file in ipairs(files) do
    local prefix, path = file:match("^(%d+) (.*)$")
    records[#records + 1] = string.pack("<i8i8i8", 1, i, 1) ..
      Codec.unhex(string.rep(name:sub(-1), 32)) ..
      string.char(math.tointeger(prefix) << 2) .. path .. "\0"
  end
  local text = table.concat(records) .. "\0"
  assert(Fs.write(root .. "/h/" .. name, text))
  local output = assert(ZigPrune.vouches(name, text))
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
  local want_manifests = { p .. "/h/" .. hex("1"), p .. "/h/" .. hex("c") }
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

--- A compile built in the global cache (libc, its stubs) has that
--- cache for its local one too, so its manifest names the global
--- cache's files by prefix 2, as one in the project's names the
--- project's: a superseded output of the global cache goes with the
--- manifests that list it there. A manifest zig made and never wrote
--- (empty: a step that failed) vouches for nothing, and is no reason
--- to keep anything whole.
local function test_a_manifest_names_its_own_cache_by_prefix_2(tmp: string)
  local project = cache(tmp .. "/zig-cache")
  project.prefix = 2
  local shared = cache(tmp .. "/zig-global")
  shared.prefix = 3
  local p, g = project.path, shared.path
  local stubs = step(g, hex("a"), { "1 libc/stubs.zig" }, { "m.s" })
  local old_stubs = orphan(g, hex("9"), { "m.s" })
  local libm = step(g, hex("b"), { "2 o/" .. stubs .. "/m.s" }, { "libm.so" })
  local old_libm = step(g, hex("c"), { "2 o/" .. old_stubs .. "/m.s" }, { "libm.so" })
  assert(Fs.write(p .. "/h/" .. hex("d"), ""))

  local plan = assert(ZigPrune.plan({ project, shared }))
  assert(table.concat(plan.manifests, " ") == g .. "/h/" .. hex("c"),
    table.concat(plan.manifests, " "))
  local want_outputs = { g .. "/o/" .. old_stubs, g .. "/o/" .. old_libm }
  table.sort(want_outputs)
  assert(table.concat(plan.outputs, " ") == table.concat(want_outputs, " "),
    table.concat(plan.outputs, " "))
  assert(plan.manifests_seen == 3, tostring(plan.manifests_seen))
  assert(ZigPrune.apply(plan))
  for _, kept in ipairs({ g .. "/o/" .. stubs .. "/m.s", g .. "/o/" .. libm .. "/libm.so",
      p .. "/h/" .. hex("d") }) do
    assert(Fs.exists(kept), kept)
  end
end

--- `zig build`'s maker, built for each CPU model a cache meets, goes
--- with its manifest whatever the run, and what it is not alone in does
--- not.
local function test_the_maker_goes_with_its_manifest(tmp: string)
  local project = cache(tmp .. "/zig-cache")
  project.prefix = 2
  local shared = cache(tmp .. "/zig-global")
  shared.prefix = 3
  local g = shared.path
  local maker = step(g, hex("a"), { "1 compiler/Maker.zig" }, { "maker", "maker_zcu.o" })
  local other = step(g, hex("b"), { "1 compiler/Maker.zig" }, { "maker" })
  local libc = step(g, hex("c"), { "1 libc/musl/x.c" }, { "maker", "libc.a" })
  local plan = assert(ZigPrune.plan({ project, shared }))
  assert(table.concat(plan.manifests, " ") == g .. "/h/" .. hex("a") .. " " .. g .. "/h/" .. hex("b"),
    table.concat(plan.manifests, " "))
  local want = { g .. "/o/" .. maker, g .. "/o/" .. other }
  table.sort(want)
  assert(table.concat(plan.outputs, " ") == table.concat(want, " "), table.concat(plan.outputs, " "))
  assert(ZigPrune.apply(plan))
  assert(Fs.exists(g .. "/o/" .. libc .. "/libc.a") and Fs.exists(g .. "/h/" .. hex("c")))
end

--- `zig build`'s configuration is a file of the cache's `c/`, which its
--- manifest vouches for as a step's does its output, and goes with
--- that manifest.
local function test_a_configuration_goes_with_its_manifest(tmp: string)
  local project = cache(tmp .. "/zig-cache")
  project.prefix = 2
  local shared = cache(tmp .. "/zig-global")
  shared.prefix = 3
  local p = project.path
  local dependencies = step(p, hex("a"), {}, { "dependencies.zig" })
  local old_dependencies = orphan(p, hex("9"), { "dependencies.zig" })
  local configured = step(p, hex("b"), { "2 o/" .. dependencies .. "/dependencies.zig" }, {})
  local old_configured = step(p, hex("c"), { "2 o/" .. old_dependencies .. "/dependencies.zig" }, {})
  assert(Fs.mkdirs(p .. "/c"))
  for _, output in ipairs({ configured, old_configured }) do
    assert(Fs.remove_tree(p .. "/o/" .. output))
    assert(Fs.write(p .. "/c/" .. output, "configuration"))
  end

  local plan = assert(ZigPrune.plan({ project, shared }))
  assert(table.concat(plan.manifests, " ") == p .. "/h/" .. hex("c"),
    table.concat(plan.manifests, " "))
  local want_outputs = { p .. "/c/" .. old_configured, p .. "/o/" .. old_dependencies }
  table.sort(want_outputs)
  assert(table.concat(plan.outputs, " ") == table.concat(want_outputs, " "),
    table.concat(plan.outputs, " "))
  assert(plan.orphans == 1 and plan.orphans_kept == 0, plan.orphans .. " " .. plan.orphans_kept)
  assert(ZigPrune.apply(plan))
  for _, kept in ipairs({ p .. "/c/" .. configured, p .. "/h/" .. hex("b") }) do
    assert(Fs.exists(kept), kept)
  end
end

--- A cache restored from a build on an older zig holds its manifests
--- (`<name>.txt`), which this zig never reads: their outputs are
--- orphans here, and one superseded goes. Each such manifest goes too,
--- first, so that the older zig, restoring what is saved, misses
--- rather than trusting an output that is gone.
local function test_an_older_zigs_manifests_go_before_their_outputs(tmp: string)
  local project = cache(tmp .. "/zig-cache")
  project.prefix = 2
  local shared = cache(tmp .. "/zig-global")
  shared.prefix = 3
  local p = project.path
  local object = step(p, hex("a"), { "1 core/a.c" }, { "a.o" })
  local older_object = orphan(p, hex("9"), { "a.o" })
  local older = p .. "/h/" .. hex("e") .. ".txt"
  assert(Fs.write(older, "0\n1 1 1 " .. hex("e") .. " 2 o/" .. older_object .. "/a.o\n"))

  local plan = assert(ZigPrune.plan({ project, shared }))
  assert(table.concat(plan.manifests, " ") == older, table.concat(plan.manifests, " "))
  assert(table.concat(plan.outputs, " ") == p .. "/o/" .. older_object,
    table.concat(plan.outputs, " "))
  assert(plan.manifests_seen == 2, tostring(plan.manifests_seen))
  assert(ZigPrune.apply(plan))
  assert(not Fs.exists(older) and not Fs.exists(p .. "/o/" .. older_object))
  assert(Fs.exists(p .. "/o/" .. object .. "/a.o") and Fs.exists(p .. "/h/" .. hex("a")))
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
      assert(Fs.write(p .. "/h/" .. hex("f"), "\1"))
    else
      assert(Fs.write(p .. "/h/" .. hex("f"), "\0"))
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
