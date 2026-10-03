--- Fetches, verifies and runs the one pinned zig: what [`bin/zig`] hands
--- off to once it has a bootstrap cosmic.
---
---     cosmic --standalone build/zig.tl [args...]
---
--- This file runs standalone, against the bootstrap binary's own
--- embedded standard library and never the tree it sits in, so it
--- requires `cosmic.*` modules only. It runs two more files the same
--- way: before a build, [`build/patch.tl`], which patches the vendored
--- trees (`patch`), and, when the pinned zig is not installed yet,
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
--- `build` gets a prefix flag naming the repository's `o/` (the root is
--- found from this script's own path) and flags naming zig's two caches.
--- The global cache holds what zig builds of its own (libc, compiler-rt,
--- the standard library); the project cache holds what this build
--- compiles. Both are keyed by content, and every checkout shares them:
--- `COSMIC_ZIG_GLOBAL_CACHE` and `COSMIC_ZIG_CACHE` when set, else
--- `zig-global` and `zig-project` in this user's cosmic cache directory,
--- else (no cache directory at all) `o/zig-global` and `o/zig-cache`.
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

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Log = require("cosmic.log")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

local record Zig
  record Pin
    version: string
    shas: {string:string}
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
function Zig.read_pin(text: string): Zig.Pin | nil, string
  local pin: Zig.Pin = { version = "", shas = {} }
  local seen: {string:boolean} = {}
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_.%-]+)%s+(%S+)")
    if key ~= nil and not seen[key] then
      seen[key] = true
      if key == "version" then
        pin.version = value
      else
        pin.shas[key] = value
      end
    end
  end
  if pin.version == "" then
    return nil, "names no version"
  end
  return pin, ""
end

--- `<arch>-<os>` from `uname(2)`'s raw `sysname` and `machine`,
--- normalized to the names [`bin/zig.pin`] and zig's releases use.
function Zig.host(sysname: string, machine: string): string | nil, string
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

--- The repository root, from this script's own path, `argv[0]`.
function Zig.repo_root(script_path: string): string | nil, string
  if script_path == nil then
    return nil, "expected to run as .../build/zig.tl"
  end
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
--- own arguments, installing under `root/o`, with zig's project cache at
--- `project` and its global cache at `shared`, and running [`build_jobs`]
--- steps at once for `cpus` processors unless the caller passes `-j`;
--- anything else passes through unchanged.
function Zig.build_args(root: string, project: string, shared: string,
    argv: {string}, cpus: integer, defines?: {string}): {string}
  local out: {string} = {}
  if argv[1] == "build" then
    out = {
      "build",
      "--cache-dir", project,
      "--global-cache-dir", shared,
      "--prefix", root .. "/o",
    }
    for _, define in ipairs(defines or {}) do
      out[#out + 1] = define
    end
    local jobs_given = false
    for i = 2, #argv do
      if argv[i]:match("^%-j") then
        jobs_given = true
      end
    end
    if not jobs_given then
      out[#out + 1] = "-j" .. tostring(Zig.build_jobs(cpus))
    end
    for i = 2, #argv do
      out[#out + 1] = argv[i]
    end
    return out
  end
  for i = 1, #argv do
    out[#out + 1] = argv[i]
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
                          words: {string}): Child.Result | nil, string
  local argv: {string} = {}
  local env: {string:string} = Env.all()
  local fds: {integer:integer | string} = {}
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
    argv[1] = self
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
                              host: string): string | nil, string
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
    return nil, why ~= "" and why or "build/zig_fetch.tl failed"
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
function Zig.install_name(pin: Zig.Pin, host: string): string | nil, string
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
function Zig.pinned_install(root: string, cache: string): Zig.Install | nil, string
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

--- The zig to run and its first trouble: `COSMIC_ZIG` when set,
--- otherwise the pinned release for this host, fetched if need be.
local function locate(root: string): string | nil, string
  local env_zig = Env.get("COSMIC_ZIG")
  if env_zig ~= nil and env_zig ~= "" then
    return env_zig, ""
  end
  local cache, ctrouble = Fs.cache_dir("zig")
  if cache == nil then
    return nil, ctrouble
  end
  local install, trouble = Zig.pinned_install(root, cache)
  if install == nil then
    return nil, trouble
  end
  return Zig.ensure_installed(root, cache, install.path, install.pin, install.host)
end

--- Where one of zig's caches is: `variable` from `environment` (the
--- process's own when nil) when set, else `tool` in this user's cosmic
--- cache directory, made as [`Fs.cache_dir`] makes it, else `fallback`.
--- build/zig_caches.tl spells the same rule, with nothing made, for
--- the test harness, which cannot load this file
--- (build/zig_caches_test.tl holds the two together).
local function located(variable: string, tool: string, fallback: string,
                       environment: {string:string} | nil): string
  local given: string
  if environment ~= nil then
    given = environment[variable]
  else
    given = Env.get(variable)
  end
  if given ~= nil and given ~= "" then
    return given
  end
  local made, _ = Fs.cache_dir(tool, { environment = environment })
  if made ~= nil then return made end
  return fallback
end

--- Where zig keeps its global cache: `COSMIC_ZIG_GLOBAL_CACHE` when
--- set, else `zig-global` in this user's cosmic cache directory, made
--- if need be, else `root/o/zig-global`.
function Zig.global_cache(root: string, environment?: {string:string}): string
  return located("COSMIC_ZIG_GLOBAL_CACHE", "zig-global", root .. "/o/zig-global", environment)
end

--- Where zig keeps this build's own cache: `COSMIC_ZIG_CACHE` when set,
--- else `zig-project` in this user's cosmic cache directory, shared by
--- every checkout and made if need be, else `root/o/zig-cache`.
function Zig.project_cache(root: string, environment?: {string:string}): string
  return located("COSMIC_ZIG_CACHE", "zig-project", root .. "/o/zig-cache", environment)
end

--- The environment a zig command other than `build` runs in --
--- `environment`, the caller's, with zig's own caches where `build`
--- puts them: ZIG_GLOBAL_CACHE_DIR the global cache and
--- ZIG_LOCAL_CACHE_DIR the project cache, unless the caller names
--- either itself. Without them `zig cc` would keep a global cache of its
--- own under the user's cache directory, `zig` there, which neither CI
--- restores nor a sandboxed test is given ([`build.caches`]).
function Zig.passthrough_environment(root: string,
                                     environment: {string:string}): {string:string}
  local out: {string:string} = {}
  for name, value in pairs(environment) do out[name] = value end
  if (out.ZIG_GLOBAL_CACHE_DIR or "") == "" then
    out.ZIG_GLOBAL_CACHE_DIR = Zig.global_cache(root, environment)
  end
  if (out.ZIG_LOCAL_CACHE_DIR or "") == "" then
    out.ZIG_LOCAL_CACHE_DIR = Zig.project_cache(root, environment)
  end
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
--- anything hidden, the build's own output, and `ci/`, a tree of its
--- own the boot never stages.
local function unwatched(entry: string, name: string): boolean
  return name:sub(1, 1) == "." or entry == "o" or entry == "ci"
end

--- Whether a build reads the file at `path`, relative to the root:
--- CI's cache key ([`bin/zig.pin`], `build.zig`, `build.zig.zon`,
--- `core/`, `test/portable/*.c`, `vendor/`, `patch/`), plus what the
--- boot stages -- the tool's own trees whole ([`build/patch.tl`], the
--- applier, among them), Teal anywhere else, and the doc guides whose
--- examples it runs.
local function watches(path: string): boolean
  if watched_files[path] then
    return true
  end
  local first = path:match("^([^/]+)/")
  if first == nil then
    return String.ends_with(path, ".tl")
  end
  if watched_trees[first] then
    return true
  end
  if path:match("^test/portable/[^/]+%.c$") ~= nil or
      path:match("^doc/guides/[^/]+%.md$") ~= nil then
    return true
  end
  return first ~= "bin" and first ~= "doc" and String.ends_with(path, ".tl")
end

--- What a build reads under `root`, by relative path, each as its
--- size, modification time and inode: enough to see an edit, an
--- editor's replace-by-rename, or a file added or removed, at the cost
--- of a walk and a stat per file and never a read.
function Zig.snapshot(root: string): {string:string} | nil, string
  -- A link is taken for what it leads to, as work.stage takes it.
  local walked, trouble = Fs.walk_following(root, unwatched)
  if walked == nil then
    return nil, trouble
  end
  local seen: {string:string} = {}
  for _, path in ipairs(walked) do
    if watches(path) then
      -- A file gone between the listing and the stat is simply absent.
      local st, _ = sys.stat(root .. "/" .. path)
      if st ~= nil then
        seen[path] = string.format("%d %d.%09d %d", st.size, st.mtime, st.mtime_ns, st.ino)
      end
    end
  end
  return seen, ""
end

--- The paths two snapshots disagree on -- changed, added or removed --
--- sorted.
function Zig.changed(before: {string:string}, after: {string:string}): {string}
  local out: {string} = {}
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
--- moved, then how many more.
function Zig.race_report(paths: {string}): string
  local named: {string} = {}
  for i = 1, math.min(#paths, 5) do
    named[i] = paths[i]
  end
  local list = table.concat(named, ", ")
  if #paths > 5 then
    list = list .. " and " .. tostring(#paths - 5) .. " more"
  end
  return "sources changed during the build: " .. list .. "; run it again"
end

--- The status a shell reports for a child: its exit code, or 128 plus
--- the signal that ended it.
function Zig.child_status(result: Child.Result): integer
  if result.signal ~= nil then
    return 128 + result.signal
  end
  return result.code or 1
end

local MS <const> = Time.ms(1)
local POLL_NS <const> = Time.ms(20)
local PASS_ON_NS <const> = Time.ms(250)

--- Runs `argv` (`argv[1]` an exact path) to its end in this process
--- group, with the standard streams shared, and answers its status.
---
--- SIGINT and SIGTERM are held by a [`Child.guard`] meanwhile, so this
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
  local opened, guard_trouble = Child.guard()
  if opened == nil then
    log:complain("signal guard: " .. guard_trouble)
    return 1
  end
  -- Released below; closed, delivering what it holds, only if an error
  -- leaves this scope first.
  local g <close> = opened
  -- The last signal taken but not yet passed on to the child, 0 when
  -- none.
  local pending = 0
  local function supervise(): Child.Result | nil, string
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
      local now = Time.monotonic_ns()
      local taken = g:take()
      if taken ~= 0 then
        -- A repeat within the window is passed on once, as the last.
        if pending == 0 then
          pass_on_at = now + PASS_ON_NS
        end
        pending = taken
      end
      if pending ~= 0 and now >= pass_on_at then
        -- TODO: this reaches zig's own pid alone, so once zig build has
        -- started its runner, the runner and its compile jobs outlive
        -- zig, orphaned, and build on to the end (a SIGINT sent to
        -- bin/zig alone mid-build leaves them). Pass it on to zig's
        -- descendants as well -- or to this whole process group with
        -- kill(0, signal), weighing that it also reaches the rest of a
        -- pipeline such as `| tee`, and that this same guard catches
        -- the signal sent to the group: such a fix must drop its own
        -- reflected signal rather than take it as a new one and pass it
        -- on again every PASS_ON_NS.
        local _, _ = h:stop(pending)
        pending = 0
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
  local unpassed = untaken ~= 0 and untaken or pending
  if unpassed ~= sys.SIGTERM then
    unpassed = 0
  end
  if result == nil then
    log:complain(argv[1] .. ": " .. trouble)
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
  return Zig.child_status(result)
end

--- `build` between two snapshots of `root`: zig's own status, unless
--- a source moved while it ran. A snapshot that cannot be taken first
--- leaves the build unwatched rather than stopped. zig runs in `env`,
--- this process's environment unless given.
local function watched_build(root: string, env: {string:string} | nil,
    command: function(): {string} | nil): integer
  local before, _ = Zig.snapshot(root)
  local argv = command()
  if argv == nil then
    return 1
  end
  local status = Zig.run(argv, env)
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
  log:complain(Zig.race_report(moved))
  return status ~= 0 and status or 1
end

--- Writes every vendored tree with its patch records applied, as
--- [`build/patch.tl`] does, into `project`'s `cosmic-vendor` directory, by
--- running that script on this same binary standalone; and the manifest
--- it prints, naming each tree's directory, to `root/o/patched.tsv`,
--- which build.zig reads (`-Dpatched=`). Answers the manifest's path.
--- build.zig compiles every vendored file from these directories, each
--- named by its contents, so its path is the same from every checkout.
local function patch(root: string, project: string): string | nil, string
  local result, trouble = standalone(root, "build/patch.tl",
    { root, project .. "/cosmic-vendor" })
  if result == nil then
    return nil, trouble
  end
  if not result.ok then
    return nil, "build/patch.tl failed"
  end
  local made, made_trouble = Fs.mkdirs(root .. "/o")
  if not made then
    return nil, made_trouble
  end
  local manifest = root .. "/o/patched.tsv"
  local written, write_trouble = Fs.write(manifest, result.stdout or "")
  if not written then
    return nil, write_trouble
  end
  return manifest, ""
end

--- The checkout's rebuild lock, as build/rebuild_lock.tl holds it.
--- This standalone entry point takes flock first and SQLite's transaction
--- only where flock_kind says the two lock kinds are apart. The SQL half
--- remains for older checkouts and bisects, whose tools take it alone.
local lock_name <const> = "/o/rebuild.lock"
local holder_name <const> = "/o/rebuild.lock.pid"

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
  write = "is writing o/cosmic.db",
}

--- How long a waiting boot waits in one go before it says it still is.
local reminder_ns <const> = Time.minutes(5)

--- Whether `given`, the words after bin/zig, is a build of a step that
--- boots, writing the working database under o/ beside a tool: `boot`,
--- and `sanitized`, which boots the checked core into o/sanitized.
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

--- The run holding the lock of `root`, and what it is doing, as
--- build/rebuild_lock.tl's `holder` names them.
function Zig.holder(root: string): string
  local text, _ = Fs.read(root .. holder_name)
  local pid: integer | nil = nil
  local role = "rebuild"
  if text ~= nil then
    local number, named = text:match("^(%d+)\n(%l*)\n?$")
    pid = math.tointeger(tonumber(number))
    if named ~= nil and doing[named] ~= nil then
      role = named
    end
  end
  local who = "another cosmic run"
  if pid ~= nil and pid ~= Proc.pid() then
    local alive, _ = sys.kill(pid, 0)
    if alive then
      who = "another cosmic run (pid " .. tostring(pid) .. ")"
    end
  end
  return who .. " in this checkout " .. doing[role]
end

--- Begins the lock's transaction on `db`, waiting up to `wait_ns`:
--- "held", "busy" when another run holds it, or nil and why for any
--- other failure.
local function begin(db: Sqlite.Handle, path: string, wait_ns: integer): string | nil, string
  db:busy_timeout(wait_ns)
  local begun = db:exec_result("BEGIN IMMEDIATE")
  if begun.cancelled then return nil, path .. ": interrupted while waiting for the write lock" end
  if begun.code == Sqlite.OK then
    return "held", ""
  end
  if begun.code == Sqlite.BUSY then
    return "busy", ""
  end
  return nil, path .. ": " .. begun.reason
end

--- Owns both halves until the callback ends, including on an exception.
--- No second descriptor is closed while the SQL half is held: closing
--- any descriptor of that inode releases this process's fcntl locks.
local record Lock
  fd: integer
  db: Sqlite.Handle | nil
  metamethod __close: function(Lock)
end

local lock_mt: metatable<Lock> = {
  __close = function(self: Lock)
    if self.db ~= nil then local _, _ = self.db:close() end
    local _, _ = sys.close(self.fd)
  end,
}

local function take(lock: Lock, path: string, wait_ns: integer): string | nil, string
  local started = Time.monotonic_ns()
  local flocked, trouble, errno = sys.flock(lock.fd, "exclusive", Time.ceil(wait_ns, MS))
  if not flocked then
    if sys.errno_name(errno) == "ETIMEDOUT" then return "busy", "" end
    return nil, path .. ": " .. trouble
  end
  local kind, kind_trouble = sys.flock_kind(lock.fd)
  if kind == nil then return nil, path .. ": " .. kind_trouble end
  if kind == "apart" then
    if lock.db == nil then
      local db, db_trouble = Sqlite.open(path, { writable = true })
      if db == nil then return nil, path .. ": " .. db_trouble end
      lock.db = db
    end
    local left = math.max(0, wait_ns - (Time.monotonic_ns() - started))
    return begin(lock.db, path, left)
  end
  return "held", ""
end

--- Takes the boot's lock, or accepts a parent's handoff only when it
--- names the held descriptor's inode. One wait budget covers both halves.
function Zig.with_lock(root: string, environment: {string:string},
    run: function({string:string}): integer): integer
  local made, made_trouble = Fs.mkdirs(root .. "/o")
  if not made then
    log:complain(root .. "/o: " .. made_trouble)
    return 1
  end
  local path = root .. lock_name
  local fd, open_trouble = sys.open(path, sys.O_RDWR | sys.O_CREAT, 0x1a4)
  if fd == nil then
    log:complain(path .. ": " .. open_trouble)
    return 1
  end
  local opened: Lock = { fd = fd }
  local lock <close> = setmetatable(opened, lock_mt)
  local taken, trouble = take(lock, path, 0)
  local handed = false
  if taken == "busy" then
    local given_path = environment[handed_variable]
    if given_path ~= nil and given_path ~= "" then
      local given, _ = sys.stat(given_path)
      local own, _ = sys.fstat(fd)
      handed = given ~= nil and own ~= nil and given.dev == own.dev and given.ino == own.ino
    end
    if not handed then
      log:complain(Zig.holder(root) .. "; waiting for it (one run at a time holds " .. path .. ")")
      local waited_ns = 0
      while taken == "busy" do
        taken, trouble = take(lock, path, reminder_ns)
        if taken == "busy" then
          waited_ns = waited_ns + reminder_ns
          local minutes = waited_ns // Time.minutes(1)
          log:complain("still waiting, " .. tostring(minutes) ..
            (minutes == 1 and " minute" or " minutes") .. " on: " ..
            Zig.holder(root) .. " (one run at a time holds " .. path .. ")")
        end
      end
    end
  end
  if taken == nil then
    log:complain(trouble)
    return 1
  end
  if not handed then
    local aside = root .. holder_name .. "." .. tostring(Proc.pid())
    local written, _ = Fs.write(aside, tostring(Proc.pid()) .. "\nrebuild\n")
    if written then local _, _ = Fs.rename(aside, root .. holder_name) end
  end
  local env: {string:string} = {}
  for key, value in pairs(environment) do env[key] = value end
  env[handed_variable] = path
  return run(env)
end

--- The whole entry point, over `argv` as the entry-point contract
--- hands it: `argv[0]` is this script's own path.
function Zig.main(argv: {integer:string}): integer
  local root, root_trouble = Zig.repo_root(argv[0])
  if root == nil then
    log:complain(root_trouble)
    return 2
  end
  local zig, ztrouble = locate(root)
  if zig == nil then
    log:complain(ztrouble)
    return 1
  end
  local resolved = Zig.resolve(zig, Env.get_or("PATH", "/usr/bin:/bin"))
  if resolved.kind ~= "resolved" then
    local status = resolved.kind == "not_executable" and 126 or 127
    log:complain(zig .. ": " .. (status == 127 and "not found" or "permission denied"))
    return status
  end

  local program = assert(resolved.path)
  local given: {string} = {}
  local at = 1
  while argv[at] ~= nil do
    given[#given + 1] = argv[at]
    at = at + 1
  end
  if given[1] == "build" then
    -- The vendored trees are patched once the snapshot is taken, so a
    -- vendored file edited while they are is caught as any source is.
    local function build(env?: {string:string}): integer
      return watched_build(root, env, function(): {string} | nil
        local manifest, patch_trouble = patch(root, Zig.project_cache(root))
        if manifest == nil then
          log:complain(patch_trouble)
          return nil
        end
        local build_argv: {string} = { program }
        for _, a in ipairs(Zig.build_args(root, Zig.project_cache(root),
            Zig.global_cache(root), given, Proc.cpu_count(),
            { "-Dpatched=" .. manifest })) do
          build_argv[#build_argv + 1] = a
        end
        return build_argv
      end)
    end
    if Zig.boots(given) then
      return Zig.with_lock(root, Env.all(), build)
    end
    return build()
  end
  local exec_argv: {string} = { zig }
  for _, a in ipairs(Zig.build_args(root, Zig.project_cache(root),
      Zig.global_cache(root), given,
      Proc.cpu_count())) do
    exec_argv[#exec_argv + 1] = a
  end
  local _, trouble, number = sys.execve(program, exec_argv,
    Zig.passthrough_environment(root, Env.all()))
  log:complain(program .. ": " .. tostring(trouble))
  return Zig.exec_status(math.tointeger(number) or 0)
end

return Zig
