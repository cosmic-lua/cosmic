--- Fuzz property for [`declared_key.preimage`]: a sandboxed test's key
--- is the digest of what it was given (build/declared_key.tl), so two
--- specs that differ must spell apart before anything is hashed -- an
--- encoding that framed two fields, or two entries, so that one spells
--- as another would key two tests' inputs alike, and a verdict reached
--- on one would stand for the other. Each input is a spec and another
--- made from it by one edit: a byte moved across the boundary of two
--- fields or of an entry and the next, an entry split, joined, added or
--- dropped, a field drawn again, or one present or not.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fs = require("cosmic.fs")
local Fuzz = require("build.fuzz")
local declared_key = require("build.declared_key")
local key_parts = require("build.key_parts")
local test_inputs = require("build.test_inputs")
local Clock = require("cosmic.clock")
local support = require("build.test_support_fixture")

--- The scalar fields of a spec a preimage names, in the order it spells
--- them, and the optional ones, which are there or not.
local SCALARS <const> = { "id", "module_key", "runtime", "compiler", "host",
  "declaration", "launcher", "tree", "program", "closure_store", "system" }
local OPTIONAL <const>: {string:boolean} = { launcher = true, tree = true,
  closure_store = true }

--- The collections a spec's inputs name: its closure's files, the paths
--- of the tree it reads, the host paths it declares, and the
--- environment its worker is given, as names and values in turn.
local LISTS <const> = { "files", "reads", "hosts", "environment", "requires" }

--- The lists that are names and values in turn, a map by name.
local function is_map(name: string): boolean return name == "environment" or name == "requires" end

--- A spec as a generator draws it: each scalar a string or, for an
--- optional one, absent (nil); each list of strings.
local record Drawn
  scalars: mut {string:string}
  lists: mut {string:{string}}
end

--- Bytes a framing would single out: separators a preimage or a value
--- might split on, a NUL, and hex digits, which a framing by hex spells.
local ALPHABET <const> = { "a", "b", "0", "f", " ", "\n", ":", "\0" }

--- The same less NUL, which no path can hold. Neither alphabet holds "."
--- or "/": a key reads a path as the place it names
--- ([`test_inputs.plain`]), so "a/./b" and "a/b" are one path.
local PATH_ALPHABET <const> = { "a", "b", "0", "f", " ", "\n", ":" }

--- The list `d` holds under `name`: a drawn spec holds every one of [`LISTS`].
local function list_of(d: Drawn, name: string): {string}
  local list = d.lists[name]
  assert(list, name .. " is a list a drawn spec holds")
  return list
end

--- `list` with `drop` entries from `at` replaced by `put`, as a new list: the entries before and after are not written in
--- place, which a list that is not `mut` does not allow.
local function splice(list: {string}, at: integer, drop: integer, put: {string}): mut {string}
  local out: mut {string} = {}
  for i = 1, at - 1 do out[#out + 1] = support.nth(list, i) end
  for _, entry in ipairs(put) do out[#out + 1] = entry end
  for i = at + drop, #list do out[#out + 1] = support.nth(list, i) end
  return out
end

local function draw_string(src: Fuzz.Source, alphabet: {string}, least: integer): string
  local out: mut {string} = {}
  while #out < least or Fuzz.more(src, #out, 6) do out[#out + 1] = Fuzz.pick(src, alphabet) end
  return table.concat(out)
end

--- Each list as a key holds it: files, reads and host paths are sets,
--- the environment a map by name, so a spec that lists one twice, or
--- in another order, is the same spec.
local function canonical(d: Drawn): Drawn
  local out: Drawn = { scalars = d.scalars, lists = {} }
  for _, name in ipairs({ "files", "reads", "hosts" }) do
    local seen: mut {string:boolean} = {}
    local set: mut {string} = {}
    for _, entry in ipairs(list_of(d, name)) do
      if entry ~= "" and seen[entry] ~= true then
        seen[entry] = true
        set[#set + 1] = entry
      end
    end
    table.sort(set)
    out.lists[name] = set
  end
  for _, map in ipairs({ "environment", "requires" }) do
    local values: mut {string:string} = {}
    local env = list_of(d, map)
    for i = 1, #env - 1, 2 do
      -- The last value of a name given twice, as [`spec_of`] gives it.
      local name, value = support.nth(env, i), support.nth(env, i + 1)
      if name ~= "" then values[name] = value end
    end
    local names: mut {string} = {}
    for name in pairs(values) do names[#names + 1] = name end
    table.sort(names)
    local pairs_out: mut {string} = {}
    for _, name in ipairs(names) do
      local value = values[name]
      assert(value, name .. " is a name collected above")
      pairs_out[#pairs_out + 1] = name
      pairs_out[#pairs_out + 1] = value
    end
    out.lists[map] = pairs_out
  end
  return out
end

--- A drawn spec as one string: the same string for the same spec.
local function pack(d: Drawn): string
  local c = canonical(d)
  local fields: mut {string} = {}
  for _, name in ipairs(SCALARS) do
    local value = c.scalars[name]
    fields[#fields + 1] = if value == nil then "-" else ("+" .. value) end
  end
  for _, name in ipairs(LISTS) do fields[#fields + 1] = Fuzz.pack(list_of(c, name)) end
  return Fuzz.pack(fields)
end

local function unpack(packed: string): Drawn
  local fields = Fuzz.unpack(packed)
  local d: Drawn = { scalars = {}, lists = {} }
  for i, name in ipairs(SCALARS) do
    local value = support.nth(fields, i)
    if value:sub(1, 1) == "+" then d.scalars[name] = value:sub(2) end
  end
  for i, name in ipairs(LISTS) do d.lists[name] = Fuzz.unpack(support.nth(fields, #SCALARS + i)) end
  return d
end

local function copy(d: Drawn): Drawn
  local out: Drawn = { scalars = {}, lists = {} }
  for name, value in pairs(d.scalars) do out.scalars[name] = value end
  for name, list in pairs(d.lists) do
    local each: mut {string} = {}
    for i, entry in ipairs(list) do each[i] = entry end
    out.lists[name] = each
  end
  return out
end

local function draw_spec(src: Fuzz.Source): Drawn
  local d: Drawn = { scalars = {}, lists = {} }
  for _, name in ipairs(SCALARS) do
    if OPTIONAL[name] ~= true or src:int(0, 1) == 1 then
      d.scalars[name] = draw_string(src, ALPHABET, 0)
    end
  end
  for _, name in ipairs(LISTS) do
    local list: mut {string} = {}
    local alphabet = is_map(name) and ALPHABET or PATH_ALPHABET
    while Fuzz.more(src, #list, 6) do list[#list + 1] = draw_string(src, alphabet, 1) end
    -- The environment is names and values in turn.
    if is_map(name) and #list % 2 == 1 then list[#list + 1] = "" end
    d.lists[name] = list
  end
  return d
end

--- `d` with one byte moved from the end of one string to the start of
--- the next: two scalars the preimage spells in turn, or two entries of
--- a list, or a variable's name and its value.
local function shift(src: Fuzz.Source, d: Drawn): Drawn
  local out = copy(d)
  if src:int(0, 1) == 0 then
    local at = src:int(1, #SCALARS - 1)
    local a, b = support.nth(SCALARS, at), support.nth(SCALARS, at + 1)
    local left, right = out.scalars[a] or "", out.scalars[b] or ""
    if left ~= "" then
      out.scalars[a], out.scalars[b] = left:sub(1, -2), left:sub(-1) .. right
    end
  else
    local name = Fuzz.pick(src, LISTS)
    local list = list_of(out, name)
    if #list >= 2 then
      local at = src:int(1, #list - 1)
      local left, right = support.nth(list, at), support.nth(list, at + 1)
      if left ~= "" then
        out.lists[name] = splice(list, at, 2, { left:sub(1, -2), left:sub(-1) .. right })
      end
    end
  end
  return out
end

--- `d` with one edit other than a shift.
local function edit(src: Fuzz.Source, d: Drawn): Drawn
  local out = copy(d)
  local kind = src:int(1, 4)
  if kind == 1 then
    -- A scalar drawn again, or one present or not.
    local name = Fuzz.pick(src, SCALARS)
    if OPTIONAL[name] == true and src:int(0, 1) == 1 then
      if out.scalars[name] == nil then out.scalars[name] = "" else out.scalars[name] = nil end
    else
      out.scalars[name] = draw_string(src, ALPHABET, 0)
    end
  else
    local name = Fuzz.pick(src, LISTS)
    local list = list_of(out, name)
    local step = if is_map(name) then 2 else 1 end
    if kind == 2 and #list > 0 then
      -- An entry split in two, or two joined.
      local at = src:int(1, #list)
      local entry = support.nth(list, at)
      if src:int(0, 1) == 0 and #entry >= 2 then
        local cut = src:int(1, #entry - 1)
        out.lists[name] = splice(list, at, 1, { entry:sub(1, cut), entry:sub(cut + 1) })
      elseif at < #list then
        out.lists[name] = splice(list, at, 2, { entry .. support.nth(list, at + 1) })
      end
      list = list_of(out, name)
    elseif kind == 3 and #list >= step then
      -- One dropped.
      local at = (src:int(1, #list // step) - 1) * step + 1
      for _ = 1, step do table.remove(list, at) end
    else
      -- One added.
      for _ = 1, step do
        local drawn = draw_string(src, is_map(name) and ALPHABET or PATH_ALPHABET, 1)
        list[#list + 1] = drawn
      end
    end
    if is_map(name) and #list % 2 == 1 then list[#list + 1] = "" end
  end
  return out
end

--- The spec `d` names, of a test whose host paths are beneath `host`.
--- Every part a preimage holds only as another says is held: its module
--- runs the tool (`program`), is given the system (`system`), and is
--- given the store of its closure rather than the projection
--- (`closure_store`).
-- TODO: draw the files above the project (`effective.parent`) too, so the
-- fuzz holds the key's `up` lines distinct from its other parts; the
-- cases of build/declared_key_test.tl hold their contents and relative
-- paths to the key alone.
local function spec_of(d: Drawn, host: string): declared_key.Spec
  local files: mut {string:boolean} = {}
  for _, file in ipairs(d.lists.files) do files[file] = true end
  local hosts: mut {string} = {}
  for _, path in ipairs(d.lists.hosts) do hosts[#hosts + 1] = host .. "/" .. path end
  local environment: mut {string:string} = {}
  local env = d.lists.environment
  for i = 1, #env - 1, 2 do environment[env[i]] = env[i + 1] end
  local required: mut {string:string} = {}
  local asked = d.lists.requires
  for i = 1, #asked - 1, 2 do required[asked[i]] = asked[i + 1] end
  local effective: test_inputs.Effective = {
    files = files, reads = d.lists.reads, host = hosts, env = {}, network = {},
    tool = true, store = false, system = true, caches = {},
    cache_paths = {},
  }
  local s = d.scalars
  return {
    id = s.id, group = "group", module_key = s.module_key, runtime = s.runtime,
    compiler = s.compiler, epoch = "1-00000000", timeout_ns = Clock.seconds(30), program = s.program, host = s.host,
    system = s.system, launcher = s.launcher, declaration = s.declaration,
    effective = effective, environment = environment, requires = required, runs_tool = false,
    closure_store = s.closure_store, tree = s.tree,
  }
end

--- All a key digests of `spec` but `version`: its name, framed as
--- `compute` frames it, and its preimage.
local function spelled(root: string, spec: declared_key.Spec): string
  local preimage = assert(declared_key.preimage(declared_key.digests(root), spec))
  return key_parts.key_part("i", spec.id, "") .. "\n" .. preimage
end

local function test_distinct_specs_spell_distinct_preimages(tmp: string)
  local root, host = tmp .. "/tree", tmp .. "/host"
  assert(Fs.mkdirs(root))
  assert(Fs.mkdirs(host))
  Fuzz.run({
    name = "declared key preimage",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local one = draw_spec(src)
      local shifted = src:int(0, 1) == 0
      local other = shifted and shift(src, one) or edit(src, one)
      return Fuzz.pack({ if shifted then "shift" else "edit" end, pack(one), pack(other) })
    end,
    check = function(input: string): boolean, string
      local parts = Fuzz.unpack(input)
      if parts[2] == parts[3] then
        Fuzz.label("same")
        return true, ""
      end
      Fuzz.label(if parts[1] == "shift" then "shifted" else "edited" end)
      local one = spelled(root, spec_of(unpack(support.nth(parts, 2)), host))
      local other = spelled(root, spec_of(unpack(support.nth(parts, 3)), host))
      if one == other then return false, "two specs spell one preimage" end
      return true, ""
    end,
    requires = { "shifted", "edited" },
    shares = { shifted = 0.1, edited = 0.1 },
  })
end

--- A variable named twice is given its last value, by [`spec_of`] and by
--- `canonical` alike: two lists that give the same environment pack
--- as one spec, so the property does not fail them as two.
local function test_a_variable_named_twice_packs_as_its_last_value()
  local one = draw_spec({ int = function(_: Fuzz.Source, min: integer, _max: integer): integer
    return min
  end })
  local other = copy(one)
  one.lists.environment = { "X", "a", "X", "b" }
  other.lists.environment = { "X", "b" }
  assert(pack(one) == pack(other), "one environment packed as two")
  assert(spec_of(unpack(pack(one)), "/host").environment.X == "b")
end
