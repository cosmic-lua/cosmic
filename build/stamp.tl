--- The stamps the running binary's database carries: identities a start
--- would otherwise work out again from the same rows every time, which
--- the build that wrote the database worked out once and kept as `meta`
--- rows ([`build.stamps`] names them and fills them).
---
--- The invariant: a stamp `read` answers is the value this binary would
--- work out from its own database. Two things hold it:
---
--- - [`build.stamps`] writes stamps only where the code that works them
---   out is the code the database carries, so this binary's code would
---   work out the same from the same rows.
--- - `read` answers a stamp only where the database's `stamp_of` row is
---   the digest of the rows the stamps were worked out from
---   (`content`), taken again here. A database that came to hold stamps
---   made for other rows answers none, and the caller works the value
---   out as it would with no stamp.
---
--- `read` asks the binary's own database and no other, whatever is
--- attached ahead of it: a project's projection names another binary.
---
--- COSMIC_STAMPS=0 has `read` answer none of the binary's own, so each
--- caller works its value out: for the test that holds a run to reaching
--- the same keys either way (build/sandboxed_verdicts_test.tl), and for
--- telling whether a stamp is at fault.

local Env = require("cosmic.env")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")

local record stamp
  --- The row that binds a database's stamps to its rows (`content`).
  of: string

  --- The digest of the rows of `db` its stamps are functions of: which
  --- compiler compiled it and the runtime basis (`meta`), each module by
  --- its kind and the hash of its source, each declaration by its source,
  --- and what each module and declaration requires. A module's bytecode
  --- and stub follow from its source and that compiler. Nil and why where
  --- `db` cannot be read.
  content: function(db: Sqlite.Handle): string?, string

  --- The stamp `key` of `db`, by default the running binary's own
  --- database: nil where it holds none, or where its stamps are not of
  --- its rows. The binary's own are read once a process, and none of them
  --- is answered under COSMIC_STAMPS=0.
  read: function(key: string, db?: Sqlite.Handle): string?

  --- Whether the running binary's database carries stamps of its own
  --- rows, whatever COSMIC_STAMPS says: what tells a tool the code it
  --- carries stamped from one a stale tool wrote without
  --- ([`build.reboot`]).
  carried: function(): boolean
end

stamp.of = "stamp_of"

local content_sql <const> = "SELECT lower(hex(sha256(" ..
  "coalesce((SELECT group_concat(key || '=' || value, char(10) ORDER BY key) FROM meta " ..
  "WHERE key IN ('compiled_by', 'runtime_basis')), '') || char(10, 10) || " ..
  "coalesce((SELECT group_concat(path || ' ' || kind || ' ' || hex(source_hash), char(10) ORDER BY path) " ..
  "FROM modules), '') || char(10, 10) || " ..
  "coalesce((SELECT group_concat(path || ' ' || requires, char(10) ORDER BY path, requires) " ..
  "FROM imports), '') || char(10, 10) || " ..
  "coalesce((SELECT group_concat(path || ' ' || requires, char(10) ORDER BY path, requires) " ..
  "FROM decl_imports), '') || char(10, 10) || " ..
  "coalesce((SELECT group_concat(path || ' ' || hex(sha256(inflate(source))), char(10) ORDER BY path) " ..
  "FROM decls), ''))))"

function stamp.content(db: Sqlite.Handle): string?, string
  local rows, trouble = Sqlite.text_rows(db, content_sql)
  if rows == nil then return nil, trouble end
  local row = rows[1]
  if row == nil then return nil, "the digest of a database's rows answered no row" end
  return row:text(1), ""
end

--- The value of `db`'s `meta` row `key`, or nil for none.
local function meta_of(db: Sqlite.Handle, key: string): string?
  local rows, _ = Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = ?1", { { text = key } })
  if rows == nil then return nil end
  local row = rows[1]
  if row == nil then return nil end
  return row:text(1)
end

--- Whether `db`'s stamps are of its rows.
local function bound(db: Sqlite.Handle): boolean
  local of = meta_of(db, stamp.of)
  if of == nil or of == "" then return false end
  local content, _ = stamp.content(db)
  return content ~= nil and content == of
end

--- What this process has read of the binary's own stamps: whether they
--- are of its rows (nil until asked), and each one read, "" for none.
local record Own
  mut bound: boolean?
  read: mut {string:string}
end

local own: Own = { bound = nil, read = {} }

function stamp.carried(): boolean
  local is_bound = own.bound
  if is_bound == nil then
    local databases = Store.databases()
    local binary = databases[#databases]
    is_bound = binary ~= nil and bound(binary)
    own.bound = is_bound
  end
  return is_bound
end

function stamp.read(key: string, db?: Sqlite.Handle): string?
  if db ~= nil then
    if not bound(db) then return nil end
    local held = meta_of(db, key)
    return if held ~= "" then held else nil end
  end
  if Env.read("COSMIC_STAMPS") == "0" then return nil end
  local read = own.read[key]
  if read ~= nil then return if read ~= "" then read else nil end end
  local value: string? = nil
  if stamp.carried() then
    local databases = Store.databases()
    local binary = databases[#databases]
    if binary ~= nil then value = meta_of(binary, key) end
  end
  if value == "" then value = nil end
  own.read[key] = value or ""
  return value
end

return stamp
