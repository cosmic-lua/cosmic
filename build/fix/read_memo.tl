--- What a run of `cosmic fix` takes from the parse of a Teal file, kept so that a file left as it was is not parsed again to
--- be read: what its links read of it ([`build.links`]'s `facts`), the candidates the notes compare ([`build.fix.near`]) and
--- the plurals the tree checks look for ([`build.tree_checks`]'s `plurals_in`).
---
--- Each is a function of the file's text, so it is kept as text in the check memo ([`build.check_memo`]) under the text, the
--- file's name and the code that makes it ([`build.fix.laid`]'s `code_salt`: the compiler's bytecode and that of every module
--- the readers load). What a file's links read of what it declares is a function of a line ([`link_text`]'s `declarations`),
--- which is kept for the line of every comment of the file, by the place it stands at; a line asked for that is none of them
--- is answered by parsing the file then, and reading it as the parse would have.
local Sqlite = require("cosmic.sqlite")
local ast = require("build.ast")
local check_memo = require("build.check_memo")
local laid = require("build.fix.laid")
local link_text = require("build.link_text")
local links = require("build.links")
local near = require("build.fix.near")
local tree_checks = require("build.tree_checks")
local type compiler = require("build.compiler")

local record read_memo
  --- What a parse of one file gives the phases after the layout.
  record Read
    facts: links.Facts
    --- What the notes compare: nil for a file they do not read.
    ready: {near.Candidate} | nil
    --- What the tree checks look for: nil for a file they do not read.
    plurals: tree_checks.Plurals | nil
  end

  --- The modules whose bytecode, with everything they load, and those whose bytecode alone, name the code that reads a parse
  --- ([`build/fix/read_memo_test.tl`] holds them to what the readers call).
  roots: {string}
  alone: {string}
  --- The salt of the code that reads a parse, or nil where it cannot be named.
  salt: function(): string | nil
  --- What the memo `db` keeps under `salt` of the file `name` whose text is `source`, or nil where it keeps none or it does not
  --- read. `built` parses the file where a line is asked for that the text does not hold.
  get: function(db: Sqlite.Handle, salt: string, built: compiler, name: string, source: string): Read | nil
  --- Keeps `read`, made of `parsed`, the parse of `source`.
  put: function(db: Sqlite.Handle, salt: string, name: string, source: string, read: Read, parsed: ast.Parsed)
end

local KIND <const> = "laid"

read_memo.roots = { "build.link_text", "build.analyzer", "build.scopes", "build.ast", "build.symbols", "build.plural_sites" }
read_memo.alone = { "build.links", "build.fix", "build.tree_checks", "build.fix.read_memo", "build.fix.near" }

function read_memo.salt(): string | nil
  -- What the readers run: what a link says of a file, the docs of its functions, the scopes, the parse and the sites of its
  -- plurals ([`tree_checks.plurals_in`] calls [`build.plural_sites`]), with everything they load; and the modules that hold
  -- [`links.facts`], `read_off`, `candidates_of`, `plurals_in` and this one, themselves alone (what they load beyond those is
  -- what they call elsewhere).
  return laid.code_salt("read 2", read_memo.roots, read_memo.alone)
end

--- The line of every comment of a parse, in order and once.
local function comment_lines(parsed: ast.Parsed): {integer}
  local out: {integer} = {}
  local seen: {integer: boolean} = {}
  for _, token in ipairs(parsed.tokens) do
    for _, comment in ipairs(token.comments or {}) do
      if seen[comment.y] == nil then
        seen[comment.y] = true
        out[#out + 1] = comment.y
      end
    end
  end
  return out
end

local function encode(read: read_memo.Read, parsed: ast.Parsed): string
  local rows: {{string}} = { { "V", "1" } }
  for _, block in ipairs(read.facts.blocks) do
    local starts = "-"
    local held = block.starts
    if held ~= nil then
      local numbers: {string} = {}
      for _, at in ipairs(held) do
        numbers[#numbers + 1] = tostring(at)
      end
      starts = "+" .. table.concat(numbers, ",")
    end
    rows[#rows + 1] = { "B", tostring(block.line), block.text, starts }
  end
  for name in pairs(read.facts.known.module_level) do
    rows[#rows + 1] = { "M", name }
  end
  -- What each comment's line sees: the names every line sees once, then each distinct place's own names and aliases.
  local ids: {link_text.Declared: integer} = {}
  local count = 0
  local shared = false
  for _, line in ipairs(comment_lines(parsed)) do
    local declared = read.facts.known.at(line)
    local id = ids[declared]
    if id == nil then
      count = count + 1
      id = count
      ids[declared] = id
      if not shared then
        shared = true
        -- Filled by the first line asked for.
        for name in pairs(read.facts.known.everywhere or {}) do
          rows[#rows + 1] = { "G", name }
        end
      end
      for name in pairs(declared.names) do
        rows[#rows + 1] = { "n", tostring(id), name }
      end
      for name, module in pairs(declared.aliases) do
        rows[#rows + 1] = { "a", tostring(id), name, module }
      end
      rows[#rows + 1] = { "P", tostring(id) }
    end
    rows[#rows + 1] = { "L", tostring(line), tostring(id) }
  end
  local noted = read.ready
  if noted ~= nil then
    rows[#rows + 1] = { "k" }
    for _, c in ipairs(noted) do
      rows[#rows + 1] = { "K", c.source_symbol, c.text, tostring(c.line), c.method == true and "1" or "0" }
    end
  end
  local found = read.plurals
  if found ~= nil then
    rows[#rows + 1] = { "s" }
    for _, site in ipairs(found.sites) do
      rows[#rows + 1] = { "S", site[1] or "", site[2] or "", site[3] or "", site[4] or "" }
    end
  end
  return check_memo.encode(rows)
end

local function decode(text: string, built: compiler, name: string, source: string): read_memo.Read | nil
  local blocks: {link_text.Block} = {}
  local module_level: {string: boolean} = {}
  local everywhere: {string: boolean} = {}
  local own: {integer: {string: boolean}} = {}
  local aliases: {integer: {string: string}} = {}
  local at_line: {integer: integer} = {}
  local candidates: {near.Candidate} | nil = nil
  local sites: {{string}} | nil = nil
  local versioned = false
  for _, f in ipairs(check_memo.decode(text)) do
    local kind = f[1]
    if kind == "V" then
      versioned = f[2] == "1"
    elseif kind == "B" and #f == 4 then
      local line = math.tointeger(tonumber(f[2] or ""))
      local marker = (f[4] or ""):sub(1, 1)
      if line == nil or (marker ~= "-" and marker ~= "+") then return nil end
      local starts: {integer} | nil = nil
      if marker == "+" then
        starts = {}
        for number in ((f[4] or ""):sub(2)):gmatch("[^,]+") do
          local at = math.tointeger(tonumber(number))
          if at == nil then return nil end
          starts[#starts + 1] = at
        end
      end
      blocks[#blocks + 1] = { line = line, text = f[3] or "", starts = starts }
    elseif kind == "M" and #f == 2 then
      module_level[f[2] or ""] = true
    elseif kind == "G" and #f == 2 then
      everywhere[f[2] or ""] = true
    elseif kind == "n" and #f == 3 then
      local id = math.tointeger(tonumber(f[2] or ""))
      if id == nil then return nil end
      own[id] = own[id] or {}
      local names = own[id]
      if names ~= nil then names[f[3] or ""] = true end
    elseif kind == "a" and #f == 4 then
      local id = math.tointeger(tonumber(f[2] or ""))
      if id == nil then return nil end
      aliases[id] = aliases[id] or {}
      local map = aliases[id]
      if map ~= nil then map[f[3] or ""] = f[4] or "" end
    elseif kind == "P" and #f == 2 then
      local id = math.tointeger(tonumber(f[2] or ""))
      if id == nil then return nil end
      own[id] = own[id] or {}
      aliases[id] = aliases[id] or {}
    elseif kind == "L" and #f == 3 then
      local line, id = math.tointeger(tonumber(f[2] or "")), math.tointeger(tonumber(f[3] or ""))
      if line == nil or id == nil then return nil end
      at_line[line] = id
    elseif kind == "k" then
      candidates = candidates or {}
    elseif kind == "K" and #f == 5 and candidates ~= nil then
      local line = math.tointeger(tonumber(f[4] or ""))
      if line == nil then return nil end
      local method: boolean | nil = nil
      if f[5] == "1" then
        method = true
      end
      candidates[#candidates + 1] = { source_symbol = f[2] or "", text = f[3] or "", line = line, method = method }
    elseif kind == "s" then
      sites = sites or {}
    elseif kind == "S" and #f == 5 and sites ~= nil then
      sites[#sites + 1] = { f[2] or "", f[3] or "", f[4] or "", f[5] or "" }
    else
      return nil
    end
  end
  if not versioned then
    return nil
  end
  local places: {integer: link_text.Declared} = {}
  local inherit: metatable<{string: boolean}> = { __index = everywhere }
  for id, names in pairs(own) do
    places[id] = { names = setmetatable(names, inherit), aliases = aliases[id] or {} }
  end
  -- A line that is no comment's is read off a parse made then, which is what the parse made now would have said.
  local fallback: {link_text.Declarations} = {}
  local function at(line: integer): link_text.Declared
    local id = at_line[line]
    if id ~= nil then
      local place = places[id]
      if place ~= nil then
        return place
      end
    end
    local settled = fallback[1]
    if settled == nil then
      local parsed, _ = ast.parse(built, source, name)
      settled = link_text.declarations(assert(parsed), true)
      fallback[1] = settled
    end
    return settled.at(line)
  end
  local plurals: tree_checks.Plurals | nil = nil
  if sites ~= nil then
    plurals = { source = source, sites = sites }
  end
  return {
    facts = { source = source, blocks = blocks,
      known = { at = at, module_level = module_level, parsed = true, everywhere = everywhere } },
    ready = candidates, plurals = plurals,
  }
end

function read_memo.get(db: Sqlite.Handle, salt: string, built: compiler, name: string, source: string): read_memo.Read | nil
  local text = check_memo.get(db, KIND, check_memo.key(salt, "read " .. name, source))
  if text == nil then
    return nil
  end
  return decode(text, built, name, source)
end

function read_memo.put(db: Sqlite.Handle, salt: string, name: string, source: string, read: read_memo.Read,
                       parsed: ast.Parsed)
  check_memo.put(db, KIND, check_memo.key(salt, "read " .. name, source), encode(read, parsed))
end

return read_memo
