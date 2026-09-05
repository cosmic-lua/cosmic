--- Internal helper for cosmic.sqlite: atomic rebuild-in-place for a
--- WAL-mode database file. Lives in its own file so
--- cosmic/sqlite/init.tl stays under the 500-line cap.
---
--- The mechanism: `fill_fn` opens its own connection at a
--- `<final>.tmp.<pid>` path, populates it, and closes it; `finish`
--- then forces a checkpoint on that same file (`PRAGMA journal_mode =
--- DELETE`, which also drops its own `-wal`/`-shm` sidecars) before
--- renaming it into place — cosmic/sqlite/init.tl reopens the renamed
--- file in WAL mode once this returns. Skipping the
--- checkpoint-before-rename step is a genuine, non-obvious gotcha: a
--- rename only moves the one path it names, so a `-wal` left behind
--- under the temp name becomes permanent litter beside the renamed
--- file instead. The checkpoint here goes through the raw lsqlite3
--- binding rather than cosmic.sqlite's own ergonomic wrapper: this
--- module cannot import that wrapper's Database type without cycling
--- back to init.tl, its own caller, and a bare PRAGMA needs nothing
--- an ergonomic wrapper would add.

local fs = require("cosmic.fs")
local lsqlite3 = require("cosmo.lsqlite3")
local proc = require("cosmic.proc")

--- Remove each path that exists; a missing path is fine, and a
--- removal failure is swallowed — this is best-effort litter cleanup,
--- never a step whose failure should block a rebuild that otherwise
--- succeeded.
--- @param paths {string} Paths to remove if present
local function remove_if_present(paths: {string})
  for _, p in ipairs(paths) do
    if fs.is_present(p) then
      local _ok, _err = fs.remove(p)
    end
  end
end

--- The `-wal`/`-shm` sidecar paths a WAL-mode file may have beside it.
--- @param path string The database file's path
--- @return {string} The two sidecar paths
local function sidecars(path: string): {string}
  return {path .. "-wal", path .. "-shm"}
end

--- Begin a rebuild: the temp path `fill_fn` should populate, with any
--- leftover from a crashed prior attempt (and its sidecars) wiped
--- first, so stale rows can never leak into the fresh build.
--- @param final_path string The file being rebuilt
--- @return string The temp path to populate
local function start(final_path: string): string
  local tmp_path = ("%s.tmp.%d"):format(final_path, proc.getpid())
  remove_if_present({tmp_path, table.unpack(sidecars(tmp_path))})
  return tmp_path
end

--- Discard a temp file after a failed `fill_fn`: remove it and its
--- sidecars, leaving `final_path` untouched.
--- @param tmp_path string The temp path from start()
local function discard(tmp_path: string)
  remove_if_present({tmp_path, table.unpack(sidecars(tmp_path))})
end

--- Force the populated temp file's WAL checkpoint, drop its sidecars,
--- and rename it into place. Call once `fill_fn` has populated and
--- closed its own connection at `tmp_path`.
--- @param tmp_path string The populated temp file
--- @param final_path string Where to rename it
--- @return boolean True once the file is in place at final_path
--- @return string Error message
local function finish(tmp_path: string, final_path: string): boolean, string
  local raw_db, errmsg = lsqlite3.open(tmp_path)
  if not (raw_db is lsqlite3.Database) then
    return false, errmsg or "could not reopen the temp file to checkpoint it"
  end
  if raw_db:exec("PRAGMA journal_mode = DELETE") ~= lsqlite3.OK then
    local em = raw_db:errmsg()
    raw_db:close()
    return false, em
  end
  if raw_db:close() ~= lsqlite3.OK then
    return false, raw_db:errmsg()
  end
  remove_if_present(sidecars(tmp_path))
  return fs.move(tmp_path, final_path)
end

local record rebuild
  start: function(final_path: string): string
  discard: function(tmp_path: string)
  finish: function(tmp_path: string, final_path: string): boolean, string
end

local M: rebuild = {
  start = start,
  discard = discard,
  finish = finish,
}

return M
