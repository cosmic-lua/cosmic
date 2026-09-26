--- What the databases under `o/` hold, table by table: rows,
--- pages and bytes, from SQLite's own `dbstat` table, and how the
--- last few builds went. This is how growth gets named rather than
--- noticed, and how a change to what the build stores is judged by
--- what it costs.

local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local clock = require("build.clock")
local narrow = require("build.narrow")
local reboot = require("build.reboot")

local log = require("build.verdict").log

local record databases
end

--- `name` as an SQL identifier, quoted, with each `"` in it doubled.
local function quoted(name: string): string
  return "\"" .. (name:gsub("\"", "\"\"")) .. "\""
end

--- A number, right-aligned in `width` columns.
local function column(value: string, width: integer): string
  return string.rep(" ", width - #value) .. value
end

--- One database's tables and indexes, largest first, each with its
--- rows (for a table), its pages, the bytes those pages take, and the
--- bytes that are actually payload. Returns how many tables it saw.
local function describe(path: string): integer | nil, string
  local db, open_trouble = Sqlite.open(path, false)
  if db == nil then
    return nil, open_trouble
  end
  local sizes, size_trouble = Sqlite.text_rows(db,
    "SELECT name, count(*), sum(pgsize), sum(payload) FROM dbstat " ..
    "GROUP BY name ORDER BY sum(pgsize) DESC, name")
  if sizes == nil then
    local _, _ = db:close()
    return nil, size_trouble
  end
  local tables, table_trouble = Sqlite.text_rows(db,
    "SELECT name FROM sqlite_schema WHERE type = 'table'")
  if tables == nil then
    local _, _ = db:close()
    return nil, table_trouble
  end
  local is_table: {string:boolean} = {}
  for _, row in ipairs(tables) do
    is_table[row[1]] = true
  end
  local st, _ = Fs.stat(path)
  log:say(path .. "  " .. (st ~= nil and st.size or 0) .. " bytes")
  log:say("  " .. column("rows", 8) .. column("pages", 8) ..
    column("bytes", 10) .. column("payload", 10) .. "  name")
  for _, row in ipairs(sizes) do
    local name, pages, bytes, payload = row[1], row[2], row[3], row[4]
    local rows = ""
    if is_table[name] then
      local counted, count_trouble = Sqlite.text_rows(db,
        "SELECT count(*) FROM " .. quoted(name))
      if counted == nil then
        local _, _ = db:close()
        return nil, count_trouble
      end
      rows = counted[1][1]
    end
    log:say("  " .. column(rows, 8) .. column(pages, 8) .. column(bytes, 10) ..
      column(payload, 10) .. "  " .. name)
  end
  local _, _ = db:close()
  return #tables
end

--- The last few rows of the working database's `builds`.
local function builds(path: string): boolean, string
  local db, open_trouble = Sqlite.open(path, false)
  if db == nil then
    return false, open_trouble
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT run, ms, files, read, compiled, cached, verdict FROM builds " ..
    "ORDER BY run DESC LIMIT 5")
  local _, _ = db:close()
  if rows == nil then
    return false, trouble
  end
  log:say("builds, latest first")
  for _, row in ipairs(rows) do
    log:say("  run " .. row[1] .. "  " .. row[2] .. " ms  " .. row[3] ..
      " files staged (" .. row[4] .. " read)  " .. row[5] .. " compiled, " ..
      row[6] .. " cached  " .. row[7])
  end
  return true, ""
end

--- How many of the slowest tests to name in the report.
local slowest_kept = 5

--- The slowest tests of the last-run `runs` rows, latest first by
--- their own duration -- what "which test is dragging the suite out"
--- costs before this had to be found by timing modules one by one.
--- @param about whether a test module's rows are to be reported
local function slowest(path: string, about: function(string): boolean): boolean, string
  local db, open_trouble = Sqlite.open(path, false)
  if db == nil then
    return false, open_trouble
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT path, test, elapsed_ns FROM runs ORDER BY elapsed_ns DESC")
  local _, _ = db:close()
  if rows == nil then
    return false, trouble
  end
  local kept: {{string}} = {}
  for _, row in ipairs(rows) do
    if #kept < slowest_kept and about(row[1]) then kept[#kept + 1] = row end
  end
  if #kept == 0 then
    return true, ""
  end
  log:say("slowest tests")
  for _, row in ipairs(kept) do
    local ns = math.tointeger(tonumber(row[3]) or 0) or 0
    log:say("  " .. string.format("%.1f", ns / 1e9) .. "s  " .. row[1] ..
      " " .. row[2])
  end
  return true, ""
end

--- The columns that say which source a row is about, the first a table
--- has taken: a file's path, or a path that is a file's or a module's.
--- A table keyed only by a source's hash (`source_hash`, `sha256`) is
--- about the file with that hash.
local source_columns = { "file", "from_file", "path", "source_hash", "sha256" }

--- The source file each module name and each source hash stands for,
--- from whichever of the two databases hold one: `o/cosmic.db`'s modules
--- and `o/build.db`'s derived rows and staged files.
local function module_files(root: string): {string:string} | nil, string
  local files: {string:string} = {}
  for _, source in ipairs({
    { "o/cosmic.db", "SELECT path, file FROM modules" },
    { "o/build.db", "SELECT path, file FROM derived" },
    { "o/build.db", "SELECT source_hash, file FROM derived" },
    { "o/build.db", "SELECT sha256, path FROM files" },
  }) do
    local path = root .. "/" .. source[1]
    local present, present_trouble = Fs.exists(path)
    if present == nil then
      return nil, present_trouble
    end
    if present then
      local db, open_trouble = Sqlite.open(path, false)
      if db == nil then
        return nil, open_trouble
      end
      local rows, trouble = Sqlite.text_rows(db, source[2])
      local _, _ = db:close()
      if rows == nil then
        return nil, path .. ": " .. trouble
      end
      for _, row in ipairs(rows) do files[row[1]] = row[2] end
    end
  end
  return files, ""
end

--- One database's tables that say which source each row is about, each
--- with how many of its rows `about` keeps, for the tables that keep
--- any. Returns how many rows it kept.
local function describe_under(path: string, about: function(string): boolean): integer | nil, string
  local db, open_trouble = Sqlite.open(path, false)
  if db == nil then
    return nil, open_trouble
  end
  local tables, table_trouble = Sqlite.text_rows(db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name")
  if tables == nil then
    local _, _ = db:close()
    return nil, table_trouble
  end
  log:say(path)
  log:say("  " .. column("rows", 8) .. "  name")
  local kept = 0
  for _, row in ipairs(tables) do
    local name = row[1]
    local columns, column_trouble = Sqlite.text_rows(db,
      "SELECT name FROM pragma_table_info(?1)", { { text = name } })
    if columns == nil then
      local _, _ = db:close()
      return nil, column_trouble
    end
    local has: {string:boolean} = {}
    for _, c in ipairs(columns) do has[c[1]] = true end
    local chosen: string | nil = nil
    for _, candidate in ipairs(source_columns) do
      if chosen == nil and has[candidate] then chosen = candidate end
    end
    if chosen ~= nil then
      local values, value_trouble = Sqlite.text_rows(db,
        "SELECT " .. quoted(chosen) .. " FROM " .. quoted(name))
      if values == nil then
        local _, _ = db:close()
        return nil, value_trouble
      end
      local count = 0
      for _, value in ipairs(values) do
        if about(value[1]) then count = count + 1 end
      end
      if count > 0 then
        log:say("  " .. column(tostring(count), 8) .. "  " .. name)
        kept = kept + count
      end
    end
  end
  local _, _ = db:close()
  return kept
end

--- `cosmic db [path...]`: describes `o/cosmic.db`, `o/carried.db` (what
--- the tool built from cosmic's own tree carries) and `o/build.db` under
--- the working directory, each one there is, printing a verdict line and
--- returning the exit code. Paths narrow it to the rows about the sources under them: each
--- table's count of those rows, and the slowest of those tests. The
--- coverage rows counted are every kept run's, not only the latest.
--- @param argv the command line, re-entered if this binary embeds a
---   stale copy of `build.databases` itself -- see `build.reboot.stale_exit`
function databases.run(argv: {integer:string}): integer
  local started = Time.monotonic_ns()
  local parsed, parse_trouble = Flags.parse(argv, 2, {})
  if parsed == nil then
    log:complain("db: " .. parse_trouble)
    return 2
  end
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain(root_trouble)
    return 1
  end
  local code = reboot.stale_exit(argv)
  if code ~= nil then
    return code
  end
  local paths = narrow.paths(root, parsed.words)
  local files: {string:string} = {}
  if #paths > 0 then
    local found, files_trouble = module_files(root)
    if found == nil then
      log:complain(files_trouble)
      return 1
    end
    files = found
  end
  -- A row is about a source under the paths when its value is that
  -- source's path, the name of a module compiled from it, or its hash.
  local function about(value: string): boolean
    if narrow.holds(paths, value) then
      return true
    end
    local file = files[value]
    return file ~= nil and narrow.holds(paths, file)
  end
  local seen = 0
  local tables = 0
  local rows = 0
  for _, name in ipairs({ "o/cosmic.db", "o/carried.db", "o/build.db" }) do
    local path = root .. "/" .. name
    local present, present_trouble = Fs.exists(path)
    if present == nil then
      log:complain(present_trouble)
      return 1
    end
    if present then
      local counted, trouble: integer, string
      if #paths > 0 then
        counted, trouble = describe_under(path, about)
      else
        counted, trouble = describe(path)
      end
      if counted == nil then
        log:complain(path .. ": " .. trouble)
        return 1
      end
      seen = seen + 1
      if #paths > 0 then
        rows = rows + counted
      else
        tables = tables + counted
      end
      if name == "o/build.db" then
        if #paths == 0 then
          local ok, build_trouble = builds(path)
          if not ok then
            log:complain(path .. ": " .. build_trouble)
            return 1
          end
        end
        local ok, slow_trouble = slowest(path, about)
        if not ok then
          log:complain(path .. ": " .. slow_trouble)
          return 1
        end
      end
    end
  end
  if seen == 0 then
    log:verdict("db", false, "no database under " .. root .. "/o; build first, " ..
      clock.took(started))
    return 1
  end
  if #paths > 0 then
    local under = table.concat(paths, ", ")
    if rows == 0 then
      log:verdict("db", false, "no row is about " .. under .. ", " ..
        clock.took(started))
      return 1
    end
    log:verdict("db", true, rows .. " rows about " .. under .. " in " .. seen ..
      " databases, " .. clock.took(started))
    return 0
  end
  log:verdict("db", true, tables .. " tables in " .. seen .. " databases, " ..
    clock.took(started))
  return 0
end

return databases
