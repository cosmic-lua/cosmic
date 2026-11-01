--- Fetches, verifies and runs the one pinned zig: what [`bin/zig`] hands
--- off to once it has a bootstrap cosmic.
---
---     cosmic --standalone build/zig.tl [args...]
---
--- This file runs standalone, against the bootstrap binary's own
--- embedded standard library and never the tree it sits in, so it
--- requires `cosmic.*` modules only. It runs the output directory resolver
--- ([`build/paths.tl`]) the same way; before a build, [`build/patch.tl`],
--- which patches the vendored trees (`patch`); and, when the pinned zig is not installed yet,
--- [`build/zig_fetch.tl`], which fetches it; nothing else of the tree is
--- loaded. So a bootstrap older or newer than the tree, a core edit
--- nobody has booted yet, or a syntax error elsewhere in the tree cannot
--- stop zig from running, which is what rebuilds all of those. A syntax
--- error in one of those files can.
---
--- The pin is [`bin/zig.pin`]: a `version` line, then one line per host
--- naming that host's release tarball's sha256. `COSMIC_ZIG` names an
--- already-installed zig and skips all of this; a name without a slash
--- is looked up on `PATH`, as a shell would.
---
--- Otherwise the release is cached at
--- `$XDG_CACHE_HOME/cosmic/zig/<version>-<host>-<sha>` (default
--- `$HOME/.cache/cosmic/zig/...`, and no fallback when neither is set;
--- see [`Fs.cache_dir`], which also refuses a cache directory someone else
--- could write to). `<sha>` is the first 16 hex digits of the host's
--- sha256 ([`Zig.install_name`]). If `<install>/zig` is already there it
--- is used as is. Otherwise [`build/zig_fetch.tl`], run standalone as
--- `patch` is, downloads the tarball `zig-<host>-<version>.tar.xz`,
--- checks it against the pin's sha256 and unpacks it into place
--- ([`Zig.ensure_installed`]). It is a file apart so that what downloads
--- and unpacks is no part of this module's import closure, which
--- build.c, and every test that reaches it, holds.
---
--- `build` gets a prefix flag naming the repository's build directory,
--- as build/paths.tl names it (the root is found from this script's own
--- path), and flags naming zig's two caches.
--- The global cache holds what zig builds of its own (libc, compiler-rt,
--- the standard library); the project cache holds what this build
--- compiles. Both are keyed by content, and every checkout shares them:
--- `COSMIC_ZIG_GLOBAL_CACHE` and `COSMIC_ZIG_CACHE` when set, else
--- `zig-global` and `zig-project` in this user's cosmic cache directory,
--- else (no cache directory at all) `zig-global` and `zig-cache` in the
--- build directory.
--- zig keys a C object by its source's path, and a file in a checkout
--- has an absolute path of its own, so build.zig compiles every C file,
--- vendor/'s and the tree's own, from copies in the project cache, and a
--- fresh worktree compiles none of it again. zig runs in the caller's
--- own working directory.
---
--- Every other subcommand replaces this process with zig, its two caches
--- set in the environment ([`Zig.passthrough_environment`]). `build` runs
--- zig as a child instead, between two snapshots of what the build reads
--- ([`Zig.snapshot`]): a source edited while zig compiles can land in one
--- of a step's inputs and not another's (two links of one core, say),
--- and the failure that follows names neither. When the snapshots differ
--- this says which files moved and exits 1, even when zig succeeded,
--- since what it wrote may mix the two versions. The child stays in this
--- terminal's process group, so a Ctrl-C reaches zig itself. This
--- process catches SIGINT and SIGTERM while zig runs, passes on one zig
--- has not answered, and waits for zig to exit before it answers as zig
--- did ([`Zig.run`]): dying of the signal that ended zig, or of a SIGTERM
--- zig never got, and otherwise exiting with zig's status.
---
--- Exit codes follow the shell's: 127 when zig cannot be found, 126 when
--- it is found but cannot be run, 1 for anything else that stops it from
--- starting.

-- TODO: read the variables below through Env.read (`located` taking an Env.Name) once ci/cosmic-driver.pin names a release
-- whose Env.Name declares them (they are in Env.Name already); bin/zig runs this file on the pinned release, whose Env.Name lacks COSMIC_ZIG, COSMIC_ZIG_CACHE and COSMIC_ZIG_GLOBAL_CACHE.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Log = require("cosmic.log")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Signal = require("cosmic.signal")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

local record Zig
  record Pin
    version: string
    shas: mut {string:string}
  end

  --- Where [`bin/zig.pin`]'s release for a host is installed: `path`,
  --- whether it is there yet or not, with the pin and host that name it.
  record Install
    path: string
    pin: Pin
    host: string
  end
end

local log = Log.new("bin/zig")

--- [`bin/zig.pin`]'s text: a `version <v>` line, then `<host> <sha256>`
--- lines. Each line is read as its first two words, so trailing blanks
--- or a `\r` never become part of a value, and the first line naming a
--- key wins over any later one.
function Zig.read_pin(text: string): Zig.Pin?, string
  local version = ""
  local shas: mut {string:string} = {}
  local seen: mut {string:boolean} = {}
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_.%-]+)%s+(%S+)")
    if key ~= nil and value ~= nil and seen[key] ~= true then
      seen[key] = true
      if key == "version" then
        version = value
      else
        shas[key] = value
      end
    end
  end
  if version == "" then
    return nil, "names no version"
  end
  return { version = version, shas = shas }, ""
end

--- `<arch>-<os>` from `uname(2)`'s raw `sysname` and `machine`,
--- normalized to the names [`bin/zig.pin`] and zig's releases use.
function Zig.host(sysname: string, machine: string): string?, string
  local os: string
  if sysname == "Linux" then
    os = "linux"
  elseif sysname == "Darwin" then
    os = "macos"
  else
    return nil, "unsupported host " .. sysname .. "; cosmic builds on Linux and macOS"
  end
  local arch: string
  if machine == "x86_64" or machine == "amd64" then
    arch = "x86_64"
  elseif machine == "aarch64" or machine == "arm64" then
    arch = "aarch64"
  else
    return nil, "unsupported host cpu " .. machine
  end
  return arch .. "-" .. os, ""
end

--- The repository root, from this script's own path, Lua's `arg[0]`.
function Zig.repo_root(script_path: string): string?, string
  local abs, trouble = Fs.absolute(script_path)
  if abs == nil then
    return nil, trouble
  end
  local root = abs:match("^(.*)/build/[^/]+%.tl$")
  if root == nil then
    return nil, script_path .. ": expected to run as .../build/zig.tl"
  end
  return root, ""
end

--- How many steps `zig build` runs at once on `cpus` processors, unless
--- the caller says (`-j<n>`). zig's own default is one fewer than the
--- processors, which kept about two compiles going in practice: the
--- three targets' vendored libraries, each bound by one long SQLite
--- compile, ran one after another while most processors sat idle. `-j`
--- bounds steps only; each compile still spreads its files over every
--- processor.
function Zig.build_jobs(cpus: integer): integer
  return math.max(8, 2 * cpus)
end

--- `argv` as zig gets it: `build` gains its flags ahead of the caller's
--- own arguments, installing under `output`, the build directory
--- build/paths.tl names, with zig's project cache at
--- `project`, and running [`build_jobs`] steps at once for `cpus`
--- processors unless the caller passes `-j`; anything else passes
--- through unchanged. `zig build` takes no flag for its global cache,
--- only ZIG_GLOBAL_CACHE_DIR ([`Zig.build_environment`]). zig keeps
--- build.zig's configuration until what build.zig declared it read
--- changes; `--cache-poison=disallowed` makes build.zig fail rather
--- than quietly configure again on every build (it calls `findProgram`,
--- say). A read build.zig does not declare, it cannot catch: build.zig
--- declares each (`dependOn*`).
---
--- `--build-file` names build.zig by its absolute path, so `bin/zig build`
--- runs from any working directory, and its build root has a path: one
--- found in the working directory has none in zig 0.17's own library
--- (compiler/Maker.zig's `findBuildRoot`), whose cache then keys every
--- file of the tree by its absolute path, and a checkout elsewhere (CI's
--- Linux legs move the tree with every commit) compiles the vendored
--- libraries again. patch/zig-lib/05 fixes that for a bare `zig build`;
--- this keeps it fixed where zig runs without that library (`COSMIC_ZIG`,
--- a `ZIG_LIB_DIR` of the caller's).
function Zig.build_args(root: string, project: string, output: string,
                        argv: {string}, cpus: integer, defines?: {string}): {string}
  local out: mut {string} = {}
  if argv[1] == "build" then
    out = {
      "build",
      "--build-file", root .. "/build.zig",
      "--cache-dir", project,
      "--prefix", output,
      "--cache-poison=disallowed",
    }
    for _, define in ipairs(defines or {}) do
      out[#out + 1] = define
    end
    local jobs_given = false
    for i, word in ipairs(argv) do
      if i >= 2 and word:match("^%-j") ~= nil then
        jobs_given = true
      end
    end
    if not jobs_given then
      table.insert(out, "-j" .. tostring(Zig.build_jobs(cpus)))
    end
    for i, word in ipairs(argv) do
      if i >= 2 then
        out[#out + 1] = word
      end
    end
    return out
  end
  for _, word in ipairs(argv) do
    out[#out + 1] = word
  end
  return out
end

--- Runs `root`'s `script` standalone on this same binary with `words`,
--- its stdout captured: what [`patch`] and [`Zig.ensure_installed`]
--- start. The binary is started past its launcher ([`Proc.relaunch`]), as
--- a test worker is, so running the script takes no shell and lands on
--- this same core; one with no artifact to relaunch is started as
--- [`Proc.executable`] names it.
local function standalone(root: string, script: string,
                          words: {string}): Child.Result?, string
  local argv: mut {string} = {}
  local env: mut {string:string} = {}
  for name, value in pairs(Env.all()) do env[name] = value end
  local fds: mut {integer:integer | string} = {}
  local relaunch, _ = Proc.relaunch()
  if relaunch ~= nil then
    for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
    for name, value in pairs(relaunch.env) do env[name] = value end
    for number, fd in pairs(relaunch.fds) do fds[number] = fd end
  else
    local self, self_trouble = Proc.executable()
    if self == nil then
      return nil, self_trouble
    end
    argv[#argv + 1] = self
  end
  argv[#argv + 1] = "--standalone"
  argv[#argv + 1] = root .. "/" .. script
  for _, word in ipairs(words) do
    argv[#argv + 1] = word
  end
  local result, trouble = Child.run(argv, { env = env, fds = fds, stdout = "capture" })
  if result == nil then
    return nil, script .. ": " .. trouble
  end
  return result, ""
end

--- `install/zig`, fetching the release into it first unless it is
--- already there -- the cache hit, which never touches the network.
--- The fetch is [`build/zig_fetch.tl`]'s, run standalone from `root`,
--- so nothing that downloads or unpacks is this file's to load.
function Zig.ensure_installed(root: string, cache: string, install: string, pin: Zig.Pin,
                              host: string): string?, string
  local zig = install .. "/zig"
  local installed, look_trouble = Fs.exists(zig)
  if installed == nil then
    return nil, look_trouble
  end
  if installed then
    return zig, ""
  end
  local result, trouble = standalone(root, "build/zig_fetch.tl",
    { cache, install, pin.version, host, pin.shas[host] or "" })
  if result == nil then
    return nil, trouble
  end
  if not result.ok then
    local why = result.stdout or ""
    if why == "" then why = "build/zig_fetch.tl failed" end
    return nil, why
  end
  installed, look_trouble = Fs.exists(zig)
  if installed == nil then
    return nil, look_trouble
  end
  if not installed then
    return nil, "could not install zig into " .. install
  end
  return zig, ""
end

--- Where `name` runs from, or its typed lookup failure. Names holding a
--- slash pass through unchanged; a bare name searches `path` once.
function Zig.resolve(name: string, path: string): Proc.FindResult
  return Proc.find_result(name, path)
end

--- How many of a pin's sha256 hex digits name its install. The name
--- only has to tell apart the pins one cache sees over time (a
--- re-released tarball under an unchanged version, a pin edited by
--- hand), since what gets installed is still held to the whole sha256
--- as it downloads, and the cache is this user's alone
--- ([`Fs.cache_dir`]). 64 bits of a sha256 never collide by chance among
--- those, and a pin chosen to collide gains its author nothing: they
--- write the whole sha256 anyway. The whole digest would work as well;
--- 16 keeps a path short enough to read and type.
local INSTALL_SHA_DIGITS <const> = 16

--- The directory name `pin`'s release for `host` installs under:
--- `<version>-<host>-<sha>`, the sha the first `INSTALL_SHA_DIGITS` of
--- the host's sha256, so a pin whose sha256 changes and whose version
--- does not names a new install rather than finding the old one in
--- place. Nil and why when the pin names no sha256 for `host`, or one
--- that is not 64 hex digits.
-- TODO: remove installs no pin names any more. Each stays until it is
-- removed by hand: one per version and sha a cache has seen, and any
-- `<version>-<host>` directory with no sha, from a naming this no longer
-- uses. That wants a way to tell an install another checkout's pin
-- still names (a last-used stamp touched on each run, say) from one
-- none does.
function Zig.install_name(pin: Zig.Pin, host: string): string?, string
  local sha256 = pin.shas[host]
  if sha256 == nil then
    return nil, "names no sha256 for " .. host
  end
  if #sha256 ~= 64 or sha256:match("^%x+$") == nil then
    return nil, "names a sha256 for " .. host .. " that is not 64 hex digits"
  end
  return pin.version .. "-" .. host .. "-" .. sha256:sub(1, INSTALL_SHA_DIGITS):lower(), ""
end

--- Where the release [`bin/zig.pin`] names for this host is installed
--- under `cache`, whether it is there yet or not: what was extracted
--- from a download the pin's sha256 was checked against when it was
--- installed. Nil and why when the pin or the host cannot be read, or
--- the pin names no well-formed sha256 for the host ([`install_name`]).
function Zig.pinned_install(root: string, cache: string): Zig.Install?, string
  local text, ptrouble = Fs.read(root .. "/bin/zig.pin")
  if text == nil then
    return nil, ptrouble
  end
  local pin, trouble = Zig.read_pin(text)
  if pin == nil then
    return nil, root .. "/bin/zig.pin " .. trouble
  end
  local names, utrouble = sys.uname()
  if names == nil then
    return nil, "uname: " .. utrouble
  end
  local host, htrouble = Zig.host(names.sysname, names.machine)
  if host == nil then
    return nil, htrouble
  end
  local name, ntrouble = Zig.install_name(pin, host)
  if name == nil then
    return nil, root .. "/bin/zig.pin " .. ntrouble
  end
  return { path = cache .. "/" .. name, pin = pin, host = host }, ""
end

--- The name a patched zig library is given ([`patched_lib`]): the first
--- 16 hex digits of the sha256 of each record's name and the sha256 of
--- its bytes, in name order, `records` mapping each name to its bytes.
--- A record edited, added or removed names a new library; the release
--- it patches is named by the directory it sits in.
function Zig.lib_key(records: {string:string}): string
  local names: mut {string} = {}
  for name in pairs(records) do names[#names + 1] = name end
  table.sort(names)
  local lines: mut {string} = {}
  for _, name in ipairs(names) do
    local bytes = records[name]
    if bytes ~= nil then
      lines[#lines + 1] = name .. " " .. Hash.hex_sha256(bytes) .. "\n"
    end
  end
  return Hash.hex_sha256(table.concat(lines)):sub(1, 16)
end

--- zig's library directory as the pinned release installed at `install`
--- ships it, with every record under `root/patch/zig-lib/` applied:
--- `install/lib-<key>` ([`Zig.lib_key`]), written by build/patch.tl
--- run standalone when it is not there yet, so nothing that copies a
--- tree or applies a record is this file's to load. zig compiles `zig
--- build`'s maker, and the cache code it runs, from its library at run
--- time, so a record there fixes what `zig build` does without a zig of
--- our own; the compiler's own copy of that code is fixed only in a
--- rebuilt zig. Nil and "" when there are no records, nil and why when
--- the library cannot be written: every zig command then fails, `cc` and
--- `env` among them, rather than run on a library the tree did not ask
--- for. Builds that start at once before it exists each copy it, and all
--- but the first to finish discard theirs.
-- TODO: remove the `lib-<key>` libraries no record set names any more:
-- each record edit leaves the one before beside the install (234 MB for
-- zig 0.17), as Zig.install_name's TODO says of whole installs.
-- TODO: drop patch/zig-lib/ and this function's call once bin/zig.pin
-- names a zig whose library carries its fixes (cosmic-lua/zig's branches
-- cache-same-contents-hit and build-root-path, not yet sent upstream).
local function patched_lib(root: string, install: string): string?, string
  local dir = root .. "/patch/zig-lib"
  local present, present_trouble = Fs.exists(dir)
  if present == nil then
    return nil, present_trouble
  end
  if not present then
    return nil, ""
  end
  local names, list_trouble = Fs.list(dir)
  if names == nil then
    return nil, list_trouble
  end
  local records: mut {string:string} = {}
  local any = false
  for _, name in ipairs(names) do
    if #name > 4 and name:sub(-4) == ".txt" then
      local data, read_trouble = Fs.read(dir .. "/" .. name)
      if data == nil then
        return nil, read_trouble
      end
      records[name] = data
      any = true
    end
  end
  if not any then
    return nil, ""
  end
  local out = install .. "/lib-" .. Zig.lib_key(records)
  local made, made_trouble = Fs.exists(out)
  if made == nil then
    return nil, made_trouble
  end
  if made then
    return out, ""
  end
  local result, trouble = standalone(root, "build/patch.tl",
    { "--zig-lib", root, install .. "/lib", out })
  if result == nil then
    return nil, trouble
  end
  if not result.ok then
    return nil, "build/patch.tl could not patch zig's library into " .. out
  end
  return out, ""
end

--- The zig to run, and the directory of its pinned install, if it is one.
local record Located
  zig: string
  install?: string
end

--- `COSMIC_ZIG` when set, with no install, otherwise the pinned release
--- for this host, fetched if need be. Nil and why when it cannot be had.
local function locate(root: string): Located?, string
  local env_zig = Env.get("COSMIC_ZIG")
  if env_zig ~= nil and env_zig ~= "" then
    return { zig = env_zig }, ""
  end
  local cache, ctrouble = Fs.cache_dir("zig")
  if cache == nil then
    return nil, ctrouble
  end
  local install, trouble = Zig.pinned_install(root, cache)
  if install == nil then
    return nil, trouble
  end
  local zig, install_trouble = Zig.ensure_installed(root, cache, install.path, install.pin,
    install.host)
  if zig == nil then
    return nil, install_trouble
  end
  return { zig = zig, install = install.path }, ""
end

--- Where one of zig's caches is: `variable` from `environment` (the
--- process's own when nil) when set, else `tool` in this user's cosmic
--- cache directory, made as [`Fs.cache_dir`] makes it, else `fallback`.
--- build/zig_caches.tl spells the same rule, with nothing made, for
--- the test harness, which cannot load this file
--- (build/zig_caches_test.tl holds the two together).
local function located(variable: string, tool: string, fallback: string,
                       environment: {string:string}?): string
  local given = ""
  if environment ~= nil then
    given = environment[variable] or ""
  else
    given = Env.get_or(variable, "")
  end
  if given ~= "" then
    return given
  end
  local made, _ = Fs.cache_dir(tool, { environment = environment })
  if made ~= nil then return made end
  return fallback
end

--- Where zig keeps its global cache: `COSMIC_ZIG_GLOBAL_CACHE` when
--- set, else `zig-global` in this user's cosmic cache directory, made
--- if need be, else `zig-global` in `output`, the build directory.
function Zig.global_cache(output: string, environment?: {string:string}): string
  return located("COSMIC_ZIG_GLOBAL_CACHE", "zig-global", output .. "/zig-global", environment)
end

--- Where zig keeps this build's own cache: `COSMIC_ZIG_CACHE` when set,
--- else `zig-project` in this user's cosmic cache directory, shared by
--- every checkout and made if need be, else `zig-cache` in `output`, the
--- build directory.
function Zig.project_cache(output: string, environment?: {string:string}): string
  return located("COSMIC_ZIG_CACHE", "zig-project", output .. "/zig-cache", environment)
end

--- The environment a zig command other than `build` runs in --
--- `environment`, the caller's, with zig's own caches where `build`
--- puts them: ZIG_GLOBAL_CACHE_DIR the global cache and
--- ZIG_LOCAL_CACHE_DIR the project cache, unless the caller names
--- either itself. Without them `zig cc` would keep a global cache of its
--- own under the user's cache directory, `zig` there, which neither CI
--- restores nor a sandboxed test is given ([`build.caches`]).
function Zig.passthrough_environment(output: string,
                                     environment: {string:string}): {string:string}
  local out: mut {string:string} = {}
  for name, value in pairs(environment) do out[name] = value end
  if (out["ZIG_GLOBAL_CACHE_DIR"] or "") == "" then
    out["ZIG_GLOBAL_CACHE_DIR"] = Zig.global_cache(output, environment)
  end
  if (out["ZIG_LOCAL_CACHE_DIR"] or "") == "" then
    out["ZIG_LOCAL_CACHE_DIR"] = Zig.project_cache(output, environment)
  end
  return out
end

--- The environment `zig build` runs in: `environment`, with
--- ZIG_GLOBAL_CACHE_DIR `shared` whatever the caller set, so every
--- build of every checkout shares it, and ZIG_DEBUG_CMD set.
---
--- zig compiles the maker that runs `zig build` for the host's own CPU
--- model, ReleaseSafe unless ZIG_DEBUG_CMD is set at all, any value
--- asking for Debug: 98 s against 10 s on an x86_64 Linux host, and no
--- build of the tree is slower for it (a boot takes 7 s either way). A
--- cache restored on a runner of another model, as GitHub's Linux
--- runners vary, compiles it again; zig names no way to choose the
--- model. Debug's maker logs at debug level, so a build prints zig's
--- `debug:` lines (a configuration cache hit, say) on standard error.
--- It is 89 MB, so CI's prune drops it before a save
--- (cosmic_ci/zig_prune.tl).
function Zig.build_environment(shared: string,
                               environment: {string:string}): {string:string}
  local out: mut {string:string} = {}
  for name, value in pairs(environment) do out[name] = value end
  out["ZIG_GLOBAL_CACHE_DIR"] = shared
  out["ZIG_DEBUG_CMD"] = "1"
  return out
end

--- The exit status a failed exec means, as a shell reports it.
function Zig.exec_status(number: integer): integer
  if number == sys.ENOENT or number == sys.ENOTDIR then
    return 127
  end
  return 126
end

--- The top-level files a build reads: CI's cache key names these.
local watched_files: {string:boolean} = {
  ["bin/zig.pin"] = true,
  ["build.zig"] = true,
  ["build.zig.zon"] = true,
}

--- The trees whose every file a build may read: the core's C and zig,
--- the vendored sources and their patch records (CI's cache key), and
--- the Teal trees the boot compiles and stages.
local watched_trees: {string:boolean} = {
  ["core"] = true,
  ["vendor"] = true,
  ["patch"] = true,
  ["build"] = true,
  ["cosmic"] = true,
  ["cmd"] = true,
}

--- Whether a walk of the root passes by `entry` (bare name `name`):
--- anything hidden, `o`, the checkout-local build directory older tools
--- wrote, and `ci/`, a tree of its own the boot never stages.
local function unwatched(entry: string, name: string, _kind: Fs.Kind): boolean
  return name:sub(1, 1) == "." or entry == "o" or entry == "ci"
end

--- Whether a build reads the file at `path`, relative to the root:
--- CI's cache key ([`bin/zig.pin`], `build.zig`, `build.zig.zon`,
--- `core/`, `test/portable/*.c`, `vendor/`, `patch/`), plus what the
--- boot stages -- the tool's own trees whole ([`build/patch.tl`], the
--- applier, among them), Teal anywhere else, and the doc guides whose
--- examples it runs.
local function watches(path: string): boolean
  if watched_files[path] == true then
    return true
  end
  local first = path:match("^([^/]+)/")
  if first == nil then
    return String.ends_with(path, ".tl")
  end
  if watched_trees[first] == true then
    return true
  end
  if path:match("^test/portable/[^/]+%.c$") ~= nil or
      path:match("^doc/guides/[^/]+%.md$") ~= nil then
    return true
  end
  return first ~= "bin" and first ~= "doc" and String.ends_with(path, ".tl")
end

--- What a build reads under `root`, by relative path, each as its
--- size, modification and change times, inode and device: enough to see
--- an edit or replacement, or a file added or removed, at the cost of a
--- walk and a stat per file.
function Zig.snapshot(root: string): {string:string}?, string
  -- A link is taken for what it leads to, as work.stage takes it.
  local walked, trouble = Fs.walk_following(root, unwatched)
  if walked == nil then
    return nil, trouble
  end
  local seen: mut {string:string} = {}
  for _, path in ipairs(walked) do
    if watches(path) then
      -- A file gone between the listing and the stat is simply absent.
      local st, _ = sys.stat(root .. "/" .. path)
      if st ~= nil then
        local stamp = string.format("%d %d.%09d %d %d %d.%09d", st.size, st.mtime,
          st.mtime_ns, st.ino, st.dev, st.ctime, st.ctime_ns)
        seen[path] = stamp
      end
    end
  end
  return seen, ""
end

--- The paths two snapshots disagree on -- changed, added or removed --
--- sorted.
function Zig.changed(before: {string:string}, after: {string:string}): {string}
  local out: mut {string} = {}
  for path, was in pairs(before) do
    if after[path] ~= was then
      out[#out + 1] = path
    end
  end
  for path in pairs(after) do
    if before[path] == nil then
      out[#out + 1] = path
    end
  end
  table.sort(out)
  return out
end

--- The line that says a build raced an edit: the first five paths that
--- moved, then how many more, and what happens next: the build is made
--- again (`again`) or left to the caller.
function Zig.race_report(paths: {string}, again?: boolean): string
  local named: mut {string} = {}
  for i, path in ipairs(paths) do
    if i > 5 then break end
    named[#named + 1] = path
  end
  local list = table.concat(named, ", ")
  if #paths > 5 then
    list = list .. " and " .. tostring(#paths - 5) .. " more"
  end
  return "sources changed during the build: " .. list ..
    (if again == true then "; building again" else "; run it again" end)
end

local MS <const> = Clock.ms(1)
local POLL_NS <const> = Clock.ms(20)
local PASS_ON_NS <const> = Clock.ms(250)

--- What [`Zig.run`] shares with the function that watches its child.
local record Signals
  --- The last signal taken but not yet passed on to the child, 0 when none.
  mut pending: integer
end

--- Runs `argv` (`argv[1]` an exact path) to its end in this process
--- group, with the standard streams shared, and answers its status.
---
--- SIGINT and SIGTERM are held by a [`Signal.guard`] meanwhile, so this
--- process outlives the child whatever it is sent. A terminal's Ctrl-C
--- reaches the child directly, since it shares this group. A signal sent
--- to this process alone does not, so one the child has not answered by
--- exiting within a quarter second is passed on to it; the delay keeps a
--- child the terminal already interrupted from being interrupted twice.
---
--- A child ended by SIGINT or SIGTERM ends this process with the same
--- signal, as a shell expects of an interrupted command, and so does a
--- SIGTERM the child never got: one it exited before being passed, or
--- one that came after it ended. A SIGINT the child never got is
--- answered by the child's status instead, as bash answers a Ctrl-C its
--- command caught and exited from: a terminal's Ctrl-C reaches the child
--- too, and one it caught cleanly within the quarter second looks here
--- just like a SIGINT sent to this process alone. A terminal never sends
--- SIGTERM.
function Zig.run(argv: {string}, env?: {string:string}): integer
  local opened, guard_trouble = Signal.guard()
  if opened == nil then
    log:complain("signal guard: " .. guard_trouble)
    return 1
  end
  -- Released below, so its close at the end of this scope does nothing
  -- then; an error that leaves `supervise` first closes it, delivering
  -- what it holds.
  local g <close> = opened
  local signals: Signals = { pending = 0 }
  local function supervise(): Child.Result?, string
    local h, trouble = Child.start(argv, { process_group = false, env = env })
    if h == nil then
      return nil, trouble
    end
    local pass_on_at = 0
    while true do
      local state, wait_trouble = h:try_wait()
      if state == nil then
        -- End the child rather than leave it running unsupervised.
        local _, _ = h:close()
        return nil, wait_trouble
      end
      if state.finished then
        return state.result, ""
      end
      local now = Clock.monotonic_ns()
      local taken = g:take()
      if taken ~= 0 then
        -- A repeat within the window is passed on once, as the last.
        if signals.pending == 0 then
          pass_on_at = now + PASS_ON_NS
        end
        signals.pending = taken
      end
      if signals.pending ~= 0 and now >= pass_on_at then
        -- TODO: this reaches zig's own pid alone -- `zig build` execs its
        -- maker there, which exits on it -- so the compile jobs the
        -- maker started outlive it, orphaned, and build on to the end
        -- (a SIGINT sent to bin/zig alone mid-build leaves them). Pass
        -- it on to zig's descendants as well -- or to this whole process
        -- group with kill(0, signal), weighing that it also reaches the
        -- rest of a pipeline such as `| tee`, and that this same guard
        -- catches the signal sent to the group: such a fix must drop its
        -- own reflected signal rather than take it as a new one and pass
        -- it on again every PASS_ON_NS.
        local _, _ = h:stop(signals.pending)
        signals.pending = 0
      end
      local _, _ = sys.nanosleep(POLL_NS)
    end
  end
  local result, trouble = supervise()
  local caught, release_trouble = g:release()
  -- Taken after the release, so a signal landing between the last
  -- round and the release is kept.
  local untaken = g:take()
  if caught == nil then
    log:complain("signal guard: " .. release_trouble)
  end
  -- A signal the child never got is re-raised only when it is SIGTERM,
  -- which a terminal never sends. A Ctrl-C the child caught and exited
  -- from cleanly is answered by its status, as bash answers it.
  -- Signal provenance identifies a sender, not whether kill targeted
  -- this process or its group. A never-passed SIGINT may already have
  -- reached a child that caught it and exited cleanly, so its status
  -- wins; SIGTERM remains an unanswered cancellation.
  local unpassed = signals.pending
  if untaken ~= 0 then
    unpassed = untaken
  end
  if unpassed ~= sys.SIGTERM then
    unpassed = 0
  end
  if result == nil then
    log:complain((argv[1] or "") .. ": " .. trouble)
    if caught ~= nil and unpassed ~= 0 then
      local _, _ = sys.kill(Proc.pid(), unpassed)
    end
    return 1
  end
  local signal = result.signal
  if signal ~= sys.SIGINT and signal ~= sys.SIGTERM then
    signal = unpassed
  end
  if caught ~= nil and signal ~= nil and signal ~= 0 then
    local _, _ = sys.kill(Proc.pid(), signal)
  end
  return Child.shell_status(result)
end

--- How many times a build runs in all when a source moves while it
--- runs: the first, and one more for each time it did. An edit made
--- while a boot ran leaves the build unfinished, not its work: what zig
--- and the shared compiles kept makes the next run take the files that
--- did not move as they were, so it costs what the edit did.
local MOST_BUILDS <const> = 3

--- `build` between two snapshots of `root`: zig's own status, unless
--- a source moved while it ran, which runs it again, up to
--- [`MOST_BUILDS`] runs in all, and then says so and fails. A snapshot
--- that cannot be taken first leaves the build unwatched rather than
--- stopped. `command` makes the command line for each run, and `run` runs
--- it and answers its status ([`Zig.run`] in zig's own environment).
function Zig.watched_build(root: string, command: function(): {string}?,
                           run: function({string}): integer): integer
  local runs = 0
  while true do
    runs = runs + 1
    local before, _ = Zig.snapshot(root)
    local argv = command()
    if argv == nil then
      return 1
    end
    local status = run(argv)
    if before == nil or status > 128 then
      return status
    end
    local after, trouble = Zig.snapshot(root)
    local moved: {string}
    if after == nil then
      moved = { trouble }
    else
      moved = Zig.changed(before, after)
    end
    if #moved == 0 then
      return status
    end
    -- A build that failed is reported as it failed, not run again for
    -- an edit that may be what it failed on.
    local again = status == 0 and runs < MOST_BUILDS
    log:complain(Zig.race_report(moved, again))
    if not again then
      if status == 0 then return 1 end
      return status
    end
  end
end

--- Writes every vendored tree with its patch records applied, as
--- [`build/patch.tl`] does, into `project`'s `cosmic-vendor` directory, by
--- running that script on this same binary standalone; and the manifest
--- it prints, naming each tree's directory, to an immutable file named by
--- its contents beside those trees. Its shared absolute path keys Zig's
--- configuration without changing with the checkout.
--- build.zig compiles every vendored file from these directories, each
--- named by its contents, so its path is the same from every checkout.
local function patch(root: string, project: string): string?, string
  local made, make_trouble = Fs.mkdirs(project .. "/cosmic-vendor")
  if not made then return nil, make_trouble end
  local directory, directory_trouble = Fs.absolute(project)
  if directory == nil then return nil, directory_trouble end
  local result, trouble = standalone(root, "build/patch.tl",
    { root, directory .. "/cosmic-vendor" })
  if result == nil then
    return nil, trouble
  end
  if not result.ok then
    return nil, "build/patch.tl failed"
  end
  local text = result.stdout or ""
  local manifest = directory .. "/cosmic-vendor/manifest-" .. Hash.hex_sha256(text) .. ".tsv"
  local stored, _ = Fs.read(manifest)
  if stored == text then return manifest, "" end
  local written, write_trouble = Fs.write(manifest, text)
  if not written then
    return nil, write_trouble
  end
  return manifest, ""
end

--- The checkout's rebuild lock, as build/rebuild_lock.tl holds it, by
--- its names in the build directory (build/paths.tl's `Layout`, which
--- build/paths_test.tl holds these to).
--- This standalone entry point takes flock first and SQLite's transaction
--- only where flock_kind says the two lock kinds are apart. The SQL half
--- remains for older checkouts and bisects, whose tools take it alone.
local lock_name <const> = "/rebuild.lock"
local holder_name <const> = "/rebuild.lock.pid"

--- build/rebuild_lock.tl's `handed_variable`: set, to the lock's path,
--- in the environment of a child of the lock's holder, which goes on
--- under that hold rather than wait for it.
local handed_variable <const> = "COSMIC_REBUILD_LOCK_HANDED"

--- build/rebuild_lock.tl's `doing`: what a holder of each role is
--- doing, as a waiting run says it (build/zig_test.tl holds the two
--- alike).
local doing: {string:string} = {
  test = "is running its tests",
  rebuild = "is rebuilding the tool",
  write = "is writing its projection",
  remake = "is making its working database again",
}

--- How long a waiting boot waits in one go before it says it still is.
local reminder_ns <const> = Clock.seconds(15)

--- Whether `given`, the words after bin/zig, is a build of a step that
--- boots, writing the working database in the build directory beside a
--- tool: `boot`, and `sanitized`, which boots the checked core into the
--- build directory's `sanitized`.
function Zig.boots(given: {string}): boolean
  if given[1] ~= "build" then
    return false
  end
  for i = 2, #given do
    if given[i] == "boot" or given[i] == "sanitized" then
      return true
    end
  end
  return false
end

--- The run holding the lock in the build directory `output`, and what it
--- is doing, as build/rebuild_lock.tl's `holder` names them.
function Zig.holder(output: string): string
  local text, _ = Fs.read(output .. holder_name)
  local pid: integer? = nil
  local what = doing["rebuild"] or ""
  if text ~= nil then
    local number, named = text:match("^(%d+)\n(%l*)\n?$")
    pid = math.tointeger(tonumber(number))
    local other = doing[named or ""]
    if other ~= nil then
      what = other
    end
  end
  local who = "another cosmic run"
  if pid ~= nil and pid ~= Proc.pid() then
    local alive, _ = sys.kill(pid, 0)
    if alive then
      who = "another cosmic run (pid " .. tostring(pid) .. ")"
    end
  end
  return who .. " in this checkout " .. what
end

--- Begins the lock's transaction on `db`, waiting up to `wait_ns`:
--- "held", "busy" when another run holds it, or nil and why for any
--- other failure.
local function begin(db: Sqlite.Handle, path: string, wait_ns: integer): string?, string
  db:busy_timeout(wait_ns)
  local begun = db:exec_result("BEGIN IMMEDIATE")
  if begun.cancelled == true then
    return nil, path .. ": interrupted while waiting for the write lock"
  end
  if begun.code == Sqlite.OK then
    return "held", ""
  end
  if begun.code == Sqlite.BUSY then
    return "busy", ""
  end
  return nil, path .. ": " .. begun.reason
end

--- Both halves of the lock, the flock descriptor and the SQL handle
--- that follows it. No second descriptor is closed while the SQL half
--- is held: closing any descriptor of that inode releases this process's
--- fcntl locks. A `<close>` local of it lets go of both, the SQL one
--- first, however its block ends.
local class Lock
  fd: integer
  mut db: Sqlite.Handle?

  function __close(self)
    local db = self.db
    if db ~= nil then local _, _ = db:close() end
    local _, _ = sys.close(self.fd)
  end
end

local function take(lock: Lock, path: string, wait_ns: integer): string?, string
  local started = Clock.monotonic_ns()
  local flocked, trouble, errno = sys.flock(lock.fd, "exclusive", Clock.ceil(wait_ns, MS))
  if not flocked then
    if sys.errno_name(errno) == "ETIMEDOUT" then return "busy", "" end
    return nil, path .. ": " .. trouble
  end
  local kind, kind_trouble = sys.flock_kind(lock.fd)
  if kind == nil then return nil, path .. ": " .. kind_trouble end
  if kind == "apart" then
    local db: Sqlite.Handle
    local lock_db = lock.db
    if lock_db ~= nil then
      db = lock_db
    else
      local opened, db_trouble = Sqlite.open(path, { writable = true })
      if opened == nil then return nil, path .. ": " .. db_trouble end
      lock.db = opened
      db = opened
    end
    local left = math.max(0, wait_ns - (Clock.monotonic_ns() - started))
    return begin(db, path, left)
  end
  return "held", ""
end

--- Takes the boot's lock, or accepts a parent's handoff only when it
--- names the held descriptor's inode. One wait budget covers both halves.
--- Both are let go when the callback ends, including on an exception.
function Zig.with_lock(output: string, environment: {string:string},
                       run: function({string:string}): integer): integer
  local out = output
  local made, made_trouble = Fs.mkdirs(out)
  if not made then
    log:complain(out .. ": " .. made_trouble)
    return 1
  end
  local path = out .. lock_name
  local fd, open_trouble = sys.open(path, sys.O_RDWR | sys.O_CREAT, 0x1a4)
  if fd == nil then
    log:complain(path .. ": " .. open_trouble)
    return 1
  end
  local descriptor: integer = fd
  local function hold(lock: Lock): integer
    local taken, trouble = take(lock, path, 0)
    local handed = false
    if taken == "busy" then
      local given_path = environment[handed_variable]
      if given_path ~= nil and given_path ~= "" then
        local given, _ = sys.stat(given_path)
        local own, _ = sys.fstat(descriptor)
        handed = given ~= nil and own ~= nil and given.dev == own.dev and given.ino == own.ino
      end
      if not handed then
        log:complain(Zig.holder(out) .. "; waiting for it (one run at a time holds " .. path .. ")")
        local waited_ns = 0
        while taken == "busy" do
          taken, trouble = take(lock, path, reminder_ns)
          if taken == "busy" then
            waited_ns = waited_ns + reminder_ns
            local minutes = waited_ns // Clock.minutes(1)
            -- As build/rebuild_lock.tl's `elapsed` says it.
            local said = tostring(waited_ns // Clock.seconds(1)) .. " s"
            if minutes >= 2 then said = tostring(minutes) .. " min" end
            log:complain("still waiting, " .. said .. " on: " ..
                Zig.holder(out) .. " (one run at a time holds " .. path .. ")")
          end
        end
      end
    end
    if taken == nil then
      log:complain(trouble)
      return 1
    end
    if not handed then
      local aside = out .. holder_name .. "." .. tostring(Proc.pid())
      local written, _ = Fs.write(aside, tostring(Proc.pid()) .. "\nrebuild\n")
      if written then local _, _ = Fs.rename(aside, out .. holder_name) end
    end
    local env: mut {string:string} = {}
    for key, value in pairs(environment) do env[key] = value end
    env[handed_variable] = path
    return run(env)
  end
  local lock <close>: Lock = { fd = fd, db = nil }
  return hold(lock)
end

--- The whole entry point over `argv`, the words after this script's own
--- path, `script`.
function Zig.enter(argv: {string}, script: string): integer
  local found_root, root_trouble = Zig.repo_root(script)
  if found_root == nil then
    log:complain(root_trouble)
    return 2
  end
  local root: string = found_root
  local found, ztrouble = locate(root)
  if found == nil then
    log:complain(ztrouble)
    return 1
  end
  local zig = found.zig
  -- The pinned release runs on its library with patch/zig-lib/'s records
  -- applied, unless the caller names a library of their own.
  local environment: mut {string:string} = {}
  for name, value in pairs(Env.all()) do environment[name] = value end
  local install = found.install
  if install ~= nil and (environment["ZIG_LIB_DIR"] or "") == "" then
    local lib, lib_trouble = patched_lib(root, install)
    if lib_trouble ~= "" then
      log:complain(lib_trouble)
      return 1
    end
    if lib ~= nil then environment["ZIG_LIB_DIR"] = lib end
  end
  local resolved = Zig.resolve(zig, Env.get_or("PATH", "/usr/bin:/bin"))
  if resolved.kind ~= "resolved" then
    local status = if resolved.kind == "not_executable" then 126 else 127 end
    log:complain(zig .. ": " .. (if status == 127 then "not found" else "permission denied" end))
    return status
  end

  local program = assert(resolved.path)
  local given: mut {string} = {}
  for _, word in ipairs(argv) do
    given[#given + 1] = word
  end
  if Zig.boots(given) then
    for i, word in ipairs(given) do
      if i >= 2 and (word == "--prefix" or word:sub(1, 9) == "--prefix=" or
          word:sub(1, 2) == "-p") then
        log:complain("boot and sanitized use the project's build directory; do not pass --prefix or -p")
        return 2
      end
    end
  end
  -- A build makes the build directory, which nothing else here writes.
  -- Another command asks for it only where zig's caches fall back to it:
  -- with neither a variable nor a cache directory to name them.
  local function named(variable: string, tool: string): boolean
    if (environment[variable] or "") ~= "" then return true end
    local directory, _ = Fs.cache_dir(tool, { environment = environment, make = false })
    return directory ~= nil
  end
  local output = ""
  if given[1] == "build" or not (named("COSMIC_ZIG_GLOBAL_CACHE", "zig-global") and
      named("COSMIC_ZIG_CACHE", "zig-project")) then
    local words = if given[1] == "build" then { "--prepare", root } else { root } end
    local selected, selection_trouble = standalone(root, "build/paths.tl", words)
    if selected == nil or not selected.ok then
      local why = "build/paths.tl failed"
      if selected == nil then why = selection_trouble end
      log:complain(why)
      return 1
    end
    output = (selected.stdout or ""):gsub("\n$", "")
    if output == "" then
      log:complain("build/paths.tl named no output directory")
      return 1
    end
  end
  local project = Zig.project_cache(output, environment)
  local shared = Zig.global_cache(output, environment)
  if given[1] == "build" then
    -- The vendored trees are patched once the snapshot is taken, so a
    -- vendored file edited while they are is caught as any source is.
    local function build(env?: {string:string}): integer
      local zig_env = Zig.build_environment(shared, env or environment)
      return Zig.watched_build(root, function(): {string}?
        local manifest, patch_trouble = patch(root, project)
        if manifest == nil then
          log:complain(patch_trouble)
          return nil
        end
        local build_argv: mut {string} = { program }
        for _, a in ipairs(Zig.build_args(root, project, output,
            given, Proc.cpu_count(),
            { "-Dpatched=" .. manifest })) do
          build_argv[#build_argv + 1] = a
        end
        return build_argv
      end, function(words: {string}): integer
        return Zig.run(words, zig_env)
      end)
    end
    if Zig.boots(given) then
      return Zig.with_lock(output, environment, build)
    end
    return build()
  end
  local exec_argv: mut {string} = { zig }
  for _, a in ipairs(Zig.build_args(root, project, output, given,
      Proc.cpu_count())) do
    exec_argv[#exec_argv + 1] = a
  end
  local _, trouble, number = sys.execve(program, exec_argv,
    Zig.passthrough_environment(output, environment))
  log:complain(program .. ": " .. tostring(trouble))
  return Zig.exec_status(math.tointeger(number) or 0)
end

--- The entry point: [`Zig.enter`] with this script's path, Lua's `arg[0]`.
function Zig.main(argv: {string}): integer
  return Zig.enter(argv, (assert(arg[0], "zig: no script path")))
end

return Zig
