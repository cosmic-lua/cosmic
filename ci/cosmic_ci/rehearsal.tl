-- The rehearsal's verdict (ci.yml's `rehearsal` job, `platform rehearsal`): the failures of a whole-suite run with the new
-- checker (`COSMIC_GRAMMAR=new`) against the list of failures it is expected to have, testdata/gate/rehearsal.txt. A failure
-- not on the list, and an entry whose failure did not happen, both fail the job, so the list only shrinks: it reaches
-- nothing at the switch (doc/plans/strict-teal.md, "the switch").

local record Rehearsal
  --- The path of the list below the checkout's root.
  path: string

  --- The entries of the list `text`: a failure's name to why it is expected. A line is `<name> -- <reason>`; a blank line and a
  --- line that starts with `#` say nothing. nil and what is wrong with the text: an entry with no reason or a name that two
  --- entries give.
  parse: function(text: string): {string: string} | nil, string

  --- The name of each failure the output of a run lists, once each, in order. A line `test: FAIL  <failure>` names the test
  --- (`<module> <test>`) or the module the new checker refused (`<file> <code>`, the code of its first error, none for a
  --- module not compiled for requiring a refused one) or the C function no test entered (`<file>:<function>`): the words up to
  --- the first `: `, less the line and column a refusal says.
  failures: function(output: string): {string}

  --- What is wrong between `failed` and the list `allowed`, one line each: a failure the list does not hold, and an entry
  --- whose failure did not happen. None when the run is what the list says.
  judge: function(allowed: {string: string}, failed: {string}): {string}
end

Rehearsal.path = "testdata/gate/rehearsal.txt"

function Rehearsal.parse(text: string): {string: string} | nil, string
  local out: {string: string} = {}
  local number = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local name, reason = line:match("^(%S.-) %-%- (%S.*)$")
      if name == nil or reason == nil then
        return nil, Rehearsal.path .. ":" .. tostring(number) .. ": expected `<failure> -- <reason>`, not `" .. line .. "`"
      end
      if out[name] ~= nil then
        return nil, Rehearsal.path .. ":" .. tostring(number) .. ": `" .. name .. "` is listed twice"
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
  local out: {string} = {}
  local seen: {string: boolean} = {}
  local rows: {string} = {}
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
        if code == "" and head:find(": the compiler refused it", 1, true) ~= nil and rows[at + 1] ~= nil then
          code = rows[at + 1]:match("%(([%a][%w_]*)%): ") or ""
        end
        if code ~= "" then
          name = name .. " " .. code
        end
      end
      if not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
  end
  return out
end

function Rehearsal.judge(allowed: {string: string}, failed: {string}): {string}
  local out: {string} = {}
  local happened: {string: boolean} = {}
  for _, name in ipairs(failed) do
    happened[name] = true
    if allowed[name] == nil then
      out[#out + 1] = name .. " failed and " .. Rehearsal.path .. " does not expect it: fix it, or list it with its reason"
    end
  end
  local names: {string} = {}
  for name in pairs(allowed) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    if not happened[name] then
      out[#out + 1] = name .. " is listed in " .. Rehearsal.path .. " and did not fail: remove the entry"
    end
  end
  return out
end

return Rehearsal
