--- The tables of counts a test of the checks gives them ([`Ceilings.Table`]'s `stages`): the file of the tree holds no row
--- ([`Ceilings.parse`] refuses one), but [`Ceilings.over`] still judges a count a caller passes, and these tests hold it to
--- the words it tells them in.
local Ceilings = require("build.ceilings")

local record ceilings_fixture
  --- The table `text` holds, a section per stage (`[checked]`) of lines `<file> <code> <count>` (`<file> <count>` under
  --- `[untyped]`), with no stage held by markers. A line of any other shape is an error of the test.
  rows: function(text: string): Ceilings.Table
end

function ceilings_fixture.rows(text: string): Ceilings.Table
  local stages: mut {string: {string: integer}} = {}
  local opened_by: mut {string: mut {string: integer}} = {}
  local held: mut {string: integer}? = nil
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local name = line:match("^%[([a-z]+)%]$")
    if name ~= nil then
      local opened: mut {string: integer} = opened_by[name] or {}
      opened_by[name] = opened
      stages[name] = opened
      held = opened
    elseif line ~= "" and line:sub(1, 1) ~= "#" then
      local key, count = line:match("^(%S.-)%s+(%d+)$")
      assert(key ~= nil and count ~= nil and held ~= nil, "a row of a test is `<file> <code> <count>` under a stage: " .. line)
      held[key] = assert(math.tointeger(tonumber(count)))
    end
  end
  return { stages = stages, none = nil, marked = {} }
end

return ceilings_fixture
