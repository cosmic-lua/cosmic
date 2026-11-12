--- The bootstrap cosmic a check of the tree's C falls back to: where the
--- pinned zig is not installed, a compile runs [`bin/zig`], which runs
--- build/zig.tl on it ([`build.c`]'s `bootstrap_cosmic`). The checks
--- themselves, which start zig alone, are build/c/rules_test.tl's.

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local c = require("build.c")

--- What bin/cosmic-bootstrap reads to find or fetch the bootstrap cosmic,
--- the system's `sh` that runs it, and the cache it keeps it in.
Test.policy{
  profiles = { "system" },
  grants = {
    { path = "bin/cosmic-bootstrap", letters = "r" },
    { path = "ci/cosmic-driver.pin", letters = "r" },
    { path = "ci/bootstrap-files.txt", letters = "r" },
    { path = "/cache/bootstrap", letters = "rwxc" },
  },
  env = { "ALL_PROXY", "COSMIC_BOOTSTRAP", "COSMIC_BOOTSTRAP_ATTEMPTS", "COSMIC_BOOTSTRAP_VERIFY",
    "CURL_CA_BUNDLE", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "PATH", "SSL_CERT_DIR", "SSL_CERT_FILE",
    "all_proxy", "http_proxy", "https_proxy", "no_proxy" },
}

local root = assert(Fs.absolute("."))

--- The digest ci/cosmic-driver.pin's third line names.
local function pinned_digest(): string
  local pin = assert(Fs.read(root .. "/ci/cosmic-driver.pin"))
  local digest = assert(pin:match("^[^\n]*\n[^\n]*\n(%x+)"), "the pin names no digest")
  return digest
end

--- The bootstrap cosmic a check's compiler runs on is found where bin/cosmic has cached it.
local function test_the_cached_bootstrap_cosmic_is_found()
  local found, why = c.bootstrap_cosmic(root, Env.all(), pinned_digest())
  assert(found ~= nil, why)
  assert(found:sub(-#pinned_digest()) == pinned_digest(), found)
end

--- A bootstrap cosmic that is not cached and cannot be fetched is said, with the fetch's own error, so a check reports
--- why rather than confine a compiler that cannot run: here a cache of its own holds nothing, and the one fetch goes to
--- a proxy that refuses it.
local function test_a_bootstrap_cosmic_that_cannot_be_had_is_said(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cache"))
  local found, why = c.bootstrap_cosmic(root, {
    PATH = Env.get("PATH") or "/usr/bin:/bin", HOME = tmp, XDG_CACHE_HOME = tmp .. "/cache",
    COSMIC_BOOTSTRAP_ATTEMPTS = "1", https_proxy = "http://127.0.0.1:9", HTTPS_PROXY = "http://127.0.0.1:9",
  }, pinned_digest())
  assert(found == nil, tostring(found))
  assert(why:find("not cached, and bin/cosmic-bootstrap could not fetch it: ", 1, true) ~= nil, why)
  -- The script's own refusal, not a start that failed: it ran, tried once, and said so.
  assert(why:find("(after 1 attempt)", 1, true) ~= nil, why)
end
