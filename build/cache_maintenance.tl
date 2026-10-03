--- Maintenance of explicitly named shared-cache files. The running tool owns
--- their formats; neither a candidate project nor a cache writer is loaded.

local Child = require("cosmic.child")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local formats = require("build.cache_formats")

local record maintenance
  enum Family
    "compiles"
    "verdicts"
  end
  record Options
    family: Family
    paths: {string}
    since_ns: integer
    whole: boolean
    restored: string
  end
  record File
    path: string
    state: string
    reason: string
    kept: integer
    removed: integer
    before_bytes: integer
    after_bytes: integer
    reached: boolean
    unknown_tables: {string}
    unstamped_tables: {string}
    removed_set_aside: {string}
  end
  record Result
    report: Report
    complete: boolean
  end
  record Report
    version: integer
    files: {File}
    digest: string
    fresh: integer
    warnings: {string}
  end
end

local record Database
  db: Sqlite.Handle
  transaction: boolean
  metamethod __close: function(Database)
end

local database_mt: metatable<Database> = {
  __close = function(self: Database)
    if self.db ~= nil then
      if self.transaction then local _, _ = self.db:exec("ROLLBACK") end
      local _, _ = self.db:close()
    end
  end,
}

local function owned(db: Sqlite.Handle): Database
  return setmetatable({ db = db, transaction = false }, database_mt)
end

local function close(database: Database): boolean, string
  local ok, why = database.db:close()
  if not ok then return false, why end
  database.db = nil
  return true, ""
end

local function quoted(name: string): string
  return '"' .. name:gsub('"', '""') .. '"'
end

local function count(db: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): integer | nil, string
  local rows, why = Sqlite.rows(db, sql, values)
  if rows == nil then return nil, why end
  return rows[1][1].integer, ""
end

--- A column's shape, including hidden/generated columns that table_info omits.
local function columns(db: Sqlite.Handle, name: string): {string} | nil, string
  local rows, why = Sqlite.text_rows(db,
    'SELECT name, upper(type), "notnull", coalesce(dflt_value, \'\'), pk, hidden ' ..
    "FROM pragma_table_xinfo(?1) ORDER BY cid", { { text = name } })
  if rows == nil then return nil, why end
  local shape: {string} = {}
  for _, row in ipairs(rows) do shape[#shape + 1] = table.concat(row, "\0") end
  return shape, ""
end

--- SQLite interprets our own creation statements once, outside any cache.
--- Recognition needs no second hand-maintained list of column constraints.
local record Shape
  columns: {string}
  sql: string
end

--- Whitespace and identifier quoting do not change these fixed schemas.
--- Column metadata is checked too, so quoted names/defaults cannot merge.
local function normalized(sql: string): string
  return (sql:gsub('[`"%[%]%s]', ""):upper())
end

local function shapes(): {string:Shape}
  local scratch <close> = owned((assert(Sqlite.memory())))
  for _, schema in ipairs({ formats.compiles, formats.verdicts }) do
    for _, sql in ipairs(schema) do assert(scratch.db:exec(sql)) end
  end
  assert(scratch.db:exec(formats.legacy_verdicts))
  local out: {string:Shape} = {}
  for _, name in ipairs({ formats.compiled, formats.parsed, formats.declared,
      formats.stores, "verdicts_v4" }) do
    local sql = assert(Sqlite.text_rows(scratch.db,
      "SELECT sql FROM sqlite_schema WHERE name = ?1", { { text = name } }))[1][1]
    out[name] = { columns = (assert(columns(scratch.db, name))), sql = normalized(sql) }
  end
  return out
end

local function matches(name: string, sql: string, found: {string}, expected: Shape): boolean
  if expected == nil then return false end
  -- The declared format predates parts; its writer adds that final column.
  local old_declared = name == formats.declared and #found == #expected.columns - 1
  if #found ~= #expected.columns and not old_declared then
    return false
  end
  for i, column in ipairs(found) do
    if column ~= expected.columns[i] then return false end
  end
  local definition = expected.sql
  if old_declared then definition = definition:gsub(",PARTSTEXTNOTNULLDEFAULT''%)$", ")") end
  return normalized(sql) == definition
end

local function belongs(name: string, family: maintenance.Family): boolean
  if family == "compiles" then
    return name:match("^compiled_v%d+$") ~= nil or name:match("^parsed_v%d+$") ~= nil
  end
  return name:match("^declared_v%d+$") ~= nil or name:match("^stores_v%d+$") ~= nil or
    name:match("^verdicts_v%d+$") ~= nil
end

local record Table
  name: string
  supported: boolean
  stamped: boolean
end

--- A DELETE must not invoke schema code or cascade into an unknown table.
--- Conservatively retain all family rows when any such effect is present.
local function inspect(db: Sqlite.Handle, family: maintenance.Family,
    expected: {string:Shape}): {Table} | nil, string
  local schema, why = Sqlite.text_rows(db,
    "SELECT name, type, coalesce(sql, '') FROM sqlite_schema ORDER BY name")
  if schema == nil then return nil, why end
  local unsafe = false
  for _, row in ipairs(schema) do
    if row[2] == "trigger" or row[3]:upper():match("^CREATE%s+VIRTUAL%s+TABLE") then
      unsafe = true
    end
    if row[2] == "table" then
      local foreign, foreign_why = count(db, "SELECT count(*) FROM pragma_foreign_key_list(?1)",
        { { text = row[1] } })
      if foreign == nil then return nil, foreign_why end
      if foreign ~= 0 then unsafe = true end
    end
  end
  local out: {Table} = {}
  for _, row in ipairs(schema) do
    local name = row[1]
    if row[2] == "table" and belongs(name, family) then
      local actual, actual_why = columns(db, name)
      if actual == nil then return nil, actual_why end
      local stamped = false
      for _, column in ipairs(actual) do
        if column:sub(1, 8) == "used_ns\0" then stamped = true end
      end
      out[#out + 1] = { name = name, stamped = stamped,
        supported = not unsafe and matches(name, row[3], actual, expected[name]) }
    end
  end
  return out, ""
end

local function file_result(path: string): maintenance.File
  return { path = path, state = "kept", reason = "", unknown_tables = {},
    unstamped_tables = {}, removed_set_aside = {} }
end

local function failed(file: maintenance.File, why: string): maintenance.File
  file.state, file.reason = "failed", why
  return file
end

--- Only regular files with the exact historical retirement names belong to
--- cleanup. A matching prefix alone says nothing about who owns a sibling.
local function clean_aside(file: maintenance.File): boolean, string
  local dir, base = Fs.dirname(file.path), Fs.basename(file.path)
  local st, why, errno = sys.stat(dir)
  if st == nil then
    if errno == sys.ENOENT then return true, "" end
    return false, why
  end
  local names, list_why = Fs.list(dir)
  if names == nil then return false, list_why end
  local prefix = base .. ".corrupt-"
  for _, name in ipairs(names) do
    local tail = name:sub(#prefix + 1)
    local retired = tail:match("^%d+$") or tail:match("^%d+%-wal$") or tail:match("^%d+%-shm$")
    if name:sub(1, #prefix) == prefix and retired then
      local path = dir .. "/" .. name
      local entry, entry_why, entry_errno = sys.lstat(path)
      if entry == nil then
        if entry_errno ~= sys.ENOENT then return false, entry_why end
      elseif entry.kind == "file" then
        local ok, remove_why = Fs.remove(path)
        if not ok then return false, remove_why end
        file.removed_set_aside[#file.removed_set_aside + 1] = path
      end
    end
  end
  table.sort(file.removed_set_aside)
  return true, ""
end

--- A checkpoint can report SQLITE_OK while its result row says busy.
local function checkpoint(db: Sqlite.Handle): boolean, string
  local rows, why = Sqlite.rows(db, "PRAGMA wal_checkpoint(TRUNCATE)")
  if rows == nil then return false, why end
  local row = rows[1]
  if row == nil or row[1].integer ~= 0 or row[2].integer ~= row[3].integer then
    return false, "WAL checkpoint is busy or incomplete; no save-ready digest"
  end
  return true, ""
end

local function maintain_file(path: string, options: maintenance.Options,
    expected: {string:Shape}): maintenance.File
  local file = file_result(path)
  local cleaned, clean_why = clean_aside(file)
  if not cleaned then return failed(file, clean_why) end
  local before, stat_why, errno = sys.stat(path)
  if before == nil then
    if errno == sys.ENOENT then
      file.state = "missing"
      return file
    end
    return failed(file, stat_why)
  end
  if before.kind ~= "file" then return failed(file, "not a regular database file") end
  file.before_bytes = before.size
  local opened, open_why = Sqlite.open(path, { writable = true, create = false })
  -- TODO: restore automatic retirement of a provably corrupt active cache
  -- once SQLite exposes typed open/prepare/step failures. Until then keep
  -- every unreadable file and omit its save digest; diagnostics authorize no deletion.
  if opened == nil then return failed(file, open_why) end
  local database <close> = owned(opened)
  local db = database.db
  db:busy_timeout(Time.seconds(10))
  local begun = db:exec_result("BEGIN IMMEDIATE")
  if begun.code ~= Sqlite.OK then return failed(file, begun.reason) end
  database.transaction = true
  local tables, tables_why = inspect(db, options.family, expected)
  if tables == nil then return failed(file, tables_why) end
  local total, reached, supported = 0, false, 0
  for _, entry in ipairs(tables) do
    local n, count_why = count(db, "SELECT count(*) FROM " .. quoted(entry.name))
    if n == nil then return failed(file, count_why) end
    total = total + n
    if not entry.stamped then file.unstamped_tables[#file.unstamped_tables + 1] = entry.name end
    if not entry.supported then
      file.unknown_tables[#file.unknown_tables + 1] = entry.name
    else
      supported = supported + 1
      if not options.whole then
        local used, used_why = count(db, "SELECT count(*) FROM " .. quoted(entry.name) ..
          " WHERE used_ns >= ?1", { { integer = options.since_ns } })
        if used == nil then return failed(file, used_why) end
        if used > 0 then reached = true end
      end
    end
  end
  file.kept, file.removed = total, 0
  if not options.whole then file.reached = reached end
  local left = total
  local trimming = not options.whole and (options.family == "compiles" or reached)
  if trimming then
    for _, entry in ipairs(tables) do
      if entry.supported then
        local ok, why = Sqlite.run(db, "DELETE FROM " .. quoted(entry.name) ..
          " WHERE used_ns < ?1", { { integer = options.since_ns } })
        if not ok then return failed(file, why) end
        left = left - db:changes()
      end
    end
  end
  local committed = db:exec_result("COMMIT")
  if committed.code ~= Sqlite.OK then return failed(file, committed.reason) end
  database.transaction = false
  file.kept, file.removed = left, total - left
  if trimming and supported > 0 then file.state = "trimmed" end
  if not options.whole and supported > 0 then
    local vacuumed = db:exec_result("VACUUM")
    if vacuumed.code ~= Sqlite.OK then return failed(file, vacuumed.reason) end
  end
  local ready, ready_why = checkpoint(db)
  if not ready then return failed(file, ready_why) end
  local closed, close_why = close(database)
  if not closed then return failed(file, close_why) end
  local after, after_why = sys.stat(path)
  if after == nil then return failed(file, after_why) end
  file.after_bytes = after.size
  return file
end

--- Canonical rows, not pages. This framing is the existing CI save identity:
--- file basename, columns in cid order, tables/rows sorted, SQLite cell kinds.
--- A partial traversal never produces a fallback byte digest.
local function feed_rows(hasher: Hash.Hasher, path: string, guard: Child.Guard): boolean, string
  local opened, open_why = Sqlite.open(path, { writable = true, create = false })
  if opened == nil then return false, open_why end
  local database <close> = owned(opened)
  local db = database.db
  db:busy_timeout(Time.seconds(10))
  local begun = db:exec_result("BEGIN")
  if begun.code ~= Sqlite.OK then return false, begun.reason end
  database.transaction = true
  local names, names_why = Sqlite.text_rows(db, "SELECT name FROM sqlite_schema " ..
    "WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name")
  if names == nil then return false, names_why end
  for _, row in ipairs(names) do
    if guard:cancelled() ~= 0 then return false, "cache maintenance interrupted" end
    local name = row[1]
    local fields, fields_why = Sqlite.text_rows(db,
      "SELECT name FROM pragma_table_info(?1) WHERE name <> 'used_ns' ORDER BY cid",
      { { text = name } })
    if fields == nil then return false, fields_why end
    local selected: {string} = {}
    local order: {string} = {}
    for i, field in ipairs(fields) do
      selected[i], order[i] = quoted(field[1]), tostring(i)
      hasher:update("column\0" .. #field[1] .. ":" .. field[1])
    end
    hasher:update("table\0" .. #name .. ":" .. name .. "\0" .. #fields .. "\0")
    if #selected > 0 then
      local query, query_why = Sqlite.query(db, "SELECT " .. table.concat(selected, ", ") ..
        " FROM " .. quoted(name) .. " ORDER BY " .. table.concat(order, ", "))
      if query == nil then return false, query_why end
      local q <close> = query
      for cells in q:each() do
        if guard:cancelled() ~= 0 then return false, "cache maintenance interrupted" end
        for _, cell in ipairs(cells) do
          local value = cell.text or cell.blob or
            (cell.integer ~= nil and tostring(cell.integer)) or
            (cell.number ~= nil and string.format("%.17g", cell.number)) or ""
          hasher:update(cell.kind .. "\0" .. #value .. ":" .. value)
        end
        hasher:update("\n")
      end
      if q:failure() ~= "" then return false, q:failure() end
    end
  end
  local committed = db:exec_result("COMMIT")
  if committed.code ~= Sqlite.OK then return false, committed.reason end
  database.transaction = false
  local ready, ready_why = checkpoint(db)
  if not ready then return false, ready_why end
  return close(database)
end

local function digest(paths: {string}, guard: Child.Guard): string | nil, string
  if #paths == 0 then return nil, "" end
  local hasher = assert(Hash.hasher("sha256"))
  for _, path in ipairs(paths) do
    local name = Fs.basename(path)
    hasher:update("file\0" .. #name .. ":" .. name .. "\0")
    local ok, why = feed_rows(hasher, path, guard)
    if not ok then return nil, path .. ": " .. why end
  end
  return Codec.hex((assert(hasher:digest()))), ""
end

--- Merge two ordered key cursors; memory holds at most one key from each.
local function new_keys(db: Sqlite.Handle, restored: Sqlite.Handle,
    name: string, guard: Child.Guard): integer | nil, string
  if restored == nil then return count(db, "SELECT count(*) FROM " .. quoted(name)) end
  local there, there_why = count(restored,
    "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name = ?1", { { text = name } })
  if there == nil then return nil, there_why end
  if there == 0 then return count(db, "SELECT count(*) FROM " .. quoted(name)) end
  local opened, why = Sqlite.query(db, "SELECT key FROM " .. quoted(name) .. " ORDER BY key")
  if opened == nil then return nil, why end
  local live <close> = opened
  local old_opened, old_why = Sqlite.query(restored, "SELECT key FROM " .. quoted(name) .. " ORDER BY key")
  if old_opened == nil then return nil, old_why end
  local old <close> = old_opened
  local previous, previous_why = old:read()
  if previous == nil and previous_why ~= "" then return nil, previous_why end
  local fresh = 0
  for row in live:each() do
    if guard:cancelled() ~= 0 then return nil, "cache maintenance interrupted" end
    local key = row[1].text
    if key == nil then return nil, "compile key is not text" end
    while previous ~= nil do
      local old_key = previous[1].text
      if old_key == nil then return nil, "restored compile key is not text" end
      if old_key >= key then break end
      previous, previous_why = old:read()
      if previous == nil and previous_why ~= "" then return nil, previous_why end
    end
    if previous == nil or previous[1].text ~= key then fresh = fresh + 1 end
  end
  if live:failure() ~= "" then return nil, live:failure() end
  return fresh, ""
end

local function fresh_keys(path: string, restored: string, expected: {string:Shape},
    guard: Child.Guard): integer | nil, string
  local opened, why = Sqlite.open(path, { writable = true, create = false })
  if opened == nil then return nil, why end
  local live <close> = owned(opened)
  live.db:busy_timeout(Time.seconds(10))
  local old <close> = owned(nil)
  local st, stat_why, errno = sys.stat(restored)
  if st ~= nil then
    old.db, why = Sqlite.open(restored)
    if old.db == nil then return nil, why end
    old.db:busy_timeout(Time.seconds(10))
  elseif errno ~= sys.ENOENT then
    return nil, stat_why
  end
  for _, db in ipairs(old.db ~= nil and { live.db, old.db } or { live.db }) do
    local tables, table_why = inspect(db, "compiles", expected)
    if tables == nil then return nil, table_why end
    for _, entry in ipairs(tables) do
      if entry.name:match("^compiled_v%d+$") and not entry.supported then
        return nil, "cannot compare unknown compile format " .. entry.name
      end
    end
  end
  local names, names_why = Sqlite.text_rows(live.db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name")
  if names == nil then return nil, names_why end
  local total = 0
  for _, row in ipairs(names) do
    if row[1]:match("^compiled_v%d+$") then
      local n, count_why = new_keys(live.db, old.db, row[1], guard)
      if n == nil then return nil, count_why end
      total = total + n
    end
  end
  if old.db ~= nil then
    local closed, close_why = close(old)
    if not closed then return nil, close_why end
  end
  local ready, ready_why = checkpoint(live.db)
  if not ready then return nil, ready_why end
  local closed, close_why = close(live)
  if not closed then return nil, close_why end
  return total, ""
end

--- Maintains exactly the supplied files. Writers must remain quiescent through
--- this operation and the caller's save; a transaction cannot enforce that lease.
function maintenance.run(options: maintenance.Options): maintenance.Result
  local report: maintenance.Report = { version = 1, files = {}, warnings = {} }
  local guard, guard_why = Child.guard()
  if guard == nil then
    report.warnings[1] = guard_why
    return { report = report, complete = false }
  end
  local held <close> = guard
  local expected = shapes()
  local paths: {string} = {}
  local complete = true
  for _, path in ipairs(options.paths) do
    if held:cancelled() ~= 0 then
      report.warnings[#report.warnings + 1] = "cache maintenance interrupted"
      complete = false
      break
    end
    local file = maintain_file(path, options, expected)
    report.files[#report.files + 1] = file
    if file.state == "failed" then
      complete = false
    elseif file.state ~= "missing" then
      paths[#paths + 1] = path
    end
  end
  if complete then
    local why: string
    report.digest, why = digest(paths, held)
    if why ~= "" then
      report.warnings[#report.warnings + 1] = why
      complete = false
    end
    if complete and options.restored ~= nil and #paths > 0 then
      report.fresh, why = fresh_keys(paths[1], options.restored, expected, held)
      if why ~= "" then
        report.warnings[#report.warnings + 1] = why
        complete = false
      end
    end
  end
  local signal, release_why = held:release()
  if signal == nil or signal ~= 0 then
    report.digest, report.fresh = nil, nil
    report.warnings[#report.warnings + 1] = signal == nil and release_why or "cache maintenance interrupted"
    complete = false
  end
  if not complete then report.digest, report.fresh = nil, nil end
  return { report = report, complete = complete }
end

return maintenance
