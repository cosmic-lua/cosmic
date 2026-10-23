--- Tests of the write that starts from the projection already standing
--- ([`build.writer`]'s `usable_base`): whatever it carries over, its
--- bytes are those of a write of the whole tree, since a projection's
--- digest names verdicts that checkouts share and two builds of one tree
--- compare their files.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")

local built = assert(teal.load())

--- What one module of the tree is: the variants of each part that an edit
--- moves, so that a step is one change to one record.
local record Spec
  body: integer
  comment: integer
  doc: integer
  errors: integer
  dep: string
  example: integer
  declared: integer
end

local record Tree
  specs: {string: Spec}
  names: {string}
end

--- The module named `name`, as its spec says.
local function module_source(name: string, spec: Spec): string
  local lines: {string} = {}
  if spec.dep ~= "" then
    lines[#lines + 1] = 'local Dep = require("' .. spec.dep .. '")'
  end
  for line = 1, spec.doc do
    lines[#lines + 1] = "--- Doc " .. name .. " line " .. line .. " of " .. spec.doc .. "."
  end
  if spec.doc > 0 and spec.dep ~= "" then
    lines[#lines + 1] = "--- See [`Dep.value`]."
  end
  lines[#lines + 1] = "local record M"
  lines[#lines + 1] = "end"
  if spec.comment > 0 then
    lines[#lines + 1] = "-- a plain comment " .. spec.comment
  end
  lines[#lines + 1] = "--- Value " .. name .. "."
  lines[#lines + 1] = "function M.value(): integer"
  if spec.dep ~= "" then
    lines[#lines + 1] = "  local _ = Dep.value()"
  end
  lines[#lines + 1] = "  return " .. spec.body
  lines[#lines + 1] = "end"
  for count = 1, spec.errors do
    lines[#lines + 1] = "function M.fail" .. count .. "(): nil, string"
    lines[#lines + 1] = '  return nil, "failed ' .. name .. " " .. count .. '"'
    lines[#lines + 1] = "end"
  end
  lines[#lines + 1] = "return M"
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

local function example_source(spec: Spec): string
  local lines: {string} = { "local record Example", "end" }
  for index = 1, spec.example do
    lines[#lines + 1] = "--- Shows " .. index .. "."
    lines[#lines + 1] = "function Example.show" .. index .. "()"
    lines[#lines + 1] = "end"
  end
  lines[#lines + 1] = "return Example"
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

local function declaration_source(name: string, spec: Spec): string
  return "--- Declared " .. name .. " " .. spec.declared .. ".\nlocal record M\n" ..
    "  value: function(): integer\nend\nreturn M\n"
end

--- Writes the tree's files under `root`, and removes those of a module the
--- tree no longer has (`gone`).
local function write_tree(root: string, tree: Tree, gone: {string})
  assert(Fs.mkdirs(root))
  for _, name in ipairs(gone) do
    for _, suffix in ipairs({ ".tl", "_example.tl", ".d.tl" }) do
      local _ = Fs.remove(root .. "/" .. name .. suffix)
    end
  end
  for _, name in ipairs(tree.names) do
    local spec = tree.specs[name]
    assert(Fs.write(root .. "/" .. name .. ".tl", module_source(name, spec)))
    local example = root .. "/" .. name .. "_example.tl"
    if spec.example > 0 then
      assert(Fs.write(example, example_source(spec)))
    else
      local _ = Fs.remove(example)
    end
    local declaration = root .. "/" .. name .. ".d.tl"
    if spec.declared > 0 then
      assert(Fs.write(declaration, declaration_source(name, spec)))
    else
      local _ = Fs.remove(declaration)
    end
  end
  assert(Fs.write(root .. "/main.tl", "return function(): integer\n  return 0\nend\n"))
end

local function new_spec(dep: string): Spec
  return { body = 1, comment = 0, doc = 1, errors = 1, dep = dep, example = 0, declared = 0 }
end

--- How many modules the write at `handle` took from the base: the rows of
--- `temp.reused`, which a write that found no usable base leaves absent.
local function reused(handle: work.Handle): integer
  local rows = Sqlite.text_rows(handle.db, "SELECT count(*) FROM temp.reused")
  if rows == nil then
    return 0
  end
  return math.tointeger(tonumber(assert(rows[1]):text(1))) or 0
end

--- Stages and compiles the tree under `root`, writes it to `out` and then
--- as a whole to `whole` (a path nothing stands at), and returns how many
--- modules the first took from what stood at `out`.
local function write_both(handle: work.Handle, out: string, whole: string, tool: string): integer
  assert(work.stage(handle, false))
  local result = assert(importer.compile(handle, built, tool))
  assert(handle.db:exec("DROP TABLE IF EXISTS temp.reused"))
  assert(writer.write_result(handle, out, result))
  local taken = reused(handle)
  assert(handle.db:exec("DROP TABLE IF EXISTS temp.reused"))
  local _ = Fs.remove(whole)
  assert(writer.write_result(handle, whole, result))
  assert(reused(handle) == 0, "a write with nothing standing took modules from a base")
  return taken
end

local function same_bytes(left: string, right: string, step: string)
  local a = assert(Fs.read(left))
  local b = assert(Fs.read(right))
  assert(a == b, step .. ": the projection written from the base differs from the whole write (" ..
      #a .. " and " .. #b .. " bytes)")
end

--- A step of a sequence of edits drawn by `draw`, which gives the next
--- integer below its argument; returns what the step did.
local function edit(tree: Tree, draw: function(integer): integer, fresh: {integer}): string, {string}
  local names = tree.names
  local gone: {string} = {}
  local pick = names[draw(#names) + 1]
  local spec = tree.specs[pick]
  local op = draw(10)
  if op == 0 then
    spec.body = spec.body + 1
    return "body of " .. pick, gone
  elseif op == 1 then
    spec.comment = spec.comment + 1
    return "comment in " .. pick, gone
  elseif op == 2 then
    spec.doc = draw(4)
    return "doc of " .. pick, gone
  elseif op == 3 then
    spec.errors = draw(3)
    return "errors of " .. pick, gone
  elseif op == 4 then
    spec.example = draw(3)
    return "examples of " .. pick, gone
  elseif op == 5 then
    spec.declared = draw(3)
    return "declaration of " .. pick, gone
  elseif op == 6 or op == 7 then
    fresh[1] = fresh[1] + 1
    local name = "n" .. fresh[1]
    tree.specs[name] = new_spec(pick)
    tree.names[#tree.names + 1] = name
    table.sort(tree.names)
    return "added " .. name, gone
  elseif op == 8 and #names > 2 then
    local kept: {string} = {}
    for _, name in ipairs(names) do
      if name ~= pick then
        kept[#kept + 1] = name
        if tree.specs[name].dep == pick then
          tree.specs[name].dep = ""
        end
      end
    end
    tree.specs[pick] = nil
    tree.names = kept
    gone[1] = pick
    return "removed " .. pick, gone
  elseif op == 9 and #names > 2 then
    fresh[1] = fresh[1] + 1
    local name = "r" .. fresh[1]
    local kept: {string} = {}
    for _, other in ipairs(names) do
      if other ~= pick then
        kept[#kept + 1] = other
      end
      if tree.specs[other].dep == pick then
        tree.specs[other].dep = name
      end
    end
    kept[#kept + 1] = name
    table.sort(kept)
    tree.specs[name] = spec
    tree.specs[pick] = nil
    tree.names = kept
    gone[1] = pick
    return "renamed " .. pick .. " to " .. name, gone
  end
  return "nothing", gone
end

local function initial(): Tree
  local specs: {string: Spec} = {}
  local names = { "a1", "b2", "c3", "d4", "e5" }
  local before = ""
  for _, name in ipairs(names) do
    specs[name] = new_spec(before)
    before = name
  end
  return { specs = specs, names = names }
end

--- A projection written from the one standing is the projection a write of
--- the whole tree makes, whatever the edit: a body or a comment, a doc
--- comment that moves the ids of `docs` and the entries of `catalog` and
--- `examples` after it, a module added, removed or renamed, a declaration
--- stood in for one. Each of several sequences runs from the previous step's
--- file, so a difference would be carried forward; and each of them takes
--- modules from the base at least once, or this is no test of that.
local function test_a_write_from_a_base_is_a_write_of_the_whole(tmp: string)
  local taken = 0
  for seed = 1, 3 do
    local state = { value = seed * 7919 }
    local function draw(limit: integer): integer
      state.value = (state.value * 1103515245 + 12345) % 2147483648
      return (state.value // 65536) % limit
    end
    local root = tmp .. "/tree" .. seed
    local out = tmp .. "/out" .. seed .. ".db"
    local whole = tmp .. "/whole" .. seed .. ".db"
    local tree = initial()
    write_tree(root, tree, {})
    local handle = assert(work.open(root))
    local fresh = { 0 }
    write_both(handle, out, whole, "writer-test")
    same_bytes(out, whole, "seed " .. seed .. " start")
    for step = 1, 14 do
      local what, gone = edit(tree, draw, fresh)
      write_tree(root, tree, gone)
      local label = "seed " .. seed .. " step " .. step .. " (" .. what .. ")"
      local from_base = write_both(handle, out, whole, "writer-test")
      same_bytes(out, whole, label)
      taken = taken + from_base
    end
    assert(work.close(handle))
  end
  assert(taken > 0, "no write took a module from the base")
end

--- An edit to one module's body leaves to the base each module whose key it
--- does not move: those that do not require the module, directly or not.
local function test_an_edit_to_one_module_takes_the_unrelated_from_the_base(tmp: string)
  local tree = initial()
  write_tree(tmp .. "/t", tree, {})
  local handle = assert(work.open(tmp .. "/t"))
  write_both(handle, tmp .. "/out.db", tmp .. "/whole.db", "writer-test")
  tree.specs["c3"].body = 2
  write_tree(tmp .. "/t", tree, {})
  local taken = write_both(handle, tmp .. "/out.db", tmp .. "/whole.db", "writer-test")
  same_bytes(tmp .. "/out.db", tmp .. "/whole.db", "body edit")
  -- a1, b2 and main stand; c3 is edited, and d4 and e5 require it.
  assert(taken == 3, "three of six modules stand, took " .. taken)
  assert(work.close(handle))
end

--- Where a base cannot stand in for the rows -- another compiler wrote
--- it, or it holds another schema, another declaration, another core --
--- the write is whole, and equals the whole write.
local function test_a_base_that_cannot_stand_in_is_not_used(tmp: string)
  local tampers: {string: string} = {
    ["compiler"] = "UPDATE meta SET value = 'other' WHERE key = 'compiled_by'",
    ["writer"] = "UPDATE meta SET value = 'other' WHERE key = 'written_by'",
    ["core image"] = "INSERT OR REPLACE INTO meta (key, value) VALUES ('image_hash', x'00')",
    ["runtime basis"] = "UPDATE meta SET value = x'00' WHERE key = 'runtime_basis'",
    ["signature"] = "UPDATE meta SET value = 'other' WHERE key = 'projected'",
    ["schema"] = "CREATE TABLE extra (x)",
    ["declaration"] = "INSERT INTO decls (path, source) VALUES ('stray', x'00')",
  }
  for name, statement in pairs(tampers) do
    local root = tmp .. "/" .. name:gsub(" ", "_")
    local tree = initial()
    write_tree(root, tree, {})
    local handle = assert(work.open(root))
    write_both(handle, root .. ".db", root .. ".whole.db", "writer-test")
    local db = assert(Sqlite.open(root .. ".db", { writable = true }))
    assert(db:exec(statement))
    assert(db:close())
    tree.specs["b2"].body = 5
    write_tree(root, tree, {})
    local taken = write_both(handle, root .. ".db", root .. ".whole.db", "writer-test")
    assert(taken == 0, name .. ": a base that cannot stand in was used")
    same_bytes(root .. ".db", root .. ".whole.db", name)
    assert(work.close(handle))
  end
end

--- A compiler of another identity writes the whole projection too.
local function test_another_compiler_writes_the_whole_projection(tmp: string)
  local tree = initial()
  write_tree(tmp .. "/t", tree, {})
  local handle = assert(work.open(tmp .. "/t"))
  write_both(handle, tmp .. "/out.db", tmp .. "/whole.db", "writer-test")
  tree.specs["a1"].body = 9
  write_tree(tmp .. "/t", tree, {})
  local taken = write_both(handle, tmp .. "/out.db", tmp .. "/whole.db", "another-tool")
  assert(taken == 0, "a projection another compiler wrote was built on")
  same_bytes(tmp .. "/out.db", tmp .. "/whole.db", "another compiler")
  assert(work.close(handle))
end
