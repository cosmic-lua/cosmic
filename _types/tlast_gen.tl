--- Generate the tl stdlib AST cache into `o/_types/tlast_gen/`.
---
--- A generation unit, like `_types/types_gen.tl` beside it: `--make`
--- hands it its output directory and runs it before the graph. What it
--- writes is the artifact payload `.tl_ast.luac` — the pinned tl's
--- embedded prelude and stdlib d.tl sources, parsed once HERE and
--- serialized as a Lua chunk that rebuilds the two program ASTs, then
--- dumped to bytecode. `cosmic._teal_ast` thaws it at run time and
--- hands the programs to `tl.new_env` (carried patch, `3p/tl/tl_patch.tl`
--- ast-cache-*), which skips the parse that dominates a fresh
--- process's first env: ~11 of ~16 ms per compile child
--- (whilp/cosmic#967).
---
--- Determinism is load-bearing: the repro lane byte-compares whole
--- artifacts, so every table walk here is ordered (array part in
--- order, then integer keys ascending, then string keys ascending) and
--- the chunk name is constant. Rebuilding the same pinned bytes yields
--- the same cache, byte for byte.

local cosmic = require("cosmic")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")

local TL_LUA < const > = "o/3p/tl/tl.lua"
local OUT_NAME < const > = "tl_ast.luac"

--- Lua keywords: a table key spelled like one cannot be written bare
--- in a constructor.
local RESERVED < const >: {string: boolean} = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
  ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
  ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

--- The non-array keys of a table, in deterministic order: integer keys
--- ascending first, then string keys ascending. Any other key type is
--- a serializer error and reported by the caller.
--- @param t table The table
--- @param arraylen integer Length of the array part already emitted
--- @return {any} The ordered keys
local function ordered_keys(t: {any: any}, arraylen: integer): {any}
  local ints: {number} = {}
  local strs: {string} = {}
  for k in pairs(t) do
    if k is number then
      -- the array part [1..arraylen] is emitted positionally already
      if not (math.type(k) == "integer" and k >= 1 and k <= arraylen) then
        ints[#ints + 1] = k
      end
    elseif k is string then
      strs[#strs + 1] = k
    else
      error("tlast_gen: unsupported key type " .. type(k))
    end
  end
  table.sort(ints)
  table.sort(strs)
  local out: {any} = {}
  for _, k in ipairs(ints) do
    out[#out + 1] = k
  end
  for _, k in ipairs(strs) do
    out[#out + 1] = k
  end
  return out
end

--- One scalar as Lua source. Strings via %q, integers plainly, floats
--- via %.17g (round-trip exact), booleans literally.
--- @param v any The value
--- @return string The literal
local function scalar(v: any): string
  if v is string then
    return string.format("%q", v)
  elseif v is number then
    if math.type(v) == "integer" then
      return tostring(v)
    end
    return string.format("%.17g", v)
  elseif v is boolean then
    return tostring(v)
  end
  error("tlast_gen: unsupported value type " .. type(v))
end

--- Serialize the two parsed programs into one thaw chunk.
---
--- The chunk is `return function(hooks) ... return prelude, stdlib end`:
--- given tl's ast_hooks (node/type metatables and the typeid
--- allocator) it rebuilds the ASTs exactly as tl.parse made them —
--- same metatables, fresh typeids allocated through the real counter
--- with the original id RELATIONS preserved via an old-to-new map, so
--- ids stay distinct from anything a later parse allocates. Shared
--- tables and the (rare) cycles go through a registry created empty
--- first and filled by assignment; everything else inlines.
--- @param prelude table The parsed prelude program
--- @param stdlib table The parsed stdlib program
--- @param type_mt table tl's type metatable, to tag type nodes
--- @return string The chunk source
--- A mixed AST table viewed as an array, for its positional part.
--- @param t table The table
--- @return {any} The same table, array-typed
local function array_part(t: {any: any}): {any}
  return t as {any} -- cast: array view of a mixed AST table
end

local function serialize(prelude: {any: any}, stdlib: {any: any},
    type_mt: {any: any}): string
  -- pass 1: deterministic DFS; count references, list shared tables in
  -- first-visit order
  local refcount: {any: integer} = {}
  local registry: {any: integer} = {}
  local reg_order: {{any: any}} = {}
  local function count(t: {any: any})
    local n = (refcount[t] or 0) + 1
    refcount[t] = n
    if n > 1 then
      if not registry[t] then
        reg_order[#reg_order + 1] = t
        registry[t] = #reg_order
      end
      return
    end
    local arr = array_part(t)
    for _, v in ipairs(arr) do
      if v is {any: any} then
        count(v)
      end
    end
    for _, k in ipairs(ordered_keys(t, #arr)) do
      local v = t[k]
      if v is {any: any} then
        count(v)
      end
    end
  end
  count(prelude)
  count(stdlib)
  for _, root in ipairs({prelude, stdlib}) do
    if not registry[root] then
      reg_order[#reg_order + 1] = root
      registry[root] = #reg_order
    end
  end

  local buf: {string} = {}
  local function emit(s: string)
    buf[#buf + 1] = s
  end

  --- One field's value as an expression: a registry reference, an
  --- inline constructor, or a scalar; `typeid` fields go through the
  --- id map so relations survive renumbering.
  --- The constructor wrapper a table needs: TY for type nodes, NO for
  --- parser nodes, bare braces for plain tables.
  local function tag_of(t: {any: any}): string, string
    local mt = getmetatable(t) as {any: any} -- cast: metatable identity compare
    if mt == type_mt then
      return "TY(", ")"
    elseif mt ~= nil then
      return "NO(", ")"
    end
    return "", ""
  end

  local expr: function(v: any): string
  local function ctor(t: {any: any}): string
    local open, close = tag_of(t)
    local parts: {string} = {}
    local arr = array_part(t)
    for _, v in ipairs(arr) do
      parts[#parts + 1] = expr(v)
    end
    for _, k in ipairs(ordered_keys(t, #arr)) do
      local v = t[k]
      if k == "typeid" then
        parts[#parts + 1] = "typeid=tid(" .. tostring(v) .. ")"
      elseif k is string and k:match("^[%a_][%w_]*$") and not RESERVED[k] then
        parts[#parts + 1] = k .. "=" .. expr(v)
      else
        parts[#parts + 1] = "[" .. scalar(k) .. "]=" .. expr(v)
      end
    end
    return open .. "{" .. table.concat(parts, ",") .. "}" .. close
  end
  expr = function(v: any): string
    if v is {any: any} then
      local ri = registry[v]
      if ri then
        return "R[" .. ri .. "]"
      end
      return ctor(v)
    end
    return scalar(v)
  end

  emit("return function(hooks)\n")
  emit("local sm=setmetatable\n")
  emit("local node_mt,type_mt,new_typeid=hooks.node_mt,hooks.type_mt,hooks.new_typeid\n")
  emit("local function NO(t) return sm(t,node_mt) end\n")
  emit("local function TY(t) return sm(t,type_mt) end\n")
  emit("local idmap={}\n")
  emit("local function tid(o) local n=idmap[o] " ..
    "if not n then n=new_typeid() idmap[o]=n end return n end\n")
  emit("local R={}\n")
  for i, t in ipairs(reg_order) do
    local open, close = tag_of(t)
    emit("R[" .. i .. "]=" .. open .. "{}" .. close .. "\n")
  end
  for i, t in ipairs(reg_order) do
    local arr = array_part(t)
    for j, v in ipairs(arr) do
      emit("R[" .. i .. "][" .. j .. "]=" .. expr(v) .. "\n")
    end
    for _, k in ipairs(ordered_keys(t, #arr)) do
      local v = t[k]
      if k == "typeid" then
        emit("R[" .. i .. "].typeid=tid(" .. tostring(v) .. ")\n")
      else
        emit("R[" .. i .. "][" .. scalar(k) .. "]=" .. expr(v) .. "\n")
      end
    end
  end
  emit("return R[" .. registry[prelude] .. "],R[" .. registry[stdlib] .. "]\n")
  emit("end\n")
  return table.concat(buf)
end

--- Generate the cache into `dest`.
--- @param dest string The unit's output directory
--- @return string|nil The error message, nil on success
local function generate(dest: string): string | nil
  local body = fs.read(TL_LUA)
  if not body then
    return TL_LUA .. ": missing; run `cosmic --make fetch` first"
  end
  -- A private tl instance: parse with the pinned bytes themselves, so
  -- the serialized programs match the tl.lua this artifact embeds, and
  -- typeids are the deterministic ids of a fresh interpreter.
  local chunk, lerr = load(body, "@" .. TL_LUA)
  if not chunk then
    return TL_LUA .. ": " .. (lerr or "cannot load")
  end
  local ok, tl_any = pcall(chunk)
  if not ok then
    return TL_LUA .. ": " .. tostring(tl_any)
  end
  local tl = tl_any as {string: any} -- cast: freshly loaded module surface
  local hooks = tl.ast_hooks as {string: any} -- cast: carried-patch surface
  if not hooks then
    return TL_LUA .. ": no ast_hooks; is the tl patch applied? re-run fetch"
  end
  local prelude_text = body:match("local prelude = %[=====%[\n(.-)%]=====%]")
  local stdlib_text = body:match("local stdlib = %[=====%[\n(.-)%]=====%]")
  if not prelude_text or not stdlib_text then
    return TL_LUA .. ": embedded d.tl sources not found"
  end
  -- cast: dynamic tl surface, same call shape cosmic.teal relies on
  local parse = tl.parse as function(string, string, string): ({any: any}, {any})
  local prelude_ast, perrs = parse(prelude_text, "prelude.d.tl", "tl")
  if not prelude_ast or #perrs > 0 then
    return "prelude parse failed"
  end
  local stdlib_ast, serrs = parse(stdlib_text, "stdlib.d.tl", "tl")
  if not stdlib_ast or #serrs > 0 then
    return "stdlib parse failed"
  end
  local src = serialize(prelude_ast, stdlib_ast,
    hooks.type_mt as {any: any}) -- cast: metatable as plain table identity
  local thaw, terr = load(src, "=.tl_ast")
  if not thaw then
    return "serialized chunk does not load: " .. (terr or "unknown")
  end
  -- Stripped: the chunk is data reconstruction, not code anyone
  -- debugs, and its line info is thousands of entries of noise (the
  -- module-shipping rationale in _make/bytecode.tl does not apply).
  local out = fs.join(dest, OUT_NAME)
  local previous = fs.read(out)
  local dumped = string.dump(thaw, true)
  if previous == dumped then
    return nil
  end
  local wok, werr = fs.write(out, dumped)
  if not wok then
    return out .. ": " .. (werr or "cannot write")
  end
  return nil
end

if proc.is_main() then
  cosmic.main(function(args: {string}): number, string
      local dest = args[1]
      if not dest or dest == "" then
        return 1, "tlast_gen: usage: tlast_gen <output-dir>"
      end
      local err = generate(dest)
      if err then
        return 1, "tlast_gen: " .. err
      end
      return 0
    end)
end

local record TlastGenModule
  generate: function(dest: string): string | nil
end

local M: TlastGenModule = {
  generate = generate,
}

return M
