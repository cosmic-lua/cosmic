--- The build a read-only verb makes so it answers from the tree as it
--- stands: `docs` and `uses` read the projection, `cosmic.db`, which only a build
--- writes, so without this an edit is invisible to them until a
--- `cosmic test` or `cosmic fix` builds. It is the build `cosmic test`
--- makes (stage, compile, write the projection), and no more.

local build_paths = require("build.paths")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local clock = require("build.clock")
local importer = require("build.importer")
local shared_compiles = require("build.shared_compiles")
local teal = require("build.teal")
local tree = require("build.tree")
local work = require("build.work")
local workers = require("build.workers")
local writer = require("build.writer")
local log = require("build.logger").log
local type compiler = require("build.compiler")

local record rebuild
  --- What [`rebuild.stage`] finds of a directory ([`where`]).
  record Where
    --- Whether it is one to build ([`where`]).
    project: boolean
    --- Whether it is cosmic's own tree ([`tree.is_own`]).
    own_tree: boolean
    --- Its build directory, or nil where it can have none.
    directory: string | nil
    --- Whether [`rebuild.stage`] staged nothing, another run holding
    --- the working database.
    busy: boolean
    --- The schema [`rebuild.stage`] found the working database of, where
    --- it staged nothing, the file being of another schema than this
    --- tool's ([`work.try_open`]).
    other_schema: string | nil
    --- Whether [`rebuild.stage`] staged nothing, the check before the verb
    --- not having held the tool to the tree ([`reboot.unchecked`]): what
    --- its code derived could be older code's than the tree's.
    unchecked: boolean
  end
end

--- Whether a build was started with the build directory `directory`,
--- failed or not: it holds the working database, which every build opens
--- before it does anything else ([`work.open`]), or a projection. It
--- looks at nothing but those two files, and nothing outside the build
--- directory. Nil and why where it cannot tell.
function rebuild.started(directory: string): boolean | nil, string
  local layout = build_paths.under(directory)
  for _, path in ipairs({ layout.working, layout.projection }) do
    local there, trouble = Fs.exists(path)
    if there == nil then return nil, trouble end
    if there == true then return true, "" end
  end
  return false, ""
end

--- What the directory `root` is to a build: whether it is one to build,
--- whether it is cosmic's own tree, and its build directory. A project
--- is what `cosmic test` builds: cosmic's own tree, or a directory a build
--- has been started in, wherever it was run, failed or not. Every build
--- opens the working database before it does anything else
--- ([`work.open`]), so a build directory holding it, or a projection, is
--- one a build was started in. Anything else is left alone, whatever it
--- holds: a lookup never starts a tree of its own in a directory that has
--- a stray `.tl`, nor below the home directory.
local function where(root: string): rebuild.Where | nil, string
  local own, own_trouble = tree.is_own(root)
  if own == nil then return nil, own_trouble end
  local own_tree = own == true
  local directory, directory_trouble = build_paths.optional(root)
  if directory == nil then
    if directory_trouble ~= "" and not own_tree then return nil, directory_trouble end
    return { project = own_tree, own_tree = own_tree, directory = nil, busy = false,
      other_schema = nil, unchecked = false }, ""
  end
  local started, trouble = rebuild.started(directory)
  if started == nil then return nil, trouble end
  return { project = own_tree or started == true, own_tree = own_tree, directory = directory, busy = false,
    other_schema = nil, unchecked = false }, ""
end

--- Whether the check before the verb went on in the tree at `root`
--- without holding the tool to it ([`reboot.unchecked`]), so that what
--- this tool's code derives there could be older code's than the tree's.
--- Loaded only here: a stage or a lookup that reaches this is one the
--- check came before.
local function unchecked(root: string): boolean
  return require("build.reboot").unchecked(root)
end

--- The compiler identity a build in this process compiles under: the
--- one the build that made this binary recorded, or "" for one that
--- carries none. A project's rows are keyed by it, and a projection
--- records it as `compiled_by` ([`writer.other_code`]).
function rebuild.compiler(): string
  return Store.meta("compiler") or ""
end

--- Whether `root` looks like a project that has not been built: Teal at
--- its top, or a `cmd/`.
local function looks_unbuilt(root: string): boolean
  local top, _ = Fs.list(root)
  if top == nil then return false end
  for _, name in ipairs(top) do
    if name == "cmd" or String.ends_with(name, ".tl") then return true end
  end
  return false
end

--- `root`'s working database, opened as a build opens it, waiting for
--- another run that holds it, where `wait`; otherwise opened only where
--- no run holds it ([`work.try_open`]), with no handle where one does.
local function opened_for(root: string, wait: boolean): work.Opening | nil, string
  if not wait then return work.try_open(root) end
  local handle, trouble = work.open(root)
  if handle == nil then return nil, trouble end
  return { handle = handle, other_schema = nil }, ""
end

--- Builds the project at `root` as `cosmic test` does, leaving
--- its projection as the tree stands. It does nothing, answering true,
--- where `root` is not one to build ([`where`]) and `start` is not
--- set, saying so on stderr when it looks like a project no build has
--- been made of. Answers false and why when the build fails, which the
--- caller may say and go on from the last build. Only a build with
--- `start` waits for another run that holds the working database: a
--- lookup's does nothing where one does, which builds the same tree, but
--- say so once ([`work.tell_busy`]), and answers true, the caller reading
--- what that run last committed. Nor does a lookup's wait for a run that
--- holds the rebuild lock, a `cosmic test` run above all: it writes no
--- projection under it, says so once ([`rebuild_lock.try_hold`]), and
--- the caller reads the projection that is there. Where the check before
--- the verb went on without holding the tool to the tree
--- ([`reboot.unchecked`]), a lookup's builds nothing, and the caller reads
--- what is there.
local function project(root: string, verb: string, start: boolean): boolean, string
  local found, found_trouble = where(root)
  if found == nil then return false, found_trouble end
  if unchecked(root) then
    -- Compiled by code that may be older than the tree's, the rows and
    -- the projection would be keyed and signed as no build of the tree
    -- would make them.
    return true, ""
  end
  if not found.project and not start then
    if looks_unbuilt(root) then
      log:complain(verb .. ": this directory has not been built; `cosmic build` or `cosmic test` " ..
          "first to include its modules")
    end
    return true, ""
  end
  local own_tree = found.own_tree
  local started = Clock.monotonic_ns()
  local opening, open_trouble = opened_for(root, start)
  if opening == nil then return false, open_trouble end
  local handle = opening.handle
  if handle == nil then
    local working = build_paths.resolve(root).working
    local other = opening.other_schema
    if other ~= nil then
      work.tell_other_schema(verb, working, other)
    else
      work.tell_busy(verb, working)
    end
    return true, ""
  end
  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    local _, _ = work.close(handle)
    return false, stage_trouble
  end
  local result, compile_trouble = importer.compile(handle, teal.lazy(),
    rebuild.compiler(), false, shared_compiles.for_build(),
    workers.pool(workers.tool_spec()))
  if result == nil then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local _, _ = work.close(handle)
    return false, compile_trouble
  end
  -- A lookup's build leaves the projection as it is where another run
  -- holds the rebuild lock, rather than wait for it ([`writer.write_result`]).
  local reader: string | nil = nil
  if not start then reader = verb end
  local written, write_trouble = writer.write_recorded(handle,
    build_paths.resolve(root).projection, result, started, staged, reader)
  local _, _ = work.close(handle)
  if not written then return false, write_trouble end
  return true, ""
end

--- Stages the project at `root` and derives what a parse finds of each
--- source, as a build does before it compiles ([`work.stage`],
--- [`importer.derive`]), so the working database's `inputs` rows and the
--- `stubs` of their sources are the tree as it stands: no compile, no
--- projection. `built` parses what is new. A directory that is no
--- project ([`where`]) is left alone: nothing is staged, and no
--- build directory is made. A derive that fails leaves the database as
--- it was, stage and all. Where the check before the verb went on
--- without holding the tool to the tree ([`reboot.unchecked`]), nothing
--- is staged, for the life of the process, and what it answers is
--- `unchecked`. Otherwise it waits for no other run: where one holds the
--- database ([`work.try_open`]), nothing is staged, and what it answers
--- is `busy`; where the database is of another schema, nothing is staged
--- and none of it read, and what it answers names that schema. Answers
--- what the directory is, or nil and why it could not be staged.
function rebuild.stage(root: string, built: compiler): rebuild.Where | nil, string
  local found, found_trouble = where(root)
  if found == nil then return nil, found_trouble end
  if not found.project then return found, "" end
  if unchecked(root) then
    return { project = true, own_tree = found.own_tree, directory = found.directory,
      busy = false, other_schema = nil, unchecked = true }, ""
  end
  local opening, open_trouble = work.try_open(root)
  if opening == nil then return nil, open_trouble end
  local handle = opening.handle
  if handle == nil then
    local other = opening.other_schema
    return { project = true, own_tree = found.own_tree, directory = found.directory,
      busy = other == nil, other_schema = other, unchecked = false }, ""
  end
  local staged, stage_trouble = work.stage(handle, found.own_tree)
  if staged == nil then
    local _, _ = work.abort(handle)
    return nil, stage_trouble
  end
  local shared = shared_compiles.for_build()
  local pool = workers.pool(workers.tool_spec())
  local parses, derive_trouble = importer.derive(handle, found.own_tree, built, shared, pool)
  if shared ~= nil then shared.finish() end
  pool.close()
  if parses == nil then
    local _, _ = work.abort(handle)
    return nil, derive_trouble
  end
  local closed, close_trouble = work.close(handle)
  if not closed then return nil, close_trouble end
  return found, ""
end

--- Builds the project at `root`, the working directory by default, as
--- `project` does, for the verb `verb`, which names itself in what it
--- says: a lookup's, which waits for no other run. With `start`, it
--- builds one no build has been made of yet too, and waits for another
--- run as a build does: `cosmic fix`, which stages and compiles the
--- directory to check it whatever it holds ([`build.fix.spill`]), so
--- that what its links name is the tree as it stands rather than
--- whatever an earlier `cosmic test` left.
function rebuild.here(verb: string, start?: boolean, root?: string): boolean, string
  local at = root
  if at == nil then
    local found, trouble = Fs.absolute(".")
    if found == nil then return false, trouble end
    at = found
  end
  return project(at, verb, start == true)
end

return rebuild
