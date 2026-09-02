#!/usr/bin/env cosmic
--- Per-file counts of the `return nil` sites the committed tree carries
--- under a signature that cannot be nil.
---
--- A function declaring a bare non-nil return type and returning nil
--- anyway is a promise to the reader that nothing enforces: the checker
--- accepts the return, callers index the result without narrowing, and
--- none of the nil tooling can see it, because the narrowing rules,
--- `check.must` and the `fallible-returns` rule all act on a type that
--- ADMITS nil and this one does not. The union never forms, so nothing
--- downstream is ever asked to narrow it.
---
--- What is counted is `_cli.nilreturn`' `nil_return_lines` — one lexer,
--- shared with the parser that reads declared return lists, so a
--- `return nil` quoted in a string or shown in a doc comment counts for
--- nothing, and an inner closure's nil is charged to the closure rather
--- than to the function around it.
---
--- Beside the count, `unbalanced` reports every file whose walk left a
--- frame open or met an `end` with nothing to pop — the type grammar's
--- own consistency check, which the same test gates at zero over the
--- whole tree.
---
--- The count feeds `_build/nil_returns_test.tl`, which gates it against
--- the committed floor in `_build/nil_returns_baseline.tl`. Rewrite that
--- floor whenever the counts move:
---
---     bin/cosmic --make run _build/nil_returns.tl --baseline
---
--- The floor is written and read back through `_tool.floor`, over
--- `cosmic.literal.format_file`/`parse_file`: one `["path"] = count`
--- entry per line, sorted by path, so a review sees the files whose
--- counts changed and nothing else.

local floor = require("_tool.floor")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local nilreturn = require("_cli.nilreturn")

--- The committed floor: where this module writes it and the test reads
--- it, relative to the project root.
local BASELINE < const > = "_build/nil_returns_baseline.tl"

--- The trees the count covers: every tree of committed Teal source.
--- `3p/` is not one — its contents are vendored, not written here.
local TREES < const >: {string} = {
  "_build", "_cli", "_docs", "_eval",
  "_fuzz", "_make", "_perf", "_tool",
  "_types", "cmd", "cosmic",
}

--- Every readable source the count covers, visited in `fs.find` order:
--- each tree in `TREES`, less `testdata/` fixtures (not the tree) and
--- `.d.tl` declarations (C binding interfaces, which declare no bodies
--- to return from). A tree missing under `root` and a file that cannot
--- be read contribute nothing — the walk is a measurement of what is
--- there.
--- @param root string The project root
--- @param visit function(rel: string, text: string) Called once per
--- source with its root-relative path and bytes
local function each_source(root: string,
    visit: function(rel: string, text: string))
  for _, tree in ipairs(TREES) do
    local dir = fs.join(root, tree)
    if fs.is_dir(dir) then
      local found = fs.find(dir, {glob = "*.tl"})
      if found then
        for _, path in ipairs(found) do
          local rest = path:sub(#dir + 2)
          if not ("/" .. rest):find("/testdata/", 1, true)
          and not rest:find("%.d%.tl$") then
            local text = fs.read(path)
            if text then
              visit(tree .. "/" .. rest, text)
            end
          end
        end
      end
    end
  end
end

--- Sites per source file, keyed by path relative to `root`.
---
--- Only files carrying at least one site appear: a file at zero is
--- absent, which is what lets the gate read "absent from the baseline"
--- as "had none". A file the lexer cannot lex contributes nothing — the
--- count is a measurement of what is there, and there is no failure it
--- could report that the gate reading it would not already see as a
--- moved number.
--- @param root string The project root to count under
--- @return {string: integer} Counts by root-relative path
local function count(root: string): {string: integer}
  local out: {string: integer} = {}
  each_source(root, function(rel: string, text: string)
      local n = #nilreturn.nil_return_lines(text, rel)
      if n > 0 then
        out[rel] = n
      end
    end)
  return out
end

--- Files whose frame walk does not balance: a frame left open at end of
--- file, or an `end` that arrived with nothing to pop.
---
--- This is the type grammar's consistency check, and it needs no
--- knowledge of the shape it catches. The walk pushes a frame for every
--- body it lands on and pops one per `end`, so a type-position shape it
--- mis-reads — a nested generic whose closers arrive as one token, an
--- alias whose body was consumed as a name — unbalances the stack
--- somewhere in the tree before it moves a count anywhere, and a count
--- over an unbalanced file is wrong in whichever direction the misread
--- pointed. The fix for a file listed here is in the grammar, never in
--- the file.
--- @param root string The project root to walk under
--- @return {string} One line per unbalanced file, sorted by path; empty
--- when every file balances
local function unbalanced(root: string): {string}
  local out: {string} = {}
  each_source(root, function(rel: string, text: string)
      local w = nilreturn.walk(text, rel)
      if w.residual > 0 or w.underflow > 0 then
        out[#out + 1] = string.format(
          "%s: %d frame(s) left open at end of file, %d end(s) with nothing"
          .. " to pop", rel, w.residual, w.underflow)
      end
    end)
  table.sort(out)
  return out
end

--- The lines a single file's sites sit on, for a gate that has to say
--- WHERE a count grew. The ratchet's own message is a number; a number
--- with no line leaves the author to find the site themselves.
--- @param path string The file to read
--- @return {integer} The lines, ascending; empty when unreadable
local function lines_in(path: string): {integer}
  local text = fs.read(path)
  if text == nil then
    return {}
  end
  return nilreturn.nil_return_lines(text, path)
end

--- The committed floor, read as data.
--- @param path string|nil The baseline file (default `_build/nil_returns_baseline.tl`)
--- @return {string: integer}|nil Counts by root-relative path
--- @return string The error when the file cannot be read or parsed
local function baseline(path?: string): {string: integer} | nil, string
  local from = path or BASELINE
  local data, err = floor.read(from)
  if data == nil then
    return nil, err
  end
  local out: {string: integer} = {}
  for file, n in pairs(data) do
    -- A floor entry that is not a count is a corrupt floor, and saying
    -- so beats coercing it: the gate reading this back would otherwise
    -- compare a real count against nonsense and call the file changed.
    if not (n is integer) then
      return nil, ("%s: %s is not a count"):format(from, file)
    end
    out[file] = n
  end
  return out
end

--- Rewrite the baseline from a fresh count of the tree.
--- @param ... string Command-line arguments
--- @return integer The exit status
local function main(...: string): integer
  local args = {...}
  if args[1] ~= "--baseline" then
    io.stderr:write(
      "usage: cosmic --make run _build/nil_returns.tl --baseline\n")
    return 1
  end
  local counts = count(".")
  local files, total = 0, 0
  for _, n in pairs(counts) do
    files = files + 1
    total = total + n
  end
  local ok, err = floor.write(BASELINE, counts)
  if not ok then
    io.stderr:write("nil-returns: " .. err .. "\n")
    return 1
  end
  print(string.format("nil-returns: wrote %s — %d sites in %d files",
      BASELINE, total, files))
  return 0
end

if proc.is_main() then
  os.exit(main(...))
end

local record NilReturnsModule
  --- The committed floor's path, relative to the project root.
  BASELINE: string
  --- The trees this count covers: every tree of committed Teal source.
  TREES: {string}
  count: function(root: string): {string: integer}
  unbalanced: function(root: string): {string}
  lines_in: function(path: string): {integer}
  baseline: function(path?: string): {string: integer} | nil, string
  main: function(...: string): integer
end

local M: NilReturnsModule = {
  BASELINE = BASELINE,
  TREES = TREES,
  count = count,
  unbalanced = unbalanced,
  lines_in = lines_in,
  baseline = baseline,
  main = main,
}

return M
