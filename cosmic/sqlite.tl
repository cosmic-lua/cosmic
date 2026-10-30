--- SQLite, typed.
---
--- Values keep their type: text and bytes are different, and a parameter
--- is bound by naming what it is. On top of a handle this module gives
--- the shapes a caller wants: a query that yields rows, all at once
--- (`rows`) or one at a time (`query`), a statement run once (`run`),
--- and a transaction that rolls back when the work inside it fails
--- (`transact`).
---
--- A parameter is a one-field table naming its type, one per `?N`, in
--- order; a result row is read a column at a time by the type the caller
--- expects, from 1:
---
---     local db = assert(Sqlite.open("notes.db", { writable = true }))
---     assert(db:exec("CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, body TEXT)"))
---     assert(Sqlite.run(db, "INSERT INTO t (body) VALUES (?1)", { { text = "hi" } }))
---     local rows = assert(Sqlite.rows(db, "SELECT id, body FROM t WHERE id = ?1",
---       { { integer = db:last_insert_rowid() } }))
---     print(rows[1]:integer(1), rows[1]:text(2)) -- 1  hi
---
--- `{ integer = n }`, `{ number = x }`, `{ text = s }` and `{ blob = b }`
--- bind those types; `{}` binds NULL. A [`Sqlite.Row`] is not a list:
--- `row:text(2)`, `row:integer(2)`, `row:number(2)` and `row:blob(2)` answer
--- column 2 when it holds that type, and raise when it does not;
--- [`Sqlite.map`] turns each row into a record of such reads.
---
--- SQLite's JSON functions read JSON5 always, and in cosmic's copy `#`
--- line comments too, as `cosmic.json` does given `hash_comments`: a
--- text in YAML's flow style reads the same through either.
---
--- Every handle answers the SQL functions, virtual tables and
--- collations [the SQL guide](doc/guides/sql.md) lists, and only those:
--- SQLite's own, its math and percentile functions, cosmic's, and the
--- extensions from SQLite's `ext/misc/` the core is built with
--- (`generate_series`, `REGEXP`, `decimal`, `uuid`, `sha3`, `base64`,
--- `compress`, ...).

-- The raw module behind this one lives under the reserved
-- `cosmic.internal.` namespace, which never satisfies an ordinary
-- `require` for any caller -- see cosmic/store.tl for why -- and
-- arrives instead as the second argument `require` passes this
-- chunk's own loader, present because this module was itself loaded,
-- trusted, from the binary's own tree. Boot mode falls back to
-- requiring it by name, which only boot's own preload answers.
local type raw_sqlite = require("cosmic.internal.sqlite")

local extra: any = select(2, ...)
local sqlite: raw_sqlite
if type(extra) == "table" then
  sqlite = extra as raw_sqlite
else
  sqlite = require("cosmic.internal.sqlite")
end

local record Sqlite
  --- An open database, as `open` and `memory` return it: the type to
  --- name for a parameter or field that holds one. Its methods (`exec`,
  --- `prepare`, ...) are listed by `cosmic docs Sqlite.Handle`.
  type Handle = raw_sqlite.Handle
  --- One prepared statement.
  type Statement = raw_sqlite.Statement

  --- One execution's SQLite result, independent of later calls, closes
  --- and statement finalizers. `code` is the primary result code and
  --- `extended_code` retains its extended detail. Both are [`Sqlite.OK`]
  --- on success, with an empty `reason`; otherwise `reason` is for a
  --- person. `cancelled` says the busy handler installed by
  --- `handle:busy_timeout(ns)` stopped this call for an unread guard
  --- signal. SQLite's codes stay unchanged, usually BUSY; cancellation
  --- does not imply SQLITE_INTERRUPT or a rollback. The signal remains
  --- available to the guard. Reading that guard clears its notification
  --- for later waits even though `guard:cancelled()` remembers it.
  --- No statement is retried: earlier statements in a batch
  --- may already have changed the database when a later one fails.
  --- `handle:exec_result(sql)` returns this record alone. A closed
  --- handle or SQL containing a NUL raises; `handle:exec` returns
  --- false and a reason for SQL containing a NUL.
  type ExecResult = raw_sqlite.ExecResult

  --- An open attempt, with `handle` only on success. Outcome fields follow [`ExecResult`].
  type OpenResult = raw_sqlite.OpenResult
  --- A prepared statement, with `statement` only on success.
  type PrepareResult = raw_sqlite.PrepareResult
  --- All typed rows, or no rows on a captured failure.
  record RowsResult is raw_sqlite.Outcome
    --- Every row on success; nil on failure, including a failed later step.
    rows?: Rows
    --- The primary SQLite code; [`Sqlite.OK`] on success.
    code: integer
    --- The extended SQLite code, captured before cleanup; zero on success.
    extended_code: integer
    --- A diagnostic for a person; empty on success, never parsed for a decision.
    reason: string
    --- A busy wait stopped for an unread guard signal; see [`ExecResult`].
    cancelled: boolean
  end
  --- All text rows, or no rows on a captured failure.
  record TextRowsResult is raw_sqlite.Outcome
    --- Every row on success; nil on failure, including a failed later step.
    rows?: Rows
    --- The primary SQLite code; [`Sqlite.OK`] on success.
    code: integer
    --- The extended SQLite code, captured before cleanup; zero on success.
    extended_code: integer
    --- A diagnostic for a person; empty on success, never parsed for a decision.
    reason: string
    --- A busy wait stopped for an unread guard signal; see [`ExecResult`].
    cancelled: boolean
  end
  --- Successful execution.
  OK: integer
  --- Another connection prevents the operation; extended_code can
  --- distinguish cases such as a stale WAL snapshot requiring rollback.
  BUSY: integer
  --- This connection, or one sharing its cache, prevents the operation.
  LOCKED: integer
  --- SQLite found a malformed database structure.
  CORRUPT: integer
  --- SQLite did not recognize a database file.
  NOTADB: integer

  --- One bound parameter. Its field says what SQLite is told it is, so
  --- a blob never arrives as text by accident. At most one field is
  --- allowed; an empty table explicitly binds SQL NULL. A value of
  --- another shape raises where it is bound. A list in `integers`,
  --- `numbers`, `texts` or `blobs` is bound as an array that only
  --- `carray(?N)` reads, as a table of its elements: `x IN carray(?1)`
  --- tests membership in it. Used as a value, compared, stored or
  --- returned, it is NULL.
  type Value = raw_sqlite.Value

  --- The SQLite storage class of a result cell, as [`Sqlite.Row.kind`] names
  --- it.
  enum Kind
    "null"
    "integer"
    "number"
    "text"
    "blob"
  end

  --- How [`Sqlite.open`] opens a database.
  record OpenOptions
    --- Opens for reading and writing. Without it the database is read-only.
    writable?: boolean
    --- With `writable`, creates a missing file unless explicitly false.
    --- False refuses a missing named file; read-only opens never create.
    create?: boolean
    --- Opens read-only a database that nothing will change while it is
    --- open: see [`Sqlite.open`]. Giving it with `writable` raises.
    immutable?: boolean
  end

  --- One result row, read a column at a time. A column is its position
  --- from 1; the accessor names the type the caller expects, and a
  --- column of any other type raises, as does a position the row has no
  --- column at, so a query that does not answer what the reader assumed
  --- fails where it is read, not later. A row is no list: it has no
  --- numeric keys, and `#row` is not its length (use `count`). Code the
  --- checker does not see (a cast, an `any`, a Lua chunk) that indexes a row
  --- reads the row's internal slots, kinds mixed with values, and nothing
  --- refuses it: read a row only through its accessors.
  ---
  ---     local db = assert(Sqlite.memory())
  ---     local rows = assert(Sqlite.rows(db, "SELECT 7, 'seven', NULL, x'ff'"))
  ---     local row = rows[1]
  ---     print(row:count(), row:integer(1), row:text(2), row:is_null(3), #row:blob(4))
  ---
  --- `rows` and [`Sqlite.query`] answer rows that keep each column's
  --- SQLite type; [`Sqlite.text_rows`] answers rows whose every column is
  --- text.
  interface Row
    --- The number of columns.
    count: function(Row): integer
    --- The type of the column: `"null"` for SQL NULL. A row from
    --- [`text_rows`] has only `"text"` columns.
    kind: function(Row, integer): Kind
    --- Whether the column is SQL NULL. Always false for a row from
    --- [`text_rows`], which holds no NULL.
    is_null: function(Row, integer): boolean
    --- The column of an INTEGER cell. A number, text or NULL cell raises.
    integer: function(Row, integer): integer
    --- The column of an INTEGER or REAL cell, an integer as the nearest
    --- float (one beyond 2^53 rounds). A REAL cell is answered as stored,
    --- `-0.0` included. Text, a blob or NULL raises.
    number: function(Row, integer): number
    --- The column of a TEXT cell, or of any column of a row from
    --- [`text_rows`]. An integer, number, blob or NULL cell of a typed
    --- row raises.
    text: function(Row, integer): string
    --- The bytes of a BLOB cell. Any other cell raises, and so does a
    --- column of a row from [`text_rows`].
    blob: function(Row, integer): string
    --- The bytes of a TEXT or BLOB cell, for a column that may hold
    --- either. An integer, number or NULL cell raises.
    bytes: function(Row, integer): string
    --- Every column as `text` answers it, in order, as a new list: for a
    --- row from [`text_rows`], its columns. A column of another type
    --- raises.
    texts: function(Row): {string}
    --- The parameter that binds this column back as it is, of the type
    --- `kind` names: `{ integer = n }`, `{ number = x }`, `{ text = s }`,
    --- `{ blob = b }`, and `{}` for NULL. It is how a row is copied to
    --- another table.
    value: function(Row, integer): Value
  end

  --- Every row of a result, in the order the query gave them.
  type Rows = {Row}

  --- A query's rows read one at a time: see [`Sqlite.query`].
  interface Query
    __close: function(Query)
    --- The next row, and ""; nil and "" after the last; nil and why
    --- when stepping failed, the same again on every later read.
    read: function(Query): Row?, string
    --- An iterator for a `for` loop over the rows still to come. It
    --- ends at the last one or at a failure, which `failure` then says.
    each: function(Query): function(): Row?
    --- Why the rows ended early, or "" when they have not: after an
    --- `each` loop that ran out, "" means every row was read. A `break`,
    --- or a `close` inside the loop, ends it early with no failure.
    failure: function(Query): string
    --- Finalizes the statement, so the handle can close; the last
    --- row, a failure and a `<close>` variable each do it too. A read
    --- afterward fails. Closing again does nothing.
    close: function(Query)
  end

  --- The version of SQLite the core carries.
  version: string
end

--- Opens the database file at `path`: read-only unless `opts.writable`
--- is true, in which case a missing file is created unless `opts.create`
--- is false. Answers the handle,
--- or `nil` and why. `opts` that is not a table raises.
--- SQLite's special empty and `:memory:` paths still open temporary
--- databases, including with `create = false`.
---
--- `opts.immutable` opens a database that nothing will change while it
--- is open, read-only and with no lock: no `-wal`, `-shm` or journal file
--- is made beside it, and a running statement holds nothing a writer
--- waits on. A `-wal` is never read, so commits still in one do not
--- show: open a database that is being written without `immutable`.
--- Giving `immutable` with `writable` raises.
---
--- Every handle adds these SQL functions, each answering NULL for a NULL
--- argument:
---
--- - `sha256(X)`: the 32-byte digest of a text or blob.
--- - `digest(A, X)`: the digest of X under the algorithm A names (a
---   [`cosmic.hash`] `Algorithm`).
--- - `hmac(A, K, X)`: the HMAC of X under the key K over A.
--- - `deflate(X)`: the raw deflate of X, as `Compress.deflate("raw", X)`
---   writes it; `inflate(X)` decodes such a stream, to a blob.
---
--- `handle:limit(name, value)` sets one of the connection's limits,
--- `"attached"` among them, and answers the old one.
function Sqlite.open(path: string, opts?: Sqlite.OpenOptions): Sqlite.Handle?, string
  return sqlite.open(path, opts and opts.writable, opts and opts.immutable, opts and opts.create)
end

--- Opens with [`Sqlite.open`]'s options and captures SQLite's codes before
--- cleanup. A failed open has no `handle`; a successful one has code zero.
--- A path containing NUL raises, as do invalid options.
function Sqlite.open_result(path: string, opts?: Sqlite.OpenOptions): Sqlite.OpenResult
  return sqlite.open_result(path, opts and opts.writable, opts and opts.immutable, opts and opts.create)
end

--- A writable database held in memory: it is gone when the handle
--- closes.
function Sqlite.memory(): Sqlite.Handle?, string
  return sqlite.open(":memory:", true)
end

--- Raises, blaming as [`checked`] does, unless `list` holds elements 1 to
--- its length, each of the type `field` names: an integer for integers,
--- a number for numbers, a string for texts and blobs, and no NUL in a
--- text, which carray reads to its first NUL.
local function check_array<T>(key: integer, field: string, list: {T})
  for i = 1, rawlen(list) do
    local element = rawget(list, i)
    local fits: boolean
    if field == "integers" then
      fits = math.type(element) == "integer"
    elseif field == "numbers" then
      fits = type(element) == "number"
    else
      fits = type(element) == "string"
    end
    if not fits then
      error("sqlite: element " .. tostring(i) .. " of parameter " .. tostring(key) .. "'s " .. field .. " is not of its type", 5)
    end
    if field == "texts" and element is string and element:find("\0", 1, true) ~= nil then
      error("sqlite: element " .. tostring(i) .. " of parameter " .. tostring(key) .. "'s texts holds a NUL; bind it in blobs", 5)
    end
  end
end

--- Raises, blaming the caller of the public function that calls the
--- function that calls this, unless `values` is a list of Values: each a
--- table with at most one field, named integer, number, text, blob, or an
--- array's integers, numbers, texts or blobs ({} for NULL), under keys
--- that are positions from 1. It runs before a statement is prepared, so
--- a raise leaves none to finalize. Answers the highest key, 0 for none.
local function checked(values: {Sqlite.Value}): integer
  local highest = 0
  for key, value in pairs(values as {any: any}) do
    if not (key is integer) or key < 1 then
      error("sqlite: values holds the key " .. tostring(key) .. ", not a position from 1", 4)
    end
    if type(value) ~= "table" then
      error("sqlite: parameter " .. key .. " is no Value table (use {} for NULL)", 4)
    end
    local fields = 0
    for field in pairs(value as {any: any}) do
      if field ~= "integer" and field ~= "number" and field ~= "text" and field ~= "blob" and
          field ~= "integers" and field ~= "numbers" and field ~= "texts" and field ~= "blobs" then
        error("sqlite: parameter " .. key .. " has an unknown Value field: " .. tostring(field), 4)
      end
      fields = fields + 1
    end
    if key is integer then
      local held = values[key]
      local integers = held.integers
      if integers ~= nil then check_array(key, "integers", integers) end
      local numbers = held.numbers
      if numbers ~= nil then check_array(key, "numbers", numbers) end
      local texts = held.texts
      if texts ~= nil then check_array(key, "texts", texts) end
      local blobs = held.blobs
      if blobs ~= nil then check_array(key, "blobs", blobs) end
    end
    if fields > 1 then
      error("sqlite: parameter " .. key .. " has more than one Value field", 4)
    end
    if key > highest then highest = key end
  end
  return highest
end

--- Binds SQLite parameters positionally, which [`checked`] has found
--- well formed, `highest` the greatest position they hold: the positions
--- must be 1..N, matching the statement's own placeholders, or the
--- statement is refused with why.
local function bind(
    statement: Sqlite.Statement, values: {Sqlite.Value}, highest: integer
): boolean, string
  local count = statement:parameters()
  if highest > count then
    return false, "sqlite: values holds a parameter " .. tostring(highest) ..
      ", and the statement has " .. tostring(count)
  end
  for index = 1, count do
    local value = values[index]
    if value == nil then
      return false, "sqlite: parameter " .. tostring(index) .. " has no value (use {} for NULL)"
    end
    local ok: boolean
    local trouble: string
    local integer, number, text, blob = value.integer, value.number, value.text, value.blob
    local integers, numbers, texts, blobs = value.integers, value.numbers, value.texts, value.blobs
    if integer ~= nil then
      ok, trouble = statement:bind_integer(index, integer)
    elseif number ~= nil then
      ok, trouble = statement:bind_number(index, number)
    elseif text ~= nil then
      ok, trouble = statement:bind_text(index, text)
    elseif blob ~= nil then
      ok, trouble = statement:bind_blob(index, blob)
    elseif integers ~= nil then
      ok, trouble = statement:bind_integers(index, integers)
    elseif numbers ~= nil then
      ok, trouble = statement:bind_numbers(index, numbers)
    elseif texts ~= nil then
      ok, trouble = statement:bind_texts(index, texts)
    elseif blobs ~= nil then
      ok, trouble = statement:bind_blobs(index, blobs)
    else
      ok, trouble = statement:bind_null(index)
    end
    if not ok then
      return false, "sqlite: parameter " .. tostring(index) .. ": " .. trouble
    end
  end
  return true, ""
end

--- `sql` prepared on `handle` with `values` bound, or nil and why; a
--- statement that does not bind is finalized.
local function prepared(handle: Sqlite.Handle, sql: string,
                        given?: {Sqlite.Value}): Sqlite.Statement?, string
  local values = given or {}
  local highest = checked(values)
  local statement, trouble = handle:prepare(sql)
  if statement == nil then
    return nil, trouble
  end
  local bound, why = bind(statement, values, highest)
  if not bound then
    statement:finalize()
    return nil, why
  end
  return statement, ""
end

--- Runs a statement that yields no rows: it answers `true` and
--- "", or `false` and why.
---
--- `values` is a dense list indexed by SQLite's parameter index, through
--- its highest index. Repeated named parameters share an index, and a
--- gap in `?NNN` numbers still needs an entry (use `{}`). A missing entry
--- or an extra key answers `false` and why. A malformed [`Sqlite.Value`]
--- (no table, a field it has no name for, more than one field) raises, as
--- does a key that is no position from 1.
function Sqlite.run(handle: Sqlite.Handle, sql: string,
                    values?: {Sqlite.Value}): boolean, string
  local statement, trouble = prepared(handle, sql, values)
  if statement == nil then
    return false, trouble
  end
  local state, failure = statement:step()
  statement:finalize()
  if state == nil then
    return false, failure
  end
  return true, ""
end

-- A row is one table with a metatable, so reading a result allocates
-- the row and nothing per cell. It holds each cell as two slots, the
-- cell's kind then its value (`false` for NULL, which a table cannot
-- hold as nil). A text row, whose cells are all text, holds only each
-- value, one slot a column, and has accessors of its own. Only the
-- accessors below look inside. A stored row has the accessors of
-- [`Sqlite.Row`] but is not declared to implement it: a record that has an
-- array part takes no interface, so the rows are cast where they are made.
-- TODO: once the grammar lets a record carry an array part and an interface, or a stored row is a class, delete
-- the casts in [`cells_of`] and [`texts_of`] (and their entries in build/contract_rules.tl's casts) and list
-- [`Sqlite.Row`] on [`Stored`] and [`TextStored`].
local record Stored is {any}
  count: function(Stored): integer
  kind: function(Stored, integer): Sqlite.Kind
  is_null: function(Stored, integer): boolean
  integer: function(Stored, integer): integer
  number: function(Stored, integer): number
  text: function(Stored, integer): string
  blob: function(Stored, integer): string
  bytes: function(Stored, integer): string
  texts: function(Stored): {string}
  value: function(Stored, integer): Sqlite.Value
end

local stored_mt: metatable<Stored> = { __index = Stored }

--- What a cell of kind `kind` is called in a failure.
local function described(kind: Sqlite.Kind): string
  if kind == "null" then return "NULL" end
  if kind == "integer" then return "an integer" end
  if kind == "number" then return "a number" end
  if kind == "blob" then return "a blob" end
  return "text"
end

--- The kind a row stored for a cell.
local function kind_of(stored: any): Sqlite.Kind
  if stored == "integer" then return "integer" end
  if stored == "number" then return "number" end
  if stored == "text" then return "text" end
  if stored == "blob" then return "blob" end
  return "null"
end

--- The kind and value of column `index` of `row`, which `name` reads.
--- Raises, blaming the caller of the accessor that called this, unless
--- `index` is a position the row has a column at.
local function cell_at(row: Stored, index: integer, name: string): Sqlite.Kind, any
  local count = #row // 2
  if index < 1 or index > count then
    error("sqlite: row:" .. name .. "(" .. tostring(index) .. "): the row has " .. tostring(count) ..
        (if count == 1 then " column" else " columns" end), 3)
  end
  local at = 2 * index - 1
  return kind_of(row[at]), row[at + 1]
end

--- The failure of reading column `index` as `wants` when it holds a
--- cell of kind `kind`, blaming the caller of the accessor that raises
--- it.
local function mismatch(name: string, index: integer, kind: Sqlite.Kind, wants: string): string
  return "sqlite: row:" .. name .. "(" .. tostring(index) .. "): column " .. tostring(index) .. " is " ..
    described(kind) .. ", not " .. wants
end

function Stored.count(self: Stored): integer
  return #self // 2
end

function Stored.kind(self: Stored, index: integer): Sqlite.Kind
  local kind, _ = cell_at(self, index, "kind")
  return kind
end

function Stored.is_null(self: Stored, index: integer): boolean
  local kind, _ = cell_at(self, index, "is_null")
  return kind == "null"
end

function Stored.integer(self: Stored, index: integer): integer
  local kind, held = cell_at(self, index, "integer")
  if held is integer then return held end
  error(mismatch("integer", index, kind, "an integer"), 2)
end

function Stored.number(self: Stored, index: integer): number
  local kind, held = cell_at(self, index, "number")
  if held is integer then return held + 0.0 end
  if held is number then return held end
  error(mismatch("number", index, kind, "a number or an integer"), 2)
end

function Stored.text(self: Stored, index: integer): string
  local kind, held = cell_at(self, index, "text")
  if kind == "text" and held is string then return held end
  error(mismatch("text", index, kind, "text"), 2)
end

function Stored.blob(self: Stored, index: integer): string
  local kind, held = cell_at(self, index, "blob")
  if kind == "blob" and held is string then return held end
  error(mismatch("blob", index, kind, "a blob"), 2)
end

function Stored.bytes(self: Stored, index: integer): string
  local kind, held = cell_at(self, index, "bytes")
  if held is string then return held end
  error(mismatch("bytes", index, kind, "text or a blob"), 2)
end

function Stored.texts(self: Stored): {string}
  local out: mut {string} = {}
  for index = 1, #self // 2 do
    local kind, held = cell_at(self, index, "texts")
    if kind == "text" and held is string then
      out[index] = held
    else
      error(mismatch("texts", index, kind, "text"), 2)
    end
  end
  return out
end

function Stored.value(self: Stored, index: integer): Sqlite.Value
  local kind, held = cell_at(self, index, "value")
  if held is integer then return { integer = held } end
  if held is number then return { number = held } end
  if held is string then
    if kind == "blob" then return { blob = held } end
    return { text = held }
  end
  return {}
end

--- A row of [`text_rows`]: one slot a column, each its bytes.
local record TextStored is {any}
  count: function(TextStored): integer
  kind: function(TextStored, integer): Sqlite.Kind
  is_null: function(TextStored, integer): boolean
  integer: function(TextStored, integer): integer
  number: function(TextStored, integer): number
  text: function(TextStored, integer): string
  blob: function(TextStored, integer): string
  bytes: function(TextStored, integer): string
  texts: function(TextStored): {string}
  value: function(TextStored, integer): Sqlite.Value
end

local text_stored_mt: metatable<TextStored> = { __index = TextStored }

--- The bytes of column `index` of `row`, which `name` reads. Raises,
--- blaming the caller of the accessor that called this, unless `index`
--- is a position the row has a column at.
local function text_at(row: TextStored, index: integer, name: string): string
  local held = row[index]
  if held is string then return held end
  local count = #row
  error("sqlite: row:" .. name .. "(" .. tostring(index) .. "): the row has " .. tostring(count) ..
      (if count == 1 then " column" else " columns" end), 3)
end

function TextStored.count(self: TextStored): integer
  return #self
end

function TextStored.kind(self: TextStored, index: integer): Sqlite.Kind
  local _ = text_at(self, index, "kind")
  return "text"
end

function TextStored.is_null(self: TextStored, index: integer): boolean
  local _ = text_at(self, index, "is_null")
  return false
end

function TextStored.integer(self: TextStored, index: integer): integer
  local _ = text_at(self, index, "integer")
  error(mismatch("integer", index, "text", "an integer"), 2)
end

function TextStored.number(self: TextStored, index: integer): number
  local _ = text_at(self, index, "number")
  error(mismatch("number", index, "text", "a number or an integer"), 2)
end

function TextStored.text(self: TextStored, index: integer): string
  return text_at(self, index, "text")
end

function TextStored.blob(self: TextStored, index: integer): string
  local _ = text_at(self, index, "blob")
  error(mismatch("blob", index, "text", "a blob"), 2)
end

function TextStored.bytes(self: TextStored, index: integer): string
  return text_at(self, index, "bytes")
end

function TextStored.texts(self: TextStored): {string}
  local out: mut {string} = {}
  for index = 1, #self do
    local held = self[index]
    if held is string then out[index] = held end
  end
  return out
end

function TextStored.value(self: TextStored, index: integer): Sqlite.Value
  return { text = text_at(self, index, "value") }
end

--- The row `statement` was just stepped to, as typed cells in column
--- order. Its columns are asked after each step: a schema change
--- re-prepares the statement, and its columns with it.
local function cells_of(statement: Sqlite.Statement): Sqlite.Row
  local row: Stored = setmetatable({}, stored_mt)
  for index = 0, statement:columns() - 1 do
    local kind = statement:kind(index)
    local at = 2 * index + 1
    if kind == "integer" then
      row[at], row[at + 1] = "integer", statement:integer(index)
    elseif kind == "number" then
      row[at], row[at + 1] = "number", statement:number(index)
    elseif kind == "text" or kind == "blob" then
      row[at], row[at + 1] = kind, statement:bytes(index)
    else
      row[at], row[at + 1] = "null", false
    end
  end
  return row as Sqlite.Row
end

--- The row `statement` was just stepped to, as the bytes of each column
--- in order, each a "text" cell. Asked after each step, as [`cells_of`] is.
local function texts_of(statement: Sqlite.Statement): Sqlite.Row
  local row: TextStored = setmetatable({}, text_stored_mt)
  for index = 0, statement:columns() - 1 do
    row[index + 1] = statement:bytes(index)
  end
  return row as Sqlite.Row
end

--- Steps `statement` once and gives `project` the row it stands on: the
--- projection, or `nil` and "" when the statement is done, or `nil` and
--- why when the step failed. [`Sqlite.rows`], [`Sqlite.text_rows`] and
--- [`Sqlite.query`] all step through it, so they agree on what a failure
--- says.
local function step_row<T>(statement: Sqlite.Statement,
                           project: function(Sqlite.Statement): T): T?, string
  local state, failure = statement:step()
  if state == nil then
    return nil, failure ~= "" and failure or "sqlite: the step failed"
  end
  if state == "done" then
    return nil, ""
  end
  return project(statement), ""
end

--- Every row of `statement` as `project` gives it, and the statement
--- finalized: the rows, or `nil` and why a step failed.
local function each_row<T>(statement: Sqlite.Statement,
                           project: function(Sqlite.Statement): T): {T}?, string
  local out: mut {T} = {}
  while true do
    local row, failure = step_row(statement, project)
    if row == nil then
      statement:finalize()
      if failure ~= "" then
        return nil, failure
      end
      return out, ""
    end
    out[#out + 1] = row
  end
end

--- Every row a query yields, each a [`Sqlite.Row`] that keeps its
--- columns' SQLite types. Answers the rows, or `nil` and why. `values`
--- follows [`Sqlite.run`]'s contract.
function Sqlite.rows(handle: Sqlite.Handle, sql: string,
                     values?: {Sqlite.Value}): Sqlite.Rows?, string
  local statement, trouble = prepared(handle, sql, values)
  if statement == nil then
    return nil, trouble
  end
  return each_row(statement, cells_of)
end

--- Every row a query yields as `project` makes it: the list of what
--- `project` answered for each row in turn, or `nil` and why. `project`
--- reads the row's columns (`r:text(1)`) and answers one value, never
--- nil, which is how a caller builds a record per row. A raise inside
--- `project`, such as a column of another type than it read, leaves
--- nothing open and reaches the caller. `values` follows
--- [`Sqlite.run`]'s contract, and is nil where the query takes none.
---
---     local record Named
---       name: string
---       n: integer
---     end
---     local db = assert(Sqlite.memory())
---     assert(db:exec("CREATE TABLE t (name TEXT, n INTEGER); INSERT INTO t VALUES ('a', 1), ('b', 2)"))
---     local found = assert(Sqlite.map(db, "SELECT name, n FROM t WHERE n > ?1 ORDER BY n",
---       { { integer = 0 } }, function(r: Sqlite.Row): Named
---         return { name = r:text(1), n = r:integer(2) }
---       end))
---     print(#found, found[2].name) -- 2  b
function Sqlite.map<T>(handle: Sqlite.Handle, sql: string, values: {Sqlite.Value}?,
                       project: function(Sqlite.Row): T): {T}?, string
  local statement, trouble = prepared(handle, sql, values)
  if statement == nil then
    return nil, trouble
  end
  local out: mut {T} = {}
  while true do
    local state, failure = statement:step()
    if state == nil then
      statement:finalize()
      return nil, failure ~= "" and failure or "sqlite: the step failed"
    end
    if state == "done" then
      statement:finalize()
      return out, ""
    end
    local called, made = pcall(project, cells_of(statement))
    if not called then
      statement:finalize()
      error(made, 0)
    end
    if made == nil then
      statement:finalize()
      error("sqlite: map: project answered nil for a row; answer a value", 2)
    end
    out[#out + 1] = made
  end
end

-- How an object of this module is made: see the note on objects in
-- cosmic/stream.tl.

--- Finalizes `query`'s statement, once.
local function finish(query: StatementQuery)
  if query.open then
    query.open = false
    query.statement:finalize()
  end
end

--- The Query over one prepared statement, which it finalizes.
local class StatementQuery is Sqlite.Query
  statement: Sqlite.Statement
  mut open: boolean
  mut ended: boolean
  mut failed: string

  function read(self): Sqlite.Row?, string
    if self.failed ~= "" then return nil, self.failed end
    if self.ended then return nil, "" end
    if not self.open then return nil, "sqlite: the query is closed" end
    local row, failure = step_row(self.statement, cells_of)
    if row == nil then
      if failure == "" then
        self.ended = true
      else
        self.failed = failure
      end
      finish(self)
      return nil, failure
    end
    return row, ""
  end

  function each(self): function(): Sqlite.Row?
    return function(): Sqlite.Row?
      local row, _ = self:read()
      return row
    end
  end

  function failure(self): string
    return self.failed
  end

  function close(self)
    finish(self)
  end

  function __close(self)
    self:close()
  end
end

--- A query whose rows are read one at a time, as `rows` gives them but
--- never all held at once: nil and why when the statement does not
--- prepare or bind (`values` follows [`Sqlite.run`]'s contract). The
--- statement stays open, and the handle cannot close, until the last
--- row is read, a step fails, or the query is
--- closed; hold it in a `<close>` variable to close it on a `break` or
--- an error too.
---
--- An open query holds SQLite's read lock on a file database between
--- reads, so a writer on another connection waits for it (in rollback
--- mode, up to the busy timeout, then fails): read it out promptly. A
--- write on the same connection to a table the query reads may be
--- read back by it, without end for an insert into a table scanned
--- whole; collect what to write first. The statement runs at the first
--- read, not before: [`Sqlite.run`] is for one that yields no rows.
---
---     local q <close> = assert(Sqlite.query(db, "SELECT id, body FROM t"))
---     for row in q:each() do print(row:integer(1), row:text(2)) end
---     assert(q:failure() == "", q:failure())
function Sqlite.query(handle: Sqlite.Handle, sql: string,
                      values?: {Sqlite.Value}): Sqlite.Query?, string
  local opened, trouble = prepared(handle, sql, values)
  if opened == nil then
    return nil, trouble
  end
  local q: StatementQuery = {
    statement = opened, open = true, ended = false, failed = "",
  }
  return q, ""
end

--- A direct text projection for callers whose SQL already defines the
--- coercion they want. Every column of every row is text, read with
--- `row:text(i)`: SQLite's byte representation is returned for every
--- value: NULL, empty text and empty blob all become `""`; integers and
--- floats use SQLite's text formatting; text and blobs remain byte
--- strings, including NUL. Such a row answers `kind` as `"text"` for
--- every column and [`is_null`] as false, and raises from `integer`,
--- `number` and `blob`: read those from [`Sqlite.rows`].
function Sqlite.text_rows(handle: Sqlite.Handle, sql: string,
                          values?: {Sqlite.Value}): Sqlite.Rows?, string
  local statement, trouble = prepared(handle, sql, values)
  if statement == nil then
    return nil, trouble
  end
  return each_row(statement, texts_of)
end

local type Outcome = raw_sqlite.Outcome

local function copy_outcome(from: Outcome, to: Outcome)
  to.code, to.extended_code = from.code, from.extended_code
  to.reason, to.cancelled = from.reason, from.cancelled
end

--- A typed helper owns preparation and binding failures alike. A bad
--- parameter shape raises, but must not leave a statement holding its handle.
local function prepared_result(handle: Sqlite.Handle, sql: string,
                               values?: {Sqlite.Value}): Sqlite.PrepareResult
  local opened = handle:prepare_result(sql)
  if opened.statement == nil then return opened end
  local statement = opened.statement
  if values == nil and statement:parameters() == 0 then return opened end
  if values == nil then values = {} end
  local called, bound = pcall(statement.bind_values_result, statement, values)
  if not called then
    statement:finalize()
    error(bound, 0)
  end
  if bound.code ~= Sqlite.OK then
    statement:finalize()
    opened.statement = nil
    copy_outcome(bound, opened)
  end
  return opened
end

--- Runs once with a captured outcome, including preparation, binding and
--- stepping. Parameters have [`Sqlite.run`]'s shape; missing, extra or wrongly
--- typed parameters raise. No statement is retried or transaction rolled back.
function Sqlite.run_result(handle: Sqlite.Handle, sql: string,
                           values?: {Sqlite.Value}): Sqlite.ExecResult
  local opened = prepared_result(handle, sql, values)
  local result: Sqlite.ExecResult = { code = 0, extended_code = 0, reason = "", cancelled = false }
  copy_outcome(opened, result)
  if opened.statement == nil then return result end
  local state = opened.statement:step_result()
  opened.statement:finalize()
  if state is Sqlite.ExecResult then return state end
  return result
end

--- The typed step surface allocates a guard once per statement, reusing it
--- for successful rows. Only a failure makes a result record for a step.
local function collect_result<T>(statement: Sqlite.Statement,
                                 project: function(Sqlite.Statement): T, outcome: Outcome): {T}?
  local rows: mut {T} = {}
  while true do
    local state = statement:step_result()
    if state is Sqlite.ExecResult then
      statement:finalize()
      copy_outcome(state, outcome)
      return nil
    end
    if state == "done" then
      statement:finalize()
      return rows
    end
    rows[#rows + 1] = project(statement)
  end
end

--- [`Sqlite.rows`] with captured SQLite codes. Any failed step discards the
--- partial rows and finalizes the statement. Parameters follow [`run_result`].
function Sqlite.rows_result(handle: Sqlite.Handle, sql: string,
                            values?: {Sqlite.Value}): Sqlite.RowsResult
  local opened = prepared_result(handle, sql, values)
  local result: Sqlite.RowsResult = { code = 0, extended_code = 0, reason = "", cancelled = false }
  copy_outcome(opened, result)
  if opened.statement ~= nil then
    result.rows = collect_result(opened.statement, cells_of, result)
  end
  return result
end

--- [`Sqlite.text_rows`] with captured SQLite codes; otherwise follows
--- [`Sqlite.rows_result`], including discarding partial rows on failure.
function Sqlite.text_rows_result(handle: Sqlite.Handle, sql: string,
                                 values?: {Sqlite.Value}): Sqlite.TextRowsResult
  local opened = prepared_result(handle, sql, values)
  local result: Sqlite.TextRowsResult = { code = 0, extended_code = 0, reason = "", cancelled = false }
  copy_outcome(opened, result)
  if opened.statement ~= nil then
    result.rows = collect_result(opened.statement, texts_of, result)
  end
  return result
end

--- Runs `work` inside a transaction and commits when it answers `true`.
--- When `work` answers `false` and why, or the commit fails, the
--- transaction rolls back and this answers `false` and that reason. When
--- `work` raises, the transaction rolls back and the same error is
--- raised again. A transaction already open on `handle` makes `BEGIN`
--- fail, so calls do not nest.
---
--- The statements of one transaction are written through the same
--- handle:
---
---     local ok, why = Sqlite.transact(db, function(): boolean, string
---       local a, trouble = Sqlite.run(db, "INSERT INTO t (body) VALUES (?1)", { { text = "a" } })
---       if not a then return false, trouble end
---       return Sqlite.run(db, "INSERT INTO t (body) VALUES (?1)", { { text = "b" } })
---     end)
function Sqlite.transact(handle: Sqlite.Handle,
                         work: function(): boolean, string): boolean, string
  local started, trouble = handle:exec("BEGIN")
  if not started then
    return false, trouble
  end
  local called, ok, why = pcall(work)
  if not called then
    local _, _ = handle:exec("ROLLBACK")
    error(ok, 0)
  end
  if not ok then
    local _, _ = handle:exec("ROLLBACK")
    return false, why
  end
  local committed, failure = handle:exec("COMMIT")
  if not committed then
    local _, _ = handle:exec("ROLLBACK")
    return false, failure
  end
  return true, ""
end

Sqlite.OK = 0
Sqlite.BUSY = 5
Sqlite.LOCKED = 6
Sqlite.CORRUPT = 11
Sqlite.NOTADB = 26
Sqlite.version = sqlite.version

return Sqlite
