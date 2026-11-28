--- What `cosmic fix` reads off a Teal file it lays out ([`build.fix`]'s `read_off`), kept by the file's path and text, so
--- that a run over a tree whose files have not changed parses none of them again: what the file's links read
--- ([`SyntaxLinks.Settled`]), the functions the notes compare (`candidates`, for a file they compare) and the plurals the
--- tree checks look for. A row holds all three as [`build.check_memo`] encodes rows; one that does not decode is a miss.
---
--- What each comment line sees declared is held once for each distinct set of names, since many lines share one, and
--- each set holds only its own names: the names every comment sees (`everywhere`) are held once, and each set inherits
--- them again when it is read ([`SyntaxLinkText.seeing`]).
local LinkText = require("cosmic.internal.link_text")
local SyntaxLinkText = require("build.syntax_link_text")
local SyntaxLinks = require("build.syntax_links")
local check_memo = require("build.check_memo")
local type near = require("build.fix.near")
local type tree_checks = require("build.tree_checks")

local record ReadMemo
  --- What one file's read made.
  record Read
    settled: SyntaxLinks.Settled
    --- Nil for a file the notes do not compare.
    candidates?: {near.Candidate}
    --- Nil for a file with no plural sites.
    plurals?: tree_checks.Plurals
    --- What the file requires and, for a test file, its early returns, which the checks of the tree read
    --- ([`tree_checks.knows`]); nil where a read kept none.
    mut requires?: {string}
    mut returns?: {{string}}
  end

  --- The rows `read` is kept as.
  encode: function(read: Read): string

  --- The read `text` holds, for the file whose text is `source`; nil where it does not decode.
  decode: function(text: string, source: string): Read?

  --- The salt of a read in the tree at `root`: the sources of the code that reads a file and of this memo.
  salt: function(root: string): string
end

function ReadMemo.salt(root: string): string
  return check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "build/syntax_node.tl", "build/syntax_scopes.tl", "build/syntax_links.tl", "build/syntax_link_text.tl",
    "build/syntax_analyzer.tl", "build/todo_scan.tl", "build/markers.tl", "build/plural_sites.tl",
    "build/tree_checks/docs.tl", "build/tree_checks/init.tl", "build/tree_checks/common.tl", "build/fix/init.tl",
    "build/fix/near.tl", "build/fix/read_memo.tl", "build/check_memo.tl", "cosmic/internal/link_text.tl",
    "cosmic/string.tl", "build/test_returns.tl", "build/analysis_schema.tl" }, "read 3")
end

local function bit(value: boolean): string
  return if value then "1" else "0" end
end

function ReadMemo.encode(read: ReadMemo.Read): string
  local rows: mut {{string}} = { { "read 1" } }
  local settled = read.settled
  for _, block in ipairs(settled.blocks) do
    local starts: mut {string} = {}
    for _, start in ipairs(block.starts or {}) do starts[#starts + 1] = tostring(start) end
    rows[#rows + 1] = { "block", tostring(block.line), block.text, bit(block.starts ~= nil), table.concat(starts, ",") }
  end
  for name in pairs(settled.module_level) do rows[#rows + 1] = { "top", name } end
  for name in pairs(settled.everywhere) do rows[#rows + 1] = { "every", name } end
  -- Each distinct set once, by the order it is first met on the lines in order.
  local ids: mut {LinkText.Declared: integer} = {}
  local made = 0
  local lines: mut {integer} = {}
  for line in pairs(settled.lines) do lines[#lines + 1] = line end
  table.sort(lines)
  for _, line in ipairs(lines) do
    local declared = assert(settled.lines[line])
    local id = ids[declared]
    if id == nil then
      made = made + 1
      id = made
      ids[declared] = id
      local own: mut {string} = {}
      for name in pairs(declared.names) do own[#own + 1] = name end
      table.sort(own)
      local row: mut {string} = { "set", tostring(id) }
      for _, name in ipairs(own) do row[#row + 1] = name end
      rows[#rows + 1] = row
      for name, module in pairs(declared.aliases) do
        rows[#rows + 1] = { "alias", tostring(id), name, module }
      end
    end
    rows[#rows + 1] = { "line", tostring(line), tostring(id) }
  end
  local candidates = read.candidates
  if candidates ~= nil then
    rows[#rows + 1] = { "compared" }
    for _, c in ipairs(candidates) do
      rows[#rows + 1] = { "candidate", c.source_symbol, c.text, tostring(c.line), bit(c.method == true) }
    end
  end
  local plurals = read.plurals
  if plurals ~= nil then
    rows[#rows + 1] = { "plurals" }
    for _, site in ipairs(plurals.sites) do
      local row: mut {string} = { "site" }
      for _, part in ipairs(site) do row[#row + 1] = part end
      rows[#rows + 1] = row
    end
  end
  local requires = read.requires
  if requires ~= nil then
    local row: mut {string} = { "requires" }
    for _, name in ipairs(requires) do row[#row + 1] = name end
    rows[#rows + 1] = row
  end
  local returns = read.returns
  if returns ~= nil then
    rows[#rows + 1] = { "returns" }
    for _, one in ipairs(returns) do
      local row: mut {string} = { "return" }
      for _, part in ipairs(one) do row[#row + 1] = part end
      rows[#rows + 1] = row
    end
  end
  return check_memo.encode(rows)
end

function ReadMemo.decode(text: string, source: string): ReadMemo.Read?
  local rows = check_memo.decode(text)
  local head = rows[1]
  if head == nil or head[1] ~= "read 1" then return nil end
  local blocks: mut {LinkText.Block} = {}
  local module_level: mut {string: boolean} = {}
  local everywhere: mut {string: boolean} = {}
  local sets: mut {integer: LinkText.Declared} = {}
  local lines: mut {integer: LinkText.Declared} = {}
  local candidates: mut {near.Candidate}? = nil
  local sites: mut {{string}}? = nil
  local requires: mut {string}? = nil
  local returns: mut {{string}}? = nil
  for i = 2, #rows do
    local row = assert(rows[i])
    local kind = row[1]
    if kind == "block" then
      local line = math.tointeger(tonumber(row[2] or ""))
      if line == nil then return nil end
      local starts: mut {integer}? = nil
      if row[4] == "1" then
        local held: mut {integer} = {}
        for part in (row[5] or ""):gmatch("[^,]+") do
          local start = math.tointeger(tonumber(part))
          if start == nil then return nil end
          held[#held + 1] = start
        end
        starts = held
      end
      blocks[#blocks + 1] = { line = line, text = row[3] or "", starts = starts }
    elseif kind == "top" then
      module_level[row[2] or ""] = true
    elseif kind == "every" then
      everywhere[row[2] or ""] = true
    elseif kind == "set" then
      local id = math.tointeger(tonumber(row[2] or ""))
      if id == nil then return nil end
      local names = SyntaxLinkText.seeing(everywhere)
      for j = 3, #row do names[row[j]] = true end
      sets[id] = { names = names, aliases = {} }
    elseif kind == "alias" then
      local set = sets[math.tointeger(tonumber(row[2] or "")) or 0]
      if set == nil then return nil end
      set.aliases[row[3] or ""] = row[4] or ""
    elseif kind == "line" then
      local line = math.tointeger(tonumber(row[2] or ""))
      local set = sets[math.tointeger(tonumber(row[3] or "")) or 0]
      if line == nil or set == nil then return nil end
      lines[line] = set
    elseif kind == "compared" then
      candidates = {}
    elseif kind == "candidate" then
      local line = math.tointeger(tonumber(row[4] or ""))
      if candidates == nil or line == nil then return nil end
      candidates[#candidates + 1] = { source_symbol = row[2] or "", text = row[3] or "", line = line,
        method = if row[5] == "1" then true else nil end }
    elseif kind == "plurals" then
      sites = {}
    elseif kind == "site" then
      if sites == nil then return nil end
      local site: mut {string} = {}
      for j = 2, #row do site[#site + 1] = row[j] end
      sites[#sites + 1] = site
    elseif kind == "requires" then
      local names: mut {string} = {}
      for j = 2, #row do names[#names + 1] = row[j] end
      requires = names
    elseif kind == "returns" then
      returns = {}
    elseif kind == "return" then
      if returns == nil then return nil end
      local one: mut {string} = {}
      for j = 2, #row do one[#one + 1] = row[j] end
      returns[#returns + 1] = one
    else
      return nil
    end
  end
  local plurals: tree_checks.Plurals? = nil
  if sites ~= nil then plurals = { source = source, sites = sites } end
  return {
    settled = { blocks = blocks, lines = lines, module_level = module_level, everywhere = everywhere },
    candidates = candidates, plurals = plurals, requires = requires, returns = returns,
  }
end

return ReadMemo
