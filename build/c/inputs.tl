--- What a compile of one C file reads, as a key: the file, every header it could include and the command that compiles
--- it ([`build.c`] keeps what it made of a compile's syntax tree under it, so a file whose inputs have not changed is
--- not compiled again).
---
--- The tree clang prints is a function of the translation unit the preprocessor makes and the target, and that of the
--- text of the file, the text of each header it includes and the command's defines. The key holds the file and every
--- header the file could include, along any branch of a conditional: the headers of `dirs` and the file's own directory
--- are found as the compiler finds them (a quoted name beside the including file first, then each directory in order),
--- by the text of each `#include`, and each is held by the hash of its bytes and the path it was found at, so a header
--- added ahead of another in the search order changes the key. A header found nowhere is the compiler's own, by the pinned
--- zig's install, which the key's caller names, and is held by its name.
---
--- An include through a macro names every string the macro is defined as anywhere in the headers read and in the command
--- (a macro defined nowhere there names none: only the compiler's own macros come from elsewhere, and none of them is
--- included). A `__has_include` of a name is held by where the name is found.
---
--- The key is nil, so that the file is compiled, where its includes cannot be read from text: a macro that is defined
--- as more than a string or another macro and is included, `include_next`, `import`, a `__has_include` that is not of a
--- literal name, a digraph or a trigraph, a comment between the `#` and the directive, a header that cannot be read, or
--- the date and time macros.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")

local record inputs
  --- What a run keeps of each header it has read: shared by the keys of one run, which have the same `dirs`.
  record Reader
    dirs: {string}
    --- What the command defines, as [`Header.defines`] lists a header's.
    defined: {inputs.Define}
    held: {string: Header}
  end

  --- A macro defined as `text` of a `kind`: a string or a name between `"` or `<>`, another macro (`alias`), or anything
  --- else (`other`), which a file that includes through the macro cannot be keyed for.
  record Define
    name: string
    kind: string
    text: string
  end

  --- What one header says: the hash of its bytes, the places it could include, or why they cannot be known.
  record Header
    hash: string
    --- The paths of the headers it includes that are found, and the names of those that are not.
    found: {string}
    system: {string}
    --- The macros it includes through, and what it defines.
    macros: {string}
    defines: {inputs.Define}
    --- The names it asks `__has_include` about, as written: `<name>` or `"name"`.
    probes: {string}
    unreadable: boolean
  end

  --- A string a macro can be, with whether it was written `"` or `<>`.
  record Target
    quoted: boolean
    text: string
  end

  --- A macro a header includes through, and the header.
  record Pending
    path: string
    macro: string
  end

  --- A reader of headers searched through `dirs` (absolute paths), for the compiler `command`.
  reader: function(dirs: {string}, command: {string}): inputs.Reader
  --- The key for compiling `file` (an absolute path) with `command` under `install`, the zig the compiler runs from; nil
  --- where it cannot be known.
  key: function(reader: inputs.Reader, file: string, command: {string}, install: string): string | nil
end

--- How a macro's text is defined, as a [`Define`] says.
local function definition(name: string, text: string): inputs.Define
  local trimmed = text:gsub("^%s+", "")
  local quoted = trimmed:match('^"([^"]*)"%s*$') or trimmed:match('^"([^"]*)"%s*//') or trimmed:match('^"([^"]*)"%s*/%*')
  if quoted ~= nil then
    return { name = name, kind = "string", text = quoted }
  end
  local angled = trimmed:match("^<([^>]*)>%s*$") or trimmed:match("^<([^>]*)>%s*//") or trimmed:match("^<([^>]*)>%s*/%*")
  if angled ~= nil then
    return { name = name, kind = "angle", text = angled }
  end
  local alias = trimmed:match("^([%a_][%w_]*)%s*$") or trimmed:match("^([%a_][%w_]*)%s*//") or trimmed:match("^([%a_][%w_]*)%s*/%*")
  if alias ~= nil then
    return { name = name, kind = "alias", text = alias }
  end
  return { name = name, kind = "other", text = trimmed }
end

function inputs.reader(dirs: {string}, command: {string}): inputs.Reader
  local defined: {inputs.Define} = {}
  for _, argument in ipairs(command) do
    local name, text = argument:match("^%-D([%a_][%w_]*)=(.*)$")
    if name ~= nil and text ~= nil then
      defined[#defined + 1] = definition(name, text)
    else
      local bare = argument:match("^%-D([%a_][%w_]*)$")
      if bare ~= nil then
        defined[#defined + 1] = { name = bare, kind = "other", text = "1" }
      end
    end
  end
  return { dirs = dirs, defined = defined, held = {} }
end

--- Text that makes a file's includes unreadable from its text, apart from the directives [`header_of`] reads.
local function opaque(text: string): boolean
  return text:find("%:", 1, true) ~= nil or (text:find("??", 1, true) ~= nil and text:find("%?%?[=/'()!<>%-]") ~= nil) or
    text:find("__DATE__", 1, true) ~= nil or text:find("__TIME__", 1, true) ~= nil or
    text:find("__TIMESTAMP__", 1, true) ~= nil
end

--- Whether the file or directory `path` is there.
local function present(path: string): boolean
  local there, _ = Fs.exists(path)
  return there == true
end

--- The path `name` names for an include of the file at `from`, as the compiler finds it: `quoted` names are looked for
--- beside the includer first. Nil where no directory holds it.
local function resolved(reader: inputs.Reader, from: string, name: string, quoted: boolean): string | nil
  if name:sub(1, 1) == "/" then
    if present(name) then
      return name
    end
    return nil
  end
  if quoted then
    local beside = Fs.dirname(from) .. "/" .. name
    if present(beside) then
      return beside
    end
  end
  for _, dir in ipairs(reader.dirs) do
    local path = dir .. "/" .. name
    if present(path) then
      return path
    end
  end
  return nil
end

--- How many times `text` holds `word` as written.
local function count_of(text: string, word: string): integer
  local n, from = 0, 1
  while true do
    local at = text:find(word, from, true)
    if at == nil then
      return n
    end
    n = n + 1
    from = at + #word
  end
end

--- A header whose includes are not read.
local function unreadable_header(): inputs.Header
  return { hash = "", found = {}, system = {}, macros = {}, defines = {}, probes = {}, unreadable = true }
end

--- What the header at `path` says, made afresh.
local function read_header(reader: inputs.Reader, path: string): inputs.Header
  local text, _ = Fs.read(path)
  if text == nil or opaque(text) then
    return unreadable_header()
  end
  local found: {string} = {}
  local system: {string} = {}
  local macros: {string} = {}
  local defines: {inputs.Define} = {}
  local probes: {string} = {}
  -- A directive continued on the next line is one line.
  local joined = text
  if text:find("\\\n", 1, true) ~= nil or text:find("\\\r", 1, true) ~= nil then
    joined = text:gsub("\\\r?\n", "")
  end
  -- Each `#` of the text, wherever it is: a directive, or a word of a comment or a string, which can only add to what is read.
  local from = 1
  while true do
    local hash = joined:find("#", from, true)
    if hash == nil then
      break
    end
    from = hash + 1
    local word, after = joined:match("^[ \t]*([%a_]*)()", from)
    if word == "" then
      if joined:find("^[ \t]*/[/*]", from) ~= nil then
        return unreadable_header()
      end
    elseif word == "include_next" or word == "import" then
      return unreadable_header()
    elseif word == "include" then
      local line = joined:match("^[ \t]*([^\n]*)", after) or ""
      local name: string | nil
      local quoted = false
      local first = line:sub(1, 1)
      local through = false
      if first == '"' then
        name = line:match('^"([^"]*)"')
        quoted = true
      elseif first == "<" then
        name = line:match("^<([^>]*)>")
      else
        -- An include through a macro: the macro's name, or nothing where the line is not one (a word of a comment).
        through = true
        local macro = line:match("^([%a_][%w_]*)")
        if macro ~= nil then
          if line:sub(#macro + 1, #macro + 1) == "(" then
            return unreadable_header()
          end
          macros[#macros + 1] = macro
        end
      end
      if not through then
        if name == nil or name == "" then
          return unreadable_header()
        end
        local at = resolved(reader, path, name, quoted)
        if at ~= nil then
          found[#found + 1] = at
        else
          system[#system + 1] = name
        end
      end
    elseif word == "define" then
      local name, rest = joined:match("^[ \t]+([%a_][%w_]*)([^\n]*)", after)
      if name ~= nil and rest ~= nil then
        if rest:sub(1, 1) == "(" then
          defines[#defines + 1] = { name = name, kind = "other", text = "" }
        else
          defines[#defines + 1] = definition(name, rest)
        end
      end
    end
  end
  if joined:find("__has_include", 1, true) ~= nil then
    -- Where `__has_include` is asked of a literal name, directly or through a macro that wraps it, the names; any other use
    -- is not read. Asking whether the compiler has it at all is the pinned compiler's answer.
    local wrappers: {string: boolean} = { __has_include = true }
    local wrapper_defines = 0
    for wrapper in joined:gmatch("#%s*define%s+([%a_][%w_]*)%s*%(%s*[%a_][%w_]*%s*%)%s*__has_include%s*%(%s*[%a_][%w_]*%s*%)") do
      wrappers[wrapper] = true
      wrapper_defines = wrapper_defines + 1
    end
    local asked = 0
    for wrapper in pairs(wrappers) do
      for open, written in joined:gmatch("[^%w_]" .. wrapper .. "%s*%(%s*([<\"])([^>\"\n]*)[>\"]%s*%)") do
        probes[#probes + 1] = open .. (written or "")
        if wrapper == "__has_include" then
          asked = asked + 1
        end
      end
    end
    local tested = 0
    for _ in joined:gmatch("defined%s*%(?%s*__has_include%s*%)?") do tested = tested + 1 end
    for _ in joined:gmatch("#%s*ifn?def%s+__has_include") do tested = tested + 1 end
    if count_of(joined, "__has_include") ~= asked + wrapper_defines + tested then
      return unreadable_header()
    end
  end
  return { hash = Hash.hex_sha256(text), found = found, system = system, macros = macros, defines = defines,
    probes = probes, unreadable = false }
end

--- What the header at `path` says, read once.
local function header_of(reader: inputs.Reader, path: string): inputs.Header
  local kept = reader.held[path]
  if kept ~= nil then
    return kept
  end
  local header = read_header(reader, path)
  reader.held[path] = header
  return header
end

--- The strings the macro `name` can be, as the strings it is defined as in `defines` with whether each was written `"`,
--- following the macros it is defined as; nil where one definition is neither, or the chain is long.
local function targets_of(defines: {string: {inputs.Define}}, name: string, depth: integer): {inputs.Target} | nil
  if depth > 8 then
    return nil
  end
  local out: {inputs.Target} = {}
  for _, d in ipairs(defines[name] or {}) do
    if d.kind == "string" or d.kind == "angle" then
      out[#out + 1] = { quoted = d.kind == "string", text = d.text }
    elseif d.kind == "alias" then
      local through = targets_of(defines, d.text, depth + 1)
      if through == nil then
        return nil
      end
      for _, t in ipairs(through) do
        out[#out + 1] = t
      end
    else
      return nil
    end
  end
  return out
end

function inputs.key(reader: inputs.Reader, file: string, command: {string}, install: string): string | nil
  local entries: {string} = {}
  local seen: {string: boolean} = {}
  local stack: {string} = { file }
  seen[file] = true
  local defines: {string: {inputs.Define}} = {}
  local function define(d: inputs.Define)
    local list = defines[d.name]
    if list == nil then
      list = {}
      defines[d.name] = list
    end
    list[#list + 1] = d
  end
  for _, d in ipairs(reader.defined) do
    define(d)
  end
  -- The macros included through, by the file that includes through them.
  local pending: {inputs.Pending} = {}
  local pending_seen: {string: boolean} = {}
  while true do
    while #stack > 0 do
      local path = table.remove(stack) or file
      local header = header_of(reader, path)
      if header.unreadable then
        return nil
      end
      entries[#entries + 1] = path .. "=" .. header.hash
      for _, name in ipairs(header.system) do
        if seen["<" .. name] == nil then
          seen["<" .. name] = true
          entries[#entries + 1] = "<" .. name
        end
      end
      for _, d in ipairs(header.defines) do
        define(d)
      end
      for _, written in ipairs(header.probes) do
        local at = resolved(reader, path, written:sub(2), written:sub(1, 1) == '"')
        local mark = "has " .. written .. "=" .. (at or "-")
        if seen[mark] == nil then
          seen[mark] = true
          entries[#entries + 1] = mark
        end
      end
      for _, macro in ipairs(header.macros) do
        local id = path .. "\0" .. macro
        if pending_seen[id] == nil then
          pending_seen[id] = true
          pending[#pending + 1] = { path = path, macro = macro }
        end
      end
      for _, next_path in ipairs(header.found) do
        if seen[next_path] == nil then
          seen[next_path] = true
          stack[#stack + 1] = next_path
        end
      end
    end
    -- Each macro included through names what the headers read define it as so far; a definition read later is found in
    -- the next round.
    local grew = false
    local marks: {string} = {}
    for _, entry in ipairs(pending) do
      local from, macro = entry.path, entry.macro
      local targets = targets_of(defines, macro, 0)
      if targets == nil then
        return nil
      end
      -- A macro defined nowhere (a word of a comment, a branch that is not taken) names no header.
      local mark = from .. " macro " .. macro .. "="
      for _, t in ipairs(targets) do
        local at = resolved(reader, from, t.text, t.quoted)
        mark = mark .. (t.quoted and '"' or "<") .. t.text .. ">" .. (at or "-") .. ";"
        if at ~= nil and seen[at] == nil then
          seen[at] = true
          stack[#stack + 1] = at
          grew = true
        end
      end
      marks[#marks + 1] = mark
    end
    -- What a header found now defines can change what a macro names, so the marks are those of a round that found none.
    if not grew then
      for _, mark in ipairs(marks) do
        entries[#entries + 1] = mark
      end
      break
    end
  end
  table.sort(entries, function(a: string, b: string): boolean return a < b end)
  return Hash.hex_sha256("c inputs 2\0" .. install .. "\0" .. table.concat(command, "\0") .. "\0" ..
      table.concat(entries, "\0"))
end

return inputs
