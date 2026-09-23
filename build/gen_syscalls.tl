--- The declaration of the syscall table, derived from its header.
---
--- `core/syscalls.h` carries one annotation block per call, in the
--- LuaCATS grammar, followed by the macro that names it. This turns
--- those blocks into the Teal record the rest of the tree checks
--- against, with each block's prose as the doc comment `cosmic docs`
--- shows, and refuses a call whose block is missing a slot, so a
--- binding cannot exist without its type.

local record Parameter
  name: string
  kind: string
  optional: boolean
  description: string
end

local record Result
  kind: string
  name: string
  description: string
end

local record Call
  name: string
  summary: string
  --- Every prose line of the block, in order: the summary is the first.
  prose: {string}
  parameters: {Parameter}
  results: {Result}
end

local record Field
  name: string
  kind: string
  description: string
end

local record Class
  name: string
  summary: string
  prose: {string}
  fields: {Field}
end

--- Everything one read of the header found: two lists, together, so a
--- fallible read stays two slots -- the pair, and an error -- rather
--- than smuggling a third.
local record Declarations
  calls: {Call}
  classes: {Class}
end

local record generator
  Parameter: Parameter
  Result: Result
  Call: Call
  Field: Field
  Class: Class
  Declarations: Declarations
end

--- Turns a LuaCATS type into a Teal one. The two agree on everything
--- this header uses except the spelling of a union.
local function teal_type(text: string): string
  local parts: {string} = {}
  for piece in text:gmatch("[^|]+") do
    parts[#parts + 1] = piece
  end
  return table.concat(parts, " | ")
end

--- The annotation lines of a block comment, with the comment's own
--- decoration removed. Returns nil when the comment is not one.
local function annotation_lines(comment: string): {string} | nil
  local lines: {string} = {}
  for line in (comment .. "\n"):gmatch("([^\n]*)\n") do
    local text = line:match("^%s*%*?%s?(.*)$") or line
    text = text:gsub("%s+$", "")
    if text:sub(1, 3) == "---" then
      lines[#lines + 1] = text:sub(4)
    end
  end
  if #lines == 0 then
    return nil
  end
  return lines
end

--- `lines` without the blank lines at either end.
local function trimmed(lines: {string}): {string}
  local first, last = 1, #lines
  while first <= last and lines[first] == "" do
    first = first + 1
  end
  while last >= first and lines[last] == "" do
    last = last - 1
  end
  return table.move(lines, first, last, 1, {})
end

local function parse_call(name: string, lines: {string}): Call | nil, string
  local call: Call = {
    name = name,
    summary = "",
    prose = {},
    parameters = {},
    results = {},
  }
  for _, line in ipairs(lines) do
    local tag, rest = line:match("^@(%a+)%s+(.*)$")
    if tag == "param" then
      local pname, kind, description = rest:match("^([%w_]+)(%??)%s+(.*)$")
      local optional = false
      if pname == nil then
        return nil, name .. ": a @param line names no parameter"
      end
      if kind == "?" then
        optional = true
      end
      local ptype, pdescription = description:match("^(%S+)%s*(.*)$")
      if ptype == nil then
        return nil, name .. ": parameter '" .. pname .. "' has no type"
      end
      call.parameters[#call.parameters + 1] = {
        name = pname,
        kind = teal_type(ptype),
        optional = optional,
        description = pdescription,
      }
    elseif tag == "return" then
      local kind, rname, description = rest:match("^(%S+)%s+([%w_]+)%s*(.*)$")
      if kind == nil then
        return nil, name .. ": a @return line has no type and name"
      end
      call.results[#call.results + 1] = {
        kind = teal_type(kind),
        name = rname,
        description = description,
      }
    elseif tag == nil then
      local text = line:gsub("^%s+", "")
      if call.summary == "" then
        call.summary = text
      end
      call.prose[#call.prose + 1] = text
    end
  end
  if call.summary == "" then
    return nil, name .. ": the block says nothing about what it does"
  end
  call.prose = trimmed(call.prose)
  local n = #call.results
  if n ~= 0 and n ~= 1 and n ~= 3 then
    return nil, name .. ": declares " .. n .. " returns; a syscall is " ..
      "infallible (1), never returns (0), or fallible (exactly 3: " ..
      "value, string, integer)"
  end
  if n == 3 then
    if call.results[2].kind ~= "string" then
      return nil, name .. ": a fallible syscall's second return is the " ..
        "error, which must be string"
    end
    if call.results[3].kind ~= "integer" then
      return nil, name .. ": a fallible syscall's third return is the " ..
        "error code, which must be integer"
    end
  end
  return call
end

local function parse_class(lines: {string}): Class | nil, string
  local class: Class = { name = "", summary = "", prose = {}, fields = {} }
  for _, line in ipairs(lines) do
    local tag, rest = line:match("^@(%a+)%s+(.*)$")
    if tag == "class" then
      class.name = rest:match("^(%S+)") or ""
    elseif tag == "field" then
      local fname, kind, description = rest:match("^([%w_]+)%s+(%S+)%s*(.*)$")
      if fname == nil then
        return nil, "a @field line names no field"
      end
      class.fields[#class.fields + 1] = {
        name = fname,
        kind = teal_type(kind),
        description = description,
      }
    elseif tag == nil then
      local text = line:gsub("^%s+", "")
      if class.summary == "" then
        class.summary = text
      end
      class.prose[#class.prose + 1] = text
    end
  end
  if class.name == "" then
    return nil, "a class block names no class"
  end
  class.prose = trimmed(class.prose)
  if #class.fields == 0 then
    return nil, class.name .. ": the class has no fields"
  end
  return class
end

--- Reads every annotated call and class out of the header. The two
--- lists travel together in one record, so a fallible read stays two
--- slots: the record, or nil and why.
--- @param header the whole text of core/syscalls.h
function generator.read(header: string): Declarations | nil, string
  local calls: {Call} = {}
  local classes: {Class} = {}
  local at = 1
  while true do
    local from, to, comment = header:find("/%*(.-)%*/", at)
    if from == nil or to == nil or comment == nil then
      break
    end
    at = to + 1
    local lines = annotation_lines(comment)
    if lines ~= nil then
      local tail = header:sub(at, at + 200)
      local name, arity_text =
        tail:match("^%s*COSMIC_SYSCALL%(([%w_]+)%s*,%s*(%d+)%s*%)")
      if name ~= nil then
        local call, trouble = parse_call(name, lines)
        if call == nil then
          return nil, trouble
        end
        local arity = tonumber(arity_text) or -1
        if #call.parameters ~= arity then
          return nil, name .. ": the header declares " .. arity ..
            " parameter(s) in COSMIC_SYSCALL but the annotation has " ..
            #call.parameters .. " @param line(s)"
        end
        calls[#calls + 1] = call
      else
        local has_class = false
        for _, line in ipairs(lines) do
          if line:match("^@class%s") then
            has_class = true
          end
        end
        if has_class then
          local class, trouble = parse_class(lines)
          if class == nil then
            return nil, trouble
          end
          classes[#classes + 1] = class
        end
      end
    end
  end
  if #calls == 0 then
    return nil, "the header declares no calls"
  end
  return { calls = calls, classes = classes }
end

--- Appends `lines` to `out` as a doc comment at `indent`, so `cosmic
--- docs` reads the header's own prose rather than a bare signature.
local function comment(out: {string}, indent: string, lines: {string})
  for _, line in ipairs(lines) do
    if line ~= "" or #lines > 1 then
      out[#out + 1] = indent .. (line == "" and "---" or "--- " .. line)
    end
  end
end

--- A call's doc comment: its prose, then one line per parameter and
--- result that says anything.
local function call_comment(call: Call): {string}
  local lines: {string} = {}
  for _, line in ipairs(call.prose) do
    lines[#lines + 1] = line
  end
  for _, p in ipairs(call.parameters) do
    if p.description ~= "" then
      lines[#lines + 1] = "@param " .. p.name .. " " .. p.description
    end
  end
  for _, r in ipairs(call.results) do
    if r.description ~= "" then
      lines[#lines + 1] = "@return " .. r.name .. " " .. r.description
    end
  end
  return lines
end

local function signature(call: Call): string
  local parameters: {string} = {}
  for _, p in ipairs(call.parameters) do
    parameters[#parameters + 1] =
      p.name .. (p.optional and "?" or "") .. ": " .. p.kind
  end
  local results: {string} = {}
  for _, r in ipairs(call.results) do
    results[#results + 1] = r.kind
  end
  local text = "function(" .. table.concat(parameters, ", ") .. ")"
  if #results > 0 then
    text = text .. ": " .. table.concat(results, ", ")
  end
  return text
end

--- The Teal declaration of the module the header describes.
--- @param header the whole text of core/syscalls.h
function generator.declaration(header: string): string | nil, string
  local found, trouble = generator.read(header)
  if found == nil then
    return nil, trouble
  end
  local calls, classes = found.calls, found.classes

  local out: {string} = {}
  out[#out + 1] = "--- The syscall table: one C function per call, the same on Linux"
  out[#out + 1] = "--- and on macOS. Derived from core/syscalls.h."
  out[#out + 1] = ""
  out[#out + 1] = "-- Edit the header; this file is written by the build."
  out[#out + 1] = ""
  out[#out + 1] = "local record syscalls"

  for _, class in ipairs(classes) do
    if class.name ~= "Constants" then
      comment(out, "  ", class.prose)
      out[#out + 1] = "  record " .. class.name
      for _, field in ipairs(class.fields) do
        comment(out, "    ", { field.description })
        out[#out + 1] = "    " .. field.name .. ": " .. field.kind
      end
      out[#out + 1] = "  end"
      out[#out + 1] = ""
    end
  end

  for index, call in ipairs(calls) do
    if index > 1 then
      out[#out + 1] = ""
    end
    comment(out, "  ", call_comment(call))
    out[#out + 1] = "  " .. call.name .. ": " .. signature(call)
  end

  for _, class in ipairs(classes) do
    if class.name == "Constants" then
      out[#out + 1] = ""
      for _, field in ipairs(class.fields) do
        comment(out, "  ", { field.description })
        out[#out + 1] = "  " .. field.name .. ": " .. field.kind
      end
    end
  end

  out[#out + 1] = "end"
  out[#out + 1] = ""
  out[#out + 1] = "return syscalls"
  out[#out + 1] = ""
  return table.concat(out, "\n")
end

return generator
