--- `--rewrite PATTERN [PATH...]`: one process over `cosmic.ast.rewrite`,
--- multi-file -- the item's whole point is amortizing the ~11-12ms of
--- process boot plus `require`s across every file in one invocation
--- instead of one `bin/cosmic` per file.
---
--- One mechanism, never two: without `--fix` this IS `--find`'s own
--- search mode, delegated rather than re-implemented, and prints
--- exactly what `--find` prints. `--rewrite PATTERN REPL --fix
--- PATH...` is the only new behaviour: it applies REPL over every
--- match, in place, via `cosmic.ast.rewrite`, and refuses (leaves
--- untouched) any hit that would silently drop a comment -- reported
--- to stderr, never re-decided here.
---
--- `cosmic.flags` recognizes `--fix` from ITS OWN registration
--- (`--format`/`--fix`'s FILE-taking flag), so in `--rewrite PATTERN
--- REPL --fix PATH...` that flag absorbs the first PATH as its own
--- value: REPL lands as `paths[1]` and the real target paths are
--- `fix_paths` (that absorbed PATH plus every remaining positional)
--- with REPL's own leading slot removed. `run` reassembles the two.

local ast = require("cosmic.ast")
local fs = require("cosmic.fs")
local find = require("_cli.find")

local type Node = ast.Node

--- Apply `pattern`/`replacement` to one file. Writes the file back only
--- on an ok (formatted, reparsed-clean) result; a parse or format
--- failure is reported to stderr and leaves the file untouched. Every
--- refused hit (comment-loss) is reported to stderr with its own
--- position, per `cosmic.ast.rewrite`'s own refusal.
--- @param pattern Node A compiled pattern
--- @param replacement string A replacement template, `$NAME`/`$$$NAME` surface syntax
--- @param path string The file to rewrite in place
--- @return integer Hits applied in this file
--- @return integer Hits refused in this file
local function fix_one(pattern: Node, replacement: string, path: string): integer, integer
  local source = fs.read(path)
  if not source then
    return 0, 0
  end
  local parsed = ast.parse(source, path)
  local total_hits = parsed and #ast.find_all(parsed.node, pattern) or 0

  local result, err = ast.rewrite(source, path, pattern, replacement)
  if not result then
    io.stderr:write("rewrite: " .. path .. ": " .. tostring(err) .. "\n")
    return 0, 0
  end
  for _, r in ipairs(result.refused) do
    local y, x = ast.span_start(r.node)
    io.stderr:write("rewrite: refused " .. path .. ":" .. y .. ":" .. x
      .. ": would drop " .. #r.comments .. " comment(s)\n")
  end
  local ok, werr = fs.write(path, result.code)
  if not ok then
    io.stderr:write("rewrite: " .. path .. ": " .. tostring(werr) .. "\n")
    return 0, #result.refused
  end
  return total_hits - #result.refused, #result.refused
end

--- Run `--rewrite PATTERN [PATH...]` (search) or `--rewrite PATTERN
--- REPL --fix PATH...` (apply).
--- @param pattern_src string Pattern source, `$NAME`/`$$$NAME` metavariables
--- @param paths {string} Positionals left after the pattern: PATH... in
--- search mode, or REPL followed by PATH...[2:] in --fix mode
--- @param fix_paths {string} `opts.fix`: empty in search mode; in --fix
--- mode, the path `--fix` absorbed as its own value followed by every
--- remaining positional (REPL included, at index 2 -- see module doc)
--- @return integer Exit code: 0 on a clean apply/any hits, 1 on a
--- refusal or none applied, 2 on refused input (bad pattern/files/args)
local function run(pattern_src: string, paths: {string}, fix_paths: {string}): integer
  if #fix_paths == 0 then
    return find.run(pattern_src, paths)
  end
  if #paths == 0 then
    io.write("rewrite: refused: --fix requires a replacement argument\n")
    return 2
  end
  local replacement = paths[1]
  local real_paths: {string} = {fix_paths[1]}
  for i = 2, #paths do
    real_paths[#real_paths + 1] = paths[i]
  end

  local pattern, compile_err = ast.compile_pattern(pattern_src)
  if not pattern then
    io.write("rewrite: refused: " .. compile_err .. "\n")
    return 2
  end
  local files, files_err = find.files_for(real_paths)
  if not files then
    io.write("rewrite: refused: " .. files_err .. "\n")
    return 2
  end

  local applied, refused = 0, 0
  for _, path in ipairs(files) do
    local a, r = fix_one(pattern, replacement, path)
    applied = applied + a
    refused = refused + r
  end
  io.write("rewrite: " .. applied .. " applied, " .. refused ..
    " refused in " .. #files .. " file(s)\n")
  if refused > 0 then
    return 1
  end
  return applied > 0 and 0 or 1
end

local record RewriteModule
  run: function(pattern_src: string, paths: {string}, fix_paths: {string}): integer
end

local M: RewriteModule = {
  run = run,
}

return M
