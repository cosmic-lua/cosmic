--- Tests of [`build.policy_rules`]: the rules a `policy` is held to, through the analyzer on the new tree
--- ([`build.syntax_analyzer`]). Each case is a policy call and either a word its refusal holds or the declaration it is read
--- into.
local Analyzer = require("build.syntax_analyzer")
local PolicyRules = require("build.policy_rules")

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
  --- For a policy that is accepted, the declaration it is read into, as `described` spells it.
  inputs: string
end

local CASES: {Case} = {
  { body = "Test.policy{}", refused = "", inputs = "2|||||false|false|false|false|false|false|||" },
  { body = 'Test.policy{ profiles = { "cosmic" } }', refused = "", inputs = "2|||||false|true|false|false|false|false|||" },
  { body = 'Test.policy{ profiles = { "nope" } }', refused = "no profile nope", inputs = "" },
  { body = 'Test.policy{ isolate = { "net" } }', refused = "isolate", inputs = "" },
  { body = 'Test.policy{ promises = { "nest" } }', refused = "", inputs = "2|||||false|false|true|false|false|false|||" },
  { body = 'Test.policy{ promises = { "stdio" } }', refused = "no promise stdio", inputs = "" },
  { body = 'Test.policy{ connect = { "a:1" } }', refused = "connect is refused", inputs = "" },
  { body = 'Test.policy{ loopback = { "127.0.0.1" } }', refused = "", inputs = "2||||127.0.0.1|false|false|false|false|false|false|||" },
  { body = 'Test.policy{ loopback = { "localhost" } }', refused = "loopback", inputs = "" },
  { body = 'Test.policy{ loopback = { "127.0.0.256" } }', refused = "loopback", inputs = "" },
  { body = 'Test.policy{ loopback = { "127.00.0.1" } }', refused = "loopback", inputs = "" },
  { body = 'Test.policy{ loopback = { "127.0.0.1:80" } }', refused = "loopback", inputs = "" },
  { body = 'Test.policy{ env = { "HOME" } }', refused = "", inputs = "2|||HOME||false|false|false|false|false|false|||" },
  { body = 'Test.policy{ env = { "a b" } }', refused = "", inputs = "2|||a b||false|false|false|false|false|false|||" },
  { body = 'Test.policy{ env = { "*" } }', refused = "wildcard", inputs = "" },
  { body = 'Test.policy{ requires = { "own_proc" } }', refused = "", inputs = "2|||||false|false|false|false|false|false|||own_proc" },
  { body = 'Test.policy{ set_env = { A = "b" } }', refused = "set_env", inputs = "" },
  { body = 'Test.policy{ set_env_digests = { A = "b" } }', refused = "set_env_digests", inputs = "" },
  { body = 'Test.policy{ grants = { { path = "build", letters = "r" } } }', refused = "", inputs = "2|build||||false|false|false|false|false|false|||" },
  { body = 'Test.policy{ grants = { { path = "../x", letters = "r" } } }', refused = "spell the path plainly", inputs = "" },
  { body = 'Test.policy{ grants = { { path = "/etc/", letters = "r" } } }', refused = "names a directory", inputs = "" },
  { body = 'Test.policy{ grants = { { path = "/etc/hosts", letters = "r" } } }', refused = "", inputs = "2||/etc/hosts|||false|false|false|false|false|false|||" },
  { body = 'Test.policy{ grants = { { path = "x", letters = "rwx", bad = "q" } } }', refused = "has no field bad", inputs = "" },
  { body = 'Test.policy{ grants = { "x" } }', refused = "takes a table", inputs = "" },
  { body = 'Test.policy{ grants = 3 }', refused = "grants takes a list", inputs = "" },
  { body = 'Test.policy{ grants = { { path = "$HOME", letters = "r" } } }', refused = "names a variable", inputs = "" },
  { body = 'Test.policy{ grants = { { path = "a//b", letters = "r" } } }', refused = "spell the path plainly", inputs = "" },
  { body = 'Test.policy{ grants = { { path = "o/cosmic.db", letters = "r" } } }', refused = "", inputs = "2|||||false|false|false|false|true|false|||" },
  { body = 'Test.policy{ grants = { { path = "/cache/zig", letters = "rwxc" } } }', refused = "", inputs = "2|||||false|false|false|false|false|false|zig||" },
  { body = 'Test.policy{ grants = { { path = "/cache/nowhere", letters = "rwxc" } } }', refused = "no cache nowhere", inputs = "" },
  { body = 'Test.policy{ grants = { { path = "/parent/x.txt", letters = "r" } } }', refused = "", inputs = "2|||||false|false|false|false|false|false||x.txt|" },
  { body = 'Test.policy{ grants = { { path = "/parent/", letters = "r" } } }', refused = "names no file", inputs = "" },
  { body = 'Test.policy{ grants = { { path = "o/bin", letters = "rx" } } }', refused = "beside the profile", inputs = "" },
  { body = 'Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }', refused = "", inputs = "2|||||true|false|false|false|false|false|||" },
  { body = 'Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/cosmic.db", letters = "r" } } }',
    refused = "which is refused beside", inputs = "" },
  { body = 'Test.policy{ limits = { open_files = 3 } }', refused = "limits", inputs = "" },
  { body = 'Test.policy{ limits = { nope = 3 } }', refused = "limits takes open_files", inputs = "" },
  { body = 'Test.policy{ limits = { open_files = "x" } }', refused = "limits takes open_files", inputs = "" },
  { body = 'Test.policy{ limits = 3 }', refused = "limits takes a table", inputs = "" },
  { body = "Test.policy{ tmp = true }", refused = "", inputs = "2|||||false|false|false|false|false|false|||" },
  { body = "Test.policy{ tmp = false }", refused = "tmp = false", inputs = "" },
  { body = "Test.policy{ tmp = 3 }", refused = "takes true or false", inputs = "" },
  { body = "Test.policy{ user = 3, group = 4 }", refused = "is refused", inputs = "" },
  { body = 'Test.policy{ user = "x" }', refused = "takes a whole number", inputs = "" },
  { body = 'Test.policy{ database = "d" }', refused = "database is refused", inputs = "" },
  { body = "Test.policy{ database = 4 }", refused = "takes a string written out", inputs = "" },
  { body = "Test.policy{ nope = 1 }", refused = "has no field nope", inputs = "" },
  { body = "Test.policy{ env = {}, env = {} }", refused = "declared twice", inputs = "" },
  { body = "Test.policy{ [1] = 2 }", refused = "an entry with no name", inputs = "" },
  { body = 'Test.policy{ "x" }', refused = "an entry with no name", inputs = "" },
  { body = "Test.policy(3)", refused = "hand it one table", inputs = "" },
  { body = "Test.policy()", refused = "hand it one table", inputs = "" },
  { body = 'Test.policy{ env = { "A", "B" }, requires = { "x" } }', refused = "unknown requirement", inputs = "" },
  { body = 'local p = { env = { "A" } }\nTest.policy(p)', refused = "hand it one table", inputs = "" },
  { body = 'Test.policy{ env = { "A" .. "B" } }', refused = "string written out as a literal", inputs = "" },
  { body = 'Test.policy{ env = { "a\\tb" } }', refused = "without escapes", inputs = "" },
  { body = "if true then Test.policy{} end", refused = "at the module's top level", inputs = "" },
  { body = "Test.policy{}\nTest.policy{}", refused = "declares its policy once", inputs = "" },
}

local function test_the_analyzer_applies_the_rules_to_each_policy()
  local accepted, refused = 0, 0
  local wrong: mut {string} = {}
  for _, case in ipairs(CASES) do
    local source = 'local Test = require("cosmic.test")\n' .. case.body .. "\nlocal function test_a() end\n"
    local read, why = Analyzer.analyze(source, "p_test.tl")
    if case.refused ~= "" then
      if read ~= nil then
        wrong[#wrong + 1] = case.body .. " is accepted"
      elseif why:find(case.refused, 1, true) == nil then
        wrong[#wrong + 1] = case.body .. ": refused as " .. why .. ", not with " .. case.refused
      end
      refused = refused + 1
    else
      if read == nil then
        wrong[#wrong + 1] = case.body .. ": refused as " .. tostring(why)
      elseif described(read.inputs) ~= case.inputs then
        wrong[#wrong + 1] = case.body .. ": read as " .. described(read.inputs) .. ", not " .. case.inputs
      end
      accepted = accepted + 1
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
  -- Neither side is compared empty with empty.
  assert(accepted >= 12 and refused >= 40, tostring(accepted) .. " accepted, " .. tostring(refused) .. " refused")
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

--- A deliberate difference from the fork, which refused the policy for a jump past its call (it said "jumps nowhere"): a
--- source cannot jump, so it does not parse.
local function test_a_goto_past_a_policy_is_a_parse_error()
  local source = 'local Test = require("cosmic.test")\ngoto done\nTest.policy{}\n::done::\n'
  local _, why = Analyzer.analyze(source, "p_test.tl")
  assert(why:find("goto", 1, true) ~= nil, why)
end
