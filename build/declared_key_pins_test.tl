--- What no key holds by its code, which build/declared_key.tl's
--- `version` stands for: a module's graph key (`build.importer`),
--- pinned over a small fixed tree. An edit that moves how it is
--- computed, and so what a key names, must bump `version` there, or
--- verdicts kept under the old keys stand for what the new ones name;
--- this fails until it is bumped and the digests here are taken again.
--- The store of a test's closure is not pinned: its address is salted
--- by the code that writes it (`build.test`'s `store_salt`), so an edit
--- there moves every address already.

local Fs = require("cosmic.fs")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

--- What a failed pin says, beside what moved and where to.
local function bump(what: string): string
  return what .. " moved: an encoding that moves every key must bump `version` in " ..
    "build/declared_key.tl, then take the digests here again"
end

--- A module's graph key -- the kinds, sources and requires of its
--- import graph -- over a fixed tree: a test module, the library it
--- requires, and a module that library reaches through a declaration
--- of its own, which the graph holds both of. The fixture requires no
--- module of the standard library, whose source a graph key holds too.
local function test_the_graph_key_is_pinned(tmp: string)
  local built = assert(teal.load())
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root))
  local files: {string:string} = {
    ["greet.tl"] = 'local shape = require("shape")\nlocal record greet\nend\n' ..
      'function greet.hello(): string\n  return "hello, " .. shape.name()\nend\n' ..
      "return greet\n",
    ["shape.d.tl"] = "local record shape\n  name: function(): string\nend\nreturn shape\n",
    ["shape.tl"] = 'local record shape\nend\nfunction shape.name(): string\n  return "shape"\n' ..
      "end\nreturn shape\n",
    ["greet_test.tl"] = 'local greet = require("greet")\nlocal function test_hello()\n' ..
      '  assert(greet.hello() ~= "")\nend\n',
  }
  for name, text in pairs(files) do assert(Fs.write(root .. "/" .. name, text)) end
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local result = assert(importer.compile(handle, built, "declared-key-pins-test"))
  assert(work.close(handle))
  local keys: {string:string} = {}
  for _, m in ipairs(result.modules) do keys[m.path] = m.graph_key end
  local pinned: {string:string} = {
    greet = "4d064f306aece5afe9d3df587cb38afac995022ee430af425021811044c42c1d",
    greet_test = "0a612f45ba0e340374c42b67687f0b2277e044b2dd33bb2cfcffafb51654fd2d",
    shape = "a80ca828ba28a296f986ab8789dc768160390738b4d7deffcb6a47dcc6f84036",
  }
  local moved: {string} = {}
  for name, want in pairs(pinned) do
    local got = tostring(keys[name])
    if got ~= want then moved[#moved + 1] = name .. " = \"" .. got .. "\"" end
  end
  table.sort(moved)
  assert(#moved == 0, bump("the graph key of " .. table.concat(moved, ", ")))
end
