--- [`plans.dependency_keys`] after an edit makes the keys of only the
--- modules that reach what it changed, and they are the keys a build that
--- kept nothing makes ([`plans.full_keys`]), whatever the edit:
--- a body or a comment, what a module requires (in a cycle too), a
--- module that becomes a declaration or a source, the file a module is in, a
--- module added, removed or renamed, the compiler.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local plans = require("build.plans")
local importer = require("build.importer")
local work = require("build.work")

Test.policy{ grants = { { path = "core", letters = "r" } } }

--- How many modules the tree can have, and the bit of `edges` that is a module of
--- the standard library, which each may require beside the others.
local count <const> = 14
local library <const> = 15

--- A deterministic source of choices, so that a failure names the same edit
--- on every run: `choose(n)` is in 1 to `n`.
local record Chooser
  mut state: integer
end

local function choose(chooser: Chooser, limit: integer): integer
  chooser.state = (chooser.state * 1103515245 + 12345) % 2147483648
  return chooser.state // 65536 % limit + 1
end

--- The source of module `index`: a require of each module whose bit `edges`
--- holds (any other, those after it too, so that the requires make cycles, and
--- itself), of the standard library's where the last bit is, and a comment
--- `salt` names, which an edit that moves no edge changes. A `declared` module is a declaration.
local function source_of(index: integer, edges: integer, salt: integer, declared: boolean): string
  local text = ""
  for other = 1, library - 1 do
    if (edges >> (other - 1)) & 1 == 1 then
      text = text .. "local r" .. tostring(other) .. " = require(\"m" .. tostring(other) .. "\")\n"
    end
  end
  if (edges >> (library - 1)) & 1 == 1 then
    text = text .. "local fs = require(\"cosmic.fs\")\n"
  end
  local name = "m" .. tostring(index)
  local returned = if declared then name else "{} as " .. name end
  return text .. "local record " .. name .. "\n  value: integer\nend\n-- " .. tostring(salt) ..
    "\nreturn " .. returned .. "\n"
end

--- The keys of the tree at `root` as `dependency_keys` makes them, and as
--- a build that kept nothing does, which say the same of every module or the
--- names of those they differ for.
local function differing(root: string, tool: string): string
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  assert(importer.derive(handle))
  local modules = assert(plans.collect(handle.db))
  local kept = assert(plans.dependency_keys(handle.db, modules, tool))
  local full = assert(plans.full_keys(handle.db, modules, tool))
  work.close(handle)
  local trouble = ""
  if #modules == 0 then trouble = "no module " end
  for _, m in ipairs(modules) do
    local a, b = kept[m.path], full[m.path]
    if a == nil or b == nil or a.key ~= b.key or a.graph ~= b.graph then
      trouble = trouble .. m.path .. " "
    end
  end
  return trouble
end

--- What the walk keeps of module `m<index>`: its edges and comment, whether it
--- stands, whether it is a declaration (a `.d.tl`, with no source) and whether
--- it is in a directory of its own. An edit makes another ([`like`]).
local record Node
  edges: integer
  salt: integer
  present: boolean
  declared: boolean
  nested: boolean
end

--- What an edit changes of a [`Node`]: the fields it names.
local record Change
  edges?: integer
  salt?: integer
  present?: boolean
  declared?: boolean
  nested?: boolean
end

--- `node` with `change` made, as a node of its own.
local function like(node: Node, change: Change): Node
  local present, declared, nested = node.present, node.declared, node.nested
  if change.present ~= nil then present = change.present end
  if change.declared ~= nil then declared = change.declared end
  if change.nested ~= nil then nested = change.nested end
  return { edges = change.edges or node.edges, salt = change.salt or node.salt,
    present = present, declared = declared, nested = nested }
end

--- A tree of modules requiring some of the others, in cycles too, each
--- required by one that every module requires, edited in turn: a body or a
--- comment, an edge (a cycle's included), a declaration, the file a module is
--- in, a module added, removed or renamed, and the compiler. The keys the
--- memo makes agree with those made of nothing at each step.
local function walk(seed: integer, steps: integer)
  local root = assert(Fs.mkdtemp("cosmic-dependency-keys-"))
  local chooser: Chooser = { state = seed }
  local nodes: {Node} = {}
  local function node_at(index: integer): Node
    return assert(nodes[index])
  end
  local function store(index: integer, node: Node)
    nodes[index] = node
  end
  for index = 1, count do
    -- Every module requires the first, which a comment there reaches them all through.
    local held = if index == 1 then 0 else 1 end
    for other = 1, count do
      if choose(chooser, 4) == 1 then held = held | (1 << (other - 1)) end
    end
    if choose(chooser, 4) == 1 then held = held | (1 << (library - 1)) end
    store(index, { edges = held, salt = 0, present = index <= count - 3, declared = false, nested = false })
  end
  local function path_of(index: integer): string
    local name = "m" .. tostring(index)
    local extension = if node_at(index).declared then ".d.tl" else ".tl" end
    if node_at(index).nested then return root .. "/" .. name .. "/init" .. extension end
    return root .. "/" .. name .. extension
  end
  --- Writes the module's source, with a comment of its own.
  local function write(index: integer)
    local node = node_at(index)
    assert(Fs.mkdirs(root .. "/m" .. tostring(index)))
    store(index, like(node, { salt = node.salt + 1 }))
    assert(Fs.write(path_of(index), source_of(index, node.edges, node.salt + 1, node.declared)))
  end
  for index = 1, count do
    if node_at(index).present then write(index) end
  end
  assert(differing(root, "tool-one") == "", "the first keys differ")

  for step = 1, steps do
    local index = choose(chooser, count)
    -- A fourth of the edits are the first module's, which every module reaches.
    if choose(chooser, 4) == 1 then index = 1 end
    local name = "m" .. tostring(index)
    local node = node_at(index)
    local edit = choose(chooser, 10)
    local what = "the compiler"
    if not node.present and (edit <= 5 or edit == 8) then edit = 7 end
    if edit == 1 or edit == 2 then
      what = "a comment in " .. name
      write(index)
    elseif edit == 3 or edit == 4 then
      what = "an edge of " .. name
      -- Another module, itself, or the standard library's.
      local bit = choose(chooser, library) - 1
      store(index, like(node, { edges = node.edges ~ (1 << bit) }))
      write(index)
    elseif edit == 5 then
      what = "the file of " .. name
      local from = path_of(index)
      local text = assert(Fs.read(from))
      assert(Fs.remove(from))
      store(index, like(node, { nested = not node.nested }))
      assert(Fs.mkdirs(root .. "/" .. name))
      assert(Fs.write(path_of(index), text))
    elseif edit == 6 then
      what = "a declaration of " .. name
      -- The module is written again as the other kind: a module has one type source.
      if node.present then
        assert(Fs.remove(path_of(index)))
      end
      store(index, like(node, { declared = not node.declared }))
      if node.present then
        write(index)
      end
    elseif edit == 7 then
      -- Added, or removed, leaving what requires it with a name that is none.
      if node.present then
        what = "the removal of " .. name
        assert(Fs.remove(path_of(index)))
        store(index, like(node, { present = false }))
      else
        what = "the addition of " .. name
        store(index, like(node, { present = true }))
        write(index)
      end
    elseif edit == 8 then
      -- Moved to the name of one that is not there: what required the old
      -- one now requires none, and what required the new one requires this.
      local to = choose(chooser, count)
      local target = node_at(to)
      assert(Fs.remove(path_of(index)))
      store(index, like(node, { present = false }))
      if target.present then
        what = "the removal of " .. name
      else
        what = "the rename of " .. name .. " to m" .. tostring(to)
        store(to, like(target, { edges = node.edges, present = true }))
        write(to)
      end
    end
    local tool = "tool-one"
    if edit == 9 then tool = "tool-" .. tostring(step) end
    local trouble = differing(root, tool)
    assert(trouble == "", "seed " .. tostring(seed) .. " step " .. tostring(step) .. ", " .. what ..
        ": the keys of " .. trouble .. "differ")
  end
end

local function test_the_keys_made_from_what_changed_are_the_keys_made_of_everything()
  walk(11, 60)
end

local function test_the_keys_made_from_what_changed_are_those_made_of_everything_in_another_walk()
  walk(2024, 60)
end

--- A module named with a byte below a newline after its first sorts its lines
--- ahead of those of one whose name it begins, which the order of the nodes
--- does not hold to: the keys are made of everything then, and are the same
--- over the edits that follow.
local function test_a_name_with_a_byte_below_a_newline_is_keyed_as_a_whole()
  local root = assert(Fs.mkdtemp("cosmic-dependency-keys-bytes-"))
  -- One that requires both, which reaches both nodes: "a" sorts before "a\tb", and "a\n" after "a\tb\n".
  assert(Fs.write(root .. "/c.tl", "local a = require(\"a\")\nlocal b = require(\"a\tb\")\nreturn {}\n"))
  assert(Fs.write(root .. "/a.tl", "return {}\n"))
  assert(Fs.write(root .. "/a\tb.tl", "return {}\n"))
  assert(differing(root, "tool-one") == "", "the first keys differ")
  assert(Fs.write(root .. "/a\tb.tl", "return { value = 1 }\n"))
  assert(differing(root, "tool-one") == "", "the keys after an edit differ")
  assert(Fs.write(root .. "/a.tl", "return { value = 2 }\n"))
  assert(differing(root, "tool-one") == "", "the keys after another edit differ")
end

--- Keys kept for one compiler are not another's.
local function test_the_keys_kept_for_one_compiler_are_not_served_for_another()
  local root = assert(Fs.mkdtemp("cosmic-dependency-keys-tool-"))
  assert(Fs.write(root .. "/m1.tl", source_of(1, 0, 1, false)))
  assert(Fs.write(root .. "/m2.tl", source_of(2, 1, 1, false)))
  local function key_of(tool: string): string
    local handle = assert(work.open(root))
    assert(work.stage(handle, { own = false }))
    assert(importer.derive(handle))
    local modules = assert(plans.collect(handle.db))
    local keys = assert(plans.dependency_keys(handle.db, modules, tool))
    work.close(handle)
    return assert(keys["m2"]).key
  end
  local one = key_of("tool-one")
  local other = key_of("tool-other")
  assert(one ~= other, "the key of a module did not move with the compiler")
  assert(key_of("tool-one") == one, "the keys of a compiler came back other than they were")
end
