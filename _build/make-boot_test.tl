#!/usr/bin/env cosmic
-- Tests for the trust-root make extractor (#756 item 6): pin parsing and
-- url interpolation, member extraction from a real zip, and the
-- executable install. The network path (download) is deliberately not
-- exercised here — the sha pin it enforces is proven by every cold
-- bootstrap.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")
local makeboot = require("_build.make-boot")
local zip = require("cosmic.zip")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_resolve_pin_interpolates_url()
  local pin = check.must(makeboot.resolve_pin({
        version = "2026.07.24-e95cebe09",
        url = "https://example.com/{version}/cosmos.zip",
        platforms = {["*"] = {sha = "AB12"}},
      }))
  assert(pin.url == "https://example.com/2026.07.24-e95cebe09/cosmos.zip",
    "got url: " .. pin.url)
  assert(pin.sha == "AB12", "got sha: " .. pin.sha)
end
test_resolve_pin_interpolates_url()

local function test_resolve_pin_requires_star_platform()
  local pin, err = makeboot.resolve_pin({
      version = "1.0",
      url = "https://example.com/x.zip",
      platforms = {["linux-x86_64"] = {sha = "AB12"}},
    })
  assert(not pin, "expected failure without a '*' platform")
  assert(err and tostring(err):find("platforms"), "got: " .. tostring(err))
end
test_resolve_pin_requires_star_platform()

local function test_resolve_pin_requires_version_and_url()
  local pin, err = makeboot.resolve_pin({
      platforms = {["*"] = {sha = "AB12"}},
    })
  assert(not pin, "expected failure without version/url")
  assert(err ~= nil, "expected an error message")
end
test_resolve_pin_requires_version_and_url()

local function test_load_spec_reads_version_lua()
  local path = fs.join(tmpdir, "version.lua")
  assert(fs.write(path, [[
return {
  platforms = {["*"] = {sha = "cafe"}},
  url = "https://example.com/{version}/cosmos.zip",
  version = "1.2.3"
}
]]))
  local spec = check.must(makeboot.load_spec(path))
  assert(spec.version == "1.2.3", "got version: " .. tostring(spec.version))
  local pin = check.must(makeboot.resolve_pin(spec))
  assert(pin.url == "https://example.com/1.2.3/cosmos.zip", "got url: " .. pin.url)
end
test_load_spec_reads_version_lua()

local function test_load_spec_missing_file()
  local spec, err = makeboot.load_spec(fs.join(tmpdir, "no-such-version.lua"))
  assert(not spec, "expected failure for a missing pin file")
  assert(err ~= nil, "expected an error message")
end
test_load_spec_missing_file()

local function make_archive(): string
  local path = fs.join(tmpdir, "fixture.zip")
  local w = check.must(zip.writer(path))
  assert(w:add("lua", "not the droid\n"))
  assert(w:add("make", "#!/fake/make\n"))
  w:close()
  local data = check.must(fs.read(path))
  return data
end

local function test_extract_member_reads_named_member()
  local data = check.must(makeboot.extract_member(make_archive(), "make"))
  assert(data == "#!/fake/make\n", "got: " .. data)
end
test_extract_member_reads_named_member()

local function test_extract_member_missing_member()
  local data, err = makeboot.extract_member(make_archive(), "unzip")
  assert(not data, "expected failure for a missing member")
  assert(err and tostring(err):find("unzip"), "got: " .. tostring(err))
end
test_extract_member_missing_member()

local function test_extract_member_rejects_garbage()
  local data, err = makeboot.extract_member("this is not a zip", "make")
  assert(not data, "expected failure for a non-zip input")
  assert(err ~= nil, "expected an error message")
end
test_extract_member_rejects_garbage()

local function test_write_executable_sets_exec_bit()
  local out = fs.join(tmpdir, "boot", "cosmo-make")
  assert(check.must(makeboot.write_executable(out, "#!/fake/make\n")))
  assert(check.must(fs.read(out)) == "#!/fake/make\n", "content round-trips")
  local st = fs.stat(out)
  assert(st, "output should stat")
  local mode = (st as fs_types.Stat):mode() % 512 -- cast: mixed-representation Stat
  assert(mode % 2 == 1, "installed file keeps the exec bit")
end
test_write_executable_sets_exec_bit()
