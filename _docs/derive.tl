#!/usr/bin/env cosmic
--- Derived regions of committed documents, and the command that writes
--- them.
---
--- Some rows in a document are not prose: they are a restatement of
--- something the tree already says, and a restatement drifts. The
--- decisions index is the clearest case -- every row repeats a record's
--- own H1, so the index can disagree with the record it points at, and
--- has (#820 is a whole issue about one title).
---
--- These stay COMMITTED rather than generated into `o/` and embedded:
--- they are read on GitHub, by people who are not running a build. So
--- the shape is the one `.cosmic-coverage` already uses in this repo --
--- a derived file, a command that rewrites it, and a gate that fails
--- when the committed copy is stale (`_build/docs_test.tl`).
---
---     bin/cosmic _docs/derive.tl        # rewrite the derived regions
---
--- Rewriting a REGION, not a file, because the surrounding prose is
--- prose: it says why the records exist and how to add one, which no
--- generator can know.

local fs = require("cosmic.fs")
local proc = require("cosmic.proc")

local DECISIONS < const > = "docs/decisions"
local INDEX < const > = DECISIONS .. "/README.md"

--- The header row the decisions table starts at.
local DECISIONS_HEAD < const > = "| # | decision | |"

--- One decision record: its number, its title, and its file.
local record Record
  n: integer
  title: string
  file: string
end

--- Every record, in numbered order, read from its own H1.
---
--- The H1 is the record's title, so the index cannot say something the
--- record does not: `# D14 — no self-hosting: …` yields both the number
--- and the words. A record whose H1 does not parse is reported rather
--- than skipped -- a row silently missing from an index is exactly the
--- failure the index exists to prevent.
--- @return {Record} The records, ordered by number
--- @return {string} Files whose H1 could not be read
local function records(): {Record}, {string}
  local found: {Record} = {}
  local bad: {string} = {}
  local listed = fs.find(DECISIONS, {glob = "*.md"})
  if listed == nil then
    return found, {DECISIONS .. ": cannot be listed"}
  end
  local names = listed as {string} -- cast: union after the guard
  table.sort(names)
  for _, path in ipairs(names) do
    local base = fs.basename(path)
    if base ~= "README.md" then
      local text = fs.read(path) or ""
      local n, title = string.match(text, "^#%s*D(%d+)%s*—%s*(.-)%s*\n")
      if n and title then
        found[#found + 1] = {
          n = math.tointeger(tonumber(n)) or 0,
          title = title,
          file = base,
        }
      else
        bad[#bad + 1] = path
      end
    end
  end
  table.sort(found, function(a: Record, b: Record): boolean
      return a.n < b.n
    end)
  return found, bad
end

--- The decisions table, rendered.
--- @return string The header and rows, newline-joined
--- @return {string} Files whose H1 could not be read
local function decisions_table(): string, {string}
  local found, bad = records()
  local out: {string} = {DECISIONS_HEAD, "|---|---|---|"}
  for _, r in ipairs(found) do
    out[#out + 1] = "| D" .. r.n .. " | " .. r.title ..
    " | [→](" .. r.file .. ") |"
  end
  return table.concat(out, "\n"), bad
end

--- The table currently committed in a document.
--- @param text string The document
--- @param head string The table's header row
--- @return string The table as committed, or "" when absent
local function committed_table(text: string, head: string): string
  local rows: {string} = {}
  local inside = false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line == head then
      inside = true
      rows[#rows + 1] = line
    elseif inside then
      if line:sub(1, 1) ~= "|" then
        break
      end
      rows[#rows + 1] = line
    end
  end
  return table.concat(rows, "\n")
end

--- Replace a document's derived table with a freshly rendered one.
--- @param path string The document
--- @param head string The table's header row
--- @param rendered string The table to put there
--- @return boolean Whether the file changed
--- @return string The reason it could not be written
local function rewrite(path: string, head: string,
    rendered: string): boolean, string
  local text = fs.read(path) or ""
  if text == "" then
    return false, path .. ": cannot read"
  end
  local current = committed_table(text, head)
  if current == "" then
    return false, path .. ": no `" .. head .. "` table to rewrite"
  end
  if current == rendered then
    return false
  end
  local pattern = (current:gsub("%p", "%%%1"))
  local replacement = (rendered:gsub("%%", "%%%%"))
  -- gsub: replacement %%-escaped on the line above; the needle is a real pattern
  local ok, werr = fs.write(path, (string.gsub(text, pattern, replacement, 1)))
  if not ok then
    return false, path .. ": " .. (werr or "cannot write")
  end
  return true
end

local record DeriveModule
  DECISIONS_HEAD: string
  INDEX: string
  decisions_table: function(): string, {string}
  committed_table: function(text: string, head: string): string
end

local M: DeriveModule = {
  DECISIONS_HEAD = DECISIONS_HEAD,
  INDEX = INDEX,
  decisions_table = decisions_table,
  committed_table = committed_table,
}

if proc.is_main() then
  local rendered, bad = decisions_table()
  for _, path in ipairs(bad) do
    io.stderr:write("derive: " .. path ..
      ": no `# D<n> — <title>` heading; it is not in the index\n")
  end
  local changed, err = rewrite(INDEX, DECISIONS_HEAD, rendered)
  if err then
    io.stderr:write("derive: " .. err .. "\n")
    os.exit(1)
  end
  print(changed and ("derive: rewrote " .. INDEX)
    or ("derive: " .. INDEX .. " already matches the records"))
end

return M
