--- A memo of what a whole-tree check found in one file, so that a file that has
--- not changed costs nothing on the next run of `cosmic fix --check .`
--- ([`build.tree_checks`]'s `lexed` and `translated`).
---
--- A memo is one table of a database, [`check_memo`], in the build directory
--- ([`build.paths`]'s `translate_check`). A row is a `kind` of check, a key and
--- the text the check made of the file. The key is the SHA-256 of a salt, the
--- dialect and the SHA-256 of the file's bytes, so a changed file, a changed
--- check and another dialect each miss. The salt is the SHA-256 of the
--- sources of the code that made the answer ([`salt`]).
---
--- A memo is an optimization and never an answer: a read or write that fails
--- is a miss, and the check runs. A run is one transaction, from [`prepare`]
--- to [`finish`], which keeps the rows it used and drops the rest of its kind,
--- so the table does not grow with each edit.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")

local record check_memo
  --- Creates the table in `db` if it is not there, marks the rows of `kind`
  --- unused and begins the run's transaction. Answers whether it could.
  prepare: function(db: Sqlite.Handle, kind: string): boolean, string
  --- The text kept under `key` for `kind`, marked used; nil on a miss.
  get: function(db: Sqlite.Handle, kind: string, key: string): string | nil
  --- Keeps `value` under `key` for `kind`, marked used.
  put: function(db: Sqlite.Handle, kind: string, key: string, value: string)
  --- Drops the rows of `kind` that this run did not use and commits.
  finish: function(db: Sqlite.Handle, kind: string)
  --- The key for a file of the given `dialect` and `bytes` under `salt`.
  key: function(salt: string, dialect: string, bytes: string): string
  --- The SHA-256 of the bytes of `files` (paths under `root`) in order and of
  --- `version`, the format of what a check keeps; a file that cannot be read
  --- counts as empty, so a tree without them still has a salt.
  salt: function(root: string, files: {string}, version: string): string
  --- `rows` (lists of fields) as one text, and the rows back.
  encode: function(rows: {{string}}): string
  decode: function(text: string): {{string}}
end

function check_memo.prepare(db: Sqlite.Handle, kind: string): boolean, string
  local made, made_trouble = Sqlite.run(db,
    "CREATE TABLE IF NOT EXISTS check_memo (kind TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, " ..
      "used INTEGER NOT NULL, PRIMARY KEY (kind, key)) WITHOUT ROWID")
  if not made then
    return false, made_trouble
  end
  local reset, reset_trouble = Sqlite.run(db, "UPDATE check_memo SET used = 0 WHERE kind = ?1", { { text = kind } })
  if not reset then
    return false, reset_trouble
  end
  -- One transaction for a run's lookups and writes: a commit for each of a
  -- thousand files is most of the cost of a memo.
  return Sqlite.run(db, "BEGIN")
end

function check_memo.get(db: Sqlite.Handle, kind: string, key: string): string | nil
  local rows, _ = Sqlite.rows(db, "SELECT value FROM check_memo WHERE kind = ?1 AND key = ?2",
    { { text = kind }, { text = key } })
  local row = rows ~= nil and rows[1] or nil
  if row == nil then
    return nil
  end
  local value = row:text(1)
  local _, _ = Sqlite.run(db, "UPDATE check_memo SET used = 1 WHERE kind = ?1 AND key = ?2",
    { { text = kind }, { text = key } })
  return value
end

function check_memo.put(db: Sqlite.Handle, kind: string, key: string, value: string)
  local _, _ = Sqlite.run(db, "INSERT OR REPLACE INTO check_memo (kind, key, value, used) VALUES (?1, ?2, ?3, 1)",
    { { text = kind }, { text = key }, { text = value } })
end

function check_memo.finish(db: Sqlite.Handle, kind: string)
  local _, _ = Sqlite.run(db, "DELETE FROM check_memo WHERE kind = ?1 AND used = 0", { { text = kind } })
  local _, _ = Sqlite.run(db, "COMMIT")
end

function check_memo.key(salt: string, dialect: string, bytes: string): string
  return Hash.hex_sha256(salt .. "\0" .. dialect .. "\0" .. Hash.hex_sha256(bytes))
end

function check_memo.salt(root: string, files: {string}, version: string): string
  local parts: {string} = {}
  for _, file in ipairs(files) do
    local text, _ = Fs.read(root .. "/" .. file)
    parts[#parts + 1] = Hash.hex_sha256(text or "")
  end
  parts[#parts + 1] = version
  return Hash.hex_sha256(table.concat(parts, "\0"))
end

local ESCAPES <const>: {string: string} = { ["\\"] = "\\\\", ["\t"] = "\\t", ["\n"] = "\\n", ["\r"] = "\\r" }
local UNESCAPES <const>: {string: string} = { ["\\"] = "\\", t = "\t", n = "\n", r = "\r" }

function check_memo.encode(rows: {{string}}): string
  local lines: {string} = {}
  for _, row in ipairs(rows) do
    local fields: {string} = {}
    for i, field in ipairs(row) do
      fields[i] = (field:gsub("[\\\t\n\r]", ESCAPES))
    end
    lines[#lines + 1] = table.concat(fields, "\t")
  end
  return table.concat(lines, "\n")
end

function check_memo.decode(text: string): {{string}}
  local rows: {{string}} = {}
  if text == "" then
    return rows
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local fields: {string} = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do
      fields[#fields + 1] = (field:gsub("\\(.)", UNESCAPES))
    end
    rows[#rows + 1] = fields
  end
  return rows
end

return check_memo
