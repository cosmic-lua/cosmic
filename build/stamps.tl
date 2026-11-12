--- Works out the stamps a tool's database carries and writes them
--- (`fill`): the identities every start of the tool would otherwise work
--- out again from its own rows, which [`build.stamp`] reads instead.
---
--- - `stamp_coded`: the code that reads and checks ([`build.pipeline`]'s
---   `code_of`), which a compile is keyed by and a start compares the
---   database's compiler with.
--- - `stamp_analyzer`: the analyzer's identity
---   ([`importer.analyzer_identity`]), which a parse is keyed by.
--- - `stamp_harness`: the test harness's digests ([`test_key.harness`]),
---   which every verdict's key holds.
--- - `stamp_extras`: the rows the digest of the modules a tree lacks is
---   taken over ([`test_key.extras_rows`]), which the key of a worker on a
---   sealed database holds.
---
--- Each is worked out from the database being written by the function
--- that works it out at a start, given that database in place of the
--- running binary's. So a stamp is what the tool carrying the database
--- would work out, provided the code working it out here is the code
--- that database carries. `fill` writes stamps only then (`code`): a boot
--- runs the tree's own code, and a tool writes the database of a tree
--- whose stamping code is its own. A stale tool whose stamping code the
--- tree has moved writes none, and the tool it wrote, which finds none,
--- writes its database again itself ([`build.reboot`]'s `unsettled`).

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Pipeline = require("build.pipeline")
local Stamp = require("build.stamp")
local importer = require("build.importer")
local test_key = require("build.test_key")

local record stamps
  --- The identity of the code `db` carries that works out its stamps:
  --- this module and every module it requires, directly or not, each by
  --- the hash of its source. Nil where `db` does not carry this module or
  --- cannot be read.
  code: function(db: Sqlite.Handle): string?

  --- Writes into `db`'s `meta` the stamps of its own rows and the row
  --- that binds them to those rows ([`Stamp.content`]), in place of any
  --- it holds. It writes none where the code `running` carries (by
  --- default the running binary's own database) is not the stamping
  --- code `db` carries, and a stamp that cannot be worked out is left
  --- out. A process with no database, a boot, runs the code of the tree
  --- it is writing. False and why where `db` cannot be written.
  fill: function(db: Sqlite.Handle, running?: Sqlite.Handle): boolean, string
end

-- TODO: name the stamping code by the modules that work a stamp out and no
-- others, once test_key.harness, importer.analyzer_identity and
-- Pipeline.code_of live in modules that require only what they run: today
-- `code` holds all that this module requires, each by its source, so a
-- comment anywhere in it has the rebuilt tool write its database again.
function stamps.code(db: Sqlite.Handle): string?
  local rows, _ = Sqlite.text_rows(db,
    "WITH RECURSIVE reached(name) AS (VALUES ('build.stamps') UNION " ..
      "SELECT requires FROM imports JOIN reached ON path = name) " ..
      "SELECT sum(path = 'build.stamps'), lower(hex(sha256(group_concat(path || ' ' || " ..
      "hex(source_hash), char(10) ORDER BY path)))) FROM modules WHERE path IN reached")
  if rows == nil then return nil end
  local row = rows[1]
  if row == nil or row:text(1) ~= "1" then return nil end
  return row:text(2)
end

--- What a walk over `db`'s sources found that leaves its stamps unknown.
local record Reading
  mut withheld: boolean
end

--- The source of the module or declaration `name` of `db`, as
--- [`Store.source`] answers it of the binary's own: a declaration's ahead
--- of a module's, nil for a name it holds no row of. A row held without
--- its source is marked in `reading`.
local function source_of(db: Sqlite.Handle, reading: Reading, name: string): string?
  for _, table_name in ipairs({ "decls", "modules" }) do
    local rows, _ = Sqlite.rows(db, "SELECT length(source), inflate(source) FROM " .. table_name ..
        " WHERE path = ?1", { { text = name } })
    local row = if rows ~= nil then rows[1] else nil end
    if row ~= nil then
      if row:integer(1) == 0 then
        reading.withheld = true
        return nil
      end
      return row:blob(2)
    end
  end
  return nil
end

--- What the module `name` of `db` requires, as [`Store.requires`] answers
--- it of the binary's own.
local function requires_of(db: Sqlite.Handle, name: string): {string}
  local rows, _ = Sqlite.text_rows(db, "SELECT requires FROM imports WHERE path = ?1 ORDER BY requires",
    { { text = name } })
  local names: mut {string} = {}
  for _, row in ipairs(rows or {}) do names[#names + 1] = row:text(1) end
  return names
end

--- The harness of `db` as its stamp spells it: its digest, the salt of
--- its stores, then each module's name and digest, a line each, in the
--- order `names` holds them.
local function harness_text(harness: test_key.Harness): string
  local lines: mut {string} = { harness.digest, harness.store_salt }
  for _, name in ipairs(harness.names) do
    lines[#lines + 1] = name .. "\t" .. (harness.modules[name] or "")
  end
  return table.concat(lines, "\n")
end

--- The stamps of `db`'s rows, by key, less each that cannot be worked
--- out; none where a source it would read is withheld.
local function worked(db: Sqlite.Handle): mut {string:string}
  local out: mut {string:string} = {}
  local reading: Reading = { withheld = false }
  local function source(name: string): string? return source_of(db, reading, name) end
  local function requires(name: string): {string} return requires_of(db, name) end
  out["stamp_coded"] = Pipeline.code_of(source, requires)
  local basis_rows, _ = Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'runtime_basis'")
  local basis_row = if basis_rows ~= nil then basis_rows[1] else nil end
  -- Given the code, it raises for nothing: a source held without its text is marked in `reading`.
  local analyzer = importer.analyzer_identity({
    basis = if basis_row ~= nil then basis_row:text(1) else "" end,
    requires = function(name: string): {string}?, string return requires(name), "" end,
    source = function(name: string): string?, string return source(name), "" end,
  })
  -- A binary that carries no source of an analyzer module names its
  -- analyzer by its whole boot hash, which is no function of these rows.
  if analyzer:sub(1, 7) ~= "binary " then out["stamp_analyzer"] = analyzer end
  if reading.withheld then return {} end
  local harness, _ = test_key.harness(db)
  if harness ~= nil then out["stamp_harness"] = harness_text(harness) end
  local extras, _ = test_key.extras_rows(db)
  if extras ~= nil then
    local lines: mut {string} = {}
    for i, row in ipairs(extras) do lines[i] = table.concat(row, "\t") end
    out["stamp_extras"] = table.concat(lines, "\n")
  end
  return out
end

function stamps.fill(db: Sqlite.Handle, running?: Sqlite.Handle): boolean, string
  local cleared, clear_trouble = Sqlite.run(db, "DELETE FROM meta WHERE key LIKE 'stamp!_%' ESCAPE '!'", {})
  if not cleared then return false, clear_trouble end
  local binary = running
  if binary == nil then
    local databases = Store.databases()
    binary = databases[#databases]
  end
  local code = stamps.code(db)
  if code == nil or (binary ~= nil and stamps.code(binary) ~= code) then return true, "" end
  local content, content_trouble = Stamp.content(db)
  if content == nil then return false, content_trouble end
  local rows = worked(db)
  rows[Stamp.of] = content
  local keys: mut {string} = {}
  for key in pairs(rows) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local written, trouble = Sqlite.run(db, "INSERT INTO meta (key, value) VALUES (?1, ?2)",
      { { text = key }, { text = rows[key] } })
    if not written then return false, trouble end
  end
  return true, ""
end

return stamps
