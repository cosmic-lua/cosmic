--- The one fix that needs the type checker: parenthesizing an
--- `assert(...)` whose extra values land where they should not.
---
--- Lua's `assert` returns every value it was given, and the checker
--- says so ([`patch/tl/15-assert-returns-every-value.txt`]). So at the end
--- of an argument list, a table constructor or a return,
--- `f(assert(g()))` passes `g`'s error slot on to `f` as a second
--- argument. The checker refuses that when `f` has no room for the
--- value or a different type for it, and reports [`spill.message`] at the
--- `assert(` concerned. Wrapping the call in parentheses keeps only its
--- first value, which is what such code always meant.
---
--- The structural rules in [`build.fix.rule`] cannot make this fix: a
--- pattern cannot tell `f(assert(g()))` where `f` takes one value from
--- one where it takes both, and parenthesizing the second would drop a
--- value passed on purpose. So this stage asks the checker: it builds
--- the tree, reads the positions the checker names, wraps exactly those
--- calls, and builds again until the checker names none.

local Store = require("cosmic.store")
local ast = require("build.ast")
local importer = require("build.importer")
local shared_compiles = require("build.shared_compiles")
local teal = require("build.teal")
local tree = require("build.tree")
local work = require("build.work")
local String = require("cosmic.string")
local type compiler = require("build.compiler")

local record spill
  --- What the checker reports at an `assert(` whose extra values it
  --- refused. The compiler patch spells the same words.
  message: string

  --- The positions the checker names, by file: each an `assert` call's
  --- own `(`, as "line:column".
  type Sites = {string:{string:boolean}}

  --- What a build of the tree said ([`spill.check`]).
  record Built
    sites: Sites
    --- Why the build refused the tree, its diagnostics as the
    --- compiler wrote them; "" when it builds.
    refused: string
  end
end

spill.message = "assert(...) passes on every value it was given, not only " ..
  "the first; write (assert(...)) to keep only the first"

--- The sites a build's refusal names, read off its diagnostics: every
--- `<file>:<line>:<column>: <spill.message>` line.
function spill.sites(text: string): spill.Sites
  local found: spill.Sites = {}
  for line in String.lines(text) do
    local file, y, x, rest = line:match("^(.-):(%d+):(%d+): (.*)$")
    if file ~= nil and String.starts_with(rest, spill.message) then
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

--- Builds the tree at `root`: the sites its refusal names, and the
--- refusal itself ("" when it builds); nil, and why, for a tree that
--- cannot be built at all.
function spill.check(root: string): spill.Built | nil, string
  local own_tree, own_trouble = tree.is_own(root)
  if own_tree == nil then return nil, own_trouble end
  local handle, open_trouble = work.open(root)
  if handle == nil then return nil, open_trouble end
  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    local _, _ = work.close(handle)
    return nil, stage_trouble
  end
  local built = teal.lazy()
  local result, compile_trouble = importer.compile(handle, built,
    Store.meta("compiler") or "", false, shared_compiles.for_build())
  local closed, close_trouble = work.close(handle)
  if not closed then return nil, close_trouble end
  local refused = compile_trouble
  if result ~= nil then refused = table.concat(result.refused, "\n") end
  return { sites = spill.sites(refused), refused = refused }, ""
end

return spill
