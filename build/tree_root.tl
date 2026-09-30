--- Which directory a tree verb runs in when it is started below the
--- project's root: `cosmic test` in `greet/` of a project already built
--- at its root is the root's, not a new tree of `greet/`'s own, whose
--- `require("greet")` finds nothing.
---
--- A tree is established where a build wrote `o/cosmic.db`, and a
--- working directory is in one when that tree's last build also staged
--- a source at or under it (`o/build.db`'s `files`). `o/build.db` alone
--- is left by a run that failed, in the wrong directory too, so it names
--- no tree; and a new project made below a built tree has staged
--- nothing there, so it stays a root of its own. The working directory
--- that holds `o/cosmic.db` is the tree; else the nearest ancestor that
--- holds one and staged the working directory is, never the home
--- directory or anything above it; and where none does, the working
--- directory is the tree as before -- a first `cosmic test` starts a
--- project where it is run. `COSMIC_TREE=<dir>` names the root instead,
--- `.` for the working directory.
---
--- A word a `test` or `todos` line gives that names an existing path
--- is taken as that path, read from where the verb was started, and not
--- as a module name or search words.
---
--- `cosmic <file.tl>` (build.dispatch's `run`) does not choose this way:
--- run in a subdirectory it still writes an `o/` there, which then makes
--- that directory a root of its own.

local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

local record tree_root
  --- Where a verb was started and the tree it runs in instead.
  record Move
    --- The tree's root, absolute.
    root: string
    --- The command line, its path arguments read from where the verb
    --- was started and now relative to `root`.
    argv: {integer:string}
  end

  --- What `move` decides.
  record Answer
    --- The move, or nil where the verb runs where it was started.
    move: Move | nil
    --- Why the command line is refused (`COSMIC_TREE` names no
    --- directory), or empty.
    refused: string
    --- Why a tree found was not used, or empty.
    note: string
  end
end

--- Whether a build wrote a database under `dir`'s `o/`.
local function established(dir: string): boolean
  local found, _ = Fs.exists(dir .. "/o/cosmic.db")
  return found == true
end

--- Whether `root`'s last build staged a source at `path` or under it,
--- `path` relative to `root`; nil and why when its `o/build.db` cannot
--- be read, which is not an answer either way.
-- TODO: climb from a directory the last build staged no Teal under --
-- prose alone (`doc/`, whose Markdown the walk skips), or one made
-- since -- which is now a root of its own: `cosmic fix` there fails
-- `../x.tl` as outside the project and writes an `o/` there. The fix is
-- for the build to record the directories it walked, less the trees of
-- their own within it (`ci/`, [`work.is_foreign_tree`]), and to climb
-- on that record.
local function staged(root: string, path: string): boolean | nil, string
  local file = root .. "/o/build.db"
  local db, open_trouble = Sqlite.open(file, false)
  if db == nil then return nil, open_trouble end
  local rows, trouble = Sqlite.rows(db, "SELECT 1 FROM files WHERE path = ?1 OR " ..
    "substr(path, 1, length(?2)) = ?2 LIMIT 1", { { text = path }, { text = path .. "/" } })
  local _, _ = db:close()
  if rows == nil then return nil, file .. ": " .. trouble end
  return #rows > 0
end

--- The nearest ancestor of `dir`, absolute, that a build established and
--- staged `dir` in, or nil: none does, or `dir` is at or above `home`,
--- or `dir` holds an established tree itself. The climb ends at `home`
--- and at the filesystem root, neither of which is a tree. A second
--- answer says why when a tree was found but its database could not be
--- read, so `dir` is left a root of its own for that reason.
--- @param dir an absolute directory
--- @param home the home directory, resolved, or nil for none
local function above(dir: string, home: string | nil): string | nil, string
  if established(dir) then return nil, "" end
  local here = dir
  while true do
    local parent = Fs.dirname(here)
    if parent == here or parent == "/" or parent == home then return nil, "" end
    if established(parent) then
      local rest, _ = Fs.relative(dir, parent)
      if rest == nil then return nil, "" end
      local found, trouble = staged(parent, rest)
      if found == nil then
        return nil, "not using the tree at " .. parent .. ": " .. trouble
      end
      if found then return parent, "" end
      return nil, ""
    end
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

--- `path` with its `.` and `..` and repeated slashes settled, lexically,
--- and no link followed: the way to name what may not exist. Absolute
--- when `path` is.
local function normalized(path: string): string
  local parts: {string} = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        parts[#parts] = nil
      elseif path:sub(1, 1) ~= "/" then
        parts[#parts + 1] = part
      end
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  local joined = table.concat(parts, "/")
  if path:sub(1, 1) == "/" then return "/" .. joined end
  return joined == "" and "." or joined
end

--- `word` read from the directory `from`, unnormalized.
local function joined_to(from: string, word: string): string
  if word:sub(1, 1) == "/" then return word end
  return (from == "/" and "" or from) .. "/" .. word
end

--- `word`, read from `from`, as a path from `root`: absolute where it is
--- not within it.
local function from_root(word: string, from: string, root: string): string
  local absolute = normalized(joined_to(from, word))
  local relative, _ = Fs.relative(absolute, root)
  return relative or absolute
end

--- The tree a command line's verb runs in and its command line for it,
--- or nil when it runs where it was started.
--- @param argv the command line, the verb at slot 1
--- @param options the verb's options, as [`cosmic.cli`] names them
--- @param home the home directory, or nil for none, where the climb ends
--- @param named `COSMIC_TREE`, or nil: the root, `.` for the working directory
function tree_root.move(argv: {integer:string},
    options: {string:boolean | Flags.Option}, home: string | nil,
    named?: string): tree_root.Answer
  local kind = paths[argv[1]]
  if kind == nil then return { refused = "", note = "" } end
  local from, _ = Fs.absolute(".")
  if from == nil then return { refused = "", note = "" } end
  local root: string | nil
  local note = ""
  if named ~= nil and named ~= "" then
    root = normalized(joined_to(from, named))
    local directory, _ = Fs.is_dir(root)
    if not directory then
      return { refused = "COSMIC_TREE=" .. named .. " is not a directory", note = "" }
    end
    local there, _ = Fs.absolute(root)
    if there == from then return { refused = "", note = "" } end
  else
    -- The home directory as `from` is spelled: resolved, else as given
    -- less its trailing slashes.
    local resolved: string | nil = nil
    if home ~= nil and home ~= "" then
      local real, _ = Fs.absolute(home)
      resolved = real or normalized(home)
    end
    root, note = above(from, resolved)
  end
  if root == nil then return { refused = "", note = note } end

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
        local rewritten = from_root(name, from, root)
        line[slot] = rewritten .. word:sub(#name + 1)
      end
    end
    slot = slot + 1
  end
  return { move = { root = root, argv = line }, refused = "", note = "" }
end

return tree_root
