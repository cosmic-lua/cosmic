--- The one place a source says "I read this file".
---
--- `require` declares what a source imports, and the graph turns those
--- edges into prerequisites so a test re-runs when what it imports
--- changes. A RATCHET does not import what it checks: `_build/
--- workflows_test.tl` reads `.github/workflows/*.yml` as bytes,
--- `_docs/derive.tl` reads every decision record. Nothing in the model
--- saw those reads, so an incremental `--make test` re-ran neither
--- ratchet when its subject changed -- the gate went green on a stale
--- result, which is the silent pass a ratchet exists to prevent. Only
--- a fresh tree (CI) caught the drift.
---
--- So this is the second declaration channel, and it is deliberately
--- the smallest one that closes that hole:
---
---     -- @reads .github/workflows/*.yml
---
--- A comment line and nothing else, anywhere in the source, naming a
--- path or a glob relative to the project ROOT. It is scheduling
--- information only: `_make.deps` unions a file's declarations with
--- those of everything it imports, `_make.graph` writes them out as
--- prerequisites, and `_make.validate` refuses one that matches
--- nothing -- a declaration that names no file is a promise about
--- staleness nobody kept.
---
--- What it deliberately is NOT: a grant. A test may already read the
--- project it belongs to (`_cli/grants.tl`), and narrowing that to
--- these declarations would need them to be COMPLETE, which nothing
--- here can check -- a forgotten declaration would turn into a denied
--- read instead of a stale result.
---
--- The limit that follows from the refusal, stated: a declaration
--- names files that are THERE when the model is scanned, which means
--- committed ones. A path a `fetch` or a generator produces later
--- cannot be declared, because on a cold tree it matches nothing.
--- Those are build outputs with rules of their own; this channel is
--- for the tree's own files, which have none.
---
--- Scanned line-anchored rather than lexically, unlike `require`: a
--- declaration IS a comment, so the scanner cannot skip comments the
--- way `_make.imports` does. The cost is a long string whose interior
--- line begins with `-- @reads`, which reads as a declaration; it
--- names a real file (a harmless extra prerequisite) or the validator
--- names it.

local fs = require("cosmic.fs")
local types = require("_make.types")

local type Issue = types.Issue
local type Project = types.Project

--- The declarations in a source, in file order, unexpanded.
--- @param src string The source text
--- @return {string} Declared paths and globs, relative to the root
local function scan(src: string): {string}
  local out: {string} = {}
  for line in src:gmatch("([^\n]*)\n?") do
    local pattern = line:match("^%s*%-%-+%s*@reads%s+(%S+)%s*$")
    if pattern then
      out[#out + 1] = pattern
    end
  end
  return out
end

--- Declarations scanned so far this model build, by absolute path.
local cache: {string: {string}} = {}

--- Drop the memo, on the same schedule as `_make.imports`: one model
--- build is one snapshot of the tree.
local function forget()
  cache = {}
end

--- The declarations of a source file, read once per model build.
--- @param path string Absolute path to the source
--- @return {string} Declared paths and globs, in file order
local function of_file(path: string): {string}
  local hit = cache[path]
  if hit then
    return hit
  end
  local content = fs.read(path)
  local found = content and scan(content as string) or {} -- cast: scalar narrowing
  cache[path] = found
  return found
end

--- What a declaration names today: the files it matches, plus — when
--- it is a glob — the directories they came out of.
---
--- The directories are what makes a DELETION visible. A record removed
--- from `docs/decisions/` leaves every surviving prerequisite
--- untouched, so make would call the ratchet up to date while the
--- index still carries the gone record's row -- one of the three
--- failures that ratchet claims to catch. A directory's mtime moves
--- when an entry appears or disappears, so listing it catches both.
---
--- One level of expansion, `fs.glob`'s: `*` and `?` never cross a `/`
--- and there is no `**`. A subtree wants a declaration per level, and
--- that is the honest spelling -- a recursive glob would quietly make
--- every file below a prerequisite of every test that named the root.
--- @param root string Absolute project root
--- @param pattern string A declared path or glob, relative to the root
--- @return {string} Matching paths, relative to the root, sorted
local function expand(root: string, pattern: string): {string}
  local base = root ~= "" and root or "."
  local matched = fs.glob(base, pattern)
  if matched == nil then
    return {}
  end
  local prefix = base:sub(-1) == "/" and base or (base .. "/")
  local seen: {string: boolean} = {}
  local out: {string} = {}
  local function add(rel: string)
    if rel ~= "" and rel ~= "." and not seen[rel] then
      seen[rel] = true
      out[#out + 1] = rel
    end
  end
  local globbed = pattern:find("[*?]") ~= nil
  for _, path in ipairs(matched as {string}) do -- cast: union after the guard
    local rel = path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or path
    add(rel)
    if globbed then
      add(fs.dirname(rel))
    end
  end
  table.sort(out)
  return out
end

--- Complain about every declaration that names nothing.
---
--- The whole value of the channel is that a prerequisite exists, so a
--- declaration matching no file is worth less than none: it reads like
--- the hole is closed while the ratchet keeps its stale-pass. A typo,
--- a moved directory and a file deleted out from under a ratchet all
--- land here, and they land at `check` time with the path and the
--- pattern named, rather than as a green stage nobody re-ran.
---
--- Absolute and escaping patterns are refused for the same reason the
--- model refuses them everywhere else: a project's inputs are inside
--- the project. `fs.glob` would answer an absolute pattern with an
--- error and an escaping one with a file no rule can name.
--- @param proj Project The scanned project
--- @param issues {Issue} Issues to append to
local function check(proj: Project, issues: {Issue})
  for _, f in ipairs(proj.files) do
    if types.scanned_kinds[f.kind] then
      local path = proj.root ~= "" and (proj.root .. "/" .. f.path) or f.path
      for _, pattern in ipairs(of_file(path)) do
        local outside = pattern:sub(1, 1) == "/" or pattern:sub(1, 3) == "../"
        or pattern:find("/../", 1, true) ~= nil
        if outside then
          issues[#issues + 1] = {path = f.path, message =
            "declares `@reads " .. pattern .. "`, which leaves the " ..
            "project; a declaration names an input, and an input is a " ..
            "file inside the tree"}
        elseif #expand(proj.root, pattern) == 0 then
          issues[#issues + 1] = {path = f.path, message =
            "declares `@reads " .. pattern .. "`, which matches no " ..
            "file; a declaration that names nothing schedules nothing, " ..
            "so the reader would keep passing on a stale result"}
        end
      end
    end
  end
end

local record ReadsModule
  scan: function(src: string): {string}
  of_file: function(path: string): {string}
  forget: function()
  expand: function(root: string, pattern: string): {string}
  check: function(proj: Project, issues: {Issue})
end

local M: ReadsModule = {
  scan = scan,
  of_file = of_file,
  forget = forget,
  expand = expand,
  check = check,
}

return M
