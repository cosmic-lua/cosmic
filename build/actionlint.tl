--- Fetches, verifies and runs the one pinned actionlint: what
--- `bin/actionlint` hands off to once it has a bootstrap cosmic.
---
---     cosmic --standalone build/actionlint.tl [args...]
---
--- actionlint (https://github.com/rhysd/actionlint) checks GitHub
--- Actions workflows: their syntax, each expression's types and the
--- contexts it may name where it sits, the inputs of well-known actions,
--- and more. Like `build/zig.tl`, this runs standalone, against the
--- bootstrap binary's own standard library, so it requires `cosmic.*`
--- modules only and holds everything it needs.
---
--- The pin is `bin/actionlint.pin`: a `version` line, then one line per
--- host (`x86_64-linux`, `aarch64-linux`, `x86_64-macos`,
--- `aarch64-macos`) naming the sha256 of that host's release tarball,
--- copied from the release's own `actionlint_<version>_checksums.txt`.
--- The binary is cached at
--- `$XDG_CACHE_HOME/cosmic/actionlint/<version>-<host>-<sha>/actionlint`,
--- the sha the first 16 hex digits of the host's tarball sha256
--- (`Actionlint.install_name`; see `Fs.cache_dir`), beside
--- `actionlint.sha256`, the binary's own sha256 as it was extracted.
--- When the binary is there and still hashes to that record it is used
--- as is; otherwise the tarball is downloaded from the GitHub release
--- with `Http.download`'s own `sha256` check into a scratch `.work.<pid>`
--- directory under the cache, extracted with `cosmic.archive`, and its
--- record then its `actionlint` renamed into place, tolerating a
--- concurrent winner. The scratch directory is removed on every path
--- out. A cached binary that is empty, not executable, or unrecorded or
--- other than its record -- what a killed copy, a bad cache restore or
--- a swapped binary leaves -- is removed and installed afresh, once; an
--- exec that still fails names the directory to remove.
---
--- actionlint runs with its shellcheck and pyflakes integrations off
--- (`Actionlint.args`): it runs whichever of them it finds on `PATH`, so
--- a verdict would depend on the host and on what it happens to have
--- installed. A caller's own `-shellcheck=<path>` comes after, and wins.
--- Unless an argument names what to check -- a file, or `-` for
--- standard input (`Actionlint.names_files`) -- it runs from the
--- repository root, so it finds `.github/workflows/` from any working
--- directory; one that does runs in the caller's own. The arguments
--- pass through unchanged either way.
---
--- Exit codes are actionlint's own (0 clean, 1 findings, 2 bad
--- arguments, 3 a failure of its own), else the shell's: 127 when it
--- cannot be found, 126 when it cannot be run, 1 for anything else that
--- stops it from starting.

-- TODO: share read_pin, host and the cache install with
-- build/zig.tl once `cosmic --standalone` can load a sibling module:
-- it runs one file and refuses any require but cosmic.*, so each tool
-- carries its own copy.

-- TODO: pin shellcheck (koalaman/shellcheck publishes linux x86_64 and
-- aarch64 and darwin aarch64 tarballs) and pass -shellcheck=<its path>,
-- so `run:` scripts are checked too, the same on every host.

-- TODO: pin each host's binary sha256 in bin/actionlint.pin too (taken
-- from its tarball), and check a cached binary against that rather than
-- against the record installed beside it, so a cache whose binary and
-- record were both replaced is caught as well.

-- TODO: actionlint 1.7.12 accepts `${{ github.token }}` in a
-- strategy.matrix value (the github context is available there), but a
-- matrix is expanded before its job has a token, so the value is empty:
-- the mistake #2077 made. Catch it here, or upstream in actionlint's
-- expression checks, once there is a way to walk a workflow's matrix
-- (a YAML reader in cosmic, say).

local Archive = require("cosmic.archive")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Log = require("cosmic.log")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

local record Actionlint
  record Pin
    version: string
    shas: {string:string}
  end

  --- How `Actionlint.ensure_installed` downloads: `Http.download`'s
  --- shape, so a test can stand in for the network.
  type Download = function(url: string, path: string, opts: Http.Options): boolean, string
end

local log = Log.new("bin/actionlint")

--- `bin/actionlint.pin`'s text: a `version <v>` line, then
--- `<host> <sha256>` lines. Each line is read as its first two words,
--- so trailing blanks or a `\r` never become part of a value, and the
--- first line naming a key wins over any later one.
function Actionlint.read_pin(text: string): Actionlint.Pin | nil, string
  local pin: Actionlint.Pin = { version = "", shas = {} }
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

--- `<arch>-<os>` from `uname(2)`'s raw `sysname` and `machine`, as
--- `bin/actionlint.pin` names hosts (and `bin/zig.pin` does).
function Actionlint.host(sysname: string, machine: string): string | nil, string
  local os: string
  if sysname == "Linux" then
    os = "linux"
  elseif sysname == "Darwin" then
    os = "macos"
  else
    return nil, "unsupported host " .. sysname
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

local release_os: {string:string} = { linux = "linux", macos = "darwin" }
local release_arch: {string:string} = { x86_64 = "amd64", aarch64 = "arm64" }

--- The release tarball's name for `host`, as actionlint's releases name
--- it: `actionlint_<version>_<os>_<arch>.tar.gz`, with Go's names for the
--- os (`darwin`) and the cpu (`amd64`, `arm64`).
function Actionlint.asset(version: string, host: string): string | nil, string
  local arch, os = host:match("^([%w_]+)%-(%w+)$")
  local go_os = os ~= nil and release_os[os] or nil
  local go_arch = arch ~= nil and release_arch[arch] or nil
  if go_os == nil or go_arch == nil then
    return nil, "no actionlint release for host " .. host
  end
  return "actionlint_" .. version .. "_" .. go_os .. "_" .. go_arch .. ".tar.gz", ""
end

--- Where the release publishes `asset` for `version`.
function Actionlint.url(version: string, asset: string): string
  return "https://github.com/rhysd/actionlint/releases/download/v" .. version .. "/" .. asset
end

--- `argv` as actionlint gets it, after the program: shellcheck and
--- pyflakes off, then the caller's own arguments, which Go's flag
--- parsing lets override them.
function Actionlint.args(argv: {string}): {string}
  local out: {string} = { "-shellcheck=", "-pyflakes=" }
  for _, a in ipairs(argv) do
    out[#out + 1] = a
  end
  return out
end

--- Whether `argv` names what actionlint is to check -- a file, or `-`
--- for standard input -- rather than leaving it to find
--- `.github/workflows/` from its working directory. A flag is `-x` or
--- `-x=v`; actionlint's flags that take a separate value (`-format`,
--- `-config-file`, ...) are always spelled with `=` here, since a bare
--- word after one would read as a file.
function Actionlint.names_files(argv: {string}): boolean
  for _, a in ipairs(argv) do
    if a == "-" or a:sub(1, 1) ~= "-" then
      return true
    end
  end
  return false
end

--- How many hex digits of the pin's sha256 name an install.
local INSTALL_SHA_DIGITS <const> = 16

--- The directory under the cache `pin`'s release for `host` installs
--- into: `<version>-<host>-<sha>`, the sha the first `INSTALL_SHA_DIGITS`
--- of the host's sha256, so a pin whose sha256 changes and whose version
--- does not names a new install rather than finding the old one in
--- place. Nil and why when the pin names no sha256 for `host`, or one
--- that is not 64 hex digits. The same name as `Zig.install_name`'s.
-- TODO: remove installs no pin names any more, as `Zig.install_name`'s
-- own TODO asks for zig's: each stays until it is removed by hand,
-- including the `<version>-<host>` ones from before the sha was part of
-- the name.
function Actionlint.install_name(pin: Actionlint.Pin, host: string): string | nil, string
  local sha256 = pin.shas[host]
  if sha256 == nil then
    return nil, "names no sha256 for " .. host
  end
  if #sha256 ~= 64 or sha256:match("^%x+$") == nil then
    return nil, "names a sha256 for " .. host .. " that is not 64 hex digits"
  end
  return pin.version .. "-" .. host .. "-" .. sha256:sub(1, INSTALL_SHA_DIGITS):lower(), ""
end

--- Where the binary at `binary` records its own sha256.
local function record_path(binary: string): string
  return binary .. ".sha256"
end

--- Whether the file at `binary` can be the cached binary: there, not
--- empty, executable by someone, and hashing to the sha256 recorded
--- beside it at install. The empty string when it can, else what is
--- wrong with it.
local function unusable(binary: string): string
  local st, _ = sys.stat(binary)
  if st == nil or st.size == 0 or st.mode & 0x49 == 0 then
    return "is empty or not executable"
  end
  local recorded, _ = Fs.read(record_path(binary))
  local want = recorded ~= nil and recorded:match("^(%x+)%s*$") or nil
  if want == nil then
    return "has no sha256 recorded beside it"
  end
  local body, _ = Fs.read(binary)
  if body == nil or Hash.hex_sha256(body) ~= want:lower() then
    return "does not match the sha256 recorded beside it"
  end
  return ""
end

--- The repository root, from this script's own path, `argv[0]`.
function Actionlint.repo_root(script_path: string): string | nil, string
  if script_path == nil then
    return nil, "expected to run as .../build/actionlint.tl"
  end
  local abs, trouble = Fs.absolute(script_path)
  if abs == nil then
    return nil, trouble
  end
  local root = abs:match("^(.*)/build/[^/]+%.tl$")
  if root == nil then
    return nil, script_path .. ": expected to run as .../build/actionlint.tl"
  end
  return root, ""
end

--- Removes every `.work.<pid>` under `cache` whose process is gone.
local function sweep(cache: string)
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

--- Downloads, verifies and extracts `pin`'s release for `host` into
--- `work`, returning the extracted binary's path, its sha256 recorded
--- beside it (`record_path`).
local function unpack(work: string, pin: Actionlint.Pin, host: string,
    download: Actionlint.Download): string | nil, string
  local sha256 = pin.shas[host]
  if sha256 == nil then
    return nil, "bin/actionlint.pin names no sha256 for " .. host
  end
  local asset, atrouble = Actionlint.asset(pin.version, host)
  if asset == nil then
    return nil, atrouble
  end
  local made, mtrouble = Fs.mkdirs(work)
  if not made then
    return nil, mtrouble
  end
  local archive = work .. "/" .. asset
  local url = Actionlint.url(pin.version, asset)
  local ok, dtrouble = download(url, archive, {
    sha256 = sha256,
    connect_timeout_ms = 10000,
    low_speed_bytes = 1024,
    low_speed_seconds = 60,
  })
  if not ok then
    return nil, "download of " .. url .. " failed: " .. dtrouble
  end
  local written, xtrouble = Archive.extract(archive, work .. "/x")
  if written == nil then
    return nil, archive .. ": " .. xtrouble
  end
  local binary = work .. "/x/actionlint"
  local has, look_trouble = Fs.exists(binary)
  if has == nil then
    return nil, look_trouble
  end
  if not has then
    return nil, asset .. " holds no actionlint binary"
  end
  local body, rtrouble = Fs.read(binary)
  if body == nil then
    return nil, rtrouble
  end
  local recorded, wtrouble = Fs.write(record_path(binary), Hash.hex_sha256(body) .. "\n")
  if not recorded then
    return nil, wtrouble
  end
  return binary, ""
end

--- `install/actionlint`, fetching the release into it first unless it is
--- already there and matches the sha256 recorded beside it -- the cache
--- hit, which never touches the network.
--- `download` is `Http.download` unless a test says otherwise.
function Actionlint.ensure_installed(cache: string, install: string, pin: Actionlint.Pin,
    host: string, download?: Actionlint.Download): string | nil, string
  local binary = install .. "/actionlint"
  local installed, look_trouble = Fs.exists(binary)
  if installed == nil then
    return nil, look_trouble
  end
  if installed then
    local wrong = unusable(binary)
    if wrong == "" then
      return binary, ""
    end
    log:complain(binary .. " " .. wrong .. "; installing it again")
    local removed, rtrouble = Fs.remove_tree(install)
    if not removed then
      return nil, install .. ": " .. tostring(rtrouble) .. "; remove it and run again"
    end
  end
  local made, mtrouble = Fs.mkdirs(install)
  if not made then
    return nil, mtrouble
  end
  sweep(cache)
  local work = cache .. "/.work." .. tostring(Proc.pid())
  local _, _ = Fs.remove_tree(work)
  local extracted, trouble = unpack(work, pin, host, download or Http.download)
  if extracted ~= nil then
    -- A concurrent install may have won; its copy is the same bytes,
    -- so a failed rename is fine as long as a binary ends up in place.
    -- The record goes first, so a binary in place always has one.
    local _, _ = Fs.rename(record_path(extracted), record_path(binary))
    local _, _ = Fs.rename(extracted, binary)
  end
  local _, _ = Fs.remove_tree(work)
  if extracted == nil then
    return nil, trouble
  end
  installed, look_trouble = Fs.exists(binary)
  if installed == nil then
    return nil, look_trouble
  end
  if not installed then
    return nil, "could not install actionlint into " .. install
  end
  return binary, ""
end

--- The actionlint to run: the pinned release for this host, fetched if
--- need be.
local function locate(root: string): string | nil, string
  local text, ptrouble = Fs.read(root .. "/bin/actionlint.pin")
  if text == nil then
    return nil, ptrouble
  end
  local pin, trouble = Actionlint.read_pin(text)
  if pin == nil then
    return nil, root .. "/bin/actionlint.pin " .. trouble
  end
  local names, utrouble = sys.uname()
  if names == nil then
    return nil, "uname: " .. utrouble
  end
  local host, htrouble = Actionlint.host(names.sysname, names.machine)
  if host == nil then
    return nil, htrouble
  end
  local cache, ctrouble = Fs.cache_dir("actionlint")
  if cache == nil then
    return nil, ctrouble
  end
  local name, ntrouble = Actionlint.install_name(pin, host)
  if name == nil then
    return nil, root .. "/bin/actionlint.pin " .. ntrouble
  end
  return Actionlint.ensure_installed(cache, cache .. "/" .. name, pin, host)
end

--- The exit status a failed exec means, as a shell reports it.
function Actionlint.exec_status(number: integer): integer
  if number == sys.ENOENT or number == sys.ENOTDIR then
    return 127
  end
  return 126
end

--- The whole entry point, over `argv` as the entry-point contract
--- hands it: `argv[0]` is this script's own path.
function Actionlint.main(argv: {integer:string}): integer
  local root, root_trouble = Actionlint.repo_root(argv[0])
  if root == nil then
    log:complain(root_trouble)
    return 2
  end
  local binary, trouble = locate(root)
  if binary == nil then
    log:complain(trouble)
    return 1
  end
  local given: {string} = {}
  local at = 1
  while argv[at] ~= nil do
    given[#given + 1] = argv[at]
    at = at + 1
  end
  if not Actionlint.names_files(given) then
    local moved, ctrouble = sys.chdir(root)
    if not moved then
      log:complain(root .. ": " .. tostring(ctrouble))
      return 1
    end
  end
  local exec_argv: {string} = { binary }
  for _, a in ipairs(Actionlint.args(given)) do
    exec_argv[#exec_argv + 1] = a
  end
  local _, etrouble, number = sys.execve(binary, exec_argv, Env.all())
  local install = Fs.dirname(binary)
  log:complain(binary .. ": " .. tostring(etrouble) .. "; if the cached copy is broken, remove " ..
    install .. " and run again")
  return Actionlint.exec_status(math.tointeger(number) or 0)
end

return Actionlint
