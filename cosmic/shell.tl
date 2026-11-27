--- The work of common shell commands, done in this process as calls on
--- values: `find`, `grep -n`, `sed -i`, `wc -l`, `sort`, `uniq -c` and a
--- one-shot `sqlite3`. No program runs, so a call needs no `x` grant, no
--- fork and no parse of a command's output, and it returns a value:
---
---     local Shell = require("cosmic.shell")
---     local files = assert(Shell.find(".", ".tl"))
---     for _, hit in ipairs(assert(Shell.grep("TODO", files, true))) do
---       print(hit.path .. ":" .. hit.line .. ": " .. hit.text)
---     end
---     local ranked = Shell.top(Shell.uniq({ "b", "a", "b" }), 10)
---
--- Each call does what its command does in the common case, after GNU
--- coreutils, grep, sed and findutils, but takes Lua patterns
--- ([`string.find`]), not regular expressions, and no flags past those
--- its options name. A call that reads or writes a file returns nil and
--- a [`cosmic.failure`] where that fails; what it is given in a wrong
--- shape (a malformed pattern, a table to bind) is a failure too, so a
--- caller tells the user rather than ending.
---
--- What one command does that one stdlib call already does is there,
--- not here: `cat` is [`Fs.read`], `test -e` is [`Fs.status`]'s
--- `exists`, `>` is [`Fs.write`] and `sha256sum` is [`Hash.hex_file`].
---
--- The calls hold no policy of their own: what a caller may read, write
--- or reach is its sandbox's to say ([`cosmic.sandbox`]).

local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local raw = require("cosmic.internal.text")

local record Shell
  --- A row of what [`Shell.sqlite`] returns: each column by its name, NULL as [`Json.null`].
  type Row = {string: Json.Value}

  --- A line [`Shell.grep`] found.
  record Hit
    --- The file, as the list given named it.
    path: string
    --- Its number, from 1.
    line: integer
    --- The line, without its newline (or a `\r` before one).
    text: string
  end

  --- A key and how often it was counted, as [`Shell.top`] lists it.
  record Count
    --- What was counted.
    key: string
    --- How often.
    count: integer
  end
end

--- Every regular file under `dir`, at any depth, as the command
--- `find` lists the files (`path` alone where `dir` is `"."`), sorted; only those
--- whose names end with `suffix` where given (`".tl"`).
function Shell.find(dir: string, suffix?: string): (mut {string}) | (nil, Failure)
  local found, why = Fs.walk(dir)
  if found == nil then return nil, why end
  local base = dir:gsub("/+$", "")
  local out: mut {string} = {}
  for _, path in ipairs(found) do
    if suffix == nil or suffix == "" or path:sub(-#suffix) == suffix then
      out[#out + 1] = if dir == "." then path elseif base == "" then "/" .. path else base .. "/" .. path end
    end
  end
  return out
end

--- The lines of `text`, each without its newline: a last line with no
--- newline is one too, and none follows a last newline. A `\r` before a
--- newline stays.
function Shell.split(text: string): mut {string}
  -- In C: a split in Lua took 5 ms a MiB, as long as wc -l takes to start and count.
  return raw.lines(text, false)
end

--- `line` without a `\r` at its end.
local function bare(line: string): string
  if line:byte(-1) == 13 then return line:sub(1, -2) end
  return line
end

--- The lines of the file `path`, without their newlines (or a `\r`
--- before one), as a loop of `IFS= read -r line` reads them: a last line with no
--- newline is one too.
function Shell.lines(path: string): (mut {string}) | (nil, Failure)
  local text, why = Fs.read(path)
  if text == nil then return nil, why end
  return raw.lines(text, true)
end

--- The lines of `text`, from the file `path`, that hold `needle`, plain text with no newline or `\r`, added to `out`:
--- one search of the whole text, as grep -F makes, not one a line, and the newlines between counted in C.
local function plain_hits(path: string, text: string, needle: string, out: mut {Shell.Hit})
  local line, start, from = 1, 1, 1
  local at = text:find(needle, 1, true)
  while at ~= nil do
    local passed, last = raw.newlines(text, from, at - 1)
    line = line + passed
    if last > 0 then start = last + 1 end
    local stop = (text:find("\n", at, true) or #text + 1) - 1
    local held = bare(text:sub(start, stop))
    out[#out + 1] = { path = path, line = line, text = held }
    line, start, from = line + 1, stop + 2, stop + 2
    at = text:find(needle, from, true)
  end
end

--- Each line of the files `paths` that holds `pattern`, a Lua pattern,
--- or plain text where `plain`, as `grep -n` finds them: in the order of
--- `paths`, then of lines. A malformed pattern is a failure.
function Shell.grep(pattern: string, paths: {string}, plain?: boolean): (mut {Shell.Hit}) | (nil, Failure)
  local out: mut {Shell.Hit} = {}
  for _, path in ipairs(paths) do
    local text, why = Fs.read(path)
    if text == nil then return nil, why end
    local exact = plain == true
    if exact and pattern ~= "" and pattern:find("[\r\n]") == nil then
      plain_hits(path, text, pattern, out)
    else
      -- A malformed pattern raises in find, once a line reaches the part that is malformed: one guard a file.
      local ok, trouble = pcall(function()
        for i, held in ipairs(raw.lines(text, true)) do
          if held:find(pattern, 1, exact) ~= nil then
            out[#out + 1] = { path = path, line = i, text = held }
          end
        end
      end)
      if not ok then return nil, Failure.new(pattern .. ": " .. tostring(trouble)) end
    end
  end
  return out
end

--- Replaces every match of `pattern` (a Lua pattern, or plain text where
--- `plain`) in the file `path` with `replacement` (where `%1` is a
--- capture, unless `plain`), as `sed -i 's/.../.../g'` does, line by
--- line: `^` and `$` hold at each line's ends, a match spans no newline,
--- and a `\r` before a newline stays. How many it replaced; a file with
--- none is not written.
function Shell.sed(path: string, pattern: string, replacement: string, plain?: boolean): (integer) | (nil, Failure)
  local text, why = Fs.read(path)
  if text == nil then return nil, why end
  local find = if plain == true then (pattern:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) else pattern end
  local put = if plain == true then (replacement:gsub("%%", "%%%%")) else replacement end
  local out: mut {string} = {}
  local count = 0
  -- A malformed pattern raises in gsub: one guard a file.
  local ok, trouble = pcall(function()
    for _, line in ipairs(Shell.split(text)) do
      local held = bare(line)
      local cr = if #held < #line then "\r" else "" end
      local changed, n = held:gsub(find, put)
      out[#out + 1] = changed .. cr
      count = count + n
    end
  end)
  if not ok then return nil, Failure.new(tostring(trouble)) end
  if count > 0 then
    local ends = if text:sub(-1) == "\n" then "\n" else "" end
    local wrote, write_why = Fs.write(path, table.concat(out, "\n") .. ends)
    if not wrote then return nil, write_why end
  end
  return count
end

--- How many lines the file `path` has, as `wc -l` counts them: its
--- newlines.
function Shell.wc(path: string): (integer) | (nil, Failure)
  local text, why = Fs.read(path)
  if text == nil then return nil, why end
  local newlines, _ = raw.newlines(text, 1, #text)
  return newlines
end

--- How often each of `keys` is in it, as `sort | uniq -c` counts.
function Shell.uniq(keys: {string}): {string: integer}
  local out: mut {string: integer} = {}
  for _, key in ipairs(keys) do out[key] = (out[key] or 0) + 1 end
  return out
end

--- `counts` as a list, the most first, ties by key, as
--- `sort -k1,1nr -k2 | head -n most` lists them; only the first `most`
--- where given.
function Shell.top(counts: {string: integer}, most?: integer): mut {Shell.Count}
  local out: mut {Shell.Count} = {}
  for key, count in pairs(counts) do out[#out + 1] = { key = key, count = count } end
  table.sort(out, function(a: Shell.Count, b: Shell.Count): boolean
    if a.count ~= b.count then return a.count > b.count end
    return a.key < b.key
  end)
  if most ~= nil then
    while #out > math.max(most, 0) do out[#out] = nil end
  end
  return out
end

--- A sorted copy of `list`, as `LC_ALL=C sort` orders bytes; by the key
--- `by` gives each item where given, as `sort -k` orders by a field
--- (`Shell.sort(lines, function(l: string): string return l:match("%S+$") or l end)`),
--- ties by the whole item.
function Shell.sort(list: {string}, by?: function(string): string): mut {string}
  -- In C with no key: table.sort took 21 ms on 16k lines, sort(1) 7 ms with its start.
  if by == nil then return raw.sort(list) end
  local out: mut {string} = {}
  for _, v in ipairs(list) do out[#out + 1] = v end
  local keys: mut {string: string} = {}
  for _, v in ipairs(out) do keys[v] = by(v) end
  table.sort(out, function(a: string, b: string): boolean
    local ka, kb = keys[a] or a, keys[b] or b
    if ka ~= kb then return ka < kb end
    return a < b
  end)
  return out
end

--- Whether `a` comes before `b` as `sort -V` orders them: each run of digits compares as the number it writes
--- (`x.tl:56` before `x.tl:1082`, `v9` before `v10`), the rest by bytes; ties by the whole text.
local function version_less(a: string, b: string): boolean
  local i, j = 1, 1
  while i <= #a and j <= #b do
    local da, ea = a:find("^%d+", i)
    local db, eb = b:find("^%d+", j)
    if da ~= nil and ea ~= nil and db ~= nil and eb ~= nil then
      local na = a:sub(da, ea):match("^0*(%d-)$") or ""
      local nb = b:sub(db, eb):match("^0*(%d-)$") or ""
      if #na ~= #nb then return #na < #nb end
      if na ~= nb then return na < nb end
      i, j = ea + 1, eb + 1
    else
      local ca, cb = a:sub(i, i), b:sub(j, j)
      if ca ~= cb then
        -- A digit run against another byte: the byte order of the two bytes still decides.
        return ca < cb
      end
      i, j = i + 1, j + 1
    end
  end
  if (#a - i) ~= (#b - j) then return (#a - i) < (#b - j) end
  return a < b
end

--- A sorted copy of `list` as `sort -V` orders it: a run of digits compares as its number, so `path:line` texts
--- come in the order of their lines (`a.tl:9` before `a.tl:10`), where [`Shell.sort`] puts `a.tl:10` first. By the
--- key `by` gives each item where given; ties by the whole item.
function Shell.version_sort(list: {string}, by?: function(string): string): mut {string}
  local out: mut {string} = {}
  for _, v in ipairs(list) do out[#out + 1] = v end
  local keys: mut {string: string} = {}
  if by ~= nil then
    for _, v in ipairs(out) do keys[v] = by(v) end
  end
  table.sort(out, function(a: string, b: string): boolean
    local ka, kb = keys[a] or a, keys[b] or b
    if ka ~= kb then return version_less(ka, kb) end
    return a < b
  end)
  return out
end

--- `values` as SQLite binds them, `?1` first: a string as text, an integer or a number as itself, a boolean as 1 or
--- 0, [`Json.null`] as NULL. Or nil, and why one cannot be bound.
local function params_of(values: {Json.Value}): {Sqlite.Param}, string?
  local out: mut {Sqlite.Param} = {}
  for i, v in ipairs(values) do
    if v is string or v is number or v is boolean then
      out[#out + 1] = v
    elseif v == Json.null then
      out[#out + 1] = Sqlite.NULL
    else
      return {}, "value " .. tostring(i) .. " is a table: bind a string, a number, a boolean or Json.null"
    end
  end
  return out, nil
end

--- The rows of one SQL statement on the SQLite file `path`, made where
--- it is missing, as the command `sqlite3 path statement` runs it: each
--- row an object of its columns (NULL is [`Json.null`]); `values` bind
--- `?1`, `?2`, ... (a string as text, a number as itself, a boolean as 1
--- or 0). A statement that changes the file yields no rows; with no
--- `values`, `statement` may be a script of several
--- (`create table ...; insert ...`), which yields none. For more than
--- one statement on a file, [`Sqlite.open`] it.
function Shell.sqlite(path: string, statement: string, values?: {Json.Value}): (mut {Shell.Row}) | (nil, Failure)
  local db, open_why = Sqlite.open(path, { writable = true })
  if db == nil then return nil, open_why end
  local prepared, why = db:prepare(statement)
  if prepared == nil then
    -- A script of several statements runs whole, as sqlite3 runs one.
    if values == nil then
      local ran, _ = db:exec(statement)
      if ran then
        local _, _ = db:close()
        return {}
      end
    end
    local _, _ = db:close()
    -- SQLite's own failure, its code and kind kept.
    return nil, why
  end
  local params, bind_why = params_of(values or {})
  local got: {Sqlite.Row} = {}
  local rows_why: Failure? = nil
  if bind_why == nil then
    local read, read_why = prepared:rows(params)
    if read == nil then rows_why = read_why else got = read end
  end
  local names = prepared:names()
  prepared:close()
  local _, _ = db:close()
  if bind_why ~= nil then return nil, Failure.new(bind_why, path) end
  if rows_why ~= nil then return nil, rows_why end
  local rows: mut {Shell.Row} = {}
  for _, got_row in ipairs(got) do
    local row: mut {string: Json.Value} = {}
    for i, name in ipairs(names) do
      local kind = got_row:kind(i)
      local key = String.as_utf8(name)
      if kind == "null" then
        row[key] = Json.null
      elseif kind == "integer" then
        row[key] = got_row:integer(i)
      elseif kind == "number" then
        row[key] = got_row:number(i)
      else
        row[key] = String.as_utf8(got_row:bytes(i))
      end
    end
    rows[#rows + 1] = row
  end
  return rows
end

return Shell
