#!/usr/bin/env cosmic
--- Fetch a previous release's named asset, as the ratchet's raw
--- material. The perf gate fetches the previous release's BINARY
--- (`--asset cosmic-lua`) and re-measures it beside the candidate,
--- because stored numbers do not survive a runner change; the size
--- gate fetches stored `size.json`, because size is deterministic.
---
---   cosmic -- o/_perf/baseline.lua --repo OWNER/NAME --out PATH [--asset NAME]
---
--- Lists releases (GET /repos/OWNER/NAME/releases?per_page=30, newest
--- first) via cosmic.fetch, authenticated with GH_TOKEN or
--- GITHUB_TOKEN when set (unauthenticated otherwise — the API allows
--- it, just at a lower rate limit). The previous release is the
--- newest one by created_at, prereleases included and drafts
--- excluded, that carries an asset named exactly --asset (default
--- "perf.json"). Its asset is downloaded to --out.
---
--- Verdict line, always the last line printed:
---   perf-baseline: OK <tag>            asset downloaded to --out
---   perf-baseline: SKIP (no baseline)  no release carries the asset;
---                                       nothing written, exit 0
---   perf-baseline: FAIL (<reason>)     network or parse failure, exit 1
---
--- Report-only policy (skip vs. fail a release on this) lives in the
--- workflow that calls this script, not here.

local flags = require("cosmic.flags")
local fetch = require("cosmic.fetch")
local fs = require("cosmic.fs")
local env = require("cosmic.env")
local proc = require("cosmic.proc")
local shape = require("cosmic.shape")

--- One release asset, as the REST API names the fields this script reads.
local record Asset
  name: string
  browser_download_url: string
end

--- One release, as the REST API names the fields this script reads.
--- A local record declaring only what pick_baseline consults, so the
--- selection is unit-testable on literal fixtures with no network.
local record Release
  tag_name: string
  created_at: string
  draft: boolean
  prerelease: boolean
  assets: {Asset}
end

--- The subset of the releases listing this script consults. Extra keys
--- the REST API sends are ignored, so a field added upstream does not
--- start failing the fetch. `assets` is optional because find_asset
--- already reads it as `release.assets or {}`, and `prerelease`
--- because nothing here consults it: prereleases are eligible.
local RELEASES_SPEC < const > = shape.list(shape.record({
      tag_name = shape.string,
      created_at = shape.string,
      draft = shape.boolean,
      prerelease = shape.optional(shape.boolean),
      assets = shape.optional(shape.list(shape.record({
              name = shape.string,
              browser_download_url = shape.string,
            }))),
    }))

local ASSET_NAME < const > = "perf.json"
local API_URL < const > = "https://api.github.com/repos/%s/releases?per_page=30"

local USAGE = [[
usage: baseline.lua --repo OWNER/NAME --out PATH [--asset NAME]
]]

local SPEC: flags.Spec = {
  name = "baseline.lua",
  flags = {
    {long = "repo", arg = "OWNER/NAME", required = true, help = "GitHub repo to query"},
    {long = "out", arg = "PATH", required = true, help = "write the baseline asset here"},
    {long = "asset", arg = "NAME", default = ASSET_NAME,
      help = "release asset name to fetch (default perf.json)"},
  },
}

local record Args
  repo: string
  out: string
  asset: string
  help: boolean
  err: string
end

--- Parse command-line arguments.
--- @param argv {string} Raw arguments
--- @return Args Parsed arguments; Args.err is set on parse failure
local function parse_args(argv: {string}): Args
  local a: Args = {}
  local parsed, perr = flags.parse(SPEC, argv)
  if not parsed then
    a.err = "argument parse failed: " .. tostring(perr)
    return a
  end
  a.repo = parsed.values["repo"]
  a.out = parsed.values["out"]
  a.asset = parsed.values["asset"]
  a.help = parsed.help
  return a
end

--- The asset named exactly `name` on a release, or nil.
--- @param release Release The release to search
--- @param name string Exact asset name
--- @return Asset | nil The matching asset
local function find_asset(release: Release, name: string): Asset | nil
  for _, a in ipairs(release.assets or {}) do
    if a.name == name then
      return a
    end
  end
  return nil
end

--- The previous release: the newest one by created_at (ISO 8601, so
--- lexicographic order is chronological order) that carries the named
--- asset. Drafts are excluded; prereleases are eligible — almost every
--- release this repo cuts is one. Pure: no network, so it is directly
--- unit-testable on literal fixtures.
--- @param releases {Release} Releases as GitHub's API returns them
--- @param asset_name string Exact asset name a qualifying release must carry
--- @return Release | nil The previous release, or nil when none qualifies
local function pick_baseline(releases: {Release}, asset_name: string): Release | nil
  local best: Release = nil
  for _, r in ipairs(releases) do
    if not r.draft and find_asset(r, asset_name) ~= nil then
      if best == nil or r.created_at > best.created_at then
        best = r
      end
    end
  end
  return best
end

--- List a repo's releases, newest first, authenticated when a token
--- is available.
--- @param repo string "owner/name"
--- @return {Release} | nil The releases
--- @return string Error message on failure
local function list_releases(repo: string): {Release} | nil, string
  local token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN")
  local headers: {string: string} = {
    ["accept"] = "application/vnd.github+json",
    ["x-github-api-version"] = "2022-11-28",
    ["user-agent"] = "cosmic-perf-baseline",
  }
  if token and token ~= "" then
    headers["authorization"] = "Bearer " .. token
  end
  local resp, err = fetch.get(API_URL:format(repo), {
      headers = headers,
      proxy = env.get("HTTPS_PROXY") or env.get("https_proxy"),
    })
  if resp == nil then
    return nil, "GET releases: " .. tostring(err)
  end
  if not resp:is_success() then
    return nil, ("GET releases: HTTP %d"):format(resp.status)
  end
  local decoded, jerr = resp:json()
  if decoded == nil then
    return nil, "decode releases: " .. tostring(jerr)
  end
  local releases, serr: {Release} | nil, string = shape.into(decoded, RELEASES_SPEC)
  if not releases then
    return nil, "decode releases: " .. serr
  end
  return releases
end

--- Download an asset to `out`, creating parent directories first.
--- @param url string Asset download URL
--- @param out string Destination path
--- @return boolean Success
--- @return string Error message on failure
local function download_asset(url: string, out: string): boolean, string
  local outdir = fs.dirname(out)
  if outdir ~= "" and not fs.is_dir(outdir) then
    local mok, mkerr = fs.make_dirs(outdir)
    if not mok then
      return false, "make_dirs " .. outdir .. ": " .. tostring(mkerr)
    end
  end
  local resp, err = fetch.download(url, out)
  if resp == nil then
    return false, "download: " .. tostring(err)
  end
  if not resp:is_success() then
    return false, ("download: HTTP %d"):format(resp.status)
  end
  return true, nil
end

--- CLI entry point.
--- @param ... string Command-line arguments
--- @return integer Exit code: 0 (OK or SKIP), 1 (FAIL)
local function main(...: string): integer
  local a = parse_args({...})
  if a.help then
    print(USAGE)
    return 0
  end
  if a.err then
    print("perf-baseline: FAIL (" .. a.err .. ")")
    return 1
  end
  local releases, lerr = list_releases(a.repo)
  if releases == nil then
    print("perf-baseline: FAIL (" .. lerr .. ")")
    return 1
  end
  local best = pick_baseline(releases, a.asset)
  if best == nil then
    print("perf-baseline: SKIP (no baseline)")
    return 0
  end
  -- pick_baseline only selects releases that carry the asset, so this
  -- cannot miss; assert narrows it to a plain Asset rather than
  -- Asset | nil.
  local asset = assert(find_asset(best, a.asset))
  local dok, derr = download_asset(asset.browser_download_url, a.out)
  if not dok then
    print("perf-baseline: FAIL (" .. derr .. ")")
    return 1
  end
  print("perf-baseline: OK " .. best.tag_name)
  return 0
end

if proc.is_main() then
  os.exit(main(...))
end

local record baseline
  type Release = Release
  type Asset = Asset
  type Args = Args
  main: function(...: string): integer
  parse_args: function(argv: {string}): Args
  pick_baseline: function(releases: {Release}, asset_name: string): Release | nil
  find_asset: function(release: Release, name: string): Asset | nil
end

local M: baseline = {
  main = main,
  parse_args = parse_args,
  pick_baseline = pick_baseline,
  find_asset = find_asset,
}

return M
