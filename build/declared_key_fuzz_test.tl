--- Fuzz property for `declared_key.preimage`: a sandboxed test's key
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
local test_inputs = require("build.test_inputs")

--- The scalar fields of a spec a preimage names, in the order it spells
--- them, and the optional ones, which are there or not.
local SCALARS <const> = { "id", "module_key", "runtime", "compiler", "host",
  "declaration", "launcher", "tree", "program", "closure_store", "system" }
local OPTIONAL <const>: {string:boolean} = { launcher = true, tree = true,
  closure_store = true }

--- The collections a spec's inputs name: its closure's files, the paths
--- of the tree it reads, the host paths it declares, and the
--- environment its worker is given, as names and values in turn.
local LISTS <const> = { "files", "reads", "hosts", "environment" }

--- A spec as a generator draws it: each scalar a string or, for an
--- optional one, absent (nil); each list of strings.
local record Drawn
  scalars: {string:string}
  lists: {string:{string}}
end

--- Bytes a framing would single out: separators a preimage or a value
--- might split on, a NUL, and hex digits, which a framing by hex spells.
local ALPHABET <const> = { "a", "b", "0", "f", " ", "\n", ":", "\0" }

--- The same, less what a path cannot hold or a key reads as a place
--- (`test_inputs.plain`): a path of the tree or of the host is named by
--- what it is, and "a/./b" and "a/b" are one path.
local PATH_ALPHABET <const> = { "a", "b", "0", "f", " ", "\n", ":" }

local function draw_string(src: Fuzz.Source, alphabet: {string}, least: integer): string
  local out: {string} = {}
  while #out < least or Fuzz.more(src, #out, 6) do out[#out + 1] = Fuzz.pick(src, alphabet) end
  return table.concat(out)
end

--- Each list as a key holds it: files, reads and host paths are sets,
--- the environment a map by name, so a spec that lists one twice, or
--- in another order, is the same spec.
local function canonical(d: Drawn): Drawn
  local out: Drawn = { scalars = d.scalars, lists = {} }
  for _, name in ipairs({ "files", "reads", "hosts" }) do
    local seen: {string:boolean} = {}
    local set: {string} = {}
    for _, entry in ipairs(d.lists[name]) do
      if entry ~= "" and not seen[entry] then
        seen[entry] = true
        set[#set + 1] = entry
      end
    end
    table.sort(set)
    out.lists[name] = set
  end
  local values: {string:string} = {}
  local env = d.lists.environment
  for i = 1, #env - 1, 2 do
    -- The last value of a name given twice, as `spec_of` gives it.
    if env[i] ~= "" then values[env[i]] = env[i + 1] end
  end
  local names: {string} = {}
  for name in pairs(values) do names[#names + 1] = name end
  table.sort(names)
  local pairs_out: {string} = {}
  for _, name in ipairs(names) do
    pairs_out[#pairs_out + 1] = name
    pairs_out[#pairs_out + 1] = values[name]
  end
  out.lists.environment = pairs_out
  return out
end

--- A drawn spec as one string: the same string for the same spec.
local function pack(d: Drawn): string
  local c = canonical(d)
  local fields: {string} = {}
  for _, name in ipairs(SCALARS) do
    local value = c.scalars[name]
    fields[#fields + 1] = value == nil and "-" or ("+" .. value)
  end
  for _, name in ipairs(LISTS) do fields[#fields + 1] = Fuzz.pack(c.lists[name]) end
  return Fuzz.pack(fields)
end

local function unpack(packed: string): Drawn
  local fields = Fuzz.unpack(packed)
  local d: Drawn = { scalars = {}, lists = {} }
  for i, name in ipairs(SCALARS) do
    local value = fields[i]
    if value:sub(1, 1) == "+" then d.scalars[name] = value:sub(2) end
  end
  for i, name in ipairs(LISTS) do d.lists[name] = Fuzz.unpack(fields[#SCALARS + i]) end
  return d
end

local function copy(d: Drawn): Drawn
  local out: Drawn = { scalars = {}, lists = {} }
  for name, value in pairs(d.scalars) do out.scalars[name] = value end
  for name, list in pairs(d.lists) do
    local each: {string} = {}
    for i, entry in ipairs(list) do each[i] = entry end
    out.lists[name] = each
  end
  return out
end

local function draw_spec(src: Fuzz.Source): Drawn
  local d: Drawn = { scalars = {}, lists = {} }
  for _, name in ipairs(SCALARS) do
    if not OPTIONAL[name] or src:int(0, 1) == 1 then
      d.scalars[name] = draw_string(src, ALPHABET, 0)
    end
  end
  for _, name in ipairs(LISTS) do
    local list: {string} = {}
    local alphabet = name == "environment" and ALPHABET or PATH_ALPHABET
    while Fuzz.more(src, #list, 6) do list[#list + 1] = draw_string(src, alphabet, 1) end
    -- The environment is names and values in turn.
    if name == "environment" and #list % 2 == 1 then list[#list + 1] = "" end
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
    local a, b = SCALARS[at], SCALARS[at + 1]
    local left, right = out.scalars[a] or "", out.scalars[b] or ""
    if left ~= "" then
      out.scalars[a], out.scalars[b] = left:sub(1, -2), left:sub(-1) .. right
    end
  else
    local list = out.lists[Fuzz.pick(src, LISTS)]
    if #list >= 2 then
      local at = src:int(1, #list - 1)
      local left = list[at]
      if left ~= "" then list[at], list[at + 1] = left:sub(1, -2), left:sub(-1) .. list[at + 1] end
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
    if OPTIONAL[name] and src:int(0, 1) == 1 then
      out.scalars[name] = out.scalars[name] == nil and "" or nil
    else
      out.scalars[name] = draw_string(src, ALPHABET, 0)
    end
  else
    local name = Fuzz.pick(src, LISTS)
    local list = out.lists[name]
    local step = name == "environment" and 2 or 1
    if kind == 2 and #list > 0 then
      -- An entry split in two, or two joined.
      local at = src:int(1, #list)
      if src:int(0, 1) == 0 and #list[at] >= 2 then
        local cut = src:int(1, #list[at] - 1)
        table.insert(list, at + 1, list[at]:sub(cut + 1))
        list[at] = list[at]:sub(1, cut)
      elseif at < #list then
        list[at] = list[at] .. table.remove(list, at + 1)
      end
    elseif kind == 3 and #list >= step then
      -- One dropped.
      local at = (src:int(1, #list // step) - 1) * step + 1
      for _ = 1, step do table.remove(list, at) end
    else
      -- One added.
      for _ = 1, step do
        list[#list + 1] = draw_string(src, name == "environment" and ALPHABET or PATH_ALPHABET, 1)
      end
    end
    if name == "environment" and #list % 2 == 1 then list[#list + 1] = "" end
  end
  return out
end

--- The spec `d` names, of a test whose host
--- paths are beneath `host`. Every part a preimage holds only as another
--- says is held: its module runs the tool (`program`), is given the
--- system (`system`), and is given the store of its closure rather than
--- the projection (`closure_store`).
local function spec_of(d: Drawn, host: string): declared_key.Spec
  local files: {string:boolean} = {}
  for _, file in ipairs(d.lists.files) do files[file] = true end
  local hosts: {string} = {}
  for _, path in ipairs(d.lists.hosts) do hosts[#hosts + 1] = host .. "/" .. path end
  local environment: {string:string} = {}
  local env = d.lists.environment
  for i = 1, #env - 1, 2 do environment[env[i]] = env[i + 1] end
  local effective: test_inputs.Effective = {
    files = files, reads = d.lists.reads, host = hosts, env = {}, network = {},
    processes = false, tool = true, store = false, system = true, caches = {},
    cache_paths = {},
  }
  local s = d.scalars
  return {
    id = s.id, group = "group", module_key = s.module_key, runtime = s.runtime,
    compiler = s.compiler, epoch = "1-00000000", timeout_ms = 30000, program = s.program, host = s.host,
    system = s.system, launcher = s.launcher, declaration = s.declaration,
    effective = effective, environment = environment, runs_tool = false,
    closure_store = s.closure_store, tree = s.tree,
  }
end

--- All a key digests of `spec` but `version`: its name, framed as
--- `compute` frames it, and its preimage.
local function spelled(root: string, spec: declared_key.Spec): string
  local preimage = assert(declared_key.preimage(declared_key.digests(root), spec))
  return declared_key.key_part("i", spec.id, "") .. "\n" .. preimage
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
      return Fuzz.pack({ shifted and "shift" or "edit", pack(one), pack(other) })
    end,
    check = function(input: string): boolean, string
      local parts = Fuzz.unpack(input)
      if parts[2] == parts[3] then
        Fuzz.label("same")
        return true, ""
      end
      Fuzz.label(parts[1] == "shift" and "shifted" or "edited")
      local one = spelled(root, spec_of(unpack(parts[2]), host))
      local other = spelled(root, spec_of(unpack(parts[3]), host))
      if one == other then return false, "two specs spell one preimage" end
      return true, ""
    end,
    requires = { "shifted", "edited" },
    shares = { shifted = 0.1, edited = 0.1 },
  })
end

--- A variable named twice is given its last value, by `spec_of` and by
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
