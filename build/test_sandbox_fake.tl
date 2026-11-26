--- The fake of the test sandbox tests (those of
--- build/test_sandbox_fixture.tl), placed at a suite's bin/probe and run
--- as a [`cosmic.fake`] main by the tests a nested `cosmic test` runs.
--- Its first argument names the case and the rest are that case's words.

local Env = require("cosmic.env")
local Steps = require("cosmic.fake.steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  -- Ends with status `words[1]`, or 2 where it names none.
  exit = function(words: {string}): integer return math.tointeger(tonumber(words[1] or "")) or 2 end,
  -- What of the suite's files and the worker's environment it sees:
  -- data.txt and secret.txt where they read, then
  -- `/<DECLARED_VAR>/<UNDECLARED_VAR>`, each empty where unset.
  view = function(_: {string}): integer
    return Steps.cat_quiet("suite/data.txt") or Steps.cat_quiet("suite/secret.txt") or
      Steps.print("/" .. (Env.get("DECLARED_VAR") or "") .. "/" .. (Env.get("UNDECLARED_VAR") or "")) or 0
  end,
  -- Reads data.txt, then later.txt, or says `|absent` where it cannot.
  ["child-reads"] = function(_: {string}): integer
    local stopped = Steps.cat("suite/data.txt")
    if stopped ~= nil then return stopped end
    if Steps.attempt(function(): integer? return Steps.cat("suite/later.txt") end) then return 0 end
    return Steps.print("|absent") or 0
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("test sandbox fake", cases, argv)
end

return main
