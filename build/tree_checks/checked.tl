--- The checks of the tree in the new checker's grammar: every `.tl` file scoping, lowering and checking but for what
--- the markers hold, kept in a memo by the sources each file reaches.

local Fs = require("cosmic.fs")
local type work_schema = require("build.work_schema")
local type Database = work_schema.Database
local Proc = require("cosmic.proc")
local fanout = require("build.compile_fanout")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local store_lookups = require("build.store_lookups")
local check_memo = require("build.check_memo")
local Ast = require("lang.ast")
local Check = require("lang.check")
local Ceilings = require("build.ceilings")
local Markers = require("build.markers")
local Report = require("build.syntax_report")
local SyntaxContracts = require("build.syntax_contracts")
local Declarations = require("lang.declarations")
local Driver = require("build.driver")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local PipelineCheck = require("build.pipeline_check")
local ShapeKey = require("build.shape_key")
local Scopes = require("lang.scopes")
local ScopesCover = require("lang.scopes_cover")
local TreeProgram = require("build.tree_program")
local Hash = require("cosmic.hash")
local artifact = require("build.artifact")
local _ = require("build.reads.all")
local tree_common = require("build.tree_checks.common")

local nth = tree_common.nth
local lookup_in = tree_common.lookup_in
local sources_of = tree_common.sources_of
local sink_of = tree_common.sink_of
local told_marks = tree_common.told_marks
local required_modules = tree_common.required_modules

local record tree_checked
end

--- What scoping one file found.
local record ScopeOutcome
  --- Why the scopes are not consistent with the tree ([`lang.scopes_cover`]), "" where they are.
  mut consistent: string
  errors: mut {Scopes.Error}
end

--- The scope builder's codes by name.
local scope_codes: mut {string: Scopes.Code} = {}
for _, code in ipairs(Scopes.codes) do
  scope_codes[code] = code
end

--- The outcome a memo kept, or nil where it kept none or it does not read.
local function kept_scopes(text: string, file: string): ScopeOutcome?
  local outcome: ScopeOutcome = { consistent = "", errors = {} }
  for _, fields in ipairs(check_memo.decode(text)) do
    local consistent = fields[2]
    if fields[1] == "C" and #fields == 2 and consistent ~= nil then
      outcome.consistent = consistent
    elseif fields[1] == "E" and #fields == 6 then
      local code_name, msg, fix = fields[2], fields[5], fields[6]
      local code = scope_codes[code_name]
      local y, x = math.tointeger(tonumber(fields[3])), math.tointeger(tonumber(fields[4]))
      if code == nil or y == nil or x == nil then
        return nil
      end
      outcome.errors[#outcome.errors + 1] = {
        filename = file, code = code, y = y, x = x, offset = 0, length = 0, msg = msg, fix = fix,
      }
    else
      return nil
    end
  end
  return outcome
end

--- The outcome of scoping `source`, from `memo` where it holds it under `salt`.
local function scope_outcome(file: string, source: string, declared: {string: Scopes.Global}, memo: Sqlite.Handle?,
                             salt: string): ScopeOutcome
  local dialect: Ast.Dialect = if file:match("%.d%.tl$") then "decl" else "tl" end
  local key = ""
  if memo ~= nil then
    key = check_memo.key(salt, dialect, source)
    local text = check_memo.get(memo, "scoped", key)
    local kept = if text ~= nil then kept_scopes(text, file) else nil end
    if kept ~= nil then
      return kept
    end
  end
  local parsed = Parser.parse(Lexer.lex(source, file), file, dialect)
  local scoped = Scopes.build(parsed.chunk, file, declared)
  local ok, reason = ScopesCover.check(parsed.chunk, scoped, declared)
  local outcome: ScopeOutcome = { consistent = if ok then "" else reason end, errors = scoped.errors } -- checked: view_as_mut
  if memo ~= nil then
    local rows: mut {{string}} = { { "C", outcome.consistent } }
    for _, e in ipairs(scoped.errors) do
      rows[#rows + 1] = { "E", e.code, tostring(e.y), tostring(e.x), e.msg, e.fix }
    end
    check_memo.put(memo, "scoped", key, check_memo.encode(rows))
  end
  return outcome
end

--- What [`tree_checked.share_checks`] read of the tool, inside [`Store.alone`].
local record Coded
  mut code: string?
  mut trouble: string
end

--- Shares the rows of this process's memoed checks with the host's other checkouts ([`build.check_memo`]), under the
--- code this tool checks with: the bytecode of the modules `cosmic fix` loads, read from the tool's own database and
--- not a projection attached ahead of it, and every byte of the tool ahead of that database. Returns whether they are
--- shared, and why not where the tool could not be read or the shared file not opened; a run that shares none by
--- its environment returns false and "".
function tree_checked.share_checks(): boolean, string
  local path = check_memo.shared_path()
  if path == nil then return check_memo.share(nil) end
  local head, head_trouble = artifact.trusted_prefix()
  if head == nil then
    local _, _ = check_memo.share(nil)
    return false, head_trouble
  end
  local core = Hash.hex_sha256(head)
  local coded: Coded = { code = nil, trouble = "" }
  Store.alone(function()
    coded.code, coded.trouble = check_memo.code_of({ requires = store_lookups.requires, bytecode = store_lookups.bytecode,
      holds = store_lookups.holds, core = core })
  end)
  local code = coded.code
  if code == nil then
    local _, _ = check_memo.share(nil)
    return false, coded.trouble
  end
  return check_memo.share(path, { code = code })
end

--- Every `.tl` file of the tree, scoped ([`lang.scopes`]) in the new checker's grammar: the names it resolves must agree
--- with the tree ([`lang.scopes_cover`]), and its errors are the ones its markers hold ([`build.ceilings`]), no more: an error
--- with no marker on its line is listed with its place and fix, and a marker that holds more than its line has is stale.
--- The sources are the `.tl` files under `root` ([`sources_of`]).
function tree_checked.scoped(root: string, memo?: Sqlite.Handle, marking?: Ceilings.Marking): {string}
  local files, trouble = sources_of(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local out: mut {string} = {}
  local given = TreeProgram.tree_globals(root)
  local declared = Driver.globals(given.sources, given.adjust)
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/scopes_cover.tl", "lang/truthy.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl",
    "build/check_memo.tl", "build/driver.tl", "build/tree_checks/checked.tl", "build/tree_checks/common.tl", "build/tree_program.tl" },
    "scoped 4")
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "scoped")
  end
  for _, row in ipairs(files) do
    local file, source = nth(row, 1), nth(row, 2)
    local outcome = scope_outcome(file, source, declared, memo, salt)
    if outcome.consistent ~= "" then
      out[#out + 1] = file .. ": its scopes are not consistent with its tree: " .. outcome.consistent
    end
    local findings: mut {Ceilings.Finding} = {}
    for _, e in ipairs(outcome.errors) do
      findings[#findings + 1] = { code = e.code, y = e.y, x = e.x, msg = e.msg, fix = e.fix }
    end
    for _, line in ipairs(told_marks(file, Ceilings.marked("scoped", file, source, findings, Scopes.codes, "scopes"),
        sink_of(marking))) do
      out[#out + 1] = line
    end
  end
  if memo ~= nil then
    check_memo.finish(memo, "scoped")
  end
  return out
end

--- An error of the new checker's lowering or checking of a file, as a check lists it.
local type Finding = Ceilings.Finding

--- What lowering or checking one file found: its errors.
local record DeclareOutcome
  errors: mut {Finding}
  --- Whether the stage could not judge the file (it does not parse, or the stage does not check that kind of file): its
  --- markers are neither held nor stale, and are left as they are.
  mut unjudged?: boolean
end

--- The outcome a memo kept, or nil where it kept none or it does not read; a code is read only if it is one of `codes`.
local function kept_findings(text: string, codes: {string}): DeclareOutcome?
  local known: mut {string: boolean} = {}
  for _, code in ipairs(codes) do
    known[code] = true
  end
  local outcome: DeclareOutcome = { errors = {} }
  for _, fields in ipairs(check_memo.decode(text)) do
    local code, msg, fix = fields[2], fields[5], fields[6]
    if fields[1] == "E" and #fields == 6 then
      local y, x = math.tointeger(tonumber(fields[3])), math.tointeger(tonumber(fields[4]))
      if code == nil or msg == nil or fix == nil or known[code] ~= true or y == nil or x == nil then
        return nil
      end
      outcome.errors[#outcome.errors + 1] = { code = code, y = y, x = x, msg = msg, fix = fix }
    elseif fields[1] == "U" then
      outcome.unjudged = true
    elseif fields[1] ~= "N" then
      return nil
    end
  end
  return outcome
end

local function kept_declarations(text: string, _file: string): DeclareOutcome?
  return kept_findings(text, Declarations.codes)
end

--- What a memo holds for an outcome.
local function kept_rows(outcome: DeclareOutcome): {{string}}
  local kept: mut {{string}} = { { if outcome.unjudged == true then "U" else "N" end } }
  for _, e in ipairs(outcome.errors) do
    kept[#kept + 1] = { "E", e.code, tostring(e.y), tostring(e.x), e.msg, e.fix }
  end
  return kept
end

--- A file of the tree to lower: its module, the modules it requires and what its result is keyed by.
local record DeclareFile
  file: string
  source: string
  module: string
  dialect: Ast.Dialect
  imports: {string}
  mut key: string
end

--- The files of the tree the new checker lowers: every `.tl` file but those of a `testdata` directory, which hold programs for
--- other projects.
local record Tree
  rows: {DeclareFile}
  --- Each file by its module, the name of its whole path ([`Driver.index`]): `ci/`, a project of its own, is no part of the tree.
  by_module: {string: DeclareFile}
  --- The same files as the sources a build is given ([`build.driver`]).
  index: Driver.Index
end

--- Where the digests of the sources the checks of other files read ([`ShapeKey`]) are kept, and the salt of the code that
--- makes them: a memo ([`build.check_memo`]) of the run, which has none in a test that gives it none.
local record Shaping
  memo: Sqlite.Handle?
  salt: string
end

--- The salt of the digests of [`ShapeKey`], from the code that makes them.
local function shaping_of(root: string, memo: Sqlite.Handle?): Shaping
  return { memo = memo, salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "build/shape_key.tl", "build/check_memo.tl" },
    "shape 2") }
end

--- The files of `files` that a lowering covers, each with the key its result is kept under: `salt`, its dialect and
--- its source and the sources of every module it requires, however far. `written` are the sources the build writes from
--- other files ([`TreeProgram.derived_of`]), which count as files of the tree, named for the file each comes from.
local function tree_of(given: {{string}}, salt: string, bindings?: {{string}}, written?: {{string}},
                       shaping?: Shaping): Tree
  local files = TreeProgram.joined(given, written or {}).files
  local derived: mut {string: boolean} = {}
  for _, entry in ipairs(bindings or {}) do
    files[#files + 1] = entry -- checked: view_written
    derived[nth(entry, 1)] = true
  end
  -- No complaint of [`build.source_parse`]'s `declared` here: a `.d.tl` beside a `.tl`, or one that names no kind, is refused when the tree is built ([`Pipeline.build`]), which the
  -- checks that read this index follow, and the files given are a tree that built.
  local index = TreeProgram.index(files, {})
  local tree: Tree = { rows = {}, by_module = {}, index = index }
  local rows, by_module = tree.rows, tree.by_module
  local hashes: mut {string: string} = {}
  -- What the files that require a module read of it, by module: its digest where it has one ([`ShapeKey`]), else its text.
  local read: mut {string: string} = {}
  local store: Sqlite.Handle? = nil
  local opened = if shaping ~= nil then shaping.memo else nil end
  if opened ~= nil then
    local prepared, _ = check_memo.prepare(opened, "shape")
    if prepared then
      store = opened
    end
  end
  local row_of: mut {Driver.Source: DeclareFile} = {}
  for _, source in ipairs(index.sources) do
    -- A declaration derived from a header is no file of the tree: its text is in the salt of the checks that read it.
    if derived[source.filename] ~= true then
      local exact = Hash.hex_sha256(source.text)
      local row: DeclareFile = {
        file = source.filename, source = source.text, module = source.module, dialect = source.dialect,
        imports = required_modules(source.text, source.filename, exact), key = "",
      }
      rows[#rows + 1] = row -- checked: view_written
      row_of[source] = row
      -- A module given as two files (`x.tl` and `x/init.tl`) is read from the first; the key holds both texts.
      hashes[row.module] = (hashes[row.module] or "") .. exact
      -- A source the build mends or writes from another file is read as its text says, comments and all.
      local held = exact
      if shaping ~= nil and source.dialect == "tl" and source.pinned == "" then
        local key = check_memo.key(shaping.salt, "shape", source.text)
        local kept = if store ~= nil then check_memo.get(store, "shape", key) else nil end
        local digest = kept or ShapeKey.digest(source.text, source.filename)
        if kept == nil and store ~= nil then
          check_memo.put(store, "shape", key, digest)
        end
        held = "s" .. digest
      end
      read[row.module] = (read[row.module] or "") .. held
    end
  end
  if store ~= nil then
    check_memo.finish(store, "shape")
  end
  for name, source in pairs(index.by_module) do
    local row = row_of[source]
    if row ~= nil then
      by_module[name] = row -- checked: view_written
    end
  end
  -- The key of a file is its source and the sources of every module it requires, however far.
  for _, row in ipairs(rows) do
    local reached: mut {string: boolean} = { [row.module] = true }
    local stack: mut {string} = {}
    for _, m in ipairs(row.imports) do
      stack[#stack + 1] = m
    end
    while #stack > 0 do
      local m = stack[#stack]
      stack[#stack] = nil
      local dep = by_module[m]
      if dep ~= nil and reached[dep.module] ~= true then
        reached[dep.module] = true
        for _, next_module in ipairs(dep.imports) do
          stack[#stack + 1] = next_module
        end
      end
    end
    local names: mut {string} = {}
    for m in pairs(reached) do
      names[#names + 1] = m
    end
    table.sort(names)
    local parts: mut {string} = {}
    for _, m in ipairs(names) do
      -- The file itself is read in full; the modules it requires as the checks of it read them.
      parts[#parts + 1] = m .. "=" .. (m == row.module and hashes[m] or read[m]) -- checked: and_ternary
    end
    -- The files of a cycle of requires reach the same modules: the file itself tells their keys apart.
    row.key = check_memo.key(salt, row.dialect, row.module .. "\n" .. table.concat(parts, "\n"))
  end
  return tree
end

--- A build ([`build.driver`]) over the tree at `root`: its prelude and the standard library's declarations as its
--- globals, the files of `tree` as its modules ([`build.tree_program`]).
local function tree_build(root: string, tree: Tree, types?: boolean, stubs?: {string: Driver.Source}): Driver.Build
  local globals = TreeProgram.tree_globals(root)
  return TreeProgram.build(tree.index, globals, types, stubs)
end

--- Asks `build` for the result of each module of `rows` (with its bodies checked where `bodies`), and gives
--- `seen` each row with the result of its module, one module's syntax held at a time ([`TreeProgram.stream`]). With `spliced`
--- the calls of [`Shape.record_of`] of each module are resolved before it is lowered, as the pipeline resolves them.
local function streamed(build: Driver.Build, tree: Tree, rows: {DeclareFile}, bodies: boolean, spliced: boolean,
                        seen: function(row: DeclareFile, result: Driver.Outcome?))
  local rows_of: mut {string: mut {DeclareFile}} = {}
  local names: mut {string} = {}
  for _, row in ipairs(rows) do
    local held = rows_of[row.module]
    local list = held or {}
    if held == nil then
      rows_of[row.module] = list
      names[#names + 1] = row.module
    end
    list[#list + 1] = row
  end
  local _ = TreeProgram.stream(build, tree.index, names, spliced, function(module: string)
    local result = build:result(module, bodies)
    local group = rows_of[module]
    if group ~= nil then
      for _, row in ipairs(group) do
        seen(row, result)
      end
    end
  end)
end

--- What one copy of a fan of the checks holds beyond the process it was forked from, as [`fanout.copies`] counts it:
--- the syntax and the declarations of the modules it lowers.
local check_copy_bytes <const> = 1024 * 1024 * 1024

--- What [`fanned`] returns: the memo text `judge` gave each file of the rows, by file, and the problems the build met,
--- in the order one process meets them.
local record Fanned
  texts: {string: string}
  problems: {string}
end

--- Gives each row of `rows` the memo text `judge` makes of its module's result, as [`streamed`] asks `build` for them, in
--- copies of the process ([`build.compile_fanout`]) where the rows are many: each copy streams every so many of the modules
--- and leaves its texts, its problems and its time in a file. The rows of a copy that did not end well, and every row where
--- no copy runs, are judged in the process. A row `judge` gives no text has none. The build's timing gets each copy's
--- time added: the time of the processors, which is more than the time the fan took.
local function fanned(build: Driver.Build, tree: Tree, rows: {DeclareFile}, bodies: boolean, spliced: boolean,
                      judge: function(row: DeclareFile, result: Driver.Outcome?): string?): Fanned
  local texts: mut {string: string} = {}
  local modules: mut {string} = {}
  local seen_module: mut {string: boolean} = {}
  for _, row in ipairs(rows) do
    if seen_module[row.module] ~= true then
      seen_module[row.module] = true
      modules[#modules + 1] = row.module
    end
  end
  local copies = fanout.copies(#modules, Proc.cpu_count(), check_copy_bytes)
  local dir: string? = nil
  if copies > 0 then
    local made, _ = Fs.mkdtemp("cosmic-checks-")
    dir = made
  end
  if dir == nil then
    streamed(build, tree, rows, bodies, spliced, function(row: DeclareFile, result: Driver.Outcome?)
      local text = judge(row, result)
      if text ~= nil then texts[row.file] = text end
    end)
    return { texts = texts, problems = build.problems }
  end
  -- The problems of each module: the stream splices a module, which may add one, just before it is lowered and judged.
  local before = #build.problems
  local of_module: mut {string: mut {string}} = {}
  local function told(module: string, text: string)
    local list = of_module[module] or {}
    of_module[module] = list
    list[#list + 1] = text
  end
  local function streamed_told(mine: {DeclareFile}, each: function(row: DeclareFile, text: string?))
    local seen = #build.problems
    streamed(build, tree, mine, bodies, spliced, function(row: DeclareFile, result: Driver.Outcome?)
      for at = seen + 1, #build.problems do
        local text = assert(build.problems[at], "an index within the list is a problem")
        told(row.module, text)
      end
      seen = #build.problems
      local text = judge(row, result)
      each(row, text)
    end)
  end
  local copy_of: mut {string: integer} = {}
  for index, module in ipairs(modules) do
    copy_of[module] = (index - 1) % copies + 1
  end
  local ran = fanout.run(copies, function(copy: integer)
    local mine: mut {DeclareFile} = {}
    for _, row in ipairs(rows) do
      if copy_of[row.module] == copy then mine[#mine + 1] = row end
    end
    local out: mut {{string}} = {}
    streamed_told(mine, function(row: DeclareFile, text: string?)
      if text ~= nil then out[#out + 1] = { "A", row.file, text } end
    end)
    for module, list in pairs(of_module) do
      for _, text in ipairs(list) do out[#out + 1] = { "P", module, text } end
    end
    local t = build.timing
    local times = { "T", tostring(t.prepare), tostring(t.lower), tostring(t.check) }
    out[#out + 1] = times
    assert(Fs.write(dir .. "/" .. tostring(copy), check_memo.encode(out)))
  end)
  local start = build.timing
  local prepare, lower, check = start.prepare, start.lower, start.check
  local left: mut {DeclareFile} = {}
  for copy = 1, copies do
    local text: string? = nil
    if ran.ended[copy] == true then
      local read, _ = Fs.read(dir .. "/" .. tostring(copy))
      text = read
    end
    if text == nil then
      for _, row in ipairs(rows) do
        if copy_of[row.module] == copy then left[#left + 1] = row end
      end
    else
      for _, fields in ipairs(check_memo.decode(text)) do
        local kind, a, b, c = fields[1], fields[2], fields[3], fields[4]
        if kind == "A" and a ~= nil and b ~= nil then
          texts[a] = b
        elseif kind == "P" and a ~= nil and b ~= nil then
          told(a, b)
        elseif kind == "T" then
          prepare = prepare + (math.tointeger(tonumber(a)) or 0) - start.prepare
          lower = lower + (math.tointeger(tonumber(b)) or 0) - start.lower
          check = check + (math.tointeger(tonumber(c)) or 0) - start.check
        end
      end
    end
  end
  start.prepare, start.lower, start.check = prepare, lower, check
  local _, _ = Fs.remove_tree(dir)
  if #left > 0 then
    streamed_told(left, function(row: DeclareFile, text: string?)
      if text ~= nil then texts[row.file] = text end
    end)
  end
  local problems: mut {string} = {}
  for at = 1, before do
    problems[#problems + 1] = assert(build.problems[at], "an index within the list is a problem")
  end
  for _, module in ipairs(TreeProgram.ordered(tree.index, modules)) do
    for _, text in ipairs(of_module[module] or {}) do problems[#problems + 1] = text end
  end
  return { texts = texts, problems = problems }
end

--- The errors of `list` as a check lists them.
local function findings_of(list: {Driver.Problem}): {Finding}
  local out: mut {Finding} = {}
  for _, e in ipairs(list) do
    out[#out + 1] = { code = e.code, y = e.y, x = e.x, msg = e.msg, fix = e.fix }
  end
  return out
end

--- The files of `tree` whose result `memo` does not hold, with the results it does.
local function kept_outcomes(memo: Sqlite.Handle?, kind: string, tree: Tree,
                             read: function(text: string, file: string): DeclareOutcome?
): mut {string: DeclareOutcome}, {DeclareFile}
  local outcomes: mut {string: DeclareOutcome} = {}
  local missed: mut {DeclareFile} = {}
  for _, row in ipairs(tree.rows) do
    local text = if memo ~= nil then check_memo.get(memo, kind, row.key) else nil end
    local kept = if text ~= nil then read(text, row.file) else nil end
    if kept ~= nil then
      outcomes[row.file] = kept
    else
      missed[#missed + 1] = row
    end
  end
  return outcomes, missed
end

--- Takes what a fan ([`fanned`]) returned for each row of `rows` into `outcomes`, and into `memo` under `kind`, each text
--- read as `read` reads a memo's; one that does not read leaves its file unjudged.
local function kept_fanned(fan: Fanned, rows: {DeclareFile}, outcomes: mut {string: DeclareOutcome}, memo: Sqlite.Handle?,
                           kind: string, read: function(text: string, file: string): DeclareOutcome?)
  for _, row in ipairs(rows) do
    local text = fan.texts[row.file]
    if text ~= nil then
      outcomes[row.file] = read(text, row.file) or { errors = {}, unjudged = true }
      if memo ~= nil then
        check_memo.put(memo, kind, row.key, text)
      end
    end
  end
end

--- The lines that list the errors no marker holds ([`build.ceilings.marked`]): the errors of each code of each file are held to the
--- markers of their lines, an error with none is listed with its place and fix, and a marker that holds more than its line
--- has is stale. `what` says what the errors are of in the message.
local function held_by_markers(tree: Tree, outcomes: {string: DeclareOutcome}, stage: Ceilings.Stage, codes: {string},
                               what: string, marking: Ceilings.Marking?): {string}
  local out: mut {string} = {}
  for _, row in ipairs(tree.rows) do
    local outcome = lookup_in(outcomes, row.file)
    -- A file the stage could not judge keeps its markers: neither held nor stale.
    if outcome.unjudged ~= true then
      for _, line in ipairs(told_marks(row.file, Ceilings.marked(stage, row.file, row.source, outcome.errors, codes, what),
          sink_of(marking))) do
        out[#out + 1] = line
      end
    end
  end
  return out
end

--- Every `.tl` file of the tree, its declarations and annotations lowered ([`lang.declarations`]) in the new
--- checker's grammar, but for the files of a `testdata` directory, and counting nothing of a file that does not parse:
--- the errors are the ones its markers hold ([`build.ceilings`]), no more: one with no marker on its line is listed with its
--- place and fix, and a marker that holds more than its line has is stale. The declaration files [`lang/prelude.d.tl`] and [`lang/stdlib.d.tl`] declare the
--- globals; every other file imports the modules it names from the whole tree, so the result for a file is
--- kept in `memo` under the sources of every module it requires, directly or not.
function tree_checked.declared(root: string, memo?: Sqlite.Handle, marking?: Ceilings.Marking): {string}
  local files, trouble = sources_of(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/truthy.tl", "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl", "build/check_memo.tl", "build/driver.tl",
    "build/tree_checks/checked.tl", "build/tree_checks/common.tl", "build/tree_program.tl", "build/gen_syscalls.tl", "core/syscalls.h",
    "core/process.h", "core/socket.h" }, "declared 6")
  local written, written_why = TreeProgram.derived_of(root)
  if written == nil then
    return { "reading the derived sources: " .. written_why }
  end
  local tree = tree_of(files, salt, TreeProgram.bindings_of(root), written, shaping_of(root, memo))
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "declared")
  end
  local outcomes, missed = kept_outcomes(memo, "declared", tree, kept_declarations)
  if #missed > 0 then
    local build = tree_build(root, tree)
    local fan = fanned(build, tree, missed, false, false, function(_row: DeclareFile, result: Driver.Outcome?): string?
      local outcome: DeclareOutcome = { errors = {}, unjudged = true }
      if result ~= nil and not result.broken then
        outcome = { errors = findings_of(result.declared) } -- checked: view_as_mut
      end
      return check_memo.encode(kept_rows(outcome))
    end)
    kept_fanned(fan, missed, outcomes, memo, "declared", kept_declarations)
  end
  if memo ~= nil then
    check_memo.finish(memo, "declared")
  end
  return held_by_markers(tree, outcomes, "declared", Declarations.codes, "declarations", marking)
end

local function kept_checks(text: string, _file: string): DeclareOutcome?
  return kept_findings(text, Check.codes)
end

--- Every `.tl` file of the tree, lowered as [`declared`] has it and then checked
--- ([`lang.check`]): every expression and statement of its bodies typed, without flow. The files left out are those
--- of [`declared`], the declaration files (which have no bodies) and the files that do not parse. The
--- errors are the ones its markers hold ([`build.ceilings`]), no more: one with no marker on its line is listed with its place
--- and fix, and a marker that holds more than its line has is stale. The result for a file is kept in `memo` under the sources of every module it requires,
--- directly or not, and of the checker. `phases`, when given, gets the nanoseconds spent parsing and scoping
--- (`prepare`), lowering (`lower`) and checking (`check`) the files the memo lacked.
function tree_checked.checked(root: string, memo?: Sqlite.Handle, phases?: {string: integer},
                              marking?: Ceilings.Marking): {string}
  local files, trouble = sources_of(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/truthy.tl", "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/check/",
    "lang/flow.tl", "lang/check_codes.tl", "lang/warnings.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl", "build/check_memo.tl", "build/driver.tl", "build/tree_checks/checked.tl", "build/tree_checks/common.tl", "build/tree_program.tl",
    "build/syntax_shape_specs.tl", "build/syntax_record_calls.tl", "build/syntax_protobuf_specs.tl", "build/syntax_record_splices.tl", "build/gen_syscalls.tl", "core/syscalls.h", "core/process.h",
    "core/socket.h" }, "checked 6")
  local written, written_why = TreeProgram.derived_of(root)
  if written == nil then
    return { "reading the derived sources: " .. written_why }
  end
  local tree = tree_of(files, salt, TreeProgram.bindings_of(root), written, shaping_of(root, memo))
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "checked")
  end
  local outcomes, missed = kept_outcomes(memo, "checked", tree, kept_checks)
  local problems: {string} = {}
  if #missed > 0 then
    local build = tree_build(root, tree)
    local fan = fanned(build, tree, missed, true, true, function(row: DeclareFile, result: Driver.Outcome?): string?
      local outcome: DeclareOutcome = { errors = {}, unjudged = true }
      if result ~= nil and row.dialect == "tl" and not result.broken then
        outcome = { errors = findings_of(result.bodies) } -- checked: view_as_mut
      end
      return check_memo.encode(kept_rows(outcome))
    end)
    kept_fanned(fan, missed, outcomes, memo, "checked", kept_checks)
    problems = fan.problems
    if phases ~= nil then
      phases.check = build.timing.check -- checked: map_field
      phases.prepare = build.timing.prepare -- checked: map_field
      phases.lower = build.timing.lower -- checked: map_field
    end
  end
  if memo ~= nil then
    check_memo.finish(memo, "checked")
  end
  local out = held_by_markers(tree, outcomes, "checked", Check.codes, "bodies", marking)
  for _, problem in ipairs(problems) do
    table.insert(out, 1, problem) -- checked: overload_none -- untyped: call
  end
  return out
end

--- Whether the build's own pipeline ([`build.pipeline`]) holds each module of the tree as the checks of the tree do, and
--- names the modules it refuses for more than a count ([`build.pipeline_check`] has the rules). `memo` keeps the result for
--- a module under the key `checked` keeps its own.
function tree_checked.pipeline(root: string, build_db: Database, memo?: Sqlite.Handle):
    {string}
  local files, trouble = sources_of(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local written, written_why = TreeProgram.derived_of(root)
  if written == nil then
    return { "reading the derived sources: " .. written_why }
  end
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/check/", "lang/flow.tl",
    "lang/check_codes.tl", "lang/warnings.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl",
    "build/check_memo.tl", "build/driver.tl", "build/tree_checks/checked.tl", "build/tree_checks/common.tl", "build/tree_program.tl",
    "build/syntax_shape_specs.tl", "build/syntax_record_calls.tl", "build/syntax_protobuf_specs.tl", "build/syntax_record_splices.tl", "build/pipeline.tl", "build/pipeline_check.tl",
    "build/gen_syscalls.tl", "build/compile_grammar.tl", "build/main_locals.tl", "build/lua_tail.tl", "lang/codegen.tl", "lang/truthy.tl", "lang/fact_wraps.tl",
    "lang/boundaries.tl", "lang/boundary_checks.tl",
    "core/syscalls.h", "core/process.h", "core/socket.h" }, "pipeline 4")
  local tree = tree_of(files, salt, TreeProgram.bindings_of(root), written, shaping_of(root, memo))
  return PipelineCheck.compare(root, build_db, memo, #tree.rows, function(index: integer): PipelineCheck.Row
    local row = assert(tree.rows[index])
    return { file = row.file, module = row.module, dialect = row.dialect, key = row.key }
  end, tree_checked.declared(root, memo), tree_checked.checked(root, memo))
end

--- What [`tree_checked.markers`] found: the lines that refuse, and the markers each file holds of each code, which the ratchet
--- holds to the merge base ([`build.ceilings_base`]).
local record Marked
  mut lines: mut {string}
  --- File to code to the count of findings its markers hold.
  mut counts: mut {string: {string: integer}}
end

--- The markers of the tree at `root`: the counts of each file's markers by `<stage> <code>`, the ratchet's side of the tree.
function tree_checked.markers(root: string): Marked
  local out: Marked = { lines = {}, counts = {} }
  local files, trouble = sources_of(root)
  if files == nil then
    out.lines[1] = "reading the sources: " .. trouble
    return out
  end
  for _, entry in ipairs(files) do
    local file, source = nth(entry, 1), nth(entry, 2)
    if Markers.mentions(source) then
      local held = Markers.counts(source, file)
      if next(held) ~= nil then
        out.counts[file] = held
      end
    end
  end
  return out
end

--- The calls the new checker gave no function, which no rule of the discipline judged ([`build.syntax_contracts`]'s
--- `untyped`), held by the markers at the lines of the calls (`-- untyped: call`): a call with no marker on its line is listed,
--- as the build itself refuses it ([`build.pipeline`]'s `generate`), and a marker that holds more than its line has is stale. The count is the port's alone, over the program the pipeline reads ([`build.tree_program`],
--- its calls of [`Shape.record_of`] resolved). The result for a
--- file is kept in `memo` under its source and those of every module it requires, and of the checker.
function tree_checked.untyped(root: string, memo?: Sqlite.Handle, marking?: Ceilings.Marking): {string}
  local files, trouble = sources_of(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local written, written_why = TreeProgram.derived_of(root)
  if written == nil then
    return { "reading the derived sources: " .. written_why }
  end
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/truthy.tl", "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/check/", "lang/flow.tl",
    "lang/check_codes.tl", "lang/warnings.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl",
    "build/check_memo.tl", "build/driver.tl", "build/syntax_node.tl", "build/syntax_report.tl",
    "build/syntax_receivers.tl", "build/syntax_contracts.tl", "build/contract_rules.tl", "build/tree_checks/checked.tl", "build/tree_checks/common.tl",
    "build/tree_program.tl", "build/gen_syscalls.tl", "core/syscalls.h", "core/process.h", "core/socket.h" }, "untyped 2")
  local tree = tree_of(files, salt, TreeProgram.bindings_of(root), written, shaping_of(root, memo))
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "untyped")
  end
  local found: mut {string: integer} = {}
  -- The line of each of those calls, by file, for the markers.
  local at: mut {string: {integer}} = {}
  -- Takes the count and the lines a memo's text holds for `row`, false where it holds none.
  local function take(row: DeclareFile, text: string): boolean
    local kept = check_memo.decode(text)[1]
    local count = if kept ~= nil then math.tointeger(tonumber(kept[1])) else nil end
    if kept == nil or count == nil then
      return false
    end
    local lines: mut {integer} = {}
    for i = 2, #kept do
      lines[#lines + 1] = math.tointeger(tonumber(kept[i])) or 0
    end
    found[row.file] = count
    at[row.file] = lines
    return true
  end
  local missed: mut {DeclareFile} = {}
  for _, row in ipairs(tree.rows) do
    if row.dialect ~= "tl" or not SyntaxContracts.applies(row.file) then
      -- Not held to the discipline: nothing is counted of it.
    else
      local text = if memo ~= nil then check_memo.get(memo, "untyped", row.key) else nil end
      if text == nil or not take(row, text) then
        missed[#missed + 1] = row
      end
    end
  end
  if #missed > 0 then
    local build = tree_build(root, tree, true)
    local fan = fanned(build, tree, missed, true, true, function(_row: DeclareFile, result: Driver.Outcome?): string?
      local subject: Report.Subject? = nil
      if result ~= nil then subject = Report.of(build.program, result) end
      if subject == nil then
        -- A module the checker kept no report of is refused elsewhere ([`checked`]).
        return nil
      end
      local read = SyntaxContracts.check(subject, nil, SyntaxContracts.declared_in(tree.index))
      local kept: mut {string} = { tostring(read.untyped) }
      for _, line in ipairs(read.untyped_lines) do kept[#kept + 1] = tostring(line) end
      return check_memo.encode({ kept })
    end)
    for _, row in ipairs(missed) do
      local text = fan.texts[row.file]
      if text ~= nil and take(row, text) and memo ~= nil then
        check_memo.put(memo, "untyped", row.key, text)
      end
    end
  end
  if memo ~= nil then
    check_memo.finish(memo, "untyped")
  end
  local out: mut {string} = {}
  for _, row in ipairs(tree.rows) do
    -- A file this check does not count has no findings and its markers are not judged: they may be of a check that did not run.
    local lines = at[row.file]
    if lines ~= nil then
      local findings: mut {Ceilings.Finding} = {}
      for _, line in ipairs(lines) do
        findings[#findings + 1] = { code = Ceilings.untyped_code, y = line, x = 1, msg = Ceilings.untyped_message,
          fix = Ceilings.untyped_fix }
      end
      for _, line in ipairs(told_marks(row.file, Ceilings.marked("untyped", row.file, row.source, findings,
          { Ceilings.untyped_code }, "calls"), sink_of(marking))) do
        out[#out + 1] = line
      end
    end
  end
  return out
end

return tree_checked
