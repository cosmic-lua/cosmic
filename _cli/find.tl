--- `--find PATTERN [PATH...]`: a read-only structural search over
--- `cosmic.ast.match`, the first workflow consumer of the matcher.
---
--- One line per hit — `<path>:<line>:<col>: <source line, trimmed>` —
--- sorted by path then line, ending in the verdict line every run
--- prints: `find: N hit(s) in M file(s)`. `N` is every node the
--- pattern matched across every searched file; `M` is how many files
--- were searched, whether or not any of them hit. A pattern that
--- fails to parse refuses on that same verdict line instead, with the
--- parse error in place of a count.
---
--- With no PATH given, the files searched are the project's own `.tl`
--- sources, selected exactly as `--check` selects them
--- (`_make.check`'s own `select_files`, over a fresh `project.scan` of
--- the current directory) — one selection rule, not a second copy of
--- it drifting here.

local ast = require("cosmic.ast")
local fs = require("cosmic.fs")
local mcheck = require("_make.check")
local project = require("_make.project")

local type Node = ast.Node

--- One matched node, ready to sort and print.
local record Hit
  path: string
  line: integer
  col: integer
  text: string
end

--- The files to search: `paths` when given, else every `.tl` source
--- `--check` would walk — one selection rule shared with it, over a
--- fresh scan of the current directory.
--- @param paths {string} PATH arguments, or empty for the whole project
--- @return {string}|nil File paths, in project order
--- @return string An error when the project cannot be scanned, or a path selects nothing
local function files_for(paths: {string}): {string} | nil, string
  local proj, perr = project.scan(".")
  if not proj then
    return nil, perr
  end
  local files, ferr = mcheck.select_files(proj, paths)
  if not files then
    return nil, ferr
  end
  return project.paths_of(files)
end

--- The 1-based line `y` of `text`, trimmed of surrounding whitespace.
--- @param text string The file's full source
--- @param y integer 1-based line number
--- @return string The trimmed line, or "" when `y` is past the file's end
local function line_at(text: string, y: integer): string
  local n = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    n = n + 1
    if n == y then
      return (line:match("^%s*(.-)%s*$"))
    end
  end
  return ""
end

--- Every node in `path`'s parsed tree that `pattern` matches. A file
--- that fails to lex or parse contributes no hits and no error of its
--- own — the same policy `_build/casts.tl`'s own tree-wide scan takes
--- for a file its lexer cannot read.
--- @param pattern Node A compiled pattern
--- @param path string The file to search
--- @return {Hit} This file's hits, in tree-walk order
local function hits_in(pattern: Node, path: string): {Hit}
  local hits: {Hit} = {}
  local source = fs.read(path)
  if not source then
    return hits
  end
  local parsed = ast.parse(source, path)
  if not parsed then
    return hits
  end
  ast.walk(parsed.node, function(n: Node)
      if ast.match(pattern, n) then
        local y, x = ast.span_start(n)
        hits[#hits + 1] = {path = path, line = y, col = x, text = line_at(source, y)}
      end
    end)
  return hits
end

--- Run `--find PATTERN [PATH...]`.
--- @param pattern_src string Pattern source, `$NAME`/`$$$NAME` metavariables
--- @param paths {string} PATH arguments, or empty for the whole project
--- @return integer Exit code: 0 on hits, 1 on none, 2 on refusal
local function run(pattern_src: string, paths: {string}): integer
  local pattern, compile_err = ast.compile_pattern(pattern_src)
  if not pattern then
    io.write("find: refused: " .. compile_err .. "\n")
    return 2
  end
  local files, files_err = files_for(paths)
  if not files then
    io.write("find: refused: " .. files_err .. "\n")
    return 2
  end
  local hits: {Hit} = {}
  for _, path in ipairs(files) do
    for _, h in ipairs(hits_in(pattern, path)) do
      hits[#hits + 1] = h
    end
  end
  table.sort(hits, function(a: Hit, b: Hit): boolean
      if a.path ~= b.path then
        return a.path < b.path
      end
      if a.line ~= b.line then
        return a.line < b.line
      end
      return a.col < b.col
    end)
  for _, h in ipairs(hits) do
    io.write(h.path .. ":" .. h.line .. ":" .. h.col .. ": " .. h.text .. "\n")
  end
  io.write("find: " .. #hits .. " hit(s) in " .. #files .. " file(s)\n")
  return #hits > 0 and 0 or 1
end

local record FindModule
  run: function(pattern_src: string, paths: {string}): integer
  --- Exported so `_cli.rewrite` (multi-file, one process) shares this
  --- exact selection rule rather than a second, separately-maintained
  --- file-walk.
  files_for: function(paths: {string}): {string} | nil, string
end

local M: FindModule = {
  run = run,
  files_for = files_for,
}

return M
