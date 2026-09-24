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
--- it is used as is; otherwise the tarball
--- `https://ziglang.org/download/<version>/zig-<host>-<version>.tar.xz`
--- is downloaded with `Http.download`'s own `sha256` check into a
--- scratch `.work.<pid>` directory under the cache, extracted with
--- `cosmic.archive`, and renamed into place -- tolerating a concurrent
--- winner, whose copy is the same bytes. The scratch directory is
--- removed on every path out, and one a dead process left behind is
--- removed by the next install.
---
--- `build` gets cache-directory, global-cache-directory and prefix
--- flags under the repository's `o/` (the root is found from this
--- script's own path); every other subcommand passes through
--- unchanged. zig runs in the caller's own working directory.
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
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

local record Zig
  record Pin
    version: string
    shas: {string:string}
  end
end

local function complain(line: string)
  Fs.put(Fs.stderr, "bin/zig: " .. line .. "\n")
end

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

--- `argv` as zig gets it: `build` gains three flags keeping zig's
--- caches and install prefix under `root/o`, ahead of the caller's own
--- arguments; anything else passes through unchanged.
function Zig.build_args(root: string, argv: {string}): {string}
  local out: {string} = {}
  if argv[1] == "build" then
    out = {
      "build",
      "--cache-dir", root .. "/o/zig-cache",
      "--global-cache-dir", root .. "/o/zig-global",
      "--prefix", root .. "/o",
    }
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
  local names = Fs.list(cache)
  if names == nil then
    return
  end
  for _, name in ipairs(names) do
    local pid = tonumber(name:match("^%.work%.(%d+)$"))
    if pid ~= nil then
      local _, _, number = sys.kill(math.tointeger(pid), 0)
      if pid ~= Proc.pid() and number == sys.ESRCH then
        Fs.remove_tree(cache .. "/" .. name)
      end
    end
  end
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
  local url = "https://ziglang.org/download/" .. pin.version .. "/" .. name
  local archive = work .. "/" .. name
  local ok, dtrouble = Http.download(url, archive, { sha256 = sha256 })
  if not ok then
    return nil, "download failed: " .. url .. ": " .. dtrouble
  end
  local written, xtrouble = Archive.extract(archive, work)
  if written == nil then
    return nil, archive .. ": " .. xtrouble
  end
  local extracted = work .. "/zig-" .. host .. "-" .. pin.version
  if not Fs.exists(extracted .. "/zig") then
    return nil, name .. " holds no zig binary"
  end
  return extracted, ""
end

--- `install/zig`, fetching the release into it first unless it is
--- already there -- the cache hit, which never touches the network.
function Zig.ensure_installed(cache: string, install: string, pin: Zig.Pin,
                              host: string): string | nil, string
  local zig = install .. "/zig"
  if Fs.exists(zig) then
    return zig, ""
  end
  local made, mtrouble = Fs.mkdirs(cache)
  if not made then
    return nil, mtrouble
  end
  Zig.sweep(cache)
  local work = cache .. "/.work." .. tostring(Proc.pid())
  Fs.remove_tree(work)
  local extracted, trouble = unpack(work, pin, host)
  if extracted ~= nil then
    -- A concurrent install may have won; its copy is the same bytes,
    -- so a failed rename is fine as long as a zig ends up in place.
    Fs.rename(extracted, install)
  end
  Fs.remove_tree(work)
  if extracted == nil then
    return nil, trouble
  end
  if not Fs.exists(zig) then
    return nil, "could not install zig into " .. install
  end
  return zig, ""
end

--- Where `name` runs from: itself when it holds a slash, else the
--- first executable file of that name on `path` (an empty entry is the
--- working directory). The second result is the exit status a shell
--- would give when nothing runnable was found: 127 for none at all,
--- 126 for one that is there but not executable.
function Zig.resolve(name: string, path: string): string | nil, integer
  if name:find("/", 1, true) ~= nil then
    return name, 0
  end
  local status = 127
  for dir in (path .. ":"):gmatch("([^:]*):") do
    local candidate = (dir == "" and "." or dir) .. "/" .. name
    local st = sys.stat(candidate)
    if st ~= nil and st.kind == "file" then
      if st.mode & 0x49 ~= 0 then
        return candidate, 0
      end
      status = 126
    end
  end
  return nil, status
end

--- The zig to run and its first trouble: `COSMIC_ZIG` when set,
--- otherwise the pinned release for this host, fetched if need be.
function Zig.locate(root: string): string | nil, string
  local env_zig = Env.get("COSMIC_ZIG")
  if env_zig ~= nil and env_zig ~= "" then
    return env_zig, ""
  end
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
  local cache, ctrouble = Fs.cache_dir("zig")
  if cache == nil then
    return nil, ctrouble
  end
  return Zig.ensure_installed(cache, cache .. "/" .. pin.version .. "-" .. host, pin, host)
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
function Zig.unwatched(entry: string, name: string): boolean
  return name:sub(1, 1) == "." or entry == "o" or entry == "ci"
end

--- Whether a build reads the file at `path`, relative to the root:
--- CI's cache key (`bin/zig.pin`, `build.zig`, `build.zig.zon`,
--- `core/`, `test/portable/*.c`, `vendor/`, `patch/`), plus what the
--- boot stages -- the tool's own trees whole, Teal anywhere else, and
--- the doc guides whose examples it runs.
function Zig.watches(path: string): boolean
  if watched_files[path] then
    return true
  end
  local first = path:match("^([^/]+)/")
  if first == nil then
    return path:sub(-3) == ".tl"
  end
  if watched_trees[first] then
    return true
  end
  if path:match("^test/portable/[^/]+%.c$") ~= nil or
      path:match("^doc/guides/[^/]+%.md$") ~= nil then
    return true
  end
  return first ~= "bin" and first ~= "doc" and path:sub(-3) == ".tl"
end

--- What a build reads under `root`, by relative path, each as its
--- size, modification time and inode: enough to see an edit, an
--- editor's replace-by-rename, or a file added or removed, at the cost
--- of a walk and a stat per file and never a read.
function Zig.snapshot(root: string): {string:string} | nil, string
  local walked, trouble = Fs.walk(root, Zig.unwatched)
  if walked == nil then
    return nil, trouble
  end
  local seen: {string:string} = {}
  for _, path in ipairs(walked) do
    if Zig.watches(path) then
      -- A file gone between the listing and the stat is simply absent.
      local st = sys.stat(root .. "/" .. path)
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
  local guarded, guard_trouble = sys.guard_child_signals()
  if not guarded then
    complain("signal guard: " .. guard_trouble)
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
        return state.result, ""
      end
      local now = Time.monotonic_ns() or 0
      local cancelled = sys.cancelled_child_signal()
      if pending == 0 and cancelled ~= nil and cancelled ~= 0 then
        pending, pass_on_at = cancelled, now + PASS_ON_NS
      end
      if pending ~= 0 and now >= pass_on_at then
        h:stop(pending)
        pending = 0
      end
      sys.nanosleep(POLL_NS)
    end
  end
  local result, trouble = supervise()
  sys.unguard_child_signals()
  if result == nil then
    complain(argv[1] .. ": " .. trouble)
    return 1
  end
  local signal = result.signal
  if signal == sys.SIGINT or signal == sys.SIGTERM then
    sys.kill(sys.getpid(), signal)
  end
  return Zig.child_status(result)
end

--- `build` between two snapshots of `root`: zig's own status, unless
--- a source moved while it ran. A snapshot that cannot be taken first
--- leaves the build unwatched rather than stopped.
function Zig.watched_build(root: string, argv: {string}): integer
  local before = Zig.snapshot(root)
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
  complain(Zig.race_report(moved))
  return status ~= 0 and status or 1
end

--- The whole entry point, over `argv` as the entry-point contract
--- hands it: `argv[0]` is this script's own path.
function Zig.main(argv: {integer:string}): integer
  local root, root_trouble = Zig.repo_root(argv[0])
  if root == nil then
    complain(root_trouble)
    return 2
  end
  local zig, ztrouble = Zig.locate(root)
  if zig == nil then
    complain(ztrouble)
    return 1
  end
  local program, status = Zig.resolve(zig, Env.get_or("PATH", "/usr/bin:/bin"))
  if program == nil then
    complain(zig .. ": " .. (status == 127 and "not found" or "permission denied"))
    return status
  end

  local given: {string} = {}
  local at = 1
  while argv[at] ~= nil do
    given[#given + 1] = argv[at]
    at = at + 1
  end
  local exec_argv: {string} = { zig }
  for _, a in ipairs(Zig.build_args(root, given)) do
    exec_argv[#exec_argv + 1] = a
  end
  if given[1] == "build" then
    exec_argv[1] = program
    return Zig.watched_build(root, exec_argv)
  end
  local _, trouble, number = sys.execve(program, exec_argv, Env.all())
  complain(program .. ": " .. tostring(trouble))
  return Zig.exec_status(math.tointeger(number) or 0)
end

return Zig
