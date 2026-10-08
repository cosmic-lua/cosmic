--- Which directory a tree verb runs in when it is started below the
--- project's root: `cosmic test` in `greet/` of a project already built
--- at its root is the root's, not a new tree of `greet/`'s own, whose
--- `require("greet")` finds nothing.
---
--- A tree is established when its build directory holds `cosmic.db`.
--- A working directory belongs to that tree when its last build staged
--- a source at or under it (`build.db`'s `files`). A working database
--- alone can remain after a failed run, so it establishes no tree.
--- A new project nested inside a built tree stays its own root until
--- that tree stages it. The nearest established ancestor that staged
--- the working directory supplies the root; the climb stops at the
--- home directory. Where none does, the working directory is the root.
--- `COSMIC_TREE=<dir>` names the root instead, `.` for the working directory.
---
--- A word a `test` or `todos` line gives that names an existing path
--- is taken as that path, read from where the verb was started, and not
--- as a module name or search words.
---
--- `cosmic <file.tl>` (build.dispatch's `run`) does not choose this way:
--- run in a subdirectory it builds that directory as a root of its own.

local build_paths = require("build.paths")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local narrow = require("build.narrow")

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

--- Whether a build wrote a projection for the project rooted at `dir`.
local function established(dir: string): boolean
  local directory, trouble = build_paths.optional(dir)
  if directory == nil then
    assert(trouble == "", trouble)
    return false
  end
  local found, _ = Fs.exists(directory .. "/cosmic.db")
  return found == true
end

--- Whether `root`'s last build staged a source at `path` or under it,
--- `path` relative to `root`; nil and why when its `build.db` cannot
--- be read, which is not an answer either way.
-- TODO: climb from a directory the last build staged no Teal under --
-- prose alone (`doc/`, whose Markdown the walk skips), or one made
-- since -- which is now a root of its own: `cosmic fix` there fails
-- `../x.tl` as outside the project and builds that directory as a project. The fix is
-- for the build to record the directories it walked, less the trees of
-- their own within it (`ci/`, [`build.identity.is_foreign_tree`]), and to climb
-- on that record.
local function staged(root: string, path: string): boolean | nil, string
  local file = build_paths.required(root) .. "/build.db"
  local db, open_trouble = Sqlite.open(file)
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

--- `word` read from the directory `from`, unnormalized.
local function joined_to(from: string, word: string): string
  if word:sub(1, 1) == "/" then return word end
  return (from == "/" and "" or from) .. "/" .. word
end

--- `word`, read from `from`, as a path from `root`: absolute where it is
--- not within it.
local function from_root(word: string, from: string, root: string): string
  local absolute = narrow.lexical(joined_to(from, word))
  local relative, _ = Fs.relative(absolute, root)
  return relative or absolute
end

--- The tree a command line's verb runs in and its command line for it,
--- or nil when it runs where it was started.
--- @param argv the command line, the verb at slot 1
--- @param options the verb's options, as [`cosmic.cli`] names them in `verbs`
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
    root = narrow.lexical(joined_to(from, named))
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
      resolved = real or narrow.lexical(home)
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
