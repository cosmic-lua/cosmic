--- [`compilation.dependency_keys`] after an edit makes the keys of only the
--- modules that reach what it changed, and they are the keys a build that
--- kept nothing makes ([`compilation.full_keys`]), whatever the edit:
--- a body or a comment, what a module requires, a declaration that
--- joins or leaves a module, the file a module is in, a module that is
--- added or goes.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local compilation = require("build.compilation")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

Test.policy{ grants = { { path = "core", letters = "r" } } }

local built = assert(teal.load())

--- A deterministic source of choices, so that a failure names the same edit
--- on every run.
local function chooser(seed: integer): function(integer): integer
  local held = { state = seed }
  return function(limit: integer): integer
    held.state = (held.state * 1103515245 + 12345) % 2147483648
    return held.state // 65536 % limit + 1
  end
end

--- The source of module `name` requiring each of `needs`, `salt` the part of
--- it an edit that moves no edge changes.
local function source_of(name: string, needs: {string}, salt: integer): string
  local lines: {string} = {}
  for i, need in ipairs(needs) do
    lines[#lines + 1] = "local r" .. i .. " = require(\"" .. need .. "\")"
  end
  lines[#lines + 1] = "local record " .. name .. "\n  value: integer\nend"
  lines[#lines + 1] = "-- " .. salt
  lines[#lines + 1] = "return {} as " .. name
  return table.concat(lines, "\n") .. "\n"
end

--- The keys of the tree at `root` as `dependency_keys` makes them, and as
--- a build that kept nothing does. They say the same of every module, or the
--- trouble.
local function same_keys(root: string, tool: string): string
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

--- A module of some modules, edited in turn: the keys the memo makes agree with
--- those made of nothing at each step.
local function test_the_keys_made_from_what_changed_are_the_keys_made_of_everything()
  local root = assert(Fs.mkdtemp("cosmic-dependency-keys-"))
  local names: {string} = {}
  for i = 1, 14 do names[i] = "m" .. i end
  -- What each requires: some of the others, and a module of the standard library.
  local needs: {string:{string}} = {}
  local pick = chooser(7)
  for i, name in ipairs(names) do
    local list: {string} = {}
    for j = 1, i - 1 do
      if pick(3) == 1 then list[#list + 1] = names[j] end
    end
    if pick(4) == 1 then list[#list + 1] = "cosmic.fs" end
    needs[name] = list
  end
  local held = { salt = 0 }
  local files: {string:string} = {}
  local function write(name: string)
    local file = files[name] or (name .. ".tl")
    files[name] = file
    assert(Fs.mkdirs(root .. "/" .. (file:match("^(.*)/[^/]*$") or ".")))
    held.salt = held.salt + 1
    assert(Fs.write(root .. "/" .. file, source_of(name, needs[name], held.salt)))
  end
  for _, name in ipairs(names) do write(name) end
  assert(same_keys(root, "tool-one") == "", "the first keys differ")

  local choose = chooser(11)
  local declared: {string:boolean} = {}
  for step = 1, 24 do
    local name = names[choose(#names)]
    local edit = choose(6)
    local what: string
    if edit == 1 or edit == 2 then
      what = "a comment in " .. name
      write(name)
    elseif edit == 3 then
      what = "an edge of " .. name
      local other = names[choose(#names)]
      local list: {string} = {}
      local present = false
      for _, need in ipairs(needs[name]) do
        if need == other then present = true else list[#list + 1] = need end
      end
      if not present and other ~= name then list[#list + 1] = other end
      needs[name] = list
      write(name)
    elseif edit == 4 then
      what = "a declaration of " .. name
      local path = root .. "/" .. name .. ".d.tl"
      if declared[name] then
        assert(Fs.remove(path))
        declared[name] = nil
      else
        assert(Fs.write(path, "local record " .. name .. "\n  value: integer\nend\nreturn " .. name .. "\n"))
        declared[name] = true
      end
    elseif edit == 5 then
      what = "the file of " .. name
      local from = root .. "/" .. (files[name] or "")
      local to = files[name] == name .. ".tl" and (name .. "/init.tl") or (name .. ".tl")
      assert(Fs.mkdirs(root .. "/" .. name))
      local text = assert(Fs.read(from))
      assert(Fs.remove(from))
      assert(Fs.write(root .. "/" .. to, text))
      files[name] = to
    else
      what = "the compiler"
    end
    local trouble = same_keys(root, edit == 6 and ("tool-" .. step) or "tool-one")
    assert(trouble == "", "step " .. step .. ", " .. what .. ": the keys of " .. trouble .. "differ")
  end
end

--- Keys kept for one compiler are not another's.
local function test_the_keys_kept_for_one_compiler_are_not_served_for_another()
  local root = assert(Fs.mkdtemp("cosmic-dependency-keys-tool-"))
  assert(Fs.write(root .. "/a.tl", source_of("a", {}, 1)))
  assert(Fs.write(root .. "/b.tl", source_of("b", { "a" }, 1)))
  local function key_of(tool: string): string
    local handle = assert(work.open(root))
    assert(work.stage(handle, false))
    assert(importer.derive(handle, false, built))
    local modules = assert(compilation.collect(handle.db))
    local keys = assert(compilation.dependency_keys(handle.db, modules, tool))
    work.close(handle)
    return assert(keys["b"]).key
  end
  local one = key_of("tool-one")
  local other = key_of("tool-other")
  assert(one ~= other, "the key of a module did not move with the compiler")
  assert(key_of("tool-one") == one, "the keys of a compiler came back other than they were")
end
