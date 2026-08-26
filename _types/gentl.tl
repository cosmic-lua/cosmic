--- Generate the `tl` shim from the pinned tl source.
---
--- tl.d.tl is the narrowed public tl surface cosmic ships (embedded in
--- the binary as the types user scripts see for require("tl")). It used
--- to be handcrafted, and its function signatures drifted from tl's
--- real API three times before anyone noticed  The
--- self-hosted tl.tl staged by the 3p pin is the ground truth, so this
--- generator extracts the allowlisted signatures from it and erases
--- internal types by rule. Records stay curated field subsets, but
--- every curated field is verified to exist upstream.
---
--- `_types/types_gen.tl` runs this on every build, into `o/_types/types_gen/`.

--- Erasure rules: primitives pass through; upstream enums/aliases of
--- string become string; the records this file re-declares keep their
--- names; everything else (internal records, interfaces) becomes any.
local KEEP: {string: boolean} = {
  string = true, boolean = true, integer = true, number = true,
  any = true, ["nil"] = true,
}
local TO_STRING: {string: boolean} = {
  GenTarget = true, GenCompat = true, CompatMode = true,
  TargetMode = true, ParseLang = true, WarningKind = true,
  TokenKind = true,
}
local NAMED: {string: boolean} = {
  Token = true, Error = true, Result = true,
  EnvOptions = true, CheckOptions = true, Comment = true,
}

local function erase(t: string): string
  t = t:match("^%s*(.-)%s*$")
  -- unions: erase each side
  if t:find("|", 1, true) then
    local parts: {string} = {}
    for side in t:gmatch("[^|]+") do
      parts[#parts + 1] = erase(side)
    end
    return table.concat(parts, " | ")
  end
  -- array / map shorthand
  local inner = t:match("^{(.*)}$")
  if inner then
    local k, v = inner:match("^([^:]+):(.+)$")
    if k then
      return "{" .. erase(k) .. ": " .. erase(v) .. "}"
    end
    return "{" .. erase(inner) .. "}"
  end
  t = t:gsub("^tl%.", "")
  if KEEP[t] then return t end
  if TO_STRING[t] then return "string" end
  if NAMED[t] then return t end
  return "any"
end

--- Split a comma-separated list at depth zero (braces and parens nest).
local function split_top(s: string): {string}
  local parts: {string} = {}
  local depth = 0
  local start = 1
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "{" or c == "(" then
      depth = depth + 1
    elseif c == "}" or c == ")" then
      depth = depth - 1
    elseif c == "," and depth == 0 then
      parts[#parts + 1] = s:sub(start, i - 1)
      start = i + 1
    end
  end
  local last = s:sub(start)
  if last:match("%S") then
    parts[#parts + 1] = last
  end
  return parts
end

--- Find tl.NAME's single-line signature (either statement form) and
--- return its parameter list text and return list text.
local function find_signature(source: string, name: string): string, string
  local pat_fn = "\n%s*function tl%." .. name .. "%((.-)%)([^\n]*)"
  local pat_asg = "\n%s*tl%." .. name .. " = function%((.-)%)([^\n]*)"
  local args, rest = source:match(pat_fn)
  if not args then
    args, rest = source:match(pat_asg)
  end
  if not args then
    return nil, nil
  end
  local rets = (rest or ""):match("^%s*:%s*(.-)%s*$") or ""
  return args, rets
end

--- Render one extracted signature with erased types. Parameters are
--- emitted positionally; `name?: T` becomes `? T`. max_params caps the
--- emitted arity for trailing upstream parameters cosmic's surface
--- deliberately omits (the cap may only drop, never reorder).
--- optional_from marks parameters from that position optional even when
--- upstream requires them, so cosmic call sites may omit trailing
--- arguments upstream would demand (tl_conformance_test.tl proves the
--- full-arity call still satisfies upstream).
local function render_signature(args: string, rets: string, max_params: integer, optional_from: integer): string
  local params: {string} = {}
  for _, p in ipairs(split_top(args)) do
    local pname, ptype = p:match("^%s*([%w_%.]+%??)%s*:%s*(.+)$")
    if not ptype then
      pname, ptype = "", p
    end
    local optional = pname:find("?", 1, true) ~= nil
    if optional_from and #params + 1 >= optional_from then
      optional = true
    end
    params[#params + 1] = (optional and "? " or "") .. erase(ptype)
    if max_params and #params >= max_params then
      break
    end
  end
  local out = "function(" .. table.concat(params, ", ") .. ")"
  if rets ~= "" then
    local rendered: {string} = {}
    for _, r in ipairs(split_top(rets)) do
      rendered[#rendered + 1] = erase(r)
    end
    out = out .. ": " .. table.concat(rendered, ", ")
  end
  return out
end

--- Assert every curated record field exists in the upstream record of
--- the same name (fields may be a subset; types are erased by rule, so
--- only presence is checked).
local function verify_record(source: string, name: string, fields: {string}): string
  local body = source:match("\n%s+record " .. name .. "\n(.-)\n%s+end\n")
  if not body then
    return "record " .. name .. " not found in tl source"
  end
  for _, field in ipairs(fields) do
    if not body:match("%f[%w_]" .. field .. "%s*:") then
      return "record " .. name .. " lost field '" .. field .. "' upstream"
    end
  end
  return nil
end

--- The curated surface: every entry is verified against the tl source.
--- comment lines are emitted verbatim above the member.
local record Entry
  name: string
  max_params: integer
  optional_from: integer
  comment: {string}
end

local FUNCTIONS: {Entry} = {
  {name = "loader"},
  {name = "search_module", comment = {
      "-- returns found filename, an open FILE handle (caller must close",
      "-- it), and the list of tried path patterns",
    }},
  {name = "init_env", comment = {
      "-- positional args: lax?, gen_compat? (\"off\"|...), gen_target? (\"5.4\"|...)",
    }},
  {name = "new_env"},
  {name = "lex"},
  {name = "parse_program"},
  {name = "process_string", optional_from = 5, comment = {
      "-- always returns a Result; parse/check failures land in its",
      "-- syntax_errors/type_errors fields, never in a second return.",
      "-- Upstream requires the 5th param (_module_name); it is unused,",
      "-- so it is declared optional here for 4-arg cosmic call sites",
    }},
  {name = "generate", comment = {
      "-- second argument is the generation TARGET string (\"5.4\"), not an",
      "-- options table; returns nil plus an error on codegen failure",
    }},
}

local RECORD_FIELDS: {string: {string}} = {
  Error = {"filename", "y", "x", "msg", "tag"},
  Result = {"ast", "syntax_errors", "type_errors", "warnings"},
  Comment = {"x", "y", "text"},
  Token = {"x", "y", "tk", "kind", "comments"},
  CheckOptions = {
    "feat_lax", "feat_arity", "gen_compat", "gen_target",
    "run_internal_compiler_checks",
  },
  EnvOptions = {"defaults", "predefined_modules", "parsed_prelude", "parsed_stdlib"},
}

local PRELUDE < const > = [[-- GENERATED into o/_types/types_gen/ by _types/types_gen.tl from the pinned tl
-- source on every build. Not committed; there is nothing to edit.
-- This is the narrowed public tl surface cosmic supports: function
-- signatures are extracted from tl.tl and internal types erased by
-- rule; records are curated field subsets verified against upstream.
local record tl
  record Error
    filename: string
    y: integer
    x: integer
    msg: string
    tag: string -- warning kind: "unknown"|"unused"|"unread"|"redeclaration"|"branch"|"hint"
  end

  record Result
    ast: any
    syntax_errors: {Error}
    type_errors: {Error}
    warnings: {Error}
  end

  -- one lexed comment, as tl's own Comment record: the three fields
  -- Token.comments elements actually carry
  record Comment
    x: integer
    y: integer
    text: string
  end

  record Token
    x: integer
    y: integer
    tk: string
    kind: string
    comments: {Comment}
  end

  -- per-env feature/codegen defaults (tl.CheckOptions upstream)
  record CheckOptions
    feat_lax: string -- "on"|"off"
    feat_arity: string -- "on"|"off"
    gen_compat: string -- "off"|"optional"|"required"
    gen_target: string -- "5.1"|"5.3"|"5.4"
    run_internal_compiler_checks: boolean
  end

  record EnvOptions
    defaults: CheckOptions
    predefined_modules: {string}
    -- pre-parsed prelude/stdlib ASTs (carried patch, tl_patch.tl
    -- ast-cache-*): cosmic._teal_ast thaws the artifact's cache into
    -- these so new_env skips tl's parse of its embedded d.tl sources
    parsed_prelude: any
    parsed_stdlib: any
  end

  path: string
  warning_kinds: {string: boolean}
  -- carried-patch surface (tl_patch.tl ast-cache-hooks-*): the node and
  -- type metatables plus the typeid allocator an AST cache thaw needs
  ast_hooks: {string: any}
]]

--- Generate the full tl.d.tl content from tl source text.
--- @param source string The staged tl.tl source
--- @return string | nil Generated declaration file content
--- @return string Error message when extraction or verification fails
local function generate(source: string): string | nil, string
  for name, fields in pairs(RECORD_FIELDS) do
    local err = verify_record(source, name, fields)
    if err then
      return nil, err
    end
  end
  local lines: {string} = {PRELUDE}
  for _, entry in ipairs(FUNCTIONS) do
    local args, rets = find_signature(source, entry.name)
    if not args then
      return nil, "tl." .. entry.name .. " not found in tl source"
    end
    if entry.comment then
      for _, c in ipairs(entry.comment) do
        lines[#lines + 1] = "  " .. c .. "\n"
      end
    end
    lines[#lines + 1] = "  " .. entry.name .. ": "
    .. render_signature(args, rets, entry.max_params, entry.optional_from) .. "\n"
  end
  lines[#lines + 1] = "end\n\nreturn tl\n"
  return table.concat(lines)
end

local M = {
  generate = generate,
  erase = erase,
}

-- When run as a script: gentl.tl <path-to-staged-tl.tl>, output on stdout
if arg and arg[0] and (arg[0]:match("gentl%.tl$") or arg[0]:match("gentl%.lua$")) then
  local path = arg[1]
  if not path then
    io.stderr:write("usage: gentl <staged-tl.tl>\n")
    os.exit(1)
  end
  local f = io.open(path, "r")
  if not f then
    io.stderr:write("cannot open " .. path .. "\n")
    os.exit(1)
  end
  local source = f:read("*a")
  f:close()
  local out, err = generate(source)
  if not out then
    io.stderr:write("gentl: " .. err .. "\n")
    os.exit(1)
  end
  io.write(out)
  os.exit(0)
end

return M
