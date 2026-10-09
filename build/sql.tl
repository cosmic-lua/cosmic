--- `cosmic sql`: one SQL statement against a database, read-only. The
--- column names print as a first line (none for a statement without
--- columns, such as most PRAGMAs that set), then the rows, one per line,
--- cells tab-separated. This is how the build's own databases get asked
--- a question without a throwaway script: a script must be built as a
--- tree, and the tree it would build is whatever directory it was run
--- from.
---
--- The verb opens the database read-only and sets `PRAGMA query_only`
--- before running the statement, so SQLite itself refuses a write;
--- nothing here reads the statement's text to decide what it may do.
--- SQLite prepares exactly one statement, so the pragma cannot be
--- undone ahead of a write in the same call. What the database holds is
--- never changed, though SQLite may leave files beside it (see
--- [`sql.open`]). Nothing is built, staged or scanned: the only directory
--- looked in is the working directory's build directory, never a
--- project's above it.
---
--- A cell, and a column's name, is written as text. NULL is `\N` and a
--- blob is `X'<hex>'`. Inside text, a backslash is `\\`, a tab, newline
--- or carriage return is `\t`, `\n` or `\r`, and any other control byte
--- is `\xHH`. So one row is always one line, no stored escape sequence
--- reaches the terminal, and undoing those escapes gives the stored
--- bytes back. The verdict line comes last on stdout, as every verb's
--- does (see build/verbs_tool_test.tl), so a pipe that wants only the
--- rows drops the first line and the last. Complaints go to stderr.
---
--- `--from <file|->` asks the same of a data file instead of a database.
--- Each `--from` is loaded as a table of an in-memory database
--- ([`build.dataset`] says how: the columns, how a value is stored, the
--- `_json` column), and the statement runs on that, under the same
--- read-only guard, with the same rows and verdict. `--as <format>`,
--- `--at '<path>'` and `--raw` belong to the `--from` they follow. With
--- no statement the verb prints each table's name, row count, columns
--- with the SQLite types seen, and a sample row. `no such column` and
--- `no such table` are answered with the names that exist. The database
--- is built from the data alone, so no build directory is read.

local build_paths = require("build.paths")
local Cli = require("cosmic.cli")
local Clock = require("cosmic.clock")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local bare = require("build.bare")
local clock = require("build.clock")
local dataset = require("build.dataset")
local verdicts = require("build.verdict")
local verb_spec = require("build.verb_spec")

local log = verdicts.log

--- The `cosmic sql` verb: `run` is what [`build/dispatch.tl`] calls;
--- `source`, `open` and `query` are its steps, each testable on its
--- own.
local record sql
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
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
  --- `out` and `err` take a line without its newline. `out` answers
  --- false and why when it could not write the line (a closed pipe),
  --- and the statement is stepped no further.
  record Output
    out: function(line: string): boolean, string
    err: function(line: string)
    verdict: function(passed: boolean, detail: string)
  end

  --- One `--from`: a data file to load as a table.
  record Input
    --- The file; nil for standard input.
    path: string | nil
    --- What a complaint calls it: the path, or "standard input".
    label: string
    --- The table's name.
    table: string
    --- The format's name, as [`dataset.read`] takes it.
    format: string
    --- Where in the document the rows are; nil for all of it.
    at: Json.Steps
    --- Keep every cell of a CSV or TSV as text.
    raw: boolean
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
local spec = Cli.verbs.sql.spec

--- The database a command line names under `root`, the working
--- directory: `--db <path>`, `--build` (its build directory's
--- build.db), `--store` (the binary's own database), or, with none of
--- them, the project's own cosmic.db when there is one and the binary's
--- own otherwise, each named by its path. Nil
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
  local within = "; the build directory is the working directory's, " ..
    "never a project's above it"
  if parsed.set["--build"] then
    local directory, trouble = build_paths.directory(root)
    if directory == nil then return nil, trouble end
    local working = build_paths.under(directory).working
    return { name = working, path = working, hint = working .. within }
  end
  if parsed.set["--store"] then
    return { name = "the binary's own database" }
  end
  local directory, directory_trouble = build_paths.optional(root)
  if directory == nil then
    if directory_trouble ~= "" then return nil, directory_trouble end
    return { name = "the binary's own database" }
  end
  local project = build_paths.under(directory).projection
  local present, trouble = Fs.exists(project)
  if present == nil then
    return nil, trouble
  end
  if present then
    return { name = project, path = project }
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
function sql.open(source: sql.Source, between?: function()): sql.Opened | nil, string
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
  -- Immutable where nothing lives outside the file: no lock is taken,
  -- and no -wal or -shm is made beside a WAL-mode database whose -wal
  -- file is missing. SQLite never reads the -wal of an immutable
  -- database, so one that holds frames (commits not yet checkpointed, as
  -- a build's database has while it runs) is opened the ordinary
  -- read-only way instead. That open reads the frames and takes the
  -- shared lock while a statement runs. The -wal is looked at again once
  -- the immutable open is made, and a frame that has come since sends
  -- the open the ordinary way after all; what is committed after that
  -- look is concurrent with the query.
  -- Decided limit: a database with no -wal that a build checkpoints or
  -- rewrites during the query may be read torn, which a one-shot query
  -- accepts. Only holding its lock would prevent that, and avoiding that
  -- lock is what an immutable open is for.
  local wal = path .. "-wal"
  local function has_frames(): boolean | nil, string
    local there, exists_trouble = Fs.exists(wal)
    if there == nil then
      return nil, exists_trouble
    end
    if not there then
      return false, ""
    end
    local wal_stat, wal_stat_trouble = Fs.stat(wal)
    if wal_stat == nil then
      return nil, wal_stat_trouble
    end
    return wal_stat.size > 0, ""
  end
  local frames, wal_trouble = has_frames()
  if frames == nil then
    return nil, wal_trouble
  end
  if between ~= nil then
    between()
  end
  local db, open_trouble = Sqlite.open(path, { immutable = not frames })
  if db == nil then
    return nil, open_trouble
  end
  if not frames then
    local later, later_trouble = has_frames()
    if later == nil then
      local _, _ = db:close()
      return nil, later_trouble
    end
    if later then
      local _, _ = db:close()
      db, open_trouble = Sqlite.open(path)
      if db == nil then
        return nil, open_trouble
      end
    end
  end
  -- No ATTACH, and so no VACUUM INTO, which attaches the file it names:
  -- query_only refuses that write only after SQLite has created the
  -- empty file, and ATTACH of an existing file or ':memory:' would pass.
  local _ = db:limit("attached", 0)
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

--- A backslash or control byte inside a cell or a column name, as
--- [`bare.escape`] writes it with `named`.
local function escape(text: string): string
  return bare.escape(text, { named = true })
end

--- Column `index` of the row `statement` stands on, as the text a row
--- line carries.
local function cell_text(statement: Sqlite.Statement, index: integer): string
  local kind = statement:kind(index)
  if kind == "integer" then
    return string.format("%d", statement:integer(index))
  elseif kind == "number" then
    return real(statement:number(index))
  elseif kind == "text" then
    return escape(statement:bytes(index))
  elseif kind == "blob" then
    return "X'" .. (statement:bytes(index):gsub(".", function(byte: string): string
      return string.format("%02X", byte:byte())
    end)) .. "'"
  end
  return "\\N"
end

--- Runs one statement on `db`, giving `emit` its column names as one
--- line (none for a statement without columns), then each row it yields
--- as one line, the moment it is stepped. Answers how many rows it
--- yielded, or nil and why when the statement takes a parameter, or
--- SQLite's own reason when it will not prepare or run (a write among
--- them). The lines before a failure have been given by then. `emit`
--- answers false and why when it could not write the line; the
--- statement is stepped no further, and that is the failure answered.
local function stream(db: Sqlite.Handle, statement: string,
                      emit: function(string): boolean, string): integer | nil, string
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
  local cells: {string} = {}
  for index = 0, width - 1 do
    cells[index + 1] = escape(prepared:name(index))
  end
  if width > 0 then
    local written, write_trouble = emit(table.concat(cells, "\t"))
    if not written then
      prepared:finalize()
      return nil, write_trouble
    end
  end
  local rows = 0
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
      cells[index + 1] = cell_text(prepared, index)
    end
    rows = rows + 1
    local written, write_trouble = emit(table.concat(cells, "\t"))
    if not written then
      prepared:finalize()
      return nil, write_trouble
    end
  end
  prepared:finalize()
  return rows, ""
end

--- `stream`'s lines held: the column names' line, if any, then a line
--- per row; nil and why when it failed.
function sql.query(db: Sqlite.Handle, statement: string): {string} | nil, string
  local lines: {string} = {}
  local rows, trouble = stream(db, statement, function(line: string): boolean, string
    lines[#lines + 1] = line
    return true, ""
  end)
  if rows == nil then
    return nil, trouble
  end
  return lines, ""
end

--- Said after a failure from the binary's own database, whose
--- authorizer lets a query through and no PRAGMA but data_version (its
--- refusal is SQLite's bare "not authorized"): what a PRAGMA would have
--- told, a query can.
local store_hint = "; the binary's own database answers a query and no PRAGMA " ..
  "but data_version: `SELECT * FROM <table> LIMIT 0` names a table's columns, " ..
  "and sqlite_schema holds each table's SQL"

--- Rows to stdout, then the verdict line through [`build.verdict`]'s
--- logger, which tells [`build/dispatch.tl`] one was given; complaints
--- to stderr.
local standard: sql.Output = {
  out = function(line: string): boolean, string
    return log:say(line)
  end,
  err = function(line: string)
    local _, _ = Fs.put(Fs.stderr, line .. "\n")
  end,
  verdict = function(passed: boolean, detail: string)
    local _, _ = log:verdict("sql", passed, detail)
  end,
}

--- The usage of `--from`, in a complaint about the line.
local from_usage = "cosmic sql --from <file|-> [--as json|ndjson|csv|tsv] [--at '<path>'] [--raw] " ..
  "[--from ...] ['<statement>']"

--- A table name from a file name: its stem (without the last
--- extension), each run of anything but a letter, digit or underscore
--- an underscore, and a leading underscore when it would begin with a
--- digit. `data` when nothing is left.
local function stem_of(path: string): string
  local base = path:match("[^/]*$")
  local stem = base:match("^(.+)%.[^.]*$") or base
  stem = stem:gsub("[^%w_]+", "_")
  if stem == "" or stem == "_" then
    return "data"
  end
  if stem:match("^%d") then
    stem = "_" .. stem
  end
  return stem
end

--- The `--from`s a command line names, each with the `--as`, `--at` and
--- `--raw` that follow it and before the next `--from`: `--from a.json --at
--- '$.rows' --from b.jsonl` reads a's rows from `$.rows` and b whole. A
--- `--from` is `<file>`, `<name>=<file>` (a name of letters, digits and
--- underscores before the first `=`, so a file with an `=` in its name
--- is written `./x=y.json`), or `-` for standard input, which has no
--- extension and so needs `--as`. The format is `--as`, else the file's
--- extension. Nil and why when a line names none of them, gives `--as`
--- or `--at` before any `--from`, names an unknown format or a bad
--- path, two tables the same name (case aside), or a file no format
--- reads.
local function read_inputs(parsed: Flags.Parsed): {sql.Input} | nil, string
  local inputs: {sql.Input} = {}
  local given_as: {integer:boolean} = {}
  local given_at: {integer:boolean} = {}
  local given_raw: {integer:boolean} = {}
  local stdin_seen = false
  local seen: {string:integer} = {}
  local counts: {string:integer} = {}
  for _, name in ipairs(parsed.given) do
    local index = (counts[name] or 0) + 1
    counts[name] = index
    local value = parsed.all[name] and parsed.all[name][index]
    if name == "--from" then
      local label = value
      local table_name: string | nil
      local given_name, rest = value:match("^([%w_]+)=(.*)$")
      if given_name ~= nil then
        if not given_name:match("^[%a_]") then
          return nil, "a table name begins with a letter or underscore, not " .. given_name
        end
        table_name, label = given_name, rest
      end
      if label == "" then
        return nil, "--from needs a file, not an empty one"
      end
      local input: sql.Input = { label = label, table = "", format = "", path = label }
      if label == "-" then
        if stdin_seen then
          return nil, "standard input can be read once; a second --from - would find it empty"
        end
        stdin_seen = true
        input.path, input.label = nil, "standard input"
      end
      input.table = table_name or (input.path and stem_of(input.path) or "stdin")
      local clash = seen[input.table:lower()]
      if clash ~= nil then
        return nil, "two tables are named " .. input.table .. " (" ..
          inputs[clash].label .. " and " .. input.label .. "); name one: --from <name>=<file>"
      end
      inputs[#inputs + 1] = input
      seen[input.table:lower()] = #inputs
    elseif name == "--raw" then
      local input = inputs[#inputs]
      if input == nil then
        return nil, "--raw belongs to the --from before it; give --from first"
      end
      if given_raw[#inputs] then
        return nil, "--raw is given twice for " .. input.label
      end
      given_raw[#inputs] = true
      input.raw = true
    elseif name == "--as" or name == "--at" then
      local input = inputs[#inputs]
      if input == nil then
        return nil, name .. " belongs to the --from before it; give --from first"
      end
      local given = name == "--as" and given_as or given_at
      if given[#inputs] then
        return nil, name .. " is given twice for " .. input.label
      end
      given[#inputs] = true
      if name == "--as" then
        if dataset.about(value) == nil then
          return nil, "dataset: no format " .. value .. " (known: " .. table.concat(dataset.names(), ", ") .. ")"
        end
        input.format = value
      else
        local steps, why = Json.from_path(value)
        if steps == nil then
          local query, _ = Json.query(value)
          if query ~= nil then
            why = "--at names one value, and `*` and `..` can match many"
          end
          return nil, "--at " .. value .. ": " .. (why:gsub("^json: ", ""))
        end
        input.at = steps
      end
    end
  end
  for _, input in ipairs(inputs) do
    if input.format == "" then
      if input.path == nil then
        return nil, "standard input has no extension to read a format from; " ..
          "give --as (" .. table.concat(dataset.names(), ", ") .. ") after its --from -"
      end
      local format, why = dataset.format_of(input.path)
      if format == nil then
        return nil, input.label .. ": " .. why .. "; or give --as after its --from"
      end
      input.format = format
    end
  end
  return inputs, ""
end

--- `text` with a control byte as `\xHH`, so a name or a sample never
--- moves the terminal.
local function plain(text: string): string
  return bare.escape(text)
end

--- Loaded tables' names of columns, for a hint: one table's columns as
--- "a, b, c", several as "t: a, b; u: c".
local function column_lists(tables: {dataset.Table}): string
  if #tables == 1 then
    return plain(table.concat(tables[1].columns, ", "))
  end
  local parts: {string} = {}
  for _, each in ipairs(tables) do
    parts[#parts + 1] = plain(each.name .. ": " .. table.concat(each.columns, ", "))
  end
  return table.concat(parts, "; ")
end

--- SQLite's `trouble` with what would have helped appended: the columns
--- there are after `no such column`, the tables after `no such table`.
--- Anything else as it was.
local function hinted(trouble: string, tables: {dataset.Table}): string
  if trouble:find("^no such column") then
    return trouble .. "; columns: " .. column_lists(tables)
  elseif trouble:find("^no such table") then
    local names: {string} = {}
    for _, each in ipairs(tables) do
      names[#names + 1] = each.name
    end
    return trouble .. "; tables: " .. table.concat(names, ", ")
  end
  return trouble
end

--- The lines that describe the loaded tables, for a statement-less
--- `--from`: per table its name and row count, each column with the
--- SQLite types stored in it (`integer`, `real`, `text`, `null`, joined
--- by `|`; none for a table without rows), and the first row as JSON,
--- cut at 200 bytes. Nil and why when SQLite fails.
local function describe(db: Sqlite.Handle, tables: {dataset.Table}): {string} | nil, string
  local lines: {string} = {}
  for _, each in ipairs(tables) do
    lines[#lines + 1] = each.name .. ": " .. each.count .. (each.count == 1 and " row" or " rows")
    local width = 0
    for _, column in ipairs(each.columns) do
      width = math.max(width, #plain(column))
    end
    local from = ' FROM "' .. each.name:gsub('"', '""') .. '"'
    for _, column in ipairs(each.columns) do
      local rows, trouble = Sqlite.text_rows(db, 'SELECT DISTINCT typeof("' ..
          column:gsub('"', '""') .. '")' .. from .. " ORDER BY 1")
      if rows == nil then
        return nil, trouble
      end
      local types: {string} = {}
      for _, row in ipairs(rows) do
        types[#types + 1] = row[1]
      end
      local name = plain(column)
      local line = "  " .. name .. string.rep(" ", width - #name) .. "  " .. (#types > 0 and table.concat(types, "|") or "-")
      local original = each.renamed[column]
      if original ~= nil then
        line = line .. "  (the key " .. plain(Json.quote(original)) .. ")"
      end
      lines[#lines + 1] = line
    end
    local sample, trouble = Sqlite.text_rows(db, 'SELECT "_json"' .. from .. " LIMIT 1")
    if sample == nil then
      return nil, trouble
    end
    if sample[1] ~= nil then
      local text = plain(sample[1][1])
      if #text > 200 then
        text = text:sub(1, 200) .. "..."
      end
      lines[#lines + 1] = "  sample: " .. text
    end
  end
  return lines, ""
end

--- The bytes of standard input, refusing a terminal, where nothing
--- would ever end them.
local function read_stdin(): string | nil, string
  return bare.stdin_text("standard input is a terminal; pipe the data in")
end

--- `cosmic sql --from ...`, after `run` has parsed the line: loads each
--- file into an in-memory database, then answers the statement, or the
--- schema when there is none. 2 for a line it cannot read -- and any
--- other option beside `--from`, which names the database instead --
--- and 1 for a file it cannot read, load or a statement that fails.
local function run_from(parsed: Flags.Parsed, to: sql.Output,
                        verdict: function(passed: boolean, detail: string),
                        complain: function(line: string),
                        stdin: function(): string | nil, string): integer
  local usage = from_usage
  local function refuse(why: string): integer
    complain(why .. "; " .. usage)
    verdict(false, "usage: see `cosmic help sql`")
    return 2
  end
  for _, other in ipairs({ "--db", "--build", "--store" }) do
    if parsed.set[other] or parsed.all[other] then
      return refuse("--from is a database of its own, not to be given with " .. other)
    end
  end
  if #parsed.words > 1 then
    return refuse("give one statement, quoted as one argument, or none")
  end
  local found, trouble = read_inputs(parsed)
  if found == nil then
    return refuse(trouble)
  end
  local inputs: {sql.Input} = found
  local labels: {string} = {}
  for index, input in ipairs(inputs) do
    labels[index] = input.label
  end
  local source = table.concat(labels, ", ")
  local opened, memory_trouble = Sqlite.memory()
  if opened == nil then
    complain(memory_trouble)
    verdict(false, source)
    return 1
  end
  local db: Sqlite.Handle = opened
  local function fail(why: string): integer
    local _, _ = db:close()
    complain(why)
    verdict(false, source)
    return 1
  end
  local tables: {dataset.Table} = {}
  for _, input in ipairs(inputs) do
    local text: string | nil
    local read_trouble: string
    if input.path == nil then
      text, read_trouble = stdin()
    else
      text, read_trouble = Fs.read(input.path)
    end
    if text == nil then
      -- A file's failure already names the file; standard input's does not.
      return fail(input.path == nil and input.label .. ": " .. read_trouble or read_trouble)
    end
    local rows, format_trouble = dataset.read(input.format, text, { at = input.at, raw = input.raw })
    if rows == nil then
      return fail(input.label .. ": " .. format_trouble)
    end
    local loaded, load_trouble = dataset.load(db, input.table, rows)
    if loaded == nil then
      return fail(input.label .. ": " .. load_trouble)
    end
    tables[#tables + 1] = loaded
  end
  -- The tables are the data's own, and the statement may not change them,
  -- nor attach a file (which VACUUM INTO does too, creating it).
  local _ = db:limit("attached", 0)
  local guarded, guard_trouble = db:exec("PRAGMA query_only = 1")
  if not guarded then
    return fail(guard_trouble)
  end
  local counted: string
  if parsed.words[1] == nil then
    local lines, describe_trouble = describe(db, tables)
    if lines == nil then
      return fail(source .. ": " .. hinted(describe_trouble, tables))
    end
    for _, line in ipairs(lines) do
      local written, write_trouble = to.out(line)
      if not written then
        return fail(source .. ": " .. write_trouble)
      end
    end
    counted = #tables .. (#tables == 1 and " table" or " tables")
  else
    local rows, statement_trouble = stream(db, parsed.words[1], to.out)
    if rows == nil then
      return fail(source .. ": " .. hinted(statement_trouble, tables))
    end
    counted = rows .. (rows == 1 and " row" or " rows")
  end
  local _, _ = db:close()
  verdict(true, counted .. " from " .. source)
  return 0
end

--- `cosmic sql [--db <path> | --build | --store] <statement>`: runs the
--- statement read-only against the database [`sql.source`] names, prints
--- its rows, and returns the exit code: 0 when it ran (no rows is not a
--- failure), 1 when the database or the statement failed, 2 for a
--- command line it cannot read.
--- @param argv the command line, `sql` at slot 1
--- @param root the directory whose build directory holds the databases; the working
---   directory when nil
--- @param output where rows, complaints and the verdict go; stdout,
---   stderr and [`build.verdict`]'s logger when nil
--- @param stdin the whole of standard input for `--from -`, or nil and
---   why; the process's own when nil
function sql.run(argv: {integer:string}, root?: string, output?: sql.Output,
                 stdin?: function(): string | nil, string): integer
  local started = Clock.monotonic_ns()
  local to = output or standard
  local function complain(line: string)
    to.err("cosmic: sql: " .. line)
  end
  local function verdict(passed: boolean, detail: string)
    to.verdict(passed, detail .. ", " .. clock.took(started))
  end
  local usage = "cosmic sql [--db <path> | --build | --store] '<statement>' | " .. from_usage
  local parsed, parse_trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then
    complain(parse_trouble .. "; " .. usage)
    verdict(false, "usage: see `cosmic help sql`")
    return 2
  end
  if parsed.all["--from"] or parsed.all["--as"] or parsed.all["--at"] or parsed.set["--raw"] then
    return run_from(parsed, to, verdict, complain, stdin or read_stdin)
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
  local rows, trouble = stream(opened.db, parsed.words[1], to.out)
  if opened.owned then
    local _, _ = opened.db:close()
  end
  if rows == nil then
    if source.path == nil then
      trouble = trouble .. store_hint
    end
    complain(source.name .. ": " .. trouble)
    verdict(false, source.name)
    return 1
  end
  verdict(true, rows .. (rows == 1 and " row" or " rows") .. " from " .. source.name)
  return 0
end

--- The `sql` verb as [`build/verb_list.tl`] lists it. Never stale-checked,
--- unlike `db`: a staleness check stages the tree, and this verb reads
--- the build directory's databases and nothing of the tree. It gives its own verdict on every exit, a
--- usage error included, so the check main runs after a verdictless exit
--- 2 never runs for it (build/verbs_store_test.tl's
--- test_sql_never_stages_the_tree).
sql.spec = {
  name = "sql",
  guide = "questions about a data file",
  tests = { "build.sql_test", "build.sql_tool_test", "build.sql_store_test" },
  run = function(argv: {integer:string}): integer return sql.run(argv) end,
  bare = false,
  takes = "one statement",
}

return sql
