--- Unit tests for baseline.pick_baseline on literal release fixtures.
--- No network: every case is a plain table literal.

local baseline = require("_perf.baseline")

local function asset(name: string): {baseline.Asset}
  return {{name = name, browser_download_url = "https://example.invalid/" .. name}}
end

local function test_newest_with_asset_wins_over_newer_without()
  local releases: {baseline.Release} = {
    {tag_name = "v1", created_at = "2026-01-01T00:00:00Z", draft = false,
      prerelease = false, assets = asset("perf.json")},
    {tag_name = "v2", created_at = "2026-02-01T00:00:00Z", draft = false,
      prerelease = false, assets = {}},
  }
  local best = baseline.pick_baseline(releases)
  assert(best ~= nil, "expected a baseline")
  assert(best.tag_name == "v1", "got: " .. tostring(best.tag_name))
end
test_newest_with_asset_wins_over_newer_without()

local function test_prereleases_are_eligible()
  local releases: {baseline.Release} = {
    {tag_name = "v1", created_at = "2026-01-01T00:00:00Z", draft = false,
      prerelease = true, assets = asset("perf.json")},
  }
  local best = baseline.pick_baseline(releases)
  assert(best ~= nil, "prerelease should be eligible")
  assert(best.tag_name == "v1", "got: " .. tostring(best.tag_name))
end
test_prereleases_are_eligible()

local function test_drafts_are_not_eligible()
  local releases: {baseline.Release} = {
    {tag_name = "v1", created_at = "2026-01-01T00:00:00Z", draft = true,
      prerelease = false, assets = asset("perf.json")},
  }
  local best = baseline.pick_baseline(releases)
  assert(best == nil, "draft should be excluded, got: " .. tostring(best))
end
test_drafts_are_not_eligible()

local function test_empty_list_yields_nil()
  local best = baseline.pick_baseline({})
  assert(best == nil, "empty list should yield nil")
end
test_empty_list_yields_nil()

local function test_no_asset_list_yields_nil()
  local releases: {baseline.Release} = {
    {tag_name = "v1", created_at = "2026-01-01T00:00:00Z", draft = false,
      prerelease = false, assets = {}},
    {tag_name = "v2", created_at = "2026-02-01T00:00:00Z", draft = false,
      prerelease = false, assets = asset("not-perf.json")},
  }
  local best = baseline.pick_baseline(releases)
  assert(best == nil, "no release carries perf.json, got: " .. tostring(best))
end
test_no_asset_list_yields_nil()

local function test_newest_among_multiple_qualifying()
  local releases: {baseline.Release} = {
    {tag_name = "v1", created_at = "2026-01-01T00:00:00Z", draft = false,
      prerelease = false, assets = asset("perf.json")},
    {tag_name = "v3", created_at = "2026-03-01T00:00:00Z", draft = false,
      prerelease = false, assets = asset("perf.json")},
    {tag_name = "v2", created_at = "2026-02-01T00:00:00Z", draft = false,
      prerelease = false, assets = asset("perf.json")},
  }
  local best = baseline.pick_baseline(releases)
  assert(best ~= nil, "expected a baseline")
  assert(best.tag_name == "v3", "got: " .. tostring(best.tag_name))
end
test_newest_among_multiple_qualifying()
