#!/usr/bin/env cosmic
-- test cosmic --docs guide

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local cenv = require("cosmic.env")
local child = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")

-- drop LUA_PATH so the test exercises the bundled libraries, not the repo
local function clean_env(): {string}
  return cenv.list({drop = {"LUA_PATH", "LUA_CPATH"}})
end

local function test_guide_no_topic()
  local __r1 = check.must(check.must(child.start({cosmic, "--docs", "guide"}, {env = clean_env()})):wait())
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "cosmic --docs guide should succeed")
  local s = out
  assert(s:find("cosmic", 1, true), "default guide output should mention cosmic")
  assert(s:find("Quick Reference", 1, true), "default guide output should contain Quick Reference")
end
test_guide_no_topic()

local function test_guide_testing()
  local __r2 = check.must(check.must(child.start({cosmic, "--docs", "guide.testing"}, {env = clean_env()})):wait())
  local ok, out = __r2.ok, __r2.stdout
  assert(ok, "cosmic --docs guide.testing should succeed")
  local s = out
  assert(s:find("Testing", 1, true), "testing guide should contain Testing header")
  assert(s:find("test_", 1, true), "testing guide should show test_ pattern")
end
test_guide_testing()

local function test_guide_checking()
  local __r3 = check.must(check.must(child.start({cosmic, "--docs", "guide.checking"}, {env = clean_env()})):wait())
  local ok, out = __r3.ok, __r3.stdout
  assert(ok, "cosmic --docs guide.checking should succeed")
  local s = out
  assert(s:find("Type Checking", 1, true), "checking guide should contain Type Checking header")
end
test_guide_checking()

local function test_guide_formatting()
  local __r4 = check.must(check.must(child.start({cosmic, "--docs", "guide.formatting"}, {env = clean_env()})):wait())
  local ok, out = __r4.ok, __r4.stdout
  assert(ok, "cosmic --docs guide.formatting should succeed")
  local s = out
  assert(s:find("Formatting", 1, true), "formatting guide should contain Formatting header")
  assert(s:find("2%-space", 1, false), "formatting guide should mention 2-space indent")
end
test_guide_formatting()

local function test_guide_quickstart()
  local __r12 = check.must(check.must(child.start({cosmic, "--docs", "guide.quickstart"}, {env = clean_env()})):wait())
  local ok, out = __r12.ok, __r12.stdout
  assert(ok, "cosmic --docs guide.quickstart should succeed")
  local s = out
  assert(s:find("Quickstart", 1, true), "quickstart guide should contain Quickstart header")
  assert(s:find("cmd/greet/main.tl", 1, true), "quickstart guide should lay out a binary")
  assert(s:find("--make build", 1, true), "quickstart guide should build the project")
  assert(s:find("--make ci", 1, true), "quickstart guide should run the gate")
end
test_guide_quickstart()

-- There is no guide.makefile: one flag, one guide, and the Makefile
-- generator it would document does not exist. A topic with nothing
-- behind it must fail like any other unknown one -- a guide that still
-- resolves is how a feature nobody ships keeps getting used.
local function test_guide_makefile_is_retired()
  local r = check.must(child.run(
      {cosmic, "--docs", "guide.makefile"}, {env = clean_env()}))
  assert(not r.ok, "guide.makefile should no longer resolve")
  local said = (r.stdout or "") .. (r.stderr or "")
  assert(said:find("unknown guide 'makefile'", 1, true),
    "the miss should name the topic, got: " .. said)
  assert(said:find("\n  make\n", 1, true),
    "the miss should list the guides that do exist, got: " .. said)
end
test_guide_makefile_is_retired()

local function test_guide_modules()
  local __r6 = check.must(check.must(child.start({cosmic, "--docs", "guide.modules"}, {env = clean_env()})):wait())
  local ok, out = __r6.ok, __r6.stdout
  assert(ok, "cosmic --docs guide.modules should succeed")
  local s = out
  assert(s:find("Modules", 1, true), "modules guide should contain Modules header")
  assert(s:find("cosmic.json", 1, true), "modules guide should list cosmic.json")
end
test_guide_modules()

local function test_guide_docs()
  local __r7 = check.must(check.must(child.start({cosmic, "--docs", "guide.docs"}, {env = clean_env()})):wait())
  local ok, out = __r7.ok, __r7.stdout
  assert(ok, "cosmic --docs guide.docs should succeed")
  local s = out
  assert(s:find("Documentation", 1, true), "docs guide should contain Documentation header")
end
test_guide_docs()

local function test_guide_make()
  local __r8 = check.must(check.must(child.start({cosmic, "--docs", "guide.make"}, {env = clean_env()})):wait())
  local ok, out = __r8.ok, __r8.stdout
  assert(ok, "cosmic --docs guide.make should succeed")
  local s = out
  assert(s:find("cosmic %-%-make", 1, false), "make guide should mention cosmic --make")
  assert(s:find("--make check", 1, true), "make guide should document the check verb")
  assert(s:find("import path", 1, true), "make guide should document the project model")
end
test_guide_make()

local function test_guide_platforms()
  local __r10 = check.must(check.must(child.start({cosmic, "--docs", "guide.platforms"}, {env = clean_env()})):wait())
  local ok, out = __r10.ok, __r10.stdout
  assert(ok, "cosmic --docs guide.platforms should succeed")
  local s = out
  assert(s:find("Platform Support", 1, true), "platforms guide should contain Platform Support header")
  assert(s:find("Sandbox Behavior", 1, true), "platforms guide should cover per-OS sandbox behavior")
  assert(s:find("is_absolute", 1, true), "platforms guide should document Windows path handling")
end
test_guide_platforms()

local function test_guide_unknown()
  local r = check.must(child.run(
      {cosmic, "--docs", "guide.nonexistent"}, {env = clean_env()}))
  local ok, code = r.ok, r.code
  assert(not ok, "cosmic --docs guide.nonexistent should fail")
  assert(code == 1, "expected exit code 1, got " .. tostring(code))
end
test_guide_unknown()

local docs = require("cosmic.doc")

local function test_strip_frontmatter_with_frontmatter()
  local input = "---\nname: test\ndescription: A test\n---\n\n# Hello\n"
  local result = docs.strip_frontmatter(input)
  assert(result == "\n# Hello\n", "should strip frontmatter, got: " .. result)
end
test_strip_frontmatter_with_frontmatter()

local function test_strip_frontmatter_without_frontmatter()
  local input = "# Hello\n\nNo frontmatter here.\n"
  local result = docs.strip_frontmatter(input)
  assert(result == input, "should return content unchanged")
end
test_strip_frontmatter_without_frontmatter()

local function test_default_guide_no_frontmatter()
  local __r9 = check.must(check.must(child.start({cosmic, "--docs", "guide"}, {env = clean_env()})):wait())
  local ok, out = __r9.ok, __r9.stdout
  assert(ok, "cosmic --docs guide should succeed")
  local s = out
  assert(not s:match("^---"), "default guide output should not start with frontmatter delimiter")
end
test_default_guide_no_frontmatter()
