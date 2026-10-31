--- A child of a test that runs the test module's own code. A test that must start this program to run code only a
--- test module may hold -- the C bindings it reaches by a cast, a hand-made table -- registers the code as a child of
--- its module at its top level, and starts this program again to run it:
---
---     local test_child = require("build.test_child")
---     test_child.register("sleeper", function(args: {string}): integer
---       -- runs in the child, as part of the module's own checked code
---       return 0
---     end)
---     ...
---     local started = this_program.program(test_child.words(tmp, "build.thing_test", "sleeper", { "arg" }))
---
--- The child loads the module (so its top level runs again, in the child, registering the same names) and calls the
--- one child by name with the words after the chunk. `cosmic -e` checks the chunk it is handed as Teal, so a child
--- written as a string of Lua cannot reach what the module reaches; this keeps that code in the module the build
--- checks. A test module is no row of the store its child runs on, so the test writes the module's row into a store
--- of its own under `dir`, which the chunk attaches before it loads the module.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local bind = require("build.bind")
local schema = require("build.schema")

local record test_child
  --- Registers `body` as the child `name` of the module that requires this one. Raises for a name already given.
  register: function(name: string, body: function(args: {string}): integer)

  --- The words after `cosmic` that run the child `name` of the test module `module` (its import path), with `args`
  --- as the words the child is called with: `-e`, the chunk, then the store written for the module, in `dir`, and
  --- `args`. Raises when the store cannot be written.
  words: function(dir: string, module: string, name: string, args?: {string}): {string}

  --- Calls the child `name`, registered by the module the chunk loaded, with `...` as its `args`, and answers its
  --- exit status. Raises for a name nothing registered.
  run: function(name: string, ...: string?): integer
end

local bodies: mut {string: function(args: {string}): integer} = {}

function test_child.register(name: string, body: function(args: {string}): integer)
  if bodies[name] ~= nil then
    error("test_child: " .. name .. " is registered twice", 2)
  end
  bodies[name] = body
end

--- A store of the one module `module`, as the running process has it, written at `path`.
local function store_of(module: string, path: string): boolean, string
  local bytecode, bytecode_trouble = Store.bytecode(module)
  if bytecode == nil then return false, module .. ": " .. bytecode_trouble end
  local basis = Store.meta("runtime_basis")
  if basis == nil or basis == "" then return false, "the running binary names no runtime basis" end
  local _, _ = Fs.remove(path)
  local db, open_trouble = Sqlite.open(path, { writable = true })
  if db == nil then return false, path .. ": " .. open_trouble end
  local statements: mut {string} = {}
  for _, statement in ipairs(schema.settings("")) do statements[#statements + 1] = statement end
  for _, statement in ipairs(schema.create("")) do statements[#statements + 1] = statement end
  for _, statement in ipairs(statements) do
    local ok, failure = db:exec(statement)
    if not ok then
      local _, _ = db:close()
      return false, failure
    end
  end
  local made, trouble = Sqlite.transact(db, function(): boolean, string
    local row, row_trouble = Sqlite.run(db, "INSERT INTO modules (path, file, kind, source_hash, key, bytecode, tests, " ..
        "source) VALUES (?1, '', 'module', x'', x'', deflate(?2), '', x'')", { bind.text(module), bind.blob(bytecode) })
    if not row then return false, row_trouble end
    local meta, meta_trouble = Sqlite.run(db, "INSERT INTO meta (key, value) VALUES ('runtime_basis', ?1)",
      { bind.text(basis) })
    if not meta then return false, meta_trouble end
    return true, ""
  end)
  local _, _ = db:close()
  if not made then return false, trouble end
  return true, ""
end

function test_child.words(dir: string, module: string, name: string, args?: {string}): {string}
  local path = dir .. "/" .. module .. ".child.db"
  local written, trouble = store_of(module, path)
  if not written then error("test_child: " .. trouble, 2) end
  local chunk = 'local Store = require("cosmic.store")\nlocal test_child = require("build.test_child")\n' ..
    'local path = ...\nif path == nil then error("test_child: no store was handed") end\n' ..
    'assert(Store.attach(path))\n' ..
    'match pcall(require, ' .. string.format("%q", module) ..
    ') do\n  | (true, _) then\n  | (false, why) then error(why)\nend\n' ..
    'return test_child.run(' .. string.format("%q", name) .. ', select(2, ...))'
  local words: mut {string} = { "-e", chunk, path }
  for _, word in ipairs(args or {}) do words[#words + 1] = word end
  return words
end

function test_child.run(name: string, ...: string?): integer
  local body = bodies[name]
  if body == nil then
    error("test_child: no child " .. name .. " is registered; the module that registers it is loaded by the chunk", 2)
  end
  local args: mut {string} = {}
  for slot = 1, select("#", ...) do
    local word = select(slot, ...)
    if word is string then args[#args + 1] = word end
  end
  return body(args)
end

return test_child
