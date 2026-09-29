local gen_syscalls = require("build.gen_syscalls")
local analyzer = require("build.analyzer")
local teal = require("build.teal")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

local function lines(parts: {string}): string
  return table.concat(parts, "\n") .. "\n"
end

local header = lines({
  "/*",
  " * --- What `stat` reports.",
  " * ---@class Stat",
  " * ---@field size integer the size in bytes",
  " */",
  "",
  "/*",
  " * --- Opens a path and returns a descriptor.",
  " * --- The mode has umask semantics.",
  " * ---",
  " * ---@param path string the path to open",
  " * ---@param mode? integer the creation mode",
  " * ---@return integer|nil fd the descriptor, or nil on failure",
  " * ---@return string error what went wrong, when fd is nil",
  " * ---@return integer errno the error number, when fd is nil",
  " */",
  "COSMIC_SYSCALL(open, 2);",
  "",
  "/*",
  " * ---@class Constants",
  " * ---@field O_RDONLY integer open for reading",
  " */",
  "COSMIC_CONSTANT(O_RDONLY)",
})

--- The generated declaration's documented symbols, by symbol.
local function docs(): {string: analyzer.DocEntry}
  local source, trouble = gen_syscalls.declaration(header)
  assert(source ~= nil, trouble)
  local found, err = analyzer.analyze(built, source, "syscalls.d.tl")
  assert(found ~= nil, "analyze failed: " .. tostring(err))
  local by_symbol: {string: analyzer.DocEntry} = {}
  for _, entry in ipairs(found.docs) do
    by_symbol[entry.symbol] = entry
  end
  return by_symbol
end

--- `cosmic docs` answers a call with the header's own prose -- every
--- line of it, then what each parameter and result is -- rather than
--- a bare signature.
local function test_a_call_carries_its_prose()
  local open = docs()["open"]
  assert(open ~= nil, "no docs row for open")
  local want = table.concat({
    "Opens a path and returns a descriptor.",
    "The mode has umask semantics.",
    "@param path the path to open",
    "@param mode the creation mode",
    "@return fd the descriptor, or nil on failure",
    "@return error what went wrong, when fd is nil",
    "@return errno the error number, when fd is nil",
  }, "\n")
  assert(open.text == want, open.text)
end

local function test_classes_and_fields_carry_their_prose()
  local by_symbol = docs()
  assert(by_symbol["Stat"].text == "What `stat` reports.", by_symbol["Stat"].text)
  assert(by_symbol["Stat.size"].text == "the size in bytes", by_symbol["Stat.size"].text)
  assert(by_symbol["O_RDONLY"].text == "open for reading", by_symbol["O_RDONLY"].text)
  local module = by_symbol[""].text
  assert(module == "The syscall table: one C function per call, the same on Linux\n" ..
    "and on macOS.", module)
end

--- The table is documented under the name every caller gives it,
--- `local sys = require("cosmic.sys")`, so `cosmic docs sys.open` and
--- the module page say `sys.open`, as a caller writes it.
local function test_the_table_is_documented_as_sys()
  local source = assert(gen_syscalls.declaration(header))
  assert(source:find("\nlocal record sys\n", 1, true), source)
  assert(source:find("\nreturn sys\n", 1, true), source)
  assert(not source:find("record syscalls", 1, true), source)
end

--- The generated source names, for each declaration, its line in the
--- header -- what the build shows in place of the generated source's
--- own lines.
local function test_each_declaration_names_its_header_line()
  local source = assert(gen_syscalls.declaration(header))
  for _, want in ipairs({ "-- line Stat 3", "-- line Stat.size 4",
                          "-- line open 17", "-- line O_RDONLY 21" }) do
    assert(source:find("\n" .. want .. "\n", 1, true), want .. " missing from:\n" .. source)
  end
end

--- The raw process table's declaration is its own record, opened with
--- its own summary and mapped to its own header, not the syscall
--- table's.
local function test_a_target_names_its_own_record_and_header()
  local process: gen_syscalls.Target = nil
  for _, derivation in ipairs(gen_syscalls.targets) do
    if derivation.path == "cosmic.internal.process" then process = derivation.target end
  end
  assert(process ~= nil and process.header == "core/process.h", "no process target")
  local source = assert(gen_syscalls.declaration(header, process))
  assert(source:find("\nlocal record process\n", 1, true), source)
  assert(source:find("\nreturn process\n", 1, true), source)
  assert(source:find("sits in core/process.h", 1, true), source)
  assert(not source:find("syscall table", 1, true), source)
end

--- A header declaring one fallible call whose first return is `first`.
local function fallible(first: string): string
  return lines({
    "/*",
    " * --- Does a thing.",
    " * ---@return " .. first .. " ok what it made, or the failure's lead",
    " * ---@return string error what went wrong",
    " * ---@return integer errno the error number",
    " */",
    "COSMIC_SYSCALL(thing, 0);",
  })
end

--- A fallible call is an effect, failing with false, or a value,
--- failing with nil: `boolean|nil` says it is both.
local function test_a_fallible_call_is_an_effect_or_a_value()
  local _, trouble = gen_syscalls.read(fallible("boolean|nil"))
  assert(trouble ~= nil and trouble:find("never boolean|nil", 1, true), trouble)
  local _, bare = gen_syscalls.read(fallible("string"))
  assert(bare ~= nil and bare:find("fails with nil", 1, true), bare)
  assert(gen_syscalls.read(fallible("boolean")) ~= nil)
  assert(gen_syscalls.read(fallible("string|nil")) ~= nil)
end

--- The `COSMIC_CONSTANT` lines after the `Constants` block are what
--- core/syscalls.c sets the constants from, so they name its fields
--- exactly, in order: none missing, none extra, none out of place.
local function test_constants_are_held_to_their_class()
  local function with(entries: {string}): string
    local parts: {string} = {
      "/*",
      " * --- Closes a descriptor.",
      " * ---@param fd integer the descriptor",
      " * ---@return boolean ok false on failure",
      " * ---@return string error what went wrong",
      " * ---@return integer errno the error number",
      " */",
      "COSMIC_SYSCALL(close, 1);",
      "/*",
      " * ---@class Constants",
      " * ---@field A integer a",
      " * ---@field B integer b",
      " */",
    }
    for _, entry in ipairs(entries) do
      parts[#parts + 1] = entry
    end
    return lines(parts)
  end
  assert(gen_syscalls.read(with({ "COSMIC_CONSTANT(A)", "", "COSMIC_CONSTANT(B)" })))
  local record Case
    entries: {string}
    refusal: string
  end
  local cases: {Case} = {
    { entries = { "COSMIC_CONSTANT(A)" },
      refusal = "the field B has no COSMIC_CONSTANT(B)" },
    { entries = { "COSMIC_CONSTANT(B)", "COSMIC_CONSTANT(A)" },
      refusal = "the field A has no COSMIC_CONSTANT(A)" },
    { entries = { "COSMIC_CONSTANT(A)", "COSMIC_CONSTANT(B)", "COSMIC_CONSTANT(C)" },
      refusal = "COSMIC_CONSTANT(C) names no field" },
  }
  local stray = with({ "COSMIC_CONSTANT(A)", "COSMIC_CONSTANT(B)" }):gsub(
    "COSMIC_SYSCALL%(close, 1%);", "COSMIC_SYSCALL(close, 1);\nCOSMIC_CONSTANT(C)")
  local refused, refusal = gen_syscalls.read(stray)
  assert(refused == nil and refusal:find("one stands outside", 1, true), refusal)
  for _, case in ipairs(cases) do
    local read, trouble = gen_syscalls.read(with(case.entries))
    assert(read == nil and trouble:find(case.refusal, 1, true), trouble)
  end
end

--- A `userdata` class is a userdata record: its `fun(...)` fields are
--- methods, written without spaces as a field's type is one word, and
--- one named `__*` a metamethod. A class of any other parent is refused.
local function test_a_userdata_class_declares_methods_and_metamethods()
  local function with(class: string): string
    return lines({
      "/*",
      " * --- A thing that owns something.",
      " * ---@class " .. class,
      " * ---@field fd fun(self:Owner):integer what it owns",
      " * ---@field close fun(self:Owner):boolean,string,integer lets it go",
      " * ---@field __close fun(self:Owner) lets it go, quietly",
      " */",
      "",
      "/*",
      " * --- Makes one.",
      " * ---@return Owner|nil owner the one made, or nil on failure",
      " * ---@return string error what went wrong",
      " * ---@return integer errno the error number",
      " */",
      "COSMIC_SYSCALL(make, 0);",
    })
  end
  local source = assert(gen_syscalls.declaration(with("Owner: userdata")))
  for _, want in ipairs({
    "  record Owner\n    userdata\n",
    "    fd: function(self: Owner): integer\n",
    "    close: function(self: Owner): boolean, string, integer\n",
    "    metamethod __close: function(self: Owner)\n",
    "  make: function(): Owner | nil, string, integer\n",
  }) do
    assert(source:find(want, 1, true), want .. " missing from:\n" .. source)
  end
  local found, err = analyzer.analyze(built, source, "syscalls.d.tl")
  assert(found ~= nil, "analyze failed: " .. tostring(err))
  local refused, why = gen_syscalls.read(with("Owner: table"))
  assert(refused == nil and why:find("a parent other than userdata", 1, true), why)
end
