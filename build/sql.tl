--- `cosmic sql`: one SQL statement against a database, read-only, its
--- rows printed one per line with their cells tab-separated. This is
--- how the build's own databases get asked a question without writing
--- a throwaway script -- a script must be built as a tree, and the
--- tree it would build is whatever directory it was run from.
---
--- It opens the database read-only and sets `PRAGMA query_only` before
--- running the statement, so SQLite itself refuses a write: nothing
--- here reads the statement's text to decide what it may do. SQLite
--- prepares exactly one statement, so the pragma cannot be undone
--- ahead of a write in the same call. Nothing is built, staged or
--- scanned: the only path read under the working directory is `o/`.
---
--- A cell is written as text: NULL as `\N`, a blob as `X'<hex>'`, a
--- backslash, tab, newline or carriage return inside text as `\\`,
--- `\t`, `\n` or `\r`, so one row is always one line. The verdict line
--- goes to stderr, not stdout, so the rows can be piped on as they are.

local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Log = require("cosmic.log")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Time = require("cosmic.time")
local clock = require("build.clock")

local log = Log.new("cosmic")

local record sql
  --- Where a statement runs.
  record Source
    --- What the verdict line and a complaint call it.
    name: string
    --- The database file; nil for the binary's own database.
    path: string | nil
  end

  --- A database `open` made read-only.
  record Opened
    db: Sqlite.Handle
    --- Whether the caller closes it: the binary's own database is the
    --- store's, borrowed, and is left open.
    owned: boolean
  end
end

--- The options `cosmic sql` takes: each names a database, and at most
--- one may be given.
local spec: {string:boolean} = { ["--db"] = true, ["--build"] = false, ["--store"] = false }

--- The database a command line names under `root`, the working
--- directory: `--db <path>`, `--build` (o/build.db), `--store` (the
--- binary's own database), or, with none of them, the project's own
--- o/cosmic.db when there is one and the binary's own otherwise. Nil
--- and why when more than one is named.
function sql.source(root: string, parsed: Flags.Parsed): sql.Source | nil, string
  local given: {string} = {}
  for _, name in ipairs({ "--db", "--build", "--store" }) do
    if parsed.set[name] or parsed.values[name] ~= nil then
      given[#given + 1] = name
    end
  end
  if #given > 1 then
    return nil, "name one database, not " .. table.concat(given, " and ")
  end
  local chosen = parsed.values["--db"]
  if chosen ~= nil then
    return { name = chosen, path = chosen }
  end
  if parsed.set["--build"] then
    return { name = "o/build.db", path = root .. "/o/build.db" }
  end
  if parsed.set["--store"] then
    return { name = "the binary's own database" }
  end
  local project = root .. "/o/cosmic.db"
  local present, trouble = Fs.exists(project)
  if present == nil then
    return nil, trouble
  end
  if present then
    return { name = "o/cosmic.db", path = project }
  end
  return { name = "the binary's own database" }
end

--- A handle on the source's database that SQLite will not let write.
--- A file is opened read-only with `PRAGMA query_only` set; the
--- binary's own database is the store's connection, whose authorizer
--- already refuses every statement but a query when it is prepared.
--- Nil and why when the file is missing or will not open.
function sql.open(source: sql.Source): sql.Opened | nil, string
  local path = source.path
  if path == nil then
    local all = Store.databases()
    local db = all[#all]
    if db == nil then
      return nil, "this binary carries no database"
    end
    return { db = db, owned = false }
  end
  local present, trouble = Fs.exists(path)
  if present == nil then
    return nil, trouble
  end
  if not present then
    return nil, "no such database"
  end
  local db, open_trouble = Sqlite.open(path, false)
  if db == nil then
    return nil, open_trouble
  end
  -- TODO: refuse ATTACH and VACUUM INTO when they are prepared, with
  -- sqlite3_limit(SQLITE_LIMIT_ATTACHED, 0), once cosmic.sqlite carries
  -- sqlite3_limit. query_only refuses VACUUM INTO's write, but only after
  -- SQLite has created the empty file it names; and ATTACH of an existing
  -- file or ':memory:' answers PASS, inert only because the one statement
  -- a call prepares leaves nothing after it to use the attachment.
  local ok, pragma_trouble = Sqlite.exec(db, "PRAGMA query_only = 1")
  if not ok then
    local _, _ = db:close()
    return nil, pragma_trouble
  end
  return { db = db, owned = true }
end

--- The shortest `%g` form that reads back as `x`, marked as a real
--- number with ".0" when it would otherwise read as an integer, as
--- SQLite writes one.
local function real(x: number): string
  local text = string.format("%.17g", x)
  for digits = 15, 16 do
    local shorter = string.format("%." .. digits .. "g", x)
    if tonumber(shorter) == x then
      text = shorter
      break
    end
  end
  if text:match("^%-?%d+$") then
    text = text .. ".0"
  end
  return text
end

local escapes: {string:string} = { ["\\"] = "\\\\", ["\t"] = "\\t", ["\n"] = "\\n", ["\r"] = "\\r" }

--- One cell as the text a row line carries.
function sql.cell(cell: Sqlite.Cell): string
  if cell.kind == "integer" then
    return string.format("%d", cell.integer)
  elseif cell.kind == "number" then
    return real(cell.number)
  elseif cell.kind == "text" then
    return (cell.text:gsub("[\\\t\n\r]", escapes))
  elseif cell.kind == "blob" then
    return "X'" .. (cell.blob:gsub(".", function(byte: string): string
      return string.format("%02X", byte:byte())
    end)) .. "'"
  end
  return "\\N"
end

--- Runs one statement on `db`, answering each row it yields as one
--- line. Nil and SQLite's own reason when it will not prepare or run --
--- a write among them.
function sql.query(db: Sqlite.Handle, statement: string): {string} | nil, string
  -- TODO: print a header line of column names once cosmic.sqlite carries
  -- sqlite3_column_name; a caller has only its own SELECT to go by now.
  local rows, trouble = Sqlite.rows(db, statement)
  if rows == nil then
    return nil, trouble
  end
  local lines: {string} = {}
  for _, row in ipairs(rows) do
    local cells: {string} = {}
    for index, cell in ipairs(row) do
      cells[index] = sql.cell(cell)
    end
    lines[#lines + 1] = table.concat(cells, "\t")
  end
  return lines, ""
end

--- The verdict line, on stderr so stdout holds only rows.
local function verdict(passed: boolean, detail: string)
  local _, _ = Fs.put(Fs.stderr, "sql: " .. (passed and "PASS" or "FAIL") ..
    " (" .. detail .. ")\n")
end

--- `cosmic sql [--db <path> | --build | --store] <statement>`: runs the
--- statement read-only against the database `sql.source` names, prints
--- its rows, and returns the exit code: 0 when it ran (no rows is not a
--- failure), 1 when the database or the statement failed, 2 for a
--- command line it cannot read.
--- @param argv the command line, `sql` at slot 1
--- @param root the directory whose o/ holds the databases; the working
---   directory when nil
function sql.run(argv: {integer:string}, root?: string): integer
  local started = Time.monotonic_ns()
  local parsed, parse_trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then
    log:complain("sql: " .. parse_trouble)
    return 2
  end
  if #parsed.words ~= 1 then
    log:complain("sql: give one statement, quoted as one argument: " ..
      "cosmic sql [--db <path> | --build | --store] '<statement>'")
    return 2
  end
  if root == nil then
    local here, trouble = Fs.absolute(".")
    if here == nil then
      log:complain("sql: " .. trouble)
      return 1
    end
    root = here
  end
  local source, source_trouble = sql.source(root, parsed)
  if source == nil then
    log:complain("sql: " .. source_trouble)
    return 2
  end
  local opened, open_trouble = sql.open(source)
  if opened == nil then
    log:complain("sql: " .. source.name .. ": " .. open_trouble)
    verdict(false, source.name .. ", " .. clock.elapsed_ms(started) .. " ms")
    return 1
  end
  local lines, trouble = sql.query(opened.db, parsed.words[1])
  if opened.owned then
    local _, _ = opened.db:close()
  end
  if lines == nil then
    log:complain("sql: " .. source.name .. ": " .. trouble)
    verdict(false, source.name .. ", " .. clock.elapsed_ms(started) .. " ms")
    return 1
  end
  for _, line in ipairs(lines) do
    log:say(line)
  end
  verdict(true, #lines .. (#lines == 1 and " row" or " rows") .. " from " ..
    source.name .. ", " .. clock.elapsed_ms(started) .. " ms")
  return 0
end

return sql
