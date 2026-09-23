--- The logic behind `build/zig.tl`, factored out so it can be unit
--- tested without a network: pin parsing, argument rewriting, and the
--- cache-hit path all have no dependency on `Http.download` actually
--- running.

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Archive = require("cosmic.archive")
local Proc = require("cosmic.proc")
local Host = require("build.host")

local record Zig
  record Pin
    version: string
    shas: {string:string}
  end
end

--- `bin/zig.pin`'s text: a `version <v>` line, then `<host> <sha256>`
--- lines, one per host it names a release for.
function Zig.read_pin(text: string): Zig.Pin | nil, string
  local pin: Zig.Pin = { version = "", shas = {} }
  for key, value in text:gmatch("([%w_.%-]+)[ \t]+([^\n]+)") do
    if key == "version" then
      pin.version = value
    else
      pin.shas[key] = value
    end
  end
  if pin.version == "" then
    return nil, "names no version"
  end
  return pin, ""
end

--- The repository root, from `build/zig.tl`'s own path -- `argv[0]`,
--- the entry point's convention (see `cosmic/entrypoint.tl`).
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

--- `argv`, rewritten the way `bin/zig` always rewrote a `build`
--- subcommand: three flags pinning zig's own caches and install
--- prefix under `root/o`, ahead of the caller's own arguments.
--- Anything else passes through unchanged.
function Zig.build_args(root: string, argv: {string}): {string}
  local out: {string} = {}
  if argv[1] == "build" then
    out[1] = "build"
    out[2] = "--cache-dir"
    out[3] = root .. "/o/zig-cache"
    out[4] = "--global-cache-dir"
    out[5] = root .. "/o/zig-global"
    out[6] = "--prefix"
    out[7] = root .. "/o"
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

--- `$XDG_CACHE_HOME/cosmic/zig`, or `$HOME/.cache/cosmic/zig` when
--- `XDG_CACHE_HOME` is unset or empty.
function Zig.cache_dir(): string
  local base = Env.get("XDG_CACHE_HOME")
  if base == nil or base == "" then
    base = Env.get_or("HOME", "/tmp") .. "/.cache"
  end
  return base .. "/cosmic/zig"
end

--- Downloads and extracts `pin`'s release for `host` into `install`
--- (a scratch directory under `cache`, moved into place once it holds
--- a `zig` binary) unless `install/zig` is already there -- the
--- cache-hit path, which never touches the network.
function Zig.ensure_installed(cache: string, install: string, pin: Zig.Pin, host: string): string | nil, string
  local zig = install .. "/zig"
  if Fs.exists(zig) then
    return zig, ""
  end
  local sha256 = pin.shas[host]
  if sha256 == nil then
    return nil, "bin/zig.pin names no sha256 for " .. host
  end
  local made, mtrouble = Fs.mkdirs(cache)
  if not made then
    return nil, mtrouble
  end
  local name = "zig-" .. host .. "-" .. pin.version .. ".tar.xz"
  local url = "https://ziglang.org/download/" .. pin.version .. "/" .. name
  local work = cache .. "/.work." .. tostring(Proc.pid())
  local work_made, wmtrouble = Fs.mkdirs(work)
  if not work_made then
    return nil, wmtrouble
  end
  local archive = work .. "/" .. name
  local ok, dtrouble = Http.download(url, archive, { sha256 = sha256 })
  if not ok then
    Fs.remove(archive)
    return nil, "download failed: " .. url .. ": " .. dtrouble
  end
  local written, xtrouble = Archive.extract(archive, work)
  if written == nil then
    return nil, archive .. ": " .. xtrouble
  end
  local extracted = work .. "/zig-" .. host .. "-" .. pin.version
  local extracted_zig = extracted .. "/zig"
  if not Fs.exists(extracted_zig) then
    return nil, name .. " holds no zig binary"
  end
  -- Another process may have won the race to install the same version;
  -- its copy is the same bytes, so a rename failure here is not fatal
  -- as long as the destination ends up holding a zig binary.
  Fs.rename(extracted, install)
  if not Fs.exists(zig) then
    return nil, "could not install zig into " .. install
  end
  return zig, ""
end

--- Locates (fetching and installing if needed) the pinned zig for this
--- host, or returns `COSMIC_ZIG` unchanged when that is set.
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
  local host, htrouble = Host.detect()
  if host == nil then
    return nil, htrouble
  end
  local cache = Zig.cache_dir()
  local install = cache .. "/" .. pin.version .. "-" .. host
  return Zig.ensure_installed(cache, install, pin, host)
end

--- The whole `build/zig.tl` entry point, over `argv` exactly as the
--- entry point contract hands it (`argv[0]` is this script's own
--- path).
function Zig.main(argv: {integer:string}): integer
  local root, root_trouble = Zig.repo_root(argv[0])
  if root == nil then
    Fs.put(Fs.stderr, "bin/zig: " .. root_trouble .. "\n")
    return 2
  end
  local zig, ztrouble = Zig.locate(root)
  if zig == nil then
    Fs.put(Fs.stderr, "bin/zig: " .. ztrouble .. "\n")
    return 1
  end

  local call_args: {string} = {}
  local at = 1
  while argv[at] ~= nil do
    call_args[#call_args + 1] = argv[at]
    at = at + 1
  end
  local final_args = Zig.build_args(root, call_args)

  local exec_argv: {string} = { zig }
  for _, a in ipairs(final_args) do
    exec_argv[#exec_argv + 1] = a
  end
  local _, exec_trouble = Proc.exec(zig, exec_argv, Env.all())
  Fs.put(Fs.stderr, "bin/zig: " .. exec_trouble .. "\n")
  return 1
end

return Zig
