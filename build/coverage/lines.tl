--- Which lines of a module's own source could ever be hit -- the
--- denominator a coverage percentage needs, over `build.ast`'s real
--- parse rather than a text scan that cannot tell a blank line, a
--- comment, or a bare `end` from a real statement.

local Sqlite = require("cosmic.sqlite")
local ast = require("build.ast")
local type compiler = require("build.compiler")

local type Node = ast.Node

local record lines
end

--- Statement kinds a "statements" node's array part can hold that this
--- module excludes from the executable count -- NOT because a
--- `local_type`/`global_type` statement always generates no Lua code,
--- but because tl's own codegen only sometimes elides it, and telling
--- the two cases apart needs information this module does not have.
---
--- The true rule, read from vendor/tl/tl.lua's `check_var_usage`
--- and its `local_type`/`global_type` codegen (the `elide_type` flag
--- codegen checks before emitting a line at all): a bare type-only
--- declaration whose name is never used as a real value anywhere else
--- in the module -- referenced only in type position, or not referenced
--- again at all -- is erased entirely, exactly a standalone `local
--- record Foo x: integer end` with nothing else naming `Foo`. But a
--- record or enum whose name IS used as a value elsewhere -- the
--- dominant idiom across this whole codebase, `local record Foo end`
--- with a `function Foo.bar() ... end` attached later in the same
--- module (cosmic/coverage.tl's own `Coverage` is one) -- generates a
--- real, always-executed initializer line (`local Foo = {}`) that a
--- correct executable-line count would include and that this
--- implementation still excludes, along with the rarer non-function
--- value uses (a plain assignment, a call argument, a field write)
--- that keep codegen from eliding it for the same reason.
---
--- `elide_type` is computed by tl's real type-checker, over the whole
--- module's variable-usage analysis (`has_been_read_from`/
--- `has_been_written_to`/`used_as_type`, tracked across every
--- statement, not only the declaration site) -- and `build.ast.parse`,
--- the only AST this module ever walks, only lexes and parses; it never
--- runs that checker, so the flag tl itself would set is simply absent
--- here. Recovering an equivalent signal from the bare parse tree alone
--- would mean re-deriving that same whole-module usage analysis by
--- hand -- scanning for every place the name is read, not only the
--- common dot-function-attachment pattern -- which is fragile in a way
--- that would make a false NEGATIVE (a name used through a shape this
--- scan does not recognize, wrongly still counted as elided) at least
--- as likely as the false positive documented above. Left as a known,
--- conservative gap: this only ever deflates a percentage, never
--- inflates one, until this module reads a fully checked AST instead of
--- a merely parsed one.
local not_executable: {string: boolean} = {
  ["local_type"] = true,
  ["global_type"] = true,
}

--- The set of executable line numbers in `source`: the starting line
--- of every statement-shaped node that is itself a direct element of
--- some "statements" node's own array part, anywhere in the parsed
--- tree -- every nested block inside a function, an `if`, or a loop
--- counts, not only the chunk's own top level -- excluding the type-only
--- kinds `not_executable` names. `ast.walk` already visits a
--- "statements" node's own array-part elements as ordinary nodes in
--- their own right, so this only has to notice the "statements" node
--- itself and read its array part directly: `Node` is declared
--- `is {Node}`, so every node already IS its own array view, empty for
--- anything that is not itself a "statements" node.
---
--- The line is `ast.span_start`'s, not the statement node's own `y`:
--- `build/ast/walk.tl`'s own doc comments warn that a compound node's
--- `y` sits wherever the parser FINISHED constructing it, which for a
--- statement whose own first token is a nested call or expression can
--- be well past the line the statement actually starts on; `span_start`
--- is the minimum position over the whole subtree, so it always lands
--- on the statement's own leftmost token instead.
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
          local y, _x = ast.span_start(stmt)
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

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- `lines.executable`'s answer for `source`, read back from `db`'s
--- `executable` table when a row for `source_hash` already stands
--- there, or computed and stored when it does not -- the cache
--- `build.work`'s schema comment documents next to `parsed`. A parse
--- failure is returned exactly as `lines.executable` returns it, and
--- nothing is written: only a successful parse is a function of the
--- hash alone worth keeping.
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
