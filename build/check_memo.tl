--- A memo of what a whole-tree check found in one file, so that a file that has
--- not changed costs nothing on the next run of `cosmic fix --check .`
--- ([`build.tree_checks`]'s `lexed` and `translated`).
---
--- A memo is one table of a database, [`check_memo`], in the build directory
--- ([`build.paths`]'s `translate_check`). A row is a `kind` of check, a key and
--- the text the check made of the file. The key is the SHA-256 of a salt, the
--- dialect and the SHA-256 of the file's bytes, so a changed file, a changed
--- check and another dialect each miss. The salt is the SHA-256 of the
--- code that made the result ([`salt`]): the bytecode of the modules it names
--- and of every module they load, so no edit to that code leaves a row.
---
--- A memo is an optimization and never required: a read or write that fails
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
--- from there: never a row its own memo supplied, which an earlier tool of
--- other code may have made. The file is in write-ahead mode and a run reads
--- it a row at a time, so runs of several checkouts never wait on each
--- other's checks. A row no run has made or taken for `kept_ns` goes, and
--- past `kept_bytes` the least lately used go first. The place
--- ([`check_memo.shared_path`]) is the cache directory's whether or not
--- `COSMIC_BUILD_CACHE` moves the compiles, so CI, which moves them, keeps
--- these apart (ci/cosmic_ci/checks_seal.tl); with it `0`, a run shares no
--- rows, as a test's worker does not.
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local shared_sqlite = require("build.shared_sqlite")
local store_lookups = require("build.store_lookups")
local sys = require("cosmic.sys")

local record check_memo
  --- Creates the table in `db` if it is not there, marks the rows of `kind`
  --- unused and begins the run's transaction, unless it runs `within` one another kind of the run began. Returns
  --- whether it could.
  prepare: function(db: Sqlite.Handle, kind: string, within?: boolean): boolean, string
  --- The text kept under `key` for `kind`, marked used; nil on a miss.
  get: function(db: Sqlite.Handle, kind: string, key: string): string?
  --- Keeps `value` under `key` for `kind`, marked used.
  put: function(db: Sqlite.Handle, kind: string, key: string, value: string)
  --- Drops the rows of `kind` that this run did not use and commits, unless it runs `within` a transaction another
  --- kind commits. A run that judged only some files (`partial`) drops none: the rows of the rest are the next whole run's.
  --- `now_ns` is the time the shared rows are stamped with and aged by, the clock's by default.
  finish: function(db: Sqlite.Handle, kind: string, now_ns?: integer, partial?: boolean, within?: boolean)
  --- Where the rows every checkout shares are kept, read from `environment` (the process's by default): `checks.db` in
  --- the cache directory's `build`; nil where `COSMIC_BUILD_CACHE` is `0` or there is no cache directory.
  shared_path: function(environment?: {string:string}): string?
  --- The code that checks, as a shared row is held under it: a digest of the bytecode of every module in the import
  --- closure of [`build.fix`], by the `imports` rows of the tool read through `reads`, and of its core. The bytecode
  --- and not the source: a tool another compiler wrote from the same source is other code. Nil and why where the tool
  --- cannot say: a module it holds with no bytecode to read, or a query that failed.
  code_of: function(reads: Reads): string?, string

  --- How [`check_memo.code_of`] and [`check_memo.salt`] read a tool: `requires`, `bytecode` and `holds` as [`cosmic.store`]'s functions of
  --- those names return, and `core`, what names every byte of the tool that is no module.
  record Reads
    requires: function(name: string): {string}?, string
    bytecode: function(name: string): string?, string
    holds: function(name: string): boolean?, string
    core: string
  end
  --- Shares rows through the file at `path` from here on, made when missing, in place of the default; with nil, shares
  --- none. `sharing` names the code the rows are held under ([`check_memo.code_of`]) and the bytes kept,
  --- `kept_bytes` by default. Returns whether the file is open, and why not: a file that is a link, another user's
  --- or writable by others is refused, as a shared compile's is.
  share: function(path: string?, sharing?: Sharing): boolean, string

  --- What [`check_memo.share`] is told of the rows.
  record Sharing
    code: string
    kept_bytes?: integer
  end
  --- The key for a file of the given `dialect` and `bytes` under `salt`.
  key: function(salt: string, dialect: string, bytes: string): string
  --- The SHA-256 of the code that makes a result and of `version`, the format of what a check keeps. A module of
  --- `files` (a `.tl` file that is no declaration, or a directory ending in `/` whose files are one module, as
  --- lang/check/ is) goes in by the bytecode of it and of every module it loads, however far, as the running tool
  --- holds them; any other file (a declaration, a C header, a module the tool does not hold) by its bytes under
  --- `root`, where one that cannot be read counts as empty. Where the tool cannot name the code, the salt is one no
  --- other is, so no row is taken. `reads` reads another tool, for a test ([`check_memo.Reads`]; its `core` is not read).
  salt: function(root: string, files: {string}, version: string, reads?: Reads): string
  --- The SHA-256 of the sources of `modules` and of every module they require, however far, as the projection `db`
  --- holds them (its `imports` and each module's `source_hash`), and of `version`: the code that makes a result, by
  --- its import closure rather than by a list of files, which falls short of what the code loads. A module the
  --- projection does not hold counts by its name alone. Nil and why where the projection cannot be read.
  closure_salt: function(db: Sqlite.Handle, modules: {string}, version: string): string?, string
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
  read = "its rows hold all of a file's comment text, too much to share (build.fix.read_memo)",
}

local shared: Shared? = nil

--- The keys of each kind this run's [`check_memo.get`] found in a checkout's memo, which [`check_memo.finish`] keeps:
--- marked used there at once, in one statement, and not by a write of each row as it is read, which was most of what a
--- run of hits cost.
local found_keys: mut {string: mut {string}} = {}

function check_memo.shared_path(environment?: {string:string}): string?
  local value: string?
  if environment ~= nil then
    value = environment["COSMIC_BUILD_CACHE"]
  else
    value = Env.read("COSMIC_BUILD_CACHE")
  end
  if value == "0" then return nil end
  local dir, _ = Fs.cache_dir("build", { environment = environment })
  if dir == nil then return nil end
  return dir .. "/checks.db"
end

--- The bytecode of `roots` and of every module they require, however far, by `reads`: one part per module, its name
--- and the SHA-256 of its bytecode, sorted, where a binding of the core is `-`. Nil and why where a module the tool
--- holds has no bytecode to read, or a query failed.
local function closure_parts(reads: check_memo.Reads, roots: {string}): {string}?, string
  local seen: mut {string: boolean} = {}
  local names: mut {string} = {}
  local stack: mut {string} = {}
  for _, root in ipairs(roots) do stack[#stack + 1] = root end
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
      -- A name the tool holds neither a module nor a declaration of is a binding of the core, which `core` holds.
      -- One it holds with no bytecode to read (a declaration, a module that does not inflate) names no code.
      local held, held_trouble = reads.holds(name)
      if held == nil then return nil, name .. ": " .. held_trouble end
      if held then return nil, name .. ": " .. code_trouble end
    end
    parts[#parts + 1] = name .. " " .. (if code ~= nil then Hash.hex_sha256(code) else "-" end)
  end
  return parts, ""
end

function check_memo.code_of(reads: check_memo.Reads): string?, string
  local parts, trouble = closure_parts(reads, { "build.fix" })
  if parts == nil then return nil, trouble end
  local all: mut {string} = {}
  for _, part in ipairs(parts) do all[#all + 1] = part end
  all[#all + 1] = "core " .. reads.core
  return Hash.hex_sha256(table.concat(all, "\n")), ""
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
    local made, made_trouble = handle:exec("CREATE TABLE IF NOT EXISTS " .. shared_table .. " (code TEXT NOT NULL, " ..
        "kind TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, used_ns INTEGER NOT NULL, " ..
        "PRIMARY KEY (code, kind, key)) WITHOUT ROWID")
    if not made then return false, tostring(made_trouble) end
    return true, ""
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
    local ok, _ = db:run("INSERT OR REPLACE INTO " .. shared_table .. " (code, kind, key, value, used_ns) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5)",
      { { text = open.code }, { text = kind }, { text = key }, { text = rows[key] or "" }, { integer = now_ns } })
    if not ok then return false end
  end
  if open.bounded then return true end
  open.bounded = true
  local aged, _ = db:run("DELETE FROM " .. shared_table .. " WHERE used_ns < ?1",
    { { integer = now_ns - kept_ns } })
  if not aged then return false end
  local bounded, _ = db:run("DELETE FROM " .. shared_table .. " WHERE (code, kind, key) IN (SELECT code, kind, " ..
      "key FROM (SELECT code, kind, key, sum(length(CAST(code AS BLOB)) + length(CAST(kind AS BLOB)) + " ..
      "length(CAST(key AS BLOB)) + length(CAST(value AS BLOB))) OVER (ORDER BY used_ns DESC, code, kind, key) " ..
      "AS held FROM " .. shared_table .. ") WHERE held > ?1)", { { integer = open.kept_bytes } })
  return bounded == true
end

function check_memo.prepare(db: Sqlite.Handle, kind: string, within?: boolean): boolean, string
  local made, made_trouble = db:run(
    "CREATE TABLE IF NOT EXISTS check_memo (kind TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, " ..
      "used INTEGER NOT NULL, PRIMARY KEY (kind, key)) WITHOUT ROWID")
  if not made then
    return false, tostring(made_trouble)
  end
  local reset, reset_trouble = db:run("UPDATE check_memo SET used = 0 WHERE kind = ?1", { { text = kind } })
  if not reset then
    return false, tostring(reset_trouble)
  end
  found_keys[kind] = {}
  if within == true then return true, "" end
  -- One transaction for a run's lookups and writes: a commit for each of a
  -- thousand files is most of the cost of a memo.
  local answered, answer_why = db:run("BEGIN")
  if not answered then return false, tostring(answer_why) end
  return answered, ""
end

function check_memo.get(db: Sqlite.Handle, kind: string, key: string): string?
  local rows, _ = db:rows("SELECT value FROM check_memo WHERE kind = ?1 AND key = ?2",
    { { text = kind }, { text = key } })
  local row = if rows ~= nil then rows[1] else nil end
  if row == nil then
    local open = shared
    if open == nil or unshared[kind] ~= nil then return nil end
    local found, _ = open.db:rows("SELECT value FROM " .. shared_table ..
        " WHERE code = ?1 AND kind = ?2 AND key = ?3", { { text = open.code }, { text = kind }, { text = key } })
    local sibling = if found ~= nil then found[1] else nil end
    if sibling == nil then return nil end
    local taken = sibling:text(1)
    local _, _ = db:run("INSERT OR REPLACE INTO check_memo (kind, key, value, used) VALUES (?1, ?2, ?3, 1)",
      { { text = kind }, { text = key }, { text = taken } })
    owe(kind, key, taken)
    return taken
  end
  local value = row:text(1)
  local keys = found_keys[kind] or {}
  keys[#keys + 1] = key
  found_keys[kind] = keys
  -- Not owed to the shared file: the tool that made the row may have been of other code than this one.
  return value
end

function check_memo.put(db: Sqlite.Handle, kind: string, key: string, value: string)
  local _, _ = db:run("INSERT OR REPLACE INTO check_memo (kind, key, value, used) VALUES (?1, ?2, ?3, 1)",
    { { text = kind }, { text = key }, { text = value } })
  owe(kind, key, value)
end

function check_memo.finish(db: Sqlite.Handle, kind: string, now_ns?: integer, partial?: boolean, within?: boolean)
  if partial ~= true then
    local quoted: mut {string} = {}
    for i, key in ipairs(found_keys[kind] or {}) do
      quoted[i] = '"' .. (key:gsub('[%c"\\]', function(c: string): string
        return string.format("\\u%04x", c:byte()!)
      end)) .. '"'
    end
    local _, _ = db:run("DELETE FROM check_memo WHERE kind = ?1 AND used = 0 AND key NOT IN " ..
        "(SELECT value FROM json_each(?2))", { { text = kind }, { text = "[" .. table.concat(quoted, ",") .. "]" } })
  end
  found_keys[kind] = nil
  if within ~= true then
    local _, _ = db:run("COMMIT")
  end
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

--- The module a file of the tree is, by its path: `lang/check/` and [`lang/check/init.tl`] are [`lang.check`]. Nil for a
--- file that is no module: a declaration, or a file of another language.
local function module_of(file: string): string?
  local path = if file:sub(-1) == "/" then file:sub(1, -2) else file end
  if file:sub(-1) ~= "/" then
    if file:match("%.d%.tl$") ~= nil or file:match("%.tl$") == nil then return nil end
    path = path:sub(1, -4)
  end
  path = path:gsub("/init$", "")
  return (path:gsub("/", "."))
end

--- How the running tool is read for a salt: its own lookups, and no core, which a salt leaves out.
local TOOL <const>: check_memo.Reads = { requires = store_lookups.requires, bytecode = store_lookups.bytecode,
  holds = store_lookups.holds, core = "" }

--- The digest of the code of each list of modules the running tool was read for in this process, by the modules
--- joined: the tool does not change while it runs.
local coded: mut {string: string} = {}

--- How many salts could not name their code, so each is unlike every other.
local unnamed = 0

function check_memo.salt(root: string, files: {string}, version: string, reads?: check_memo.Reads): string
  local tool = reads or TOOL
  local parts: mut {string} = {}
  local modules: mut {string} = {}
  for _, file in ipairs(files) do
    local name = module_of(file)
    local held = false
    if name ~= nil then
      local holds, _ = tool.holds(name)
      held = holds == true
    end
    if name ~= nil and held then
      modules[#modules + 1] = name
    else
      local text, _ = Fs.read(root .. "/" .. file)
      parts[#parts + 1] = file .. "\0" .. Hash.hex_sha256(text or "")
    end
  end
  table.sort(modules)
  if #modules > 0 then
    local joined = table.concat(modules, " ")
    local digest = if reads == nil then coded[joined] else nil end
    if digest == nil then
      local code, _ = closure_parts(tool, modules)
      if code ~= nil then
        digest = Hash.hex_sha256(table.concat(code, "\n"))
        if reads == nil then coded[joined] = digest end
      else
        unnamed = unnamed + 1
        digest = "unnamed " .. tostring(Clock.now_ns()) .. " " .. tostring(unnamed)
      end
    end
    parts[#parts + 1] = "code " .. joined .. " " .. digest
  end
  parts[#parts + 1] = version
  return Hash.hex_sha256(table.concat(parts, "\0"))
end

function check_memo.closure_salt(db: Sqlite.Handle, modules: {string}, version: string): string?, string
  local imports, imports_trouble = db:rows("SELECT path, requires FROM imports")
  if imports == nil then return nil, "reading the imports: " .. tostring(imports_trouble) end
  local hashes, hashes_trouble = db:rows("SELECT path, hex(source_hash) FROM modules")
  if hashes == nil then return nil, "reading the modules: " .. tostring(hashes_trouble) end
  local requires: mut {string: mut {string}} = {}
  for _, row in ipairs(imports) do
    local list = requires[row:text(1)] or {}
    local required = row:text(2)
    list[#list + 1] = required
    requires[row:text(1)] = list
  end
  local hash_of: mut {string: string} = {}
  for _, row in ipairs(hashes) do hash_of[row:text(1)] = row:text(2) end
  local reached: mut {string: boolean} = {}
  local stack: mut {string} = {}
  for _, name in ipairs(modules) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = assert(stack[#stack])
    stack[#stack] = nil
    if reached[name] == nil then
      reached[name] = true
      for _, required in ipairs(requires[name] or {}) do stack[#stack + 1] = required end
    end
  end
  local names: mut {string} = {}
  for name in pairs(reached) do names[#names + 1] = name end
  table.sort(names)
  local parts: mut {string} = {}
  for _, name in ipairs(names) do parts[#parts + 1] = name .. "=" .. (hash_of[name] or "") end
  parts[#parts + 1] = version
  return Hash.hex_sha256(table.concat(parts, "\0")), ""
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
  -- Plain finds, and an unescape only for a line that holds a `\\`: a run decodes the memo of every file of the tree,
  -- and patterns and a substitution for each field were most of that.
  local size = #text
  local at = 1
  -- Where the next `\\` is, found again only once a line passes it, so that a memo with none is searched once.
  local escape = text:find("\\", 1, true) or size + 1
  -- Where the next tab is, kept as the escape is, so that a line without one does not search the rest of the text.
  local tab = text:find("\t", 1, true) or size + 1
  while at <= size + 1 do
    local stop = text:find("\n", at, true) or size + 1
    if escape < at then escape = text:find("\\", at, true) or size + 1 end
    local escaped = escape < stop
    local fields: mut {string} = {}
    local from = at
    while true do
      if tab < from then tab = text:find("\t", from, true) or size + 1 end
      local last = if tab < stop then tab - 1 else stop - 1 end
      local field = text:sub(from, last)
      if escaped then field = (field:gsub("\\(.)", UNESCAPES)) end
      fields[#fields + 1] = field
      if last + 1 >= stop then break end
      from = last + 2
    end
    rows[#rows + 1] = fields
    at = stop + 1
  end
  return rows
end

return check_memo
