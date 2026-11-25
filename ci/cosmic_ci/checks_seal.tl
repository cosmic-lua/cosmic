--- The memo of the tree checks the merge queue's format check made, sealed
--- for the relay of the same commit (relay.yml), which keeps it for the
--- next pull requests and queue entries. The memo is the
--- shared rows of the candidate's build/check_memo.tl (its table
--- `check_memo_v1`), in `checks.db` of the cache directory. A run of the
--- format check writes them in write-ahead mode and exits with them still
--- in the `-wal` file beside it, which neither the artifact nor the cache
--- carries; so the queue seals the file before its upload, and the relay
--- holds the file it downloaded to the same before its save.
---
--- To seal is to drop the rows the run did not make or take (stamped before
--- SINCE, in Unix seconds; every row a run of a fresh tree used is one
--- of those), copy the rest into the file itself, and leave it a file of one
--- piece (`journal_mode = DELETE`), small enough to keep per commit. A file
--- with no row, or no such table, is refused: a save of it would be the
--- newest, and the next runs would check from cold.
local Fs = require("cosmic.fs")
local Plural = require("cosmic_ci.plural")
local Sqlite = require("cosmic.sqlite")

local record ChecksSeal
  --- What a seal came to: standard output and the diagnostics.
  record Said
    code: integer
    out: string
    err: string
  end
end

--- The shared rows' table, as build/check_memo.tl names it.
local TABLE <const> = "check_memo_v1"

--- Seals the memo at `path`, keeping the rows used at or after `since_s` (all of them where nil). 1 where the file
--- is no usable memo, 2 where `path` is not absolute, else 0.
function ChecksSeal.seal(path: string, since_s?: integer): ChecksSeal.Said
  if path:sub(1, 1) ~= "/" or path:find("\0", 1, true) ~= nil then
    return { code = 2, out = "", err = "checks-seal: PATH must be an absolute path\n" }
  end
  local present, _ = Fs.stat(path)
  if present == nil then
    return { code = 1, out = "", err = "checks-seal: " .. path .. ": no memo to seal\n" }
  end
  local db, opened = Sqlite.open(path, { writable = true })
  if db == nil then
    return { code = 1, out = "", err = "checks-seal: " .. path .. ": " .. tostring(opened) .. "\n" }
  end
  local function refused(why: string): ChecksSeal.Said
    local _, _ = db:close()
    return { code = 1, out = "", err = "checks-seal: " .. path .. ": " .. why .. "\n" }
  end
  local named, named_trouble = db:text_rows("SELECT name FROM sqlite_schema WHERE type = 'table' AND name = ?1",
    { { text = TABLE } })
  if named == nil then return refused(tostring(named_trouble)) end
  if #named == 0 then return refused("no table " .. TABLE) end
  if since_s ~= nil then
    local dropped, dropped_trouble = db:run("DELETE FROM " .. TABLE .. " WHERE used_ns < ?1",
      { { integer = since_s * 1000000000 } })
    if not dropped then return refused(tostring(dropped_trouble)) end
  end
  local counted, counted_trouble = db:text_rows("SELECT count(*) FROM " .. TABLE)
  if counted == nil then return refused(tostring(counted_trouble)) end
  local first = counted[1]
  local rows = if first ~= nil then math.tointeger(tonumber(first:text(1))) or 0 else 0 end
  if rows == 0 then return refused("no row the run used") end
  for _, sql in ipairs({ "VACUUM", "PRAGMA wal_checkpoint(TRUNCATE)", "PRAGMA journal_mode = DELETE" }) do
    local ok, why = db:exec(sql)
    if not ok then return refused(sql .. ": " .. tostring(why)) end
  end
  local closed, close_trouble = db:close()
  if not closed then
    return { code = 1, out = "", err = "checks-seal: " .. path .. ": " .. tostring(close_trouble) .. "\n" }
  end
  local stat, _ = Fs.stat(path)
  local bytes = if stat ~= nil then stat.size else 0 end
  return { code = 0, out = "checks-seal: " .. path .. ": " .. Plural.count(rows, "row") .. ", " ..
      Plural.count(bytes, "byte") .. "\n", err = "" }
end

--- `driver.tl checks-seal PATH [SINCE]`.
function ChecksSeal.command(argv: {string}): integer
  local since: integer? = nil
  local given = argv[2]
  if given ~= nil then
    since = math.tointeger(tonumber(given))
    if since == nil or since < 0 then
      local _, _ = Fs.put(Fs.stderr, "checks-seal: SINCE must be Unix seconds\n")
      return 2
    end
  end
  local said = ChecksSeal.seal(argv[1] or "", since)
  if said.out ~= "" then local _, _ = Fs.put(Fs.stdout, said.out) end
  if said.err ~= "" then local _, _ = Fs.put(Fs.stderr, said.err) end
  return said.code
end

return ChecksSeal
