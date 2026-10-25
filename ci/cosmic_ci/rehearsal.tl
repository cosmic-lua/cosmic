-- The rehearsal's verdict (ci.yml's `rehearsal` job, `platform rehearsal`): the failures of a whole-suite run with the new
-- checker (`COSMIC_GRAMMAR=new`) against the list of failures it is expected to have, testdata/gate/rehearsal.txt. A failure
-- not on the list, and an entry whose failure did not happen, both fail the job, so the list only shrinks: it reaches
-- nothing at the switch (doc/plans/strict-teal.md, "the switch").

local record Rehearsal
  --- The path of the list below the checkout's root.
  path: function(): string

  --- The entries of the list `text`: a failure's name to why it is expected. A line is `<name> -- <reason>`; a blank line and a
  --- line that starts with `#` say nothing. nil and what is wrong with the text: an entry with no reason or a name that two
  --- entries give.
  parse: function(text: string): {string: string}?, string

  --- The name of each failure the output of a run lists, once each, in order. A line `test: FAIL  <failure>` names the test
  --- (`<module> <test>`) or the module the new checker refused (`<file> <code>`, the code of its first error, none for a
  --- module not compiled for requiring a refused one) or the C function no test entered (`<file>:<function>`): the words up to
  --- the first `: `, less the line and column a refusal says.
  failures: function(output: string): {string}

  --- What is wrong between `failed` and the list `allowed`, one line each: a failure the list does not hold, and an entry
  --- whose failure did not happen. None when the run is what the list says.
  judge: function(allowed: {string: string}, failed: {string}): {string}

  --- The projects of the rehearsal, testdata/rehearsal/<name>: `project` is written in Teal both checkers read and passes with
  --- the new checker, `fork_only` in forms only the fork reads and is refused with the new checker's words and fix.
  projects: function(): {string}

  --- What is wrong with the run of the project `name` (`cosmic test` in a copy of it with `COSMIC_GRAMMAR=new`) that ended
  --- with `status` and said `output`, one line each. None when the run is what the project is for.
  judge_project: function(name: string, status: integer, output: string): {string}

  --- What is wrong with a run of the suite on the tool the rehearsal booted with the new checker, whose `output` and
  --- `errors` (what it said on stderr) are given: a tool built again by the run is no run on the tool that was booted.
  judge_tool: function(output: string, errors: string): {string}
end

local PATH <const> = "testdata/gate/rehearsal.txt"

function Rehearsal.path(): string
  return PATH
end

function Rehearsal.parse(text: string): {string: string}?, string
  local out: mut {string: string} = {}
  local number = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local name, reason = line:match("^(%S.-) %-%- (%S.*)$")
      if name == nil or reason == nil then
        return nil, PATH .. ":" .. tostring(number) .. ": expected `<failure> -- <reason>`, not `" .. line .. "`"
      end
      if out[name] ~= nil then
        return nil, PATH .. ":" .. tostring(number) .. ": `" .. name .. "` is listed twice"
      end
      out[name] = reason
    end
  end
  return out, ""
end

-- TODO: name a failed test by the head of its message too, so that it stays expected for its reason alone as a refused file
-- does, once `cosmic test` prints a failure's reason on a line of its own that does not carry a path or a number
-- (build/test_report.tl); a test is expected by name today.
function Rehearsal.failures(output: string): {string}
  local out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  local rows: mut {string} = {}
  for line in output:gmatch("[^\n]+") do
    rows[#rows + 1] = line
  end
  for at, line in ipairs(rows) do
    local head = line:match("^test: FAIL  (.*)$")
    if head ~= nil then
      local name = head:match("^(.-): ") or head
      name = name:gsub(":%d+:%d+$", "")
      -- A file the new checker refused is named with the code of its first error, so that it stays expected for the reason
      -- listed and no other: the code is in the head, or in the line after "the compiler refused it".
      if not name:find("[ :]") then
        local code = head:match("%(([%a][%w_]*)%): ") or ""
        local following = rows[at + 1]
        if code == "" and head:find(": the compiler refused it", 1, true) ~= nil and following ~= nil then
          code = following:match("%(([%a][%w_]*)%): ") or ""
        end
        if code ~= "" then
          name = name .. " " .. code
        end
      end
      if seen[name] ~= true then
        seen[name] = true
        out[#out + 1] = name
      end
    end
  end
  return out
end

function Rehearsal.projects(): {string}
  return { "project", "fork_only" }
end

--- Words a project's run must say, and why.
local record Says
  words: string
  why: string
end

--- The words each project's run must say.
local PROJECT_SAYS <const>: {string: {Says}} = {
  project = {
    { words = "test: 3 tests passed in 2 modules", why = "its 3 tests in 2 modules passed" },
  },
  fork_only = {
    { words = "lookup.tl:10:12: nil is given as return value 1, where `Entry` is wanted (nil_not_allowed): give a value, or " ..
        "declare what takes it `Entry?`", why = "the error of nil given where a type does not hold it, with the fix" },
    { words = "cache.tl:8:1: `function Kv.Lru.get` has more than one dot (function_path): assign the function to the field: " ..
        "`Kv.Lru.get = function(...) ... end`", why = "the error of a function assigned to a path of two dots, with the fix" },
    { words = "lookup_test.tl: not compiled: it requires lookup, which the new checker refused",
      why = "what requires a refused module is told so" },
    { words = "test: 4 of 4 tests failed", why = "the run is refused whole" },
  },
}

function Rehearsal.judge_project(name: string, status: integer, output: string): {string}
  local out: mut {string} = {}
  local says = PROJECT_SAYS[name]
  if says == nil then
    return { name .. ": no such project of the rehearsal" }
  end
  if name == "project" and status ~= 0 then
    out[#out + 1] = name .. ": exit " .. tostring(status) .. ", not 0: a project of Teal both checkers read passes with the new checker"
  elseif name ~= "project" and status ~= 1 then
    out[#out + 1] = name .. ": exit " .. tostring(status) .. ", not 1: a project of forms only the fork reads is refused"
  end
  for _, one in ipairs(says) do
    if output:find(one.words, 1, true) == nil then
      out[#out + 1] = name .. ": the run does not say " .. one.why .. " (`" .. one.words .. "`)"
    end
  end
  if name ~= "project" then
    -- a project has no pins to raise, and its errors speak of none
    for _, word in ipairs({ "pinned", "ceilings.txt" }) do
      if output:find(word, 1, true) ~= nil then
        out[#out + 1] = name .. ": an error of a project speaks of `" .. word .. "`, which it has none of"
      end
    end
  end
  return out
end

function Rehearsal.judge_tool(output: string, errors: string): {string}
  local out: mut {string} = {}
  for _, said in ipairs({ "the tool is stale; rebuilding it", "building it again", "bin/zig build boot" }) do
    if output:find(said, 1, true) ~= nil or errors:find(said, 1, true) ~= nil then
      out[#out + 1] = "the run built the tool again (`" .. said .. "`): the tool booted with the new checker was not settled for " ..
        "a run that asks for it, and the suite ran on another tool"
    end
  end
  return out
end

function Rehearsal.judge(allowed: {string: string}, failed: {string}): {string}
  local out: mut {string} = {}
  local happened: mut {string: boolean} = {}
  for _, name in ipairs(failed) do
    happened[name] = true
    if allowed[name] == nil then
      out[#out + 1] = name .. " failed and " .. PATH .. " does not expect it: fix it, or list it with its reason"
    end
  end
  local names: mut {string} = {}
  for name in pairs(allowed) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    if happened[name] ~= true then
      out[#out + 1] = name .. " is listed in " .. PATH .. " and did not fail: remove the entry"
    end
  end
  return out
end

return Rehearsal
