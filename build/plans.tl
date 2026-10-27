--- The plans of a derived tree: every module it holds ([`plans.collect`]), in an order where nothing is compiled before what
--- it imports ([`plans.ordered`]), with the key each is compiled and cached under ([`plans.dependency_keys`]), and the
--- refusals that hold before any module is compiled. The importer owns cache lookup, persistence and diagnostic
--- presentation around these operations; [`build.pipeline`] makes the Lua.

local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local type PolicyRules = require("build.policy_rules")
local type SyntaxReceivers = require("build.syntax_receivers")
local bind = require("build.bind")
local standard_text = require("build.standard_text")
local type module = require("build.module")
local type Module = module.Plan

local record plans
  Module: Module
  --- What compiling one module makes.
  record Generated
    lua: string
    bytecode: string
    --- The record-field uses the checker's types resolved.
    references: {SyntaxReceivers.Reference}
    --- A refusal, its contracts' or its stub's, kept for this unjudged run alone.
    refused: boolean
  end
  --- A module's key and the graph digest less its own file and compiler.
  record Keys
    key: string
    graph: string
  end

  --- The keys of `modules` made from nothing kept ([`plans.dependency_keys`]
  --- without its memos): what each is a function of, which a test holds the
  --- memos to.
  full_keys: function(db: Sqlite.Handle, modules: {Module}, tool: string): {string:Keys}?, string
end

local type Keys = plans.Keys
local text = bind.text

--- What `test_inputs` holds, by source hash: each [`Test.policy`]
--- declaration, as the [`Test.Needs`] it stands for.
local function test_inputs_by_hash(db: Sqlite.Handle): {string:PolicyRules.Declared}?, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, field, value FROM test_inputs ORDER BY source_hash, ordinal")
  if rows == nil then
    return nil, trouble
  end
  local declared: mut {string:PolicyRules.Declared} = {}
  for _, row in ipairs(rows) do
    local hash, field, value = row:text(1), row:text(2), row:text(3)
    local one = declared[hash]
    if one == nil then
      one = { line = 0, reads = {}, host = {}, env = {}, network = {},
        tool = false, lua = false, nests = false, noexec = false, store = false,
        system = false, caches = {}, requires = {} }
      declared[hash] = one
    end
    if field == "line" then
      one.line = math.tointeger(tonumber(value)) or 0
    elseif field == "reads" then
      one.reads[#one.reads + 1] = value
    elseif field == "host" then
      one.host[#one.host + 1] = value
    elseif field == "env" then
      one.env[#one.env + 1] = value
    elseif field == "network" then
      one.network[#one.network + 1] = value
    elseif field == "tool" then
      one.tool = true
    elseif field == "lua" then
      one.lua = true
    elseif field == "nests" then
      one.nests = true
    elseif field == "noexec" then
      one.noexec = true
    elseif field == "store" then
      one.store = true
    elseif field == "system" then
      one.system = true
    elseif field == "caches" then
      one.caches[#one.caches + 1] = value
    elseif field == "parent" then
      local list = one.parent or {}
      one.parent = list
      list[#list + 1] = value
    elseif field == "requires" then
      one.requires[#one.requires + 1] = value
    end
  end
  return declared, ""
end

--- Every name a table keyed by source hash lists, in order, by hash.
local function names_by_hash(db: Sqlite.Handle,
                             table_name: string): {string:{string}}?, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, name FROM " .. table_name ..
      " ORDER BY source_hash, ordinal")
  if rows == nil then
    return nil, trouble
  end
  local out: mut {string:{string}} = {}
  for _, row in ipairs(rows) do
    local list = out[row:text(1)]
    if list == nil then
      list = {}
      out[row:text(1)] = list
    end
    list[#list + 1] = row:text(2)
  end
  return out, ""
end

local record Dependency
  kind: string
  source_hash: string
  requires: {string}
end

--- The names the standard-library module `name` requires, from the
--- `decl_imports` rows of the binary's own database, where
--- [`Store.source`] reads it. Nil and why when that database has no row
--- of it: every database the program runs on carries each module's, a
--- sealed one too (build/test_key.tl's `sealed_fill`, [`Store.seal`]).
local function embedded_edges(name: string): {string}?, string
  local databases = Store.databases()
  local rows, trouble = Sqlite.text_rows(databases[#databases],
    "SELECT requires FROM decl_imports WHERE path = ?1 ORDER BY requires",
    { text(name) })
  if rows == nil then
    return nil, "decl_imports: " .. trouble
  end
  if #rows == 0 then
    return nil, name .. ": the program's database records no edges of it (decl_imports)"
  end
  local out: mut {string} = {}
  for _, row in ipairs(rows) do
    if row:text(1) ~= "" then
      out[#out + 1] = row:text(1)
    end
  end
  return out, ""
end

--- One line of the graph a key is a hash of, for the node `dependency` of
--- `slot`: what [`compute_keys`] keys by, its kind and its source.
local function source_line(slot: string, dependency: Dependency): string
  return slot .. "\n" .. dependency.kind .. "\n" .. dependency.source_hash
end

--- What [`compute_keys`] reads of the tree and of the program's embedded
--- standard library, as a graph walk needs it: each source the checker can
--- load, by slot, and how a name is looked up in them.
local record Graph
  dependencies: {string:Dependency}
  resolve: function(string, string): Dependency?, string
end

local function dependency_graph(db: Sqlite.Handle, modules: {Module}): Graph?, string
  local requires, requires_trouble = names_by_hash(db, "requires")
  if requires == nil then
    return nil, requires_trouble
  end
  local dependencies: mut {string:Dependency} = {}
  local rows, rows_trouble = Sqlite.text_rows(db,
    "SELECT path, kind, source_hash FROM inputs WHERE kind <> 'vendor' " ..
      "ORDER BY path, kind = 'decl' DESC")
  if rows == nil then
    return nil, rows_trouble
  end
  for _, row in ipairs(rows) do
    if dependencies[row:text(1)] == nil then
      dependencies[row:text(1)] = {
        kind = row:text(2), source_hash = row:text(3),
        requires = requires[row:text(3)] or {},
      }
    end
  end
  -- A module's own compile is keyed from its implementation. Imports of
  -- that same path still resolve through `dependencies`, and therefore
  -- through its declaration when it has one.
  for _, m in ipairs(modules) do
    dependencies["\0" .. m.path] = {
      kind = m.kind, source_hash = m.source_hash, requires = m.requires,
    }
  end
  --- The node `slot` names, `name` as the source wrote it: in the tree, or
  --- else an embedded module of the program's standard library, which is
  --- keyed by what the checker reads of it, a stub or a source, and by
  --- which: a project compiled against one is never taken for one compiled
  --- against the other. Nil, and why or "" for no node at all.
  local function resolve(slot: string, name: string): Dependency?, string
    local dependency = dependencies[slot]
    if dependency == nil then
      if name:sub(1, 7) ~= "cosmic." then
        return nil, ""
      end
      local served = standard_text.of(name)
      if served == nil then
        local _, source_trouble = Store.source(name)
        return nil, source_trouble
      end
      local embedded_requires, edges_trouble = embedded_edges(name)
      if embedded_requires == nil then
        return nil, edges_trouble
      end
      dependency = {
        kind = if served.stubbed then "embedded stub" else "embedded" end,
        source_hash = Hash.hex_sha256(served.text),
        requires = embedded_requires,
      }
      dependencies[slot] = dependency
    end
    return dependency, ""
  end
  return { dependencies = dependencies, resolve = resolve }, ""
end

--- The key of `name` (`file` its file) over the nodes it reaches, each as
--- `line_of` says, and `tool`; and the graph digest less the file and tool.
--- Hash the reachable graph as a sorted set rather than recursively
--- hashing one node into another. Declarations can legally refer to each
--- other, and a set closes over those cycles without making traversal
--- order part of the key. When a declaration shadows an implementation,
--- both matter: the checker reads the declaration, while the generated
--- `require` loads the implementation at runtime.
--- A module's own compile is keyed by its file as well as its import
--- path (`file` below): `x.tl` and `x/init.tl` are both `x`, and
--- build.syntax_contracts names its exemptions by file, so a module moved
--- from one to the other is compiled again under its new file's rules.
--- Only the key holds it: the graph key ([`build.positions`]'
--- `graph_key`) is the import graph's by name and content, and a
--- dependency's file decides nothing of this compile.
local function identify_in(known: Graph, name: string, file: string,
                           tool: string, line_of: function(string, Dependency): string):
    Keys?, string
  local dependencies, resolve = known.dependencies, known.resolve
  local seen: mut {string:boolean} = {}
  local graph: mut {string} = {}
  local function visit(slot: string, display: string): boolean, string
    if seen[slot] then
      return true, ""
    end
    local dependency, resolve_trouble = resolve(slot, display)
    if dependency == nil then
      if resolve_trouble ~= "" then return false, resolve_trouble end
      return true, ""
    end
    seen[slot] = true
    graph[#graph + 1] = line_of(slot, dependency)
    for _, required in ipairs(dependency.requires) do
      local child, child_trouble = resolve(required, required)
      if child == nil and child_trouble ~= "" then
        return false, child_trouble
      end
      if child ~= nil then
        graph[#graph + 1] = slot .. "\nrequires\n" .. required
        local ok, trouble = visit(required, required)
        if not ok then
          return false, trouble
        end
        if child.kind == "decl" and dependencies["\0" .. required] ~= nil then
          graph[#graph + 1] = slot .. "\nloads\n" .. required
          ok, trouble = visit("\0" .. required, required)
          if not ok then
            return false, trouble
          end
        end
      end
    end
    return true, ""
  end
  local ok, trouble = visit("\0" .. name, name)
  if not ok then
    return nil, trouble
  end
  table.sort(graph)
  local sources = table.concat(graph, "\n\0\n")
  return { key = Hash.hex_sha256(sources .. "\n\0\nfile\n" .. file .. "\n" .. tool),
    graph = Hash.hex_sha256(sources) }, ""
end

--- The identity of every source the checker can load from this tree.
--- A declaration wins over a source of the same name, just as
--- the checker's module search does. An embedded standard-library
--- module is content-addressed by what the checker reads of it when a
--- project imports it ([`standard_text`]). Each module's
--- [`Keys`], by path.
local function compute_keys(db: Sqlite.Handle, modules: {Module},
                            tool: string): {string:Keys}?, string
  local graph, trouble = dependency_graph(db, modules)
  if graph == nil then
    return nil, trouble
  end
  local out: mut {string:Keys} = {}
  for _, m in ipairs(modules) do
    local keys, identify_trouble = identify_in(graph, m.path, m.file, tool, source_line)
    if keys == nil then
      return nil, identify_trouble
    end
    out[m.path] = keys
  end
  return out, ""
end

--- What one node of the graph adds to the digest of every module that reaches
--- it: its own lines -- its kind and source, and an edge to each node it
--- requires that there is one of (`requires`, and `loads` where a
--- declaration's implementation is loaded beside it) -- sorted and joined as
--- [`identify_in`] joins them, with their digest, and the nodes it leads to.
local record Fragment
  text: string
  digest: string
  children: {string}
end

--- `a < b` over bytes, which orders strings as `table.sort` does with none.
local function by_bytes(a: string, b: string): boolean
  return a < b
end

--- `list` sorted by bytes, as a list of its own.
local function sorted(list: {string}): {string}
  local out: mut {string} = {}
  for _, one in ipairs(list) do out[#out + 1] = one end
  table.sort(out, by_bytes)
  return out
end

--- The [`Fragment`] of each slot of `known`, as [`identify_in`] walks them
--- (`line_of` is its way of spelling a node), made when first asked for and
--- kept. Nil and why where a name cannot be resolved, "" for no node.
local function fragments_in(known: Graph, line_of: function(string, Dependency): string):
    function(string): Fragment?, string
  local made: mut {string:Fragment} = {}
  return function(slot: string): Fragment?, string
    local kept = made[slot]
    if kept ~= nil then return kept, "" end
    -- `visit`'s display name: the slot less the mark of an implementation.
    local display = slot
    if slot:sub(1, 1) == "\0" then display = slot:sub(2) end
    local dependency, resolve_trouble = known.resolve(slot, display)
    if dependency == nil then return nil, resolve_trouble end
    local lines: mut {string} = { line_of(slot, dependency) }
    local children: mut {string} = {}
    for _, required in ipairs(dependency.requires) do
      local child, child_trouble = known.resolve(required, required)
      if child == nil and child_trouble ~= "" then return nil, child_trouble end
      if child ~= nil then
        lines[#lines + 1] = slot .. "\nrequires\n" .. required
        children[#children + 1] = required
        if child.kind == "decl" and known.dependencies["\0" .. required] ~= nil then
          lines[#lines + 1] = slot .. "\nloads\n" .. required
          children[#children + 1] = "\0" .. required
        end
      end
    end
    local text_of = table.concat(sorted(lines), "\n\0\n")
    local fragment: Fragment = { text = text_of, digest = Hash.hex_sha256(text_of), children = children }
    made[slot] = fragment
    return fragment, ""
  end
end

--- What a module's compile was keyed by the last time [`fast_keys`] made
--- it, and under which compiler.
local record KeptKeys
  file: string
  key: string
  graph: string
end

--- What the last [`fast_keys`] kept under `tool`: each module's keys by path
--- and each node's fragment digest by slot, or nil where it kept none. Both
--- are written together and replaced together, in one transaction.
local function kept_graph(db: Sqlite.Handle, tool: string): {string:KeptKeys}?, {string:string}?
  local modules, _ = Sqlite.text_rows(db,
    "SELECT path, file, key, graph FROM key_memo WHERE tool = ?1", { text(tool) })
  local slots, _ = Sqlite.text_rows(db,
    "SELECT slot, digest FROM key_frags WHERE tool = ?1", { text(tool) })
  if modules == nil or slots == nil or #modules == 0 or #slots == 0 then return nil, nil end
  local keys: mut {string:KeptKeys} = {}
  for _, row in ipairs(modules) do
    keys[row:text(1)] = { file = row:text(2), key = row:text(3), graph = row:text(4) }
  end
  local digests: mut {string:string} = {}
  for _, row in ipairs(slots) do digests[row:text(1)] = row:text(2) end
  return keys, digests
end

--- Replaces what [`kept_graph`] answers with `out` and `fragments`, under
--- `tool`. A failure costs only the next run's compute.
local function keep_graph(db: Sqlite.Handle, tool: string, modules: {Module}, out: {string:Keys},
                          fragments: {string:Fragment})
  local cleared, _ = db:exec("DELETE FROM key_memo; DELETE FROM key_frags")
  if not cleared then return end
  local put_module, _ = db:prepare(
    "INSERT INTO key_memo (path, tool, file, key, graph) VALUES (?1, ?2, ?3, ?4, ?5)")
  local put_slot, _ = db:prepare("INSERT INTO key_frags (slot, tool, digest) VALUES (?1, ?2, ?3)")
  if put_module == nil or put_slot == nil then
    if put_module ~= nil then put_module:finalize() end
    if put_slot ~= nil then put_slot:finalize() end
    return
  end
  local module_put: Sqlite.Statement = put_module
  local slot_put: Sqlite.Statement = put_slot
  --- Binds `values` in order and runs the statement once.
  local function put(statement: Sqlite.Statement, values: {string}): boolean
    for index, value in ipairs(values) do
      local bound, _ = statement:bind_text(index, value)
      if not bound then return false end
    end
    local done, _ = bind.once(statement)
    return done
  end
  for _, m in ipairs(modules) do
    local one = out[m.path]
    if one == nil or not put(module_put, { m.path, tool, m.file, one.key, one.graph }) then
      break
    end
  end
  for slot, fragment in pairs(fragments) do
    if not put(slot_put, { slot, tool, fragment.digest }) then break end
  end
  module_put:finalize()
  slot_put:finalize()
end

--- The keys [`compute_keys`] makes, from what changed since the last
--- ones this made under `tool` rather than every module's whole graph: each
--- node's [`Fragment`] is made once, a module's graph is its reachable
--- nodes' fragments in the order of their slots, and a module that
--- reaches no node whose fragment differs from the kept one, and has the
--- same file, keeps the keys it had. That is the same as making them: the
--- lines of the nodes a module reaches are the whole of what its key is a
--- function of (its file and `tool` beside), and a node it no longer reaches
--- is one an edge of a node it does reach has dropped, whose fragment names
--- that edge. The lines sort as their fragments do because a slot's lines
--- all start with it and a newline, which sorts below every byte a name
--- has, so that one slot that begins another has its lines first.
---
--- Nil, to be made by [`compute_keys`], where a name has a byte
--- that does not hold to that, or the tree cannot be read as it reads it,
--- which it then says in its own words.
local function fast_keys(db: Sqlite.Handle, modules: {Module}, tool: string): {string:Keys}?
  local graph, _ = dependency_graph(db, modules)
  if graph == nil then return nil end
  local fragment_of = fragments_in(graph, source_line)
  local made: mut {string:Fragment} = {}
  local pending: mut {string} = {}
  for _, m in ipairs(modules) do pending[#pending + 1] = "\0" .. m.path end
  local head = 1
  while head <= #pending do
    local slot = pending[head]
    head = head + 1
    if slot ~= nil and made[slot] == nil then
      local fragment, _ = fragment_of(slot)
      if fragment == nil then return nil end
      made[slot] = fragment
      for _, child in ipairs(fragment.children) do
        if made[child] == nil then pending[#pending + 1] = child end
      end
    end
  end
  -- A name with a byte below a newline after its first is not one the order of the slots holds for.
  local slots: mut {string} = {}
  for slot, _ in pairs(made) do
    if slot:find("[\0-\10]", 2) ~= nil then return nil end
    slots[#slots + 1] = slot
  end
  local ordered = sorted(slots)

  local kept, digests = kept_graph(db, tool)
  -- The nodes that differ from the kept ones, and each that reaches one.
  local affected: mut {string:boolean} = {}
  if kept ~= nil and digests ~= nil then
    local leading: mut {string:{string}} = {}
    local queue: mut {string} = {}
    for slot, fragment in pairs(made) do
      for _, child in ipairs(fragment.children) do
        local list = leading[child]
        if list == nil then
          list = {}
          leading[child] = list
        end
        list[#list + 1] = slot
      end
      if digests[slot] ~= fragment.digest then
        affected[slot] = true
        queue[#queue + 1] = slot
      end
    end
    local front = 1
    while front <= #queue do
      local slot = queue[front]
      front = front + 1
      if slot ~= nil then
        for _, parent in ipairs(leading[slot] or {}) do
          if affected[parent] ~= true then
            affected[parent] = true
            queue[#queue + 1] = parent
          end
        end
      end
    end
  end

  local out: mut {string:Keys} = {}
  local made_any = kept == nil
  for _, m in ipairs(modules) do
    local root = "\0" .. m.path
    local before: KeptKeys? = nil
    if kept ~= nil then before = kept[m.path] end
    if before ~= nil and affected[root] ~= true and before.file == m.file then
      out[m.path] = { key = before.key, graph = before.graph }
    else
      made_any = true
      local seen: mut {string:boolean} = {}
      local stack: mut {string} = { root }
      local top = 1
      while top <= #stack do
        local slot = stack[top]
        top = top + 1
        if slot ~= nil and seen[slot] ~= true then
          seen[slot] = true
          local fragment = made[slot]
          if fragment ~= nil then
            for _, child in ipairs(fragment.children) do
              if seen[child] ~= true then stack[#stack + 1] = child end
            end
          end
        end
      end
      local texts: mut {string} = {}
      for _, slot in ipairs(ordered) do
        local fragment = made[slot]
        if seen[slot] == true and fragment ~= nil then texts[#texts + 1] = fragment.text end
      end
      local sources = table.concat(texts, "\n\0\n")
      out[m.path] = { key = Hash.hex_sha256(sources .. "\n\0\nfile\n" .. m.file .. "\n" .. tool),
        graph = Hash.hex_sha256(sources) }
    end
  end
  if made_any or digests == nil then keep_graph(db, tool, modules, out, made) end
  return out
end

--- Everything [`compute_keys`] reads, as one digest: the compiler's
--- `tool`, every `inputs` row but the compiler's (a module's kind,
--- path and source hash decide the graph it is in), every `requires`
--- row (what each source hash imports), and each module's own path,
--- file, kind and source hash. Nil where the database will not say.
local function keys_fingerprint(db: Sqlite.Handle, modules: {Module}, tool: string): string?
  local rows, _ = Sqlite.text_rows(db,
    "SELECT coalesce((SELECT lower(hex(sha256(group_concat(path || char(1) || kind || char(1) || " ..
      "source_hash, char(10) ORDER BY path, kind, source_hash)))) FROM inputs WHERE kind <> 'vendor'), ''), " ..
      "coalesce((SELECT lower(hex(sha256(group_concat(source_hash || char(1) || ordinal || char(1) || " ..
      "name, char(10) ORDER BY source_hash, ordinal, name)))) FROM requires), '')")
  if rows == nil then return nil end
  local row = rows[1]
  if row == nil then return nil end
  local parts: mut {string} = { "keys-memo-1", tool, row:text(1), row:text(2) }
  for _, m in ipairs(modules) do
    parts[#parts + 1] = m.path .. "\1" .. m.file .. "\1" .. m.kind .. "\1" .. m.source_hash
  end
  return Hash.hex_sha256(table.concat(parts, "\0"))
end

--- How many fingerprints' keys `keys_memo` holds: a build that
--- alternates between tools (a run with run-time checks, a boot) keeps
--- the keys of each.
local kept_fingerprints <const> = 4

--- The keys `keys_memo` holds under `fingerprint`, one line a module
--- (path, key, graph, tab-separated), where they name exactly `modules`.
local function remembered_keys(db: Sqlite.Handle, fingerprint: string,
                               modules: {Module}): {string:Keys}?
  local rows, _ = Sqlite.text_rows(db, "SELECT body FROM keys_memo WHERE fp = ?1", { text(fingerprint) })
  if rows == nil then return nil end
  local row = rows[1]
  if row == nil then return nil end
  local out: mut {string:Keys} = {}
  local count = 0
  for path, key, graph in row:text(1):gmatch("([^\t\n]+)\t([^\t\n]+)\t([^\t\n]+)\n") do
    out[path] = { key = key, graph = graph }
    count = count + 1
  end
  if count ~= #modules then return nil end
  for _, m in ipairs(modules) do
    if out[m.path] == nil then return nil end
  end
  return out
end

--- Keeps `keys` under `fingerprint`, and drops all but the newest
--- `kept_fingerprints`. A failure costs only the next run's compute.
local function keep_keys(db: Sqlite.Handle, fingerprint: string, modules: {Module},
                         keys: {string:Keys})
  local lines: mut {string} = {}
  for _, m in ipairs(modules) do
    local one = keys[m.path]
    if one == nil then return end
    lines[#lines + 1] = m.path .. "\t" .. one.key .. "\t" .. one.graph .. "\n"
  end
  local kept, _ = Sqlite.run(db, "INSERT OR REPLACE INTO keys_memo (fp, body) VALUES (?1, ?2)",
    { text(fingerprint), text(table.concat(lines)) })
  if not kept then return end
  local _, _ = Sqlite.run(db, "DELETE FROM keys_memo WHERE id <= (SELECT max(id) FROM keys_memo) - ?1",
    { { integer = kept_fingerprints } })
end

--- [`compute_keys`], or what it computed before for these same inputs:
--- the digest of a module's whole import graph is some 0.3 s for a tree
--- of a thousand modules, and a run where nothing changed asks it again.
--- The memo is `keys_memo` of the working database, keyed by
--- [`keys_fingerprint`], which holds everything the computation reads.
function plans.dependency_keys(db: Sqlite.Handle, modules: {Module},
                               tool: string): {string:Keys}?, string
  local fingerprint = keys_fingerprint(db, modules, tool)
  if fingerprint ~= nil then
    local kept = remembered_keys(db, fingerprint, modules)
    if kept ~= nil then return kept, "" end
  end
  local keys: {string:Keys}
  local fast = fast_keys(db, modules, tool)
  if fast ~= nil then
    keys = fast
  else
    local full, trouble = compute_keys(db, modules, tool)
    if full == nil then return nil, trouble end
    keys = full
  end
  if fingerprint ~= nil then keep_keys(db, fingerprint, modules, keys) end
  return keys, ""
end

plans.full_keys = compute_keys

--- Why a build refuses the module `file` of `kind` that declares what
--- its tests read (`inputs`, [`Test.policy`]), or nil when it does not:
--- a declaration holds for the tests of its own module, and a module
--- that is no test's has none. What a module it requires reads, the
--- test declares.
function plans.policy_refusal(file: string, kind: string,
                              inputs: PolicyRules.Declared?): string?
  if inputs == nil or kind == "test" or kind == "example" then
    return nil
  end
  return file .. ":" .. tostring(inputs.line) .. ": test.policy: only a test or example " ..
    "module declares what its tests read; call it in each test module that " ..
    "requires this one"
end

--- Every module the derived tree holds ([`build.importer.derive`]), with what
--- its parse found.
function plans.collect(db: Sqlite.Handle): {Module}?, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.path, i.file, i.kind, i.origin, i.source, i.source_hash, " ..
      "p.has_return, s.source_hash IS NOT NULL, " ..
      -- Only cosmic's own build reads a stub, of a standard-library module.
      "CASE WHEN i.path GLOB 'cosmic.*' THEN s.text ELSE '' END, coalesce(s.pruned, 0) " ..
      "FROM inputs i JOIN parsed p ON p.source_hash = i.source_hash " ..
      "LEFT JOIN stubs s ON s.source_hash = i.source_hash " ..
      "WHERE i.kind NOT IN ('decl', 'vendor') ORDER BY i.path")
  if rows == nil then
    return nil, trouble
  end
  local requires, requires_trouble = names_by_hash(db, "requires")
  if requires == nil then
    return nil, requires_trouble
  end
  local tests, tests_trouble = names_by_hash(db, "tests")
  if tests == nil then
    return nil, tests_trouble
  end
  local examples, examples_trouble = names_by_hash(db, "examples")
  if examples == nil then
    return nil, examples_trouble
  end
  local declared, inputs_trouble = test_inputs_by_hash(db)
  if declared == nil then
    return nil, inputs_trouble
  end
  local out: mut {Module} = {}
  for _, row in ipairs(rows) do
    local path, file, kind, origin = row:text(1), row:text(2), row:text(3), row:text(4)
    local source, source_hash, has_return = row:text(5), row:text(6), row:text(7)
    local inputs = declared[source_hash]
    local misplaced = plans.policy_refusal(file, kind, inputs)
    if misplaced ~= nil then
      return nil, misplaced
    end
    out[#out + 1] = {
      path = path,
      file = file,
      kind = kind,
      source = source,
      source_hash = source_hash,
      requires = requires[source_hash] or {},
      tests = kind == "test" and (tests[source_hash] or {}) or
        kind == "example" and (examples[source_hash] or {}) or
        {},
      inputs = inputs,
      has_top_level_return = has_return == "1",
      generated = origin == "doctest" or origin == "template",
      key = "",
      graph_key = "",
      lua = "",
      stub = if row:text(8) == "1" then { text = row:text(9), pruned = row:text(10) == "1" } else nil end,
    }
  end
  return out, ""
end

--- The modules in an order where nothing is compiled before what it
--- imports. A cycle is reported rather than looped on.
function plans.ordered(modules: {Module}): {Module}?, string
  local by_path: mut {string:Module} = {}
  for _, m in ipairs(modules) do
    by_path[m.path] = m
  end

  local out: mut {Module} = {}
  local state: mut {string:string} = {}

  local function visit(m: Module): boolean, string
    if state[m.path] == "done" then
      return true, ""
    end
    if state[m.path] == "visiting" then
      return false, "a cycle of imports reaches " .. m.path
    end
    state[m.path] = "visiting"
    for _, name in ipairs(m.requires) do
      local other = by_path[name]
      if other ~= nil then
        local ok, trouble = visit(other)
        if not ok then
          return false, trouble
        end
      end
    end
    state[m.path] = "done"
    out[#out + 1] = m
    return true, ""
  end

  for _, m in ipairs(modules) do
    local ok, trouble = visit(m)
    if not ok then
      return nil, trouble
    end
  end
  return out, ""
end

--- Whether `m`'s own source both defines tests of its own and returns
--- its own value at the top level. LuaTail.with_test_tail appends a generated
--- `return` after the module's compiled Lua, and Lua allows only one
--- `return` as a block's last statement, so the two together are always
--- a parse error. Both facts come from `collect`'s one parse of
--- `m.source`; this reads what `m` carries and parses nothing.
local function collides_with_test_tail(m: Module): boolean
  return #m.tests > 0 and m.has_top_level_return
end

--- Whether an example module found `Example.<name>` functions but has
--- no top-level `return` to hand any of them back: unlike a test
--- module, an example module gets no generated tail, since its own
--- `return Example` is what the runner and `cosmic docs` both need
--- reachable from outside the file.
--- Caught here, at compile time, rather than left to fail the moment
--- the runner indexes a table that `require` handed back as `true`.
local function missing_example_return(m: Module): boolean
  return #m.tests > 0 and not m.has_top_level_return
end

--- Why a cosmic build refuses a global declared at `at` (`file:line:column`).
function plans.global_refusal(at: string): string
  return at .. ": a global is not allowed in a cosmic build: it reaches other modules by no " ..
    "`require`, which is all a build's cache and its order see -- put the value " ..
    "in a module and `require` it"
end

--- Why the build may not go on: the globals declared by any source the
--- tree holds but tl's own, one line each at the declaration, in file
--- order, or nil when there are none. A module's compile key holds its
--- kind, its source, the keys of what it requires and the compiler, and a
--- global reaches other modules by none of those: a cached compile could
--- stand after the global's type changed, and what a build accepts would
--- depend on the order modules are checked in. The declarations are the
--- rows a parse kept (build.globals) for every source, a `.d.tl`
--- and a compile that stands in a cache included, so the refusal is made
--- before any module is compiled, and does not depend on that order.
function plans.refuse_globals(db: Sqlite.Handle): string?, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.file, g.line, g.column FROM inputs i JOIN globals g " ..
      "ON g.source_hash = i.source_hash WHERE i.kind <> 'vendor' " ..
      "ORDER BY i.file, g.line, g.column")
  if rows == nil then
    return nil, trouble
  end
  if #rows == 0 then
    return nil, ""
  end
  local lines: mut {string} = {}
  for _, row in ipairs(rows) do
    lines[#lines + 1] = plans.global_refusal(row:text(1) .. ":" .. row:text(2) .. ":" ..
        row:text(3))
  end
  return table.concat(lines, "\n"), ""
end

--- The record-field uses one compile found, kept under its key beside
--- the compile itself, replacing whatever an earlier compile under the
--- same key left.
function plans.keep_references(db: Sqlite.Handle, key: string,
                               references: {SyntaxReceivers.Reference}): boolean, string
  local ok, why = Sqlite.run(db, "DELETE FROM typed_refs WHERE key = ?1", { text(key) })
  if not ok then
    return false, why
  end
  for ordinal, entry in ipairs(references) do
    ok, why = Sqlite.run(db,
      "INSERT INTO typed_refs (key, ordinal, module, member, line) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5)",
      { text(key), { integer = ordinal }, text(entry.module), text(entry.member),
        { integer = entry.line } })
    if not ok then
      return false, why
    end
  end
  return true, ""
end

--- A discovered test or example that cannot hand its functions back.
--- Checked before cache lookup, so a former cached compile cannot hide it.
function plans.refusal(m: Module): string?
  if m.kind == "test" and collides_with_test_tail(m) then
    return m.file .. ": a test file may not both " ..
      "define test_* functions and return its own value; remove the " ..
      "top-level return so the generated tail can hand the runner " ..
      "its tests"
  elseif m.kind == "example" and missing_example_return(m) then
    return m.file .. ": an example file " ..
      "must return the table its Example.* functions are declared on " ..
      "(`return Example`), or the runner has nothing to call"
  end
  return nil
end

return plans
