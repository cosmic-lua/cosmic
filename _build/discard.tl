--- Typed discarded-error scan (issue #948).
---
--- The honest-nil convention puts the error in the second return slot,
--- and nothing in the toolchain notices when a caller drops it. This
--- module finds the two shapes where that happens, using tl's typed
--- position report — the lexer-based lints cannot see a callee's
--- declared signature, which is the whole question here:
---
--- - "statement": a call whose declared returns end in the error
---   position (`T | nil, string` or `boolean, string`) standing as an
---   expression statement, every return discarded. `fs.write(path,
---   data)` as a bare line is the dangerous case.
--- - "spill": such a call as the FINAL argument to a variadic call, so
---   the extra returns spill into it. `print(json.encode(x))` printing
---   a literal `nil` is the visible case.
---
--- Callees that CONSUME the error are exempt from the spill shape:
--- `assert(fs.write(...))` checks the boolean and reports the message,
--- and `check.must(...)` is the sanctioned narrowing idiom.
---
--- `_build/discard_test.tl` holds the judgement: spills at zero, and
--- the statement debt ratcheted per file against `_build/discards.txt`.

local fs = require("cosmic.fs")
local tl = require("tl")

--- The AST and type-report values tl hands back are untyped from the
--- narrowed public API's point of view; every node is dispatched
--- through this map shape (`is` compiles to one type() check).
local type Node = {any: any}

--- One discarded-error call site.
local record Site
  file: string
  line: integer
  --- "statement" (all returns dropped) or "spill" (into a variadic call)
  kind: string
  --- The callee's type string, so a message can show the signature.
  callee: string
end

--- What one scan over a set of files found.
local record ScanResult
  sites: {Site}
  --- Files actually analyzed (processed by tl with a position report).
  checked: integer
  --- Files the scan could NOT analyze — named, never silently skipped.
  failed: {string}
end

--- Enclosing callees that consume the spilled error rather than
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
--- Matches `(T | nil, string)` and `(boolean, string)` alike: the shape
--- is "last return is `string`, and it is not the only return".
--- @param ts string A type string from tl's report (e.g. "function(string): (boolean, string)")
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

--- A node's line, defaulting to 0 when the AST carries none.
local function line_of(node: Node): integer
  local y = node["y"]
  if y is number then
    return math.tointeger(y) or 0
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

--- Record a site once per (file, line, kind).
local function add_site(sites: {Site}, dedup: {string: boolean},
    file: string, line: integer, kind: string, callee: string)
  local key = file .. ":" .. tostring(line) .. ":" .. kind
  if not dedup[key] then
    dedup[key] = true
    sites[#sites + 1] = {file = file, line = line, kind = kind, callee = callee}
  end
end

--- Walk one AST, collecting both shapes. The AST has parent links, so
--- the walk carries a seen-set instead of trusting it to be a tree.
local function walk(node: any, by: Node, types: Node, path: string,
    sites: {Site}, dedup: {string: boolean}, seen: {any: boolean})
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
            add_site(sites, dedup, path, line_of(st), "statement", ts)
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
            add_site(sites, dedup, path, line_of(last), "spill", inner)
          end
        end
      end
    end

    for k, v in pairs(node) do
      -- `expected`/`decltuple` reach into type-land, not child nodes.
      if k ~= "expected" and k ~= "decltuple" then
        walk(v, by, types, path, sites, dedup, seen)
      end
    end
  end
end

--- Scan a set of Teal files.
---
--- One shared tl environment across every file: each dependency is
--- processed once, which is what makes a whole-tree scan take seconds
--- rather than minutes. Files tl cannot process land in `failed` — a
--- file the scan skipped silently would read as a file with no debt.
--- @param paths {string} Teal files to analyze, relative to the cwd
--- @param include_dirs {string} Directories searched for .d.tl/.tl deps
--- @return ScanResult The sites, plus what was and was not analyzed
local function scan(paths: {string}, include_dirs: {string}): ScanResult
  local out: ScanResult = {sites = {}, checked = 0, failed = {}}

  local parts: {string} = {}
  for _, d in ipairs(include_dirs) do
    parts[#parts + 1] = d .. "/?.d.tl"
    parts[#parts + 1] = d .. "/?.tl"
  end
  parts[#parts + 1] = "?.tl"
  parts[#parts + 1] = "?/init.tl"
  local saved = tl.path
  tl.path = table.concat(parts, ";")

  local env = tl.new_env({defaults = {feat_lax = "off", feat_arity = "on",
        gen_target = "5.4", gen_compat = "off"}})
  if not (env is Node) then
    tl.path = saved
    out.failed[#out.failed + 1] = "tl.new_env: no environment"
    return out
  end
  -- The narrowed tl API does not expose get_types; asking the env to
  -- collect a report and reading its reporter is the same mechanism.
  local env_map = env as Node -- cast: env is opaque `any` in the narrowed API
  env_map["report_types"] = true

  local asts: {string: any} = {}
  for _, path in ipairs(paths) do
    local text = fs.read(path)
    if text is string then
      local ok, res = pcall(tl.process_string, text, false, env, path)
      if ok and res ~= nil then
        local ast = (res as Node)["ast"] -- cast: Result beyond the narrowed API
        if ast ~= nil then
          asts[path] = ast
          out.checked = out.checked + 1
        else
          out.failed[#out.failed + 1] = path .. ": no ast"
        end
      else
        out.failed[#out.failed + 1] = path .. ": " .. tostring(res)
      end
    else
      out.failed[#out.failed + 1] = path .. ": cannot read"
    end
  end
  tl.path = saved

  local reporter = env_map["reporter"]
  if not (reporter is Node) then
    out.failed[#out.failed + 1] = "tl reporter: not collected"
    return out
  end
  -- Narrowing does not survive the early-exit guards above, so each
  -- value is cast once right after its guard.
  local rep = reporter as Node -- cast: record union after guard
  -- cast: TypeReporter method, outside the narrowed API
  local get_report = rep["get_report"] as function(any): any
  local report = get_report(rep)
  if not (report is Node) then
    out.failed[#out.failed + 1] = "tl report: not a table"
    return out
  end
  local by_pos = (report as Node)["by_pos"] -- cast: record union after guard
  local types = (report as Node)["types"] -- cast: record union after guard
  if not (by_pos is Node) or not (types is Node) then
    out.failed[#out.failed + 1] = "tl report: missing by_pos/types"
    return out
  end
  local by_all = by_pos as Node -- cast: record union after guard
  local type_tab = types as Node -- cast: record union after guard

  for path, ast in pairs(asts) do
    local by = by_all[path]
    if by is Node then
      walk(ast, by, type_tab, path, out.sites, {}, {})
    else
      out.failed[#out.failed + 1] = path .. ": no position report"
    end
  end

  table.sort(out.sites, function(a: Site, b: Site): boolean
      if a.file ~= b.file then
        return a.file < b.file
      end
      return a.line < b.line
    end)
  return out
end

local record DiscardModule
  type Site = Site
  type ScanResult = ScanResult
  fallible: function(ts: string): boolean
  scan: function(paths: {string}, include_dirs: {string}): ScanResult
end

local M: DiscardModule = {
  fallible = fallible,
  scan = scan,
}

return M
