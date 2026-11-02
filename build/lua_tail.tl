--- What is done to the Lua of a module after the code generator has written it: the tail of a test module
--- that hands its tests to the runner, and the bytecode of the chunk, which every target must read alike. Used by
--- [`build.pipeline`], which the code generator feeds.
local String = require("cosmic.string")

local record LuaTail
  --- `code`, the Lua of a test module, with a generated `return` of the functions `tests` names appended, so a `local
  --- function test_*` -- otherwise unreachable from outside the file it is declared in -- comes back on the table `require`
  --- gives the runner. The Teal source the test's author wrote is never touched; only the compiled Lua this module already
  --- owns is. `code` itself where `tests` is empty.
  with_test_tail: function(code: string, tests: {string}): string

  --- The bytecode of `code` (compiled from the module `name`, whose source is `file`), checked to be the shape every target
  --- shares; nil and why where Lua refuses the chunk, said at the line of `file` it is on, or the host dumps another shape.
  bytecode_of: function(code: string, name: string, file: string): string?, string

  --- `bytecode`, a chunk of the module `name` as [`bytecode_of`] made it, written again without its debug
  --- information -- line numbers, local and upvalue names -- so that what is left is what the core runs: the same for
  --- two versions of a module that differ in a comment, a blank line or where a function sits. Nil and why where
  --- `bytecode` is not a chunk Lua loads.
  stripped: function(bytecode: string, name: string): string?, string

  --- Whether `code` compiles with `spare` locals declared in front of it, and where it does not, Lua's words: "too many local
  --- variables" where the locals are past 200 (a function may hold that many), and another message for anything else, such
  --- as a chunk that needs too many registers, which the locals in front can cause and are no count of locals. The chunk is
  --- compiled and dropped, never run ([`build.main_locals`] searches for the greatest `spare` that fits).
  fits_with: function(code: string, spare: integer): boolean, string
end

--- `string.dump` of `chunk`, which `load` makes: the one place the vararg return of that type meets the single one
--- `string.dump` declares.
local function dump(chunk: function(...: any): any..., strip: boolean): string
  return string.dump(chunk, strip)
end

--- The bytecode header every target must agree on. One column of
--- bytecode serves all three because they are all little-endian and
--- 64-bit; this is what says so out loud, so a target whose sizes or
--- byte order differ fails the build rather than a launch.
---
--- The bytes are the signature, the version and format, the data check,
--- and the size and value of an int, an instruction, an integer and a
--- number. The format is 1: patch/lua/ adds the instructions of the class
--- form to the official format 0.
local bytecode_header =
  "\27LuaU\1\25\147\13\10\26\10" ..
  "\4\136\169\255\255" ..
  "\4\120\86\52\18" ..
  "\8\136\169\255\255\255\255\255\255" ..
  "\8\0\0\0\0\0\40\119\192"

function LuaTail.with_test_tail(code: string, tests: {string}): string
  if #tests == 0 then
    return code
  end
  local fields: mut {string} = {}
  for _, name in ipairs(tests) do
    fields[#fields + 1] = name .. " = " .. name
  end
  return code .. "\nreturn { " .. table.concat(fields, ", ") .. " }\n"
end

--- Lua's refusal of the chunk compiled from `file`, said at `file`'s
--- line rather than at the chunk's name. Both compilers write each
--- statement on its source's line, adding lines only to reach one, so
--- the chunk's line is the line of the Teal.
local function at_source_line(trouble: string, file: string): string
  local line, said = trouble:match("^.-:(%d+): (.*)$")
  if line == nil then
    return file .. ": " .. trouble
  end
  assert(said ~= nil, "a match sets every capture")
  return file .. ":" .. line .. ": " .. said
end

function LuaTail.bytecode_of(code: string, name: string, file: string): string?, string
  local chunk, load_trouble = load(code, "@" .. name, "t")
  if chunk == nil then
    -- TODO: tl's checker passes what Lua 5.5 refuses only here:
    -- `global`, which Lua reserves, as a local, parameter, field or
    -- method name; a `goto` into a local's scope; and `function f()`
    -- over a `<const>` local or a for loop's control variable. The
    -- generator would write a key named `global` as `["global"]`, and
    -- the checker refuse the rest, as it does an assignment.
    return nil, at_source_line(tostring(load_trouble), file)
  end
  local bytecode = dump(chunk, false)
  if not String.starts_with(bytecode, bytecode_header) then
    return nil, file .. ": this host dumps bytecode the three " ..
      "targets do not share"
  end
  return bytecode, ""
end

function LuaTail.stripped(bytecode: string, name: string): string?, string
  if not String.starts_with(bytecode, "\27Lua") then
    return nil, name .. ": not a binary chunk"
  end
  -- An environment of its own, which `load` asks of a binary chunk; the chunk is never run.
  local chunk, trouble = load(bytecode, "=" .. name, "b", {})
  if chunk == nil then return nil, name .. ": " .. tostring(trouble) end
  return dump(chunk, true), ""
end

function LuaTail.fits_with(code: string, spare: integer): boolean, string
  local names: mut {string} = {}
  for index = 1, spare do
    names[index] = "__l" .. tostring(index)
  end
  local front = if spare > 0 then "local " .. table.concat(names, ",") .. " " else "" end
  local chunk, trouble = load(front .. code, "=fits_with", "t")
  if chunk == nil then
    return false, tostring(trouble)
  end
  return true, ""
end

return LuaTail
