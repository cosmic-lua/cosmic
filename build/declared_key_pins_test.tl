--- What no key holds by its code, which build/declared_key.tl's
--- `version` stands for: a module's graph key ([`build.importer`]),
--- pinned over a small fixed tree. An edit that moves how it is
--- computed, and so what a key names, must bump `version` there, or
--- verdicts kept under the old keys stand for what the new ones name;
--- this fails until it is bumped and the digests here are taken again.
--- The store of a test's closure is not pinned: a key holds it by its
--- bytes ([`declared_key.store_digest`]), so an edit to the code that
--- writes it that moves them moves every key that holds one already.

local Fs = require("cosmic.fs")
local importer = require("build.importer")
local work = require("build.work")

--- What a failed pin says, beside what moved and where to.
local function bump(what: string): string
  return what .. " moved: an encoding that moves every key must bump `version` in " ..
    "build/declared_key.tl, then take the digests here again"
end

--- A module's graph key -- the kinds, sources and requires of its
--- import graph -- over a fixed tree: a test module, the library it
--- requires, and a declaration that library reaches. The fixture requires no
--- module of the standard library, whose source a graph key holds too.
local function test_the_graph_key_is_pinned(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root))
  local files: {string:string} = {
    ["greet.tl"] = 'local shape = require("shape")\nlocal record greet\nend\n' ..
      'function greet.hello(): string\n  return "hello, " .. shape.name()\nend\n' ..
      "return greet\n",
    ["shape.d.tl"] = "local record shape\n  name: function(): string\nend\nreturn shape\n",
    ["greet_test.tl"] = 'local greet = require("greet")\nlocal function test_hello()\n' ..
      '  assert(greet.hello() ~= "")\nend\n',
  }
  for name, text in pairs(files) do assert(Fs.write(root .. "/" .. name, text)) end
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, "declared-key-pins-test"))
  assert(work.close(handle))
  local keys: mut {string:string} = {}
  for _, m in ipairs(result.modules) do keys[m.path] = assert(m.graph_key) end
  local pinned: {string:string} = {
    greet = "452d1d88a705d377f2c7f4445c49aa854236e844c3c70c9949ae1e96743d9d3c",
    greet_test = "d554b1d34bce1f8dedba1c008ac3f26ab1e773a0e5d66a923ceb12ad49c75d8d",
  }
  local moved: mut {string} = {}
  for name, want in pairs(pinned) do
    local got = tostring(keys[name])
    if got ~= want then moved[#moved + 1] = name .. " = \"" .. got .. "\"" end
  end
  table.sort(moved)
  assert(#moved == 0, bump("the graph key of " .. table.concat(moved, ", ")))
end
