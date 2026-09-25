--- Fetches, verifies and runs the one pinned zig: what `bin/zig` hands
--- off to once it has a bootstrap cosmic.
---
---     cosmic --standalone build/zig.tl [args...]
---
--- This file runs standalone -- against the bootstrap binary's own
--- embedded standard library, never against the tree it sits in -- so
--- it requires `cosmic.*` modules only, and everything it needs is in
--- this one file. A bootstrap older or newer than the tree, a core
--- edit nobody has booted yet, or a syntax error elsewhere in the tree
--- cannot stop zig from running, which is what rebuilds all of those.
---
--- The pin is `bin/zig.pin`: a `version` line, then one line per host
--- naming that host's release tarball's sha256. `COSMIC_ZIG` names an
--- already-installed zig and skips all of this; a name without a slash
--- is looked up on `PATH`, as a shell would.
---
--- Otherwise the release is cached at
--- `$XDG_CACHE_HOME/cosmic/zig/<version>-<host>` (default
--- `$HOME/.cache/cosmic/zig/...`, and no fallback when neither is set;
--- see `Fs.cache_dir`, which also refuses a cache directory someone
--- else could write to): if `<install>/zig` is already there
--- it is used as is; otherwise the tarball `zig-<host>-<version>.tar.xz`
--- is downloaded with `Http.download`'s own `sha256` check -- from a few
--- of zig's community mirrors, then
--- `https://ziglang.org/download/<version>/`, retried in rounds
--- (`Zig.sources`, `Zig.fetch`) -- into a
--- scratch `.work.<pid>` directory under the cache, extracted with
--- `cosmic.archive`, and renamed into place -- tolerating a concurrent
--- winner, whose copy is the same bytes. The scratch directory is
--- removed on every path out, and one a dead process left behind is
--- removed by the next install.
---
--- `build` gets a prefix flag naming the repository's `o/` (the root is
--- found from this script's own path) and flags naming zig's two caches.
--- The global cache holds what zig builds of its own -- libc,
--- compiler-rt, the standard library; the project cache holds what this
--- build compiles. Both are keyed by content, and every checkout shares
--- them: `COSMIC_ZIG_GLOBAL_CACHE` and `COSMIC_ZIG_CACHE` when set, else
--- `zig-global` and `zig-project` in this user's cosmic cache directory,
--- else (no cache directory at all) `o/zig-global` and `o/zig-cache`.
--- zig keys a C object by its source's path, and a file in a checkout
--- has an absolute path of its own; build.zig compiles everything under
--- vendor/ from copies in the project cache, so a fresh worktree compiles
--- none of it again, only the core's own C. Every other subcommand
--- passes through unchanged. zig runs in the caller's own working
--- directory.
---
--- Every other subcommand replaces this process with zig. `build` runs
--- zig as a child instead, between two snapshots of what the build
--- reads (`Zig.snapshot`): a source edited while zig compiles can land
--- in one of a step's inputs and not another's -- two links of one
--- core, say -- and the failure that follows names neither. When the
--- snapshots differ this says which files moved and exits 1, even
--- when zig succeeded, since what it wrote may mix the two versions.
--- The child stays in this terminal's process group, so a Ctrl-C
--- reaches zig itself; this process catches SIGINT and SIGTERM while
--- zig runs, passes on one zig has not answered, and waits for zig to
--- exit before it answers as zig did (`Zig.run`).
---
--- Exit codes follow the shell's: 127 when zig cannot be found, 126
--- when it is found but cannot be run, 1 for anything else that stops
--- it from starting.

local Archive = require("cosmic.archive")
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Log = require("cosmic.log")
local Proc = require("cosmic.proc")
local String = require("cosmic.string")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

local record Zig
  record Pin
    version: string
    shas: {string:string}
  end

  --- What `Zig.fetch` downloads with, pauses with (for milliseconds)
  --- and reads the time from (in milliseconds): `Http.download`,
  --- `sys.nanosleep` and `Time.monotonic_ns` unless a test says otherwise.
  record Fetcher
    download: function(url: string, path: string, opts: Http.Options): boolean, string
    sleep: function(ms: integer)
    now: function(): integer
  end

  --- Where `bin/zig.pin`'s release for a host is installed: `path`,
  --- whether it is there yet or not, with the pin and host that name it.
  record Install
    path: string
    pin: Pin
    host: string
  end
end

local log = Log.new("bin/zig")

--- `bin/zig.pin`'s text: a `version <v>` line, then `<host> <sha256>`
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
--- normalized to the names `bin/zig.pin` and zig's releases use.
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
--- processors, which in practice kept about two compiles going: the three
--- targets' vendored libraries, each bound by one long SQLite compile,
--- then ran one after another while most processors sat idle. `-j` bounds
--- steps only; each compile still spreads its files over every processor.
function Zig.build_jobs(cpus: integer): integer
  return math.max(8, 2 * cpus)
end

--- `argv` as zig gets it: `build` gains its flags ahead of the caller's
--- own arguments, installing under `root/o`, with zig's project cache at
--- `project` and its global cache at `shared`, and running `build_jobs`
--- steps at once for `cpus` processors unless the caller passes `-j`;
--- anything else passes through unchanged.
function Zig.build_args(root: string, project: string, shared: string,
    argv: {string}, cpus: integer): {string}
  local out: {string} = {}
  if argv[1] == "build" then
    out = {
      "build",
      "--cache-dir", project,
      "--global-cache-dir", shared,
      "--prefix", root .. "/o",
    }
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

--- Removes every `.work.<pid>` under `cache` whose process is gone:
--- what an install killed partway left behind. A live process's own
--- scratch directory is left alone.
function Zig.sweep(cache: string)
  local names, _ = Fs.list(cache)
  if names == nil then
    return
  end
  for _, name in ipairs(names) do
    local pid = tonumber(name:match("^%.work%.(%d+)$"))
    if pid ~= nil then
      local _, _, number = sys.kill(math.tointeger(pid), 0)
      if pid ~= Proc.pid() and number == sys.ESRCH then
        local _, _ = Fs.remove_tree(cache .. "/" .. name)
      end
    end
  end
end

--- zig's community mirrors of `https://ziglang.org/download/`, as
--- https://ziglang.org/download/community-mirrors.txt listed them on
--- 2026-09-24. Refresh this list by copying that file's lines here;
--- three of them already failed for 0.16.0 that day (zigmirror.hryx.net
--- 502, zig.linus.dev 404, zig.tilok.dev 500), which costs an attempt
--- each when drawn, ziglang.org still ending every round. A
--- mirror serves a release's files flat, at `<mirror>/<name>`. No mirror
--- is trusted: each download is held to `bin/zig.pin`'s sha256, so a
--- stale, broken or hostile one costs an attempt and nothing more, and
--- the minisign signature zig publishes beside each file is not needed.
-- TODO: check this list against community-mirrors.txt from ci/ (a
-- scheduled job that fails on a difference) rather than by hand.
local MIRRORS <const>: {string} = {
  "https://pkg.hexops.org/zig",
  "https://zigmirror.hryx.net/zig",
  "https://zig.linus.dev/zig",
  "https://zig.squirl.dev",
  "https://zig.mirror.mschae23.de/zig",
  "https://ziglang.freetls.fastly.net",
  "https://zig.tilok.dev",
  "https://zig-mirror.tsimnet.eu/zig",
  "https://zig.karearl.com/zig",
  "https://pkg.earth/zig",
  "https://fs.liujiacai.net/zigbuilds",
  "https://zigmirror.com",
  "https://zig.chainsafe.dev",
  "https://zig.savalione.com",
  "https://zig.bcr.ist",
  "https://zig.vortan.dev/zig",
}

--- How many mirrors one install tries before ziglang.org.
local MIRRORS_TRIED <const> = 4
--- How many times over the sources an install goes before it gives up.
local ROUNDS <const> = 3
--- The pause before round `n` is `(n - 1)` times this.
local BACKOFF_MS <const> = 2000

--- What bounds the attempts. The limits are there to stop a slow or
--- hostile mirror, not a slow link, which slows every source alike:
---
--- - A mirror attempt gives up on no connection in 10 s, under 64 KiB/s
---   for 20 s straight, or no whole tarball in 3 minutes (a ~55 MB one
---   needs about 300 KiB/s on average), so a trickling mirror costs at
---   most 3 minutes. Mirror attempts and the pauses between rounds share
---   a 12-minute budget: none starts once it is spent, and each one's
---   limits are cut to what is left of it, so the mirrors together cost
---   at most about 12 minutes.
--- - The fallback, ziglang.org, keeps the 10 s connect limit and only a
---   stall guard, under 1 KiB/s for 60 s, which catches a dead stream
---   and nothing slower: no ceiling, and the budget does not cut it, so
---   a slow link still installs. It is bounded only by that guard, by
---   design. It is tried once a round, and once more, last, when the
---   budget runs out partway through the mirrors -- at most `ROUNDS`
---   times in all.
local CONNECT_TIMEOUT_MS <const> = 10000
local MIRROR_LOW_SPEED_BYTES <const> = 64 * 1024
local MIRROR_LOW_SPEED_SECONDS <const> = 20
local MIRROR_TIMEOUT_MS <const> = 3 * 60 * 1000
local FALLBACK_LOW_SPEED_BYTES <const> = 1024
local FALLBACK_LOW_SPEED_SECONDS <const> = 60
local BUDGET_MS <const> = 12 * 60 * 1000

--- The URLs to fetch `name`, zig `version`'s release tarball, from, in
--- the order to try them: `MIRRORS_TRIED` of `mirrors` in a random order
--- (`random(n)` picks from 1 to n, `math.random` by default), then
--- ziglang.org. zig asks automated downloaders -- CI above all -- to
--- use the community mirrors and keep ziglang.org, which is served on a
--- budget, for last; shuffling spreads that load and keeps one dead
--- mirror from being every run's first attempt. ziglang.org comes last
--- rather than never, so a list gone stale still installs. Each mirror
--- URL carries `?source=cosmic`, which zig asks for so mirror operators
--- can tell who fetches.
function Zig.sources(version: string, name: string, mirrors: {string},
    random?: function(integer): integer): {string}
  local pick = random or math.random
  local order: {string} = {}
  for i, mirror in ipairs(mirrors) do
    order[i] = mirror
  end
  for i = #order, 2, -1 do
    local j = pick(i)
    order[i], order[j] = order[j], order[i]
  end
  local out: {string} = {}
  for i = 1, math.min(#order, MIRRORS_TRIED) do
    out[i] = order[i] .. "/" .. name .. "?source=cosmic"
  end
  out[#out + 1] = "https://ziglang.org/download/" .. version .. "/" .. name
  return out
end

local function real_sleep(ms: integer)
  local _, _ = sys.nanosleep(ms * 1000 * 1000)
end

local function real_now_ms(): integer
  return Time.monotonic_ns() // (1000 * 1000)
end

--- Downloads the file whose sha256 is `sha256` to `path` from the first
--- of `urls` that serves it, going over them up to `ROUNDS` times with a
--- growing pause between rounds. Every url but the last is a mirror,
--- held to the mirror limits and the budget; the last is the fallback
--- (ziglang.org), held only to a stall guard, as `BUDGET_MS` says. Once
--- the budget is spent the mirrors are skipped and the fallback is tried
--- one last time. Each attempt starts from no file at `path`
--- (`Http.download` writes a fresh temporary file and renames it into
--- place only once the digest matches). A mirror that served the wrong
--- bytes is not asked again; one that failed any other way is, in the
--- next round. The fallback is never barred: a transfer cut short
--- without an error reads as a mismatch too, and giving up the one
--- source every list ends with on that would make it fatal. When every
--- attempt fails, the message names each source, its last trouble and
--- how long that attempt ran.
function Zig.fetch(urls: {string}, path: string, sha256: string,
    via?: Zig.Fetcher): boolean, string
  local download = via ~= nil and via.download or Http.download
  local sleep = via ~= nil and via.sleep or real_sleep
  local now = via ~= nil and via.now or real_now_ms
  local deadline = now() + BUDGET_MS
  local last: {string:string} = {}
  local wrong: {string:boolean} = {}
  local attempts = 0
  local out_of_time = false

  local function attempt(url: string, opts: Http.Options): boolean
    attempts = attempts + 1
    local _, _ = Fs.remove(path)
    opts.sha256 = sha256
    local started = now()
    local ok, trouble = download(url, path, opts)
    if ok then
      return true
    end
    -- Http.download names the URL itself for some failures; the
    -- report names each source once.
    -- TODO: keep `trouble` whole, and drop this function's entry in
    -- build.contracts' `parsing`, once ci/cosmic-driver.pin names a
    -- cosmic whose Http.download leaves the URL, which its caller
    -- already holds, out of every reason; today's names it beside an
    -- HTTP status alone.
    if String.starts_with(trouble, url .. ": ") then
      trouble = trouble:sub(#url + 3)
    end
    last[url] = trouble .. " (after " .. tostring((now() - started) // 1000) .. " s)"
    return false
  end

  local fallback = urls[#urls]
  for round = 1, ROUNDS do
    if round > 1 then
      sleep((round - 1) * BACKOFF_MS)
    end
    for i = 1, #urls - 1 do
      local url = urls[i]
      if not wrong[url] and not out_of_time then
        local left = deadline - now()
        if left <= 0 then
          out_of_time = true
        else
          local ok = attempt(url, {
            connect_timeout_ms = math.min(CONNECT_TIMEOUT_MS, left),
            low_speed_bytes = MIRROR_LOW_SPEED_BYTES,
            low_speed_seconds = MIRROR_LOW_SPEED_SECONDS,
            timeout_ms = math.min(MIRROR_TIMEOUT_MS, left),
          })
          if ok then
            return true, ""
          end
          -- TODO: tell a digest mismatch apart by something other than
          -- Http.download's message text, once ci/cosmic-driver.pin names
          -- a cosmic whose Http.download reports which failure it hit
          -- apart from the text (test_fetch_sees_a_real_mismatch fails if
          -- the text changes first).
          if last[url]:find("sha256 mismatch", 1, true) ~= nil then
            wrong[url] = true
          end
        end
      end
    end
    if fallback ~= nil then
      local ok = attempt(fallback, {
        connect_timeout_ms = CONNECT_TIMEOUT_MS,
        low_speed_bytes = FALLBACK_LOW_SPEED_BYTES,
        low_speed_seconds = FALLBACK_LOW_SPEED_SECONDS,
      })
      if ok then
        return true, ""
      end
    end
    if out_of_time then
      break
    end
  end
  local lines: {string} = {}
  for _, url in ipairs(urls) do
    lines[#lines + 1] = "\n  " .. url .. ": " .. (last[url] or "not tried")
  end
  local why = out_of_time and "mirrors out of time; every source failed after " or
    "every source failed after "
  return false, why .. tostring(attempts) .. " attempts:" .. table.concat(lines)
end

--- Downloads, verifies and extracts `pin`'s release for `host` into
--- `work`, returning the extracted directory.
local function unpack(work: string, pin: Zig.Pin, host: string): string | nil, string
  local sha256 = pin.shas[host]
  if sha256 == nil then
    return nil, "bin/zig.pin names no sha256 for " .. host
  end
  local made, mtrouble = Fs.mkdirs(work)
  if not made then
    return nil, mtrouble
  end
  local name = "zig-" .. host .. "-" .. pin.version .. ".tar.xz"
  local archive = work .. "/" .. name
  local ok, dtrouble = Zig.fetch(Zig.sources(pin.version, name, MIRRORS), archive, sha256)
  if not ok then
    return nil, "download of " .. name .. " failed: " .. dtrouble
  end
  local written, xtrouble = Archive.extract(archive, work)
  if written == nil then
    return nil, archive .. ": " .. xtrouble
  end
  local extracted = work .. "/zig-" .. host .. "-" .. pin.version
  local has_zig, look_trouble = Fs.exists(extracted .. "/zig")
  if has_zig == nil then
    return nil, look_trouble
  end
  if not has_zig then
    return nil, name .. " holds no zig binary"
  end
  return extracted, ""
end

--- `install/zig`, fetching the release into it first unless it is
--- already there -- the cache hit, which never touches the network.
function Zig.ensure_installed(cache: string, install: string, pin: Zig.Pin,
                              host: string): string | nil, string
  local zig = install .. "/zig"
  local installed, look_trouble = Fs.exists(zig)
  if installed == nil then
    return nil, look_trouble
  end
  if installed then
    return zig, ""
  end
  local made, mtrouble = Fs.mkdirs(cache)
  if not made then
    return nil, mtrouble
  end
  Zig.sweep(cache)
  local work = cache .. "/.work." .. tostring(Proc.pid())
  local _, _ = Fs.remove_tree(work)
  local extracted, trouble = unpack(work, pin, host)
  if extracted ~= nil then
    -- A concurrent install may have won; its copy is the same bytes,
    -- so a failed rename is fine as long as a zig ends up in place.
    local _, _ = Fs.rename(extracted, install)
  end
  local _, _ = Fs.remove_tree(work)
  if extracted == nil then
    return nil, trouble
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

--- Where `name` runs from: itself when it holds a slash, else the
--- first executable file of that name on `path` (an empty entry is the
--- working directory). Nothing runnable is nil and why, as Proc.find
--- says it; `status_of` gives a shell's status for it: 126 for one
--- that is there but not executable, 127 for none at all.
function Zig.resolve(name: string, path: string): string | nil, string
  return Proc.find(name, path)
end

--- The exit status a shell gives for what `resolve` could not find.
-- TODO: tell none from not executable by something other than
-- Proc.find's message, once it reports which case it hit apart from
-- the text.
local function status_of(why: string): integer
  return String.ends_with(why, ": not executable") and 126 or 127
end

--- Where the release `bin/zig.pin` names for this host is installed
--- under `cache`, whether it is there yet or not: what was extracted
--- from a download the pin's sha256 was checked against when it was
--- installed. Nil and why when the pin or the host cannot be read.
-- TODO: name the install by the pin's sha256 as well as its version: a
-- pin whose sha changes but whose version does not finds the old
-- install in place and runs it.
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
  return { path = cache .. "/" .. pin.version .. "-" .. host, pin = pin, host = host }, ""
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
  return Zig.ensure_installed(cache, install.path, install.pin, install.host)
end

--- Where zig keeps its global cache: `COSMIC_ZIG_GLOBAL_CACHE` when
--- set, else `zig-global` in this user's cosmic cache directory, else
--- `root/o/zig-global`.
function Zig.global_cache(root: string, environment?: {string:string}): string
  local given: string
  if environment ~= nil then
    given = environment.COSMIC_ZIG_GLOBAL_CACHE
  else
    given = Env.get("COSMIC_ZIG_GLOBAL_CACHE")
  end
  if given ~= nil and given ~= "" then
    return given
  end
  local cache, _ = Fs.cache_dir("zig-global", environment)
  if cache ~= nil then
    return cache
  end
  return root .. "/o/zig-global"
end

--- Where zig keeps this build's own cache: `COSMIC_ZIG_CACHE` when set,
--- else `zig-project` in this user's cosmic cache directory, shared by
--- every checkout, else `root/o/zig-cache`.
function Zig.project_cache(root: string, environment?: {string:string}): string
  local given: string
  if environment ~= nil then
    given = environment.COSMIC_ZIG_CACHE
  else
    given = Env.get("COSMIC_ZIG_CACHE")
  end
  if given ~= nil and given ~= "" then
    return given
  end
  local cache, _ = Fs.cache_dir("zig-project", environment)
  if cache ~= nil then
    return cache
  end
  return root .. "/o/zig-cache"
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
--- CI's cache key (`bin/zig.pin`, `build.zig`, `build.zig.zon`,
--- `core/`, `test/portable/*.c`, `vendor/`, `patch/`), plus what the
--- boot stages -- the tool's own trees whole, Teal anywhere else, and
--- the doc guides whose examples it runs.
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
  local walked, trouble = Fs.walk(root, unwatched)
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

local POLL_NS <const> = 20 * 1000 * 1000
local PASS_ON_NS <const> = 250 * 1000 * 1000

--- Runs `argv` (`argv[1]` an exact path) to its end in this process
--- group, with the standard streams shared, and answers its status.
--- SIGINT and SIGTERM are caught here meanwhile, so this process
--- outlives the child whatever it is sent. A terminal's Ctrl-C reaches
--- the child directly, since it shares this group; a signal sent to
--- this process alone does not, so one the child has not answered by
--- exiting within a quarter second is passed on to it -- late enough
--- that a child the terminal already interrupted is not interrupted
--- twice. A child SIGINT or SIGTERM ended ends this process with the
--- same signal, as a shell expects of an interrupted command.
function Zig.run(argv: {string}): integer
  -- TODO: hold the signals with `Child.guard` rather than sys.*'s
  -- guard_child_signals, cancelled_child_signal and unguard_child_signals
  -- once ci/cosmic-driver.pin names a cosmic whose Child.Guard has
  -- `take` and `release` (this runs on that release; the pinned one's
  -- guard can only close, which always re-delivers, and keeps only its
  -- first signal). The port polls `g:take()` each round in place of
  -- sys.cancelled_child_signal, passing each signal taken on after
  -- PASS_ON_NS as today; it ends with `g:release()` in place of the
  -- unguard, then one more `g:take()` (after the release, so a signal
  -- landing between them is kept), and keeps this function's own
  -- re-raise rule below (a child that died of SIGINT or SIGTERM
  -- re-raises that), adding one for a signal never passed on: taken
  -- but still held back by PASS_ON_NS, or taken only after the child
  -- ended.
  local guarded, guard_trouble = sys.guard_child_signals()
  if not guarded then
    log:complain("signal guard: " .. guard_trouble)
    return 1
  end
  local function supervise(): Child.Result | nil, string
    local h, trouble = Child.start(argv, { process_group = false })
    if h == nil then
      return nil, trouble
    end
    local pending = 0
    local pass_on_at = 0
    while true do
      local state, wait_trouble = h:try_wait()
      if state == nil then
        return nil, wait_trouble
      end
      if state.finished then
        -- TODO: a `pending` signal the child exited before being passed
        -- is swallowed here: its own Ctrl-C may have ended it cleanly,
        -- but a signal sent to this process alone never reached it.
        -- Answer it beside the result and re-raise it below when the
        -- child did not die of a signal (the Child.guard port above).
        return state.result, ""
      end
      local now = Time.monotonic_ns()
      local cancelled, _ = sys.cancelled_child_signal()
      if pending == 0 and cancelled ~= nil and cancelled ~= 0 then
        pending, pass_on_at = cancelled, now + PASS_ON_NS
      end
      if pending ~= 0 and now >= pass_on_at then
        local _, _ = h:stop(pending)
        pending = 0
      end
      local _, _ = sys.nanosleep(POLL_NS)
    end
  end
  local result, trouble = supervise()
  local _, _ = sys.unguard_child_signals()
  if result == nil then
    log:complain(argv[1] .. ": " .. trouble)
    return 1
  end
  local signal = result.signal
  if signal == sys.SIGINT or signal == sys.SIGTERM then
    local _, _ = sys.kill(sys.getpid(), signal)
  end
  return Zig.child_status(result)
end

--- `build` between two snapshots of `root`: zig's own status, unless
--- a source moved while it ran. A snapshot that cannot be taken first
--- leaves the build unwatched rather than stopped.
local function watched_build(root: string, argv: {string}): integer
  local before, _ = Zig.snapshot(root)
  local status = Zig.run(argv)
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
  local program, unresolved = Zig.resolve(zig, Env.get_or("PATH", "/usr/bin:/bin"))
  if program == nil then
    local status = status_of(unresolved)
    log:complain(zig .. ": " .. (status == 127 and "not found" or "permission denied"))
    return status
  end

  local given: {string} = {}
  local at = 1
  while argv[at] ~= nil do
    given[#given + 1] = argv[at]
    at = at + 1
  end
  local exec_argv: {string} = { zig }
  for _, a in ipairs(Zig.build_args(root, Zig.project_cache(root),
      Zig.global_cache(root), given,
      Proc.cpu_count())) do
    exec_argv[#exec_argv + 1] = a
  end
  if given[1] == "build" then
    exec_argv[1] = program
    return watched_build(root, exec_argv)
  end
  local _, trouble, number = sys.execve(program, exec_argv, Env.all())
  log:complain(program .. ": " .. tostring(trouble))
  return Zig.exec_status(math.tointeger(number) or 0)
end

return Zig
