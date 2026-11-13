--- A boot from a core a release already carries, with no zig: what
--- [`bin/zig`] tries first for `bin/zig build boot`, run standalone on the
--- bootstrap cosmic as build/zig.tl runs build/patch.tl.
---
---     cosmic --standalone build/seeded_boot.tl <root> <output> <patched manifest>
---     cosmic --standalone build/seeded_boot.tl --core
---
--- A core is a function of the C it is built from and of nothing else of
--- the tree, and a release's core is the bytes zig builds here from the
--- same C. So where the tree's C is the C of a release this host has, or
--- can fetch, the boot takes that release's core for the host and runs
--- the bridge on it ([`build/boot.tl`]'s `--stage` and `--assemble`), as
--- build.zig does once zig has built one. The fetch of zig and every
--- compile of C are skipped: 108 s of a cold boot's 237 s on a four-core
--- host.
---
--- The releases tried, in order:
---
--- - the one ci/cosmic-driver.pin names, which runs this script: its core
---   is the one this process runs on, and its commit the pin's first line;
--- - the newest release of the repository, by its tag
---   (`<date>-<commit>`): its `cosmic` is fetched once, held to the digest
---   its SHA256SUMS names, and kept beside the bootstrap cosmic.
---
--- Whether the tree's C is a release's is git's answer: the files the
--- release's commit holds under `c_inputs` are the files the index holds
--- there, by mode and contents; the working tree is the index there; and
--- no file there is untracked. A commit the checkout lacks is fetched,
--- without its files, into a repository of this run's own: the checkout's
--- is read and never written. A tree that is no git checkout, a commit
--- that cannot be had, or C that differs, is no match, and [`bin/zig`]
--- builds the core.
---
--- A zig the caller names (COSMIC_ZIG, ZIG_LIB_DIR) or a bootstrap cosmic
--- standing in for the pinned one (COSMIC_BOOTSTRAP) is no match either:
--- the first asks for that zig's core, and the second's core is not the
--- pin's.
---
--- A release is trusted as the repository publishes it: nothing but its
--- own SHA256SUMS vouches for the newest one. COSMIC_BOOT_SEED=0 turns
--- this off, and `pin` keeps it to the pinned release, which
--- [`bin/cosmic-bootstrap`] holds to the pin's digest, and to the commits
--- the checkout has: it asks the network nothing. Any other value is
--- refused, and zig builds the core.
---
--- It answers 0 where the tree is booted, 4 where no release's core is
--- the tree's (the build directory as it was), and 1 where a boot it began
--- failed.

-- TODO: run the two checks of the core's C a zig boot runs (build.zig's
-- strnlen-check and environment-check) and install the host's
-- cosmic-unzstd, on a boot that takes a release's core: today it skips
-- them, the core being bytes CI ran them on, and a stub an earlier zig
-- boot installed stays as it was. It waits on the release carrying the
-- stub where a script can take it, as it carries the core.
-- TODO: notice a C file edited while the bridge runs, as
-- build/zig.tl's `watched_build` does for a zig boot: the match is asked
-- once, before the core is placed. It waits on `watched_build` taking a
-- step that is no zig command. `--core` prints the core this process runs on, which is how the
--- core of a fetched release is found: its launcher has extracted it by
--- then.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

local record SeededBoot
  listed: function(text: string): string
  mut c_inputs: {string}
  mut vendored: {string}
  mut records: string
end

--- What a core's bytes are built from, as paths of the tree: the core's
--- own sources (but its Teal, which `listed` leaves out), the build script
--- and the zig it names, the vendored trees, and the patch records and
--- what applies them.
SeededBoot.c_inputs = { "core", "build.zig", "build.zig.zon", "bin/zig.pin", "build/patch.tl", "patch",
  "vendor" }

--- The patched trees build.zig installs under the build directory's
--- `vendor/` (its `vendored` step), which the tree's own checks read.
SeededBoot.vendored = { "lua", "sqlite", "miniz", "mbedtls", "bzip2", "xz", "cares", "curl", "yyjson",
  "sqlite-ext", "zstd", "expat" }

--- The release targets as build.zig's `targetRecord` writes them, which
--- the bridge reads ([`build/boot.tl`]). build/seeded_boot_test.tl holds
--- this to build.zig's `targets`.
SeededBoot.records = "1\t1\trelease\tx86_64-linux-musl\tLinux\tx86_64\n" ..
  "2\t1\trelease\taarch64-linux-musl\tLinux\taarch64\n" ..
  "3\t1\trelease\taarch64-macos\tDarwin\tarm64\n"

local repository <const> = "cosmic-lua/cosmic"

local function say(text: string)
  local _, _ = Fs.put(Fs.stderr, "seeded boot: " .. text .. "\n")
end

--- The target of this host among `records`, or nil.
local function host_target(): string?
  local name, _ = sys.uname()
  if name == nil then return nil end
  for line in SeededBoot.records:gmatch("[^\n]+") do
    local target, os, arch = line:match("^%d+\t%d+\t[^\t]+\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
    if os == name.sysname and arch == name.machine then return target end
  end
  return nil
end

--- Runs git in the repository at `directory` with `words`, held to a
--- minute and never asking a person: its result, or nil where it cannot
--- start.
local function git(directory: string, words: {string}): Child.Result?
  local program, _ = Proc.find("git")
  if program == nil then return nil end
  local argv: mut {string} = { program, "-C", directory }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local env: mut {string:string} = {}
  for name, value in pairs(Env.all()) do env[name] = value end
  env["GIT_TERMINAL_PROMPT"] = "0"
  local result, _ = Child.run(argv, { env = env, stdout = "capture", stderr = "capture",
    timeout_ns = 60 * 1000000000 })
  return result
end

--- The files `text` lists, a line each of its mode, the name of its
--- contents and its path, sorted, whichever of git's two listings it is:
--- `ls-tree -r` (`<mode> blob <name>\t<path>`) or `ls-files -s`
--- (`<mode> <name> <stage>\t<path>`). The core's Teal is left out: no
--- core is built from it.
function SeededBoot.listed(text: string): string
  local lines: mut {string} = {}
  for line in text:gmatch("[^\n]+") do
    local mode, name, path = line:match("^(%d+) blob (%x+)\t(.+)$")
    if mode == nil then mode, name, path = line:match("^(%d+) (%x+) %d+\t(.+)$") end
    if mode ~= nil and name ~= nil and path ~= nil and
        not (path:sub(1, 5) == "core/" and path:sub(-3) == ".tl") then
      lines[#lines + 1] = mode .. " " .. name .. " " .. path
    end
  end
  table.sort(lines)
  return table.concat(lines, "\n")
end

--- `words` with each of `c_inputs` after them.
local function over_c(words: {string}): {string}
  local out: mut {string} = {}
  for _, word in ipairs(words) do out[#out + 1] = word end
  out[#out + 1] = "--"
  for _, path in ipairs(SeededBoot.c_inputs) do out[#out + 1] = path end
  return out
end

--- Whether the working tree at `root` holds the C of `commit`: "" where it
--- does, else why not. A commit the checkout lacks is fetched into a
--- repository under `work`, unless `offline`.
local function same_c(root: string, commit: string, work: string, offline: boolean): string
  local short = commit:sub(1, 12)
  local have = git(root, { "cat-file", "-e", commit .. "^{commit}" })
  if have == nil then return "git does not start, or the tree is no checkout" end
  local from = root
  if not have.ok then
    if offline then return "the checkout has no commit " .. short end
    from = work .. "/release.git"
    local made = git(work, { "init", "--quiet", "--bare", from })
    local fetched = if made ~= nil and made.ok then
      git(from, { "fetch", "--quiet", "--depth", "1", "--filter=blob:none",
        "https://github.com/" .. repository, commit }) else nil end
    if fetched == nil or not fetched.ok then
      return "the commit " .. short .. " cannot be fetched"
    end
  end
  local theirs = git(from, over_c({ "ls-tree", "-r", commit }))
  local ours = git(root, over_c({ "ls-files", "-s" }))
  if theirs == nil or not theirs.ok or ours == nil or not ours.ok then
    return "git cannot list the C"
  end
  local wanted = SeededBoot.listed(theirs.stdout or "")
  if wanted == "" or wanted ~= SeededBoot.listed(ours.stdout or "") then
    return "its C differs from " .. short .. "'s"
  end
  local edited = git(root, over_c({ "diff", "--quiet" }))
  if edited == nil or edited.code ~= 0 then return "its C is edited and not staged" end
  local others = git(root, over_c({ "ls-files", "--others" }))
  if others == nil or not others.ok then return "git cannot list the C" end
  for path in (others.stdout or ""):gmatch("[^\n]+") do
    if not (path:sub(1, 5) == "core/" and path:sub(-3) == ".tl") then
      return "it holds a C file git does not track: " .. path
    end
  end
  return ""
end

--- The core this process runs on, where it was started from a portable
--- artifact ([`Proc.relaunch`]).
local function own_core(): string?
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return nil end
  return relaunch.argv[1]
end

--- The newest release of the repository whose tag is `<date>-<commit>`:
--- the tag and the commit, or nil and why none can be named.
local function newest_release(work: string): string?, string
  local listing = work .. "/releases.json"
  local got = Http.download_result("https://api.github.com/repos/" .. repository .. "/releases?per_page=20",
    listing, { roots = "mozilla", timeout_ns = 30 * 1000000000 })
  if got.kind ~= "downloaded" then return nil, "the releases cannot be listed: " .. got.reason end
  local text, trouble = Fs.read(listing)
  if text == nil then return nil, trouble end
  local newest: string? = nil
  for tag in text:gmatch('"tag_name"%s*:%s*"(%d%d%d%d%d%d%d%d%-%x+)"') do
    -- The listing is newest first, which settles two of one day.
    if newest == nil or tag:sub(1, 8) > newest:sub(1, 8) then newest = tag end
  end
  if newest == nil then return nil, "no release is tagged <date>-<commit>" end
  return newest, ""
end

--- The `cosmic` of the release tagged `tag`, fetched where it is not kept
--- yet: its path beside the bootstrap cosmic, named by its digest as that
--- is, or nil and why.
local function release_cosmic(tag: string, work: string): string?, string
  local base = "https://github.com/" .. repository .. "/releases/download/" .. tag .. "/"
  local sums = work .. "/SHA256SUMS"
  local listed = Http.download_result(base .. "SHA256SUMS", sums, { roots = "mozilla", timeout_ns = 30 * 1000000000 })
  if listed.kind ~= "downloaded" then return nil, "its SHA256SUMS: " .. listed.reason end
  local text, _ = Fs.read(sums)
  local digest = (text or ""):match("^(%x+)%s+cosmic\n")
  if digest == nil or #digest ~= 64 then return nil, "its SHA256SUMS names no cosmic" end
  local cache, cache_trouble = Fs.cache_dir("bootstrap")
  if cache == nil then return nil, cache_trouble end
  local path = cache .. "/cosmic-" .. digest
  local there, _ = Fs.exists(path)
  if there == true then return path, "" end
  local part = path .. ".part." .. tostring(Proc.pid())
  local fetched = Http.download_result(base .. "cosmic", part,
    { roots = "mozilla", timeout_ns = 300 * 1000000000, sha256 = digest })
  if fetched.kind ~= "downloaded" then
    local _, _ = Fs.remove(part)
    return nil, "its cosmic: " .. fetched.reason
  end
  local made, mode_trouble = Fs.chmod(part, 0x1ed)
  local placed, place_trouble = false, mode_trouble
  if made then placed, place_trouble = Fs.rename(part, path) end
  if not placed then
    local _, _ = Fs.remove(part)
    return nil, place_trouble
  end
  return path, ""
end

--- The core the cosmic at `program` runs on, which it says of itself
--- (`--core`), its launcher having extracted it.
local function core_of(program: string, script: string, work: string): string?, string
  local result, trouble = Child.run({ program, "--standalone", script, "--core" },
    { cwd = work, stdout = "capture", stderr = "capture" })
  if result == nil then return nil, trouble end
  local core = (result.stdout or ""):match("^(/[^\n]+)\n")
  if not result.ok or core == nil then return nil, "it names no core: " .. (result.stderr or "") end
  return core, ""
end

--- A release's core, and what to call the release.
local record Match
  core: string
  named: string
end

--- A release whose core is the tree's, or nil and why none is.
local function matching_core(root: string, script: string, work: string, mode: string): Match?, string
  local pin, _ = Fs.read(root .. "/ci/cosmic-driver.pin")
  local pinned = (pin or ""):match("^(%x+)\n")
  local why = "no release is pinned"
  local core = own_core()
  if pinned ~= nil and core ~= nil then
    why = same_c(root, pinned, work, mode == "pin")
    if why == "" then
      return { core = core, named = "the pinned release " .. pinned:sub(1, 12) }, ""
    end
  end
  if mode == "pin" then return nil, why end
  local tag, tag_trouble = newest_release(work)
  if tag == nil then return nil, tag_trouble end
  local commit = tag:match("^%d+%-(%x+)$") or ""
  if commit == pinned then return nil, why end
  why = same_c(root, commit, work, false)
  if why ~= "" then return nil, why end
  local program, program_trouble = release_cosmic(tag, work)
  if program == nil then return nil, "the release " .. tag .. ": " .. program_trouble end
  local found, found_trouble = core_of(program, script, work)
  if found == nil then return nil, "the release " .. tag .. ": " .. found_trouble end
  return { core = found, named = "the release " .. tag }, ""
end

--- Copies the file at `from` to `to`, runnable.
local function place(from: string, to: string): boolean, string
  local data, trouble = Fs.read(from)
  if data == nil then return false, trouble end
  local aside = to .. ".part." .. tostring(Proc.pid())
  local written, write_trouble = Fs.write(aside, data)
  if not written then return false, write_trouble end
  local made, mode_trouble = Fs.chmod(aside, 0x1ed)
  if not made then return false, mode_trouble end
  return Fs.rename(aside, to)
end

--- Installs the patched trees `manifest` names under `output`'s `vendor/`,
--- as build.zig's `vendored` step does.
local function install_vendor(manifest: string, output: string): boolean, string
  local text, trouble = Fs.read(manifest)
  if text == nil then return false, trouble end
  local places: mut {string:string} = {}
  for name, directory in text:gmatch("([^\t\n]+)\t([^\n]+)\n") do places[name] = directory end
  for _, name in ipairs(SeededBoot.vendored) do
    local from = places[name]
    if from == nil then return false, "the patched trees' manifest names no " .. name end
    local to = output .. "/vendor/" .. name
    local _, _ = Fs.remove_tree(to)
    local made, make_trouble = Fs.mkdirs(output .. "/vendor")
    if not made then return false, make_trouble end
    local copied, copy_trouble = Fs.copy_tree(from, to)
    if not copied then return false, to .. ": " .. copy_trouble end
  end
  return true, ""
end

--- Compiles the seed's files with this cosmic, as build.zig's
--- `seedCompiler` does, into `into`.
local function compile_seed(root: string, into: string): boolean, string
  local listing, trouble = Fs.read(root .. "/build/seed.txt")
  if listing == nil then return false, trouble end
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return false, "this cosmic has no artifact to start again" end
  local argv: mut {string} = {}
  for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
  argv[#argv + 1] = "compile"
  argv[#argv + 1] = "-o"
  argv[#argv + 1] = into
  for name in listing:gmatch("[^\n]+") do argv[#argv + 1] = name end
  local env: mut {string:string} = {}
  for name, value in pairs(Env.all()) do env[name] = value end
  for name, value in pairs(relaunch.env) do env[name] = value end
  local result, run_trouble = Child.run(argv, { cwd = root, env = env, fds = relaunch.fds,
    stdout = "capture", stderr = "capture" })
  if result == nil then return false, run_trouble end
  if not result.ok then
    return false, "the seed did not compile: " .. (result.stderr or "") .. (result.stdout or "")
  end
  return true, ""
end

--- Boots the tree at `root` into `output` on `core`: false and why where a
--- step fails.
local function boot(root: string, output: string, manifest: string, core: string, target: string,
                    work: string): boolean, string
  local seed = work .. "/seed"
  local compiled, compile_trouble = compile_seed(root, seed)
  if not compiled then return false, compile_trouble end
  local records = work .. "/targets.tsv"
  local wrote, write_trouble = Fs.write(records, SeededBoot.records)
  if not wrote then return false, write_trouble end
  local installed, install_trouble = install_vendor(manifest, output)
  if not installed then return false, install_trouble end
  local directory = output .. "/core/" .. target
  local made, make_trouble = Fs.mkdirs(directory)
  if not made then return false, make_trouble end
  local own = directory .. "/cosmic-core"
  local placed, place_trouble = place(core, own)
  if not placed then return false, place_trouble end
  for _, mode in ipairs({ "--stage", "--assemble" }) do
    local result, trouble = Child.run({ own, "--boot", root, seed, "--host-only", mode, target, records, output },
      { cwd = root })
    if result == nil then return false, trouble end
    if not result.ok then
      return false, "the bridge's " .. mode .. " ended with " .. tostring(result.code)
    end
  end
  return true, ""
end

function SeededBoot.main(argv: {string}): integer
  if argv[1] == "--core" then
    local core = own_core()
    if core == nil then return 1 end
    local _, _ = Fs.put(Fs.stdout, core .. "\n")
    return 0
  end
  local root, output, manifest = argv[1], argv[2], argv[3]
  if root == nil or output == nil or manifest == nil then
    say("usage: build/seeded_boot.tl <root> <output> <patched manifest>")
    return 2
  end
  local mode = Env.get("COSMIC_BOOT_SEED") or ""
  if mode == "0" then return 4 end
  if mode ~= "" and mode ~= "pin" then
    say("COSMIC_BOOT_SEED is " .. mode .. ": set it to 0 or pin, or leave it unset; building the core with zig")
    return 4
  end
  for _, name in ipairs({ "COSMIC_BOOTSTRAP", "COSMIC_ZIG", "ZIG_LIB_DIR" }) do
    if (Env.get(name) or "") ~= "" then return 4 end
  end
  local target = host_target()
  if target == nil then
    say("no release carries a core for this host")
    return 4
  end
  local work, work_trouble = Fs.mkdtemp("cosmic-seeded-boot-")
  if work == nil then
    say(work_trouble)
    return 4
  end
  local found, why = matching_core(root, root .. "/build/seeded_boot.tl", work, mode)
  local status = 4
  if found == nil then
    say("no release's core is this tree's (" .. why .. "); building it with zig")
  else
    say("the tree's C is that of " .. found.named .. ": taking its core, with no zig")
    local booted, trouble = boot(root, output, manifest, found.core, target, work)
    status = if booted then 0 else 1 end
    if not booted then say(trouble .. "; building with zig") end
  end
  local _, _ = Fs.remove_tree(work)
  return status
end

return SeededBoot
