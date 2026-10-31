--- Maintenance of explicitly named shared-cache files. The running tool owns
--- their formats; neither a candidate project nor a cache writer is loaded.

local Signal = require("cosmic.signal")
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
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
    since_ns?: integer
    whole: boolean
    restored?: string
  end
  record File
    path: string
    mut state: string
    mut reason: string
    mut kept?: integer
    mut removed?: integer
    mut before_bytes?: integer
    mut after_bytes?: integer
    mut reached?: boolean
    unknown_tables: mut {string}
    unstamped_tables: mut {string}
    removed_set_aside: mut {string}
  end
  record Result
    report: Report
    complete: boolean
  end
  record Report
    version: integer
    files: mut {File}
    mut digest?: string
    mut fresh?: integer
    warnings: mut {string}
  end
end

local record Database
  --- Nil once closed, and for a database [`owned`] has none yet.
  mut db?: Sqlite.Handle
  mut transaction: boolean
  __close: function(Database)
end

local database_mt: metatable<Database> = {
  __close = function(self: Database)
    local db = self.db
    if db ~= nil then
      if self.transaction then local _, _ = db:exec("ROLLBACK") end
      local _, _ = db:close()
    end
  end,
}

local function owned(db?: Sqlite.Handle): Database
  return setmetatable({ db = db, transaction = false }, database_mt)
end

local function close(database: Database): boolean, string
  local db = database.db
  if db == nil then return true, "" end
  local ok, why = db:close()
  if not ok then return false, why end
  database.db = nil
  return true, ""
end

local function quoted(name: string): string
  return '"' .. name:gsub('"', '""') .. '"'
end

local function count(db: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): integer?, string
  local rows, why = Sqlite.rows(db, sql, values)
  if rows == nil then return nil, why end
  local row = rows[1]
  if row == nil then return nil, "the query answered no row" end
  return row:integer(1), ""
end

--- A column's shape, including hidden/generated columns that table_info omits.
local function columns(db: Sqlite.Handle, name: string): {string}?, string
  local rows, why = Sqlite.text_rows(db,
    'SELECT name, upper(type), "notnull", coalesce(dflt_value, \'\'), pk, hidden ' ..
      "FROM pragma_table_xinfo(?1) ORDER BY cid", { { text = name } })
  if rows == nil then return nil, why end
  local shape: mut {string} = {}
  for _, row in ipairs(rows) do shape[#shape + 1] = table.concat(row:texts(), "\0") end
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
  local memory = assert(Sqlite.memory())
  local _scratch <close> = owned(memory)
  for _, schema in ipairs({ formats.compiles, formats.bridge_statements, formats.verdicts }) do
    for _, sql in ipairs(schema) do assert(memory:exec(sql)) end
  end
  assert(memory:exec(formats.legacy_verdicts))
  local out: mut {string:Shape} = {}
  for _, name in ipairs({ formats.compiled, formats.parsed, formats.bridge, formats.declared,
      formats.stores, "verdicts_v4" }) do
    local declared = assert(Sqlite.text_rows(memory,
      "SELECT sql FROM sqlite_schema WHERE name = ?1", { { text = name } }))
    local sql = assert(declared[1], "every format is declared in memory"):text(1)
    out[name] = { columns = (assert(columns(memory, name))), sql = normalized(sql) }
  end
  return out
end

local function matches(name: string, sql: string, found: {string}, expected: Shape?): boolean
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
    return name:match("^compiled_v%d+$") ~= nil or name:match("^parsed_v%d+$") ~= nil or
      name:match("^bridge_v%d+$") ~= nil
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
                       expected: {string:Shape}): {Table}?, string
  local schema, why = Sqlite.text_rows(db,
    "SELECT name, type, coalesce(sql, '') FROM sqlite_schema ORDER BY name")
  if schema == nil then return nil, why end
  local unsafe = false
  for _, row in ipairs(schema) do
    if row:text(2) == "trigger" or row:text(3):upper():match("^CREATE%s+VIRTUAL%s+TABLE") ~= nil then
      unsafe = true
    end
    if row:text(2) == "table" then
      local foreign, foreign_why = count(db, "SELECT count(*) FROM pragma_foreign_key_list(?1)",
        { { text = row:text(1) } })
      if foreign == nil then return nil, foreign_why end
      if foreign ~= 0 then unsafe = true end
    end
  end
  local out: mut {Table} = {}
  for _, row in ipairs(schema) do
    local name = row:text(1)
    if row:text(2) == "table" and belongs(name, family) then
      local actual, actual_why = columns(db, name)
      if actual == nil then return nil, actual_why end
      local stamped = false
      for _, column in ipairs(actual) do
        if column:sub(1, 8) == "used_ns\0" then stamped = true end
      end
      out[#out + 1] = { name = name, stamped = stamped,
        supported = not unsafe and matches(name, row:text(3), actual, expected[name]) }
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
    if name:sub(1, #prefix) == prefix then
      local tail = name:sub(#prefix + 1)
      local retired = tail:match("^%d+$") or tail:match("^%d+%-wal$") or tail:match("^%d+%-shm$")
      if retired then
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
  end
  table.sort(file.removed_set_aside)
  return true, ""
end

--- A checkpoint can report SQLITE_OK while its result row says busy.
local function checkpoint(db: Sqlite.Handle): boolean, string
  local rows, why = Sqlite.rows(db, "PRAGMA wal_checkpoint(TRUNCATE)")
  if rows == nil then return false, why end
  local row = rows[1]
  if row == nil or row:integer(1) ~= 0 or row:integer(2) ~= row:integer(3) then
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
  -- once cache-wide lifetime ownership and identity checks exclude concurrent
  -- users and replacements. Typed failure codes alone authorize no deletion;
  -- keep every unreadable file and omit its save digest.
  if opened == nil then return failed(file, open_why) end
  local database <close> = owned(opened)
  local db = opened
  db:busy_timeout(Clock.seconds(10))
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
local function feed_rows(hasher: Hash.Hasher, path: string, guard: Signal.Guard): boolean, string
  local opened, open_why = Sqlite.open(path, { writable = true, create = false })
  if opened == nil then return false, open_why end
  local database <close> = owned(opened)
  local db = opened
  db:busy_timeout(Clock.seconds(10))
  local begun = db:exec_result("BEGIN")
  if begun.code ~= Sqlite.OK then return false, begun.reason end
  database.transaction = true
  local names, names_why = Sqlite.text_rows(db, "SELECT name FROM sqlite_schema " ..
      "WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name")
  if names == nil then return false, names_why end
  for _, row in ipairs(names) do
    if guard:cancelled() ~= 0 then return false, "cache maintenance interrupted" end
    local name = row:text(1)
    local fields, fields_why = Sqlite.text_rows(db,
      "SELECT name FROM pragma_table_info(?1) WHERE name <> 'used_ns' ORDER BY cid",
      { { text = name } })
    if fields == nil then return false, fields_why end
    local selected: mut {string} = {}
    local order: mut {string} = {}
    for i, field in ipairs(fields) do
      selected[i], order[i] = quoted(field:text(1)), tostring(i)
      hasher:update("column\0" .. tostring(#field:text(1)) .. ":" .. field:text(1))
    end
    hasher:update("table\0" .. tostring(#name) .. ":" .. name .. "\0" .. tostring(#fields) .. "\0")
    if #selected > 0 then
      local query, query_why = Sqlite.query(db, "SELECT " .. table.concat(selected, ", ") ..
          " FROM " .. quoted(name) .. " ORDER BY " .. table.concat(order, ", "))
      if query == nil then return false, query_why end
      local q <close> = query
      for cells in q:each() do
        if guard:cancelled() ~= 0 then return false, "cache maintenance interrupted" end
        for index = 1, cells:count() do
          local kind = cells:kind(index)
          local value = ""
          if kind == "text" then
            value = cells:text(index)
          elseif kind == "blob" then
            value = cells:blob(index)
          elseif kind == "integer" then
            value = tostring(cells:integer(index))
          elseif kind == "number" then
            value = string.format("%.17g", cells:number(index))
          end
          hasher:update(kind .. "\0" .. tostring(#value) .. ":" .. value)
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

local function digest(paths: {string}, guard: Signal.Guard): string?, string
  if #paths == 0 then return nil, "" end
  local hasher = assert(Hash.hasher("sha256"))
  for _, path in ipairs(paths) do
    local name = Fs.basename(path)
    hasher:update("file\0" .. tostring(#name) .. ":" .. name .. "\0")
    local ok, why = feed_rows(hasher, path, guard)
    if not ok then return nil, path .. ": " .. why end
  end
  return Codec.hex((assert(hasher:digest()))), ""
end

--- Merge two ordered key cursors; memory holds at most one key from each.
local function new_keys(db: Sqlite.Handle, restored: Sqlite.Handle?,
                        name: string, guard: Signal.Guard): integer?, string
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
    if row:kind(1) ~= "text" then return nil, "compile key is not text" end
    local key = row:text(1)
    while previous ~= nil do
      if previous:kind(1) ~= "text" then return nil, "restored compile key is not text" end
      local old_key = previous:text(1)
      if old_key >= key then break end
      previous, previous_why = old:read()
      if previous == nil and previous_why ~= "" then return nil, previous_why end
    end
    if previous == nil or previous:text(1) ~= key then fresh = fresh + 1 end
  end
  if live:failure() ~= "" then return nil, live:failure() end
  return fresh, ""
end

local function fresh_keys(path: string, restored: string, expected: {string:Shape},
                          guard: Signal.Guard): integer?, string
  local opened, why = Sqlite.open(path, { writable = true, create = false })
  if opened == nil then return nil, why end
  local live <close> = owned(opened)
  opened:busy_timeout(Clock.seconds(10))
  local old <close> = owned(nil)
  local st, stat_why, errno = sys.stat(restored)
  if st ~= nil then
    old.db, why = Sqlite.open(restored)
    local old_db = old.db
    if old_db == nil then return nil, why end
    old_db:busy_timeout(Clock.seconds(10))
  elseif errno ~= sys.ENOENT then
    return nil, stat_why
  end
  local old_db = old.db
  for _, db in ipairs(if old_db ~= nil then { opened, old_db } else { opened } end) do
    local tables, table_why = inspect(db, "compiles", expected)
    if tables == nil then return nil, table_why end
    for _, entry in ipairs(tables) do
      if entry.name:match("^compiled_v%d+$") and not entry.supported then
        return nil, "cannot compare unknown compile format " .. entry.name
      end
    end
  end
  local names, names_why = Sqlite.text_rows(opened,
    "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name")
  if names == nil then return nil, names_why end
  local total = 0
  for _, row in ipairs(names) do
    if row:text(1):match("^compiled_v%d+$") then
      local n, count_why = new_keys(opened, old.db, row:text(1), guard)
      if n == nil then return nil, count_why end
      total = total + n
    end
  end
  if old.db ~= nil then
    local closed, close_why = close(old)
    if not closed then return nil, close_why end
  end
  local ready, ready_why = checkpoint(opened)
  if not ready then return nil, ready_why end
  local closed, close_why = close(live)
  if not closed then return nil, close_why end
  return total, ""
end

--- Maintains exactly the supplied files. Writers must remain quiescent through
--- this operation and the caller's save; a transaction cannot enforce that lease.
function maintenance.run(options: maintenance.Options): maintenance.Result
  local report: maintenance.Report = { version = 1, files = {}, warnings = {} }
  local guard, guard_why = Signal.guard()
  if guard == nil then
    report.warnings[1] = guard_why
    return { report = report, complete = false }
  end
  local held <close> = guard
  local expected = shapes()
  local paths: mut {string} = {}
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
    local restored = options.restored
    local first_path = paths[1]
    if complete and restored ~= nil and first_path ~= nil then
      report.fresh, why = fresh_keys(first_path, restored, expected, held)
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
