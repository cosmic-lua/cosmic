--- `build/fetch.tl`'s cache-hit path: `Fetch.matches` and
--- `Fetch.cache_dir` never touch the network, so this covers them
--- directly rather than through `Fetch.file`.

local Fs = require("cosmic.fs")
local Fetch = require("build.fetch")

local function test_cache_dir_is_under_cosmic()
  local dir = Fetch.cache_dir("vendor")
  assert(dir:find("/cosmic/vendor$") ~= nil)
end

local function test_matches_is_false_for_a_missing_file(tmp: string)
  assert(Fetch.matches(tmp .. "/nothing-here", "0000000000000000000000000000000000000000000000000000000000000000") == false)
end

local function test_matches_compares_sha256_case_insensitively(tmp: string)
  local Hash = require("cosmic.hash")
  local path = tmp .. "/data"
  assert(Fs.write(path, "hello"))
  local digest = Hash.hex_sha256("hello")
  assert(Fetch.matches(path, digest))
  assert(Fetch.matches(path, digest:upper()))
  local mangled = (digest:gsub("^.", "0"))
  assert(not Fetch.matches(path, mangled))
end

local function test_file_is_a_cache_hit_when_already_verified(tmp: string)
  local Hash = require("cosmic.hash")
  local path = tmp .. "/cached.bin"
  assert(Fs.write(path, "already here"))
  local digest = Hash.hex_sha256("already here")
  -- A bogus url: if this were not a cache hit, Fetch.file would try to
  -- download it and fail loudly, so success here proves the network
  -- was never touched.
  local got = assert(Fetch.file("http://url.invalid/should-not-be-fetched", path, digest))
  assert(got == path)
end
