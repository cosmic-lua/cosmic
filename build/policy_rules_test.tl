--- Tests of [`build.policy_rules`]: the rules a `policy` is held to, through both analyzers that apply them: the fork's
--- ([`build.analyzer`]) and the one on the new tree ([`build.syntax_analyzer`]). They answer alike for each case, so the
--- rules stay tested when the switch deletes the fork's.
local Analyzer = require("build.syntax_analyzer")
local PolicyRules = require("build.policy_rules")
local Test = require("cosmic.test")
local analyzer = require("build.analyzer")
local teal = require("build.teal")

Test.policy{}

local built = assert(teal.load(true))

--- A declaration as one line.
local function described(found: PolicyRules.Declared?): string
  if found == nil then
    return "none"
  end
  local declared: PolicyRules.Declared = found
  local function list(values: {string}): string
    return table.concat(values, ",")
  end
  return table.concat({ tostring(declared.line), list(declared.reads), list(declared.host), list(declared.env),
    list(declared.network), tostring(declared.tool), tostring(declared.lua), tostring(declared.nests),
    tostring(declared.noexec), tostring(declared.store), tostring(declared.system), list(declared.caches),
    list(declared.parent or {}), list(declared.requires) }, "|")
end

--- A policy call and, for a refusal, a word its reason holds.
local record Case
  body: string
  refused: string
end

local CASES: {Case} = {
  { body = "Test.policy{}", refused = "" },
  { body = 'Test.policy{ profiles = { "cosmic" } }', refused = "" },
  { body = 'Test.policy{ profiles = { "nope" } }', refused = "no profile nope" },
  { body = 'Test.policy{ isolate = { "net" } }', refused = "isolate" },
  { body = 'Test.policy{ promises = { "nest" } }', refused = "" },
  { body = 'Test.policy{ promises = { "stdio" } }', refused = "no promise stdio" },
  { body = 'Test.policy{ connect = { "a:1" } }', refused = "connect is refused" },
  { body = 'Test.policy{ loopback = { "127.0.0.1" } }', refused = "" },
  { body = 'Test.policy{ loopback = { "localhost" } }', refused = "loopback" },
  { body = 'Test.policy{ loopback = { "127.0.0.256" } }', refused = "loopback" },
  { body = 'Test.policy{ loopback = { "127.00.0.1" } }', refused = "loopback" },
  { body = 'Test.policy{ loopback = { "127.0.0.1:80" } }', refused = "loopback" },
  { body = 'Test.policy{ env = { "HOME" } }', refused = "" },
  { body = 'Test.policy{ env = { "a b" } }', refused = "" },
  { body = 'Test.policy{ env = { "*" } }', refused = "wildcard" },
  { body = 'Test.policy{ requires = { "own_proc" } }', refused = "" },
  { body = 'Test.policy{ set_env = { A = "b" } }', refused = "set_env" },
  { body = 'Test.policy{ set_env_digests = { A = "b" } }', refused = "set_env_digests" },
  { body = 'Test.policy{ grants = { { path = "build", letters = "r" } } }', refused = "" },
  { body = 'Test.policy{ grants = { { path = "../x", letters = "r" } } }', refused = "spell the path plainly" },
  { body = 'Test.policy{ grants = { { path = "/etc/", letters = "r" } } }', refused = "names a directory" },
  { body = 'Test.policy{ grants = { { path = "/etc/hosts", letters = "r" } } }', refused = "" },
  { body = 'Test.policy{ grants = { { path = "x", letters = "rwx", bad = "q" } } }', refused = "has no field bad" },
  { body = 'Test.policy{ grants = { "x" } }', refused = "takes a table" },
  { body = 'Test.policy{ grants = 3 }', refused = "grants takes a list" },
  { body = 'Test.policy{ grants = { { path = "$HOME", letters = "r" } } }', refused = "names a variable" },
  { body = 'Test.policy{ grants = { { path = "a//b", letters = "r" } } }', refused = "spell the path plainly" },
  { body = 'Test.policy{ grants = { { path = "o/cosmic.db", letters = "r" } } }', refused = "" },
  { body = 'Test.policy{ grants = { { path = "/cache/zig", letters = "rwxc" } } }', refused = "" },
  { body = 'Test.policy{ grants = { { path = "/cache/nowhere", letters = "rwxc" } } }', refused = "no cache nowhere" },
  { body = 'Test.policy{ grants = { { path = "/parent/x.txt", letters = "r" } } }', refused = "" },
  { body = 'Test.policy{ grants = { { path = "/parent/", letters = "r" } } }', refused = "names no file" },
  { body = 'Test.policy{ grants = { { path = "o/bin", letters = "rx" } } }', refused = "beside the profile" },
  { body = 'Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }', refused = "" },
  { body = 'Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/cosmic.db", letters = "r" } } }',
    refused = "which is refused beside" },
  { body = 'Test.policy{ limits = { open_files = 3 } }', refused = "limits" },
  { body = 'Test.policy{ limits = { nope = 3 } }', refused = "limits takes open_files" },
  { body = 'Test.policy{ limits = { open_files = "x" } }', refused = "limits takes open_files" },
  { body = 'Test.policy{ limits = 3 }', refused = "limits takes a table" },
  { body = "Test.policy{ tmp = true }", refused = "" },
  { body = "Test.policy{ tmp = false }", refused = "tmp = false" },
  { body = "Test.policy{ tmp = 3 }", refused = "takes true or false" },
  { body = "Test.policy{ user = 3, group = 4 }", refused = "is refused" },
  { body = 'Test.policy{ user = "x" }', refused = "takes a whole number" },
  { body = 'Test.policy{ database = "d" }', refused = "database is refused" },
  { body = "Test.policy{ database = 4 }", refused = "takes a string written out" },
  { body = "Test.policy{ nope = 1 }", refused = "has no field nope" },
  { body = "Test.policy{ env = {}, env = {} }", refused = "declared twice" },
  { body = "Test.policy{ [1] = 2 }", refused = "an entry with no name" },
  { body = 'Test.policy{ "x" }', refused = "an entry with no name" },
  { body = "Test.policy(3)", refused = "hand it one table" },
  { body = "Test.policy()", refused = "hand it one table" },
  { body = 'Test.policy{ env = { "A", "B" }, requires = { "x" } }', refused = "unknown requirement" },
  { body = 'local p = { env = { "A" } }\nTest.policy(p)', refused = "hand it one table" },
  { body = 'Test.policy{ env = { "A" .. "B" } }', refused = "string written out as a literal" },
  { body = 'Test.policy{ env = { "a\\tb" } }', refused = "without escapes" },
  { body = "if true then Test.policy{} end", refused = "at the module's top level" },
  { body = "Test.policy{}\nTest.policy{}", refused = "declares its policy once" },
}

local function test_both_analyzers_apply_the_rules_alike_to_each_policy()
  local accepted, refused = 0, 0
  local wrong: mut {string} = {}
  for _, case in ipairs(CASES) do
    local source = 'local Test = require("cosmic.test")\n' .. case.body .. "\nlocal function test_a() end\n"
    local old, old_why = analyzer.analyze(built, source, "p_test.tl")
    local new, new_why = Analyzer.analyze(source, "p_test.tl")
    if (old == nil) ~= (new == nil) then
      wrong[#wrong + 1] = case.body .. ": " .. tostring(old_why) .. " against " .. tostring(new_why)
    elseif old == nil or new == nil then
      if old_why ~= new_why then
        wrong[#wrong + 1] = case.body .. ": " .. old_why .. " against " .. new_why
      elseif case.refused == "" or old_why:find(case.refused, 1, true) == nil then
        wrong[#wrong + 1] = case.body .. ": refused as " .. old_why
      end
      refused = refused + 1
    else
      if case.refused ~= "" then
        wrong[#wrong + 1] = case.body .. " is accepted"
      elseif described(old.inputs) ~= described(new.inputs) then
        wrong[#wrong + 1] = case.body .. ": " .. described(old.inputs) .. " against " .. described(new.inputs)
      end
      accepted = accepted + 1
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
  -- Neither side is compared empty with empty.
  assert(accepted >= 12 and refused >= 40, accepted .. " accepted, " .. refused .. " refused")
end

local function test_a_policy_is_read_into_the_declaration_it_stands_for()
  local source = 'local Test = require("cosmic.test")\nTest.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" },\n' ..
    '  grants = { { path = "o/bin", letters = "rx" }, { path = "testdata", letters = "r" } }, env = { "HOME" } }\n'
  local found = assert(Analyzer.analyze(source, "p_test.tl"))
  local declared = assert(found.inputs)
  assert(declared.line == 2 and declared.tool and not declared.lua)
  assert(table.concat(declared.reads, ",") == "testdata" and table.concat(declared.network, ",") == "127.0.0.1" and
      table.concat(declared.env, ",") == "HOME")
end

--- A deliberate difference: a source cannot jump, so a policy is never refused for a jump past its call.
local function test_a_goto_past_a_policy_is_a_parse_error()
  local source = 'local Test = require("cosmic.test")\ngoto done\nTest.policy{}\n::done::\n'
  local _, why = Analyzer.analyze(source, "p_test.tl")
  assert(why:find("goto", 1, true) ~= nil, why)
  local old, old_why = analyzer.analyze(built, source, "p_test.tl")
  assert(old == nil and old_why:find("jumps nowhere", 1, true) ~= nil, old_why)
end
