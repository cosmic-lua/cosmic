--- The tool's input policy, fingerprints and semantic identities.
--- These read the staged rows; [`build.work`] owns how they are staged.

local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local bind = require("build.bind")

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
  --- ([`identity.compiler_identity`]), among them [`build.teal`], which names
  --- the globals the checker is stripped of, and the Teal compiler's and
  --- Lua's pins and patches.
  --- The rest of the standard library the importer runs on is plumbing,
  --- not transformation (a bug there breaks the build loudly rather than
  --- changing bytecode quietly), and is left out, as is the rest of the
  --- build. That keeps an edit to either from recompiling everything.
  ---
  --- `runtime_basis` is the host-independent hash of the Teal and Lua pins
  --- and patches. Portable startup combines it with the validated target,
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
end

local text = bind.text

--- What is never an input: the build's own output, the upstream
--- sources and the records that patch them, prose, and anything
--- hidden. `doc` is handled on its own: almost all of it is prose with
--- no examples, but `doc/guides/*.md` is the one place doc/meta.md's
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
}
local tool_files: {string:boolean} = {
  ["build.zig"] = true,
  ["build.zig.zon"] = true,
  ["bin/zig"] = true,
  ["bin/zig.pin"] = true,
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
--- exactly `doc/guides/*.md`, never a markdown file anywhere else in
--- the tree ([`doc/design.md`], [`doc/roadmap.md`], and [`doc/meta.md`] are
--- prose with no examples, and stay out of scope on purpose).
local function is_doc_guide(file: string): boolean
  return file:match("^doc/guides/[^/]+%.md$") ~= nil
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
    if entry == "doc" or entry == "doc/guides" then
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
  if foreign_trees[first] then
    return entry == first .. "/o"
  end
  if first == "vendor" then
    return not is_vendor_pin(entry)
  end
  if tool_trees[first] or tool_files[entry] or tool_dirs[entry] then
    return false
  end
  -- The rest of `bin/` is walked too, for `scanned`: its scripts carry
  -- TODOs the build otherwise never reads.
  if tool_dirs[first] and entry:find("/", #first + 2, true) == nil then
    return false
  end
  return identity.skip_input(entry, name)
end

--- Whether a file the walk found is one the build consumes: Teal
--- source and declarations or a doc guide. Generated header inputs are
--- added by [`build.work`]. Never anything under the trees the tool alone
--- is made of.
function identity.is_input(file: string, own_tree: boolean): boolean
  local first = identity.first_of(file)
  if not_input[first] or (own_tree and foreign_trees[first]) then
    return false
  end
  if String.ends_with(file, ".tl") then
    return true
  end
  if first == "doc" then
    return is_doc_guide(file)
  end
  return false
end

--- Whether a Teal file is one the tool carries wherever it sits in the
--- tree: every module the `inputs` view reads ([`build.analysis_schema`]:
--- Teal outside a `testdata/` directory) except a test, which [`is_tool`]
--- has already left out. The tool carries every module of the tree but
--- its tests and examples ([`build.writer`]'s `dropped_modules`), so
--- eval/'s and test/portable's are carried as much as build/'s, and a
--- tree that holds none of the tool's C still moves `boot_hash` when one
--- of its modules does. An example outside the tool trees is taken too,
--- as one inside them is: a carried module may require it, and one more
--- reboot costs less than a stale tool.
local function carried_teal(file: string, own_tree: boolean): boolean
  if not String.ends_with(file, ".tl") or not identity.is_input(file, own_tree) then
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
  return tool_trees[first] == true or tool_files[file] == true
    or carried_teal(file, own_tree)
end

--- The hash over some of the rows of `tool`, in path order.
function identity.hash_over(db: Sqlite.Handle, where: string): string | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT lower(hex(sha256(group_concat(path || ' ' || sha256, char(10) " ..
    "ORDER BY path)))) FROM tool WHERE " .. where)
  if rows == nil then
    return nil, trouble
  end
  return rows[1][1]
end

--- The tool's fingerprints, over `tool` (which holds no test: see
--- [`is_tool`]): `boot` over every row, and `image` over what the C core
--- is built from. That is `core/` but the Teal beside its C (no core is
--- built from it), the zig build and wrapper, every vendored tree's pin
--- and patches (the Teal compiler's included), and [`build/patch.tl`],
--- which applies them: only `bin/zig build boot` applies a patch record
--- to a pin, so a change under [`vendor/tl/PIN`], `patch/tl/*` or to the
--- applier needs it too, as with every other vendored tree.
--- [`build/launcher.tl`] also belongs to the retained portable prefix: a
--- database-only rebuild reuses its existing shell bytes. So does
--- [`build/artifact.tl`], which lays the artifact out: a rebuild lays it
--- out with the running tool's own copy, so an edit to it boots too.
---
--- Both fingerprints are written into `meta` for the projection to carry
--- into the binary, which is how a binary knows what it was built from,
--- so a project reads them rather than computing any. Returns the
--- fingerprint written; [`identity.recorded_boot_hash`] reads it back.
function identity.record_fingerprint(db: Sqlite.Handle): identity.Fingerprint | nil, string
  local boot, boot_trouble = identity.hash_over(db, "1")
  if boot == nil then
    return nil, boot_trouble
  end
  local image, image_trouble = identity.hash_over(db,
    "(path GLOB 'core/*' AND NOT path GLOB 'core/*.tl') OR " ..
    "path IN ('build.zig', 'build.zig.zon', " ..
    "'bin/zig', 'bin/zig.pin', 'build/artifact.tl', 'build/launcher.tl', " ..
    "'build/patch.tl') OR " ..
    "path GLOB 'vendor/*/PIN' OR " ..
    "path GLOB 'patch/*'")
  if image == nil then
    return nil, image_trouble
  end
  for _, pair in ipairs({ { "boot_hash", boot }, { "image_hash", image } }) do
    local ok, why = Sqlite.run(db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
      { text(pair[1]), text(pair[2]) })
    if not ok then
      return nil, why
    end
  end
  return { boot = boot, image = image }
end

--- The `boot` fingerprint [`identity.record_fingerprint`] wrote into `meta` at
--- the last stage, read back rather than recomputed. It is for a caller
--- that only wants to know whether the tool it is running still matches
--- the tree (paired with [`build.work.tool_moved`] to know the `tool` table is
--- accurate), not to restage anything itself. `nil, ""` when the
--- database holds no such row yet: a fresh `o/`, or one nothing has
--- staged for.
function identity.recorded_boot_hash(db: Sqlite.Handle): string | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'boot_hash'")
  if rows == nil then
    return nil, trouble
  end
  if #rows == 0 then
    return nil, ""
  end
  return rows[1][1]
end

--- The Teal compiler's and Lua's pins and patches, as one text: part
--- of the compiler's identity, and the whole of `runtime_basis`.
local pins <const> =
  "coalesce((SELECT group_concat(path || ' ' || sha256, char(10) " ..
  "ORDER BY path) FROM tool WHERE path IN ('vendor/tl/PIN', 'vendor/lua/PIN') " ..
  "OR path GLOB 'patch/tl/*' OR path GLOB 'patch/lua/*'), '')"

--- What a module of the tree in the working database requires, as
--- `requires` holds of its source: the walk [`identity.compiler_modules`] and
--- [`identity.writer_modules`] take over it.
local function requires_in(db: Sqlite.Handle): function(string): {string} | nil, string
  return function(name: string): {string} | nil, string
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT DISTINCT r.name FROM inputs i " ..
      "JOIN requires r ON r.source_hash = i.source_hash WHERE i.path = ?1 " ..
      "ORDER BY r.name", { text(name) })
    if rows == nil then return nil, rows_trouble end
    local required: {string} = {}
    for _, row in ipairs(rows) do required[#required + 1] = row[1] end
    return required, ""
  end
end

--- The hash of the source hash of each of `names` the tree holds, by
--- path, then `extra`, an SQL expression.
local function hash_of(db: Sqlite.Handle, names: {string}, extra: string): string | nil, string
  local slots: {string} = {}
  local values: {Sqlite.Value} = {}
  for index, name in ipairs(names) do
    slots[#slots + 1] = "?" .. index
    values[#values + 1] = text(name)
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT lower(hex(sha256(coalesce((SELECT group_concat(path || ' ' || " ..
    "source_hash, char(10) ORDER BY path) FROM inputs WHERE path IN (" ..
    table.concat(slots, ", ") .. ")), '') || char(10) || " .. extra .. ")))", values)
  if rows == nil then
    return nil, trouble
  end
  return rows[1][1]
end

--- Where the compiler's identity starts ([`identity.compiler_modules`]):
--- the semantic compile and derivation, and each module whose code
--- they run to decide what they store. See
--- [`identity.compiler_identity`].
local compiler_roots: {string} = {
  "build.compilation", "build.derivation",
  -- The analyzer ([`build.importer`]'s `analyzer_roots`): the extractors,
  -- generators and parser a parse runs, whose `tests` rows a compile
  -- appends a test module's tail from (`with_test_tail`).
  "build.analysis_schema", "build.analyzer", "build.ast", "build.bind",
  "build.compiler", "build.doctest", "build.gen_syscalls", "build.link_text",
  -- The compile's own: the checker's environment, the rules a module is
  -- refused by and the tree they hold in, and the record-field uses
  -- the checker finds.
  "build.contracts", "build.receivers", "build.teal", "build.tree",
  -- Splices the specs [`Shape.record_of`] names into the source a compile
  -- checks ([`build.shape_specs`]): its output is part of the bytecode.
  "build.shape_specs",
}

--- The modules the compiler's identity holds, sorted, as `requires`
--- answers what a module of the tree requires: every one `require`
--- reaches from `compiler_roots` that is the build's own
--- (`build.*`). Every root is followed without exceptions; the importer
--- coordinates these operations from outside their closure.
function identity.compiler_modules(requires: function(string): {string} | nil, string): {string} | nil, string
  local reached: {string:boolean} = {}
  local stack: {string} = {}
  for _, name in ipairs(compiler_roots) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if not reached[name] then
      reached[name] = true
      local required, trouble = requires(name)
      if required == nil then return nil, trouble end
      for _, next_name in ipairs(required) do stack[#stack + 1] = next_name end
    end
  end
  local names: {string} = {}
  for name in pairs(reached) do
    if name:sub(1, 6) == "build." then names[#names + 1] = name end
  end
  table.sort(names)
  return names, ""
end

--- The compiler's identity ([`Identities.compiler`]) over what the
--- working database holds now, recorded nowhere: the source hash of each
--- of [`identity.compiler_modules`] the tree holds, and the Teal compiler's and
--- Lua's pins and patches. A boot names its analyzer by it before it
--- parses ([`build.importer.tree_code`]).
---
--- What a module requires is what `requires` holds of its source, which
--- only a parse fills. So before [`build.importer.derive`] the walk
--- reaches only what earlier parses found: the same modules, and so the
--- same identity, while none of them has changed, and another whenever
--- one it reaches has, since each one's source hash is in it.
---
--- It holds what a compile or a parse stores is a function of beyond its
--- own key (a module's Lua, bytecode, record-field uses and refusal, and
--- a source's rows in the analysis tables), and nothing else:
---
--- - the pinned compiler and Lua;
--- - [`build.compilation`] and [`build.derivation`];
--- - the checker's environment ([`build.teal`]), and the names it is
---   stripped of, which build.teal spells itself (its `withheld`) rather
---   than reading [`cosmic.removed`]: the rest of that catalog is only
---   what a refusal says, which no compile keeps;
--- - the rules a module is refused by and the tree they hold in
---   ([`build.contracts`], [`build.tree`]);
--- - the uses the checker finds ([`build.receivers`]);
--- - the analyzer, whose `tests` rows a test module's compile is
---   appended from;
--- - the schema of the rows a parse stores and of the `inputs` view a
---   compile reads a source through ([`build.analysis_schema`]).
---
--- The rule: a module build.importer calls that can change a row a
--- compile or a parse stores is one of `compiler_roots`, or is reached
--- from one. What it leaves out only stages (build.work),
--- fingerprints, reports (build.symbols' hints, in a refusal's message,
--- which no compile keeps), fails a whole build before any key is looked
--- up (build.positions), or finds the host's caches (build.caches,
--- build/zig.tl): an edit to one compiles and parses nothing again.
--- importer_test's `test_the_compiler_modules_are_closed_under_require`
--- checks the closed semantic boundary and classifies the coordinator's
--- imports outside it.
function identity.compiler_identity(db: Sqlite.Handle): string | nil, string
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
--- answers what a module of the tree requires: every one `require`
--- reaches from `writer_roots`, the standard library's included (down
--- to the SQLite binding that vacuums a projection and the codec that
--- decodes the CA roots into it), except what a root itself requires
--- that `writer_left_out` names. build/importer_test.tl's
--- `test_the_writer_modules_are_closed_under_require` holds that list
--- to the roots' requires.
function identity.writer_modules(requires: function(string): {string} | nil, string): {string} | nil, string
  local roots: {string:boolean} = {}
  for _, name in ipairs(writer_roots) do roots[name] = true end
  local reached: {string:boolean} = {}
  local stack: {string} = {}
  for _, name in ipairs(writer_roots) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if not reached[name] then
      reached[name] = true
      local required, trouble = requires(name)
      if required == nil then return nil, trouble end
      for _, next_name in ipairs(required) do
        if not (roots[name] and writer_left_out[next_name] ~= nil) then
          stack[#stack + 1] = next_name
        end
      end
    end
  end
  local names: {string} = {}
  for name in pairs(reached) do names[#names + 1] = name end
  table.sort(names)
  return names, ""
end

--- What `writer_left_out` names, for build/importer_test.tl to hold
--- the roots' requires to.
function identity.writer_left_out(): {string:string}
  local copy: {string:string} = {}
  for name, why in pairs(writer_left_out) do copy[name] = why end
  return copy
end

--- The writer's identity ([`Identities.writer`]) over what the working
--- database holds now, recorded nowhere: the source hash of each of
--- [`identity.writer_modules`] the tree holds, and the core image's hash
--- (`image_hash`), whose SQLite writes the bytes. What a module requires
--- is what `requires` holds of its source, as for [`compiler_identity`].
--- An edit to a module outside it -- build.positions, build.todo_scan,
--- the analyzer -- writes the same projection from the same rows, so
--- it moves no signature and settles no rebuilt tool.
local function writer_identity(db: Sqlite.Handle): string | nil, string
  local names, trouble = identity.writer_modules(requires_in(db))
  if names == nil then
    return nil, trouble
  end
  return hash_of(db, names,
    "coalesce((SELECT value FROM meta WHERE key = 'image_hash'), '')")
end

--- The identities, computed over the tree and written into `meta` for
--- the projections to carry, and returns them. See [`Identities`] for what
--- each is over. The compiler's closes over `requires`, so the tree must be parsed
--- ([`build.importer.derive`]) first: on a fresh working database the
--- closure would otherwise stop at its roots, and keys
--- made under that identity would match no later build's.
function identity.record_identities(db: Sqlite.Handle): identity.Identities | nil, string
  local compiler, compiler_trouble = identity.compiler_identity(db)
  if compiler == nil then
    return nil, compiler_trouble
  end
  local writer, writer_trouble = writer_identity(db)
  if writer == nil then
    return nil, writer_trouble
  end
  local bases, basis_trouble = Sqlite.text_rows(db,
    "SELECT lower(hex(sha256(" .. pins .. ")))")
  if bases == nil then
    return nil, basis_trouble
  end
  local identities: identity.Identities = {
    compiler = compiler,
    runtime_basis = bases[1][1],
    writer = writer,
  }
  for _, pair in ipairs({ { "compiler", identities.compiler },
                          { "runtime_basis", identities.runtime_basis },
                          { "writer", identities.writer } }) do
    local ok, why = Sqlite.run(db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
      { text(pair[1]), text(pair[2]) })
    if not ok then
      return nil, why
    end
  end
  return identities
end

return identity
