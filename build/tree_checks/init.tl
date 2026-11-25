--- The checks over cosmic's whole tree, which no one module's test can
--- make: every type an API names a member of its
--- module, no two doc anchors sharing a name, every
--- reader of the compiler's identity named, every familiar command
--- finding what stands in for it, every docs query a compile advertises
--- resolved, every quieted method one a module declares, every member
--- kept to a few files used by those alone, every
--- declaration's requires declared, every requirement a test module
--- declares promised by a CI leg, every verb's spec listed and
--- readable, no public doc citing the build or carrying a TODO, no
--- literal plural after a number, no test returning early (a skip is [`Test.skip`]), every file under ci/testdata
--- type-checking standalone, and every `.tl` file scoping, lowering and checking in the new checker's grammar but for
--- what the markers hold. Each asks the tree's projection,
--- `cosmic.db`, which holds every module's docs, uses, imports,
--- examples and source.
---
--- A test reads its own module's closure and no more (the rule the
--- suite's `store` declaration is kept to), so these are not tests.
--- `cosmic fix` runs them when it covers all of cosmic's own tree
--- (`cosmic fix --check .`, which CI runs), after building the
--- projection afresh (`projection`), and each line a check returns
--- fails the run. A `cosmic fix` of some paths does not run them, and a
--- tree that does not build fails them all.
---
--- Each check takes the projection and, optionally, what it holds the
--- tree to (the anchors expected, the exemptions, ...), which defaults to the
--- tree's own, so its test can hand it a fixture database and a list of
--- its own.

local type tree_standing = require("build.tree")
local build_paths = require("build.paths")
local work_schema = require("build.work_schema")
local c_functions = require("build.c_functions")
local Ceilings = require("build.ceilings")
local CeilingsBase = require("build.ceilings_base")
local check_memo = require("build.check_memo")
local Clock = require("cosmic.clock")
local docs_checks = require("build.docs_checks")
local Env = require("cosmic.env")
local example_checks = require("build.example_checks")
local fanout = require("build.compile_fanout")
local Fs = require("cosmic.fs")
local help_source = require("build.help_source")
local logger = require("build.logger")
local Memprobe = require("build.memprobe")
local Proc = require("cosmic.proc")
local progress = require("build.progress")
local Sqlite = require("cosmic.sqlite")
local Ast = require("lang.ast")
local tree_build = require("build.tree_checks.build")
local tree_checked = require("build.tree_checks.checked")
local tree_ci = require("build.tree_checks.ci")
local tree_common = require("build.tree_checks.common")
local tree_declares = require("build.tree_checks.declares")
local tree_docs = require("build.tree_checks.docs")
local tree_readers = require("build.tree_checks.readers")
local tree_tests = require("build.tree_checks.tests")

local log = logger.log

local record tree_checks
  --- What [`tree_checks.read_off`] keeps of a file's parse for the plurals check: the plurals found in one text.
  type Plurals = tree_docs.Plurals

  --- What a run of every check of the tree is given ([`tree_checks.whole`]).
  record Whole
    --- The root of cosmic's own tree.
    root: string
    standing: tree_standing.Standing
    --- The plurals `cosmic fix` found in the files it parsed ([`tree_checks.read_off`]), by path from the root.
    plurals?: {string: Plurals}
    --- Whether the run leaves the stale markers for the caller to remove, rather than naming them as findings.
    mends: boolean
  end

  --- What a run of every check of the tree found.
  record Found
    --- Each finding, prefixed with the check's name.
    lines: {string}
    --- The markers no finding needs any more, which `cosmic fix` removes where `mends` was set.
    sink: Ceilings.Sink
  end
end

--- One check of the projection: the name that prefixes each line it finds, and the check over the projection (`on`) and
--- the database of what `cosmic docs` shows (`shown`).
local record Check
  name: string
  run: function(on: Sqlite.Handle, shown: Sqlite.Handle, given: Given): {string}
end

--- What [`tree_checks.run`] passes each check besides the databases.
local record Given
  quickstart: string?
  extra: {{string}}?
  help: {string: string}?
  read: {string: tree_checks.Plurals}?
end

--- The checks of the projection, slowest first, so the copies' shares are near alike.
local checks: {Check} = {
  { name = "rendered docs", run = function(_on: Sqlite.Handle, shown: Sqlite.Handle, _g: Given): {string}
    return docs_checks.rendered(shown)
  end },
  { name = "doc references", run = function(_on: Sqlite.Handle, shown: Sqlite.Handle, g: Given): {string}
    return docs_checks.references(shown, g.help)
  end },
  { name = "public docs", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, _g: Given): {string}
    return tree_docs.public_docs(on)
  end },
  { name = "compiler readers", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, _g: Given): {string}
    return tree_readers.meta_readers(on, "compiler")
  end },
  { name = "doc anchors", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, _g: Given): {string}
    return tree_docs.anchors(on)
  end },
  { name = "plurals", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, g: Given): {string}
    return tree_docs.plurals(on, g.extra, nil, g.read)
  end },
  { name = "image_hash readers", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, _g: Given): {string}
    return tree_readers.meta_readers(on, "image_hash")
  end },
  { name = "text readers", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, _g: Given): {string}
    return tree_readers.text_readers(on)
  end },
  { name = "stand-ins", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, _g: Given): {string}
    return tree_readers.stand_ins(on)
  end },
  { name = "build directory", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, _g: Given): {string}
    return tree_readers.build_directory(on)
  end },
  { name = "unnamed types", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, _g: Given): {string}
    return tree_docs.unnamed_types(on)
  end },
  { name = "verbs", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, g: Given): {string}
    return tree_docs.verbs(on, g.quickstart)
  end },
  { name = "docs queries", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, _g: Given): {string}
    return tree_docs.queries(on)
  end },
  { name = "declarations", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, _g: Given): {string}
    return tree_declares.declarations(on)
  end },
  { name = "restricted", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, _g: Given): {string}
    return tree_declares.restricted(on)
  end },
  { name = "quieted", run = function(on: Sqlite.Handle, _s: Sqlite.Handle, _g: Given): {string}
    return tree_declares.quieted(on)
  end },
}

--- The names of [`checks`] in the order their lines are printed, whichever process ran each.
local printed <const>: {string} = { "text readers", "image_hash readers", "unnamed types", "doc anchors",
  "compiler readers", "build directory", "stand-ins", "docs queries", "quieted", "restricted", "declarations",
  "verbs", "rendered docs", "doc references", "public docs", "plurals" }

--- What one copy of [`run`]'s fan holds beyond the process it was forked from, as [`fanout.copies`] counts it: its own
--- connections to the projection and what its checks read of it.
local run_copy_bytes <const> = 256 * 1024 * 1024

--- Every check over the projection `db`, each line one failure,
--- prefixed with the check's name; none when the tree passes them all.
--- The plurals are checked with `extra` sources besides the projection's.
--- @param carried the database a release binary carries of `db`
---   ([`build.docs_checks`]' `carried`), which the checks of what `cosmic
---   docs` shows read; `db` itself when not given
--- @param help what `cosmic help` prints ([`build.help_source`]' `texts`),
---   whose references are checked with the docs'; none when not given
--- @param read the plurals already found in files' texts, as [`tree_checks.read_off`] keeps them
--- @param reopen where given, opens `db` and `carried` again for a copy of the process ([`build.compile_fanout`]), which
---   cannot use the process's own connections: the checks then run in copies, each its share, and a copy that does not
---   end well leaves its checks to the process. The lines are the same either way.
function tree_checks.run(db: Sqlite.Handle, quickstart: string?, extra?: {{string}}, carried?: Sqlite.Handle,
                         help?: {string: string}, read?: {string: tree_checks.Plurals},
                         reopen?: function(): Sqlite.Handle?, Sqlite.Handle?): {string}
  local given: Given = { quickstart = quickstart, extra = extra, help = help, read = read }
  local by_name: mut {string: Check} = {}
  for _, check in ipairs(checks) do by_name[check.name] = check end
  local found: mut {string: {string}} = {}
  local copies = if reopen ~= nil then fanout.copies(#checks, Proc.cpu_count(), run_copy_bytes, nil, 2) else 0 end
  local dir: string? = nil
  if copies > 0 then
    local made, _ = Fs.mkdtemp("cosmic-tree-checks-")
    dir = made
  end
  if dir ~= nil and reopen ~= nil then
    local ran = fanout.run(copies, function(copy: integer)
      local own, own_docs = reopen()
      local on = assert(own, "the projection does not open again")
      local shown = own_docs or on
      local out: mut {{string}} = {}
      for at = copy, #checks, copies do
        local check = assert(checks[at], "an index within the list is a check")
        out[#out + 1] = { "C", check.name }
        for _, line in ipairs(check.run(on, shown, given)) do
          out[#out + 1] = { "L", check.name, line }
        end
      end
      assert(Fs.write(dir .. "/" .. tostring(copy), check_memo.encode(out)))
    end)
    for copy = 1, copies do
      if ran.ended[copy] == true then
        local text, _ = Fs.read(dir .. "/" .. tostring(copy))
        local got: mut {string: mut {string}} = {}
        for _, fields in ipairs(check_memo.decode(text or "")) do
          local kind, name, line = fields[1], fields[2], fields[3]
          if kind == "C" and name ~= nil then
            got[name] = {}
          elseif kind == "L" and name ~= nil and line ~= nil then
            local list = got[name]
            if list ~= nil then list[#list + 1] = line end
          end
        end
        for name, lines in pairs(got) do found[name] = lines end
      end
    end
    local _, _ = Fs.remove_tree(dir)
  end
  local out: mut {string} = {}
  for _, name in ipairs(printed) do
    local check = assert(by_name[name], "each printed name is a check")
    local lines = found[name] or check.run(db, carried or db, given)
    for _, line in ipairs(lines) do
      out[#out + 1] = name .. ": " .. line
    end
  end
  return out
end

--- Keeps what `chunk`, `cosmic fix`'s parse of `source` as the text of `file`, tells the checks of the tree, so that they
--- do not parse the file again: what it requires, a test's early returns, and the plurals of its texts, which it
--- returns (nil for none) for the caller to pass to [`tree_checks.whole`].
function tree_checks.read_off(file: string, source: string, chunk: Ast.Chunk): tree_checks.Plurals?
  tree_common.knows_parse(source, file, chunk)
  while file:sub(1, 2) == "./" do file = file:sub(3) end
  return tree_docs.plurals_in(file, source, chunk)
end

--- Whether `path`, a file's path under the root, is a module of the standard library, which the tree's checks hold to
--- what a program carries.
function tree_checks.standard(path: string): boolean
  return tree_build.standard(path)
end

--- Shares the rows of this process's memoed checks with the host's other checkouts ([`build.check_memo`]); returns
--- whether they are shared, and why not where they could not be.
function tree_checks.share_checks(): boolean, string
  return tree_checked.share_checks()
end

--- Says what the tree checks are doing, as a line of the run's log.
local function tree_say(line: string)
  log:say("fix: tree checks: " .. line)
end

--- When the check being run began, in nanoseconds of the monotonic clock,
--- and when the tree checks did.
local record TreeTiming
  mut began: integer
  run_began: integer
end

--- Says on stderr which part of the tree checks begins and how long they
--- have run, so that a part that takes minutes is not silent: [`tree_took`]
--- speaks only once it is over. `step` is "n of m" for the memoed checks.
local function tree_begin(timing: TreeTiming, name: string, step?: string)
  local _, _ = logger.summary("fix", "tree checks: " .. name .. (if step ~= nil then " (" .. step .. ")" else "" end) ..
      ", " .. progress.elapsed(Clock.monotonic_ns() - timing.run_began) .. " in")
end

--- Says how long the check `name` took, where that is long enough to wait on, so that a run that is slow says where, and
--- starts the next check's time.
local function tree_took(timing: TreeTiming, name: string)
  local now = Clock.monotonic_ns()
  local seconds = (now - timing.began) // 1000000000
  if seconds >= 3 then tree_say(name .. ": " .. tostring(seconds) .. " s") end
  timing.began = now
end

--- What the CI legs' promises say against the requirements the tree's
--- test modules declare ([`tree_build.promises`]), and the modules granted
--- the zig cache with no `pinned_zig` ([`tree_build.unguarded_zig`]), the
--- declarations read from the working database the projection just wrote.
local function promise_findings(root: string): {string}
  local build, open_trouble = Sqlite.open(build_paths.resolve(root).working, { schema = work_schema.Database })
  if build == nil then return { "tree checks: " .. tostring(open_trouble) } end
  local declared, declared_trouble = tree_build.requirements(build)
  local unguarded, unguarded_trouble = tree_build.unguarded_zig(build)
  local _, _ = build:close()
  if declared == nil then return { "tree checks: " .. declared_trouble } end
  if unguarded == nil then return { "tree checks: " .. unguarded_trouble } end
  for key, name in pairs(c_functions.prerequisites()) do
    declared["C function " .. key] = { name } -- checked: view_written
  end
  local legs, legs_trouble = tree_build.legs(root)
  if legs == nil then return { "tree checks: " .. legs_trouble } end
  local out: mut {string} = {}
  for _, line in ipairs(tree_build.promises(declared, legs)) do
    out[#out + 1] = "promises: " .. line
  end
  for _, line in ipairs(unguarded) do out[#out + 1] = "requirements: " .. line end
  return out
end

--- The sealed test modules that name the portable launcher's contract
--- ([`tree_build.sealed_launch`]), over the projection `db` and the
--- declarations the working database holds.
local function sealed_launch_findings(root: string, db: Sqlite.Handle): {string}
  local build, open_trouble = Sqlite.open(build_paths.resolve(root).working, { schema = work_schema.Database })
  if build == nil then return { "tree checks: " .. tostring(open_trouble) } end
  local unsealed, unsealed_trouble = tree_build.unsealed(build)
  local _, _ = build:close()
  if unsealed == nil then return { "tree checks: " .. unsealed_trouble } end
  local out: mut {string} = {}
  for _, line in ipairs(tree_build.sealed_launch(db, unsealed)) do
    out[#out + 1] = "sealed launch: " .. line
  end
  return out
end

--- Whether the build's own pipeline holds each module as the checks of the tree do, over the working database's inputs
--- ([`tree_checked.pipeline`]).
local function pipeline_findings(root: string, memo: Sqlite.Handle?): {string}
  local build, open_trouble = Sqlite.open(build_paths.resolve(root).working, { schema = work_schema.Database })
  if build == nil then return { tostring(open_trouble) } end
  local lines = tree_checked.pipeline(root, build, memo)
  local _, _ = build:close()
  return lines
end

--- Each check of the tree, over cosmic's own tree at `given.root` and its projection built afresh: what only the whole
--- tree can answer. A finding is the tree's, not a file's. Says on stderr which part runs, and in the run's log the parts
--- that took long.
function tree_checks.whole(given: tree_checks.Whole): tree_checks.Found
  local root = given.root
  local findings: mut {string} = {}
  -- The markers hold the findings. They only fall, and a run that mends removes the stale ones.
  local sink: Ceilings.Sink = { unmarked = {}, stale = {}, mend = given.mends }
  local timing: TreeTiming = { began = Clock.monotonic_ns(), run_began = Clock.monotonic_ns() }
  tree_begin(timing, "making the projection")
  local db, projection_trouble = tree_build.projection(root, given.standing)
  if db == nil then
    findings[#findings + 1] = "tree checks: " .. projection_trouble
    return { lines = findings, sink = sink }
  end
  local guide, guide_trouble = Fs.read(root .. "/doc/guides/quickstart.md")
  if guide == nil then
    local said = "tree checks: " .. tostring(guide_trouble)
    findings[#findings + 1] = said
  end
  local paths = build_paths.resolve(root)
  -- Kept on disk while the checks run, for the copies that run them to open too.
  local carried, carried_trouble = docs_checks.carried(paths.projection, paths.docs_check, true)
  if carried == nil then
    findings[#findings + 1] = "tree checks: " .. carried_trouble
  end
  local help, help_trouble = help_source.texts()
  if help == nil then
    findings[#findings + 1] = "tree checks: " .. help_trouble
  end
  tree_begin(timing, "the checks of the projection, docs and examples")
  local function reopen(): Sqlite.Handle?, Sqlite.Handle?
    local projection, _ = Sqlite.open(paths.projection)
    local shown: Sqlite.Handle? = nil
    if carried ~= nil then
      -- A copy that cannot read the carried docs leaves its checks to the process, which can.
      shown = assert(Sqlite.open(paths.docs_check))
    end
    return projection, shown
  end
  local ran, found = pcall(function(): {string}
    return tree_checks.run(db, guide, tree_ci.ci_sources(root), carried, help, given.plurals, reopen)
  end)
  if carried ~= nil then
    local _, _ = carried:close()
  end
  local _, _ = Fs.remove(paths.docs_check)
  if not ran then error(found, 0) end
  for _, line in ipairs(found) do
    findings[#findings + 1] = line
  end
  for _, line in ipairs(example_checks.run(db, root)) do
    findings[#findings + 1] = "examples as shown: " .. line
  end
  for _, line in ipairs(tree_ci.ci_testdata(root)) do
    findings[#findings + 1] = "ci testdata: " .. line
  end
  for _, line in ipairs(tree_readers.package_readers(root)) do
    findings[#findings + 1] = "package: " .. line
  end
  for _, line in ipairs(tree_readers.text_loaders(root)) do
    findings[#findings + 1] = "loaders: " .. line
  end
  for _, line in ipairs(tree_tests.test_returns(root)) do
    findings[#findings + 1] = "early returns: " .. line
  end
  for _, line in ipairs(tree_tests.test_clones(root)) do
    findings[#findings + 1] = "copied helpers: " .. line
  end
  local marking: Ceilings.Marking = { sink = sink }
  local marks_began = Clock.monotonic_ns()
  local marks = tree_checked.markers(root)
  for _, line in ipairs(marks.lines) do
    findings[#findings + 1] = "markers: " .. line
  end
  -- The markers only fall: each file's are held to its merge base with main.
  local held = CeilingsBase.check(root, Env.all(), CeilingsBase.live_git(), marks.counts)
  for _, line in ipairs(held.lines) do
    findings[#findings + 1] = "ceilings: " .. line
  end
  if held.note ~= "" then
    tree_say("ceilings: " .. held.note .. ", read in " ..
        tostring((Clock.monotonic_ns() - marks_began) // 1000000) .. " ms")
  end
  -- What the scope builder, the lowering and the checker found in a file that has not changed is kept in the build
  -- directory; without the memo the checks run in full.
  local memo, _ = Sqlite.open(build_paths.resolve(root).translate_check, { writable = true })
  Memprobe.mark("tree checks: before the memoed checks")
  timing.began = Clock.monotonic_ns()
  tree_begin(timing, "scopes", "1 of 5")
  for _, line in ipairs(tree_checked.scoped(root, memo, marking)) do
    findings[#findings + 1] = "scopes: " .. line
  end
  tree_took(timing, "scopes")
  Memprobe.mark("tree checks: scopes")
  tree_begin(timing, "declarations", "2 of 5")
  for _, line in ipairs(tree_checked.declared(root, memo, marking)) do
    findings[#findings + 1] = "declarations: " .. line
  end
  tree_took(timing, "declarations")
  Memprobe.mark("tree checks: declarations")
  tree_begin(timing, "checker", "3 of 5")
  for _, line in ipairs(tree_checked.checked(root, memo, nil, marking)) do
    findings[#findings + 1] = "checker: " .. line
  end
  tree_took(timing, "checker")
  Memprobe.mark("tree checks: checker")
  tree_begin(timing, "pipeline", "4 of 5")
  for _, line in ipairs(pipeline_findings(root, memo)) do
    findings[#findings + 1] = "pipeline: " .. line
  end
  tree_took(timing, "pipeline")
  Memprobe.mark("tree checks: pipeline")
  -- The new checker's own count of the calls no rule judged.
  tree_begin(timing, "untyped", "5 of 5")
  for _, line in ipairs(tree_checked.untyped(root, memo, marking)) do
    findings[#findings + 1] = "untyped: " .. line
  end
  tree_took(timing, "untyped")
  if memo ~= nil then
    local _, _ = memo:close()
  end
  for _, line in ipairs(promise_findings(root)) do
    findings[#findings + 1] = line
  end
  for _, line in ipairs(sealed_launch_findings(root, db)) do
    findings[#findings + 1] = line
  end
  local closed, close_trouble = db:close()
  if not closed then
    local said = "tree checks: " .. tostring(close_trouble)
    findings[#findings + 1] = said
  end
  return { lines = findings, sink = sink }
end

--- The plurals of the Teal files `named` (each file to its path under `root`, the name the whole tree's checks use), each
--- path with `prefix` in front, which is its path from cosmic's own root.
function tree_checks.named_plurals(prefix: string, named: {string: string}): {string}
  local texts: mut {{string}} = {}
  for file, path in pairs(named) do
    local text, _ = Fs.read(file)
    if text ~= nil then texts[#texts + 1] = { prefix .. path, text } end
  end
  table.sort(texts, function(a: {string}, b: {string}): boolean
    return (a[1] or "") < (b[1] or "")
  end)
  local out: mut {string} = {}
  for _, line in ipairs(tree_docs.plurals_of(texts)) do
    out[#out + 1] = "plurals: " .. line
  end
  return out
end

--- The checks of the tree that cost a run of some paths in cosmic's own tree at `root` a few seconds, over the files
--- `named` (each to its path under `root`): the plurals, public docs and rendered docs of those files, and the names the
--- docs and help refer to. The rest wait for a run of the whole tree. Each line is the whole tree's check's, so a line may
--- name a file that was not named: a new module's name can break a reference in another.
function tree_checks.named(root: string, standing: tree_standing.Standing, named: {string: string}): {string}
  local findings: mut {string} = {}
  for _, line in ipairs(tree_checks.named_plurals("", named)) do findings[#findings + 1] = line end
  local db, projection_trouble = tree_build.projection(root, standing)
  if db == nil then
    findings[#findings + 1] = "tree checks: " .. projection_trouble
    return findings
  end
  local paths: mut {string: boolean} = {}
  for _, path in pairs(named) do paths[path] = true end
  for _, line in ipairs(tree_docs.public_docs(db, nil, paths)) do
    findings[#findings + 1] = "public docs: " .. line
  end
  local built = build_paths.resolve(root)
  -- A scratch name of its own: a whole run in the same checkout keeps `docs_check` open for its copies.
  local carried, carried_trouble = docs_checks.carried(built.projection, built.docs_check .. ".named")
  local help, help_trouble = help_source.texts()
  if carried == nil then
    findings[#findings + 1] = "tree checks: " .. carried_trouble
  elseif help == nil then
    findings[#findings + 1] = "tree checks: " .. help_trouble
  else
    for _, line in ipairs(docs_checks.references(carried, help)) do
      findings[#findings + 1] = "doc references: " .. line
    end
    for _, line in ipairs(docs_checks.rendered(carried, nil, paths)) do
      findings[#findings + 1] = "rendered docs: " .. line
    end
  end
  if carried ~= nil then
    local _, _ = carried:close()
  end
  local _, _ = db:close()
  return findings
end

return tree_checks
