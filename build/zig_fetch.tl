--- Downloads, verifies and unpacks the pinned zig release into its
--- install directory: what [`build/zig.tl`] runs when the install is not
--- there yet.
---
---     cosmic --standalone build/zig_fetch.tl <cache> <install> <version> <host> <sha256>
---
--- Like build/zig.tl it runs standalone, on the bootstrap binary's own
--- embedded standard library, so it requires `cosmic.*` modules only.
--- It is a file apart so that what fetches and unpacks -- cosmic.http,
--- cosmic.archive and what they load -- is no part of build/zig.tl's
--- import closure, which build.c, and every test that reaches it, holds.
--- build/zig.tl starts it as it starts [`build/patch.tl`], only on a
--- cache miss.
---
--- The tarball `zig-<host>-<version>.tar.xz` is downloaded, checked by
--- [`Http.download_result`]'s `sha256` option, from a few of zig's community
--- mirrors and then `https://ziglang.org/download/<version>/`, retried in
--- rounds ([`ZigFetch.sources`], [`ZigFetch.fetch`]). It goes into a
--- uniquely named scratch wrapper under `cache`, is extracted with
--- [`cosmic.archive`], and is renamed to `install`, tolerating a
--- concurrent winner, whose copy is the same bytes. The scratch directory
--- is removed on every path out, and one a dead process left behind is
--- removed by the next install after locking its owner file.
---
--- It exits 0 once `<install>/zig` is in place. Otherwise it writes why
--- on stdout, for build/zig.tl to report as its own trouble, and exits 1
--- (2 for words it cannot read).

local Archive = require("cosmic.archive")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

local SECOND <const> = Time.seconds(1)

local record ZigFetch
  --- What [`ZigFetch.fetch`] downloads with, pauses with (for
  --- nanoseconds) and reads the time from (in nanoseconds):
  --- [`Http.download_result`], [`sys.nanosleep`] and [`Time.monotonic_ns`]
  --- unless a test says otherwise.
  record Fetcher
    download: function(url: string, path: string, opts: Http.Options): Http.DownloadResult
    sleep: function(ns: integer)
    now: function(): integer
  end
end

--- The gate is never unlinked: every creator and sweeper must lock the
--- same inode. It covers creation through ownership, so no sweep sees a
--- new wrapper before its owner is locked. Expensive work runs outside it.
--- Kept here because this standalone script can load only the pinned
--- release's cosmic.* modules, not another module from the checkout.
-- TODO: once cosmic.fs carries a scratch-directory helper (the gate, the
-- owner lock, the sweep of dead owners) and ci/cosmic-driver.pin names a
-- release that has it, take this from it, and build/patch.tl's identical
-- copy with it.
local record Descriptor
  fd: integer
  metamethod __close: function(Descriptor)
end
local descriptor_mt: metatable<Descriptor> = {
  __close = function(self: Descriptor) local _, _ = sys.close(self.fd) end,
}

local record Scratch
  path: string
  owner: integer
  metamethod __close: function(Scratch)
end
local scratch_mt: metatable<Scratch> = {
  __close = function(self: Scratch)
    local _, _ = Fs.remove_tree(self.path)
    local _, _ = sys.close(self.owner)
  end,
}

local function scratch(cache: string): Scratch | nil, string
  local fd, trouble = sys.open(cache .. "/.scratch-gate", sys.O_RDWR | sys.O_CREAT | sys.O_NOFOLLOW, 0x180)
  if fd == nil then return nil, trouble end
  local opened: Descriptor = { fd = fd }
  local gate <close> = setmetatable(opened, descriptor_mt)
  local locked, lock_trouble = sys.flock(gate.fd, "exclusive", -1)
  if not locked then return nil, lock_trouble end
  local names, list_trouble = Fs.list(cache)
  if names == nil then return nil, list_trouble end
  for _, name in ipairs(names) do
    -- PID-only names belong to old tools and say nothing about ownership
    -- across namespaces. Missing owner files are also left alone.
    if name:match("^%.scratch%.[%w]+$") then
      local path = cache .. "/" .. name
      local owner, _ = sys.open(path .. "/owner", sys.O_RDWR | sys.O_NOFOLLOW)
      if owner ~= nil then
        local descriptor: Descriptor = { fd = owner }
        local probe <close> = setmetatable(descriptor, descriptor_mt)
        local dead, _ = sys.flock(probe.fd, "exclusive", 0)
        if dead then local _, _ = Fs.remove_tree(path) end
      end
    end
  end
  local path, create_trouble = sys.mkdtemp(cache .. "/.scratch.XXXXXX")
  if path == nil then return nil, create_trouble end
  local owner, owner_trouble = sys.open(path .. "/owner", sys.O_RDWR | sys.O_CREAT | sys.O_EXCL, 0x180)
  if owner == nil then
    local _, _ = Fs.remove_tree(path)
    return nil, owner_trouble
  end
  local owned: Scratch = { path = path, owner = owner }
  local holding = setmetatable(owned, scratch_mt)
  local held, hold_trouble = sys.flock(owner, "exclusive", 0)
  if not held then
    local _cleanup <close> = holding
    return nil, hold_trouble
  end
  return holding, ""
end

--- zig's community mirrors of `https://ziglang.org/download/`, copied
--- from https://ziglang.org/download/community-mirrors.txt on
--- 2026-09-24. Refresh this list by copying that file's lines here. A
--- mirror may be down or lack a release, which costs an attempt each
--- when drawn, ziglang.org still ending every round. A mirror serves a
--- release's files flat, at `<mirror>/<name>`. No mirror is trusted:
--- each download is held to [`bin/zig.pin`]'s sha256, so a stale, broken
--- or hostile one costs an attempt and nothing more, and the minisign
--- signature zig publishes beside each file is not needed.
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
local BACKOFF_NS <const> = 2 * SECOND

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
local CONNECT_TIMEOUT_NS <const> = 10 * SECOND
local MIRROR_LOW_SPEED_BYTES <const> = 64 * 1024
local MIRROR_LOW_SPEED_NS <const> = 20 * SECOND
local MIRROR_TIMEOUT_NS <const> = 3 * 60 * SECOND
local FALLBACK_LOW_SPEED_BYTES <const> = 1024
local FALLBACK_LOW_SPEED_NS <const> = 60 * SECOND
local BUDGET_NS <const> = 12 * 60 * SECOND

--- The URLs to fetch `name`, zig `version`'s release tarball, from, in
--- the order to try them: `MIRRORS_TRIED` of `mirrors` in a random order
--- (`random(n)` picks from 1 to n, `math.random` by default), then
--- ziglang.org.
---
--- zig asks automated downloaders, CI above all, to use the community
--- mirrors and keep ziglang.org, which is served on a budget, for last.
--- Shuffling spreads that load and keeps one dead mirror from being
--- every run's first attempt. ziglang.org comes last rather than never,
--- so a list gone stale still installs. Each mirror URL carries
--- `?source=cosmic`, which zig asks for so mirror operators can tell who
--- fetches.
function ZigFetch.sources(version: string, name: string, mirrors: {string},
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

local function real_sleep(ns: integer)
  local _, _ = sys.nanosleep(ns)
end

--- Native nanosecond download limits; no rounding changes the budget.
function ZigFetch.limits(connect_ns: integer, low_speed_bytes: integer, low_speed_ns: integer,
                         timeout_ns?: integer): Http.Options
  return { connect_timeout_ns = connect_ns, low_speed_bytes = low_speed_bytes,
    low_speed_ns = low_speed_ns, timeout_ns = timeout_ns }
end

--- Downloads the file whose sha256 is `sha256` to `path` from the first
--- of `urls` that serves it, going over them up to `ROUNDS` times with a
--- growing pause between rounds. Every url but the last is a mirror,
--- held to the mirror limits and the budget; the last is the fallback
--- (ziglang.org), held only to a stall guard (see the limits above
--- `CONNECT_TIMEOUT_NS`). Once the budget is spent the mirrors are
--- skipped and the fallback is tried one last time.
---
--- Each attempt starts from no file at `path` ([`Http.download_result`] writes a
--- fresh temporary file and renames it into place only once the digest
--- matches). A mirror that served the wrong bytes is not asked again;
--- one that failed any other way is, in the next round. The fallback is
--- never barred: a transfer cut short without an error reads as a
--- mismatch too, and giving up the one source every list ends with on
--- that would make it fatal. When every attempt fails, the message names
--- each source, its last trouble and how long that attempt ran.
function ZigFetch.fetch(urls: {string}, path: string, sha256: string,
                        via?: ZigFetch.Fetcher): boolean, string
  local download = via ~= nil and via.download or Http.download_result
  local sleep = via ~= nil and via.sleep or real_sleep
  local now = via ~= nil and via.now or Time.monotonic_ns
  local deadline = now() + BUDGET_NS
  local last: {string:string} = {}
  local wrong: {string:boolean} = {}
  local attempts = 0
  local out_of_time = false

  local function attempt(url: string, opts: Http.Options): Http.DownloadResult
    attempts = attempts + 1
    local _, _ = Fs.remove(path)
    opts.sha256 = sha256
    local started = now()
    local result = download(url, path, opts)
    if result.kind ~= "downloaded" then
      last[url] = result.reason .. " (after " .. tostring((now() - started) // SECOND) .. " s)"
    end
    return result
  end

  local fallback = urls[#urls]
  for round = 1, ROUNDS do
    if round > 1 then
      sleep((round - 1) * BACKOFF_NS)
    end
    for i = 1, #urls - 1 do
      local url = urls[i]
      if not wrong[url] and not out_of_time then
        local left = deadline - now()
        if left <= 0 then
          out_of_time = true
        else
          local result = attempt(url, ZigFetch.limits(math.min(CONNECT_TIMEOUT_NS, left),
            MIRROR_LOW_SPEED_BYTES, MIRROR_LOW_SPEED_NS, math.min(MIRROR_TIMEOUT_NS, left)))
          if result.kind == "downloaded" then
            return true, ""
          end
          if result.kind == "digest_mismatch" then
            wrong[url] = true
          end
        end
      end
    end
    if fallback ~= nil then
      local result = attempt(fallback, ZigFetch.limits(CONNECT_TIMEOUT_NS, FALLBACK_LOW_SPEED_BYTES,
        FALLBACK_LOW_SPEED_NS))
      if result.kind == "downloaded" then
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

--- Downloads, verifies and extracts zig `version`'s release for `host`,
--- whose tarball's sha256 is `sha256`, into `work`, returning the
--- extracted directory.
local function unpack(work: string, version: string, host: string,
                      sha256: string): string | nil, string
  local made, mtrouble = Fs.mkdirs(work)
  if not made then
    return nil, mtrouble
  end
  local name = "zig-" .. host .. "-" .. version .. ".tar.xz"
  local archive = work .. "/" .. name
  local ok, dtrouble = ZigFetch.fetch(ZigFetch.sources(version, name, MIRRORS), archive, sha256)
  if not ok then
    return nil, "download of " .. name .. " failed: " .. dtrouble
  end
  local written, xtrouble = Archive.extract(archive, work)
  if written == nil then
    return nil, archive .. ": " .. xtrouble
  end
  local extracted = work .. "/zig-" .. host .. "-" .. version
  local has_zig, look_trouble = Fs.exists(extracted .. "/zig")
  if has_zig == nil then
    return nil, look_trouble
  end
  if not has_zig then
    return nil, name .. " holds no zig binary"
  end
  return extracted, ""
end

--- Fetches zig `version`'s release for `host` into `install`, a
--- directory under `cache`, answering `install/zig`. `sha256` is the
--- host's tarball's, from [`bin/zig.pin`]; nil when the pin names none,
--- which fails with no download.
function ZigFetch.install(cache: string, install: string, version: string, host: string,
                          sha256: string | nil): string | nil, string
  local zig = install .. "/zig"
  local made, mtrouble = Fs.mkdirs(cache)
  if not made then
    return nil, mtrouble
  end
  local owned, own_trouble = scratch(cache)
  if owned == nil then return nil, own_trouble end
  local holding <close> = owned
  local work = holding.path .. "/payload"
  local extracted, trouble: string | nil, string
  if sha256 == nil or sha256 == "" then
    extracted, trouble = nil, "bin/zig.pin names no sha256 for " .. host
  else
    extracted, trouble = unpack(work, version, host, sha256)
  end
  if extracted ~= nil then
    -- A concurrent install may have won; its copy is the same bytes,
    -- so a failed rename is fine as long as a zig ends up in place.
    local _, _ = Fs.rename(extracted, install)
  end
  if extracted == nil then
    return nil, trouble
  end
  local installed, look_trouble = Fs.exists(zig)
  if installed == nil then
    return nil, look_trouble
  end
  if not installed then
    return nil, "could not install zig into " .. install
  end
  return zig, ""
end

--- The whole entry point, over `argv` as the entry-point contract
--- hands it: the words build/zig.tl starts it with (see above).
function ZigFetch.main(argv: {integer:string}): integer
  local cache, install, version, host = argv[1], argv[2], argv[3], argv[4]
  if cache == nil or install == nil or version == nil or host == nil then
    local _, _ = Fs.put(Fs.stdout,
      "usage: build/zig_fetch.tl <cache> <install> <version> <host> <sha256>")
    return 2
  end
  local zig, trouble = ZigFetch.install(cache, install, version, host, argv[5])
  if zig == nil then
    local _, _ = Fs.put(Fs.stdout, trouble)
    return 1
  end
  return 0
end

return ZigFetch
