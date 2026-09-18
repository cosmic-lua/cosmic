--- Which lines of a module's own source could ever be hit -- the
--- denominator a coverage percentage needs, over `build.ast`'s real
--- parse rather than a text scan that cannot tell a blank line, a
--- comment, or a bare `end` from a real statement.

local ast = require("build.ast")
local type compiler = require("build.compiler")

local type Node = ast.Node

local record lines
end

--- Statement kinds a "statements" node's array part can hold that
--- generate no Lua code at all: a standalone `record`/`type` statement
--- (`local_type`, `global_type`) is erased entirely at compile time --
--- vendor/tl/tl.tl's own codegen comment at the site that discards a
--- `local_type` node says so outright. A phantom line like this can
--- never be hit no matter how thoroughly a suite exercises the module,
--- so counting it as executable would only ever deflate a percentage,
--- never reflect one.
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
          out[y] = true
        end
      end
    end
  end)
  return out, ""
end

return lines
