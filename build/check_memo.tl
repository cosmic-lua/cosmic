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
---
--- The checkouts of a host share their rows through `checks.db` in
--- [`Fs.cache_dir`]'s `build` directory, beside the compiles they share
--- ([`build.shared_compiles`]), so a fresh worktree checks only what no
--- sibling has. A shared row is held under more than its key: also under the
--- code that checks ([`check_memo.code_of`]), the bytecode of every module in
--- the import closure of [`build.fix`] and the core, taken from the running
--- tool and not from the lists the salts are written from. So a row stands
--- only in a checkout whose checking code is the same, whatever a salt leaves
--- out. A kind whose key names the checkout (`unshared`) is not shared. A run
--- shares once it is told the code ([`check_memo.share`], which
--- [`build.tree_checks`]'s `share_checks` calls for a run of `cosmic fix` over
--- the whole of cosmic's tree); until then it shares nothing.
---
--- A key the checkout's own memo lacks is looked up in the shared file and
--- kept here. What a run writes to the shared file, as its kind finishes and
--- in one short transaction, is the rows it made itself and the rows it took
--- from there: never a row its own memo answered, which an earlier tool of
--- other code may have made. The file is in write-ahead mode and a run reads
--- it a row at a time, so runs of several checkouts never wait on each
--- other's checks. A row no run has made or taken for `kept_ns` goes, and
--- past `kept_bytes` the least lately used go first. The default place
--- ([`check_memo.shared_path`]) is none with `COSMIC_BUILD_CACHE` set, to `0`
--- or to a file: such a run shares no rows, as a test's worker does not.
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local shared_sqlite = require("build.shared_sqlite")
local sys = require("cosmic.sys")

local record check_memo
  --- Creates the table in `db` if it is not there, marks the rows of `kind`
  --- unused and begins the run's transaction. Answers whether it could.
  prepare: function(db: Sqlite.Handle, kind: string): boolean, string
  --- The text kept under `key` for `kind`, marked used; nil on a miss.
  get: function(db: Sqlite.Handle, kind: string, key: string): string?
  --- Keeps `value` under `key` for `kind`, marked used.
  put: function(db: Sqlite.Handle, kind: string, key: string, value: string)
  --- Drops the rows of `kind` that this run did not use and commits.
  --- `now_ns` is the time the shared rows are stamped with and aged by, the clock's by default.
  finish: function(db: Sqlite.Handle, kind: string, now_ns?: integer)
  --- Where the rows every checkout shares are kept, read from `environment` (the process's by default): nil where
  --- the run shares none (`COSMIC_BUILD_CACHE` is set) or has no cache directory.
  shared_path: function(environment?: {string:string}): string?
  --- The code that checks, as a shared row is held under it: a digest of the bytecode of every module in the import
  --- closure of [`build.fix`], by the `imports` rows of the tool `reads` answers for, and of its core. The bytecode
  --- and not the source: a tool another compiler wrote from the same source is other code. Nil and why where the tool
  --- cannot say: a module it holds with no bytecode to read, or a query that failed.
  code_of: function(reads: Reads): string?, string

  --- How [`check_memo.code_of`] reads a tool: `requires`, `bytecode` and `holds` as [`cosmic.store`]'s functions of
  --- those names answer, and `core`, what names every byte of the tool that is no module.
  record Reads
    requires: function(name: string): {string}?, string
    bytecode: function(name: string): string?, string
    holds: function(name: string): boolean?, string
    core: string
  end
  --- Shares rows through the file at `path` from here on, made when missing, in place of the default; with nil, shares
  --- none. `sharing` names the code the rows are held under ([`check_memo.code_of`]) and the bytes kept,
  --- `kept_bytes` by default. Answers whether the file is open, and why not: a file that is a link, another user's
  --- or writable by others is refused, as a shared compile's is.
  share: function(path: string?, sharing?: Sharing): boolean, string

  --- What [`check_memo.share`] is told of the rows.
  record Sharing
    code: string
    kept_bytes?: integer
  end
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

--- The shared file, open: the code its rows are taken and written under, the bytes it keeps, and the rows this
--- process used or wrote and has yet to write there, by kind then key.
local record Shared
  db: Sqlite.Handle
  code: string
  kept_bytes: integer
  owed: mut {string: mut {string: string}}
  mut bounded: boolean
end

--- The shared rows' table, named by its format's version.
local shared_table <const> = "check_memo_v1"

--- How long a shared row no run uses is kept: thirty days, as a shared compile is.
local kept_ns <const> = Clock.hours(30 * 24)

--- How many bytes of shared rows are kept: some forty whole states of cosmic's own tree.
local kept_bytes <const> = 64 * 1024 * 1024

--- How long a statement waits on another run's write of the shared file: each is one short transaction.
local shared_wait_ns <const> = Clock.seconds(2)

--- The kinds no checkout shares, each with why.
local unshared: {string: string} = {
  c = "its key holds the checkout's root and the directory the compiler runs in (build.c)",
}

local shared: Shared? = nil

function check_memo.shared_path(environment?: {string:string}): string?
  local value: string?
  if environment ~= nil then
    value = environment["COSMIC_BUILD_CACHE"]
  else
    value = Env.read("COSMIC_BUILD_CACHE")
  end
  if value ~= nil and value ~= "" then return nil end
  local dir, _ = Fs.cache_dir("build", { environment = environment })
  if dir == nil then return nil end
  return dir .. "/checks.db"
end

function check_memo.code_of(reads: check_memo.Reads): string?, string
  local seen: mut {string: boolean} = {}
  local names: mut {string} = {}
  local stack: mut {string} = { "build.fix" }
  while #stack > 0 do
    local name = assert(table.remove(stack))
    if seen[name] ~= true then
      seen[name] = true
      names[#names + 1] = name
      local needs, trouble = reads.requires(name)
      if needs == nil then return nil, name .. ": " .. trouble end
      for _, need in ipairs(needs) do stack[#stack + 1] = need end
    end
  end
  table.sort(names)
  local parts: mut {string} = {}
  for _, name in ipairs(names) do
    local code, code_trouble = reads.bytecode(name)
    if code == nil then
      -- A name the tool has no row of is a binding of the core, which `core` holds; a row it cannot read names nothing.
      local held, held_trouble = reads.holds(name)
      if held == nil then return nil, name .. ": " .. held_trouble end
      if held then return nil, name .. ": " .. code_trouble end
    end
    parts[#parts + 1] = name .. " " .. (if code ~= nil then Hash.hex_sha256(code) else "-" end)
  end
  parts[#parts + 1] = "core " .. reads.core
  return Hash.hex_sha256(table.concat(parts, "\n")), ""
end

--- Whether the file at `path` is a file of this user's that no one else may write, taken as it is and never through
--- a link, as [`build.shared_compiles`] holds its own: a row is believed as written.
local function private(path: string): boolean, string
  local st, trouble = sys.lstat(path)
  if st == nil then return false, path .. ": " .. trouble end
  if st.kind == "link" then return false, path .. ": a symbolic link" end
  if st.kind ~= "file" then return false, path .. ": not a file" end
  if st.uid ~= sys.getuid() then return false, path .. ": owned by another user" end
  if st.mode & 0x12 ~= 0 then return false, path .. ": writable by its group or others" end
  return true, ""
end

function check_memo.share(path: string?, sharing?: check_memo.Sharing): boolean, string
  local open = shared
  if open ~= nil then
    local _, _ = open.db:close()
    shared = nil
  end
  if path == nil or sharing == nil then return false, "" end
  -- Made 0600 before SQLite opens it; one already there is held to `private`.
  local fd, create_trouble, number = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, 0x180)
  if fd ~= nil then
    local _, _ = sys.close(fd)
  elseif number ~= sys.EEXIST then
    return false, path .. ": " .. create_trouble
  end
  local held, held_trouble = private(path)
  if not held then return false, held_trouble end
  local db, trouble = shared_sqlite.open(path, function(handle: Sqlite.Handle): boolean, string
    return handle:exec("CREATE TABLE IF NOT EXISTS " .. shared_table .. " (code TEXT NOT NULL, kind TEXT NOT NULL, " ..
        "key TEXT NOT NULL, value TEXT NOT NULL, used_ns INTEGER NOT NULL, PRIMARY KEY (code, kind, key)) WITHOUT ROWID")
  end, shared_wait_ns)
  if db == nil then return false, trouble end
  shared = { db = db, code = sharing.code, kept_bytes = sharing.kept_bytes or kept_bytes, owed = {}, bounded = false }
  return true, ""
end

--- Notes that this run made the row of `kind` under `key`, or took it from the shared file, for [`settle`] to write
--- there.
local function owe(kind: string, key: string, value: string)
  local open = shared
  if open == nil or unshared[kind] ~= nil then return end
  local rows: mut {string: string} = open.owed[kind] or {}
  open.owed[kind] = rows
  rows[key] = value
end

--- Writes to the shared file the rows this process owes it of `kind`, stamped `now_ns`, and, once a process, drops
--- the rows past their age and past the bytes kept. True where every statement ran.
local function settle(open: Shared, kind: string, now_ns: integer): boolean
  local db = open.db
  local keys: mut {string} = {}
  local rows = open.owed[kind] or {}
  for key in pairs(rows) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local ok, _ = Sqlite.run(db, "INSERT OR REPLACE INTO " .. shared_table .. " (code, kind, key, value, used_ns) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5)",
      { { text = open.code }, { text = kind }, { text = key }, { text = rows[key] or "" }, { integer = now_ns } })
    if not ok then return false end
  end
  if open.bounded then return true end
  open.bounded = true
  local aged, _ = Sqlite.run(db, "DELETE FROM " .. shared_table .. " WHERE used_ns < ?1",
    { { integer = now_ns - kept_ns } })
  if not aged then return false end
  local bounded, _ = Sqlite.run(db, "DELETE FROM " .. shared_table .. " WHERE (code, kind, key) IN (SELECT code, kind, " ..
      "key FROM (SELECT code, kind, key, sum(length(CAST(code AS BLOB)) + length(CAST(kind AS BLOB)) + " ..
      "length(CAST(key AS BLOB)) + length(CAST(value AS BLOB))) OVER (ORDER BY used_ns DESC, code, kind, key) " ..
      "AS held FROM " .. shared_table .. ") WHERE held > ?1)", { { integer = open.kept_bytes } })
  return bounded
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

function check_memo.get(db: Sqlite.Handle, kind: string, key: string): string?
  local rows, _ = Sqlite.rows(db, "SELECT value FROM check_memo WHERE kind = ?1 AND key = ?2",
    { { text = kind }, { text = key } })
  local row = if rows ~= nil then rows[1] else nil end
  if row == nil then
    local open = shared
    if open == nil or unshared[kind] ~= nil then return nil end
    local found, _ = Sqlite.rows(open.db, "SELECT value FROM " .. shared_table ..
        " WHERE code = ?1 AND kind = ?2 AND key = ?3", { { text = open.code }, { text = kind }, { text = key } })
    local sibling = if found ~= nil then found[1] else nil end
    if sibling == nil then return nil end
    local taken = sibling:text(1)
    local _, _ = Sqlite.run(db, "INSERT OR REPLACE INTO check_memo (kind, key, value, used) VALUES (?1, ?2, ?3, 1)",
      { { text = kind }, { text = key }, { text = taken } })
    owe(kind, key, taken)
    return taken
  end
  local value = row:text(1)
  local _, _ = Sqlite.run(db, "UPDATE check_memo SET used = 1 WHERE kind = ?1 AND key = ?2",
    { { text = kind }, { text = key } })
  -- Not owed to the shared file: the tool that made the row may have been of other code than this one.
  return value
end

function check_memo.put(db: Sqlite.Handle, kind: string, key: string, value: string)
  local _, _ = Sqlite.run(db, "INSERT OR REPLACE INTO check_memo (kind, key, value, used) VALUES (?1, ?2, ?3, 1)",
    { { text = kind }, { text = key }, { text = value } })
  owe(kind, key, value)
end

function check_memo.finish(db: Sqlite.Handle, kind: string, now_ns?: integer)
  local _, _ = Sqlite.run(db, "DELETE FROM check_memo WHERE kind = ?1 AND used = 0", { { text = kind } })
  local _, _ = Sqlite.run(db, "COMMIT")
  local open = shared
  if open == nil then return end
  -- One short transaction of the shared file, which another checkout's run may be reading: what does not go in is
  -- a miss for the next run, never a failure of this one.
  local begun, _ = open.db:exec("BEGIN IMMEDIATE")
  if begun then
    local settled = settle(open, kind, now_ns or Clock.now_ns())
    local _, _ = open.db:exec(if settled then "COMMIT" else "ROLLBACK" end)
  end
  open.owed[kind] = nil
end

function check_memo.key(salt: string, dialect: string, bytes: string): string
  return Hash.hex_sha256(salt .. "\0" .. dialect .. "\0" .. Hash.hex_sha256(bytes))
end

-- TODO: hold a checkout's own rows under [`check_memo.code_of`] too, in place of the lists of files its callers
-- write here, which the import closures show short of what the checks load (lang/generics.tl, lang/literals.tl and
-- lang/load_order.tl in none of them; build/ceilings.tl, build/markers.tl and build/checker_declarations.tl in none
-- of the checker's): an edit to one of those leaves the checkout's own stale rows standing, though never a sibling's,
-- which takes only rows made under its own code. Once an edit to any module `cosmic fix` loads may check the whole
-- tree again (5 to 8 minutes, where a listed salt checks again only for the files it names).
function check_memo.salt(root: string, files: {string}, version: string): string
  local parts: mut {string} = {}
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
  local lines: mut {string} = {}
  for _, row in ipairs(rows) do
    local fields: mut {string} = {}
    for i, field in ipairs(row) do
      fields[i] = (field:gsub("[\\\t\n\r]", ESCAPES))
    end
    lines[#lines + 1] = table.concat(fields, "\t")
  end
  return table.concat(lines, "\n")
end

function check_memo.decode(text: string): {{string}}
  local rows: mut {{string}} = {}
  if text == "" then
    return rows
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local fields: mut {string} = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do
      fields[#fields + 1] = (field:gsub("\\(.)", UNESCAPES))
    end
    rows[#rows + 1] = fields
  end
  return rows
end

return check_memo
