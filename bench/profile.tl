--- The functions a profile spent its samples in: `bin/cosmic bench/profile.tl <file>... [--top N]`, over the files a run
--- with `COSMIC_PROFILE=<path>` wrote (`<path>.<pid>`, one a process; core/profile.h). It prints the functions with the
--- most samples of their own (the innermost frame), then those with the most samples in their stack (counted once a
--- stack, so a recursive function is not counted twice). A sample is a count of Lua instructions, so time spent in C
--- (a SQLite step, a string search) is not seen.
local Stream = require("cosmic.stream")

local own: mut {string: integer} = {}
local within: mut {string: integer} = {}
local total = 0
local top = 40

local files: mut {string} = {}
local i = 1
while i <= #arg do
  local a = arg[i] or ""
  if a == "--top" then
    top = math.tointeger(tonumber(arg[i + 1] or "")) or error("--top takes a whole number")
    i = i + 2
  else
    files[#files + 1] = a
    i = i + 1
  end
end
if #files == 0 then
  error("usage: bin/cosmic bench/profile.tl <file>... [--top N]", 0)
end

for _, path in ipairs(files) do
  local reader, why = Stream.open(path)
  if reader == nil then error(tostring(why)) end
  for line in Stream.lines(reader, 1 << 20):each() do
    local stack, count_text = line:match("^(.*) (%d+)$")
    if stack ~= nil and count_text ~= nil then
      local count = math.tointeger(tonumber(count_text)) or 0
      total = total + count
      local seen: mut {string: boolean} = {}
      local last = ""
      for frame in stack:gmatch("[^;]+") do
        if seen[frame] == nil then
          seen[frame] = true
          within[frame] = (within[frame] or 0) + count
        end
        last = frame
      end
      own[last] = (own[last] or 0) + count
    end
  end
end

local function report(counts: {string: integer}, label: string)
  local names: mut {string} = {}
  for name in pairs(counts) do names[#names + 1] = name end
  table.sort(names, function(a: string, b: string): boolean
    local x, y = counts[a] or 0, counts[b] or 0
    if x ~= y then return x > y end
    return a < b
  end)
  print(label .. ", of " .. tostring(total) .. " samples:")
  for n = 1, math.min(top, #names) do
    local name = names[n] or ""
    print(string.format("%6.2f%%  %s", 100 * (counts[name] or 0) / math.max(total, 1), name))
  end
end

report(own, "own")
report(within, "in the stack")
