--- What a file run (`cosmic f.tl` in a tree) keeps of its last good build: a run of a tree in which nothing a
--- build reads has moved runs the projection that build left, and derives, compiles and writes nothing.
---
--- The writer leaves a projection as it is where the file's signature ([`build.writer`]'s `signature_sql`) is the
--- one it would write. That signature is a function of rows of the working database and of the links' answers: the
--- plan and inputs that derive and compile make of the staged files, the staged files, the zones, the web assets,
--- the identities in `meta`, and the digest of what the tree's links found ([`link_index.pending`]), on disk too.
--- The key here is a digest of what those are made from, taken after the stage and before any derive:
---
--- - every staged file, link file, tool file, zone and web asset;
--- - the links' digest, over the rows the last build planned;
--- - the identities of the running binary: what compiles, writes, links against and boots;
--- - the module the run names.
---
--- A run whose key is the one the last good run of its module kept, beside a projection whose signature is the one
--- that run wrote, would write that projection again. A run keeps its key only where its build left nothing out and
--- refused nothing, so a run that warned of a module builds, and warns, again.
---
--- The key is taken again once a build has written its projection, over the rows the build made, which are the rows
--- the next run's stage finds, and with the links' digest the write signed.

local Fs = require("cosmic.fs")
local GrammarMode = require("build.grammar_mode")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")

local record run_stamp
  --- The tool string a compile of this binary's own compiler is keyed by ([`GrammarMode.tool`]): the compiler's
  --- identity the build that made this binary recorded (its `meta`'s `compiler`), so a project's rows made by
  --- another compiler are compiled again. A worker's read of it is answered by the running tool
  --- ([`build.key_parts`]' `meta_readers` names this module for it).
  own_tool: function(): string

  --- The key of a run of the module `target` in the tree at `root` (cosmic's own where `own`), compiled with `tool`
  --- (the tool string [`importer.compile_for`] is given), over the working database `db` as the stage left it. `links`
  --- is the digest of the links a write signed ([`writer.signed`]), in place of resolving them again. Returns nil where
  --- `db` or the links cannot say.
  key: function(db: Sqlite.Handle, root: string, own: boolean, tool: string, target: string, links?: string): string?

  --- Whether the run whose key is `key` is the last good one of `target` in the tree directory `dir`, and the
  --- projection at `projection` is the one that run left.
  holds: function(dir: string, key: string, target: string, projection: string): boolean

  --- Keeps `key` as the last good run of `target` in `dir`, beside `signature`, that of the projection its build
  --- wrote ([`writer.signed`]). A failure to keep it costs the next run its shortcut only, so it returns nothing.
  mark: function(dir: string, key: string, target: string, signature: string)
end

--- What the working database holds that a build reads and that the stage, a boot or a refresh wrote, by path or
--- name and digest. Its `meta` is left out: the identities a write keeps there are the running binary's, which the
--- key holds as the binary carries them, and a build writes them after the stage.
local inputs_sql <const> = "SELECT lower(hex(sha256(" ..
  "coalesce((SELECT group_concat(path || ' ' || sha256, char(10) ORDER BY path) FROM files), '') || char(10) || " ..
  "coalesce((SELECT group_concat(path || ' ' || kind || ' ' || sha256, char(10) ORDER BY path) FROM linked), " ..
  "'') || char(10) || " ..
  "coalesce((SELECT group_concat(path || ' ' || sha256, char(10) ORDER BY path) FROM tool), '') || char(10) || " ..
  "coalesce((SELECT group_concat(name || ' ' || lower(hex(sha256(data))), char(10) ORDER BY name) " ..
  "FROM zoneinfo), '') || char(10) || " ..
  "coalesce((SELECT group_concat(name || ' ' || sha256, char(10) ORDER BY name) FROM web_assets), ''))))"

--- The file of `dir` that keeps the last good run of `target`.
local function file_of(dir: string, target: string): string
  return dir .. "/runs/" .. Hash.hex_sha256(target)
end

--- The signature the projection at `path` carries, or nil where there is none to read.
local function signature_of(path: string): string?
  local db, _ = Sqlite.open(path)
  if db == nil then return nil end
  local rows, _ = Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'projected'")
  local _, _ = db:close()
  if rows == nil then return nil end
  local row = rows[1]
  if row == nil then return nil end
  return row:text(1)
end

function run_stamp.own_tool(): string
  return GrammarMode.tool(Store.meta("compiler") or "")
end

function run_stamp.key(db: Sqlite.Handle, root: string, own: boolean, tool: string, target: string,
                       links?: string): string?
  local rows, _ = Sqlite.text_rows(db, inputs_sql)
  if rows == nil then return nil end
  local row = rows[1]
  if row == nil then return nil end
  -- What the links found, the disk's answers among them, with the library they may name as the writer gives it.
  local digest = links
  if digest == nil then
    local link_index = require("build.link_index")
    local library: link_index.Library? = if own then nil else link_index.running() end
    local pending, _ = link_index.pending(db, root, library)
    if pending == nil then return nil end
    digest = pending.digest
  end
  local parts: mut {string} = { require("build.code_identity").coded(tool), target, row:text(1), digest }
  parts[#parts + 1] = Store.meta("boot_hash") or ""
  parts[#parts + 1] = Store.meta("compiler") or ""
  parts[#parts + 1] = Store.meta("image_hash") or ""
  parts[#parts + 1] = Store.meta("receivers") or ""
  parts[#parts + 1] = Store.meta("runtime_basis") or ""
  parts[#parts + 1] = Store.meta("writer") or ""
  -- What the writer's rows of each payload come from (its `mime_digest`).
  local mime, _ = Store.bytecode("cosmic.mime")
  parts[#parts + 1] = Hash.hex_sha256(mime or "")
  return Hash.hex_sha256(table.concat(parts, "\0"))
end

function run_stamp.holds(dir: string, key: string, target: string, projection: string): boolean
  local kept, _ = Fs.read(file_of(dir, target))
  if kept == nil then return false end
  local signature = signature_of(projection)
  if signature == nil or signature == "" then return false end
  return kept == key .. "\n" .. signature .. "\n"
end

function run_stamp.mark(dir: string, key: string, target: string, signature: string)
  if signature == "" then return end
  local made, _ = Fs.mkdirs(dir .. "/runs")
  if not made then return end
  local _, _ = Fs.write(file_of(dir, target), key .. "\n" .. signature .. "\n")
end

return run_stamp
