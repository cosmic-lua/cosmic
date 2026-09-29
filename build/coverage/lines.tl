--- Which lines of a module's own source could ever be hit: the
--- denominator of a coverage percentage. It reads `build.ast`'s parse
--- rather than scanning text, which cannot tell a blank line, a comment
--- or a bare `end` from a statement.

local Sqlite = require("cosmic.sqlite")
local ast = require("build.ast")
local type compiler = require("build.compiler")
local bind = require("build.bind")

local type Node = ast.Node

local record lines
end

--- Statement kinds a "statements" node's array part can hold that are
--- left out of the executable count. Teal emits no Lua for a bare
--- type-only declaration whose name is never used as a value (it sets
--- `elide_type`, in `check_var_usage` of vendor/tl/tl.lua), but emits an
--- initializer line (`local Foo = {}`) for a record or enum whose name is
--- used as a value elsewhere, such as `local record Foo end` with a
--- `function Foo.bar()` attached later. Whether a name is used as a value
--- takes tl's whole-module usage analysis, which `build.ast.parse` (it
--- only lexes and parses) does not run, and rederiving it here would risk
--- counting a line that is elided. So every such statement is excluded,
--- and a percentage is deflated, never inflated.
-- TODO: count a `local_type` or `global_type` statement whose name is
-- used as a value, once this module reads a type-checked AST rather than
-- a parsed one.
local not_executable: {string: boolean} = {
  ["local_type"] = true,
  ["global_type"] = true,
}

--- The set of executable line numbers in `source`: the starting line of
--- every statement that is a direct element of a "statements" node, at
--- any depth (a block inside a function, an `if` or a loop counts, not
--- only the chunk's top level), except the kinds `not_executable` names.
--- `ast.walk` visits those elements as nodes in their own right, so this
--- only notices the "statements" node itself and reads its array part:
--- `Node` is declared `is {Node}`, so every node is its own array view,
--- empty for a node that is not a "statements" node.
---
--- The line is `ast.span_start`'s, not the statement's own `y`: a
--- compound node's `y` sits where the parser finished building it
--- (`build/ast/walk.tl`), which for a statement that begins with a nested
--- call or expression can be well past its first line. `span_start` is
--- the minimum position over the subtree, so it lands on the statement's
--- leftmost token.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @param source string The module's own Teal source
--- @param name string Filename for parse diagnostics
--- @return {integer: boolean} | nil Every executable line, or nil on a parse failure
--- @return string Error message on failure
function lines.executable(built: compiler, source: string,
                          name: string): {integer: boolean} | nil, string
  local parsed, trouble = ast.parse(built, source, name)
  if parsed == nil then
    return nil, trouble
  end
  local out: {integer: boolean} = {}
  ast.walk(parsed.node, function(n: Node)
    if n.kind == "statements" then
      for _, stmt in ipairs(n) do
        if not not_executable[stmt.kind] then
          local y = ast.span_start(stmt).y
          -- Lua attributes a closure to the line its body ends on, and
          -- a `local function` statement is nothing but that closure:
          -- its own first line never runs. (`function M.f` is pinned
          -- to its first line by the assignment Lua fixes there.)
          local yend = stmt.yend
          if stmt.kind == "local_function" and yend is integer then
            y = yend
          end
          out[y] = true
        end
      end
    end
  end)
  return out, ""
end

local text = bind.text

--- `lines.executable`'s answer for `source`: read from `db`'s
--- `executable` table (the cache `build.work`'s schema documents next to
--- `parsed`) when it has a row for `source_hash`, else computed and
--- stored. A parse failure is returned as `lines.executable` returns it
--- and nothing is written: only a successful parse is a function of the
--- hash alone.
--- @param db Sqlite.Handle The working database (`work.open`'s `.db`)
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @param source_hash string The module source's content hash, `executable`'s key
--- @param source string The module's own Teal source
--- @param name string Filename for parse diagnostics
--- @return {integer: boolean} | nil Every executable line, or nil on a parse failure
--- @return string Error message on failure
function lines.executable_cached(db: Sqlite.Handle, built: compiler,
                                 source_hash: string, source: string,
                                 name: string): {integer: boolean} | nil, string
  local cached, select_trouble = Sqlite.text_rows(db,
    "SELECT lines FROM executable WHERE source_hash = ?1", { text(source_hash) })
  if cached == nil then
    return nil, select_trouble
  end
  if #cached > 0 then
    local out: {integer: boolean} = {}
    for piece in cached[1][1]:gmatch("%d+") do
      local line = math.tointeger(tonumber(piece))
      if line ~= nil then out[line] = true end
    end
    return out, ""
  end

  local executable, trouble = lines.executable(built, source, name)
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
    { text(source_hash), text(table.concat(joined, " ")) })
  if not inserted then
    return nil, insert_trouble
  end
  return executable, ""
end

return lines
