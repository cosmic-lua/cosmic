--- The checker's own source, built the way the seed builds it after the switch: a part of `lang/` is translated
--- into the new grammar ([`lang.translate`]), compiled with `cosmic compile --grammar new`
--- ([`build/compile.tl`]) by [`build/lang_proof.tl`], and the checker's own tests run against the Lua that came out. The subset is the
--- lexer, the modules its tests require and the tests: four files that require one another, one of them a
--- `cosmic.*` module the new checker cannot declare. [`build/lang_proof.tl`] builds and tests the whole of `lang/`
--- the same way, which takes about a minute and is run by hand (doc/plans/strict-teal.md, "the switch"); this holds
--- the pipeline to a subset that fits a test.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Lexer = require("lang.lexer")
local LangProof = require("build.lang_proof")
-- lang.speed, compiled here, requires it.
local _ = require("cosmic.clock")

Test.policy{ grants = { { path = "lang/", letters = "r" } } }

local type LexFn = function(string, string): Lexer.Lexed

--- Translates and compiles the lexer, the modules its tests require and the tests, below `tmp`; answers the stems.
local function built(tmp: string): {string}
  local prepared = LangProof.prepare(".", tmp, { "lexer_test" })
  local compiled = LangProof.build(tmp, prepared.files)
  assert(compiled.code == 0, compiled.complaints)
  -- The checker's source uses the standard library without declaring it here, and [`cosmic.clock`] is a binding
  -- the new checker cannot declare: both are reported, and the Lua is written all the same.
  assert(compiled.complaints:find("lang/speed.tl: ", 1, true), compiled.complaints)
  assert(compiled.complaints:find("the Lua is written anyway", 1, true), compiled.complaints)
  return prepared.files
end

--- A `require` for the compiled modules in `tmp`: a `lang.*` module of `files` is its compiled Lua, run once, and
--- any other name is the tree's own.
local function requiring(tmp: string, files: {string}): function(string): any
  local made: {string: any} = {}
  local real: function(string): any = require
  local env: {string: any} = {}
  local function required(module: string): any
    local stem = module:match("^lang%.(.+)$")
    for _, name in ipairs(files) do
      if stem == name then
        if made[name] == nil then
          local text = (assert(Fs.read(tmp .. "/lua/" .. name .. ".lua")))
          local chunk = assert(load(text, "=" .. name, "t", env))
          made[name] = chunk("lang." .. name)
        end
        return made[name]
      end
    end
    return real(module)
  end
  env["require"] = required
  setmetatable(env, { __index = _G })
  return required
end

local function test_the_lexer_tests_pass_against_the_lexer_the_seed_would_build(tmp: string)
  local files = built(tmp)
  local loaded = requiring(tmp, files)("lang.lexer_test")
  assert(loaded is {string: function()}, "the compiled test module exports no tests")
  local names: {string} = {}
  for name in pairs(loaded) do
    names[#names + 1] = name
  end
  table.sort(names, function(a: string, b: string): boolean
    return a < b
  end)
  assert(#names >= 40, "expected the lexer's tests, found " .. tostring(#names))
  local failures: {string} = {}
  for _, name in ipairs(names) do
    local test = loaded[name]
    if test ~= nil then
      local passed = xpcall(test, function(why: any): any
        failures[#failures + 1] = name .. ": " .. tostring(why)
        return why
      end)
      assert(passed or #failures > 0)
    end
  end
  assert(#failures == 0, table.concat(failures, "\n"))
end

--- The tests above would pass against any lexer that lexed their sources; this holds the compiled one to the
--- tree's on a source that is not theirs: the whole of [`lang/lexer.tl`].
local function test_the_compiled_lexer_gives_the_tokens_the_tree_lexer_gives(tmp: string)
  local files = built(tmp)
  local compiled = requiring(tmp, files)("lang.lexer")
  assert(compiled is {string: any}, "the compiled lexer is no module")
  local lex = compiled["lex"]
  assert(lex is LexFn, "the compiled lexer has no lex")
  local source = (assert(Fs.read(tmp .. "/src/lang/lexer.tl")))
  local mine = lex(source, "lexer.tl")
  local theirs = Lexer.lex(source, "lexer.tl")
  assert(#theirs.tokens.kind > 1000, "expected the tokens of a file")
  assert(#mine.tokens.kind == #theirs.tokens.kind, "the compiled lexer gave another number of tokens")
  assert(#mine.errors == 0 and #theirs.errors == 0, "a lexer refused the source")
  for index, text in ipairs(theirs.tokens.text) do
    assert(mine.tokens.kind[index] == theirs.tokens.kind[index] and mine.tokens.text[index] == text and
        mine.tokens.offset[index] == theirs.tokens.offset[index],
      "token " .. tostring(index) .. " differs: " .. tostring(mine.tokens.text[index]) .. " and " .. text)
  end
end
