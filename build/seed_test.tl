--- The seed list ([`build/seed.txt`]): the files the pinned release compiles into the seed of the tool, held to the
--- files [`build/seed.tl`] really requires. A file the entry reaches that the list lacks fails a boot at its first
--- `require`, and a file the list carries that nothing reaches is compiled by every boot for nothing.

--- It sees what the parser records: a literal `require("x")` anywhere in a file. A `require(name)` of a computed name, or one
--- under `pcall`, is not seen, and a module given as both `x.d.tl` and `x.tl` is refused where [`Seed.program`] reads it, as a build
--- refuses one; none is in the closure.

local Fs = require("cosmic.fs")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Seed = require("build.seed")
local Test = require("cosmic.test")

Test.policy{ grants = {
  { path = "build/", letters = "r" },
  { path = "lang/", letters = "r" },
  { path = "cosmic/", letters = "r" },
} }

local ENTRY <const> = "build/seed.tl"

--- The files of the seed list, in order.
local function listed(): {string}
  local text = assert(Fs.read("build/seed.txt"))
  local out: mut {string} = {}
  for line in text:gmatch("[^\n]+") do
    out[#out + 1] = line
  end
  return out
end

--- The modules a file requires, as the pipeline reads it.
local function requires_of(file: string): {string}
  local text = assert(Fs.read(file))
  local parsed = Parser.parse(Lexer.lex(text, file), file, "tl")
  local out: mut {string} = {}
  for _, r in ipairs(parsed.chunk.requires) do
    out[#out + 1] = r.module
  end
  return out
end

--- The `.tl` file of the module `module`, nil for one that has none: a binding of C, or a declaration file.
local function file_of(module: string): string?
  local stem = module:gsub("%.", "/")
  for _, file in ipairs({ stem .. ".tl", stem .. "/init.tl" }) do
    if Fs.read(file) ~= nil then
      return file
    end
  end
  return nil
end

--- Every file the entry requires, itself included, by file.
local function closure(): {string: boolean}
  local seen: mut {string: boolean} = { [ENTRY] = true }
  local files: mut {string} = { ENTRY }
  for _, file in ipairs(files) do
    for _, module in ipairs(requires_of(file)) do
      local found = file_of(module)
      if found ~= nil and seen[found] ~= true then
        seen[found] = true
        files[#files + 1] = found
      end
    end
  end
  return seen
end

local function test_the_seed_list_is_the_require_closure_of_the_entry()
  local wanted = closure()
  local held: mut {string: boolean} = {}
  for _, file in ipairs(listed()) do
    held[file] = true
  end
  local said = ""
  for file, _ in pairs(wanted) do
    if held[file] ~= true then
      said = said .. " lacks " .. file
    end
  end
  for file, _ in pairs(held) do
    if wanted[file] ~= true then
      said = said .. " lists " .. file .. ", which " .. ENTRY .. " does not reach,"
    end
  end
  assert(said == "", "build/seed.txt" .. said .. ": write the closure of " .. ENTRY .. ", one file a line, in byte order")
end

local function test_the_seed_list_is_in_byte_order_with_one_file_a_line()
  local held = listed()
  for i = 2, #held do
    local before, file = assert(held[i - 1]), assert(held[i])
    assert(before < file, file .. " is out of order or listed twice, after " .. before)
  end
end

--- The seed names each output by the file's basename, so two files of one name would be one output.
local function test_no_two_files_of_the_seed_share_a_basename()
  local seen: mut {string: string} = {}
  for _, file in ipairs(listed()) do
    assert(file:match("%.tl$") ~= nil and file:match("%.d%.tl$") == nil, file .. " is no .tl source")
    local base = file:match("([^/]*)%.tl$") or file
    local before = seen[base]
    assert(before == nil, file .. " and " .. tostring(before) .. " are both written as " .. base .. ".lua")
    seen[base] = file
  end
end

--- The seed holds no part of the fork's checker, which the tree no longer has.
local function test_the_seed_holds_nothing_of_the_fork()
  for _, file in ipairs(listed()) do
    assert(file:find("^checker/") == nil, file .. " is the fork's")
    for _, module in ipairs(requires_of(file)) do
      assert(module:find("^build%.teal") == nil and module:find("^checker%.") == nil, file .. " requires the fork's " .. module)
    end
  end
end

--- A tree of its own with the declarations of the standard library and a module given as both `.d.tl` and `.tl`, a module
--- given as a declaration alone and one as a source alone.
local function seeded(tmp: string): Seed.Program
  assert(Fs.mkdirs(tmp .. "/lang"))
  for _, file in ipairs({ "lang/prelude.d.tl", "lang/stdlib.d.tl" }) do
    assert(Fs.write(tmp .. "/" .. file, (assert(Fs.read(file)))))
  end
  assert(Fs.write(tmp .. "/both.d.tl", "local record R\nend\nreturn R\n"))
  assert(Fs.write(tmp .. "/both.tl", "local record R\nend\nreturn {} as R\n"))
  assert(Fs.write(tmp .. "/alone.d.tl", "local record R\nend\nreturn R\n"))
  assert(Fs.write(tmp .. "/code.tl", "local n: integer = 1\nreturn n\n"))
  return Seed.program(tmp, {})
end

--- The seed refuses a module with a declaration and a source, with the words a build uses, where it would have taken the
--- declaration and gone on; a declaration alone has no Lua and a source alone has.
local function test_the_seed_refuses_a_declaration_beside_a_source(tmp: string)
  local program = seeded(tmp)
  local module, why = program.module("both")
  assert(module == nil and why == "both.d.tl: both.tl is already the module both. A .d.tl is only for a module " ..
      "implemented in C, and the .tl is what is checked, so one module cannot have both. If the .tl is the module, " ..
      "delete both.d.tl; if they are different modules, rename one of them.", tostring(why))
  local declared, declared_why = program.module("alone")
  assert(declared == nil and declared_why == "", tostring(declared_why))
  local code, code_why = program.module("code")
  assert(code ~= nil and code_why == "" and code.file == "code.tl")
end
