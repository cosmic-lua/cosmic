--- What the two databases under `o/` hold, table by table: rows,
--- pages and bytes, from SQLite's own `dbstat` table, and how the
--- last few builds went. This is how growth gets named rather than
--- noticed, and how a change to what the build stores is judged by
--- what it costs.

local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local clock = require("build.clock")
local reboot = require("build.reboot")

local log = require("build.verdict").log

local record databases
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
    "SELECT name FROM sqlite_master WHERE type = 'table'")
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
        "SELECT count(*) FROM \"" .. name .. "\"")
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
local function slowest(path: string): boolean, string
  local db, open_trouble = Sqlite.open(path, false)
  if db == nil then
    return false, open_trouble
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT path, test, elapsed_ns FROM runs ORDER BY elapsed_ns DESC LIMIT " ..
    tostring(slowest_kept))
  local _, _ = db:close()
  if rows == nil then
    return false, trouble
  end
  if #rows == 0 then
    return true, ""
  end
  log:say("slowest tests")
  for _, row in ipairs(rows) do
    local ns = math.tointeger(tonumber(row[3]) or 0) or 0
    log:say("  " .. string.format("%.1f", ns / 1e9) .. "s  " .. row[1] ..
      " " .. row[2])
  end
  return true, ""
end

--- Describes `o/cosmic.db` and `o/build.db` under the working
--- directory, printing a verdict line and returning the exit code.
--- @param argv the command line, re-entered if this binary embeds a
---   stale copy of `build.databases` itself -- see `build.reboot.ensure`
function databases.run(argv: {integer:string}): integer
  local started = Time.monotonic_ns()
  local parsed, parse_trouble = Flags.parse(argv, 2, {})
  if parsed ~= nil and #parsed.words > 0 then
    parsed, parse_trouble = nil, "takes no arguments, not " .. parsed.words[1]
  end
  if parsed == nil then
    log:complain("db: " .. parse_trouble)
    return 2
  end
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain(root_trouble)
    return 1
  end
  local code, reboot_trouble = reboot.ensure(root, argv)
  if code ~= nil then
    if reboot_trouble ~= "" then
      log:complain(reboot_trouble)
    end
    return code
  end
  local seen = 0
  local tables = 0
  for _, name in ipairs({ "o/cosmic.db", "o/build.db" }) do
    local path = root .. "/" .. name
    local present, present_trouble = Fs.exists(path)
    if present == nil then
      log:complain(present_trouble)
      return 1
    end
    if present then
      local counted, trouble = describe(path)
      if counted == nil then
        log:complain(path .. ": " .. trouble)
        return 1
      end
      seen = seen + 1
      tables = tables + counted
      if name == "o/build.db" then
        local ok, build_trouble = builds(path)
        if not ok then
          log:complain(path .. ": " .. build_trouble)
          return 1
        end
        ok, build_trouble = slowest(path)
        if not ok then
          log:complain(path .. ": " .. build_trouble)
          return 1
        end
      end
    end
  end
  if seen == 0 then
    log:verdict("db", false, "no database under " .. root .. "/o; build first, " ..
      clock.elapsed_ms(started) .. " ms")
    return 1
  end
  log:verdict("db", true, tables .. " tables in " .. seen .. " databases, " ..
    clock.elapsed_ms(started) .. " ms")
  return 0
end

return databases
