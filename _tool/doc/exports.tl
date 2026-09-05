--- What a module publishes, read from the module itself.
---
--- Two views, unioned: the table literal a module assigns, and its
--- interface record's function-typed fields. Kept apart from the
--- parser because both the publishable view and the shard merge in
--- `index.tl` ask the same question, and one answer serves them.

local doc_types = require("cosmic.doc")
local type RecordDoc = doc_types.RecordDoc

--- The names a module states in a table literal it assigns to its
--- module table: `local M: FsModule = { read = ..., }`, the bare
--- `M = { ... }` a step after `local M: EnvModule`, and the inline
--- `return {attach = attach}`. One of several views of a module's
--- export surface; `export_surface` below is what callers want.
local function scan_exports(source: string,
    aliases: {string: string}): {string: boolean} | nil
  local names: {string: boolean} = nil
  local in_table = false
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    if in_table then
      if line:match("^}") then
        in_table = false
      else
        local key = line:match("^%s*([%w_]+)%s*=")
        if key then
          names = names or {}
          names[key] = true
          -- `debug = debug_msg,` exports the LOCAL under another name;
          -- record the pair so the local's doc can follow the rename
          -- instead of being dropped as unexported.
          local value = line:match("^%s*[%w_]+%s*=%s*([%w_]+)%s*,?%s*$")
          if value and value ~= key then
            aliases[key] = value
          end
        end
      end
    elseif line:match("^local%s+[%w_]+%s*:%s*[%w_%.]+%s*=%s*{")
    or line:match("^[%w_]+%s*=%s*{")
    or line:match("^return%s*{") then
      local inline = line:match("{(.*)}%s*$")
      local rest = inline or line:match("{(.*)$")
      if rest then
        for key in rest:gmatch("([%w_]+)%s*=") do
          names = names or {}
          names[key] = true
        end
        -- Aliases only where the pair is exactly `key = identifier`:
        -- a call or a literal value cannot be a renamed local.
        for pair in rest:gmatch("[^,{}]+") do
          local key, value = pair:match("^%s*([%w_]+)%s*=%s*([%w_]+)%s*$")
          if key and value and value ~= key then
            aliases[key] = value
          end
        end
      end
      in_table = inline == nil
    end
  end
  return names
end

--- The function-typed fields of a module's INTERFACE RECORD — the
--- other view, and the one that does not depend on how the module
--- happens to build its table. A module states its API as a record
--- (`EnvModule`, `SignalModule`, the `stream` record a module returns
--- directly), and `render.tl` has always read exports that way.
--- Whichever record it is, its function fields are exported names.
--- @param source string The module source
--- @param records {RecordDoc} The records the parser found
--- @param into {string:boolean} The surface being accumulated
--- @return boolean Whether any record contributed a name
local function record_exports(source: string, records: {RecordDoc},
    into: {string: boolean}): boolean
  if not records then
    return false
  end
  local returned = source:match("\nreturn%s+([%w_]+)%s*\n?$")
  local found = false
  for _, rec in ipairs(records) do
    local name = rec.name
    if name == returned or name:match("Module$") then
      for _, field in ipairs(rec.fields or {}) do
        if field[2] and field[2]:match("^function") then
          into[field[1]] = true
          found = true
        end
      end
    end
  end
  return found
end

--- Every name a module publishes, by every view that can be read: the
--- literal it assigns, and its interface record's function fields.
---
--- Always a set, never "unknown": a module whose shape no view
--- recognizes yields an EMPTY surface, and an empty surface publishes
--- no locals at all. The rule is the one the doc itself states — a
--- page may omit a function, it may not invent one. Omission is
--- visible and harmless; a documented function nobody can call costs
--- the reader a build.
--- @param source string The module source
--- @param records {RecordDoc} The records the parser found
--- @return {string:boolean} The exported names, possibly empty
--- @return {string:string} Aliased exports: exported name -> local name
local function export_surface(source: string,
    records: {RecordDoc}): {string: boolean}, {string: string}
  local names: {string: boolean} = {}
  local aliases: {string: string} = {}
  local literal = scan_exports(source, aliases)
  if literal then
    for name in pairs(literal) do
      names[name] = true
    end
  end
  local _found = record_exports(source, records, names)
  return names, aliases
end

--- The top-level return-slot count a signature declares: commas outside
--- enclosing parens and braces, counted after the `):` that closes the
--- PARAMETER LIST — never the first `):` found by text search, which a
--- nested `function(...): (...)` parameter's own colon can shadow.
---
--- A signature that opens with `(` has a real parameter list: the
--- first point its paren depth returns to zero is that list's close,
--- whatever a parameter's own type nests inside it, so the return text
--- is whatever follows a `:` right there — empty when there is none, the
--- "no return declared" case. A string that never opens with `(` (a
--- bare return-type fragment, or a type with its own `{`/`(`) is
--- return text already, counted as-is.
--- @param signature string A function's full signature, or bare return-type text
--- @return integer The number of top-level return slots, 0 if none
local function return_slots(signature: string): integer
  local text = signature
  if signature:sub(1, 1) == "(" then
    local depth = 0
    local rest: string = nil
    for i = 1, #signature do
      local c = signature:sub(i, i)
      if c == "(" or c == "{" then
        depth = depth + 1
      elseif c == ")" or c == "}" then
        depth = depth - 1
        if depth == 0 then
          if signature:sub(i + 1, i + 1) == ":" then
            rest = signature:sub(i + 2):match("^%s*(.*)$")
          end
          break
        end
      end
    end
    text = rest or ""
  end
  if text == "" then
    return 0
  end
  local depth, slots = 0, 1
  for i = 1, #text do
    local c = text:sub(i, i)
    if c == "(" or c == "{" then
      depth = depth + 1
    elseif c == ")" or c == "}" then
      depth = depth - 1
    elseif c == "," and depth == 0 then
      slots = slots + 1
    end
  end
  return slots
end

--- Drop a module's private helpers from its own page.
---
--- A local is published only where the module's export surface names
--- it, so a page never advertises a function the module does not have.
--- `render.tl` holds the markdown it renders to the same rule; this is
--- the same rule for the index the binary ships, which is the only doc
--- surface a reader without the repo has. A page that names a function
--- nobody can call is worse than one that omits it: the reader writes
--- the call, and the build fails.
---
local record ExportsModule
  export_surface: function(source: string,
  records: {RecordDoc}): {string: boolean}, {string: string}
  return_slots: function(signature: string): integer
end

local M: ExportsModule = {
  export_surface = export_surface,
  return_slots = return_slots,
}

return M
