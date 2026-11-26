--- The functions a profile spent its time in: `bin/cosmic bench/profile.tl <file>... [--top N]`, over the files a run
--- with `COSMIC_PROFILE=<dir>` wrote (`<dir>/<pid>.prof`, one a process; core/profile.h). It prints the functions with
--- the most time of their own (the innermost frame, a C function included), then those with the most time in their
--- stack (counted once a stack, so a recursive function is not counted twice), then the lines. The spans, each under
--- the span it stood in, come first.
local Stream = require("cosmic.stream")

local own: mut {string: integer} = {}
local within: mut {string: integer} = {}
local lines: mut {string: integer} = {}
--- Each span path's totals, over every file.
local record SpanTotal
  mut count: integer
  mut wall_ns: integer
  mut cpu_ns: integer
end
local spans: mut {string: SpanTotal} = {}
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
    local span_path, n, wall, cpu = line:match("^span ([^ ]+) (%d+) (%d+) (%d+)$")
    if span_path ~= nil and n ~= nil and wall ~= nil and cpu ~= nil then
      local t = spans[span_path] or { count = 0, wall_ns = 0, cpu_ns = 0 }
      t.count = t.count + (math.tointeger(tonumber(n)) or 0)
      t.wall_ns = t.wall_ns + (math.tointeger(tonumber(wall)) or 0)
      t.cpu_ns = t.cpu_ns + (math.tointeger(tonumber(cpu)) or 0)
      spans[span_path] = t
    end
    local stack, at, count_text = line:match("^sample ([^ ]+) ([^ ]+) (%d+)$")
    if stack ~= nil and at ~= nil and count_text ~= nil then
      lines[at] = (lines[at] or 0) + (math.tointeger(tonumber(count_text)) or 0)
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
  print(label .. ", of " .. string.format("%.1f", total / 1000) .. " ms sampled:")
  for n = 1, math.min(top, #names) do
    local name = names[n] or ""
    print(string.format("%6.2f%% %10.1f ms  %s", 100 * (counts[name] or 0) / math.max(total, 1),
      (counts[name] or 0) / 1000, name))
  end
end

local paths: mut {string} = {}
for path in pairs(spans) do paths[#paths + 1] = path end
table.sort(paths)
if #paths > 0 then print("spans (count, wall, cpu):") end
for _, path in ipairs(paths) do
  local t = assert(spans[path])
  local _, depth = path:gsub(";", "")
  print(string.format("%s%s  %d  %.1f ms  %.1f ms", ("  "):rep(depth), path:match("([^;]+)$") or path, t.count,
    t.wall_ns / 1000000, t.cpu_ns / 1000000))
end
report(own, "own")
report(within, "in the stack")
report(lines, "lines")
