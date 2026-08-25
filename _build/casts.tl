#!/usr/bin/env cosmic
--- Per-file counts of the `as` casts the committed tree carries.
---
--- Every cast in a committed file says why it is there: `--make lint`
--- fails a line holding an `as` whose reason is missing, so each cast
--- line carries a `-- cast: <reason>` comment, trailing on the line
--- itself or standalone directly above it. What this module counts is
--- the `as` tokens themselves, through `_cli.lint`'s scanner — one
--- lexer, shared with the gate that enforces the rule, so a cast quoted
--- in a string or named in a doc comment is not counted, and a reason
--- left behind by a cast that is gone counts for nothing.
---
--- The count feeds `_build/casts_test.tl`, which gates it against the
--- committed floor in `_build/casts_baseline.tl`. Rewrite that floor
--- whenever the counts move:
---
---     bin/cosmic --make run _build/casts.tl --baseline
---
--- The floor is written and read back through `_tool.floor`, over
--- `cosmic.literal.format_file`/`parse_file`: the same module writes and
--- reads it, and its layout is what a baseline needs anyway — one
--- `["path"] = count` entry per line, sorted by path, so a review sees
--- the files whose counts changed and nothing else.

local floor = require("_tool.floor")
local fs = require("cosmic.fs")
local lint = require("_cli.lint")
local proc = require("cosmic.proc")

--- The committed floor: where this module writes it and the test reads
--- it, relative to the project root.
local BASELINE < const > = "_build/casts_baseline.tl"

--- The trees the count covers: every tree of committed Teal source.
--- `3p/` is not one — its contents are vendored, not written here.
local TREES < const >: {string} = {
  "_build", "_cli", "_docs", "_eval",
  "_fuzz", "_make", "_perf", "_tool",
  "_types", "cmd", "cosmic",
}

--- Cast counts per source file, keyed by path relative to `root`.
---
--- A file's count is its number of lines holding an `as`, one line
--- counting at most once. Only files carrying at least one cast appear:
--- a file at zero is absent, which is what lets the gate read "absent
--- from the baseline" as "had none". A tree missing under `root`, a file
--- that cannot be read, and a file the lexer cannot lex all contribute
--- nothing -- the count is a measurement of what is there, and there is
--- no failure it could report that the gate reading it would not already
--- see as a moved number.
--- @param root string The project root to count under
--- @return {string: integer} Counts by root-relative path
local function count(root: string): {string: integer}
  local out: {string: integer} = {}
  for _, tree in ipairs(TREES) do
    local dir = fs.join(root, tree)
    if fs.is_dir(dir) then
      local found = fs.find(dir, {glob = "*.tl"})
      if found then
        for _, path in ipairs(found) do
          -- The path under the tree, so the key is root-relative
          -- whatever spelling of the root the caller passed.
          local rest = path:sub(#dir + 2)
          if not ("/" .. rest):find("/testdata/", 1, true) then
            local text = fs.read(path)
            local n = text and #lint.cast_lines(text, path) or 0
            if n > 0 then
              out[tree .. "/" .. rest] = n
            end
          end
        end
      end
    end
  end
  return out
end

--- The committed floor, read as data.
--- @param path string|nil The baseline file (default `_build/casts_baseline.tl`)
--- @return {string: integer}|nil Counts by root-relative path
--- @return string The error when the file cannot be read or parsed
local function baseline(path?: string): {string: integer} | nil, string
  local data, err = floor.read(path or BASELINE)
  if not data then
    return nil, err
  end
  local out: {string: integer} = {}
  for file, n in pairs(data) do
    out[file] = n as integer -- cast: the baseline holds counts
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
      "usage: cosmic --make run _build/casts.tl --baseline\n")
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
    io.stderr:write("casts: " .. err .. "\n")
    return 1
  end
  print(string.format("casts: wrote %s — %d casts in %d files",
      BASELINE, total, files))
  return 0
end

if proc.is_main() then
  os.exit(main(...))
end

local record CastsModule
  --- The committed floor's path, relative to the project root.
  BASELINE: string
  --- The trees this count covers: every tree of committed Teal source.
  TREES: {string}
  count: function(root: string): {string: integer}
  baseline: function(path?: string): {string: integer} | nil, string
  main: function(...: string): integer
end

local M: CastsModule = {
  BASELINE = BASELINE,
  TREES = TREES,
  count = count,
  baseline = baseline,
  main = main,
}

return M
