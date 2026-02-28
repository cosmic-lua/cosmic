#!/usr/bin/env cosmic
-- test cosmic --skill option

local path = require("cosmo.path")
local spawn = require("cosmic.child")
local unix = require("cosmo.unix")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")

local function clean_env(): {string}
  local env: {string} = {}
  for _, entry in ipairs(unix.environ()) do
    if not entry:match("^LUA_PATH=") and not entry:match("^LUA_CPATH=") then
      env[#env + 1] = entry
    end
  end
  return env
end

local function test_skill_no_arg()
  local ok, out = spawn.spawn({cosmic, "--skill"}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill should succeed")
  local s = out as string
  assert(s:find("cosmic", 1, true), "default skill output should mention cosmic")
  assert(s:find("Quick Reference", 1, true), "default skill output should contain Quick Reference")
end
test_skill_no_arg()

local function test_skill_testing()
  local ok, out = spawn.spawn({cosmic, "--skill", "testing"}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill testing should succeed")
  local s = out as string
  assert(s:find("Testing", 1, true), "testing skill should contain Testing header")
  assert(s:find("test_", 1, true), "testing skill should show test_ pattern")
end
test_skill_testing()

local function test_skill_checking()
  local ok, out = spawn.spawn({cosmic, "--skill", "checking"}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill checking should succeed")
  local s = out as string
  assert(s:find("Type Checking", 1, true), "checking skill should contain Type Checking header")
end
test_skill_checking()

local function test_skill_formatting()
  local ok, out = spawn.spawn({cosmic, "--skill", "formatting"}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill formatting should succeed")
  local s = out as string
  assert(s:find("Formatting", 1, true), "formatting skill should contain Formatting header")
  assert(s:find("2%-space", 1, false), "formatting skill should mention 2-space indent")
end
test_skill_formatting()

local function test_skill_makefile()
  local ok, out = spawn.spawn({cosmic, "--skill", "makefile"}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill makefile should succeed")
  local s = out as string
  assert(s:find("Makefile", 1, true), "makefile skill should contain Makefile header")
  assert(s:find("cosmic %-%-make", 1, false), "makefile skill should mention cosmic --make")
end
test_skill_makefile()

local function test_skill_modules()
  local ok, out = spawn.spawn({cosmic, "--skill", "modules"}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill modules should succeed")
  local s = out as string
  assert(s:find("Modules", 1, true), "modules skill should contain Modules header")
  assert(s:find("cosmic.json", 1, true), "modules skill should list cosmic.json")
end
test_skill_modules()

local function test_skill_docs()
  local ok, out = spawn.spawn({cosmic, "--skill", "docs"}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill docs should succeed")
  local s = out as string
  assert(s:find("Documentation", 1, true), "docs skill should contain Documentation header")
end
test_skill_docs()

local function test_skill_make()
  local ok, out = spawn.spawn({cosmic, "--skill", "make"}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill make should succeed")
  local s = out as string
  assert(s:find("Makefile", 1, true), "make skill should contain Makefile header")
  assert(s:find("cosmic %-%-make", 1, false), "make skill should mention cosmic --make")
end
test_skill_make()

local function test_skill_unknown()
  local ok, _, code = spawn.spawn({cosmic, "--skill", "nonexistent"}, {env = clean_env(), stderr = 1}):read()
  assert(not ok, "cosmic --skill nonexistent should fail")
  assert(code == 1, "expected exit code 1, got " .. tostring(code))
end
test_skill_unknown()

local handlers = require("cosmic.main_handlers")

local function test_strip_frontmatter_with_frontmatter()
  local input = "---\nname: test\ndescription: A test\n---\n\n# Hello\n"
  local result = handlers.strip_frontmatter(input)
  assert(result == "\n# Hello\n", "should strip frontmatter, got: " .. result)
end
test_strip_frontmatter_with_frontmatter()

local function test_strip_frontmatter_without_frontmatter()
  local input = "# Hello\n\nNo frontmatter here.\n"
  local result = handlers.strip_frontmatter(input)
  assert(result == input, "should return content unchanged")
end
test_strip_frontmatter_without_frontmatter()

local function test_default_skill_no_frontmatter()
  local ok, out = spawn.spawn({cosmic, "--skill"}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill should succeed")
  local s = out as string
  assert(not s:match("^---"), "default skill output should not start with frontmatter delimiter")
end
test_default_skill_no_frontmatter()
