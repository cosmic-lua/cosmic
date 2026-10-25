--- `cosmic compile` over the checker's own source, `checker/*.tl`: all of
--- it compiles without a refusal, though the checker's source has type
--- errors under its own rules (build/compiler_test.tl pins their count).
--- That is what lets a released cosmic seed the checker. A module of its
--- own because it parses and checks all of the checker, which takes several
--- seconds.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Store = require("cosmic.store")
local checker_wrapper = require("build.checker_wrapper")
local compile = require("build.compile")
local teal = require("build.teal")

Test.policy{ grants = { { path = "checker/", letters = "r" } } }

--- The seed's call: the glob `checker/*.tl`, a declaration file among it.
local function test_the_glob_of_the_checker_gives_the_carried_compiler(tmp: string)
  local sources: mut {string} = {}
  for _, name in ipairs((assert(Fs.list("checker")))) do
    if name:find("%.tl$") ~= nil then sources[#sources + 1] = "checker/" .. name end
  end
  table.sort(sources)
  local argv: mut {string} = { "compile", "-o", tmp .. "/out" }
  for index, path in ipairs(sources) do argv[index + 3] = path end
  local complaints: {string} = {}
  local code = compile.run(argv, {
    out = function(_text: string): boolean, string return true, "" end,
    err = function(line: string) complaints[#complaints + 1] = line end,
  }, (assert(teal.load(true))))
  assert(code == 0, table.concat(complaints, "\n"))
  assert(#sources >= 6, "expected the checker's files, found " .. #sources)
  for _, path in ipairs(sources) do
    local name = (path:gsub("^checker/", ""):gsub("%.d%.tl$", ""):gsub("%.tl$", ""))
    if not path:find("%.d%.tl$") then
      local text = (assert(Fs.read(tmp .. "/out/" .. name .. ".lua")))
      assert(#text > 0 and load(text, "=" .. name) ~= nil, name .. " does not load")
    end
  end
  local said = table.concat(complaints, "\n")
  assert(said:find("checker/tl.tl: ", 1, true) and said:find("type errors, the Lua is written anyway", 1, true), said)
  assert(Fs.exists(tmp .. "/out/stdlib.lua") == false and Fs.exists(tmp .. "/out/stdlib.d.lua") == false)
  local function lua(name: string): string
    return (assert(Fs.read(tmp .. "/out/" .. name .. ".lua")))
  end
  local modules: mut {{string}} = {}
  for index, name in ipairs({ "captures", "facts", "flow", "narrowing" }) do
    modules[index] = { "checker." .. name, lua(name), "checker/" .. name .. ".tl" }
  end
  local wrapped = checker_wrapper.wrapped(lua("tl"), (assert(Fs.read("checker/stdlib.d.tl"))), modules)
  assert(wrapped == Store.source("vendor.tl"), "the glob's Lua, wrapped, is not the carried compiler")
end
