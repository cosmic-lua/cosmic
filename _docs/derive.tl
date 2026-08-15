#!/usr/bin/env cosmic
--- Derived regions of committed documents, and the command that writes
--- them.
---
--- Some rows in a document are not prose: they are a restatement of
--- something the tree already says, and a restatement drifts. The
--- decisions index is the clearest case -- every row repeats a record's
--- own H1 and status header, so the index can disagree with the record
--- it points at, and has (#820 is a whole issue about one title).
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

local docs = require("cosmic.doc")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")

local DECISIONS < const > = "docs/decisions"
local INDEX < const > = DECISIONS .. "/README.md"

--- The header row the decisions table starts at.
local DECISIONS_HEAD < const > = "| # | decision | status | |"

--- The document holding the derived module table, and its header row.
local AGENTS < const > = "AGENTS.md"
local MODULES_HEAD < const > = "| module | description |"

--- One decision record: its number, its title, its status, and its file.
local record Record
  n: integer
  title: string
  status: string
  file: string
end

--- Whether a status header uses the vocabulary a record may claim.
---
--- Three states and no others: the decision stands, a fact under it
--- moved (amended, dated), or a later record reversed it. A
--- `superseded by D<n>` naming a record that does not exist is refused
--- here, because the whole value of the pointer is that it lands.
--- @param status string The status header's text
--- @param numbered {integer:boolean} Every record number that exists
--- @return boolean Whether the status is one of the three
local function is_status(status: string,
    numbered: {integer: boolean}): boolean
  if status == "active" then
    return true
  end
  if status:match("^amended %d%d%d%d%-%d%d") ~= nil then
    return true
  end
  local target = status:match("^superseded by D(%d+)$")
  if target ~= nil then
    return numbered[math.tointeger(tonumber(target)) or 0] == true
  end
  return false
end

--- Every record, in numbered order, read from its own H1 and status.
---
--- The H1 is the record's title, so the index cannot say something the
--- record does not: `# D14 — no self-hosting: …` yields both the number
--- and the words. A record whose H1 or status does not parse is
--- reported rather than skipped -- a row silently missing from an index
--- is exactly the failure the index exists to prevent.
--- @return {Record} The records, ordered by number
--- @return {string} Records whose heading or status could not be read
local function records(): {Record}, {string}
  local found: {Record} = {}
  local bad: {string} = {}
  local listed = fs.find(DECISIONS, {glob = "*.md"})
  if listed == nil then
    return found, {DECISIONS .. ": cannot be listed"}
  end
  local names = listed
  table.sort(names)
  for _, path in ipairs(names) do
    local base = fs.basename(path)
    if base ~= "README.md" then
      local text = fs.read(path) or ""
      local n, title = string.match(text, "^#%s*D(%d+)%s*—%s*(.-)%s*\n")
      local status = string.match(text, "\n%-%s*%*%*status:%*%*%s*(.-)%s*\n")
      if n == nil or title == nil then
        bad[#bad + 1] = path .. ": no `# D<n> — <title>` heading"
      elseif status == nil then
        bad[#bad + 1] = path .. ": no `- **status:** <status>` line"
      else
        found[#found + 1] = {
          n = math.tointeger(tonumber(n)) or 0,
          title = title,
          status = status,
          file = base,
        }
      end
    end
  end
  table.sort(found, function(a: Record, b: Record): boolean
      return a.n < b.n
    end)
  local numbered: {integer: boolean} = {}
  for _, r in ipairs(found) do
    numbered[r.n] = true
  end
  for _, r in ipairs(found) do
    if not is_status(r.status, numbered) then
      bad[#bad + 1] = DECISIONS .. "/" .. r.file ..
      ": status is not `active`, `amended <YYYY-MM>` or " ..
      "`superseded by D<n>`: `" .. r.status .. "`"
    end
  end
  return found, bad
end

--- The decisions table, rendered.
--- @return string The header and rows, newline-joined
--- @return {string} Records whose heading or status could not be read
local function decisions_table(): string, {string}
  local found, bad = records()
  local out: {string} = {DECISIONS_HEAD, "|---|---|---|---|"}
  for _, r in ipairs(found) do
    out[#out + 1] = "| D" .. r.n .. " | " .. r.title ..
    " | " .. r.status .. " | [→](" .. r.file .. ") |"
  end
  return table.concat(out, "\n"), bad
end

--- The module table, rendered from the embedded doc index — the same
--- source `--help` renders its module list from at runtime (#1003), so
--- the committed table cannot describe a module differently than the
--- binary does. A row's text is its module's own H1 first line; a bad
--- row is fixed at the module header, and the fix propagates here.
--- @return string The header and rows, newline-joined
local function modules_table(): string
  local rows: {{string, string}} = {}
  for _, t in ipairs(docs.topics()) do
    local name = t[1]
    if name:sub(1, 7) == "cosmic." then
      rows[#rows + 1] = {name:sub(8), (t[2] or ""):gsub("%s+$", "")}
    end
  end
  table.sort(rows, function(a: {string}, b: {string}): boolean
      return a[1] < b[1]
    end)
  local out: {string} = {MODULES_HEAD, "|--------|-------------|"}
  for _, r in ipairs(rows) do
    out[#out + 1] = "| " .. r[1] .. " | " .. r[2] .. " |"
  end
  return table.concat(out, "\n")
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
  AGENTS: string
  MODULES_HEAD: string
  decisions_table: function(): string, {string}
  modules_table: function(): string
  committed_table: function(text: string, head: string): string
end

local M: DeriveModule = {
  DECISIONS_HEAD = DECISIONS_HEAD,
  INDEX = INDEX,
  AGENTS = AGENTS,
  MODULES_HEAD = MODULES_HEAD,
  decisions_table = decisions_table,
  modules_table = modules_table,
  committed_table = committed_table,
}

if proc.is_main() then
  local rendered, bad = decisions_table()
  -- A record that cannot be read stops the rewrite rather than landing
  -- a table that omits it or repeats its bad status back.
  if #bad > 0 then
    for _, problem in ipairs(bad) do
      io.stderr:write("derive: " .. problem .. "\n")
    end
    os.exit(1)
  end
  local failed = false
  for _, job in ipairs({
      {INDEX, DECISIONS_HEAD, rendered},
      {AGENTS, MODULES_HEAD, modules_table()},
    }) do
    local changed, err = rewrite(job[1], job[2], job[3])
    if err then
      io.stderr:write("derive: " .. err .. "\n")
      failed = true
    else
      print(changed and ("derive: rewrote " .. job[1])
        or ("derive: " .. job[1] .. " already matches its source"))
    end
  end
  if failed then
    os.exit(1)
  end
end

return M
