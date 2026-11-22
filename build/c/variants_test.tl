--- The variants the C check dumps under are the targets and the
--- checked configuration build.zig builds: written out in
--- [`build.c`] because build.zig has no form a program can read them
--- from, held to it here.

local Array = require("cosmic.array")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local c = require("build.c")

Test.policy{
  grants = { { path = "build.zig", letters = "r" } },
}

local function test_the_variants_are_build_zigs_targets()
  local source = assert(Fs.read("build.zig"))
  local block = assert(source:match("const targets = %[_%]Target{(.-)\n};"))
  local n = 0
  for id, name in block:gmatch('%.id = (%d+), %.name = "([^"]+)"') do
    n = n + 1
    local variant = assert(c.variants[n], "no variant for target " .. name)
    assert(variant.name == name and variant.target == name,
      "variant " .. tostring(n) .. " is " .. variant.name .. ", build.zig's is " .. name)
    assert(table.concat(variant.defines, " "):find("COSMIC_TARGET_ID=" .. id, 1, true),
      name .. " does not define its id " .. id)
  end
  assert(n == 3, "build.zig has " .. tostring(n) .. " targets")
  assert(#c.variants == n + 1, "one variant beside the targets, the checked core's")
end

local function test_the_checked_variant_has_the_checked_cores_defines()
  local source = assert(Fs.read("build.zig"))
  local checked = Array.at(c.variants, #c.variants)
  assert(checked.name:find("checked", 1, true))
  local defines = table.concat(checked.defines, " ")
  for _, flag in ipairs({ "-DCOSMIC_CHECKED", "-DLUAI_ASSERT", "-DLUA_USE_APICHECK" }) do
    assert(source:find('"' .. flag .. '"', 1, true), "build.zig does not define " .. flag)
    assert(defines:find(flag, 1, true), "the checked variant does not define " .. flag)
  end
  assert(source:find('.id = 2, .name = "sanitized"', 1, true))
  assert(defines:find("COSMIC_CONFIGURATION_ID=2", 1, true))
end

local function test_the_analyzer_runs_under_build_zigs_own_warnings()
  local source = assert(Fs.read("build.zig"))
  local block = assert(source:match("const own_warnings = %[_%]%[%]const u8{(.-)\n};"))
  local listed: mut {string} = {}
  for flag in block:gmatch('"([^"]+)"') do listed[#listed + 1] = flag end
  assert(table.concat(listed, " ") == table.concat(c.own_warnings, " "),
    "build.zig's own_warnings are " .. table.concat(listed, " "))
end

local function test_the_analyzed_files_are_build_zigs()
  local source = assert(Fs.read("build.zig"))
  local listed: mut {string} = {}
  for flag in assert(source:match("const core_sources = %[_%]%[%]const u8{(.-)\n};")):gmatch('"([^"]+)"') do
    listed[#listed + 1] = flag
  end
  local extra = assert(source:match("fn analyze%(.-const extra = %[_%]%[%]const u8{(.-)};"))
  for flag in extra:gmatch('"([^"]+)"') do listed[#listed + 1] = flag end
  assert(table.concat(listed, " ") == table.concat(c.analyzed, " "), "build.zig analyzes " .. table.concat(listed, " "))
end
