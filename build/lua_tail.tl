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

  --- `bytecode`, a chunk of the module `name` as [`bytecode_of`] made it, [`stripped`] and then given a line for
  --- each instruction, which no text decides: the `k`th instruction of the chunk, counting each function's before
  --- those of the functions it defines, is on line `ordinal_base + k`, and each function but the chunk's own is
  --- defined on the line before its first. So the chunk is the same for two versions of a module that differ in a
  --- comment, a blank line or where a function sits, as [`stripped`]'s is, and the coverage hook still sees each
  --- instruction it runs, which [`instruction_lines`] of the chunk as compiled from this text places at a source
  --- line. Nil and why where `bytecode` is not a chunk Lua loads.
  numbered: function(bytecode: string, name: string): string?, string

  --- What a line of a chunk [`numbered`] made is past: a line from `ordinal_base + 1` up is an instruction's
  --- ordinal, never a source's line, since no source holds this many.
  ordinal_base: integer

  --- The source line of each instruction of `bytecode`, a chunk of the module `name` as [`bytecode_of`] made it,
  --- in the order [`numbered`] counts them: the line its `k`th instruction is on is the `k`th entry. Nil and why
  --- where `bytecode` is not a chunk of that shape or carries no line information.
  instruction_lines: function(bytecode: string, name: string): {integer}?, string

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

LuaTail.ordinal_base = 1 << 24

--- Lua's own limits on a function's relative line information (lcode.c's `LIMLINEDIFF` and ldebug.h's `MAXIWTHABS`
--- and `ABSLINEINFO`): a step of a line as large as the first, or the instruction past the second since the last
--- absolute line, is held as an absolute line, the step's byte saying so with the third. [`numbered`] places them
--- as lcode.c's `savelineinfo` does, since ldebug.c's `getbaseline` reads a line by where they fall.
local line_step_limit <const> = 0x80
local absolute_every <const> = 128
local absolute_mark <const> = 0x80

--- A walk of the dump `dumped` of the module `name`, in the shape ldump.c writes it (the format 1 of
--- [`bytecode_header`], as [`without_lines`] reads it): read up to `at`, and what is written of it so far in
--- `parts`, `emitted` bytes in all. For [`numbered_lines`] and [`LuaTail.instruction_lines`]; a shape it does not
--- read raises `said`'s message.
local record Walk
  dumped: string
  name: string
  mut at: integer
  mut emitted: integer
  parts: mut {string}
end

local function said(walk: Walk, why: string): string
  return walk.name .. ": a chunk the core dumped in a shape the line numberer does not read: " .. why
end

local function take(walk: Walk, count: integer): string
  if count < 0 or walk.at + count - 1 > #walk.dumped then error(said(walk, "truncated"), 0) end
  local piece = walk.dumped:sub(walk.at, walk.at + count - 1)
  walk.at = walk.at + count
  return piece
end

local function put(walk: Walk, piece: string)
  walk.parts[#walk.parts + 1] = piece
  walk.emitted = walk.emitted + #piece
end

local function take_varint(walk: Walk): integer
  local value = 0
  while true do
    local byte = walk.dumped:byte(walk.at)
    if byte == nil then error(said(walk, "truncated"), 0) end
    walk.at = walk.at + 1
    value = (value << 7) | (byte & 0x7f)
    if byte < 0x80 then return value end
  end
end

--- ldump.c's `dumpVarint`: seven bits a byte, the most significant first, each byte but the last flagged.
local function varint_of(value: integer): string
  local bytes: mut {string} = { string.char(value & 0x7f) }
  value = value >> 7
  while value ~= 0 do
    table.insert(bytes, 1, string.char((value & 0x7f) | 0x80))
    value = value >> 7
  end
  return table.concat(bytes)
end

--- Skips the padding ldump.c's `dumpAlign` wrote before a vector of `size`-byte items, by where the input is.
local function skip_padding(walk: Walk, size: integer)
  walk.at = walk.at + (size - (walk.at - 1) % size) % size
end

--- Writes the padding `dumpAlign` writes before a vector of `size`-byte items, by where the output is.
local function pad(walk: Walk, size: integer)
  put(walk, string.rep("\0", (size - walk.emitted % size) % size))
end

local function take_string(walk: Walk): string
  local started = walk.at
  local size = take_varint(walk)
  if size == 0 then
    take_varint(walk)
  else
    take(walk, size)
  end
  return walk.dumped:sub(started, walk.at - 1)
end

--- The constants of a function, as they stand.
local function take_constants(walk: Walk): string
  local started = walk.at
  for _ = 1, take_varint(walk) do
    local tag = walk.dumped:byte(walk.at)
    if tag == nil then error(said(walk, "truncated"), 0) end
    take(walk, 1)
    if tag == 19 then
      take(walk, 8)
    elseif tag == 3 then
      take_varint(walk)
    elseif tag == 4 or tag == 20 then
      take_string(walk)
    elseif tag ~= 0 and tag ~= 1 and tag ~= 17 then
      error(said(walk, "a constant of tag " .. tostring(tag)), 0)
    end
  end
  return walk.dumped:sub(started, walk.at - 1)
end

--- `plain`, a chunk [`LuaTail.stripped`] wrote, with each instruction on the line of its ordinal (see
--- [`LuaTail.numbered`]).
local function numbered_lines(plain: string, name: string): string?, string
  local walk: Walk = { dumped = plain, name = name, at = 1, emitted = 0, parts = {} }
  local counted = 0
  -- Each function names the module as its source, where a stripped chunk names none, so the hook counts its lines
  -- as the module's, as it counts a chunk compiled from the text. ldump.c writes a string once and then by its index
  -- among the strings written so far (`dumpString`), so the name, written where the first function that names it
  -- ends, takes the index after the strings the chunk wrote before it, and every later index moves one up.
  local saved = 0
  local named_at = 0 -- none yet
  local function copy_string()
    local size = take_varint(walk)
    if size == 0 then
      local index = take_varint(walk)
      if named_at > 0 and index >= named_at then index = index + 1 end
      put(walk, varint_of(0) .. varint_of(index))
    else
      saved = saved + 1
      put(walk, varint_of(size) .. take(walk, size))
    end
  end
  local function name_source()
    if named_at > 0 then
      put(walk, varint_of(0) .. varint_of(named_at))
    else
      named_at = saved + 1
      local named = "@" .. walk.name
      put(walk, varint_of(#named + 1) .. named .. "\0")
    end
  end
  local function copy_constants()
    local count = take_varint(walk)
    put(walk, varint_of(count))
    for _ = 1, count do
      local tag = walk.dumped:byte(walk.at)
      if tag == nil then error(said(walk, "truncated"), 0) end
      put(walk, take(walk, 1))
      if tag == 19 then
        put(walk, take(walk, 8))
      elseif tag == 3 then
        local started = walk.at
        take_varint(walk)
        put(walk, walk.dumped:sub(started, walk.at - 1))
      elseif tag == 4 or tag == 20 then
        copy_string()
      elseif tag ~= 0 and tag ~= 1 and tag ~= 17 then
        error(said(walk, "a constant of tag " .. tostring(tag)), 0)
      end
    end
  end
  local function number(main: boolean)
    if take_varint(walk) ~= 0 or take_varint(walk) ~= 0 then
      error(said(walk, "a stripped function defined on a line"), 0)
    end
    local shape = take(walk, 3)
    local count = take_varint(walk)
    local first = counted
    counted = counted + count
    local defined = if main then 0 else LuaTail.ordinal_base + first end
    put(walk, varint_of(defined))
    put(walk, varint_of(if main then 0 else defined + count end))
    put(walk, shape)
    put(walk, varint_of(count))
    skip_padding(walk, 4)
    pad(walk, 4)
    put(walk, take(walk, count * 4))
    copy_constants()
    local upvalues = take_varint(walk)
    put(walk, varint_of(upvalues))
    put(walk, take(walk, 3 * upvalues))
    local protos = take_varint(walk)
    put(walk, varint_of(protos))
    for _ = 1, protos do number(false) end
    if take_string(walk) ~= "\0\0" then error(said(walk, "a source in a stripped chunk"), 0) end
    name_source()
    for _ = 1, 4 do
      if take_varint(walk) ~= 0 then
        error(said(walk, "debug information in a stripped chunk"), 0)
      end
    end
    -- As lcode.c's `savelineinfo` writes them, from the line the function is defined on.
    local steps: mut {string} = {}
    local absolute: mut {string} = {}
    local previous, since = defined, 0
    for pc = 0, count - 1 do
      local line = LuaTail.ordinal_base + first + pc + 1
      local step = line - previous
      local held = math.abs(step) >= line_step_limit
      if not held then
        held = since >= absolute_every
        since = since + 1
      end
      if held then
        absolute[#absolute + 1] = string.pack("<i4i4", pc, line)
        steps[#steps + 1] = string.char(absolute_mark)
        since = 1
      else
        steps[#steps + 1] = string.char(step & 0xff)
      end
      previous = line
    end
    put(walk, varint_of(count))
    put(walk, table.concat(steps))
    put(walk, varint_of(#absolute))
    if #absolute > 0 then
      pad(walk, 4)
      put(walk, table.concat(absolute))
    end
    put(walk, varint_of(0))
    put(walk, varint_of(0))
  end
  local ok, trouble = pcall(function()
    put(walk, take(walk, #bytecode_header))
    put(walk, take(walk, 1))
    number(true)
    if walk.at ~= #plain + 1 then error(said(walk, "bytes after the chunk"), 0) end
  end)
  if not ok then return nil, tostring(trouble) end
  return table.concat(walk.parts), ""
end

function LuaTail.numbered(bytecode: string, name: string): string?, string
  local plain, why = LuaTail.stripped(bytecode, name)
  if plain == nil then return nil, why end
  local numbered, trouble = numbered_lines(plain, name)
  if numbered == nil then return nil, trouble end
  -- Read back, or the writing above is not a chunk Lua loads.
  local again, again_trouble = load(numbered, "=" .. name, "b", {})
  if again == nil then return nil, name .. ": " .. tostring(again_trouble) end
  -- Without its lines it is the stripped chunk, and Lua reads the line of each instruction as its ordinal.
  local back, _ = without_lines(dump(again, true), name)
  if back ~= plain then
    return nil, name .. ": the chunk with its instructions numbered is not the chunk"
  end
  local lines, lines_trouble = LuaTail.instruction_lines(dump(again, false), name)
  if lines == nil then return nil, lines_trouble end
  for ordinal, line in ipairs(lines) do
    if line ~= LuaTail.ordinal_base + ordinal then
      return nil, name .. ": instruction " .. tostring(ordinal) .. " of the numbered chunk is on line " .. tostring(line)
    end
  end
  return numbered, ""
end

function LuaTail.instruction_lines(bytecode: string, name: string): {integer}?, string
  local walk: Walk = { dumped = bytecode, name = name, at = 1, emitted = 0, parts = {} }
  local placed: mut {integer:integer} = {}
  local counted = 0
  local function read()
    local defined = take_varint(walk)
    take_varint(walk)
    take(walk, 3)
    local count = take_varint(walk)
    local first = counted
    counted = counted + count
    skip_padding(walk, 4)
    take(walk, count * 4)
    take_constants(walk)
    take(walk, 3 * take_varint(walk))
    for _ = 1, take_varint(walk) do read() end
    take_string(walk)
    local steps = take(walk, take_varint(walk))
    if #steps ~= count then error(said(walk, "no line for each instruction"), 0) end
    local absolute: mut {integer:integer} = {}
    local held = take_varint(walk)
    if held > 0 then
      skip_padding(walk, 4)
      for _ = 1, held do
        local pc, line = string.unpack("<i4i4", take(walk, 8))
        absolute[assert(math.tointeger(pc))] = assert(math.tointeger(line))
      end
    end
    local line = defined
    for pc = 0, count - 1 do
      local step = assert(steps:byte(pc + 1), "a step for each instruction, counted above")
      if step == absolute_mark then
        local at = absolute[pc]
        if at == nil then error(said(walk, "an absolute line that is not there"), 0) end
        line = at
      else
        line = line + (if step >= 0x80 then step - 0x100 else step end)
      end
      placed[first + pc + 1] = line
    end
    for _ = 1, take_varint(walk) do
      take_string(walk)
      take_varint(walk)
      take_varint(walk)
    end
    for _ = 1, take_varint(walk) do take_string(walk) end
  end
  local ok, trouble = pcall(function()
    if not String.starts_with(bytecode, bytecode_header) then
      error(said(walk, "another header"), 0)
    end
    take(walk, #bytecode_header)
    take(walk, 1)
    read()
    if walk.at ~= #bytecode + 1 then error(said(walk, "bytes after the chunk"), 0) end
  end)
  if not ok then return nil, tostring(trouble) end
  -- Placed out of order, since a function's lines follow those of the functions it defines.
  local lines: mut {integer} = {}
  for ordinal = 1, counted do
    lines[#lines + 1] = assert(placed[ordinal], "every instruction is placed")
  end
  return lines, ""
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
