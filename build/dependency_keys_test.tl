--- [`compilation.dependency_keys`] after an edit makes the keys of only the
--- modules that reach what it changed, and they are the keys a build that
--- kept nothing makes ([`compilation.full_keys`]), whatever the edit:
--- a body or a comment, what a module requires, a declaration that
--- joins or leaves a module, the file a module is in, the compiler.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local compilation = require("build.compilation")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

Test.policy{ grants = { { path = "core", letters = "r" } } }

local built = assert(teal.load())

--- How many modules the tree has, and the bit of `edges` that is a module of
--- the standard library, which each may require beside those before it.
local count <const> = 14
local library <const> = 14

--- A deterministic source of choices, so that a failure names the same edit
--- on every run: `choose(n)` is in 1 to `n`.
local record Chooser
  state: integer
end

local function choose(chooser: Chooser, limit: integer): integer
  chooser.state = (chooser.state * 1103515245 + 12345) % 2147483648
  return chooser.state // 65536 % limit + 1
end

--- The source of module `index`: a require of each module before it whose bit
--- `edges` holds, of the standard library's where the last bit is, and a
--- comment `salt` names, which an edit that moves no edge changes.
local function source_of(index: integer, edges: integer, salt: integer): string
  local text = ""
  for other = 1, index - 1 do
    if (edges >> (other - 1)) & 1 == 1 then
      text = text .. "local r" .. tostring(other) .. " = require(\"m" .. tostring(other) .. "\")\n"
    end
  end
  if (edges >> (library - 1)) & 1 == 1 then
    text = text .. "local fs = require(\"cosmic.fs\")\n"
  end
  local name = "m" .. tostring(index)
  return text .. "local record " .. name .. "\n  value: integer\nend\n-- " .. tostring(salt) ..
    "\nreturn {} as " .. name .. "\n"
end

--- The keys of the tree at `root` as `dependency_keys` makes them, and as
--- a build that kept nothing does, which say the same of every module or the
--- names of those they differ for.
local function differing(root: string, tool: string): string
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  assert(importer.derive(handle, false, built))
  local modules = assert(compilation.collect(handle.db))
  local kept = assert(compilation.dependency_keys(handle.db, modules, tool))
  local full = assert(compilation.full_keys(handle.db, modules, tool))
  work.close(handle)
  local trouble = ""
  for _, m in ipairs(modules) do
    local a, b = kept[m.path], full[m.path]
    if a == nil or b == nil or a.key ~= b.key or a.graph ~= b.graph then
      trouble = trouble .. m.path .. " "
    end
  end
  return trouble
end

--- A tree of modules requiring some of those before them, edited in turn: the
--- keys the memo makes agree with those made of nothing at each step.
local function test_the_keys_made_from_what_changed_are_the_keys_made_of_everything()
  local root = assert(Fs.mkdtemp("cosmic-dependency-keys-"))
  local chooser: Chooser = { state = 7 }
  -- Each module's edges, comment, whether a declaration stands before it and whether it is in
  -- a directory of its own.
  local edges: {integer} = {}
  local salts: {integer} = {}
  local declared: {boolean} = {}
  local nested: {boolean} = {}
  for index = 1, count do
    local held = 0
    for other = 1, index - 1 do
      if choose(chooser, 3) == 1 then held = held | (1 << (other - 1)) end
    end
    if choose(chooser, 4) == 1 then held = held | (1 << (library - 1)) end
    edges[index], salts[index], declared[index], nested[index] = held, 0, false, false
  end
  local function path_of(index: integer): string
    local name = "m" .. tostring(index)
    if nested[index] == true then return root .. "/" .. name .. "/init.tl" end
    return root .. "/" .. name .. ".tl"
  end
  local function write(index: integer)
    assert(Fs.mkdirs(root .. "/m" .. tostring(index)))
    salts[index] = (salts[index] or 0) + 1
    assert(Fs.write(path_of(index), source_of(index, edges[index] or 0, salts[index] or 0)))
  end
  for index = 1, count do write(index) end
  assert(differing(root, "tool-one") == "", "the first keys differ")

  chooser.state = 11
  for step = 1, 24 do
    local index = choose(chooser, count)
    local name = "m" .. tostring(index)
    local edit = choose(chooser, 6)
    local what = "the compiler"
    if edit == 1 or edit == 2 then
      what = "a comment in " .. name
      write(index)
    elseif edit == 3 then
      what = "an edge of " .. name
      -- A module before it, or the standard library's.
      local bit = choose(chooser, index) - 1
      if bit == index - 1 then bit = library - 1 end
      edges[index] = (edges[index] or 0) ~ (1 << bit)
      write(index)
    elseif edit == 4 then
      what = "a declaration of " .. name
      local file = root .. "/" .. name .. ".d.tl"
      if declared[index] == true then
        assert(Fs.remove(file))
      else
        assert(Fs.write(file, "local record " .. name .. "\n  value: integer\nend\nreturn " .. name .. "\n"))
      end
      declared[index] = declared[index] ~= true
    elseif edit == 5 then
      what = "the file of " .. name
      local from = path_of(index)
      local text = assert(Fs.read(from))
      assert(Fs.remove(from))
      nested[index] = nested[index] ~= true
      assert(Fs.mkdirs(root .. "/" .. name))
      assert(Fs.write(path_of(index), text))
    end
    local tool = "tool-one"
    if edit == 6 then tool = "tool-" .. tostring(step) end
    local trouble = differing(root, tool)
    assert(trouble == "", "step " .. tostring(step) .. ", " .. what .. ": the keys of " .. trouble .. "differ")
  end
end

--- Keys kept for one compiler are not another's.
local function test_the_keys_kept_for_one_compiler_are_not_served_for_another()
  local root = assert(Fs.mkdtemp("cosmic-dependency-keys-tool-"))
  assert(Fs.write(root .. "/m1.tl", source_of(1, 0, 1)))
  assert(Fs.write(root .. "/m2.tl", source_of(2, 1, 1)))
  local function key_of(tool: string): string
    local handle = assert(work.open(root))
    assert(work.stage(handle, false))
    assert(importer.derive(handle, false, built))
    local modules = assert(compilation.collect(handle.db))
    local keys = assert(compilation.dependency_keys(handle.db, modules, tool))
    work.close(handle)
    return assert(keys["m2"]).key
  end
  local one = key_of("tool-one")
  local other = key_of("tool-other")
  assert(one ~= other, "the key of a module did not move with the compiler")
  assert(key_of("tool-one") == one, "the keys of a compiler came back other than they were")
end
