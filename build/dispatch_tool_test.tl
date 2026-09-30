--- What this program loads before it runs `-e`'s chunk: the child most
--- tests start, so every module [`build.dispatch`] requires ahead of it
--- is paid by each of them.

local Child = require("cosmic.child")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, started with `-e`.
Test.needs{ lua = true }

--- The `build.*` modules `-e` may have loaded as its chunk runs: dispatch,
--- the exit status its answer is read as, the verdict logger that reads
--- through, and the slot dispatch leaves `cosmic help`'s texts in.
local allowed <const> = 4

--- The `cosmic.*` modules `-e` may have loaded: the verdict logger's and
--- what it reads through. A verb's own ([`cosmic.cli`], [`cosmic.flags`],
--- [`cosmic.store`]) is not among them.
local library: {string: boolean} = {
  ["cosmic.env"] = true,
  ["cosmic.fs"] = true,
  ["cosmic.log"] = true,
  ["cosmic.sys"] = true,
}

--- `-e` loads no verb, no help and none of the build, and of the standard
--- library only what the verdict logger reads: a module required at
--- dispatch's top level for a verb's sake is loaded by every child a test
--- starts, and fails this.
local function test_e_loads_none_of_the_verbs(tmp: string)
  local started = this_program.program({ "-e", [[
local names = {}
for name in pairs(package.loaded) do
  if name:match("^build%.") or name:match("^cosmic%.") then names[#names + 1] = name end
end
table.sort(names)
print(table.concat(names, " "))
]] }, { env = {}, cwd = tmp, stdout = "capture", stderr = "capture", timeout_ms = 30000 })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, tostring(r.stdout) .. tostring(r.stderr))
  local names: {string} = {}
  for name in (r.stdout or ""):gmatch("%S+") do
    if name:match("^build%.") then
      names[#names + 1] = name
    else
      assert(library[name], name .. " is loaded before -e's chunk runs: " .. tostring(r.stdout))
    end
  end
  assert(#names > 0 and #names <= allowed, #names .. " build modules, more than " .. allowed ..
    ": " .. tostring(r.stdout))
  local loaded = " " .. table.concat(names, " ") .. " "
  for _, name in ipairs({ "build.dispatch", "build.exit_status" }) do
    assert(loaded:find(" " .. name .. " ", 1, true), name .. " is not among " .. loaded)
  end
end
