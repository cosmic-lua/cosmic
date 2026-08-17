--- Facts: the measurable claims an issue body makes in its ```facts
--- fenced blocks, and the check that they hold. `parse` reads a body
--- into Fact records; `fact_failures` runs each one's command and
--- compares its stdout; `problems` is the one call the ready bar
--- makes, folding a parse error and every failed claim into one list.
--- Parsing is pure — running a command is not, which is why the two
--- halves are named apart even though they live together.
local child = require("cosmic.child")
local str = require("cosmic.string")

--- One measurable claim parsed from a ```facts fenced block: a shell
--- command and the stdout it must produce.
local record Fact
  command: string
  expected: string
end

--- Measurable claims parsed from every ```facts fenced block in a body.
--- Inside such a block, a line starting "$ " begins a command; the
--- following non-"$ " lines, up to the next "$ " line or the fence
--- close, are its expected stdout (joined with "\n", no trailing
--- newline). A body with no facts block returns an empty list. A
--- non-empty line before the first "$ " in a block, or a facts block
--- left unclosed at end of body, is malformed and returns nil plus a
--- message naming the problem and its line.
--- @param body string The spec sidecar's markdown
--- @return {Fact} | nil Parsed facts, possibly empty
--- @return string Error message naming the problem and its line
local function parse(body: string): {Fact} | nil, string
  local normalized = body:gsub("\r\n", "\n")
  local out: {Fact} = {}
  local state = "none" -- "none" | "facts" | "fence"
  local open_line = 0
  local cur: Fact = nil
  local expected: {string} = {}
  local lineno = 0
  for line in (normalized .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    if state == "none" then
      local info = line:match("^```(%S*)%s*$")
      if info == "facts" then
        state = "facts"
        open_line = lineno
      elseif info ~= nil then
        state = "fence"
      end
    elseif state == "fence" then
      if line:match("^```%s*$") then
        state = "none"
      end
    else -- state == "facts"
      if line:match("^```%s*$") then
        if cur then
          cur.expected = table.concat(expected, "\n")
          out[#out + 1] = cur
        end
        state = "none"
        cur = nil
      else
        local command = line:match("^%$%s+(.-)%s*$")
        if command then
          if cur then
            cur.expected = table.concat(expected, "\n")
            out[#out + 1] = cur
          end
          cur = {command = command}
          expected = {}
        elseif cur then
          expected[#expected + 1] = line
        elseif line:match("%S") then
          return nil, ("facts: line %d: content before first $ command"):format(lineno)
        end
      end
    end
  end
  if state == "facts" then
    return nil, ("facts: line %d: unclosed block"):format(open_line)
  end
  return out
end

--- Runs each fact's command IN `root`; trailing whitespace is trimmed
--- from both sides of the comparison before it decides mismatch or
--- match. Exit status is ignored (the expected output IS the
--- assertion); a spawn failure reports the spawn error as the "got"
--- side.
---
--- The root matters because a fact describes the PRODUCT tree —
--- `wc -l < _make/verbs.tl` — while the verb asking it runs from the
--- board worktree, where that path does not exist. Running them
--- anywhere else turns every fact into a false failure.
--- @param facts {Fact} Parsed facts
--- @param root string Directory to run each command in
--- @return {string} One failure line per fact whose output does not match
local function fact_failures(facts: {Fact}, root: string): {string}
  local out: {string} = {}
  for _, f in ipairs(facts) do
    local expected = str.trim_right(f.expected)
    local result, err = child.run({"/bin/sh", "-c", f.command}, {cwd = root})
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

--- Facts problems for a spec: the parse error as a one-item list, or
--- every fact's failure line — the one call `check` and `move ID
--- ready` share.
--- @param body string The spec sidecar's markdown
--- @param root string Directory to run each command in
--- @return {string} Problems, empty when every fact parses and holds
local function problems(body: string, root: string): {string}
  local parsed, ferr = parse(body)
  if parsed == nil then
    return {ferr}
  end
  return fact_failures(parsed, root)
end

local record facts_module
  type Fact = Fact
  parse: function(body: string): {Fact} | nil, string
  fact_failures: function(facts: {Fact}, root: string): {string}
  problems: function(body: string, root: string): {string}
end

local M: facts_module = {
  parse = parse,
  fact_failures = fact_failures,
  problems = problems,
}

return M
