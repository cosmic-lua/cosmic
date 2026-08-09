--- What a module publishes, read from the module itself.
---
--- Two views, unioned: the table literal a module assigns, and its
--- interface record's function-typed fields. Kept apart from the
--- parser because both the publishable view and the shard merge in
--- `index.tl` ask the same question, and one answer serves them.

--- The names a module states in a table literal it assigns to its
--- module table: `local M: FsModule = { read = ..., }`, the bare
--- `M = { ... }` a step after `local M: EnvModule`, and the inline
--- `return {attach = attach}`. One of several views of a module's
--- export surface; `export_surface` below is what callers want.
local function scan_exports(source: string): {string: boolean} | nil
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
--- @param records {{string:any}} The records the parser found
--- @param into {string:boolean} The surface being accumulated
--- @return boolean Whether any record contributed a name
local function record_exports(source: string, records: {{string: any}},
    into: {string: boolean}): boolean
  if not records then
    return false
  end
  local returned = source:match("\nreturn%s+([%w_]+)%s*\n?$")
  local found = false
  for _, rec in ipairs(records) do
    local name = rec.name as string -- cast: from any
    if name == returned or name:match("Module$") then
      local fields = rec.fields as {{string}} -- cast: from any
      for _, field in ipairs(fields or {}) do
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
--- @param records {{string:any}} The records the parser found
--- @return {string:boolean} The exported names, possibly empty
local function export_surface(source: string,
    records: {{string: any}}): {string: boolean}
  local names: {string: boolean} = {}
  local literal = scan_exports(source)
  if literal then
    for name in pairs(literal) do
      names[name] = true
    end
  end
  local _found = record_exports(source, records, names)
  return names
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
  records: {{string: any}}): {string: boolean}
end

local M: ExportsModule = {
  export_surface = export_surface,
}

return M
