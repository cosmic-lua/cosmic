--- The environment core/surface.c builds: `print` over the syscall
--- table, a traceback where `debug` used to be, and a name the surface
--- removed saying what took its place.

local Fs = require("cosmic.fs")
local Removed = require("cosmic.removed")
local sys = require("cosmic.sys")
local errors = require("cosmic.internal.errors")

--- What `fn` printed to descriptor 1, which it was pointed at a file of
--- `tmp` for, and restored after.
local function printed(tmp: string, fn: function()): string
  local path = tmp .. "/printed"
  local file = assert(sys.open(path, sys.O_CREAT | sys.O_WRONLY | sys.O_TRUNC, 420))
  local saved = assert(sys.dup(1))
  assert(sys.dup2(file, 1))
  local ok = pcall(fn)
  assert(sys.dup2(saved, 1))
  sys.close(saved)
  sys.close(file)
  assert(ok, "the printing raised")
  return (assert(Fs.read(path)))
end

--- One line longer than a `luaL_Buffer` holds inline (1 KB on a 64-bit
--- build), from arguments whose text only exists once `print` converts
--- them: the path that once freed the buffer out from under itself. A
--- core built with Lua's API checks or AddressSanitizer fails here.
local function test_print_carries_a_line_past_the_inline_buffer(tmp: string)
  local long = string.rep(".", 1100)
  local shown = setmetatable({}, {
    __tostring = function(): string return "(a value that prints itself)" end,
  })
  local text = printed(tmp, function()
    print("surface_test: a long print ->", 42, shown, long, true, nil)
  end)
  assert(text == "surface_test: a long print ->\t42\t(a value that prints itself)\t" .. long ..
      "\ttrue\tnil\n", text)
end

local function test_print_with_nothing_writes_an_empty_line(tmp: string)
  assert(printed(tmp, function() print() end) == "\n")
end

local function test_trace_names_the_message_and_the_stack()
  local trace = errors.trace("where it went wrong")
  assert(trace:find("where it went wrong", 1, true) == 1)
  assert(trace:find("stack traceback:", 1, true) ~= nil)
  assert(errors.trace():find("stack traceback:", 1, true) == 1)
end

--- The error a chunk of plain Lua raises, compiled past the checker by
--- `load` the way any Lua a program is handed would be.
local function raised(code: string): string
  local chunk = assert(load(code, "=plain.lua", "t"))
  local ok, trouble = pcall(chunk)
  assert(not ok, "expected " .. code .. " to raise")
  return tostring(trouble)
end

--- A removed library's field says what replaced that very field, at the
--- line that reached for it, in the words a refused compile uses too
--- ([`cosmic.removed`]'s `message`).
local function test_a_removed_field_says_what_replaced_it()
  local trouble = raised('return os.getenv("HOME")')
  assert(trouble == "plain.lua:1: " .. Removed.message("os", "getenv"), trouble)
  assert(trouble:find('use Env.get(name) (local Env = require("cosmic.env"))', 1, true) ~= nil,
    trouble)
  trouble = raised('io.stderr:write("x")')
  assert(trouble:find("Fs.put(Fs.stderr, text)", 1, true) ~= nil, trouble)
  trouble = raised("return debug.traceback()")
  assert(trouble:find("Errors.trace(message, level)", 1, true) ~= nil, trouble)
  trouble = raised("return os.frobnicate")
  assert(trouble:find("os.frobnicate is not available: time is cosmic.time", 1, true) ~= nil,
    trouble)
end

local function test_writing_or_calling_a_removed_library_says_what_replaced_it()
  local trouble = raised("os.exit = nil")
  assert(trouble:find("os.exit is not available: use Proc.exit(status)", 1, true) ~= nil,
    trouble)
  trouble = raised("io()")
  assert(trouble == "plain.lua:1: " .. Removed.message("io"), trouble)
  trouble = raised("return io[1]")
  assert(trouble == "plain.lua:1: " .. Removed.message("io"), trouble)
end

--- A removed function raises the moment it is read; nothing is left to
--- call it with.
local function test_a_removed_function_says_what_replaced_it()
  for name, replacement in pairs({ dofile = "require", loadfile = "require" }) do
    local trouble = raised("return " .. name)
    assert(trouble == "plain.lua:1: " .. Removed.message(name), trouble)
    assert(trouble:find(replacement, 1, true) ~= nil,
      name .. "'s refusal must name " .. replacement)
  end
end

--- The fields of `package` that are gone raise what replaced them,
--- read or written, rather than yielding a nil that fails somewhere
--- else; the fields that remain are untouched.
local function test_a_removed_package_field_says_what_replaced_it()
  for _, field in ipairs(Removed.package_fields) do
    local expected = "plain.lua:1: " .. Removed.message("package", field)
    local trouble = raised("return package." .. field)
    assert(trouble == expected, trouble)
    trouble = raised("package." .. field .. " = 'x'")
    assert(trouble == expected, trouble)
  end
  local trouble = raised('return package.path .. "x"')
  assert(trouble:find("there is no file search path", 1, true) ~= nil, trouble)
  assert(package.loaded ~= nil and package.preload ~= nil and package.searchers ~= nil)
  assert(package.config ~= nil)
  local other = assert(load("package.frobnicate = 1\nlocal seen = package.frobnicate\n" ..
      "package.frobnicate = nil\nreturn seen, package.frobnicate", "=other.lua", "t"))
  local seen, gone = other() as (integer, any)
  assert(seen == 1 and gone == nil)
end

--- A `require` of a removed library says what replaced it, as the
--- checker's `module not found` does.
local function test_requiring_a_removed_library_says_what_replaced_it()
  for _, name in ipairs({ "io", "os", "debug" }) do
    local trouble = raised("return require('" .. name .. "')")
    assert(trouble:find("no module '" .. name .. "' in the store", 1, true) ~= nil, trouble)
    assert(trouble:find(Removed.message(name), 1, true) ~= nil, trouble)
  end
  local trouble = raised("return require('not_a_removed_library')")
  assert(trouble:find("is not available", 1, true) == nil, trouble)
end

local function test_a_name_that_never_existed_is_nil()
  local globals = _G as {string: any}
  assert(globals["cosmic_surface_test_never_defined"] == nil)
end

--- The state's allocator keeps freed big blocks for reuse. A buffer
--- that grows through its sizes moves between them, and one that ends
--- shorter than it grew shrinks: every string made that way, and every
--- one made after its blocks were freed and handed out again, holds
--- exactly its own bytes.
local function test_big_strings_keep_their_bytes_through_reused_blocks()
  local sizes = { 30000, 33000, 40960, 40961, 65536, 65537, 100000, 1 << 20,
    (2 << 20) - 1, 2 << 20, (2 << 20) + 1, 3 << 20 }
  for round = 1, 3 do
    local made: {string} = {}
    for index, size in ipairs(sizes) do
      local byte = string.char(65 + (index + round) % 26)
      local pieces: {string} = {}
      for i = 1, size // 1000 do pieces[i] = string.rep(byte, 1000) end
      pieces[#pieces + 1] = string.rep(byte, size % 1000)
      local joined = table.concat(pieces)
      local repeated = string.rep(byte, size)
      assert(#joined == size and joined == repeated, "size " .. size)
      made[index] = joined:sub(2) .. "!"
    end
    collectgarbage("collect")
    for index, size in ipairs(sizes) do
      local byte = string.char(65 + (index + round) % 26)
      assert(made[index] == string.rep(byte, size - 1) .. "!", "size " .. size)
    end
  end
end

--- A coroutine that raised keeps its stack until it is closed: the
--- trace of it names the function that raised, under the message.
local function test_trace_of_a_coroutine_that_raised_names_where()
  local function deepest()
    error("raised in the coroutine", 0)
  end
  local co = coroutine.create(function() deepest() end)
  local resumed, err = coroutine.resume(co)
  assert(not resumed and err == "raised in the coroutine", tostring(err))
  local trace = errors.trace_of(co, "it raised")
  assert(trace:find("it raised\nstack traceback:", 1, true) == 1, trace)
  assert(trace:find("deepest", 1, true) ~= nil, trace)
  assert(errors.trace_of(co):find("stack traceback:", 1, true) == 1)
  local own = errors.trace_of((coroutine.running()))
  assert(own:find("stack traceback:\n\t[C]", 1, true) == nil, own)
end
