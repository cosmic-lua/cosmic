--- Discarded-error diagnostics for the strict checker (issue #948).
---
--- The honest-nil convention puts the error in the second return slot,
--- and the type system alone never notices when a caller drops it.
--- This pass runs after tl's check, over the typed position report the
--- checker already produced, and flags the two shapes where an error
--- return vanishes:
---
--- - "statement": a call whose declared returns end in the error
---   position (`T | nil, string` or `boolean, string`) standing as a
---   bare expression statement — `fs.write(path, data)` on its own
---   line proceeds as if the write happened.
--- - "spill": such a call as the FINAL argument to a variadic call, so
---   the error return spills in as an extra argument —
---   `print(json.encode(x))` prints a literal `nil` after the value.
---
--- The escapes are ordinary code, no new syntax: capture the returns
--- (`local v, err = f(...)`; `local _ok, _err = f(...)` for deliberate
--- fire-and-forget — the underscore convention the checker already
--- blesses), and for the spill shape, callees that CONSUME the error
--- (`assert`, `check.must`, `pcall`, ...) are exempt because they are
--- the sanctioned handling idioms.
---
--- Split from `cosmic.teal` for room (that file sits at the length
--- limit); wired in by `check` and strict `compile`, so the rule holds
--- wherever the strict gate runs — this repo and user projects alike.

--- tl's AST and report values are untyped from the narrowed public
--- API's point of view; every node is dispatched through this map
--- shape (`is` compiles to one type() check).
local type Node = {any: any}

--- One finding, in cosmic.teal's Issue shape (severity always "error").
local record Diag
  file: string
  line: integer
  column: integer
  message: string
  severity: string
end

--- Enclosing callees that consume a spilled error rather than
--- rendering it: the sanctioned handling idioms, not the trap.
local CONSUMES < const >: {string: boolean} = {
  ["assert"] = true,
  ["must"] = true,
  ["pcall"] = true,
  ["xpcall"] = true,
  ["error"] = true,
  ["select"] = true,
}

--- Does a type string declare returns ending in the error position?
--- The shape is "the final return is `string`, and it is not the only
--- return" — `(T | nil, string)` and `(boolean, string)` alike.
--- @param ts string A type string from tl's report
--- @return boolean True when the final return is an error-position string
local function fallible(ts: string): boolean
  if not string.match(ts, "^function") then
    return false
  end
  local rets = string.match(ts, ":%s*(%b())%s*$")
  or string.match(ts, ":%s*([^)]*)$")
  if not rets then
    return false
  end
  rets = string.gsub(rets, "^%(", "")
  rets = string.gsub(rets, "%)$", "")
  return string.match(rets, ",%s*string$") ~= nil
end

--- The function-type string recorded at a position, or nil.
local function type_str_at(by: Node, types: Node, y: any, x: any): string | nil
  local row = by[y]
  if row is Node then
    local tid = row[x]
    if tid ~= nil then
      local t = types[tid]
      if t is Node then
        local s = t["str"]
        if s is string then
          if string.match(s, "^function") then
            return s
          end
        end
      end
    end
  end
  return nil
end

--- A call's callee type: the field identifier for `a.f(...)`/`a:f(...)`
--- (its position carries the function type), else the bare variable.
local function callee_type(call: Node, by: Node, types: Node): string | nil
  local e1 = call["e1"]
  if e1 is Node then
    local e2 = e1["e2"]
    if e2 is Node then
      local s = type_str_at(by, types, e2["y"], e2["x"])
      if s then
        return s
      end
    end
    local s = type_str_at(by, types, e1["y"], e1["x"])
    if s then
      return s
    end
  end
  return nil
end

--- A call's callee NAME (`f` in `f(...)`, `must` in `check.must(...)`),
--- for the consumer exemption.
local function callee_name(call: Node): string | nil
  local e1 = call["e1"]
  if e1 is Node then
    local tk = e1["tk"]
    if e1["kind"] == "variable" and tk is string then
      return tk
    end
    local e2 = e1["e2"]
    if e2 is Node then
      local ftk = e2["tk"]
      if ftk is string then
        return ftk
      end
    end
  end
  return nil
end

--- A node's recorded position, defaulting to 0.
local function pos_of(node: Node, key: string): integer
  local v = node[key]
  if v is number then
    return math.tointeger(v) or 0
  end
  return 0
end

--- Is this node a `@funcall` op?
local function is_funcall(node: any): boolean
  if node is Node then
    if node["kind"] == "op" then
      local op = node["op"]
      if op is Node then
        return op["op"] == "@funcall"
      end
    end
  end
  return false
end

--- Record a finding once per (line, shape).
local function add(diags: {Diag}, dedup: {string: boolean}, path: string,
    node: Node, message: string)
  local key = tostring(pos_of(node, "y")) .. ":" .. message
  if not dedup[key] then
    dedup[key] = true
    diags[#diags + 1] = {
      file = path,
      line = pos_of(node, "y"),
      column = pos_of(node, "x"),
      message = message,
      severity = "error",
    }
  end
end

--- Walk one AST, collecting both shapes. The AST carries parent links,
--- so the walk keeps a seen-set instead of trusting it to be a tree.
local function walk(node: any, by: Node, types: Node, path: string,
    diags: {Diag}, dedup: {string: boolean}, seen: {any: boolean})
  if node is Node then
    if seen[node] then
      return
    end
    seen[node] = true

    -- Statement shape: a direct child of a statements block that is a
    -- bare call — every return discarded.
    if node["kind"] == "statements" then
      local arr = node as {any} -- cast: a statements node is array-shaped
      for i = 1, #arr do
        local st = arr[i]
        if is_funcall(st) and st is Node then
          local ts = callee_type(st, by, types)
          if ts and fallible(ts) then
            add(diags, dedup, path, st,
              "discarded error return of " .. ts
              .. " — capture it: `local v, err = f(...)`"
              .. " (or `local _ok, _err = f(...)` for deliberate"
              .. " fire-and-forget; assert/check.must in tests)")
          end
        end
      end
    end

    -- Spill shape: a fallible call as the FINAL argument of a variadic
    -- call (its extra returns become extra arguments), unless the
    -- enclosing callee consumes them.
    if is_funcall(node) then
      local args = node["e2"]
      if args is Node then
        local arr = args as {any} -- cast: an expression_list is array-shaped
        local last = arr[#arr]
        if is_funcall(last) and last is Node then
          local encl = callee_type(node, by, types)
          local inner = callee_type(last, by, types)
          local ename = callee_name(node)
          local consumes = false
          if ename then
            consumes = CONSUMES[ename] or false
          end
          if encl and inner and not consumes
          and string.find(encl, "...", 1, true) and fallible(inner) then
            add(diags, dedup, path, last,
              "error return of " .. inner
              .. " spills into the enclosing call — capture it first"
              .. " (`local v, err = f(...)`), or parenthesize to"
              .. " truncate: `(f(...))`")
          end
        end
      end
    end

    for k, v in pairs(node) do
      -- `expected`/`decltuple` reach into type-land, not child nodes.
      if k ~= "expected" and k ~= "decltuple" then
        walk(v, by, types, path, diags, dedup, seen)
      end
    end
  end
end

--- Findings for one processed file.
---
--- `env` is the tl environment the file was processed in, with
--- `report_types` enabled; `ast` the file's tree; `path` the name the
--- file was processed under (the report is keyed by it). Returns an
--- empty list when the report is unavailable — this pass refines a
--- check that already ran, it never blocks one.
--- @param env any The tl env (opaque in the narrowed API)
--- @param ast any The file's AST from tl's Result
--- @param path string The filename the report keys positions by
--- @return {Diag} Findings, in file order
local function issues(env: any, ast: any, path: string): {Diag}
  local diags: {Diag} = {}
  if not (env is Node) then
    return diags
  end
  local reporter = (env)["reporter"]
  if not (reporter is Node) then
    return diags
  end
  local rep = reporter
  -- cast: TypeReporter method, outside the narrowed API
  local get_report = rep["get_report"] as function(any): any
  local report = get_report(rep)
  if not (report is Node) then
    return diags
  end
  local by_pos = (report)["by_pos"]
  local types = (report)["types"]
  if not (by_pos is Node) or not (types is Node) then
    return diags
  end
  local by = (by_pos)[path]
  if not (by is Node) then
    return diags
  end
  local by_file = by
  local type_tab = types
  walk(ast, by_file, type_tab, path, diags, {}, {})
  table.sort(diags, function(a: Diag, b: Diag): boolean
      if a.line ~= b.line then
        return a.line < b.line
      end
      return a.column < b.column
    end)
  return diags
end

local record TealDiscardModule
  type Diag = Diag
  fallible: function(ts: string): boolean
  issues: function(env: any, ast: any, path: string): {Diag}
end

local M: TealDiscardModule = {
  fallible = fallible,
  issues = issues,
}

return M
