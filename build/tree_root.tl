--- Which directory a tree verb runs in when it is started below the
--- project's root: `cosmic test` in `greet/` of a project already built
--- at its root is the root's, not a new tree of `greet/`'s own, whose
--- `require("greet")` finds nothing.
---
--- A tree is established where a build wrote `o/cosmic.db`: `o/build.db`
--- alone is left by a run that failed, in the wrong directory too, so it
--- names no tree. The working directory that holds one is the tree; else
--- the nearest ancestor that does is, never the home directory or
--- anything above it; and where none does, the working directory is the
--- tree as before -- a first `cosmic test` starts a project where it is
--- run.

local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")

local record tree_root
  --- Where a verb was started and the tree it runs in instead.
  record Move
    --- The tree's root, absolute.
    root: string
    --- The working directory the verb was started in, absolute.
    from: string
    --- The command line, its path arguments read from `from` and now
    --- relative to `root`.
    argv: {integer:string}
  end
end

--- Whether a build wrote a database under `dir`'s `o/`.
local function established(dir: string): boolean
  local found, _ = Fs.exists(dir .. "/o/cosmic.db")
  return found == true
end

--- The nearest ancestor of `dir`, absolute, that a build established, or
--- nil: none does, or `dir` is at or above `home`, or `dir` holds one
--- itself. The climb ends at `home` and at the filesystem root, neither
--- of which is a tree.
--- @param dir an absolute directory
--- @param home the home directory, or nil for none
local function above(dir: string, home: string | nil): string | nil
  if established(dir) then return nil end
  local here = dir
  while true do
    local parent = Fs.dirname(here)
    if parent == here or parent == "/" or parent == home then return nil end
    if established(parent) then return parent end
    here = parent
  end
end

--- The verbs whose words, all of them ("all") or all but the first
--- ("rest") or only those naming something that exists ("named"), are
--- paths to read from where the verb was started. `docs` and `db` take none
--- that matter; `sql` looks in the working directory only, by its documentation.
local paths <const>: {string:string} = {
  test = "named", fix = "all", build = "all", db = "all", uses = "rest", todos = "named",
  docs = "none",
}

--- `word` as a path from `root`, absolute where it is not within it.
local function from_root(word: string, root: string): string
  local absolute, _ = Fs.absolute(word)
  if absolute == nil then return word end
  local relative, _ = Fs.relative(absolute, root)
  return relative or absolute
end

--- The tree a command line's verb runs in and its command line for it,
--- or nil when it runs where it was started.
--- @param argv the command line, the verb at slot 1
--- @param options the verb's options, as `cosmic.cli` names them
--- @param home the home directory, or nil for none, where the climb ends
function tree_root.move(argv: {integer:string},
    options: {string:boolean | Flags.Option}, home: string | nil): tree_root.Move | nil
  local kind = paths[argv[1]]
  if kind == nil then return nil end
  local from, _ = Fs.absolute(".")
  if from == nil then return nil end
  local root = above(from, home)
  if root == nil then return nil end

  local line: {integer:string} = {}
  for slot, word in pairs(argv) do line[slot] = word end
  local seen = 0
  local slot = 2
  local literal = false
  while argv[slot] ~= nil do
    local word = argv[slot]
    if not literal and word == "--" then
      literal = true
    elseif not literal and word:sub(1, 1) == "-" and word ~= "-" then
      local option = options[word]
      if option is Flags.Option and option.value ~= nil and word:find("=", 1, true) == nil then
        slot = slot + 1
      end
    else
      seen = seen + 1
      local name = word
      if argv[1] == "test" then name = word:match("^(.-):[^:/]*$") or word end
      local takes = kind == "all" or (kind == "rest" and seen > 1)
      if not takes and kind == "named" then
        local there, _ = Fs.exists(name)
        takes = there == true
      end
      if takes then
        local rewritten = from_root(name, root)
        line[slot] = rewritten .. word:sub(#name + 1)
      end
    end
    slot = slot + 1
  end
  return { root = root, from = from, argv = line }
end

return tree_root
