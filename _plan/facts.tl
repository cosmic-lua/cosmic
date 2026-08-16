--- The facts effect half: runs a body's parsed model.Fact commands
--- through cosmic.child and reports whether each one's stdout
--- matches. Split out of verbs.tl to keep that file under the
--- line-length gate — the same reason cosmic.child.types holds the
--- shared shapes beside cosmic.child.init instead of inside it.
local child = require("cosmic.child")
local str = require("cosmic.string")
local model = require("_plan.model")

--- Runs each fact's command; trailing whitespace is trimmed from both
--- sides of the comparison before it decides mismatch or match. Exit
--- status is ignored (the expected output IS the assertion); a spawn
--- failure reports the spawn error as the "got" side.
--- @param facts {model.Fact} Parsed facts
--- @return {string} One failure line per fact whose output does not match
local function fact_failures(facts: {model.Fact}): {string}
  local out: {string} = {}
  for _, f in ipairs(facts) do
    local expected = str.trim_right(f.expected)
    local result, err = child.run({"/bin/sh", "-c", f.command})
    local actual: string = err or "spawn failed"
    if result then
      actual = str.trim_right(result.stdout)
    end
    if actual ~= expected then
      out[#out + 1] = ("fact ($%s): expected \"%s\", got \"%s\""):format(
        f.command, expected, actual)
    end
  end
  return out
end

--- Facts problems for an issue body: the parse error as a one-item
--- list, or every fact's failure line — the one call cmd_check and
--- cmd_move's ready branch share.
--- @param body string Issue body markdown
--- @return {string} Problems, empty when every fact parses and holds
local function problems(body: string): {string}
  local parsed, ferr = model.facts(body)
  if parsed == nil then
    return {ferr}
  end
  return fact_failures(parsed)
end

local record facts_module
  fact_failures: function(facts: {model.Fact}): {string}
  problems: function(body: string): {string}
end

local M: facts_module = {
  fact_failures = fact_failures,
  problems = problems,
}

return M
