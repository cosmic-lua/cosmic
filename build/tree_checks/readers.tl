--- The checks of the tree over who reads what: every reader of the compiler's identity named, the build directory
--- spelled by its module alone, every familiar command finding what stands in for it, `package` read by the files
--- that may, text loaded and text tables read only where allowed.

local CodeWalk = require("build.code_walk")
local key_parts = require("build.key_parts")
local docs = require("build.docs")
local Doc = require("cosmic.doc")
local Lexer = require("lang.lexer")
local String = require("cosmic.string")
local _ = require("build.reads.all")
local tree_common = require("build.tree_checks.common")
local type build_schema = require("build.schema")
local type Build = build_schema.Build

local sources_of = tree_common.sources_of

local record tree_readers
end

--- Whether `line` reads one of the `meta` rows `entry.keys` by its quoted
--- name, as [`Store.meta`] takes it (or a function of the module that
--- passes it on, `meta_of`); or reads a row by a name no reader can see:
--- [`Store.meta`] called with anything but a string, or with a string and
--- more (`"image_" .. rest`); or takes [`Store.meta`] as a value, in code,
--- (after an `=`, a `,` or a `(`), where an alias or a callback would read
--- any row. A declaration of the
--- function is none of these.
---
-- TODO: see a read of a row in SQL over a handle [`Store.databases`] returns,
-- which a scan of lines cannot tell from one over any other database, once
-- the checker tells which module opens a handle from the store's databases.
-- Until then the store's loud refusal ([`Store.meta`] raises for a withheld
-- row) is the backstop for a read by name; a query of the handle finds no row.
local function reads(line: string, entry: key_parts.MetaReaders): boolean
  if line:find("^%s*function ") ~= nil then return false end
  for _, name in ipairs(entry.keys) do
    for _, quote in ipairs({ '"', "'" }) do
      for _, call in ipairs({ "meta", "meta_of" }) do
        if line:find(call .. "%(%s*" .. quote .. name .. quote) ~= nil then return true end
      end
    end
  end
  if line:find("Store%.meta%(%s*[^\"'%s]") ~= nil then return true end
  if line:find("Store%.meta%(%s*[\"'][^\"']*[\"']%s*%.%.") ~= nil then return true end
  if line:find("^%s*%-%-") == nil then
    local at = 1
    while true do
      local first, last = line:find("Store%.meta", at, false)
      if first == nil or last == nil then break end
      local rest = line:sub(last + 1)
      local before = line:sub(1, first - 1)
      if rest:find("^%s*%(") == nil and rest:find("^[%w_\"'`]") == nil and
          before:find("[=,(]%s*$") ~= nil and before:find("==%s*$") == nil then
        return true
      end
      at = last + 1
    end
  end
  return false
end

--- Each module of `db` that reads a row of the group `group` of
--- [`build.key_parts`]' [`meta_readers`] (`compiler`, `image_hash`) through
--- [`Store.meta`] and `named` (by default the group's `readers` and
--- `carriers`) does not name, and then each it names that no longer reads
--- one.
---
--- A worker is given such a row only where its closure holds a reader the
--- map names ([`build.key_parts`]'s `reads_meta`): the compiler's identity
--- is given by the running tool and held in the key of that test alone,
--- and a closure store carries `image_hash` for it alone. A reader the map
--- misses would leave a verdict standing that turned on a value no key
--- held, or be given no row.
function tree_readers.meta_readers(db: Build, group: string, named?: {string}): {string}
  local entry = key_parts.meta_group(group)
  if entry == nil then
    return { group .. " is no group of build/key_parts.tl's `meta_readers`" }
  end
  local rows, trouble = db:rows(
    "SELECT path, CAST(inflate(source) AS TEXT) FROM modules ORDER BY path")
  if rows == nil then
    return { "reading the modules' sources: " .. tostring(trouble) }
  end
  local found: mut {string: boolean} = {}
  for _, row in ipairs(rows) do
    for line in String.lines(row:text(2)) do
      if reads(line, entry) then
        found[row:text(1)] = true
        break
      end
    end
  end
  local listed: mut {string: boolean} = {}
  local names: mut {string} = {}
  if named ~= nil then
    for _, name in ipairs(named) do names[#names + 1] = name end
  else
    for _, name in ipairs(entry.readers) do names[#names + 1] = name end
    for _, name in ipairs(entry.carriers) do names[#names + 1] = name end
  end
  for _, name in ipairs(names) do listed[name] = true end
  local what = table.concat(entry.keys, "/")
  local missing, stale: mut {string}, mut {string} = {}, {}
  for name in pairs(found) do
    if listed[name] ~= true then
      missing[#missing + 1] = name .. " reads the meta row " .. what .. ", but " ..
        "build/key_parts.tl's `meta_readers." .. group .. "` does not name it, so no key " ..
        "of a test that runs it holds it"
    end
  end
  for name in pairs(listed) do
    if found[name] ~= true then
      stale[#stale + 1] = name .. " is named in build/key_parts.tl's " ..
        "`meta_readers." .. group .. "`, but no longer reads the meta row " .. what .. " -- remove it"
    end
  end
  table.sort(missing)
  table.sort(stale)
  for _, line in ipairs(stale) do missing[#missing + 1] = line end
  return missing
end

--- The files of the tree that may spell a path under the build directory
--- themselves rather than ask [`build.paths`], each with why.
local spelled: {string: string} = {
  ["build/key_parts.tl"] = "names the build directory in a verdict key by the name a " ..
    "declaration gives it, `o` below the tree's marker, wherever the host keeps it",
  ["build/perf.tl"] = "asks a baseline artifact from before build.paths for its build " ..
    "directory, which that artifact can only name by the rule it was built with",
  ["build/identity.tl"] = "skips a checkout-local o/ of a tree of its own (ci/o) from the " ..
    "input walk, by its name in the tree, which a stale one keeps wherever the build " ..
    "directory goes",
  ["eval/check/grade.tl"] = "runs standalone on the cosmic.* modules alone, and grades a " ..
    "project the arena's own cosmic built",
}

--- Whether `line`, code rather than a comment, joins a path to `/o`: a
--- build directory spelled by hand.
local function spells_build_directory(line: string): boolean
  if line:find("^%s*%-%-") ~= nil then return false end
  return line:find("%.%.%s*([\"'])/o%1") ~= nil or line:find("%.%.%s*[\"']/o/") ~= nil
end

--- Each line of a module of `db` but a test that spells a path under the
--- build directory by hand -- `root .. "/o"` -- where `excused` (by
--- default [`spelled`]) does not name its file, as `<file>:<line>: ...`,
--- and then each file `excused` names that no longer does. Only
--- [`build.paths`] says where a build directory is, so boot, the verbs and
--- the rebuild lock cannot come to name different ones.
function tree_readers.build_directory(db: Build, excused?: {string: string}): {string}
  excused = excused or spelled
  local rows, trouble = db:rows(
    "SELECT file, CAST(inflate(source) AS TEXT) FROM modules " ..
      "WHERE file GLOB '*.tl' AND file NOT GLOB '*_test.tl' ORDER BY file")
  if rows == nil then
    return { "reading the modules' sources: " .. tostring(trouble) }
  end
  local out: mut {string} = {}
  local found: mut {string: boolean} = {}
  for _, row in ipairs(rows) do
    local number = 0
    for line in String.lines(row:text(2)) do
      number = number + 1
      if spells_build_directory(line) then
        found[row:text(1)] = true
        if excused[row:text(1)] == nil then
          out[#out + 1] = row:text(1) .. ":" .. tostring(number) .. ": spells the build directory " ..
            "by hand; ask build.paths' `resolve` for it, or for the path under it"
        end
      end
    end
  end
  local stale: mut {string} = {}
  for file in pairs(excused) do
    if found[file] ~= true then
      stale[#stale + 1] = file .. ": excused in build/tree_checks/readers.tl's `spelled`, but no " ..
        "longer spells the build directory -- remove it"
    end
  end
  table.sort(stale)
  for _, line in ipairs(stale) do out[#out + 1] = line end
  return out
end

--- What a newcomer types first, and the function that stands in for it.
local stand_ins_expected: {{string}} = {
  { "which", "Proc.find" },
  { "command -v", "Proc.find" },
  { "Proc.which", "Proc.find" },
  { "cp -R", "Fs.copy_tree" },
  { "mkdir -p", "Fs.mkdirs" },
  { "rm -rf", "Fs.remove_tree" },
  { "unlink", "Fs.remove" },
  { "ls", "Fs.list" },
  { "find type", "Fs.walk" },
  { "mktemp", "Fs.mkdtemp" },
  { "realpath", "Fs.absolute" },
  { "mv", "Fs.rename" },
  { "ln -s", "Fs.symlink" },
  { "touch", "Fs.set_mtime" },
  { "nproc", "Proc.cpu_count" },
  { "isatty", "Proc.is_tty" },
  { "getpid", "Proc.pid" },
  { "curl", "Http.download" },
  { "wget", "Http.download" },
  { "tar -x", "Archive.extract" },
  { "unzip", "Archive.extract" },
  { "sha256sum", "Hash.hex_sha256" },
  { "sleep", "Clock.sleep" },
  { "getentropy", "Rand.entropy" },
  { "getenv", "Env.get" },
  { "urandom", "Rand.entropy" },
}

--- Each of `cases` (by default the tree's own), a command or call and
--- the function that stands in for it, that `cosmic docs <command>`,
--- looked up the way a project sees the standard library in `db`, does
--- not show that function first, after any raw [`cosmic.sys`]
--- binding of that name. What a newcomer types first is the command or
--- call they would have used elsewhere, so a doc comment that stops
--- naming its command is caught here, not by the next person who writes
--- the function again.
function tree_readers.stand_ins(db: Build, cases?: {{string}}): {string}
  local looked, trouble = docs.view({ db }, { true })
  if looked == nil then
    return { "reading the docs: " .. trouble }
  end
  local out: mut {string} = {}
  for _, case in ipairs(cases or stand_ins_expected) do
    local query, wanted = case[1], case[2]
    if query == nil or wanted == nil then
      out[#out + 1] = "a stand-in case is the query a newcomer types and the function that stands in for it"
    else
      local found, lookup_trouble = Doc.lookup(looked, query)
      local first = "nothing"
      if found == nil then
        first = "nothing (" .. tostring(lookup_trouble) .. ")"
      else
        -- A raw binding of the same name may come first; what stands in
        -- for it must come right after.
        for _, entry in ipairs(found) do
          if entry.module ~= "cosmic.sys" then
            first = entry.source_symbol
            break
          end
        end
      end
      if first ~= wanted then
        out[#out + 1] = "`cosmic docs " .. query .. "` answers " .. first .. " first, not " ..
          wanted .. " -- name the command in " .. wanted .. "'s doc comment"
      end
    end
  end
  return out
end

--- The files that may read `package`, tests apart: the table that holds the loaded modules, the searchers that find them, `preload`,
--- `searchpath`, `loadlib` and the search paths. A module that reads them can load a module by a name it computes, which
--- the build does not see as an edge, so `require`, the one way the build follows, is the only way the rest load one.
local packagers: {string: string} = {
  ["build/link_resolve.tl"] = "refuses a step into `package.loaded` or `package.preload` when it resolves a name",
  ["build/removed_fix.tl"] = "reads the catalog from `package.loaded`",
  ["build/sandbox.tl"] = "asks whether the core preloads a module",
  ["build/test_worker.tl"] = "holds `require` to a test's closure through the searchers and `package.loaded`",
  ["cosmic/store.tl"] = "reads the store's searcher",
}

--- Each read of `package` in a file of the tree that is not one of `files` (by default [`packagers`]), as
--- `<file>:<line>: reads \`package\`...`: a name `package` that is no field (`t.package`, `s:package()`, `{ package = 1 }`, a field `package: T` declared),
--- so that an alias (`local p = package`), an index (`package["searchers"]`) and each field are all found.
function tree_readers.package_readers(root: string, files?: {string: string}): {string}
  local sources, trouble = sources_of(root)
  if sources == nil then
    return { "reading the sources: " .. trouble }
  end
  local permitted = files or packagers
  local out: mut {string} = {}
  for _, entry in ipairs(sources) do
    local file, text = entry[1], entry[2]
    -- A test is exempt: the worker holds it to its closure, so a test that reads `package` can load nothing the build
    -- does not follow, and it is no module a program carries.
    if file ~= nil and text ~= nil and permitted[file] == nil and file:match("_test%.tl$") == nil and
        text:find("package", 1, true) ~= nil then
      local tokens = Lexer.lex(text, file).tokens
      for i, word in ipairs(tokens.text) do
        if word == "package" and tokens.kind[i] == "identifier" then
          local before, after = tokens.text[i - 1], tokens.text[i + 1]
          local is_field = before == "." or before == ":" or after == ":" or
            ((before == "{" or before == ",") and after == "=")
          if not is_field then
            out[#out + 1] = file .. ":" .. tostring(tokens.y[i]) .. ": reads `package`, which only the files " ..
              "build/tree_checks/readers.tl's `packagers` names may: a module loads what it needs by `require` of a " ..
              "literal name, which the build follows, and not through the searchers or the table of loaded modules"
          end
        end
      end
    end
  end
  return out
end

--- The files that turn text into a chunk, tests apart: `load` and the names of its family, which build a function from
--- Lua text. What such a chunk is handed is what it can reach, and a chunk of text no checker read reaches the
--- library with the checks the library would otherwise rely on being dead. So each file here loads text the build
--- itself wrote or a constant, and the reason says which; a file that loads other text is a path by which unchecked Lua
--- reaches `cosmic.*`, and is not added without the owner's say.
local loaders: {string: string} = {
  ["build/child_policy_database_fixture.tl"] = "the main of a fixture program, a constant chunk of the test support",
  ["build/database_start_fixture.tl"] = "the modules of a fixture database, compiled by the build and loaded to test a start",
  ["cosmic/fuzz.tl"] = "the constant chunk `return __cosmic_tc`, the hook a checked run defines",
  ["build/load_module.tl"] = "the named loader: the constant chunk `return require((...))`",
  ["build/lua_tail.tl"] = "the Lua the compiler wrote, loaded in an environment of its own to dump its bytecode or to probe its locals",
  ["build/sandbox.tl"] = "the script the checker compiled ([`build.standalone`]'s `code`), as the main of a sealed program",
  ["build/standalone.tl"] = "the Lua the checker compiled from a file or a `-e` chunk, or kept from such a compile",
  ["build/test_worker.tl"] = "the constant chunk that reads a value's metatable in the form the compiler writes",
  ["build/type_watch.tl"] = "the constant chunk `return __cosmic_tc`, the hook a checked run defines",
  ["cosmic/errors_example.tl"] = "shows what a chunk built by `load` does with a method that is missing",
  ["cosmic/removed_example.tl"] = "shows what a chunk built by `load` is told of a removed name",
  ["lang/check_programs.tl"] = "the Lua the checker wrote of the programs it is tested on",
}

--- Each use of `load`, `loadfile`, `dofile` or `loadstring` as a name in a file of the tree that is not one of `files`
--- (by default [`loaders`]) and is no test, as `<file>:<line>: ...`: a name that is no field (`t.load`, `s:load()`, a field
--- `load: T` declared) and no function being defined, so that a call, an alias and an argument are all found.
function tree_readers.text_loaders(root: string, files?: {string: string}): {string}
  local sources, trouble = sources_of(root)
  if sources == nil then
    return { "reading the sources: " .. trouble }
  end
  local permitted = files or loaders
  local named: {string: boolean} = { load = true, loadfile = true, dofile = true, loadstring = true }
  local out: mut {string} = {}
  for _, entry in ipairs(sources) do
    local file, text = entry[1], entry[2]
    if file ~= nil and text ~= nil and permitted[file] == nil and file:match("_test%.tl$") == nil and
        file:match("%.tl$") ~= nil and (text:find("load", 1, true) ~= nil or text:find("dofile", 1, true) ~= nil) then
      local tokens = Lexer.lex(text, file).tokens
      local told = "which only the files build/tree_checks/readers.tl's `loaders` names may: a function built from text is a " ..
        "path by which Lua no checker read reaches `cosmic.*`; load a module by `require` of a literal name"
      for i, word in ipairs(tokens.text) do
        local before, after = tokens.text[i - 1], tokens.text[i + 1]
        if named[word] == true and tokens.kind[i] == "identifier" then
          -- A field of the globals table is the function itself, whatever the receiver is called.
          local receiver = tokens.text[i - 2]
          local is_field = before == "." or before == ":" or after == ":" or before == "function" or
            ((before == "{" or before == ",") and after == "=")
          if before == "." and (receiver == "_G" or receiver == "_ENV") then is_field = false end
          if not is_field then
            out[#out + 1] = file .. ":" .. tostring(tokens.y[i]) .. ": uses `" .. word .. "`, " .. told
          end
        elseif (word == "_G" or word == "_ENV") and tokens.kind[i] == "identifier" then
          -- `_G["load"]` and `rawget(_G, "load")` name it by a string.
          local by_string = false
          if (after == "[" or after == ",") and tokens.kind[i + 2] == "string" then
            local value = tokens.value[i + 2]
            by_string = value ~= nil and named[value] == true
          end
          if by_string then
            out[#out + 1] = file .. ":" .. tostring(tokens.y[i]) .. ": uses a function of the globals by its name, " .. told
          end
        end
      end
    end
  end
  return out
end

--- The tables of text-derived rows that a pure store ([`build.closure_store`]) leaves out, so a query of one fails there.
--- `stubs` is not among them: a pure store keeps those of the modules a test names, and the module it lacks fails by name.
local text_tables <const>: {string:boolean} = {
  docs = true, uses = true, links = true, examples = true, catalog = true, places = true,
}

--- The string literals of the Teal `source`, comments left out and a run of literals joined by `..` as one, so a statement
--- built in pieces reads whole. A `--` inside a literal is part of it.
local function literal_runs(source: string): {string}
  local runs: mut {string} = {}
  local current = ""
  local open = false
  local joining = false
  local function flush()
    if open then
      local run = current
      runs[#runs + 1] = run
    end
    current, open, joining = "", false, false
  end
  local function add(literal: string)
    if open and not joining then flush() end
    current, open, joining = current .. literal, true, false
  end
  local at, size = 1, #source
  while at <= size do
    local c = source:sub(at, at)
    local long_open = source:match("^%[(=*)%[", at)
    if source:sub(at, at + 1) == "--" then
      local comment_open = source:match("^%-%-%[(=*)%[", at)
      local ends = "\n"
      if comment_open ~= nil then ends = "]" .. comment_open .. "]" end
      local _, to = source:find(ends, at, true)
      at = (to or size) + 1
    elseif c == '"' or c == "'" then
      local parts: mut {string} = {}
      at = at + 1
      while at <= size and source:sub(at, at) ~= c do
        local d = source:sub(at, at)
        if d == "\\" then
          parts[#parts + 1] = source:sub(at + 1, at + 1)
          at = at + 2
        else
          parts[#parts + 1] = d
          at = at + 1
        end
      end
      at = at + 1
      add(table.concat(parts))
    elseif long_open ~= nil then
      local start = at + #long_open + 2
      local from, to = source:find("]" .. long_open .. "]", start, true)
      add(source:sub(start, (from or size + 1) - 1))
      at = (to or size) + 1
    elseif c == "." and source:sub(at + 1, at + 1) == "." then
      if open and not joining then joining = true else flush() end
      at = at + 2
    elseif c:find("%s") ~= nil then
      at = at + 1
    else
      flush()
      at = at + 1
    end
  end
  flush()
  return runs
end

--- The word of a table in a `FROM` or `JOIN` item, without its schema (`main.catalog`) or `_fts` (the full-text table of
--- one), and only its first word: `docs d` is `docs`.
local function table_of(item: string): string
  local name = item:match("^%s*([%w_%.]+)") or ""
  name = name:gsub("^[%w_]+%.", "")
  name = name:gsub("_fts$", "")
  return name
end

--- Whether one SQL fragment `run` reads a table of [`text_tables`]: it follows a `FROM` (and a comma-separated list after it)
--- or a `JOIN`. A fragment is SQL when it holds `select`, or `from` a table is followed by a clause (`where`, `join`,
--- `order`, ...): prose that says "Read from links" is neither.
local function reads_text_table(run: string): boolean
  local lowered = run:lower()
  local sql = lowered:find("%f[%w_]select%f[^%w_]") ~= nil
  local clauses <const> = { "where", "join", "on", "order", "group", "limit", "left", "inner", "union", "having" }
  local at = 1
  while true do
    local _, to = lowered:find("%f[%w_]from%s+", at)
    local _, joined = lowered:find("%f[%w_]join%s+", at)
    local found = to
    local after_join = false
    if joined ~= nil and (found == nil or joined < found) then found, after_join = joined, true end
    if found == nil then return false end
    local rest = lowered:sub(found + 1)
    local cut = #rest + 1
    local ended = false
    for _, clause in ipairs(clauses) do
      local from = rest:find("%f[%w_]" .. clause .. "%f[^%w_]")
      if from ~= nil and from < cut then cut, ended = from, true end
    end
    local close = rest:find("[;%)]")
    if close ~= nil and close < cut then cut, ended = close, true end
    local list = rest:sub(1, cut - 1)
    if sql or ended then
      local items: mut {string} = { list }
      if not after_join then
        items = {}
        for item in (list .. ","):gmatch("([^,]*),") do items[#items + 1] = item end
      end
      for _, item in ipairs(items) do
        if text_tables[table_of(item)] == true then return true end
      end
    end
    at = found + 1
  end
end

--- Whether `source` runs SQL that reads text a pure store withholds: a table of [`text_tables`], or the source of a module or
--- a declaration (`modules` or `decls` read beside a `source` column). A statement whose table is built at run time
--- (`"FROM " .. name`) is not seen.
local function queries_text(source: string): boolean
  for _, run in ipairs(literal_runs(source)) do
    if reads_text_table(run) then return true end
    local lowered = run:lower()
    if lowered:find("%f[%w_]source%f[^%w_]") ~= nil and
        (lowered:find("from%s+modules%f[^%w_]") ~= nil or lowered:find("from%s+decls%f[^%w_]") ~= nil) then
      return true
    end
  end
  return false
end

--- The readers of text that need no declaration, each with why: a reader that is given a handle on the projection or the
--- working database and not the store a test is given, or whose read fails loudly in the pure store. Each
--- is a module that would otherwise be refused by [`tree_readers.text_readers`].
local text_read_allowed <const>: {string:string} = {
  ["build.checker_declarations"] = "reads the declarations of the globals and the standard library, which a closure store adds for a closure that holds this module ([`build.closure_store`]'s `declared_beside`), so its read is never short",
  ["build.plans"] = "asks the stub or source of a standard-library module a compile names; the pure store holds the stubs a test names and fails for the rest ([`Store.withheld`])",
  ["build.stamp"] = "hashes each declaration's source into what binds a tool's stamps to its rows; a store a test is given carries no stamp, and where it withholds a source the binding is not the stamps' and none is answered",
  ["build.standard_text"] = "serves the stub or source of a standard-library module; the pure store holds the stubs a test names and fails for the rest ([`Store.withheld`])",
  ["build.closure_store"] = "reads the projection it writes the stores of, which a test is never given and which no test's store holds",
  ["build.perf"] = "a standalone script a release program runs; its SQL is the argument of a `cosmic sql` it starts and times against a project's own store, not a read of the store a test is given, and it cannot require a module of the tree it benchmarks",
  ["build.writer"] = "writes the projection from the working database it is handed, whose tables a test's store never holds",
  ["cosmic.internal.symbols"] = "words a hint of a refusal from the docs and examples of the databases it is handed; in a pure store those tables are absent and it raises ([`cosmic.internal.symbols`]'s `refuse_withheld`)",
  ["cosmic.doc"] = "with its parts in cosmic/doc/, answers a caller from the docs, uses, links and examples of the databases it is handed; in a pure store those tables are absent and it raises, naming `store_lookups`; a standard-library module, which cannot require a module of the build",
  ["cosmic.errors"] = "asks the catalog for the guidance on an error; a pure store has no catalog and the lookup raises there ([`Errors.guidance_in`]); a standard-library module, which cannot require a module of the build",
}

-- TODO: see a table named at run time (`"FROM " .. name`), which a scan of literals cannot, once the checker tells
-- the value a string expression holds.

--- Whether `excused` names `path`, or the module whose directory holds it: cosmic.doc.search, a part in
--- cosmic/doc/ beside cosmic.doc's init.tl, reads as cosmic.doc does and is excused with it. One level only, so a
--- module further down says why on its own.
local function excused_by(excused: {string:string}, path: string): boolean
  local parent = path:match("^(.*)%.[^.]*$")
  return excused[path] ~= nil or (parent ~= nil and excused[parent] ~= nil)
end

--- Each module of `db` that is no test and reads module text without declaring it, as `<module> reads text (<how>) and
--- requires none of build.reads.*`.
---
--- This is a lint, not what makes the pure store sound: a read of text the pure store withholds fails there (a source
--- is withheld, a table is absent), so a reader the lint misses fails the test that reaches it and is declared then. The lint finds
--- most readers early. A module declares what it reads by requiring one of [`build.code_walk`]'s `markers` by value (a
--- `local type` require is erased), which a test's closure follows ([`build.closure_store`]'s pure store keeps what the
--- closure declares); `excusing` (by default [`text_read_allowed`]) excuses a reader with a reason. The reads taken as
--- text: [`Store.source`] and [`Store.withheld`], which return a module's source; and SQL that reads a table of
--- [`text_tables`] or the source of a module, in any module that names it (a handle handed on is read by whoever
--- queries it). A module that runs a statement it is handed (`cosmic sql`) cannot be told apart by what it names, and
--- declares [`build.reads.all`] by hand.
function tree_readers.text_readers(db: Build, excusing?: {string:string}): {string}
  local excused = excusing or text_read_allowed
  local imported, imported_trouble = db:rows("SELECT path, requires FROM imports ORDER BY path, requires")
  if imported == nil then return { "reading the imports: " .. tostring(imported_trouble) } end
  local modules, trouble = db:rows(
    "SELECT path, CAST(inflate(source) AS TEXT) FROM modules WHERE kind NOT IN ('test', 'example') ORDER BY path")
  if modules == nil then return { "reading the modules: " .. tostring(trouble) } end
  local source_of: mut {string:string} = {}
  for _, row in ipairs(modules) do source_of[row:text(1)] = row:text(2) end
  local called, called_trouble = db:rows(
    "SELECT DISTINCT from_module, symbol FROM uses WHERE module = 'cosmic.store' " ..
      "AND symbol IN ('source', 'withheld') ORDER BY from_module, symbol")
  if called == nil then return { "reading the uses: " .. tostring(called_trouble) } end
  local how: mut {string:string} = {}
  for _, row in ipairs(called) do
    local path = row:text(1)
    if source_of[path] ~= nil and path ~= "cosmic.store" and how[path] == nil then
      how[path] = "Store." .. row:text(2)
    end
  end
  for path, source in pairs(source_of) do
    if how[path] == nil and path ~= "cosmic.store" and queries_text(source) then
      how[path] = "SQL of a text table"
    end
  end
  local out: mut {string} = {}
  for path, symbol in pairs(how) do
    local declared = CodeWalk.markers[path] ~= nil or excused_by(excused, path)
    for _, row in ipairs(imported) do
      local required = row:text(2)
      -- A `local type` require is erased, and a test's closure leaves the edge out.
      if row:text(1) == path and CodeWalk.markers[required] ~= nil and
          (source_of[path] or ""):find("local%s+type%s+[%w_]+%s*=%s*require%s*%(?%s*[\"']" ..
                (required:gsub("%.", "%%.")) .. "[\"']") == nil then
        declared = true
      end
    end
    if not declared then
      out[#out + 1] = path .. " reads text (" .. symbol .. ") and requires none of build.reads.*: require the one that " ..
        "names what it reads (build/reads/), `all` where nothing narrower is true"
    end
  end
  table.sort(out)
  return out
end

return tree_readers
