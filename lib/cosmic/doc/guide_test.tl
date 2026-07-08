#!/usr/bin/env cosmic
-- test cosmic --docs guide

local fs = require("cosmic.fs")
local cenv = require("cosmic.env")
local spawn = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")

local function clean_env(): {string}
  local env: {string} = {}
  for _, entry in ipairs(cenv.list()) do
    if not entry:match("^LUA_PATH=") and not entry:match("^LUA_CPATH=") then
      env[#env + 1] = entry
    end
  end
  return env
end

local function test_guide_no_topic()
  local __r1 = (spawn.spawn({cosmic, "--docs", "guide"}, {env = clean_env()}) as spawn.Handle):wait() as spawn.Result
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "cosmic --docs guide should succeed")
  local s = out as string
  assert(s:find("cosmic", 1, true), "default guide output should mention cosmic")
  assert(s:find("Quick Reference", 1, true), "default guide output should contain Quick Reference")
end
test_guide_no_topic()

local function test_guide_testing()
  local __r2 = (spawn.spawn({cosmic, "--docs", "guide.testing"}, {env = clean_env()}) as spawn.Handle):wait() as spawn.Result
  local ok, out = __r2.ok, __r2.stdout
  assert(ok, "cosmic --docs guide.testing should succeed")
  local s = out as string
  assert(s:find("Testing", 1, true), "testing guide should contain Testing header")
  assert(s:find("test_", 1, true), "testing guide should show test_ pattern")
end
test_guide_testing()

local function test_guide_checking()
  local __r3 = (spawn.spawn({cosmic, "--docs", "guide.checking"}, {env = clean_env()}) as spawn.Handle):wait() as spawn.Result
  local ok, out = __r3.ok, __r3.stdout
  assert(ok, "cosmic --docs guide.checking should succeed")
  local s = out as string
  assert(s:find("Type Checking", 1, true), "checking guide should contain Type Checking header")
end
test_guide_checking()

local function test_guide_formatting()
  local __r4 = (spawn.spawn({cosmic, "--docs", "guide.formatting"}, {env = clean_env()}) as spawn.Handle):wait() as spawn.Result
  local ok, out = __r4.ok, __r4.stdout
  assert(ok, "cosmic --docs guide.formatting should succeed")
  local s = out as string
  assert(s:find("Formatting", 1, true), "formatting guide should contain Formatting header")
  assert(s:find("2%-space", 1, false), "formatting guide should mention 2-space indent")
end
test_guide_formatting()

local function test_guide_makefile()
  local __r5 = (spawn.spawn({cosmic, "--docs", "guide.makefile"}, {env = clean_env()}) as spawn.Handle):wait() as spawn.Result
  local ok, out = __r5.ok, __r5.stdout
  assert(ok, "cosmic --docs guide.makefile should succeed")
  local s = out as string
  assert(s:find("Makefile", 1, true), "makefile guide should contain Makefile header")
  assert(s:find("cosmic %-%-make", 1, false), "makefile guide should mention cosmic --make")
end
test_guide_makefile()

local function test_guide_modules()
  local __r6 = (spawn.spawn({cosmic, "--docs", "guide.modules"}, {env = clean_env()}) as spawn.Handle):wait() as spawn.Result
  local ok, out = __r6.ok, __r6.stdout
  assert(ok, "cosmic --docs guide.modules should succeed")
  local s = out as string
  assert(s:find("Modules", 1, true), "modules guide should contain Modules header")
  assert(s:find("cosmic.json", 1, true), "modules guide should list cosmic.json")
end
test_guide_modules()

local function test_guide_docs()
  local __r7 = (spawn.spawn({cosmic, "--docs", "guide.docs"}, {env = clean_env()}) as spawn.Handle):wait() as spawn.Result
  local ok, out = __r7.ok, __r7.stdout
  assert(ok, "cosmic --docs guide.docs should succeed")
  local s = out as string
  assert(s:find("Documentation", 1, true), "docs guide should contain Documentation header")
end
test_guide_docs()

local function test_guide_make()
  local __r8 = (spawn.spawn({cosmic, "--docs", "guide.make"}, {env = clean_env()}) as spawn.Handle):wait() as spawn.Result
  local ok, out = __r8.ok, __r8.stdout
  assert(ok, "cosmic --docs guide.make should succeed")
  local s = out as string
  assert(s:find("Makefile", 1, true), "make guide should contain Makefile header")
  assert(s:find("cosmic %-%-make", 1, false), "make guide should mention cosmic --make")
end
test_guide_make()

local function test_guide_unknown()
  local r = spawn.run(
    {cosmic, "--docs", "guide.nonexistent"}, {env = clean_env(), stderr = 1}
  ) as spawn.Result
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
  local __r9 = (spawn.spawn({cosmic, "--docs", "guide"}, {env = clean_env()}) as spawn.Handle):wait() as spawn.Result
  local ok, out = __r9.ok, __r9.stdout
  assert(ok, "cosmic --docs guide should succeed")
  local s = out as string
  assert(not s:match("^---"), "default guide output should not start with frontmatter delimiter")
end
test_default_guide_no_frontmatter()
