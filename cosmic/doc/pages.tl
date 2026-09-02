--- The prose pages `--docs` serves: four kinds, each a directory the
--- binary ships, addressed as `<kind>.<topic>`.
---
--- A page is `docs/<kind>/<topic>.md` and is addressed as
--- `<kind>.<topic>`; the directory is the whole declaration. This is
--- the shard behind `cosmic.doc.query`'s page lookups and `--help`'s
--- page listing.

local fs = require("cosmic.fs")

local DOCS_DIR < const > = "/zip/docs"

--- The four kinds of prose page, in the order a newcomer meets them.
--- A page is `docs/<kind>/<topic>.md` and is addressed as
--- `<kind>.<topic>`; the directory is the whole declaration.
local KINDS < const >: {string} = {"tutorial", "howto", "reference", "explanation"}

--- What each kind is for, one line, shown at the top of its listing.
local KIND_BLURB < const >: {string: string} = {
  tutorial = "lessons: follow one from start to finish and end with something that works",
  howto = "steps for one task, for a reader who knows the basics",
  reference = "the facts: every rule, verb, table and shape, and nothing else",
  explanation = "why things are the way they are",
}

--- The heading a kind's listing prints, and `--help` uses.
local KIND_TITLE < const >: {string: string} = {
  tutorial = "tutorials",
  howto = "how-to guides",
  reference = "reference",
  explanation = "explanation",
}

--- Whether a query names one of the four kinds.
local function is_kind(name: string): boolean
  return KIND_BLURB[name] ~= nil
end

--- The heading for one kind.
local function kind_title(kind: string): string
  return KIND_TITLE[kind] or kind
end

--- The topics one kind holds, from the embedded directory.
--- @param kind string One of `KINDS`
--- @return {string} Sorted topic names (file stems)
local function page_topics(kind: string): {string}
  local dir = fs.open_dir(DOCS_DIR .. "/" .. kind)
  if not dir then return {} end
  local topics: {string} = {}
  while true do
    local name = dir:read()
    if not name then break end
    if string.match(name, "%.md$") then
      topics[#topics + 1] = string.sub(name, 1, #name - 3)
    end
  end
  dir:close()
  table.sort(topics)
  return topics
end

--- One kind's pages with the title each file's H1 gives it.
--- @param kind string One of `KINDS`
--- @return {{string, string}} Pairs of topic and title
local function pages(kind: string): {{string, string}}
  local out: {{string, string}} = {}
  for _, name in ipairs(page_topics(kind)) do
    local content = fs.read(DOCS_DIR .. "/" .. kind .. "/" .. name .. ".md")
    local desc = name
    if content then
      local heading = string.match(content, "^#%s+(.-)%s*\n")
      if heading then desc = heading end
    end
    table.insert(out, {name, desc})
  end
  return out
end

--- One kind's listing, as `--docs <kind>` prints it.
local function render_kind(kind: string): string
  local listed = pages(kind)
  local max_len = 0
  for _, p in ipairs(listed) do
    if #p[1] > max_len then max_len = #p[1] end
  end
  local lines: {string} = {"# " .. kind_title(kind), "", KIND_BLURB[kind] .. ".", ""}
  for _, p in ipairs(listed) do
    lines[#lines + 1] = "  " .. p[1] .. string.rep(" ", max_len - #p[1] + 2) .. p[2]
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Use 'cosmic --docs " .. kind .. ".<name>' to read one."
  return table.concat(lines, "\n")
end

--- Show one page, or list a kind when the topic is empty.
--- @param kind string One of `KINDS`
--- @param topic string The page, or "" for the listing
--- @return string | nil The markdown, or nil when there is no such page
--- @return string Why, naming the pages that do exist
local function page(kind: string, topic: string): string | nil, string
  if topic == "" then
    return render_kind(kind)
  end
  local topics = page_topics(kind)
  local valid = false
  for _, t in ipairs(topics) do
    if t == topic then valid = true; break end
  end
  if not valid then
    local lines: {string} = {"error: unknown " .. kind .. " '" .. topic .. "'", ""}
    table.insert(lines, "Available " .. kind_title(kind) .. ":")
    for _, t in ipairs(topics) do
      table.insert(lines, "  " .. t)
    end
    return nil, table.concat(lines, "\n")
  end
  local path = DOCS_DIR .. "/" .. kind .. "/" .. topic .. ".md"
  local content, err = fs.read(path)
  if not content then
    return nil, "error: " .. (err or "failed to load " .. path)
  end
  return content
end

local record PagesModule
  KINDS: {string}
  is_kind: function(name: string): boolean
  kind_title: function(kind: string): string
  page: function(kind: string, topic: string): string | nil, string
  pages: function(kind: string): {{string, string}}
end

local M: PagesModule = {
  KINDS = KINDS,
  is_kind = is_kind,
  kind_title = kind_title,
  page = page,
  pages = pages,
}

return M
