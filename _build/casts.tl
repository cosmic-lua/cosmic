#!/usr/bin/env cosmic
--- Per-file counts of the `as` casts the committed tree carries.
---
--- Every cast in a committed file says why it is there: `--make lint`
--- fails a line holding an `as` whose reason is missing, so each cast
--- line carries a `-- cast: <reason>` comment, trailing on the line
--- itself or standalone directly above it. Counting those comments
--- therefore counts the cast lines, and does it without a second cast
--- lexer to keep in step with the linter's.
---
--- The count feeds `_build/casts_test.tl`, which gates it against the
--- committed floor in `_build/casts_baseline.tl`. Rewrite that floor
--- whenever the counts move:
---
---     bin/cosmic --make run _build/casts.tl --baseline
---
--- The floor is written by `cosmic.literal.format_file` and read back by
--- `cosmic.literal.parse_file`: the same module writes and reads it, and
--- its layout is what a baseline needs anyway — one `["path"] = count`
--- entry per line, sorted by path, so a review sees the files whose
--- counts changed and nothing else.

local fs = require("cosmic.fs")
local literal = require("cosmic.literal")
local proc = require("cosmic.proc")

--- The committed floor: where this module writes it and the test reads
--- it, relative to the project root.
local BASELINE < const > = "_build/casts_baseline.tl"

--- The trees the count covers: every tree of committed Teal source.
--- `3p/` is not one — its contents are vendored, not written here.
local TREES < const >: {string} = {
  "_build", "_cli", "_docs", "_make", "_perf", "_tool",
  "_types", "_work", "cmd", "cosmic",
}

--- Cast-justification comments in one file's text.
---
--- One line holds at most one, in either position, so the line count is
--- the cast-line count. A file that quotes the comment's own syntax --
--- the linter's message, this module's tests -- counts those lines too;
--- the floor records what is there, so a quotation costs a baseline
--- entry and nothing else.
--- @param text string The file's bytes
--- @return integer The number of lines carrying a justification
local function in_text(text: string): integer
  local n = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("%-%- cast: %S") then
      n = n + 1
    end
  end
  return n
end

--- Cast counts per source file, keyed by path relative to `root`.
---
--- Only files carrying at least one cast appear: a file at zero is
--- absent, which is what lets the gate read "absent from the baseline"
--- as "had none". A tree missing under `root`, or a file that cannot be
--- read, contributes nothing -- the count is a measurement of what is
--- there, and there is no failure it could report that the gate reading
--- it would not already see as a moved number.
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
            local n = text and in_text(text) or 0
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
  local data, err = literal.parse_file(path or BASELINE)
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
  local ok, err = literal.format_file(BASELINE, counts)
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
  count: function(root: string): {string: integer}
  baseline: function(path?: string): {string: integer} | nil, string
  main: function(...: string): integer
end

local M: CastsModule = {
  BASELINE = BASELINE,
  count = count,
  baseline = baseline,
  main = main,
}

return M
