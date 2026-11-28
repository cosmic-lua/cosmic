--- A patch applied to a directory tree, as `patch -p1` does, with the checks a patch from elsewhere needs.
---
---     local entries = assert(Diff.parse(text, { strip = 1 }))
---     local result = assert(Patch.apply("/srv/work", entries))
---     if not result.applied then -- a hunk did not fit: nothing was written
---       for _, file in ipairs(result.files) do print(file.path, #file.rejects) end
---     end
---
--- Every name in the patch is a path under the root, and nothing else: an absolute name, one with a `..`
--- part, a `\` or a NUL byte, or one that goes through a symbolic link is a failure before anything is
--- written. A link at the last part is a failure too, and a patch that makes a link (mode 120000) or a
--- submodule (160000) is refused. A file is read and written through directory descriptors opened from the
--- root one part at a time ([`Fs.Dir`]), so a link planted while a patch applies is met, not followed. The
--- root itself may be a link: it is resolved once.
---
--- The whole patch is worked out in memory first. One hunk that does not fit, a file that is not there, or a
--- file that is in the way leaves the tree as it was: unlike `patch`, which leaves the files it did apply.
--- Only then are the files written, each through a temporary neighbor and a rename. A write that fails part
--- way leaves the files already written; the tree has no more than that to undo.
---
--- Nothing may change the tree while a patch applies: the check of a name and its use are two steps. The
--- removal of a file and the `chmod` of a written one name their path again, so a directory swapped for a link
--- between the check and the call is followed by those two.
---
--- A name with a `.git` part is refused, since a hook or a config written there runs later. Directories a
--- delete or an undo empties stay.

local Diff = require("cosmic.diff")
local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")

local record Patch
  --- What [`Patch.apply`] takes.
  record Options
    --- Context lines at each end of a hunk that may differ, as [`Diff.ApplyOptions.fuzz`]: 0 unless given.
    fuzz?: integer
    --- Undo the patch instead of doing it.
    reverse?: boolean
    --- Work everything out but write nothing.
    dry_run?: boolean
  end

  --- What happened to one entry of the patch.
  record File
    --- Which entry, from 1.
    entry: integer
    --- The path under the root the entry works on: the new path of a rename or copy.
    path: string
    --- How the file changes, after any reversal.
    kind: Diff.Kind
    --- The hunks placed, as [`Diff.Applied.placed`].
    placed: {Diff.Placed}
    --- The hunks that did not fit, as [`Diff.Applied.rejects`].
    rejects: {Diff.Reject}
    --- Why the entry cannot be done, when it is not a hunk: the file is missing, or in the way.
    problem?: string
  end

  --- What [`Patch.apply`] returns.
  record Result
    --- True when every entry was done: no reject and no problem. When false nothing was written.
    applied: boolean
    --- One for each entry, in order.
    files: {File}
    --- True when the files were written (not a dry run, and `applied`).
    written: boolean
  end
end

--- A file's content as the patch leaves it.
local record Content
  text: string
  mode: integer
end

--- The names of `path` as parts, or nil and why it is no path under a root.
local function parts_of(path: string): ({string}) | (nil, Failure)
  if path == "" then return nil, Failure.new("patch: a file name is empty") end
  if path:byte(1) == 47 then
    return nil, Failure.new("patch: " .. path .. " is an absolute name", path)
  end
  if path:find("[%z\\]") ~= nil or path:find("^%a:") ~= nil then
    return nil, Failure.new("patch: " .. path .. " is not a plain relative name", path)
  end
  local out: mut {string} = {}
  for segment in (path .. "/"):gmatch("([^/]*)/") do
    if segment == ".." then
      return nil, Failure.new("patch: " .. path .. " leaves the root", path)
    end
    if segment:lower() == ".git" then
      return nil, Failure.new("patch: " .. path .. " is inside .git, which holds hooks", path)
    end
    if segment ~= "" and segment ~= "." then out[#out + 1] = segment end
  end
  if #out == 0 then return nil, Failure.new("patch: " .. path .. " names no file", path) end
  return out
end

--- The directories opened for one run, closed together.
local record Tree
  root: Fs.Dir
  opened: mut {string: Fs.Dir}
end

--- Where a path's last part sits: the directory holding it, nil when a directory above is missing.
local record Place
  holder: Fs.Dir?
  name: string
end

--- The directory that holds `parts`, opened by hand from the root. With `make`, a missing directory is made;
--- without it, a missing one gives a Place with no holder. A link on the way, or a part that is no directory,
--- is a failure.
local function place(tree: Tree, parts: {string}, make: boolean): (Place) | (nil, Failure)
  local current = tree.root
  local key = ""
  for i = 1, #parts - 1 do
    local name = assert(parts[i])
    key = key .. "/" .. name
    local known = tree.opened[key]
    if known ~= nil then
      current = known
    else
      local status, status_why = current:status(name)
      if status == nil then return nil, status_why end
      if not status.exists then
        if not make then return { holder = nil, name = assert(parts[#parts]) } end
        local made, why = current:mkdir(name)
        if made == nil then return nil, why end
      elseif not status.is_dir then
        return nil, Failure.new("patch: " .. current.path .. "/" .. name .. " is not a directory", current.path .. "/" .. name)
      end
      local opened, why = current:dir(name)
      if opened == nil then return nil, why end
      tree.opened[key] = opened
      current = opened
    end
  end
  return { holder = current, name = assert(parts[#parts]) }
end

--- The file at `parts` as it is on disk: nil content where it is not there. A link, a directory or any other
--- kind of file is a failure: only a regular file is patched.
local function on_disk(tree: Tree, parts: {string}): (Content | boolean) | (nil, Failure)
  local at, why = place(tree, parts, false)
  if at == nil then return nil, why end
  local holder = at.holder
  if holder == nil then return false end
  local status, trouble = holder:status(at.name)
  if status == nil then return nil, trouble end
  if not status.exists then return false end
  local stat = assert(status.stat)
  if stat.kind ~= "file" then
    return nil, Failure.new("patch: " .. holder.path .. "/" .. at.name .. " is a " .. stat.kind .. ", not a file", holder.path .. "/" .. at.name)
  end
  local text, read_why = holder:read(at.name)
  if text == nil then return nil, read_why end
  return { text = text, mode = stat.mode & 0x1ff }
end

--- The mode `written` names as permission bits, never setuid, setgid or sticky: nil when it names none.
local function mode_of(written: string?): integer?
  if written == nil then return nil end
  local number = math.tointeger(tonumber(written, 8))
  if number == nil then return nil end
  return number & 0x1ff
end

--- A mode that makes no file: a link or a submodule.
local function refused_mode(written: string?): boolean
  return written ~= nil and (written:sub(1, 2) == "12" or written:sub(1, 2) == "16")
end

--- `entry` with the two sides swapped, so that undoing it is doing the flipped entry with reversed hunks.
local function flipped(entry: Diff.Entry): Diff.Entry
  local kind: Diff.Kind = entry.kind
  if kind == "create" then
    kind = "delete"
  elseif kind == "delete" then
    kind = "create"
  end
  return {
    kind = kind,
    old_name = entry.new_name,
    new_name = entry.old_name,
    old_mode = entry.new_mode,
    new_mode = entry.old_mode,
    hunks = entry.hunks,
  }
end

--- The paths an entry works on: the one it reads and the one it writes. Each is nil where the entry has none.
local record Route
  from: string?
  to: string?
end

local function route_of(entry: Diff.Entry): Route
  if entry.kind == "create" then return { from = nil, to = entry.new_name } end
  if entry.kind == "delete" then return { from = entry.old_name, to = nil } end
  if entry.kind == "modify" then
    local one = entry.old_name or entry.new_name
    return { from = one, to = one }
  end
  return { from = entry.old_name, to = entry.new_name }
end

--- `path` in one spelling, so `f`, `./f` and `d//f` are one key.
local function normal(path: string): (string) | (nil, Failure)
  local parts, why = parts_of(path)
  if parts == nil then return nil, why end
  return table.concat(parts, "/")
end

--- The tree's file at `path` as the patch has it so far: the overlay first, then the disk.
local function current(tree: Tree, overlay: {string: Content | boolean}, path: string): (Content | boolean) | (nil, Failure)
  local held = overlay[path]
  if held ~= nil then return held end
  local parts, why = parts_of(path)
  if parts == nil then return nil, why end
  return on_disk(tree, parts)
end

--- Writes what the overlay holds. Parents are made as needed; a file is removed only if it is there.
local function write_out(tree: Tree, order: {string}, overlay: {string: Content | boolean}): (true) | (nil, Failure)
  for _, path in ipairs(order) do
    local parts = assert(parts_of(path))
    local held = overlay[path]
    if type(held) == "table" then
      local at, why = place(tree, parts, true)
      if at == nil then return nil, why end
      local holder = assert(at.holder)
      local written, write_why = holder:write(at.name, held.text, held.mode)
      if written == nil then return nil, write_why end
      -- `write` honours the umask: a mode the patch names is set outright.
      local chmod, chmod_why = Fs.chmod(holder.path .. "/" .. at.name, held.mode)
      if chmod == nil then return nil, chmod_why end
    end
  end
  for _, path in ipairs(order) do
    local parts = assert(parts_of(path))
    if overlay[path] == false then
      local at, why = place(tree, parts, false)
      if at == nil then return nil, why end
      local holder = at.holder
      if holder ~= nil then
        local status, trouble = holder:status(at.name)
        if status == nil then return nil, trouble end
        if status.exists then
          local removed, remove_why = Fs.remove(holder.path .. "/" .. at.name)
          if removed == nil then return nil, remove_why end
        end
      end
    end
  end
  return true
end

--- What a run holds while it works the entries out.
local record Run
  tree: Tree
  overlay: mut {string: Content | boolean}
  order: mut {string}
  options: Patch.Options
end

--- Sets `path` in the run's overlay, noting the order paths are first touched.
local function touch(run: Run, path: string, value: Content | boolean)
  if run.overlay[path] == nil then run.order[#run.order + 1] = path end
  run.overlay[path] = value
end

--- Why a file cannot be written at `path` beside the files the patch makes: a file where a directory is
--- needed, or a directory where the file goes. Nil when nothing clashes.
local function clash_with(run: Run, path: string): string?
  local here = ""
  for part in (path .. "/"):gmatch("([^/]*)/") do
    here = if here == "" then part else here .. "/" .. part end
    if here ~= path and type(run.overlay[here]) == "table" then
      return here .. " is a file, and " .. path .. " goes under it"
    end
  end
  for _, other in ipairs(run.order) do
    if type(run.overlay[other]) == "table" and other:sub(1, #path + 1) == path .. "/" then
      return path .. " is a file, and " .. other .. " goes under it"
    end
  end
  return nil
end

--- Works one entry out against the run's overlay. A file with a problem or a reject changes nothing.
local function plan(run: Run, index: integer, given: Diff.Entry): (Patch.File) | (nil, Failure)
  local entry = if run.options.reverse == true then flipped(given) else given end
  if run.options.reverse == true and given.kind == "copy" then
    -- Undoing a copy removes the copy; the source stays.
    entry = { kind = "delete", old_name = given.new_name, hunks = {} }
  end
  if refused_mode(entry.new_mode) or refused_mode(entry.old_mode) then
    return nil, Failure.new("patch: entry " .. tostring(index) .. " makes a link or a submodule, which a patch does not")
  end
  local route = route_of(entry)
  if (entry.kind ~= "create" and route.from == nil) or (entry.kind ~= "delete" and route.to == nil) then
    return nil, Failure.new("patch: entry " .. tostring(index) .. " lacks a file name")
  end
  local from: string? = nil
  local to: string? = nil
  if route.from ~= nil then
    local key, key_why = normal(route.from)
    if key == nil then return nil, key_why end
    from = key
  end
  if route.to ~= nil then
    local key, key_why = normal(route.to)
    if key == nil then return nil, key_why end
    to = key
  end
  local name = to or from or ""
  local source_text = ""
  local source_mode = 0x1a4 -- 0644
  if from ~= nil then
    local found, why = current(run.tree, run.overlay, from)
    if found == nil then return nil, why end
    if found == false then
      return { entry = index, path = name, kind = entry.kind, placed = {}, rejects = {}, problem = "no file " .. from }
    end
    if type(found) == "table" then
      source_text = found.text
      source_mode = found.mode
    end
  end
  if to ~= nil and entry.kind ~= "modify" then
    local found, why = current(run.tree, run.overlay, to)
    if found == nil then return nil, why end
    if found ~= false then
      return { entry = index, path = name, kind = entry.kind, placed = {}, rejects = {}, problem = to .. " is already there" }
    end
  end
  local outcome = Diff.apply(source_text, entry.hunks, { fuzz = run.options.fuzz, reverse = run.options.reverse })
  local file: Patch.File = { entry = index, path = name, kind = entry.kind, placed = outcome.placed, rejects = outcome.rejects }
  if outcome.text == nil then return file end
  if entry.kind == "delete" and from ~= nil then
    if outcome.text ~= "" and #entry.hunks > 0 then
      return { entry = index, path = name, kind = entry.kind, placed = outcome.placed, rejects = {},
        problem = from .. " still has lines after the patch deletes it" }
    end
    touch(run, from, false)
    return file
  end
  if to == nil then
    return nil, Failure.new("patch: entry " .. tostring(index) .. " lacks a file name")
  end
  local clash = clash_with(run, to)
  if clash ~= nil then
    return { entry = index, path = name, kind = entry.kind, placed = outcome.placed, rejects = {}, problem = clash }
  end
  if entry.kind == "rename" and from ~= nil and from ~= to then touch(run, from, false) end
  touch(run, to, { text = outcome.text, mode = mode_of(entry.new_mode) or source_mode })
  return file
end

--- Closes every directory a run opened.
local function close_all(tree: Tree)
  for _, opened in pairs(tree.opened) do opened:close() end
  tree.root:close()
end

--- Works every entry out and, when all fit, writes them.
local record Outcome
  result?: Patch.Result
  failure?: Failure
end

local function run_entries(run: Run, entries: {Diff.Entry}): Outcome
  local files: mut {Patch.File} = {}
  local fit = true
  for index, entry in ipairs(entries) do
    local file, plan_why = plan(run, index, entry)
    if file == nil then return { failure = plan_why } end
    if file.problem ~= nil or #file.rejects > 0 then fit = false end
    files[#files + 1] = file
  end
  local written = false
  if fit and run.options.dry_run ~= true then
    local ok, write_why = write_out(run.tree, run.order, run.overlay)
    if ok == nil then return { failure = write_why } end
    written = true
  end
  return { result = { applied = fit, files = files, written = written } }
end

--- Applies the entries of a parsed patch to the tree under `root`; see the module's notes.
---
--- Nil and a [`Failure`] for a name that is no path under the root, a link on a path, a file that is not a
--- regular file, a patch that makes a link or a submodule, or a read or write that fails. A hunk that does
--- not fit is in the result, not a failure.
function Patch.apply(root: string, entries: {Diff.Entry}, opts?: Patch.Options): (Patch.Result) | (nil, Failure)
  -- The root may be a link, or sit under one (`/tmp` is on macOS): it is resolved once, here.
  local real, real_why = Fs.absolute(root)
  if real == nil then return nil, real_why end
  local held, why = Fs.dir(real)
  if held == nil then return nil, why end
  local run: Run = { tree = { root = held, opened = {} }, overlay = {}, order = {}, options = opts or {} }
  local ok, outcome = pcall(run_entries, run, entries)
  close_all(run.tree)
  if not ok then error(outcome, 0) end
  if outcome.result ~= nil then return outcome.result end
  return nil, assert(outcome.failure)
end

return Patch
