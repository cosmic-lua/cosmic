--- The tool's input policy, fingerprints and semantic identities.
--- These read the staged rows; [`build.work`] owns how they are staged.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local analysis_schema = require("build.analysis_schema")
local bind = require("build.bind")
local tree = require("build.tree")
local type work_schema = require("build.work_schema")
local type Database = work_schema.Database

--- A row of the `meta` table the identity is recorded in.
local record MetaRow
  key: string
  value: string
end

local record identity
  --- What the tool is made of, as two hashes: everything (`boot`), and
  --- the part the C core is built from (`image`). A binary carries both.
  --- A tree whose `boot` differs but whose `image` matches needs only a
  --- new database combined with the exact portable prefix the binary
  --- carries, which the tool can do to itself.
  record Fingerprint
    boot: string
    image: string
  end

  --- What a compile and a verdict are functions of, beyond their own
  --- inputs. All three are computed over the tree being built and carried
  --- by its portable projection, so a tool always names what it actually
  --- is.
  ---
  --- `compiler` is what turns source into bytecode: the build's own
  --- modules a compile or a parse runs to decide what it stores
  --- ([`identity.compiler_identity`]), among them [`build.withheld`], which names
  --- the globals the checker is stripped of, the declarations of the
  --- Lua standard library the new checker types a program with
  --- (lang/prelude.d.tl, lang/stdlib.d.tl), and the pins and patches
  --- Lua is built from. The checker's own source (`lang/`) is not in it:
  --- a compile is keyed by the code that reads ([`build.code_identity`]'s
  --- `coded`) and a parse by the analyzer's modules ([`build.importer`]'s
  --- `analyzer_identity`), each of which holds the modules of `lang/` it runs.
  --- The rest of the standard library the importer runs on is plumbing,
  --- not transformation (a bug there breaks the build loudly rather than
  --- changing bytecode quietly), and is left out, as is the rest of the
  --- build. That keeps an edit to either from recompiling everything.
  ---
  --- `runtime_basis` is the host-independent hash of the same pins, patches
  --- and checker source. Portable startup combines it with the validated target,
  --- configuration and exact raw-core digest.
  ---
  --- `writer` is what turns compiled rows into a projection: build.writer,
  --- this module and what they require ([`identity.writer_modules`], less
  --- `writer_left_out`, the standard library's included), and the core
  --- image, down to the SQLite that vacuums it and the codec that decodes
  --- the CA roots into it. A projection is signed with the identity of the
  --- writer that wrote it ([`build.writer`]), so a tool whose writer has not
  --- moved writes the same bytes as the tree's own, and one whose writer
  --- has is told apart.
  record Identities
    compiler: string
    runtime_basis: string
    writer: string
  end

  --- What names the lexer this process runs, which the code hashes `code_hashes` keeps are of: the boot hash of the
  --- tool, or nil where none is carried (a boot, a test's worker), which keeps none. A test sets it to reach the cache.
  mut lexed_by: function(): string?
end

local text = bind.text

--- What is never an input: `o`, the checkout-local build directory
--- older tools wrote, which a checkout may still hold, stale; the upstream
--- sources and the records that patch them, prose, and anything
--- hidden. `doc` is handled on its own: almost all of it is prose with
--- no examples, but a guide (`doc/guides/*.md`, `doc/guides/internal/*.md`) is where doc/writing.md's
--- grammar applies, and the build has to see those files to run
--- [`build.doctest`] over them. In cosmic's own tree the patches, the
--- vendor pins and the zig wrapper are walked after all, as inputs to
--- the tool rather than to the build, and `.github/` for the TODOs
--- alone, never as an input even where it holds Teal.
local not_input: {string:boolean} = {
  ["o"] = true,
  ["vendor"] = true,
  ["patch"] = true,
  ["bin"] = true,
  [".github"] = true,
}

--- The trees and files the tool is made of, in cosmic's own tree,
--- beside the Teal it carries from anywhere else in the tree
--- ([`carried_teal`]).
local tool_trees: {string:boolean} = {
  ["build"] = true,
  ["core"] = true,
  ["cosmic"] = true,
  ["cmd"] = true,
  ["patch"] = true,
  ["lang"] = true,
}

local tool_files: {string:boolean} = {
  ["build.zig"] = true,
  ["build.zig.zon"] = true,
  ["bin/zig"] = true,
  ["bin/zig.pin"] = true,
  ["lang/prelude.d.tl"] = true,
  ["lang/stdlib.d.tl"] = true,
}

--- The files of cosmic's own tree that the tool carries as text for the new checker's globals ([`build.checker_declarations`])
--- and that no module is: they declare globals, and the fork, which compiles every declaration file of the tree, reads
--- Teal and not the new grammar they are written in.
local global_declarations: {string:boolean} = {
  ["lang/prelude.d.tl"] = true,
  ["lang/stdlib.d.tl"] = true,
}

--- The directory the `bin/` files above sit in, walked for them and,
--- one level deep, for the TODOs its other scripts hold.
local tool_dirs: {string:boolean} = {
  ["bin"] = true,
}

--- Trees of their own that sit inside cosmic's: `ci/` is the project
--- the pinned CI driver runs from, with its own `o/`, so this tree's
--- build never reads its modules or tests. It walks it, all but that
--- `o/`, only for the TODOs its files hold ([`build.work`]).
local foreign_trees: {string:boolean} = {
  ["ci"] = true,
}

--- Whether `name`, a directory at the root of cosmic's own tree, is a
--- tree of its own (`foreign_trees`).
function identity.is_foreign_tree(name: string): boolean
  return foreign_trees[name] == true
end

--- The top-level directory an entry sits under, or the entry itself
--- at the top. A plain find, since this runs for every entry walked.
function identity.first_of(entry: string): string
  local slash = entry:find("/", 1, true)
  if slash == nil then
    return entry
  end
  return entry:sub(1, slash - 1)
end

--- Whether an entry under `vendor/` is one tree's pin, or the tree's
--- own directory on the way to it.
local function is_vendor_pin(entry: string): boolean
  local second = entry:find("/", 8, true)
  if second == nil then
    return true
  end
  return entry:sub(second) == "/PIN"
end

--- Whether `file` is a doc this tree extracts runnable examples from --
--- exactly `doc/guides/*.md`, `doc/guides/internal/*.md` and a program's
--- own `cmd/<name>/doc/guides/*.md`, never a markdown file anywhere else in
--- the tree ([`doc/design.md`], [`doc/roadmap.md`], and [`doc/writing.md`]
--- are prose with no examples, and stay out of scope on purpose).
local function is_doc_guide(file: string): boolean
  return file:match("^doc/guides/[^/]+%.md$") ~= nil or file:match("^doc/guides/internal/[^/]+%.md$") ~= nil or
    file:match("^cmd/[^/]+/doc/guides/[^/]+%.md$") ~= nil
end

--- The walk's predicates take the entry's bare name second, so what
--- is hidden is one byte compare, and the top-level rules run on the
--- top-level component alone.
function identity.skip_input(entry: string, name: string): boolean
  if name:sub(1, 1) == "." then
    return true
  end
  local first = identity.first_of(entry)
  if first == "doc" then
    if entry == "doc" or entry == "doc/guides" or entry == "doc/guides/internal" then
      return false
    end
    return not is_doc_guide(entry)
  end
  return not_input[first] == true
end

function identity.skip_in_own_tree(entry: string, name: string): boolean
  local first = identity.first_of(entry)
  -- `.github/` is walked, for `scanned` alone: its workflows, actions
  -- and scripts carry TODOs the build never reads. Hidden names under
  -- it are skipped like any other.
  if first == ".github" then
    return entry ~= first and name:sub(1, 1) == "."
  end
  if name:sub(1, 1) == "." then
    return true
  end
  if foreign_trees[first] == true then
    return entry == first .. "/o"
  end
  if first == "vendor" then
    return not is_vendor_pin(entry)
  end
  if tool_trees[first] == true or tool_files[entry] == true or tool_dirs[entry] == true then
    return false
  end
  -- The rest of `bin/` is walked too, for `scanned`: its scripts carry
  -- TODOs the build otherwise never reads.
  if tool_dirs[first] == true and entry:find("/", #first + 2, true) == nil then
    return false
  end
  return identity.skip_input(entry, name)
end

--- Whether `file` is a static asset ([`cosmic.layout`]'s `static`), under
--- `static/` or a program's `cmd/<name>/static/`
--- ([`analysis_schema.static_asset`]): an asset the project carries
--- verbatim, whatever its extension, never a module.
function identity.is_static(file: string): boolean
  return analysis_schema.static_asset(file) ~= nil
end

--- The most bytes of a static asset the build embeds: the cost is memory
--- at run time, where an embedded file is read whole.
local static_limit <const> = 16 * 1024 * 1024

--- The longest path of a static asset, relative to its `static/`.
local static_path_limit <const> = 255

--- Why `file`, a static asset of `size` bytes, cannot be carried,
--- or nil when it can: too big, a name that needs escaping in every URL
--- and tag the app writes (a control byte, `\`, `%`, `?` or `#`), or a
--- path too long. The reason leads with the file's own path.
function identity.static_refusal(file: string, size: integer): string?
  local asset = analysis_schema.static_asset(file)
  local name = if asset ~= nil then asset.path else file end
  if size > static_limit then
    return ("%s: %d MiB is past the %d MiB limit for an embedded asset; serve it from disk " ..
      "or object storage"):format(file, (size + 1048575) // 1048576, static_limit // 1048576)
  end
  if name:find("[\0-\31\127\\%%?#]") then
    return file .. ": the name holds a control byte, a backslash or one of % ? #, which " ..
      "every URL and tag that names it would have to escape; rename it"
  end
  if #name > static_path_limit then
    return ("%s: the path is %s, past the %d-byte limit for an asset"):format(
      file, String.counted(#name, "byte"), static_path_limit)
  end
  return nil
end

--- Whether a file the walk found is one the build consumes: Teal
--- source and declarations, a template, a doc guide or a static asset. Generated header
--- inputs are added by [`build.work`]. Never anything under the trees the tool alone
--- is made of, nor the declarations of the new checker's globals (`global_declarations`).
function identity.is_input(file: string, own_tree: boolean): boolean
  local first = identity.first_of(file)
  if not_input[first] == true or (own_tree and (foreign_trees[first] == true or global_declarations[file] == true)) then
    return false
  end
  if identity.is_static(file) then
    return true
  end
  if String.ends_with(file, ".tl") or String.ends_with(file, ".tmpl") then
    return true
  end
  if first == "doc" or first == "cmd" then
    return is_doc_guide(file)
  end
  return false
end

--- Whether a Teal file is one the tool carries wherever it sits in the
--- tree: every module the `inputs` view reads ([`build.analysis_schema`]:
--- Teal outside a `testdata/` directory, and a template, whose module
--- the tool carries as it does Teal's) except a test, which [`is_tool`]
--- has already left out. The tool carries every module of the tree but
--- its tests and examples ([`build.writer`]'s `dropped_modules`), so
--- eval/'s and test/portable's are carried as much as build/'s, and a
--- tree that holds none of the tool's C still moves `boot_hash` when one
--- of its modules does. An example outside the tool trees is taken too,
--- as one inside them is: a carried module may require it, and one more
--- reboot costs less than a stale tool.
local function carried_teal(file: string, own_tree: boolean): boolean
  if not (String.ends_with(file, ".tl") or String.ends_with(file, ".tmpl")) or
      identity.is_static(file) or not identity.is_input(file, own_tree) then
    return false
  end
  return file:sub(1, 9) ~= "testdata/" and file:find("/testdata/", 1, true) == nil
end

--- Whether a file is one the tool is made of, in cosmic's own tree: a
--- file under one of its trees, one of its named files, a module it
--- carries from elsewhere ([`carried_teal`]), or a vendored tree's pin. A
--- Teal test (`*_test.tl`, the `inputs` view's `test` kind) never is: no
--- binary carries a test ([`build.writer`]'s `carried`), and in cosmic's
--- own tree only a test may require one ([`build.positions`]), so none is
--- carried for being required either. So an edit to a test moves neither
--- fingerprint ([`identity.record_fingerprint`]) and never rebuilds the tool,
--- though the test is staged as an input all the same.
function identity.is_tool(file: string, own_tree: boolean): boolean
  if not own_tree then
    return false
  end
  local first = identity.first_of(file)
  if first == "vendor" then
    return file:sub(-4) == "/PIN"
  end
  if String.ends_with(file, "_test.tl") then
    return false
  end
  return tool_trees[first] == true or tool_files[file] == true or
    carried_teal(file, own_tree)
end

--- The hash over some of the rows of `tool`, in path order.
function identity.hash_over(db: Sqlite.Handle, where: string): string?, string
  local rows, trouble = db:rows(
    "SELECT lower(hex(sha256(group_concat(path || ' ' || sha256, char(10) " ..
      "ORDER BY path)))) FROM tool WHERE " .. where)
  if rows == nil then
    return nil, tostring(trouble)
  end
  local row = assert(rows[1], "a hash query answers one row")
  return row:text(1), ""
end

--- The files the seed compiles, as [`build/seed.txt`] under `root` lists them, one to a line; none in a tree that has no
--- seed list (a project's), whose tool's compiler is the one it was given.
local function seed_paths(root: string): {string}?, string
  local path = root .. "/build/seed.txt"
  local present_status, missing = Fs.status(path)
  if present_status == nil then return nil, "seed list: " .. tostring(missing) end
  local present = present_status.exists
  if not present then return {}, "" end
  local listed, trouble = Fs.read(path)
  if listed == nil then return nil, "seed list: " .. tostring(trouble) end
  local paths: mut {string} = {}
  for line in listed:gmatch("[^\n]+") do paths[#paths + 1] = line end
  return paths, ""
end

--- The tool's fingerprints, over `tool` (which holds no test: see
--- [`is_tool`]): `boot` over every row, and `image` over what the C core
--- is built from. That is `core/` but the Teal beside its C (no core is
--- built from it), the zig build and wrapper, every vendored tree's pin
--- and patches, and [`build/patch.tl`], which applies them: only
--- `bin/zig build boot` applies a patch record to a pin, so a change under
--- `patch/*` or to the applier needs it too. So does a change to
--- [`build.tree`], which decides from what a tool records which tree it
--- is built from: a rebuild by a tool that decided otherwise writes a
--- tool that records the wrong thing. The bridge, core/bridge.lua, is
--- under `core/` and so in it.
--- [`build/launcher.tl`] also belongs to the retained portable prefix: a
--- database-only rebuild reuses its existing shell bytes. So does
--- [`build/artifact.tl`], which lays the artifact out: a rebuild lays it
--- out with the running tool's own copy, so an edit to it boots too.
---
--- The seed ([`build/seed.txt`] and each file it lists) is in it too: a boot compiles the compiler the tool carries from
--- those files alone (core/bridge.lua's `bootstrap`), and a rebuild by the running tool carries its own compiler on, so
--- an edit to one of them (lang/check/init.tl, say) is a tool that only a boot makes.
---
--- Both fingerprints are written into `meta` for the projection to carry
--- into the binary, which is how a binary knows what it was built from,
--- so a project reads them rather than computing any. So is
--- `built_from`, the root the binary is built from ([`build.tree`]'s
--- `built_from`): only a boot or a rebuild, the acts that write a tool,
--- record it. Returns the fingerprint written;
--- [`identity.recorded_boot_hash`] reads it back.
function identity.record_fingerprint(db: Database, root: string): identity.Fingerprint?, string
  local boot, boot_trouble = identity.hash_over(db, "1")
  if boot == nil then
    return nil, boot_trouble
  end
  local seed, seed_trouble = seed_paths(root)
  if seed == nil then
    return nil, seed_trouble
  end
  local quoted: mut {string} = { "'build/seed.txt'" }
  for _, path in ipairs(seed) do quoted[#quoted + 1] = "'" .. path:gsub("'", "''") .. "'" end
  local image, image_trouble = identity.hash_over(db,
    "(path GLOB 'core/*' AND NOT path GLOB 'core/*.tl') OR " ..
      "path IN ('build.zig', 'build.zig.zon', " ..
      "'bin/zig', 'bin/zig.pin', 'build/artifact.tl', 'build/launcher.tl', " ..
      "'build/patch.tl', 'build/tree.tl') OR " ..
      "path GLOB 'vendor/*/PIN' OR " ..
      "path GLOB 'patch/*' OR " ..
      "path IN (" .. table.concat(quoted, ", ") .. ")")
  if image == nil then
    return nil, image_trouble
  end
  local built_from, built_trouble = tree.built_from(root)
  if built_from == nil then
    return nil, built_trouble
  end
  local fingerprints: {MetaRow} = { { key = "boot_hash", value = boot }, { key = "image_hash", value = image },
    { key = "built_from", value = built_from } }
  for _, pair in ipairs(fingerprints) do
    local ok, why = db:run(
      "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
      { text(pair.key), text(pair.value) })
    if not ok then
      return nil, tostring(why)
    end
  end
  return { boot = boot, image = image }, ""
end

--- The `boot` fingerprint [`identity.record_fingerprint`] wrote into `meta` at
--- the last stage, read back rather than recomputed. It is for a caller
--- that only wants to know whether the tool it is running still matches
--- the tree (paired with [`build.work.tool_moved`] to know the `tool` table is
--- accurate), not to restage anything itself. `nil, ""` when the
--- database holds no such row yet: a fresh build directory, or one nothing has
--- staged for.
function identity.recorded_boot_hash(db: Sqlite.Handle): string?, string
  local rows, trouble = db:rows(
    "SELECT value FROM meta WHERE key = 'boot_hash'")
  if rows == nil then
    return nil, tostring(trouble)
  end
  if #rows == 0 then
    return nil, ""
  end
  -- Read on a file whose tables are not held to the schema: the value may be of any type.
  return rows[1]:as_text(1), ""
end

--- The pins and declarations of the compiler's basis, as one text: the pin
--- of Lua, the declarations the new checker types a program against ([`lang/prelude.d.tl`], [`lang/stdlib.d.tl`]),
--- and Lua's patches. Part of the compiler's identity, and the whole of
--- `runtime_basis`. [`ci/cosmic-driver.pin`], which names the release that
--- seeds a boot, is not in it: a boot loads
--- the seed's source compiled twice (core/bridge.lua's `bootstrap`),
--- and the compiler it carries is the second stage, a function of that
--- source alone, so no release's emitter is in what it is.
local pins <const> =
  "coalesce((SELECT group_concat(path || ' ' || sha256, char(10) " ..
  "ORDER BY path) FROM tool WHERE path = 'vendor/lua/PIN' " ..
  "OR path IN ('lang/prelude.d.tl', 'lang/stdlib.d.tl') OR path GLOB 'patch/lua/*'), '')"

--- What a module of the tree in the working database requires, as
--- `requires` holds of its source: the walk [`identity.compiler_modules`] and
--- [`identity.writer_modules`] take over it.
local function requires_in(db: Database): function(string): {string}?, string
  -- Every module's names are read at the first walk's first step: a query
  -- for each of the some three hundred modules a walk reaches took a tenth
  -- of a second a build.
  local held: mut {{string:{string}}} = {}
  return function(name: string): {string}?, string
    local all = held[1]
    if all == nil then
      local rows, rows_trouble = db:rows(
        "SELECT DISTINCT i.path, r.name FROM inputs i " ..
          "JOIN requires r ON r.source_hash = i.source_hash ORDER BY i.path, r.name")
      if rows == nil then return nil, tostring(rows_trouble) end
      local read: mut {string:mut {string}} = {}
      for _, row in ipairs(rows) do
        local list = read[row:text(1)] or {}
        read[row:text(1)] = list
        local second = row:text(2)
        list[#list + 1] = second
      end
      held[1] = read
      all = read
    end
    local found = all[name]
    local required: mut {string} = {}
    if found ~= nil then
      for i, item in ipairs(found) do required[i] = item end
    end
    return required, ""
  end
end

identity.lexed_by = function(): string? return Store.meta("boot_hash") end

--- The hash of the code of each of `names` the tree holds, by path: the hash of a module's code text
--- ([`build.code_text`]), so that an edit to a comment or to layout moves no identity, and of a declaration's source.
--- Then `extra`, an SQL expression.
---
--- A module's hash is kept in `code_hashes` by its source's hash and the boot hash of the tool that lexed it, whose
--- lexer the hash is of ([`identity.lexed_by`]), so a build of an unchanged tree lexes nothing.
local function hash_of(db: Database, names: {string}, extra: string): string?, string
  local slots: mut {string} = {}
  local by = identity.lexed_by()
  local values: mut {Sqlite.Value} = { text(by or "") }
  for index, name in ipairs(names) do
    slots[#slots + 1] = "?" .. tostring(index + 1)
    values[#values + 1] = text(name)
  end
  local rows, trouble = db:rows("SELECT i.path, i.file, i.source_hash, coalesce(c.code_hash, '') FROM inputs i " ..
      "LEFT JOIN code_hashes c ON c.source_hash = i.source_hash AND c.by = ?1 WHERE i.path IN (" ..
      table.concat(slots, ", ") .. ") ORDER BY i.path, i.file", values)
  if rows == nil then
    return nil, tostring(trouble)
  end
  local tail, tail_trouble = db:rows("SELECT " .. extra)
  if tail == nil then
    return nil, tostring(tail_trouble)
  end
  local lines: mut {string} = {}
  local found: mut {string:string} = {}
  local missed = false
  for _, row in ipairs(rows) do
    local file, source_hash = row:text(2), row:text(3)
    local code_hash = row:text(4)
    if file:match("%.d%.tl$") ~= nil then
      -- A declaration's comments are data: its leading block names its kind (`--- @kind`), which the build reads.
      -- Its hash is its source's, and no row of `code_hashes`, which holds the code hashes of modules alone.
      code_hash = Hash.hex_sha256("source\n" .. source_hash)
    elseif code_hash == "" then
      local sources = assert(db:rows("SELECT source FROM inputs WHERE source_hash = ?1 LIMIT 1",
        { text(source_hash) }))
      local source = assert(sources[1], "an input's source_hash names its source"):text(1)
      code_hash = Hash.hex_sha256(require("build.code_text").of(source, file))
      found[source_hash] = code_hash
      missed = true
    end
    lines[#lines + 1] = row:text(1) .. " " .. code_hash
  end
  if by ~= nil and missed then
    -- A cache: a database another process holds, or one opened to be read, keeps none and loses nothing. A write
    -- that fails is taken back to the savepoint, so it leaves no part of itself and nothing else of the caller's.
    local began, begin_trouble = db:exec("SAVEPOINT code_hashes")
    if not began then
      return nil, tostring(begin_trouble)
    end
    local kept, _ = db:run("DELETE FROM code_hashes WHERE by <> ?1", { text(by) })
    for source_hash, code_hash in pairs(found) do
      if kept then
        kept, _ = db:run("INSERT OR REPLACE INTO code_hashes (source_hash, by, code_hash) VALUES (?1, ?2, ?3)",
          { text(source_hash), text(by), text(code_hash) })
      end
    end
    if not kept then
      local _, _ = db:exec("ROLLBACK TO code_hashes")
    end
    local released, release_trouble = db:exec("RELEASE code_hashes")
    if not released then
      return nil, tostring(release_trouble)
    end
  end
  lines[#lines + 1] = assert(tail[1], "a select of one expression answers one row"):text(1)
  return Hash.hex_sha256(table.concat(lines, "\n")), ""
end

--- Where the compiler's identity starts ([`identity.compiler_modules`]):
--- the semantic compile and derivation, and each module whose code
--- they run to decide what they store. See
--- [`identity.compiler_identity`].
local compiler_roots: {string} = {
  "build.plans", "build.derivation",
  -- The analyzer ([`build.importer`]'s `analyzer_roots`): the extractors,
  -- generators and parser a parse runs, whose `tests` rows a compile
  -- appends a test module's tail from (`with_test_tail`).
  "build.analysis_schema", "build.bind", "build.doctest", "build.gen_syscalls", "cosmic.internal.link_text",
  -- The compile's own: the tree the rules hold in and the globals the checker is stripped of.
  "build.tree", "build.withheld",
  -- What reads the identities a compile and a parse are keyed by from the binary's stamps: a stamp it
  -- read wrongly would store a row under another code's key.
  "build.stamp",
  -- The Store lookups the analyzer's walk and the tree checks' memo are handed in the text shape.
  "build.store_lookups",
}

--- The modules the compiler's identity holds, sorted, as `requires`
--- returns what a module of the tree requires: every one `require`
--- reaches from `compiler_roots` that is the build's own
--- (`build.*`) or is the template compiler ([`cosmic.template`] and its
--- submodules), whose output [`build.derivation`] stores. Every root is
--- followed without exceptions; the importer coordinates these
--- operations from outside their closure.
function identity.compiler_modules(requires: function(string): {string}?, string): {string}?, string
  local reached: mut {string:boolean} = {}
  local stack: mut {string} = {}
  for _, name in ipairs(compiler_roots) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if name ~= nil and reached[name] ~= true then
      reached[name] = true
      local required, trouble = requires(name)
      if required == nil then return nil, trouble end
      for _, next_name in ipairs(required) do stack[#stack + 1] = next_name end
    end
  end
  local names: mut {string} = {}
  for name in pairs(reached) do
    if name:sub(1, 6) == "build." or name == "cosmic.template" or
        name:sub(1, 16) == "cosmic.template." then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names, ""
end

--- The compiler's identity ([`Identities.compiler`]) over what the
--- working database holds now, recorded nowhere: the code text ([`build.code_text`]) of each
--- of [`identity.compiler_modules`] the tree holds, the declarations the new checker
--- types a program with and Lua's pins and patches.
---
--- What a module requires is what `requires` holds of its source, which
--- only a parse fills. So before [`build.importer.derive`] the walk
--- reaches only what earlier parses found: the same modules, and so the
--- same identity, while none of them has changed, and another whenever
--- one it reaches has, since each one's code text is in it.
---
--- It holds what a compile or a parse stores is a function of beyond its
--- own key (a module's Lua, bytecode, record-field uses and refusal, and
--- a source's rows in the analysis tables), and nothing else:
---
--- - the pinned Lua and its patches, and the declarations the new
---   checker types a program with (lang/prelude.d.tl, lang/stdlib.d.tl),
---   which decide what every compile accepts. The checker's source
---   (`lang/`) is not here: a compile is keyed by [`build.code_identity`]'s
---   `coded` over what reads and writes in the new mode, and a parse by
---   [`build.importer`]'s `analyzer_identity`, which hold the modules of
---   `lang/` they reach;
--- - build.plans and [`build.derivation`];
--- - the names the globals are stripped of, which build.withheld spells itself rather
---   than reading [`cosmic.removed`]: the rest of that catalog is only
---   what a refusal says, which no compile keeps;
--- - the rules a module is refused by and the tree they hold in
---   (build.syntax_contracts, [`build.tree`]);
--- - the uses the checker finds ([`build.syntax_receivers`]);
--- - the analyzer, whose `tests` rows a test module's compile is
---   appended from;
--- - the schema of the rows a parse stores and of the `inputs` view a
---   compile reads a source through ([`build.analysis_schema`]).
---
--- The rule: a module build.importer calls that can change a row a
--- compile or a parse stores is one of `compiler_roots`, or is reached
--- from one, or is the compile or the parse of the first item
--- ([`build.pipeline`], [`build.parse_derive`]), keyed as it says. What
--- it leaves out only stages (build.work),
--- fingerprints, reports (cosmic.internal.symbols' hints, in a refusal's message,
--- which no compile keeps), fails a whole build before any key is looked
--- up (build.positions), or finds the host's caches (build.caches,
--- build/zig.tl): an edit to one compiles and parses nothing again.
--- importer_test's `test_the_compiler_modules_are_closed_under_require`
--- checks the closed semantic boundary and classifies the coordinator's
--- imports outside it.
function identity.compiler_identity(db: Database): string?, string
  local names, trouble = identity.compiler_modules(requires_in(db))
  if names == nil then
    return nil, trouble
  end
  return hash_of(db, names, pins)
end

--- Where the writer's identity starts ([`identity.writer_modules`]): what
--- decides a projection's bytes beside the rows it is filled from, each
--- of which its signature holds by value or by a key ([`build.writer`]'s
--- `signature_sql`). Those are build.writer, which fills and vacuums it,
--- and this module, which computes the fingerprint and the identities it
--- carries in `meta`. A tool rebuilt by a stale tool carries them as
--- that tool's code took them, and is told apart from one the tree's
--- code wrote only by this module's being in the identity
--- ([`build.reboot`]'s `unsettled`).
local writer_roots <const>: {string} = { "build.writer", "build.identity" }

--- What a writer root requires that the writer's identity leaves out,
--- and why none decides a projection's bytes beside its rows. Only a
--- root's own require is left out: a module that another module of the
--- identity requires is in it, whichever of these it is.
local writer_left_out <const>: {string:string} = {
  ["build.importer"] = "build.writer requires it for its `Result` type alone " ..
    "(`local type`), which `requires` still records; what its " ..
    "compiles and parses store reaches a projection as rows the compiler's " ..
    "identity keys",
  ["build.work"] = "build.writer uses its transaction lifecycle; staging, scans " ..
    "and history do not decide projection bytes beside the staged rows",
}

--- The modules the writer's identity holds, sorted, as `requires`
--- returns what a module of the tree requires: every one `require`
--- reaches from `writer_roots`, the standard library's included (down
--- to the SQLite binding that vacuums a projection and the codec that
--- decodes the CA roots into it), except what a root itself requires
--- that `writer_left_out` names. build/importer_test.tl's
--- `test_the_writer_modules_are_closed_under_require` holds that list
--- to the roots' requires.
function identity.writer_modules(requires: function(string): {string}?, string): {string}?, string
  local roots: mut {string:boolean} = {}
  for _, name in ipairs(writer_roots) do roots[name] = true end
  local reached: mut {string:boolean} = {}
  local stack: mut {string} = {}
  for _, name in ipairs(writer_roots) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if name ~= nil and reached[name] ~= true then
      reached[name] = true
      local required, trouble = requires(name)
      if required == nil then return nil, trouble end
      for _, next_name in ipairs(required) do
        if not (roots[name] == true and writer_left_out[next_name] ~= nil) then
          stack[#stack + 1] = next_name
        end
      end
    end
  end
  local names: mut {string} = {}
  for name in pairs(reached) do names[#names + 1] = name end
  table.sort(names)
  return names, ""
end

--- What `writer_left_out` names, for build/importer_test.tl to hold
--- the roots' requires to.
function identity.writer_left_out(): {string:string}
  local copy: mut {string:string} = {}
  for name, why in pairs(writer_left_out) do copy[name] = why end
  return copy
end

--- The writer's identity ([`Identities.writer`]) over what the working
--- database holds now, recorded nowhere: the code text of each of
--- [`identity.writer_modules`] the tree holds, and the core image's hash
--- (`image_hash`), whose SQLite writes the bytes. What a module requires
--- is what `requires` holds of its source, as for [`compiler_identity`].
--- An edit to a module outside it -- build.todo_scan,
--- the analyzer -- writes the same projection from the same rows, so
--- it moves no signature and settles no rebuilt tool.
local function writer_identity(db: Database): string?, string
  local names, trouble = identity.writer_modules(requires_in(db))
  if names == nil then
    return nil, trouble
  end
  return hash_of(db, names,
    "coalesce((SELECT value FROM meta WHERE key = 'image_hash'), '')")
end

--- The runtime basis ([`Identities.runtime_basis`]) over what the working
--- database holds now, recorded nowhere: the hash of Lua's pin and patches
--- and the declarations the new checker types a program with.
function identity.runtime_basis(db: Database): string?, string
  local rows, trouble = db:rows("SELECT lower(hex(sha256(" .. pins .. ")))")
  if rows == nil then
    return nil, tostring(trouble)
  end
  return assert(rows[1], "a hash query answers one row"):text(1), ""
end

--- The identities, computed over the tree and written into `meta` for
--- the projections to carry, and returns them. See [`Identities`] for what
--- each is over. The compiler's closes over `requires`, so the tree must be parsed
--- ([`build.importer.derive`]) first: on a fresh working database the
--- closure would otherwise stop at its roots, and keys
--- made under that identity would match no later build's.
function identity.record_identities(db: Database): identity.Identities?, string
  local compiler, compiler_trouble = identity.compiler_identity(db)
  if compiler == nil then
    return nil, compiler_trouble
  end
  local writer, writer_trouble = writer_identity(db)
  if writer == nil then
    return nil, writer_trouble
  end
  local basis, basis_trouble = identity.runtime_basis(db)
  if basis == nil then
    return nil, basis_trouble
  end
  local identities: identity.Identities = {
    compiler = compiler,
    runtime_basis = basis,
    writer = writer,
  }
  local recorded: {MetaRow} = {
    { key = "compiler", value = identities.compiler },
    { key = "runtime_basis", value = identities.runtime_basis },
    { key = "writer", value = identities.writer },
  }
  for _, pair in ipairs(recorded) do
    local ok, why = db:run(
      "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
      { text(pair.key), text(pair.value) })
    if not ok then
      return nil, tostring(why)
    end
  end
  return identities, ""
end

return identity
