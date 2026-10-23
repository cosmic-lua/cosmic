--- The semantic compile: module plans, dependency keys, acceptance,
--- generated Lua, bytecode and typed references. The importer owns cache
--- lookup, persistence and diagnostic presentation around these operations.

local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local analyzer = require("build.analyzer")
local ast = require("build.ast")
local contracts = require("build.contracts")
local LuaTail = require("build.lua_tail")
local receivers = require("build.receivers")
local shape_specs = require("build.shape_specs")
local stub = require("build.stub")
local teal = require("build.teal")
local bind = require("build.bind")
local type compiler = require("build.compiler")
local type module = require("build.module")
local type Module = module.Plan

local record compilation
  Module: Module
  --- What compiling one module makes.
  record Generated
    lua: string
    bytecode: string
    --- The record-field uses the checker's types resolved.
    references: {receivers.Reference}
    --- A refusal, its contracts' or its stub's, kept for this unjudged run alone.
    refused: boolean
  end
  --- A module's key and the graph digest less its own file and compiler.
  record Keys
    key: string
    graph: string
  end

  --- The keys of `modules` made from nothing kept ([`compilation.dependency_keys`]
  --- without its memos): what each is a function of, which a test holds the
  --- memos to.
  full_keys: function(db: Sqlite.Handle, modules: {Module}, tool: string): {string:Keys} | nil, string
end

local type Keys = compilation.Keys
local text = bind.text

--- What `test_inputs` holds, by source hash: each [`Test.policy`]
--- declaration, as the [`Test.Needs`] it stands for.
local function test_inputs_by_hash(db: Sqlite.Handle): {string:analyzer.Declared} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, field, value FROM test_inputs ORDER BY source_hash, ordinal")
  if rows == nil then
    return nil, trouble
  end
  local declared: {string:analyzer.Declared} = {}
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
                             table_name: string): {string:{string}} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, name FROM " .. table_name ..
      " ORDER BY source_hash, ordinal")
  if rows == nil then
    return nil, trouble
  end
  local out: {string:{string}} = {}
  for _, row in ipairs(rows) do
    local list = out[row:text(1)]
    if list == nil then
      list = {}
      out[row:text(1)] = list
    end
    list[#list + 1] = row:text(2)
  end
  return out
end

local record Dependency
  kind: string
  source_hash: string
  requires: {string}
end

--- The interface key of a module ([`compilation.interface_keys`]), or nil
--- and why.
local type Interfaced = function(Module): string | nil, string

--- The names the standard-library module `name` requires, from the
--- `decl_imports` rows of the binary's own database, where
--- [`Store.source`] reads it. Nil and why when that database has no row
--- of it: every database the program runs on carries each module's, a
--- sealed one too (build/test.tl's `sealed_fill`, [`Store.seal`]).
local function embedded_edges(name: string): {string} | nil, string
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
  local out: {string} = {}
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
  resolve: function(string, string): Dependency | nil, string
end

local function dependency_graph(db: Sqlite.Handle, modules: {Module}): Graph | nil, string
  local requires, requires_trouble = names_by_hash(db, "requires")
  if requires == nil then
    return nil, requires_trouble
  end
  local dependencies: {string:Dependency} = {}
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
  local function resolve(slot: string, name: string): Dependency | nil, string
    local dependency = dependencies[slot]
    if dependency == nil then
      if name:sub(1, 7) ~= "cosmic." then
        return nil, ""
      end
      local served = teal.standard_text(name)
      if served == nil then
        local _, source_trouble = Store.source(name)
        return nil, source_trouble
      end
      local embedded_requires, edges_trouble = embedded_edges(name)
      if embedded_requires == nil then
        return nil, edges_trouble
      end
      dependency = {
        kind = served.stubbed and "embedded stub" or "embedded",
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
--- build.contracts names its exemptions by file, so a module moved
--- from one to the other is compiled again under its new file's rules.
--- Only the key holds it: the graph key ([`build.positions`]'
--- `graph_key`) is the import graph's by name and content, and a
--- dependency's file decides nothing of this compile.
local function identify_in(known: Graph, name: string, file: string,
                           tool: string, line_of: function(string, Dependency): string):
    Keys | nil, string
  local dependencies, resolve = known.dependencies, known.resolve
  local seen: {string:boolean} = {}
  local graph: {string} = {}
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
--- [`build.teal`]'s module search does. An embedded standard-library
--- module is content-addressed by what the checker reads of it when a
--- project imports it ([`teal.standard_text`]). Each module's
--- [`Keys`], by path.
local function compute_keys(db: Sqlite.Handle, modules: {Module},
                            tool: string): {string:Keys} | nil, string
  local graph, trouble = dependency_graph(db, modules)
  if graph == nil then
    return nil, trouble
  end
  local out: {string:Keys} = {}
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
  local out: {string} = {}
  for _, one in ipairs(list) do out[#out + 1] = one end
  table.sort(out, by_bytes)
  return out
end

--- The [`Fragment`] of each slot of `known`, as [`identify_in`] walks them
--- (`line_of` is its way of spelling a node), made when first asked for and
--- kept. Nil and why where a name cannot be resolved, "" for no node.
local function fragments_in(known: Graph, line_of: function(string, Dependency): string):
    function(string): Fragment | nil, string
  local made: {string:Fragment} = {}
  return function(slot: string): Fragment | nil, string
    local kept = made[slot]
    if kept ~= nil then return kept, "" end
    -- `visit`'s display name: the slot less the mark of an implementation.
    local display = slot
    if slot:sub(1, 1) == "\0" then display = slot:sub(2) end
    local dependency, resolve_trouble = known.resolve(slot, display)
    if dependency == nil then return nil, resolve_trouble end
    local lines: {string} = { line_of(slot, dependency) }
    local children: {string} = {}
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
local function kept_graph(db: Sqlite.Handle, tool: string): {string:KeptKeys} | nil, {string:string} | nil
  local modules, _ = Sqlite.text_rows(db,
    "SELECT path, file, key, graph FROM key_memo WHERE tool = ?1", { text(tool) })
  local slots, _ = Sqlite.text_rows(db,
    "SELECT slot, digest FROM key_frags WHERE tool = ?1", { text(tool) })
  if modules == nil or slots == nil or #modules == 0 or #slots == 0 then return nil, nil end
  local keys: {string:KeptKeys} = {}
  for _, row in ipairs(modules) do
    keys[row:text(1)] = { file = row:text(2), key = row:text(3), graph = row:text(4) }
  end
  local digests: {string:string} = {}
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
local function fast_keys(db: Sqlite.Handle, modules: {Module}, tool: string): {string:Keys} | nil
  local graph, _ = dependency_graph(db, modules)
  if graph == nil then return nil end
  local fragment_of = fragments_in(graph, source_line)
  local made: {string:Fragment} = {}
  local pending: {string} = {}
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
  local slots: {string} = {}
  for slot, _ in pairs(made) do
    if slot:find("[\0-\10]", 2) ~= nil then return nil end
    slots[#slots + 1] = slot
  end
  local ordered = sorted(slots)

  local kept, digests = kept_graph(db, tool)
  -- The nodes that differ from the kept ones, and each that reaches one.
  local affected: {string:boolean} = {}
  if kept ~= nil and digests ~= nil then
    local leading: {string:{string}} = {}
    local queue: {string} = {}
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

  local out: {string:Keys} = {}
  local made_any = kept == nil
  for _, m in ipairs(modules) do
    local root = "\0" .. m.path
    local before: KeptKeys | nil = nil
    if kept ~= nil then before = kept[m.path] end
    if before ~= nil and affected[root] ~= true and before.file == m.file then
      out[m.path] = { key = before.key, graph = before.graph }
    else
      made_any = true
      local seen: {string:boolean} = {}
      local stack: {string} = { root }
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
      local texts: {string} = {}
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
local function keys_fingerprint(db: Sqlite.Handle, modules: {Module}, tool: string): string | nil
  local rows, _ = Sqlite.text_rows(db,
    "SELECT coalesce((SELECT lower(hex(sha256(group_concat(path || char(1) || kind || char(1) || " ..
      "source_hash, char(10) ORDER BY path, kind, source_hash)))) FROM inputs WHERE kind <> 'vendor'), ''), " ..
      "coalesce((SELECT lower(hex(sha256(group_concat(source_hash || char(1) || ordinal || char(1) || " ..
      "name, char(10) ORDER BY source_hash, ordinal, name)))) FROM requires), '')")
  if rows == nil then return nil end
  local row = rows[1]
  if row == nil then return nil end
  local parts: {string} = { "keys-memo-1", tool, row:text(1), row:text(2) }
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
                               modules: {Module}): {string:Keys} | nil
  local rows, _ = Sqlite.text_rows(db, "SELECT body FROM keys_memo WHERE fp = ?1", { text(fingerprint) })
  if rows == nil then return nil end
  local row = rows[1]
  if row == nil then return nil end
  local out: {string:Keys} = {}
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
  local lines: {string} = {}
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
function compilation.dependency_keys(db: Sqlite.Handle, modules: {Module},
                                     tool: string): {string:Keys} | nil, string
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

compilation.full_keys = compute_keys

--- Why a build refuses the module `file` of `kind` that declares what
--- its tests read (`inputs`, [`Test.policy`]), or nil when it does not:
--- a declaration holds for the tests of its own module, and a module
--- that is no test's has none. What a module it requires reads, the
--- test declares.
function compilation.policy_refusal(file: string, kind: string,
                                    inputs: analyzer.Declared | nil): string | nil
  if inputs == nil or kind == "test" or kind == "example" then
    return nil
  end
  return file .. ":" .. inputs.line .. ": test.policy: only a test or example " ..
    "module declares what its tests read; call it in each test module that " ..
    "requires this one"
end

--- Every module the derived tree holds ([`build.importer.derive`]), with what
--- its parse found.
function compilation.collect(db: Sqlite.Handle): {Module} | nil, string
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
  local out: {Module} = {}
  for _, row in ipairs(rows) do
    local path, file, kind, origin = row:text(1), row:text(2), row:text(3), row:text(4)
    local source, source_hash, has_return = row:text(5), row:text(6), row:text(7)
    local inputs = declared[source_hash]
    local misplaced = compilation.policy_refusal(file, kind, inputs)
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
      stub = row:text(8) == "1" and { text = row:text(9), pruned = row:text(10) == "1" } or nil,
    }
  end
  return out, ""
end

--- The modules in an order where nothing is compiled before what it
--- imports. A cycle is reported rather than looped on.
function compilation.ordered(modules: {Module}): {Module} | nil, string
  local by_path: {string:Module} = {}
  for _, m in ipairs(modules) do
    by_path[m.path] = m
  end

  local out: {Module} = {}
  local state: {string:string} = {}

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
  return out
end

--- A `local function test_*` at a test module's top level is only ever
--- called by the runner, from outside the file, so the checker's
--- "unused function" warning about it is a false positive: it is
--- narrow enough to name the exact function discovery already found,
--- rather than turning the warning off for the whole file.
local function discount_test_warnings(result: compiler.Result,
                                      tests: {string}): compiler.Result
  local names: {string:boolean} = {}
  for _, name in ipairs(tests) do
    names[name] = true
  end
  local kept: {compiler.Error} = {}
  for _, w in ipairs(result.warnings) do
    local unused = w.code == "unused" and w.declares == "function" and w.variable or nil
    if unused == nil or not names[unused] then
      kept[#kept + 1] = w
    end
  end
  result.warnings = kept
  return result
end

--- Drops the one warning tl's checker always raises over a
--- [`build.doctest`] generated module: an example that declares an
--- `output` block shadows the global `print` with a local of the same
--- name, so a doc's own `print(...)` calls run against the capturing
--- one. The shadow is on purpose: `print` is `<const>` in tl's prelude,
--- so reassigning the global is a type error, and a local is the only
--- way to intercept a bare `print`. It drops less than
--- [`discount_test_warnings`] but applies more widely: to any module
--- `m.generated` marks, not only to functions a scan of `m` found.
local function discount_doctest_shadow_warnings(result: compiler.Result): compiler.Result
  local kept: {compiler.Error} = {}
  for _, w in ipairs(result.warnings) do
    if not (w.code == "shadows" and w.declares == "variable" and w.variable == "print" and
        not w.declared_before) then
      kept[#kept + 1] = w
    end
  end
  result.warnings = kept
  return result
end

--- Whether `m`'s own source both defines tests of its own and returns
--- its own value at the top level. [`LuaTail.with_test_tail`] appends a generated
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
--- reachable from outside the file -- see [`analyzer.ExampleEntry`].
--- Caught here, at compile time, rather than left to fail the moment
--- the runner indexes a table that `require` handed back as `true`.
local function missing_example_return(m: Module): boolean
  return #m.tests > 0 and not m.has_top_level_return
end

--- Whether the stub ([`build.stub`]) of the module `m`, which `result`
--- is the checker's reading of, types it the same, and if not why: a stub
--- that is not declaration-only (or none, for a module that returns
--- nothing), a type error in the stub, or where its type and
--- `result.type` part ([`stub.difference`]). The stub is the one the
--- projection carries ([`build.writer`]). It is checked in `env`, where
--- `m`'s source was, so each module it requires is the one the source's
--- check read, under a file name of its own; its warnings are of the bodies
--- it leaves out, and no reader of the module sees them.
local function held_to_stub(m: Module, built: compiler, env: compiler.Env,
                            result: compiler.Result): boolean, string
  local made = m.stub
  if made == nil or not made.pruned then
    return false, m.file .. ": its stub keeps every statement, so a project's checker " ..
      "would read and load all of it: a standard-library module must end by returning a " ..
      "name whose last top-level declaration spells its type (`local record M ... end`, " ..
      "a local function, or `local m: M = ...`) (build/stub.tl)"
  end
  local stubbed = built.check_string(made.text, env, m.file .. " (stub)", "tl")
  local refusal = (stubbed.syntax_errors or {})[1] or (stubbed.type_errors or {})[1]
  local trouble: string | nil = nil
  if refusal ~= nil then
    trouble = refusal.y .. ":" .. refusal.x .. ": " .. refusal.msg
  else
    trouble = stub.difference(result.type, stubbed.type)
  end
  if trouble ~= nil then
    return false, m.file .. ": the stub a project's checker reads in its place " ..
      "(build/stub.tl) types it differently from its source: " .. trouble
  end
  return true, ""
end

--- What a verdict on a stub is kept under beside the module's compile key:
--- the hash of the stub's own text, so that a stub derived again differently
--- is judged again whatever the key says.
local function stub_hash(stub_text: string): string
  return Hash.hex_sha256(stub_text)
end

--- The stub ([`build.stub`]) of the module of the tree at `path` if a
--- compile has held it to the source's type ([`compilation.hold_stubs`])
--- under the module's key now, else nil: what a compile of a module that
--- requires it reads in place of its source ([`teal.environment_for`]). A
--- module whose stub was never compared, or differs, is read from its
--- source, as is one a declaration stands in front of, and one the
--- database cannot be asked about. Typing a module's whole source is most
--- of what a compile costs when a module it requires changed, and a stub
--- leaves every body out and, of a module that returns a named type, every
--- statement that type needs none of, with the modules those statements
--- require.
--- @param keys each module's [`compilation.Keys`], by path
local function verified_stub(db: Sqlite.Handle, keys: {string:Keys}, path: string): string | nil
  local named = keys[path]
  if named == nil then
    return nil
  end
  local rows, _ = Sqlite.text_rows(db,
    "SELECT s.text FROM inputs i JOIN stubs s ON s.source_hash = i.source_hash " ..
      "WHERE i.kind = 'module' AND i.path = ?1 " ..
      "AND NOT EXISTS (SELECT 1 FROM inputs d WHERE d.path = i.path AND d.kind = 'decl')",
    { text(path) })
  if rows == nil then
    return nil
  end
  local first = rows[1]
  if first == nil then
    return nil
  end
  local stub_text = first:text(1)
  local held, _ = Sqlite.text_rows(db,
    "SELECT key FROM stub_holds WHERE key = ?1 AND stub = ?2 AND held = 1",
    { text(named.key), text(stub_hash(stub_text)) })
  if held == nil or held[1] == nil then
    return nil
  end
  return stub_text
end

--- What [`build.teal`]'s `environment_for` reads of a module in place of its
--- source, as a function of its path: its stub if a compile has held that
--- to the source's type under the module's key now ([`verified_stub`]), else
--- nil, and nil for every path unless `serving`.
--- @param keys each module's [`compilation.Keys`], by path
function compilation.stub_lookup(db: Sqlite.Handle, keys: {string:Keys},
                                 serving: boolean): function(string): string | nil
  return function(path: string): string | nil
    if not serving then
      return nil
    end
    return verified_stub(db, keys, path)
  end
end

--- Gives the verdict on the stub ([`build.stub`]) of the module `path` under
--- its key now, unless one is kept: whether it types the module as
--- `env` holds the source's type of it ([`stub.difference`]), kept in
--- `stub_holds`. True where it does. A module `env` does not hold the type
--- of has no verdict given.
local function hold_one(db: Sqlite.Handle, built: compiler, env: compiler.Env,
                        keys: {string:Keys}, path: string, file: string,
                        stub_text: string): boolean, string
  local named = keys[path]
  local source_type = env.modules[path]
  if named == nil or source_type == nil then
    return false, ""
  end
  local known, known_trouble = Sqlite.text_rows(db,
    "SELECT held FROM stub_holds WHERE key = ?1 AND stub = ?2",
    { text(named.key), text(stub_hash(stub_text)) })
  if known == nil then
    return false, known_trouble
  end
  local verdict = known[1]
  if verdict ~= nil then
    return verdict:text(1) == "1", ""
  end
  local stubbed = built.check_string(stub_text, env, file .. " (stub)", "tl")
  local held = #stubbed.syntax_errors == 0 and #stubbed.type_errors == 0 and
    stub.difference(source_type, stubbed.type) == nil
  local ok, why = Sqlite.run(db,
    "INSERT OR REPLACE INTO stub_holds (key, stub, held) VALUES (?1, ?2, ?3)",
    { text(named.key), text(stub_hash(stub_text)), { integer = held and 1 or 0 } })
  if not ok then
    return false, why
  end
  return held, ""
end

--- Compares, for each module of the tree that `env` holds the type of
--- and that has no verdict under its key yet, the stub
--- ([`build.stub`]) with the source's type ([`stub.difference`]), and
--- keeps the answer in `stub_holds` under the module's key and the stub's text. The key names
--- the module's source and its whole import graph and the compiler: the
--- stub types the module as its source does, or it does not, for as long as
--- the key stands. The type `env` holds is the source's, whether the
--- module was compiled in this run or read from its source by the checker
--- for one that requires it: a module read from its stub has a verdict
--- already, and is not compared with itself. A module a declaration
--- stands in front of is not compared. A stub that is a type error, or
--- not the same type, only goes unheld, never refuses the module:
--- [`compilation.generate`] refuses a standard-library module for that.
--- @param keys each module's [`compilation.Keys`], by path
function compilation.hold_stubs(db: Sqlite.Handle, built: compiler, env: compiler.Env,
                                keys: {string:Keys}): boolean, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.path, i.file, s.text FROM inputs i JOIN stubs s ON s.source_hash = i.source_hash " ..
      "WHERE i.kind = 'module' AND i.path NOT IN (SELECT path FROM inputs WHERE kind = 'decl') " ..
      "ORDER BY i.path")
  if rows == nil then
    return false, trouble
  end
  for _, row in ipairs(rows) do
    local _, hold_trouble = hold_one(db, built, env, keys, row:text(1), row:text(2), row:text(3))
    if hold_trouble ~= "" then
      return false, hold_trouble
    end
  end
  return true, ""
end

--- Whether the stub of the module `path` is held to its source's type
--- under the module's key now: [`verified_stub`]'s test, with the verdict
--- given on the spot where none is kept and `env` holds the source's type
--- of the module (it was compiled in this run). A module with no stub,
--- or one a declaration stands in front of, is not.
--- @param env what the run has compiled so far, or nil before any module was
--- @param keys each module's [`compilation.Keys`], by path
function compilation.stub_held(db: Sqlite.Handle, built: compiler, env: compiler.Env | nil,
                               keys: {string:Keys}, path: string): boolean
  local named = keys[path]
  if named == nil then
    return false
  end
  local rows, _ = Sqlite.text_rows(db,
    "SELECT i.file, s.text FROM inputs i JOIN stubs s ON s.source_hash = i.source_hash " ..
      "WHERE i.kind = 'module' AND i.path = ?1 " ..
      "AND NOT EXISTS (SELECT 1 FROM inputs d WHERE d.path = i.path AND d.kind = 'decl')",
    { text(path) })
  local first: Sqlite.Row | nil = nil
  if rows ~= nil then first = rows[1] end
  if first == nil then
    return false
  end
  local file, stub_text = first:text(1), first:text(2)
  local known, _ = Sqlite.text_rows(db,
    "SELECT held FROM stub_holds WHERE key = ?1 AND stub = ?2",
    { text(named.key), text(stub_hash(stub_text)) })
  if known == nil then
    return false
  end
  local verdict = known[1]
  if verdict ~= nil then
    return verdict:text(1) == "1"
  end
  if env == nil then
    return false
  end
  local held, _ = hold_one(db, built, env, keys, path, file, stub_text)
  return held
end

--- The key of a module over what a dependent's check can see of it: the
--- module's own source, and of each module it reaches, the stub where that
--- is held to the source's type in place of the source. A module whose
--- key moved but whose interface did not -- a body, a comment -- has the same
--- one, and what was compiled under the one stands for the other: a check
--- reads of a held stub what it reads of the source, which is what the
--- hold judges. The verdicts kept are read once; a module the stub of which
--- has none under its key is asked of `judge`, which can give one only for a
--- module compiled in this run and so by the time a module that reaches it
--- is asked about.
--- @param tool the compiler's identity, as in [`compilation.dependency_keys`]
--- @param keys each module's [`compilation.Keys`], by path
--- @param judge whether the stub of the module at a path is held to its source's type
--- ([`compilation.stub_held`]), where no verdict is kept
--- @return the interface key of a module, by it: nil and why where the tree cannot be read
function compilation.interface_keys(db: Sqlite.Handle, modules: {Module}, tool: string,
                                    keys: {string:Keys}, judge: function(string): boolean):
    Interfaced | nil, string
  local made_graph, trouble = dependency_graph(db, modules)
  if made_graph == nil then
    return nil, trouble
  end
  local graph: Graph = made_graph
  local rows, rows_trouble = Sqlite.text_rows(db,
    "SELECT i.path, s.text FROM inputs i JOIN stubs s ON s.source_hash = i.source_hash " ..
      "WHERE i.kind = 'module' AND NOT EXISTS " ..
      "(SELECT 1 FROM inputs d WHERE d.path = i.path AND d.kind = 'decl')")
  if rows == nil then
    return nil, rows_trouble
  end
  local stubs: {string:string} = {}
  for _, row in ipairs(rows) do
    stubs[row:text(1)] = stub_hash(row:text(2))
  end
  local verdicts, verdicts_trouble = Sqlite.text_rows(db, "SELECT key, stub, held FROM stub_holds")
  if verdicts == nil then
    return nil, verdicts_trouble
  end
  local kept: {string:boolean} = {}
  for _, row in ipairs(verdicts) do
    kept[row:text(1) .. "\0" .. row:text(2)] = row:text(3) == "1"
  end
  local judged: {string:boolean} = {}
  local function held(path: string): boolean
    local hash, named = stubs[path], keys[path]
    if hash == nil or named == nil then
      return false
    end
    local verdict = kept[named.key .. "\0" .. hash]
    if verdict ~= nil then
      return verdict
    end
    local made = judged[path]
    if made == nil then
      made = judge(path)
      judged[path] = made
    end
    return made
  end
  local function line_of(slot: string, dependency: Dependency): string
    if slot:sub(1, 1) ~= "\0" and dependency.kind == "module" and held(slot) then
      return slot .. "\nstub\n" .. (stubs[slot] or "")
    end
    return source_line(slot, dependency)
  end
  local interfaced: Interfaced = function(m: Module): string | nil, string
    local made, identify_trouble = identify_in(graph, m.path, m.file,
      "interface-1 " .. tool, line_of)
    if made == nil then
      return nil, identify_trouble
    end
    return made.key, ""
  end
  return interfaced, ""
end

--- Why a cosmic build refuses a global declared at `at` (`file:line:column`).
function compilation.global_refusal(at: string): string
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
--- rows a parse kept ([`build.globals`]) for every source, a `.d.tl`
--- and a compile that stands in a cache included, so the refusal is made
--- before any module is compiled, and does not depend on that order.
function compilation.refuse_globals(db: Sqlite.Handle): string | nil, string
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
  local lines: {string} = {}
  for _, row in ipairs(rows) do
    lines[#lines + 1] = compilation.global_refusal(row:text(1) .. ":" .. row:text(2) .. ":" ..
        row:text(3))
  end
  return table.concat(lines, "\n"), ""
end

--- Compiles one module: the checker over its source (with each
--- [`Shape.record_of`] call resolved first, [`build.shape_specs`]), the test
--- tail when it is a test, and the bytecode.
--- @param resolved the source with its calls resolved already, as
---   [`shape_specs.resolve`] answers it, when the caller has it: it is
---   not resolved again
--- @param unreferenced whether to leave out the record-field uses
---   (`references`, none), which only a build keeps
function compilation.generate(m: Module, built: compiler, env: compiler.Env,
                              typed: receivers.State, own_tree: boolean, judged: boolean,
                              render: function(string, string, compiler.Result): string,
                              resolved?: string, unreferenced?: boolean): compilation.Generated | nil, string
  local source = ""
  if resolved ~= nil then
    source = resolved
  else
    local found, spec_trouble = shape_specs.resolve(built, env, m.file, m.path, m.source)
    if found == nil then
      return nil, spec_trouble
    end
    source = found
  end
  -- Checked under the module's own file name, not `gen`'s empty
  -- one: a mismatch between a value's type and the type a slot
  -- expects is reported at the value's declaration when the checker
  -- takes both for one file's and the declaration lies after the use,
  -- which on a cold build put a template's error at the field in its
  -- data module, under the template's name.
  typed.checking = m.file
  -- The module that holds the hook the checks call is compiled without
  -- them: a check of the hook's own parameters would call the hook.
  local checks = env.defaults.runtime_checks
  if m.path == "build.test_worker" then
    env.defaults.runtime_checks = false
  end
  local checked_ok, outcome = pcall(built.check_string, source, env, m.file, "tl")
  env.defaults.runtime_checks = checks
  -- Put back before a raise goes on, so the run's state names no file
  -- the checker has left.
  typed.checking = ""
  if not checked_ok then
    error(outcome, 0)
  end
  local result = assert(outcome, "the checker answered no result")
  local code: string | nil = nil
  local result_ast = result.ast
  if result_ast ~= nil and #result.syntax_errors == 0 then
    local written, write_trouble = built.generate(result_ast, env.defaults.gen_target, nil)
    if written == nil then
      return nil, m.file .. ": " .. write_trouble
    end
    code = written
  end
  if m.kind == "test" and result ~= nil then
    result = discount_test_warnings(result, m.tests)
  end
  if m.generated and result ~= nil then
    result = discount_doctest_shadow_warnings(result)
  end
  -- Presentation cannot decide acceptance: even an empty rendering of
  -- a checker error must refuse the compile, and successful compiles
  -- never call the renderer.
  local rejected = result ~= nil and (#(result.syntax_errors or {}) > 0 or
    #(result.type_errors or {}) > 0 or #(result.warnings or {}) > 0)
  if code == nil or rejected then
    local complaint = result ~= nil and render(m.file, m.source, result) or ""
    return nil, m.file .. ": the compiler refused it\n" .. complaint
  end
  -- A standard-library module is what a project's checker reads its
  -- stub for, in the tool this tree builds ([`build.writer`]). An
  -- unjudged run keeps a module whose stub its own, older build.stub
  -- refuses, as it keeps one its contracts refuse (below), for the tool
  -- it builds to judge.
  local checked = result.ast
  if not (checked is ast.Node) then
    return nil, m.file .. ": the compiler answered no syntax tree"
  end
  local refused = false
  if own_tree and m.kind == "module" and m.path:sub(1, 7) == "cosmic." then
    local held, hold_trouble = held_to_stub(m, built, env, result)
    if not held and judged then
      return nil, hold_trouble
    end
    refused = not held
  end
  -- The checker has just seen this module whole; a module compiled
  -- after it that requires it is checked against that, rather than
  -- against a second read and check of the same source.
  env.modules[m.path] = result.type
  if own_tree and contracts.applies(m.kind, m.generated) then
    local problems = contracts.check(m.file, checked, typed, contracts.quiet_records(env),
      contracts.binding_tables(env), nil, result.type)
    if #problems > 0 and judged then
      return nil, table.concat(problems, "\n")
    end
    refused = refused or #problems > 0
  end
  local references: {receivers.Reference} = {}
  if unreferenced ~= true then
    references = receivers.references(typed, env, checked)
  end
  if m.kind == "test" then
    code = LuaTail.with_test_tail(code, m.tests)
  end
  local bytecode, dump_trouble = LuaTail.bytecode_of(code, m.path, m.file)
  if bytecode == nil then
    return nil, dump_trouble
  end
  return { lua = code, bytecode = bytecode, references = references, refused = refused }, ""
end

--- The record-field uses one compile found, kept under its key beside
--- the compile itself, replacing whatever an earlier compile under the
--- same key left.
function compilation.keep_references(db: Sqlite.Handle, key: string,
                                     references: {receivers.Reference}): boolean, string
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
function compilation.refusal(m: Module): string | nil
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

--- The vendored compiler's compile key. Its source is already Lua.
function compilation.vendor_key(source: string, tool: string): string
  return Hash.hex_sha256(source .. "\n" .. tool)
end

--- Dumped only when the vendor key missed the local compile cache.
function compilation.vendor_bytecode(source: string): string | nil, string
  local chunk, trouble = load(source, "@vendor.tl", "t")
  if chunk == nil then
    return nil, "the vendored compiler would not load: " .. tostring(trouble)
  end
  return string.dump(chunk, false), ""
end

--- The identity of the code that finds `typed_refs` and checks the
--- error-slot discipline beside the compiler: [`build.receivers`] and
--- [`build.contracts`] as the running binary carries them, or the binary
--- whole when it carries none. A boot carries no database and runs the
--- tree's own code, so it names them by the tree's source, as the tool
--- it writes will: the identity is signed into the projection
--- ([`build.writer`]), which a self-rebuild must write the same as a boot
--- does. Named apart from [`build.importer.analyzer_identity`] because its rows ride on
--- compiles, which only a change to this code must redo.
function compilation.receivers_identity(db: Sqlite.Handle): string | nil, string
  local booting = Store.meta("boot_hash") == nil
  local parts: {string} = {}
  for _, name in ipairs({ "build.receivers", "build.contracts" }) do
    local source: string | nil
    if booting then
      local rows, trouble = Sqlite.text_rows(db,
        "SELECT source FROM inputs WHERE path = ?1", { text(name) })
      if rows == nil then
        return nil, trouble
      end
      if #rows > 0 then
        source = rows[1]:text(1)
      end
    else
      local carried, _ = Store.source(name)
      source = carried
    end
    if source == nil then
      return "binary " .. (Store.meta("boot_hash") or "")
    end
    parts[#parts + 1] = source
  end
  return Hash.hex_sha256(table.concat(parts, "\n\0\n"))
end

return compilation
