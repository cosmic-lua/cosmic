--- `cosmic sql`: one SQL statement against a database, read-only, its
--- column names printed as a first line (none for a statement without
--- columns, such as most PRAGMAs that set) and its rows one per line
--- after, cells tab-separated. This is
--- how the build's own databases get asked a question without writing
--- a throwaway script -- a script must be built as a tree, and the
--- tree it would build is whatever directory it was run from.
---
--- It opens the database read-only and sets `PRAGMA query_only` before
--- running the statement, so SQLite itself refuses a write: nothing
--- here reads the statement's text to decide what it may do. SQLite
--- prepares exactly one statement, so the pragma cannot be undone
--- ahead of a write in the same call. What the database holds is never
--- changed, though SQLite may leave files beside it -- see `sql.open`.
--- Nothing is built, staged or scanned: the only directory looked in
--- is `o/` under the working directory, never one above it.
---
--- A cell, and a column's name, is written as text: NULL as `\N`, a
--- blob as `X'<hex>'`, and
--- inside text a backslash as `\\`, a tab, newline or carriage return
--- as `\t`, `\n` or `\r`, and any other control byte as `\xHH`, so one
--- row is always one line, no stored escape sequence reaches the
--- terminal, and undoing those escapes gives the stored bytes back. The
--- verdict line comes last on stdout, as every verb's does (see
--- build/verbs_test.tl), so a pipe that wants only the rows drops the
--- first line and the last; complaints go to stderr.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Time = require("cosmic.time")
local clock = require("build.clock")
local verdicts = require("build.verdict")

local log = verdicts.log

--- The `cosmic sql` verb: `run` is what `build/dispatch.tl` calls;
--- `source`, `open` and `query` are its steps, each testable on its
--- own.
local record sql
  --- Where a statement runs.
  record Source
    --- What the verdict line and a complaint call it.
    name: string
    --- The database file; nil for the binary's own database.
    path: string | nil
    --- Said after "no such database" when the file is missing.
    hint: string | nil
  end

  --- Where `run` writes: a row line, a complaint, and the verdict.
  --- `out` and `err` take a line without its newline.
  record Output
    out: function(line: string)
    err: function(line: string)
    verdict: function(passed: boolean, detail: string)
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
local spec = Cli.options.sql

--- The database a command line names under `root`, the working
--- directory: `--db <path>`, `--build` (o/build.db), `--store` (the
--- binary's own database), or, with none of them, the project's own
--- o/cosmic.db when there is one and the binary's own otherwise. Nil
--- and why when the line gives more than one of them, or one of them
--- twice, or `--db` names the empty path.
function sql.source(root: string, parsed: Flags.Parsed): sql.Source | nil, string
  if #parsed.given > 1 then
    return nil, "name one database, not " .. table.concat(parsed.given, " and ")
  end
  local chosen = parsed.values["--db"]
  if chosen ~= nil then
    if chosen == "" then
      return nil, "--db needs a path, not an empty one"
    end
    return { name = chosen, path = chosen }
  end
  local within = "; o/ is looked for only in the working directory, " ..
    "never above it"
  if parsed.set["--build"] then
    return { name = "o/build.db", path = root .. "/o/build.db",
      hint = root .. "/o/build.db" .. within }
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
--- Nil and why when the file is missing, is not a regular file (after
--- following symbolic links: SQLite would wait forever on a FIFO), or
--- will not open.
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
    return nil, "no such database: " .. (source.hint or path)
  end
  local st, stat_trouble = Fs.stat(path)
  if st == nil then
    return nil, stat_trouble
  end
  if st.kind ~= "file" then
    return nil, "not a regular file (its kind is " .. st.kind .. "), so not a database"
  end
  -- TODO: open with the URI's immutable=1, or SQLITE_OPEN_READONLY with
  -- nolock, once cosmic.sqlite.open takes a URI or open flags: a
  -- read-only open of a WAL-mode database whose -wal file is missing
  -- creates <db>-wal and <db>-shm beside it and leaves them there.
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
  local ok, pragma_trouble = db:exec("PRAGMA query_only = 1")
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

--- A backslash or control byte inside text, as its escape.
local function escape(byte: string): string
  return escapes[byte] or string.format("\\x%02X", byte:byte())
end

--- One cell as the text a row line carries.
local function cell_text(cell: Sqlite.Cell): string
  if cell.kind == "integer" then
    return string.format("%d", cell.integer)
  elseif cell.kind == "number" then
    return real(cell.number)
  elseif cell.kind == "text" then
    return (cell.text:gsub("[\\%c]", escape))
  elseif cell.kind == "blob" then
    return "X'" .. (cell.blob:gsub(".", function(byte: string): string
      return string.format("%02X", byte:byte())
    end)) .. "'"
  end
  return "\\N"
end

--- Runs one statement on `db`, answering its column names as one line
--- -- none for a statement without columns -- then each row it yields
--- as one line. Nil and why when it takes a parameter, or SQLite's own
--- reason when it will not prepare or run -- a write among them.
function sql.query(db: Sqlite.Handle, statement: string): {string} | nil, string
  local prepared, prepare_trouble = db:prepare(statement)
  if prepared == nil then
    return nil, prepare_trouble
  end
  -- Nothing is bound: a parameter left unbound would read as NULL.
  local wanted = prepared:parameters()
  if wanted > 0 then
    prepared:finalize()
    return nil, "the statement takes " .. wanted ..
      (wanted == 1 and " parameter" or " parameters") .. "; cosmic sql binds none"
  end
  local width = prepared:columns()
  local lines: {string} = {}
  local cells: {string} = {}
  for index = 0, width - 1 do
    cells[index + 1] = (prepared:name(index):gsub("[\\%c]", escape))
  end
  if width > 0 then
    lines[1] = table.concat(cells, "\t")
  end
  -- TODO: write each row as it is stepped rather than holding them all
  -- here, once `open` takes the database without locks (its immutable=1
  -- TODO): until then a statement holds a shared lock until it is
  -- finalized, so a reader of stdout that stalls (`| less`) would hold
  -- off every build's write for as long as it waits, and past SQLite's
  -- busy timeout fail it. `run` prints the rows once the statement is
  -- done.
  while true do
    local state, trouble = prepared:step()
    if state == nil then
      prepared:finalize()
      return nil, trouble
    end
    if state == "done" then
      break
    end
    for index = 0, width - 1 do
      cells[index + 1] = cell_text(Sqlite.cell(prepared, index))
    end
    lines[#lines + 1] = table.concat(cells, "\t")
  end
  prepared:finalize()
  return lines, ""
end

--- Said after a failure from the binary's own database, whose
--- authorizer lets a query through and no PRAGMA but data_version (its
--- refusal is SQLite's bare "not authorized"): what a PRAGMA would have
--- told, a query can.
local store_hint = "; the binary's own database answers a query and no PRAGMA " ..
  "but data_version: `SELECT * FROM <table> LIMIT 0` names a table's columns, " ..
  "and sqlite_schema holds each table's SQL"

--- Rows to stdout, then the verdict line through `build.verdict`'s
--- logger, which tells `build/dispatch.tl` one was given; complaints
--- to stderr.
local standard: sql.Output = {
  out = function(line: string)
    local _, _ = log:say(line)
  end,
  err = function(line: string)
    local _, _ = Fs.put(Fs.stderr, line .. "\n")
  end,
  verdict = function(passed: boolean, detail: string)
    local _, _ = log:verdict("sql", passed, detail)
  end,
}

--- `cosmic sql [--db <path> | --build | --store] <statement>`: runs the
--- statement read-only against the database `sql.source` names, prints
--- its rows, and returns the exit code: 0 when it ran (no rows is not a
--- failure), 1 when the database or the statement failed, 2 for a
--- command line it cannot read.
--- @param argv the command line, `sql` at slot 1
--- @param root the directory whose o/ holds the databases; the working
---   directory when nil
--- @param output where rows, complaints and the verdict go; stdout,
---   stderr and `build.verdict`'s logger when nil
function sql.run(argv: {integer:string}, root?: string, output?: sql.Output): integer
  local started = Time.monotonic_ns()
  local to = output or standard
  local function complain(line: string)
    to.err("cosmic: sql: " .. line)
  end
  local function verdict(passed: boolean, detail: string)
    to.verdict(passed, detail .. ", " .. clock.elapsed_ms(started) .. " ms")
  end
  local usage = "cosmic sql [--db <path> | --build | --store] '<statement>'"
  local parsed, parse_trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then
    complain(parse_trouble .. "; " .. usage)
    verdict(false, "usage: see `cosmic help sql`")
    return 2
  end
  if #parsed.words ~= 1 then
    complain("give one statement, quoted as one argument: " .. usage)
    verdict(false, "usage: see `cosmic help sql`")
    return 2
  end
  if root == nil then
    local here, trouble = Fs.absolute(".")
    if here == nil then
      complain(trouble)
      verdict(false, "no working directory")
      return 1
    end
    root = here
  end
  local source, source_trouble = sql.source(root, parsed)
  if source == nil then
    complain(source_trouble .. "; " .. usage)
    verdict(false, "usage: see `cosmic help sql`")
    return 2
  end
  local opened, open_trouble = sql.open(source)
  if opened == nil then
    complain(source.name .. ": " .. open_trouble)
    verdict(false, source.name)
    return 1
  end
  local lines, trouble = sql.query(opened.db, parsed.words[1])
  if opened.owned then
    local _, _ = opened.db:close()
  end
  if lines == nil then
    if source.path == nil then
      trouble = trouble .. store_hint
    end
    complain(source.name .. ": " .. trouble)
    verdict(false, source.name)
    return 1
  end
  for _, line in ipairs(lines) do
    to.out(line)
  end
  local rows = math.max(#lines - 1, 0)
  verdict(true, rows .. (rows == 1 and " row" or " rows") .. " from " .. source.name)
  return 0
end

return sql
