--- `cosmic docs` and `cosmic uses`: what the databases say about a symbol, as [`cosmic.doc`] reads the shipped
--- `docs`, `uses` and `links` tables, asked of every database the store searches and of a project's own
--- `cosmic.db` when the working directory holds one. What is the tool's alone is here: which databases those are,
--- the tool's verbs as the commands a page shows the options of, and who may require a module of the tree.

local build_paths = require("build.paths")
local Cli = require("cosmic.cli")
local Clock = require("cosmic.clock")
local Doc = require("cosmic.doc")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local AnalysisSchema = require("build.analysis_schema")
local clock = require("build.clock")
local narrow = require("build.narrow")
local positions = require("build.positions")
local symbols = require("cosmic.internal.symbols")
local tree = require("build.tree")

local logger = require("build.logger")
local log = logger.log
local bind = require("build.bind")
local verb_spec = require("build.verb_spec")
-- Declares what text this module reads ([`build.code_walk`]'s `markers`): all.
local _ = require("build.reads.all")

local record docs
  --- The verbs' registrations: see build/verb_spec.tl.
  mut spec: verb_spec.Spec
  mut uses_spec: verb_spec.Spec
  --- The databases a lookup reads, in order, and which of them, by
  --- index, are public sources: what `view` takes.
  record Sources
    handles: {Sqlite.Handle}
    public: {boolean}
    --- The handles `databases` opened itself, which its caller closes;
    --- the store's own are not among them.
    opened: {Sqlite.Handle}
  end
  --- What a caller already knows of the project `databases` reads, so it
  --- looks at none of the project's paths: its build directory, nil
  --- where it has none, and whether it is cosmic's own tree.
  record Known
    directory: string?
    own_tree: boolean
  end
end

local text = bind.text

--- Says once a process, on stderr, that the projection at `path`, which
--- `other` wrote ([`writer.other_code`]), is read none of. `root` is the
--- project it belongs to, where that is known: the directory to build in.
local function tell_other_code(path: string, other: string, root: string?)
  if not require("build.work").first_time("projection other_code " .. other, path) then return end
  local remedy = "`cosmic test` in the project writes it again"
  local whose = path
  if root ~= nil then
    remedy = "`cd " .. root .. " && cosmic test` writes it again"
    whose = root .. "'s build, " .. path
  end
  log:complain(whose .. " was written by " .. other .. "; reading none of it, which this " ..
      "tool's code may misread, and answering from this tool's own databases: " .. remedy)
end

--- Says once a process, on stderr, that the projection at `path` is read
--- none of, which code wrote it being unread for `trouble`.
local function tell_unread_code(path: string, trouble: string)
  if not require("build.work").first_time("projection other_code unread", path) then return end
  log:complain(path .. ": reading which code wrote it: " .. trouble .. "; reading none of it, " ..
      "and answering from this tool's own databases")
end

--- The databases a lookup reads, in order: the project's own
--- `cosmic.db` when there is one, then every database the store
--- searches. A module found in an earlier one hides the same module in
--- a later one, so a project's build answers for its own modules and
--- the binary answers for the standard library. The project's own is
--- left out where other code than this process's wrote it
--- ([`writer.other_code`]), as where it cannot be read.
--- @param store the store's databases, [`Store.databases()`] unless the
--- caller hands it others, as a test of databases of its own does
--- @param at the project's directory, the working directory when nil
--- @param known what the caller knows of the project, which `at` is then
---   not read for
function docs.databases(store?: {Sqlite.Handle}, at?: string, known?: docs.Known): docs.Sources
  local out: mut {Sqlite.Handle} = {}
  local public: mut {boolean} = {}
  local opened: mut {Sqlite.Handle} = {}
  local directory: string? = nil
  local own_tree = false
  local project: string? = nil
  if known ~= nil then
    directory, own_tree = known.directory, known.own_tree
  else
    local root, root_trouble = Fs.absolute(at or ".")
    assert(root ~= nil, tostring(root_trouble))
    project = root
    -- A directory with no build directory to have one in has no build of
    -- its own; one whose build directory cannot be named is answered from
    -- the binary's databases too, as a stale build is below.
    local optional, _ = build_paths.optional(root)
    directory = optional
    local standing, tree_trouble = tree.standing(root)
    assert(standing ~= nil, tree_trouble)
    own_tree = standing.own
  end
  local own_path = build_paths.under(directory or "/nonexistent").projection
  local own_exists = false
  if directory ~= nil then
    local exists = assert(Fs.status(own_path)).exists
    own_exists = exists
  end
  if own_exists then
    -- The project's own build is best effort: one that cannot be opened
    -- or read (a directory, a file that is not a database, one a build
    -- is rewriting) is left out, so help and docs still answer from the
    -- binary's own databases rather than failing on a stale output.
    local own, _ = Sqlite.open(own_path)
    if own ~= nil then
      local readable, _ = Doc.documented(own)
      -- One written by other code than this process runs is left out
      -- too, said once: what that code wrote may mean other than this
      -- code takes it to.
      if readable ~= nil then
        local other, other_trouble = require("build.writer").other_code(own, require("build.rebuild").compiled_by())
        if other ~= nil then tell_other_code(own_path, other, project) end
        if other == nil and other_trouble ~= "" then tell_unread_code(own_path, other_trouble) end
        if other ~= nil or other_trouble ~= "" then readable = nil end
      end
      if readable == nil then
        local _, _ = own:close()
      else
        out[#out + 1] = own
        public[#public + 1] = false
        opened[#opened + 1] = own
      end
    end
  end
  -- Outside cosmic's own tree the store's databases are public sources:
  -- a project sees its own code and the standard library, never the
  -- build that made the binary.
  local outside = not own_tree
  for _, db in ipairs(store or Store.databases()) do
    out[#out + 1] = db
    public[#public + 1] = outside
  end
  return { handles = out, public = public, opened = opened }
end

--- Who alone may require each module of the tree `db` holds, as [`Doc.Summary`]'s `closed` says it, by module: a
--- module of the `module` kind only, since a guide, a test or a program is required by none, and none the database
--- records as public ([`symbols.public_modules`]); absent for one any module may require. A module at
--- `cosmic/internal/` is always the standard library's (a project may not define
--- `cosmic.*`), so it is judged as cosmic's own tree judges it. A mark is a hint, not the build's refusal: one that
--- cannot be judged, the database or the module's source not being read, is left off.
local function closed_in(db: Sqlite.Handle): {string: string}
  local out: mut {string: string} = {}
  local rows, _ = db:text_rows("SELECT path, file, kind FROM modules", {})
  if rows == nil then
    return out
  end
  local files: mut {string} = {}
  for _, row in ipairs(rows) do files[#files + 1] = row:text(2) end
  local entries = positions.entries(files)
  local read, _ = symbols.public_modules(db)
  local recorded = read or {}
  for _, row in ipairs(rows) do
    local module, file = row:text(1), row:text(2)
    -- What the database records as public any module may require, so it has no mark to judge.
    if row:text(3) == "module" and recorded[module] ~= true then
      -- Only a module of a closed directory is asked, so few sources are inflated. One whose source cannot be read, or
      -- is not held (a row written without it), cannot be judged, and counts as open, which leaves its mark off.
      local reach = positions.reach(file, entries, function(): boolean
        local sources, _ = db:text_rows(
          "SELECT CAST(inflate(source) AS TEXT) FROM modules WHERE path = ?1 AND length(source) > 0",
          { text(module) })
        return sources == nil or #sources == 0 or AnalysisSchema.declares_public(sources[1]:text(1))
      end, true)
      if reach ~= nil then
        local rule = if reach.internal then "internal to " else "private to " end
        out[module] = rule .. reach.within .. "/"
      end
    end
  end
  return out
end

--- The tool's verbs as the commands of a view: each is documented by its field of [`cosmic.cli`]'s record, and
--- its options are data (a `spec` of [`Cli.verbs`]), shown and searched as the binary answering has them.
local function verbs(): {Doc.Command}
  local names: mut {string} = {}
  for verb in pairs(Cli.verbs) do names[#names + 1] = verb end
  table.sort(names)
  local out: mut {Doc.Command} = {}
  for _, verb in ipairs(names) do
    local command = assert(Cli.verbs[verb])
    local spec = command.spec
    local options = if spec ~= nil then Flags.options(spec) else nil end
    out[#out + 1] = { name = verb, module = "cosmic.cli", symbol = "Cli." .. verb, options = options }
  end
  return out
end

--- [`Doc.view`] over `databases` as the tool asks it: with the tool's verbs for its commands and the modules of
--- a tree marked by who may require them ([`closed_in`]).
--- @param public which databases, by index, are public sources
function docs.view(databases: {Sqlite.Handle}, public?: {boolean}): Doc.View?, string
  local view, trouble = Doc.view(databases, public)
  if view == nil then
    return nil, tostring(trouble)
  end
  view.commands = verbs()
  view.marks = closed_in
  return view, ""
end

--- What a lookup's summary says of the answer where its build did not
--- leave the projection as the tree stands ([`rebuild.here`]), "" where it
--- did: from the last build, or from cosmic's own docs alone where the
--- project has none this tool reads, and why -- the tree's refusal, or
--- another run holding the build ([`rebuild.held`]). The tree's refusal is said there alone, in
--- the summary a reader sees beside the answer; any other trouble is said
--- on a line of its own too, being the host's rather than the tree's.
--- @param sources the databases the lookup reads ([`docs.databases`])
local function stale_note(verb: string, built: boolean, trouble: string, sources: docs.Sources): string
  local why = trouble
  if built then
    why = require("build.rebuild").held()
    if why == "" then return "" end
  elseif #require("build.rebuild").refused() == 0 then
    log:complain(verb .. ": not rebuilt: " .. trouble)
    why = "not rebuilt"
  end
  local from = if #sources.opened > 0 then "from the last build"
    else "from cosmic's own docs, there being no build of the tree by this tool" end
  return from .. " (" .. why .. ")"
end

--- `cosmic docs <words...>`: prints what [`Doc.answer`] says of the
--- words, then its summary on stderr; fails when a word finds nothing.
--- With `--json` it prints [`Doc.records`] instead.
local function run(argv: {string}): integer
  local parsed, parse_trouble = Flags.parse(argv, 2, assert(assert(Cli.verbs["docs"]).spec))
  if parsed == nil then
    log:complain("docs: " .. parse_trouble)
    return 2
  end
  local exit = require("build.reboot").stale_exit(argv, true)
  if exit ~= nil then
    return exit
  end
  local built, build_trouble = require("build.rebuild").here("docs")
  local started = Clock.monotonic_ns()
  local sources = docs.databases()
  local stale = stale_note("docs", built, build_trouble, sources)
  local view, view_trouble = docs.view(sources.handles, sources.public)
  if view == nil then
    log:complain("docs: " .. view_trouble)
    return 1
  end
  if parsed.set["--json"] == true then
    local records, records_trouble = Doc.records(view, parsed.words, stale ~= "")
    if records == nil then
      log:complain("docs: " .. tostring(records_trouble))
      return 1
    end
    for _, line in ipairs(records.lines) do
      log:say(line)
    end
    -- The records have no summary but this one, for a stale answer, which a query that finds nothing hears too.
    if stale ~= "" then local _, _ = logger.summary("docs", "answered " .. stale) end
    return if records.found then 0 else 1 end
  end
  local answer, trouble = Doc.answer(view, parsed.words)
  if answer == nil then
    log:complain("docs: " .. tostring(trouble))
    return 1
  end
  for _, line in ipairs(answer.lines) do
    log:say(line)
  end
  local said = answer.said .. (if stale ~= "" then ", " .. stale else "" end)
  if not answer.found then
    local _, _ = logger.summary("docs", said .. ", " .. clock.took(started))
    return 1
  end
  local _, _ = logger.summary("docs", said .. ", " ..
      String.counted(#view.databases, "database") .. ", " .. clock.took(started))
  return 0
end

--- `cosmic uses <symbol> [path...]`: every place that refers to the
--- symbol, one `file:line` per line -- only those in a file under one
--- of the paths, when there are any -- then its summary on stderr. A link is
--- marked `link`; the symbol may be a file instead, which only links
--- name ([`doc/writing.md`], `doc/writing.md#every-example-runs`).
local function run_uses(argv: {string}): integer
  local parsed, parse_trouble = Flags.parse(argv, 2, {})
  if parsed == nil then
    log:complain("uses: " .. parse_trouble)
    return 2
  end
  local query = parsed.words[1] or ""
  if query == "" then
    log:complain("uses: which symbol? as declared (Fs.read) or by its last name (read), " ..
        "or which file (doc/writing.md, doc/writing.md#heading)")
    return 2
  end
  local exit = require("build.reboot").stale_exit(argv, true)
  if exit ~= nil then
    return exit
  end
  local built, build_trouble = require("build.rebuild").here("uses")
  local started = Clock.monotonic_ns()
  local sources = docs.databases()
  local stale = stale_note("uses", built, build_trouble, sources)
  if stale ~= "" then stale = ", " .. stale end
  local view, view_trouble = docs.view(sources.handles, sources.public)
  if view == nil then
    log:complain("uses: " .. view_trouble)
    return 1
  end
  local found, trouble = Doc.uses(view, query)
  if found == nil then
    log:complain("uses: " .. tostring(trouble))
    return 1
  end
  local words: mut {string} = {}
  for slot, word in ipairs(parsed.words) do
    if slot >= 2 then words[#words + 1] = word end
  end
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain("uses: " .. tostring(root_trouble))
    return 1
  end
  local paths = narrow.paths(root, words)
  local shown = 0
  for _, use in ipairs(found) do
    if narrow.holds(paths, use.from_file) then
      local target = if use.symbol ~= "" then use.module .. " " .. use.symbol else use.module end
      if use.link and use.module == "" then
        target = use.path .. (if use.anchor ~= "" then "#" .. use.anchor else "" end)
      end
      log:say(use.from_file .. ":" .. tostring(use.line) .. ": " .. (if use.link then "link " else "" end) .. target)
      shown = shown + 1
    end
  end
  if shown == 0 then
    local where = if #paths > 0 then " under " .. table.concat(paths, ", ") else "" end
    local _, _ = logger.summary("uses", "nothing" .. where .. " refers to '" .. query .. "'" .. stale .. ", " ..
        clock.took(started))
    return 1
  end
  local _, _ = logger.summary("uses", String.counted(shown, "place") .. stale .. ", " .. clock.took(started))
  return 0
end

--- The `docs` verb as [`build/verb_list.tl`] lists it.
docs.spec = {
  name = "docs",
  summarizes_failure = true,
  guide = "looking up a symbol and where it is used",
  tests = { "build.docs_test" },
  run = function(argv: {string}): integer return run(argv) end,
  bare = false,
  reads = true,
  takes = "words to search for",
}

--- The `uses` verb as [`build/verb_list.tl`] lists it.
docs.uses_spec = {
  name = "uses",
  summarizes_failure = true,
  guide = "looking up a symbol and where it is used",
  tests = { "build.docs_test" },
  run = run_uses,
  bare = false,
  reads = true,
  takes = "paths after its symbol",
}

return docs
