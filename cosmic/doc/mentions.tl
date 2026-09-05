--- Find where the shipped guides and other modules' docs mention a
--- documented symbol. `cosmic --docs <symbol>` renders the symbol's own
--- doc comment; this module answers the different question of who else
--- talks about it, so a disagreement between a function's contract and
--- a guide's example costs one screen to notice instead of a grep
--- across `docs/guides/`.

local types = require("cosmic.doc.types")
local DocIndex = types.DocIndex
local sqlite = require("cosmic.sqlite")

local GUIDES_DIR = "/zip/docs/guides"
local INDEX_PATH = "/zip/.docs/index.lua"

local record MentionsModule
  --- One place the shipped docs mention a symbol.
  --- `source` is `guide.<topic>`, `<module>` (its module doc),
  --- `<module>.<function>` or `<module>.Example_<name>`.
  record Mention
    source: string
    heading: string
    line: integer
    text: string
  end
  mentions: function(full_name: string): {Mention}
  qualify: function(file: string, symbol: string, method?: string): string
  render: function(list: {Mention}): string
  -- Test hook: force the plain fallback path even when FTS5 is
  -- available, so both paths are exercised over a real query.
  _force_plain: boolean
end

local Mention = MentionsModule.Mention

-- Split `text` into its non-blank lines, one Mention-shaped row per
-- line, appended to `out`. Blank lines carry nothing a MATCH could ever
-- find, so they are not worth a row.
local function split_lines(text: string, source: string, heading: string, out: {Mention})
  if not text or text == "" then return end
  local lineno = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    if line:match("%S") then
      table.insert(out, {source = source, heading = heading, line = lineno, text = line})
    end
  end
end

-- A guide's `## ` sections, heading and body (fences included — a
-- recipe's code mentioning the symbol counts as a mention). Anything
-- before the first `## ` heading is not part of a section and is left
-- out; content under a deeper `### ` heading stays attached to its
-- enclosing `## ` section.
local function split_guide(path: string, topic: string, out: {Mention})
  local fs = require("cosmic.fs")
  local content = fs.read(path)
  if not content then return end
  local heading: string = nil
  local lineno = 0
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    local h = line:match("^##%s+(.+)$")
    if h then
      heading = h
    elseif heading and line:match("%S") then
      table.insert(out, {source = "guide." .. topic, heading = heading, line = lineno, text = line})
    end
  end
end

--- Guide filenames under docs/guides/, excluding the index.
local function guide_files(): {string}
  local fs = require("cosmic.fs")
  local dir = fs.open_dir(GUIDES_DIR)
  if not dir then return {} end
  local names: {string} = {}
  while true do
    local name = dir:read()
    if not name then break end
    if name ~= "index.md" and name:match("%.md$") then table.insert(names, name) end
  end
  dir:close()
  return names
end

-- The embedded documentation index, loaded independently of
-- cosmic.doc.query (which requires cosmic.doc.show, which requires
-- this module) to avoid a require cycle.
local function load_index(): DocIndex | nil
  local fs = require("cosmic.fs")
  local source = fs.read(INDEX_PATH)
  if not source then return nil end
  local chunk = load("return " .. source, "=docindex", "t", {})
  if not chunk then return nil end
  local ok, result = pcall(chunk)
  if not ok then return nil end
  if not (result is DocIndex) then return nil end
  return result
end

local function build_corpus(): {Mention}
  local out: {Mention} = {}
  for _, name in ipairs(guide_files()) do
    local topic = name:sub(1, #name - 3)
    split_guide(GUIDES_DIR .. "/" .. name, topic, out)
  end
  local index = load_index()
  if index then
    for mod_name, mod_doc in pairs(index.modules) do
      split_lines(mod_doc.module_doc, mod_name, "module doc", out)
      if mod_doc.functions then
        for _, func in ipairs(mod_doc.functions) do
          split_lines(func.description, mod_name .. "." .. func.name, func.name, out)
        end
      end
      if mod_doc.examples then
        for _, example in ipairs(mod_doc.examples) do
          split_lines(example.body, mod_name .. "." .. example.name,
            (example.name:gsub("^Example_?", "")), out)
        end
      end
    end
  end
  return out
end

local cached_corpus: {Mention} = nil
local function corpus(): {Mention}
  if not cached_corpus then cached_corpus = build_corpus() end
  return cached_corpus
end

--- Derive the fully-qualified symbol name from a module's `doc.file`
--- (its source path, which under this repo's layout is also its
--- require path) and the symbol matched within it. `method`, when
--- given, spells a record method as `Record:method`.
--- @param file string The module's ModuleDoc.file
--- @param symbol string The matched function, record, or example name
--- @param method string? A matched record method name
--- @return string The fully-qualified symbol name
local function qualify(file: string, symbol: string, method?: string): string
  local mod = file:gsub("%.tl$", ""):gsub("/", "."):gsub("%.init$", "")
  if method then return mod .. "." .. symbol .. ":" .. method end
  return mod .. "." .. symbol
end

-- Spellings to search for, most specific first: the full name
-- ("cosmic.fs.read"), the short name using its last module segment
-- ("fs.read"), and — for a record method — a bare ":method" spelling.
-- A method's natural short form ("db:query") uses the receiver's local
-- variable name, which is not recoverable from the record's type name
-- ("Database"), so only the colon-prefixed method name is searched;
-- unicode61's tokenchars merge "db:query" into one token, so this
-- spelling matches only a mention that writes the method with no
-- receiver at all — a known, accepted limit, not a bug.
local function spellings(full_name: string): {string}
  local list: {string} = {full_name}
  local method = full_name:match(":([^:]+)$")
  local base = method and full_name:match("^(.*):") or full_name
  local segs: {string} = {}
  for seg in base:gmatch("[^%.]+") do table.insert(segs, seg) end
  if #segs >= 2 then
    local short = segs[#segs - 1] .. "." .. segs[#segs]
    if method then short = short .. ":" .. method end
    if short ~= full_name then table.insert(list, short) end
  end
  if method then table.insert(list, ":" .. method) end
  return list
end

local function fts5_available(db: sqlite.Database): boolean
  local row = db:query_one("SELECT name FROM pragma_module_list WHERE name = 'fts5'")
  return row ~= nil
end

local function build_match(spellings_list: {string}): string
  local parts: {string} = {}
  for _, s in ipairs(spellings_list) do
    table.insert(parts, '"' .. (s:gsub('"', '""')) .. '"')
  end
  return table.concat(parts, " OR ")
end

-- Ranked path: an in-memory FTS5 table, rebuilt once per process from
-- `corpus()`. Returns nil (never an empty list) when FTS5 is not
-- registered or the table cannot be built, so the caller falls back to
-- the unranked plain-text path instead of reporting zero mentions.
local function query_fts(rows: {Mention}, spellings_list: {string}, exclude: string): {Mention} | nil
  local db = sqlite.open(":memory:")
  if not db then return nil end
  if not fts5_available(db) then local _ok, _err = db:close(); return nil end
  local created = db:exec(
    "CREATE VIRTUAL TABLE m USING fts5(source UNINDEXED, heading UNINDEXED, line UNINDEXED, "
    .. "text, tokenize = \"unicode61 tokenchars '._:'\")")
  if not created then local _ok, _err = db:close(); return nil end
  for _, r in ipairs(rows) do
    local _ok, _err = db:exec("INSERT INTO m (source, heading, line, text) VALUES (?, ?, ?, ?)",
      {r.source, r.heading, r.line, r.text})
  end
  local rs = db:query(
    "SELECT source, heading, line, snippet(m, 3, '', '', '...', 12) AS text FROM m "
    .. "WHERE m MATCH ? ORDER BY rank", {build_match(spellings_list)})
  if not rs then local _ok, _err = db:close(); return nil end
  local results: {Mention} = {}
  local seen: {string: boolean} = {}
  for row in rs do
    local source = tostring(row.source)
    local key = source .. "|" .. tostring(row.line)
    if source ~= exclude and not seen[key] then
      seen[key] = true
      table.insert(results, {source = source, heading = tostring(row.heading),
          line = math.floor(tonumber(row.line) or 0), text = tostring(row.text)})
    end
  end
  local _ok, _err = db:close()
  return results
end

-- A char that unicode61's tokenchars ('.', '_', ':') or the default
-- alnum set would fold into the same token as its neighbor.
local function is_token_char(c: string): boolean
  return c ~= "" and c:match("[%w_%.:]") ~= nil
end

-- Whole-token substring search, so "fs.read" does not also match
-- inside "fs.readlink" — the same distinction FTS5's exact-token MATCH
-- draws for free via tokenchars.
local function contains_token(text: string, needle: string): boolean
  local from = 1
  while true do
    local s, e = text:find(needle, from, true)
    if not s then return false end
    local before = s > 1 and text:sub(s - 1, s - 1) or ""
    local after = e < #text and text:sub(e + 1, e + 1) or ""
    if not is_token_char(before) and not is_token_char(after) then
      return true
    end
    from = e + 1
  end
end

-- Fallback path when FTS5 is unavailable: a plain substring scan over
-- the same corpus and spellings, in corpus order — unranked, but never
-- absent.
local function query_plain(rows: {Mention}, spellings_list: {string}, exclude: string): {Mention}
  local results: {Mention} = {}
  for _, r in ipairs(rows) do
    if r.source ~= exclude then
      for _, s in ipairs(spellings_list) do
        if contains_token(r.text, s) then
          table.insert(results, r)
          break
        end
      end
    end
  end
  return results
end

local M: MentionsModule

--- Find every place the shipped guides and module docs mention a
--- symbol, ranked by FTS5 when available. The symbol's own entry is
--- excluded — its doc is already shown alongside this list.
--- @param full_name string The fully-qualified symbol, e.g. "cosmic.fs.read"
--- @return {Mention} Mentions, ranked when FTS5 is available, else in corpus order
local function mentions(full_name: string): {Mention}
  local rows = corpus()
  local spellings_list = spellings(full_name)
  if not M._force_plain then
    local result = query_fts(rows, spellings_list, full_name)
    if result then return result end
  end
  return query_plain(rows, spellings_list, full_name)
end

--- Render a "Mentioned in:" section, or "" when `list` is empty.
--- Guide sources sort before module sources; at most 12 lines are
--- shown, with a "... and N more" tail for the rest.
--- @param list {Mention} Mentions to render
--- @return string The rendered section, or "" when there is nothing to show
local function render(list: {Mention}): string
  if #list == 0 then return "" end
  local sorted: {Mention} = {}
  for _, m in ipairs(list) do table.insert(sorted, m) end
  table.sort(sorted, function(a: Mention, b: Mention): boolean
      local ag, bg = a.source:sub(1, 6) == "guide.", b.source:sub(1, 6) == "guide."
      if ag ~= bg then return ag end
      if a.source ~= b.source then return a.source < b.source end
      return a.line < b.line
    end)
  local shown: {Mention} = {}
  for i, m in ipairs(sorted) do
    if i > 12 then break end
    table.insert(shown, m)
  end
  local label_w, line_w = 0, 0
  for _, m in ipairs(shown) do
    local label_len = #(m.source .. " § " .. m.heading)
    if label_len > label_w then label_w = label_len end
    local line_len = #("line " .. m.line)
    if line_len > line_w then line_w = line_len end
  end
  local lines: {string} = {"Mentioned in:"}
  for _, m in ipairs(shown) do
    local label = m.source .. " § " .. m.heading
    local line_str = "line " .. m.line
    table.insert(lines, "  " .. label .. string.rep(" ", label_w - #label + 2)
      .. line_str .. string.rep(" ", line_w - #line_str + 2) .. m.text)
  end
  if #sorted > 12 then
    table.insert(lines, "  ... and " .. (#sorted - 12) .. " more")
  end
  return table.concat(lines, "\n")
end

M = {
  mentions = mentions,
  qualify = qualify,
  render = render,
  _force_plain = false,
}

return M
