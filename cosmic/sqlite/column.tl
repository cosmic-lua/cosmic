--- Internal helper for cosmic.sqlite: typed column readers over a row.
--- A row is `{string: any}` — a query's columns are known only at
--- runtime, so the table cannot be a record — and reading a column whose
--- type the caller already knows would otherwise cost an `as` cast at
--- every read. These readers move that check into one place that reports
--- a mismatch instead of asserting one, and they narrow with `is`, so no
--- cast is spent here either.
--- Lives in its own file so cosmic/sqlite/init.tl stays under the
--- 500-line cap.

--- One row from a query: column name to value, with SQL NULL absent.
local type Row = {string: any}

--- Message for a column that carries no value at all. A missing column
--- and a SQL NULL both read as nil off a row, so one message covers
--- both rather than claiming a distinction the row cannot make.
--- @param column string The column name that was read
--- @return string The formatted message
local function absent(column: string): string
  return 'column "' .. column .. '" is absent or NULL'
end

--- Message for a column holding the wrong type.
--- @param column string The column name that was read
--- @param got string What the value actually is
--- @param want string The type the reader was asked for
--- @return string The formatted message
local function mismatch(column: string, got: string, want: string): string
  return 'column "' .. column .. '" is ' .. got .. ', want ' .. want
end

--- Read a TEXT column as a string.
---
--- BLOB columns also arrive as Lua strings, so this reader accepts them
--- too; the row carries no column affinity to tell the two apart.
--- @param row Row The row to read from
--- @param column string The column name
--- @return string | nil The column value, or nil when it is missing or not a string
--- @return string Error message on failure
local function column_text(row: Row, column: string): string | nil, string
  local v = row[column]
  if v is string then
    return v
  end
  if v == nil then
    return nil, absent(column)
  end
  return nil, mismatch(column, type(v), "string")
end

--- Read a numeric column as a number, integer or float alike.
--- @param row Row The row to read from
--- @param column string The column name
--- @return number | nil The column value, or nil when it is missing or not a number
--- @return string Error message on failure
local function column_number(row: Row, column: string): number | nil, string
  local v = row[column]
  if v is number then
    return v
  end
  if v == nil then
    return nil, absent(column)
  end
  return nil, mismatch(column, type(v), "number")
end

--- Read an INTEGER column as an integer, rejecting a float.
---
--- SQLite stores an INTEGER column as an integer subtype, so a float
--- here means the column was REAL (or an expression produced one) and
--- the caller's assumption about the schema is wrong.
--- @param row Row The row to read from
--- @param column string The column name
--- @return integer | nil The column value, or nil when it is missing or not an integer
--- @return string Error message on failure
local function column_integer(row: Row, column: string): integer | nil, string
  local v = row[column]
  if v is integer then
    return v
  end
  if v == nil then
    return nil, absent(column)
  end
  local got = type(v)
  if got == "number" then
    got = "a float"
  end
  return nil, mismatch(column, got, "integer")
end

local record ColumnModule
  type Row = Row

  column_text: function(row: Row, column: string): string | nil, string
  column_number: function(row: Row, column: string): number | nil, string
  column_integer: function(row: Row, column: string): integer | nil, string
end

local M: ColumnModule = {
  column_text = column_text,
  column_number = column_number,
  column_integer = column_integer,
}

return M
