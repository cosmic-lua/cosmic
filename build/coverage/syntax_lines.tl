--- Which lines of a module's own source could ever be hit: the denominator of a coverage percentage. It reads the
--- syntax tree, which tells a statement from a blank line, a comment or a bare `end`, where a scan of the text cannot.
local Ast = require("lang.ast")
local Node = require("build.syntax_node")
local Sqlite = require("cosmic.sqlite")
local bind = require("build.bind")

local record Lines
  --- The set of executable lines of `source`, a file named `name`: the line each statement of a block starts on, at
  --- any depth (a block inside a function, an `if` or a loop counts, not only the chunk's own), except a type
  --- declaration, which emits Lua only when its name is used as a value, and the tree does not say that. nil and why
  --- where the source does not parse.
  --
  -- TODO: count a record, enum or alias statement whose name is used as a value, once this reads the checker's type
  -- report and not the tree alone: the percentage is deflated until then, never inflated.
  executable: function(source: string, name: string): {integer: boolean} | nil, string

  --- [`Lines.executable`]'s answer for `source`, read from the `executable` table of `db` (the cache [`build.work`]'s
  --- schema documents next to `parsed`) when it has a row for `source_hash`, else computed and stored. A parse failure
  --- is returned as [`Lines.executable`] returns it and nothing is written: only a parse is a function of the hash.
  executable_cached: function(db: Sqlite.Handle, source_hash: string, source: string,
                              name: string): {integer: boolean} | nil, string
end

local text = bind.text

--- The key of a row in the `executable` table: the reader's name before the hash, so that the rows the fork's reader
--- keeps for the same source, which count a label's line, are not read as these.
--
-- TODO: drop the prefix when the table's rows are these alone, at the switch (doc/plans/strict-teal.md, "the switch").
local function keyed(source_hash: string): string
  return "syntax:" .. source_hash
end

--- The kinds of statement that declare a type.
local function declares_type(stat: Ast.Stat): boolean
  return Node.declared(stat) ~= nil
end

function Lines.executable(source: string, name: string): {integer: boolean} | nil, string
  local chunk, why = Node.parse(source, name)
  if chunk == nil then
    return nil, why
  end
  local out: {integer: boolean} = {}
  Node.walk(chunk, function(node: Ast.Node)
    if node is Ast.Block then
      for _, stat in ipairs(node.stats) do
        if not declares_type(stat) then
          local base = Node.base(stat)
          local y = chunk.tokens[base.first].y
          -- Lua attributes a closure to the line its body ends on, and a `local function` is nothing but that closure:
          -- its own first line never runs. (`function M.f` is pinned to its first line by the assignment Lua fixes
          -- there.)
          if stat is Ast.LocalFunction then
            y = chunk.tokens[base.last].yend
          end
          out[y] = true
        end
      end
    end
  end)
  return out, ""
end

function Lines.executable_cached(db: Sqlite.Handle, source_hash: string, source: string,
                                 name: string): {integer: boolean} | nil, string
  local cached, select_trouble = Sqlite.text_rows(db,
    "SELECT lines FROM executable WHERE source_hash = ?1", { text(keyed(source_hash)) })
  if cached == nil then
    return nil, select_trouble
  end
  if #cached > 0 then
    local out: {integer: boolean} = {}
    for piece in cached[1]:text(1):gmatch("%d+") do
      local line = math.tointeger(tonumber(piece))
      if line ~= nil then out[line] = true end
    end
    return out, ""
  end
  local executable, trouble = Lines.executable(source, name)
  if executable == nil then
    return nil, trouble
  end
  local numbers: {integer} = {}
  for line in pairs(executable) do
    numbers[#numbers + 1] = line
  end
  table.sort(numbers)
  local joined: {string} = {}
  for i, line in ipairs(numbers) do
    joined[i] = tostring(line)
  end
  local inserted, insert_trouble = Sqlite.run(db,
    "INSERT OR IGNORE INTO executable (source_hash, lines) VALUES (?1, ?2)",
    { text(keyed(source_hash)), text(table.concat(joined, " ")) })
  if not inserted then
    return nil, insert_trouble
  end
  return executable, ""
end

return Lines
