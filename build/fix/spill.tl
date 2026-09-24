--- The one fix that needs the type checker: parenthesizing an
--- `assert(...)` whose extra values land where they should not.
---
--- Lua's `assert` returns every value it was given, and the checker
--- says so (`patch/tl/15-assert-returns-every-value.txt`). So at the end
--- of an argument list, a table constructor, or a return,
--- `f(assert(g()))` hands `g`'s error slot on to `f` as a second
--- argument, and the checker refuses it when `f` has no room for that
--- value or the wrong type for it. It then also reports, at the very
--- `assert(` it means, `spill.message`. Wrapping that call in
--- parentheses keeps only its first value, which is what such code
--- always meant.
---
--- The structural rules in `build.fix.rule` cannot make this fix: a
--- pattern cannot tell `f(assert(g()))` where `f` takes one value from
--- one where it takes both, and parenthesizing the second would drop a
--- value on purpose passed. So this stage asks the checker instead: it
--- builds the tree, reads the positions the checker names, wraps exactly
--- those calls, and builds again until the checker names none.

local Store = require("cosmic.store")
local ast = require("build.ast")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local type compiler = require("build.compiler")

local record spill
  --- What the checker reports at an `assert(` whose extra values it
  --- refused. The compiler patch spells the same words.
  message: string

  --- The positions the checker names, by file: each an `assert` call's
  --- own `(`, as "line:column".
  type Sites = {string:{string:boolean}}
end

spill.message = "assert(...) passes on every value it was given, not only " ..
  "the first; write (assert(...)) to keep only the first"

--- The sites a build's refusal names, read off its diagnostics: every
--- `<file>:<line>:<column>: <spill.message>` line.
function spill.sites(text: string): spill.Sites
  local found: spill.Sites = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local file, y, x, rest = line:match("^(.-):(%d+):(%d+): (.*)$")
    if file ~= nil and rest:sub(1, #spill.message) == spill.message then
      local at = found[file]
      if at == nil then
        at = {}
        found[file] = at
      end
      at[y .. ":" .. x] = true
    end
  end
  return found
end

local pattern_source <const> = "assert($$$ARGS)"
local replacement <const> = "(assert($$$ARGS))"

--- `source` with every `assert(...)` call whose own `(` sits at one of
--- `at`'s positions wrapped in parentheses.
function spill.wrap(built: compiler, source: string, name: string,
                    at: {string:boolean}): string | nil, string
  local pattern, why = ast.compile_pattern(built, pattern_source)
  if pattern == nil then
    return nil, why
  end
  local result, trouble = ast.rewrite(built, source, name, pattern, replacement,
    function(node: ast.Node): boolean
      return at[node.y .. ":" .. node.x] == true
    end)
  if result == nil then
    return nil, trouble
  end
  if #result.refused > 0 then
    return nil, "wrapping an assert would drop a comment: " ..
      table.concat(result.refused[1].comments, " ")
  end
  return result.code, ""
end

--- Builds the tree at `root` and returns the sites its refusal names,
--- none when it builds or when what stops it is something else. A
--- tree that cannot be built at all answers none, and says why.
function spill.check(root: string): spill.Sites, string
  local own_tree, own_trouble = importer.is_own_tree(root)
  if own_tree == nil then return {}, own_trouble end
  local handle, open_trouble = work.open(root)
  if handle == nil then return {}, open_trouble end
  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    local _, _ = work.close(handle)
    return {}, stage_trouble
  end
  local built = teal.lazy()
  local result, compile_trouble = importer.compile(handle, built,
    Store.meta("compiler") or "")
  local closed, close_trouble = work.close(handle)
  if not closed then return {}, close_trouble end
  if result ~= nil then
    return spill.sites(table.concat(result.refused, "\n")), ""
  end
  return spill.sites(compile_trouble), ""
end

return spill
