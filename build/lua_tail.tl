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
  --- information -- line numbers, local and upvalue names -- and with the line each function is defined on and ends
  --- on as 0, which `string.dump` keeps of a stripped chunk, so that what is left is what the core runs: the same for
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
  return string.dump(chunk, strip) -- checked: not_assignable
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

--- `stripped`, a dump with its debug information left out, written again with the line each function is defined
--- on and ends on (`linedefined`, `lastlinedefined`) as 0. `string.dump` keeps those two with the debug
--- information stripped, so a function that moved down the file would otherwise differ. They are varints, so the
--- code that follows may need other padding to stay aligned (ldump.c's `dumpAlign`): the whole dump is read as
--- ldump.c writes it (the format 1 of [`bytecode_header`]) and written again. Nil and why where it is not a dump
--- of that shape.
local function without_lines(dumped: string, name: string): string?, string
  local parts: mut {string} = {}
  local at, emitted = 1, 0
  local function said(why: string): string
    return name .. ": a chunk the core dumped in a shape the line normalizer does not read: " .. why
  end
  local function copy(count: integer)
    if count < 0 or at + count - 1 > #dumped then error(said("truncated"), 0) end
    local piece = dumped:sub(at, at + count - 1)
    parts[#parts + 1] = piece
    at = at + count
    emitted = emitted + count
  end
  local function varint(): integer
    local value = 0
    while true do
      local byte = dumped:byte(at)
      if byte == nil then error(said("truncated"), 0) end
      at = at + 1
      value = (value << 7) | (byte & 0x7f)
      if byte < 0x80 then return value end
    end
  end
  local function copy_varint(): integer
    local started = at
    local value = varint()
    local piece = dumped:sub(started, at - 1)
    parts[#parts + 1] = piece
    emitted = emitted + (at - started)
    return value
  end
  local function zero()
    parts[#parts + 1] = "\0"
    emitted = emitted + 1
  end
  local function copy_string()
    local size = copy_varint()
    if size == 0 then
      copy_varint()
    else
      copy(size)
    end
  end
  local function copy_function()
    varint()
    zero()
    varint()
    zero()
    copy(3)
    local code = copy_varint()
    -- The padding is written for where the code now starts.
    at = at + (4 - (at - 1) % 4) % 4
    local pad = (4 - emitted % 4) % 4
    local padding = string.rep("\0", pad)
    parts[#parts + 1] = padding
    emitted = emitted + pad
    copy(code * 4)
    for _ = 1, copy_varint() do
      local tag = dumped:byte(at)
      if tag == nil then error(said("truncated"), 0) end
      copy(1)
      if tag == 19 then
        copy(8)
      elseif tag == 3 then
        copy_varint()
      elseif tag == 4 or tag == 20 then
        copy_string()
      elseif tag ~= 0 and tag ~= 1 and tag ~= 17 then
        error(said("a constant of tag " .. tostring(tag)), 0)
      end
    end
    copy(3 * copy_varint())
    for _ = 1, copy_varint() do copy_function() end
    copy_string()
    for _ = 1, 4 do
      if copy_varint() ~= 0 then error(said("debug information in a stripped chunk"), 0) end
    end
  end
  local ok, trouble = pcall(function()
    copy(#bytecode_header)
    copy(1)
    copy_function()
    if at ~= #dumped + 1 then error(said("bytes after the chunk"), 0) end
  end)
  if not ok then return nil, tostring(trouble) end
  return table.concat(parts), ""
end

function LuaTail.stripped(bytecode: string, name: string): string?, string
  if not String.starts_with(bytecode, "\27Lua") then
    return nil, name .. ": not a binary chunk"
  end
  -- An environment of its own, which `load` asks of a binary chunk; the chunk is never run.
  local chunk, trouble = load(bytecode, "=" .. name, "b", {})
  if chunk == nil then return nil, name .. ": " .. tostring(trouble) end
  local plain, why = without_lines(dump(chunk, true), name)
  if plain == nil then return nil, why end
  -- Read back, or the writing above is not the chunk it was given.
  local again, again_trouble = load(plain, "=" .. name, "b", {})
  if again == nil then return nil, name .. ": " .. tostring(again_trouble) end
  if dump(again, true) ~= plain then
    return nil, name .. ": the chunk without its lines is not the chunk"
  end
  return plain, ""
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
