--- The artifact a sandboxed worker that builds roots of its own (`nests`),
--- or whose module declares `lua` where it cannot run on a sealed database
--- (build/test.tl's `sealed_for`), opens by its path in place of the program's: the
--- program's launcher, cores and manifest, with a database of the worker's
--- import closure ([`build.closure_store`]) and of what every worker loads.
--- A worker of that kind is handed no descriptor of the program
--- ([`build.test_worker`]'s `invocation`), so what it and its starts read
--- of the artifact is what it is given at the artifact's name, and the real
--- one holds every module of the tree, beyond what the key of a test that
--- declares neither `store` nor `tool` holds.
---
--- Its bytes follow from what a key holds already, or what the harness's
--- epoch does: the head ([`declared_key.launcher_identity`]'s
--- `keyed_head`, which every key holds where an artifact runs the
--- program), the closure store's bytes ([`declared_key.store_digest`]), and
--- the rows of the modules every worker loads that the program carries
--- ([`build.test_worker`]'s `loads`, held by the harness's digests), and
--- the zones and CA roots, which every key holds by their digest.
--- The worker's own start reads those from the artifact; a closure store
--- has them only where the tree is the program's own.

local artifact = require("build.artifact")
local Fs = require("cosmic.fs")
local hashing = require("build.digest")
local Sqlite = require("cosmic.sqlite")

local record closure_artifact
  --- The program's artifact cut at its database ([`artifact.split`]), and
  --- the digest of all its bytes, which names the artifacts made from it.
  record Program
    parts: artifact.Split
    digest: string
  end
end

-- TODO: share the head between the artifacts of every closure, which each
-- carry a copy of the launcher and cores (most of the program's size), once
-- core/startup.c's by-path start can take the launcher and cores from one
-- file and the database from another, or once the filesystems the stores
-- directory is on are known to reflink: today each closure that nests costs
-- the program's size in o/stores.

--- The program's artifact at `path`, or nil and why where it is none: a
--- host program has no launcher to open by a path, and a worker whose
--- program is one has no artifact to be given.
--- @param path the program's artifact
--- @return the program, nil where it has none
--- @return why, where it has none
function closure_artifact.read(path: string): closure_artifact.Program | nil, string
  local bytes, read_trouble = Fs.read(path)
  if bytes == nil then return nil, path .. ": " .. read_trouble end
  local parts, split_trouble = artifact.split(bytes)
  if parts == nil then return nil, path .. ": " .. split_trouble end
  if parts.host then return nil, path .. ": a host program has no launcher to open by path" end
  return { parts = parts, digest = hashing.hex_sha256(bytes) }, ""
end

--- The statements that add to a closure store the modules of the program's
--- database `program`, attached, that every worker loads (`loads`) or
--- that the tree does not have (`tree`) -- its standard library, where the
--- tree is another's -- and the store has not, as [`build.closure_store`]'s
--- `write` carries a module: its row, less the key (the compiler's
--- identity, which no worker reads), the imports among them and the
--- names it binds. The program's `meta` rows replace the store's, which
--- name its main module. The zones and the CA roots are carried whole,
--- since the core, [`cosmic.time`] and [`cosmic.http`] read them from the
--- program's own database alone, and every key holds them by their
--- digest ([`build.schema`]'s `tables_digest`). No other table is carried
--- (docs, uses, links and the payload rows): a worker's own start and the
--- starts of its test read modules alone, and what else a key does not
--- hold the program's rows of stays out of reach.
local adding: {string} = {
  "CREATE TEMP TABLE added (path TEXT PRIMARY KEY)",
  "INSERT INTO temp.added SELECT path FROM program.modules WHERE " ..
    "(path IN temp.loads OR path NOT IN temp.tree) AND path NOT IN (SELECT path FROM main.modules)",
  "INSERT OR REPLACE INTO main.meta SELECT * FROM program.meta WHERE key IN " ..
    "('image_hash', 'main', 'runtime_basis')",
  "INSERT INTO main.modules (path, file, kind, source_hash, key, bytecode, tests, source) " ..
    "SELECT path, file, kind, source_hash, X'', bytecode, tests, source FROM program.modules " ..
    "WHERE path IN temp.added ORDER BY path",
  "INSERT OR IGNORE INTO main.imports SELECT * FROM program.imports " ..
    "WHERE path IN temp.added AND requires IN (SELECT path FROM main.modules) " ..
    "ORDER BY path, requires",
  "INSERT OR IGNORE INTO main.bound SELECT * FROM program.bound WHERE path IN temp.added " ..
    "ORDER BY path, name",
  "INSERT INTO main.zoneinfo (name, data) SELECT name, data FROM program.zoneinfo ORDER BY name",
  "INSERT INTO main.ca_roots SELECT * FROM program.ca_roots ORDER BY sha256",
}

--- The file name, in the stores directory, of the artifact of the closure
--- store at `address` made from `program`, `loads` and `tree` (`write`): it
--- holds all of them, and the statements that carry rows of the program
--- (`adding`), so a rebuilt program, an edited closure, a tree whose
--- modules are others, or another choice of rows is another file.
--- @param address the closure store's address ([`build.closure_store`]'s `address`)
--- @param program the program's artifact
--- @param loads the modules every worker loads
--- @param tree the modules of the tree
--- @return the name
function closure_artifact.name(address: string, program: closure_artifact.Program,
                               loads: {string}, tree: {string}): string
  local text = program.digest .. "\0" .. table.concat(loads, "\n") .. "\0" ..
    table.concat(tree, "\n") .. "\0" .. table.concat(adding, "\n")
  return address .. "-" .. hashing.hex_sha256(text):sub(1, 16) .. ".artifact"
end

--- Writes the artifact of the closure store at `store` to `out`: the
--- launcher, cores and manifest of `program`, then a database holding the
--- store and the modules of the program that `loads` names or that
--- `tree`, the modules of the tree the store was written from, lacks, and
--- the store does not hold. Written through a rename, so one at `out` is whole;
--- its temporary files, beside it, are removed.
--- @param program the program's artifact
--- @param store the closure store's path
--- @param loads the modules every worker loads
--- @param tree the modules of the tree
--- @param out where to write
--- @return whether it was written
--- @return why not
function closure_artifact.write(program: closure_artifact.Program, store: string,
                                loads: {string}, tree: {string}, out: string): boolean, string
  local aside, carried = out .. ".building", out .. ".program"
  local function cleanup()
    for _, path in ipairs({ aside, carried }) do
      local _, _ = Fs.remove(path)
    end
  end
  local original, read_store_trouble = Fs.read(store)
  if original == nil then return false, store .. ": " .. read_store_trouble end
  local copied, copy_trouble = Fs.write(aside, original)
  if not copied then
    cleanup()
    return false, copy_trouble
  end
  local wrote, write_trouble = Fs.write(carried, program.parts.database)
  if not wrote then
    cleanup()
    return false, write_trouble
  end
  local opened, open_trouble = Sqlite.open(aside, { writable = true })
  if opened == nil then
    cleanup()
    return false, aside .. ": " .. open_trouble
  end
  local db: Sqlite.Handle = opened
  local function fill(): boolean, string
    local attached, attach_trouble = Sqlite.run(db, "ATTACH DATABASE ?1 AS program",
      { { text = carried } })
    if not attached then return false, attach_trouble end
    local made, made_trouble = Sqlite.transact(db, function(): boolean, string
      local tables: {string:{string}} = { loads = loads, tree = tree }
      for _, table_name in ipairs({ "loads", "tree" }) do
        local ok, failure = db:exec("CREATE TEMP TABLE " .. table_name ..
            " (path TEXT PRIMARY KEY)")
        if not ok then return false, failure end
        for _, name in ipairs(tables[table_name]) do
          local inserted, insert_trouble = Sqlite.run(db,
            "INSERT OR IGNORE INTO temp." .. table_name .. " (path) VALUES (?1)",
            { { text = name } })
          if not inserted then return false, insert_trouble end
        end
      end
      for _, statement in ipairs(adding) do
        local done, why = db:exec(statement)
        if not done then return false, why end
      end
      return true, ""
    end)
    local _, _ = db:exec("DETACH program")
    if not made then return false, made_trouble end
    return true, ""
  end
  local filled, fill_trouble = fill()
  local _, _ = db:close()
  if not filled then
    cleanup()
    return false, fill_trouble
  end
  local database, read_trouble = Fs.read(aside)
  cleanup()
  if database == nil then return false, aside .. ": " .. read_trouble end
  local bytes, join_trouble = artifact.rejoin(program.parts, database)
  if bytes == nil then return false, join_trouble end
  return Fs.write(out, bytes)
end

return closure_artifact
