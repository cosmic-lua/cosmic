--- The right answers of the eval tasks that count, list or hash the cosmic tree, from cosmic's own stdlib alone: no
--- shell, awk, sed or jq. `truth.tl NAME [DATA]` runs from the root of the tree and prints what the task wants, with
--- the same lines the pipelines it replaces printed. `DATA` is the file the MCP and web tasks serve, as tab-separated
--- lines.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")

local record Row
  n: integer
  name: string
end

local record Found
  line: integer
  name: string
end

local record Dir
  name: string
  files: integer
  lines: integer
end

local function text_of(path: string): string
  return assert(Fs.read(path))
end

local function lines_of(text: string): {string}
  local out: mut {string} = {}
  local at = 1
  while at <= #text do
    local stop = text:find("\n", at, true)
    if stop == nil then
      out[#out + 1] = text:sub(at)
      break
    end
    out[#out + 1] = text:sub(at, stop - 1)
    at = stop + 1
  end
  return out
end

local function is_test(path: string): boolean
  return path:match("_test%.tl$") ~= nil
end

--- The `.tl` files under `root`, as `find root -name '*.tl' -type f`, sorted, with `root/` in front.
local function sources(root: string, deep: boolean): {string}
  local out: mut {string} = {}
  for _, path in ipairs(assert(Fs.walk(root))) do
    if path:match("%.tl$") ~= nil and (deep or path:find("/", 1, true) == nil) then
      out[#out + 1] = root .. "/" .. path
    end
  end
  return out
end

local function plain(path: string): boolean
  return not is_test(path)
end

local function only(paths: {string}, keep: function(string): boolean): {string}
  local out: mut {string} = {}
  for _, path in ipairs(paths) do
    if keep(path) then out[#out + 1] = path end
  end
  return out
end

--- Rows by count, most first, then by name.
local function ranked(rows: {Row}, most?: integer): {Row}
  local sorted: mut {Row} = {}
  for _, row in ipairs(rows) do sorted[#sorted + 1] = row end
  table.sort(sorted, function(a: Row, b: Row): boolean
    if a.n ~= b.n then return a.n > b.n end
    return a.name < b.name
  end)
  local out: mut {Row} = {}
  for i, row in ipairs(sorted) do
    if most ~= nil and i > most then break end
    out[#out + 1] = row
  end
  return out
end

local function show(rows: {Row})
  for _, row in ipairs(rows) do print(tostring(row.n) .. " " .. row.name) end
end

local function count_lines(text: string): integer
  local n = 0
  for _ in text:gmatch("\n") do n = n + 1 end
  return n
end

--- The distinct `require("cosmic.<...>")` module names of a text, or all of them with their repeats.
local function required(text: string): {string}
  local out: mut {string} = {}
  for name in text:gmatch('require%("(cosmic%.[^"]*)"%)') do out[#out + 1] = name end
  return out
end

local function distinct(names: {string}): {string}
  local seen: mut {string: boolean} = {}
  local out: mut {string} = {}
  for _, name in ipairs(names) do
    if seen[name] == nil then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local function counted(names: {string}): {Row}
  local n: mut {string: integer} = {}
  for _, name in ipairs(names) do n[name] = (n[name] or 0) + 1 end
  local out: mut {Row} = {}
  for name, count in pairs(n) do out[#out + 1] = { n = count, name = name } end
  return out
end

local function word(text: string, name: string): boolean
  return text:find("%f[%w_]" .. name .. "%f[^%w_]") ~= nil
end

--- The text with each whole-word `name` in place, as `sed 's/\<name\>/with/g'`.
local function replaced(text: string, name: string, with: string): string
  return (text:gsub("%f[%w_]" .. name .. "%f[^%w_]", with))
end

local function hashed(text: string)
  print(Hash.hex_sha256(text))
end

--- The line number and text of each local function whose line before is no `---` doc line.
local function undocumented_of(text: string): {Found}
  local out: mut {Found} = {}
  local previous = ""
  for number, line in ipairs(lines_of(text)) do
    local name = line:match("^local function ([A-Za-z_][A-Za-z0-9_]*)%(")
    if name ~= nil and previous:sub(1, 3) ~= "---" then
      out[#out + 1] = { line = number, name = name }
    end
    previous = line
  end
  return out
end

local tasks: mut {string: function(string?)} = {}

tasks["largest"] = function()
  local rows: mut {Row} = {}
  for _, path in ipairs(sources("cosmic", true)) do
    rows[#rows + 1] = { n = count_lines(text_of(path)), name = path }
  end
  show(ranked(rows, 5))
end

tasks["todos"] = function()
  for _, path in ipairs(sources("cosmic", true)) do
    for number, line in ipairs(lines_of(text_of(path))) do
      if line:find("TODO", 1, true) ~= nil then print(path .. ":" .. tostring(number)) end
    end
  end
end

tasks["requires"] = function()
  local rows: mut {Row} = {}
  for _, path in ipairs(only(sources("cosmic/agent", true), plain)) do
    rows[#rows + 1] = { n = #distinct(required(text_of(path))), name = path }
  end
  show(ranked(rows, 3))
end

tasks["tests"] = function()
  local rows: mut {Row} = {}
  for _, path in ipairs(only(sources("cosmic/agent", true), is_test)) do
    local n = 0
    for _, line in ipairs(lines_of(text_of(path))) do
      if line:sub(1, 20) == "local function test_" then n = n + 1 end
    end
    rows[#rows + 1] = { n = n, name = path }
  end
  -- Most tests first, then the path: the count and the name sort the other way round in the old pipeline's keys.
  table.sort(rows, function(a: Row, b: Row): boolean
    if a.n ~= b.n then return a.n > b.n end
    return a.name < b.name
  end)
  for _, row in ipairs(rows) do print(row.name .. " " .. tostring(row.n)) end
end

tasks["undocumented"] = function()
  for _, path in ipairs(only(sources("cosmic/agent", true), plain)) do
    for _, found in ipairs(undocumented_of(text_of(path))) do
      print(path .. ":" .. tostring(found.line) .. " " .. found.name)
    end
  end
end

tasks["fan-in"] = function()
  local files = sources("cosmic", true)
  local texts: mut {string: string} = {}
  for _, path in ipairs(files) do texts[path] = text_of(path) end
  local rows: mut {Row} = {}
  for _, own in ipairs(only(sources("cosmic", false), plain)) do
    local module = own:match("([^/]*)%.tl$") or ""
    local needle = 'require("cosmic.' .. module .. '")'
    local n = 0
    for _, path in ipairs(files) do
      if path ~= own and (texts[path] or ""):find(needle, 1, true) ~= nil then n = n + 1 end
    end
    rows[#rows + 1] = { n = n, name = "cosmic." .. module }
  end
  show(ranked(rows, 10))
end

tasks["two-hop"] = function()
  local rows: mut {Row} = {}
  for _, module in ipairs(distinct(required(text_of("cosmic/agent/init.tl")))) do
    local base = "cosmic/" .. module:sub(#"cosmic." + 1):gsub("%.", "/")
    local path = base .. ".tl"
    local found, _ = Fs.stat(path)
    if found == nil then path = base .. "/init.tl" end
    rows[#rows + 1] = { n = count_lines(text_of(path)), name = module }
  end
  show(ranked(rows))
end

tasks["rename-many"] = function()
  local text: mut {string} = {}
  for _, path in ipairs(sources("cosmic", true)) do
    local body = text_of(path)
    if word(body, "MAX_BYTES") then
      text[#text + 1] = path .. "\n" .. replaced(body, "MAX_BYTES", "BYTES_MOST")
    end
  end
  if #text > 0 then hashed(table.concat(text)) end
end

tasks["sqlite"] = function()
  print("SQLite format 3")
  local files: mut {string: integer} = {}
  local lines: mut {string: integer} = {}
  for _, path in ipairs(sources("cosmic", true)) do
    local directory = path:match("^(.*)/[^/]*$") or path
    files[directory] = (files[directory] or 0) + 1
    lines[directory] = (lines[directory] or 0) + count_lines(text_of(path))
  end
  local rows: mut {Dir} = {}
  for directory, n in pairs(files) do
    rows[#rows + 1] = { name = directory, files = n, lines = lines[directory] or 0 }
  end
  table.sort(rows, function(a: Dir, b: Dir): boolean
    if a.lines ~= b.lines then return a.lines > b.lines end
    return a.name < b.name
  end)
  for i, row in ipairs(rows) do
    if i > 10 then break end
    print(row.name .. " " .. tostring(row.files) .. " " .. tostring(row.lines))
  end
end

tasks["hashes"] = function()
  for _, path in ipairs(assert(Fs.walk("doc/guides"))) do
    if path:find("/", 1, true) == nil and path:match("%.md$") ~= nil then
      print(Hash.hex_sha256(text_of("doc/guides/" .. path)) .. "  doc/guides/" .. path)
    end
  end
end

tasks["rename"] = function()
  local body = text_of("cosmic/agent/tools.tl")
  if body:find("MAX_LINES", 1, true) ~= nil then hashed((body:gsub("MAX_LINES", "MOST_LINES"))) end
end

tasks["imports"] = function()
  local names: mut {string} = {}
  for _, path in ipairs(sources("cosmic/agent", true)) do
    for _, name in ipairs(required(text_of(path))) do names[#names + 1] = name end
  end
  show(ranked(counted(names), 5))
end

tasks["header"] = function()
  local body = text_of("cosmic/agent/tools.tl")
  if body:sub(1, 3) ~= "---" then return end
  local out: mut {string} = {}
  local heading = true
  for _, line in ipairs(lines_of(body)) do
    if heading and line:sub(1, 3) == "---" then
      -- dropped
    else
      if heading then out[#out + 1] = "--- The tools of cosmic agent." end
      heading = false
      out[#out + 1] = line
    end
  end
  hashed(table.concat(out, "\n") .. "\n")
end

--- The tab-separated lines of the data file, as fields.
local function records(data: string?): {{string}}
  local out: mut {{string}} = {}
  for _, line in ipairs(lines_of(text_of(assert(data)))) do
    local fields: mut {string} = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
    out[#out + 1] = fields
  end
  return out
end

local function sums_by(data: string?, key: integer, amount: function({string}): integer): {Row}
  local totals: mut {string: integer} = {}
  for _, fields in ipairs(records(data)) do
    local name = fields[key] or ""
    totals[name] = (totals[name] or 0) + amount(fields)
  end
  local out: mut {Row} = {}
  for name, n in pairs(totals) do out[#out + 1] = { n = n, name = name } end
  return ranked(out)
end

local function stock_value(fields: {string}): integer
  return (math.tointeger(tonumber(fields[4]) or 0) or 0) * (math.tointeger(tonumber(fields[5]) or 0) or 0)
end

local function low_stock(data: string?)
  local ids: mut {string} = {}
  for _, fields in ipairs(records(data)) do
    if (tonumber(fields[5]) or 0) < 3 then
      ids[#ids + 1] = (fields[1] or "") .. " " .. (fields[5] or "")
    end
  end
  table.sort(ids)
  for _, line in ipairs(ids) do print(line) end
end

tasks["mcp-value"] = function(data: string?) show(sums_by(data, 3, stock_value)) end
tasks["mcp-many-value"] = function(data: string?) show(sums_by(data, 3, stock_value)) end
tasks["mcp-low"] = low_stock
tasks["mcp-many-low"] = low_stock
tasks["web-low"] = low_stock

tasks["web-csv"] = function(data: string?)
  show(sums_by(data, 2, function(fields: {string}): integer
    return math.tointeger(tonumber(fields[3]) or 0) or 0
  end))
end

tasks["earlier-log"] = function(data: string?)
  local names: mut {string} = {}
  for _, line in ipairs(lines_of(text_of(assert(data)))) do
    local level, name = line:match("^%S+%s+(%S+)%s+(%S+)")
    if level == "ERROR" and name ~= nil then names[#names + 1] = name end
  end
  show(ranked(counted(names)))
end

tasks["docedit"] = function()
  local body = text_of("cosmic/compress.tl")
  local out: mut {string} = {}
  local previous = ""
  local n = 0
  for _, line in ipairs(lines_of(body)) do
    if line:match("^local function [A-Za-z_][A-Za-z0-9_]*%(") ~= nil and previous:sub(1, 3) ~= "---" then
      out[#out + 1] = "--- TODO: say what this does."
      n = n + 1
    end
    out[#out + 1] = line
    previous = line
  end
  if n > 0 then hashed(table.concat(out, "\n") .. "\n") end
end

tasks["json-legs"] = function()
  local capabilities = assert(Json.decode_object(text_of("ci/cosmic_ci/capabilities.json")))
  local legs = Json.object_of(capabilities["legs"]) or {}
  local rows: mut {Row} = {}
  for name, members in pairs(legs) do
    local n = 0
    for _, member in ipairs(Json.array_of(members) or {}) do
      local text = Json.string_of(member)
      if text ~= nil and text:sub(1, 8) == "program:" then n = n + 1 end
    end
    rows[#rows + 1] = { n = n, name = name }
  end
  show(ranked(rows))
end

tasks["error-lines"] = function()
  for _, path in ipairs(only(sources("cosmic/agent", false), plain)) do
    for number, line in ipairs(lines_of(text_of(path))) do
      if line:find("error(", 1, true) ~= nil then print(path .. ":" .. tostring(number)) end
    end
  end
end

tasks["append-many"] = function()
  local text: mut {string} = {}
  for _, path in ipairs(only(sources("cosmic/agent", false), plain)) do
    text[#text + 1] = path .. "\n" .. text_of(path) .. "-- end\n"
  end
  hashed(table.concat(text))
end

tasks["tested-modules"] = function()
  local tests: mut {string} = {}
  for _, path in ipairs(assert(Fs.walk("cosmic/agent"))) do
    if path:find("/", 1, true) == nil and is_test(path) then
      tests[#tests + 1] = text_of("cosmic/agent/" .. path)
    end
  end
  local rows: mut {Row} = {}
  for _, module in ipairs(distinct(required(text_of("cosmic/agent/host.tl")))) do
    local needle = 'require("' .. module .. '")'
    local n = 0
    for _, body in ipairs(tests) do
      if body:find(needle, 1, true) ~= nil then n = n + 1 end
    end
    if n >= 1 then rows[#rows + 1] = { n = n, name = module } end
  end
  show(ranked(rows))
end

tasks["darwin-dirs"] = function()
  local names: mut {string} = {}
  for _, line in ipairs(lines_of(text_of("ci/darwin-tests.txt"))) do
    if line:sub(1, 1) ~= "#" and line:match("^%s*$") == nil then
      names[#names + 1] = line:match("^([^/]*)") or line
    end
  end
  show(ranked(counted(names)))
end

tasks["longest-lines"] = function()
  local rows: mut {Row} = {}
  for _, path in ipairs(only(sources("cosmic/agent", false), plain)) do
    local longest = 0
    for _, line in ipairs(lines_of(text_of(path))) do
      if #line > longest then longest = #line end
    end
    rows[#rows + 1] = { n = longest, name = path }
  end
  show(ranked(rows, 5))
end

tasks["rename-shared"] = function()
  local text: mut {string} = {}
  local found = false
  for _, path in ipairs(sources("cosmic", true)) do
    local body = text_of(path)
    if body:find("Cookies.format", 1, true) ~= nil then found = true end
    text[#text + 1] = path .. "\n" .. (body:gsub("Cookies%.format%f[^%w_]", "Cookies.render"))
  end
  if found then hashed(table.concat(text)) end
end

tasks["write-wordfreq"] = function()
  -- As `cat doc/guides/*.md` joins them: a file with no last newline runs into the next one.
  local joined: mut {string} = {}
  for _, path in ipairs(assert(Fs.walk("doc/guides"))) do
    if path:find("/", 1, true) == nil and path:sub(1, 1) ~= "." and path:match("%.md$") ~= nil then
      joined[#joined + 1] = text_of("doc/guides/" .. path)
    end
  end
  local names: mut {string} = {}
  for found in table.concat(joined):lower():gmatch("[a-z]+") do names[#names + 1] = found end
  show(ranked(counted(names), 5))
end

tasks["write-dirs"] = function()
  local rows: mut {Row} = {}
  for _, name in ipairs(assert(Fs.list("cosmic"))) do
    local path = "cosmic/" .. name
    local status = assert(Fs.stat(path))
    if status.kind == "dir" then rows[#rows + 1] = { n = #sources(path, true), name = path } end
  end
  show(ranked(rows))
end

local name, data = ...
local task: function(string?)? = nil
if name ~= nil then task = tasks[name] end
if task == nil then error("truth.tl: no task " .. tostring(name)) end
task(data)
