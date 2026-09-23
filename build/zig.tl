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
--- Exit codes follow the shell's: 127 when zig cannot be found, 126
--- when it is found but cannot be run, 1 for anything else that stops
--- it from starting.

local Archive = require("cosmic.archive")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

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
  local _, trouble, number = sys.execve(program, exec_argv, Env.all())
  complain(program .. ": " .. tostring(trouble))
  return Zig.exec_status(math.tointeger(number) or 0)
end

return Zig
