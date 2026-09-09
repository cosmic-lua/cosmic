--- Immutable source snapshots and exact source-owned syntax ranges.
local tl = require("tl")
local hash = require("cosmic.hash")
local node_mod = require("cosmic.ast.node")
local children_mod = require("cosmic.ast.children")
local position = require("cosmic.ast.source_position")
local type Node = node_mod.Node
local type Range = position.Range
local enum Phase
  "lex"
  "parse"
end
local record Issue
  phase: Phase
  message: string
  line: integer
  column: integer
  range: Range | nil
end
--- A parsed source type. Teal type values are deliberately not expression Nodes.
local record TypeSyntax
  owner: Node
  role: string
  value: any
  range: Range
end
local record AttributeSyntax
  owner: Node
  role: string
  name: string
  range: Range
end
local record GenericSyntax
  owner: Node
  role: string
  range: Range
end
local record Snapshot
  source: string
  name: string
  lang: string
  id: string
  node: Node
  tokens: {tl.Token}
  line_starts: {integer}
  issues: {Issue}
  parents: {Node: Node}
  roles: {Node: string}
  ranges: {Node: Range}
  owned_ranges: {Range: boolean}
  types: {TypeSyntax}
  attributes: {AttributeSyntax}
  generics: {GenericSyntax}
end
local record ParseResult
  snapshot: Snapshot | nil
  issues: {Issue}
end
local function detect_lang(name: string, lang?: string): string
  if lang then return lang end
  return name:match("%.tl$") and "tl" or "lua"
end

local function map_of(value: any): {any: any}
  return value as {any: any} -- cast: parser-owned syntax/type table
end

local function syntax_range(snapshot: Snapshot, value: any): Range | nil
  if not (value is {any: any}) then return nil end
  local y, x = value["syntax_y"], value["syntax_x"]
  local yend, xend = value["syntax_yend"], value["syntax_xend"]
  if not (y is integer and x is integer and yend is integer and xend is integer) then
    return nil
  end
  return position.from_positions(snapshot.line_starts, #snapshot.source + 1,
    y, x, yend, xend)
end

local function add_type(snapshot: Snapshot, owner: Node, role: string, value: any)
  local range = syntax_range(snapshot, value)
  if range then
    snapshot.owned_ranges[range] = true
    snapshot.types[#snapshot.types + 1] = {
      owner = owner, role = role, value = value, range = range,
    }
  end
end

local function add_generic(snapshot: Snapshot, owner: Node, role: string, value: any)
  local range = syntax_range(snapshot, value)
  if range then
    snapshot.owned_ranges[range] = true
    snapshot.generics[#snapshot.generics + 1] = {
      owner = owner, role = role, range = range,
    }
  end
end

local function collect_type(snapshot: Snapshot, owner: Node, role: string,
    value: any, seen: {any: boolean})
  if not (value is {any: any}) or seen[value] then return end
  seen[value] = true
  local raw = value as {any: any} -- cast: narrowed parser type table
  add_type(snapshot, owner, role, value)
  local typename = raw["typename"]
  if typename == "generic" then
    add_generic(snapshot, owner, role .. ".generic_arguments", raw["typeargs"])
    collect_type(snapshot, owner, role .. ".value", raw["t"], seen)
    local args = raw["typeargs"]
    if args is {any} then
      for i, typearg in ipairs(args) do
        collect_type(snapshot, owner, role .. ".generic_parameter[" .. i .. "]",
          typearg, seen)
      end
    end
  elseif typename == "tuple" then
    local tuple = raw["tuple"]
    if tuple is {any} then
      for i, typ in ipairs(tuple) do
        collect_type(snapshot, owner, role .. "[" .. i .. "]", typ, seen)
      end
    end
  elseif typename == "union" or typename == "tupletable" or typename == "poly" then
    local types = raw["types"]
    if types is {any} then
      for i, typ in ipairs(types) do
        collect_type(snapshot, owner, role .. "[" .. i .. "]", typ, seen)
      end
    end
  elseif typename == "map" then
    collect_type(snapshot, owner, role .. ".key", raw["keys"], seen)
    collect_type(snapshot, owner, role .. ".value", raw["values"], seen)
  elseif typename == "record" or typename == "interface" then
    local interfaces = raw["interface_list"]
    if interfaces is {any} then
      for i, typ in ipairs(interfaces) do
        collect_type(snapshot, owner, role .. ".interface[" .. i .. "]", typ, seen)
      end
    end
    collect_type(snapshot, owner, role .. ".element", raw["elements"], seen)
    local fields = raw["fields"]
    if fields is {any: any} then
      for name, typ in pairs(fields) do
        collect_type(snapshot, owner, role .. ".field[" .. tostring(name) .. "]", typ, seen)
      end
    end
    local meta = raw["meta_fields"]
    if meta is {any: any} then
      for name, typ in pairs(meta) do
        collect_type(snapshot, owner, role .. ".metamethod[" .. tostring(name) .. "]",
          typ, seen)
      end
    end
  elseif typename == "function" then
    collect_type(snapshot, owner, role .. ".parameters", raw["args"], seen)
    collect_type(snapshot, owner, role .. ".returns", raw["rets"], seen)
  elseif typename == "nominal" then
    add_generic(snapshot, owner, role .. ".generic_arguments", raw["typevals"])
    local values = raw["typevals"]
    if values is {any} then
      for i, typ in ipairs(values) do
        collect_type(snapshot, owner, role .. ".type_argument[" .. i .. "]", typ, seen)
      end
    end
  elseif typename == "typearg" then
    collect_type(snapshot, owner, role .. ".constraint", raw["constraint"], seen)
  elseif typename == "array" then
    collect_type(snapshot, owner, role .. ".element", raw["elements"], seen)
  elseif typename == "typedecl" then
    collect_type(snapshot, owner, role .. ".definition", raw["def"], seen)
  elseif typename == "literal_table_item" then
    collect_type(snapshot, owner, role .. ".key", raw["ktype"], seen)
    collect_type(snapshot, owner, role .. ".value", raw["vtype"], seen)
  end
end

local function index_owned_syntax(snapshot: Snapshot, node: Node)
  local raw = map_of(node)
  local seen: {any: boolean} = {}
  if node.kind == "argument" then
    collect_type(snapshot, node, "parameter_type", raw["argtype"], seen)
  elseif (node.kind == "local_declaration" or node.kind == "global_declaration")
  and raw["decltuple"] then
    collect_type(snapshot, node, "declaration_types", raw["decltuple"], seen)
    local vars = raw["vars"] as {any} -- cast: declaration variable list
    local tuple = map_of(raw["decltuple"])["tuple"]
    if tuple is {any} then
      for i, var in ipairs(vars) do
        collect_type(snapshot, var as Node, "declared_type", tuple[i], {}) -- cast: parser node
      end
    end
  elseif node.kind == "local_type" or node.kind == "global_type" then
    local value = raw["value"]
    if value is {any: any} then
      collect_type(snapshot, node, "type_value", value["newtype"], seen)
    end
  elseif node.kind == "cast" then
    collect_type(snapshot, node, "cast_target", raw["casttype"], seen)
  end
  if node.kind == "function" or node.kind == "local_function"
  or node.kind == "global_function" or node.kind == "record_function"
  or node.kind == "macroexp" then
    collect_type(snapshot, node, "return_types", raw["rets"], seen)
    add_generic(snapshot, node, "generic_parameters", raw["typeargs"])
    local args = raw["typeargs"]
    if args is {any} then
      for i, typearg in ipairs(args) do
        collect_type(snapshot, node, "generic_parameter[" .. i .. "]", typearg, seen)
      end
    end
  end
  local attribute = raw["attribute"]
  local ay, ax = raw["attribute_y"], raw["attribute_x"]
  local aey, aex = raw["attribute_yend"], raw["attribute_xend"]
  if attribute is string and ay is integer and ax is integer
  and aey is integer and aex is integer then
    local range = position.from_positions(snapshot.line_starts, #snapshot.source + 1,
      ay, ax, aey, aex)
    snapshot.owned_ranges[range] = true
    snapshot.attributes[#snapshot.attributes + 1] = {
      owner = node, role = "attribute", name = attribute,
      range = range,
    }
  end
end

local record TokenIndex
  starts: {string: integer}
  ends: {string: integer}
  closes: {integer: integer}
end

local record OpenToken
  token: string
  index: integer
end

local function position_key(y: integer, x: integer): string
  return y .. ":" .. x
end

local function token_index(tokens: {tl.Token}): TokenIndex
  local out: TokenIndex = {starts = {}, ends = {}, closes = {}}
  local stack: {OpenToken} = {}
  for i, token in ipairs(tokens) do
    out.starts[position_key(token.y, token.x)] = i
    out.ends[position_key(token.y, token.x + #token.tk - 1)] = i
    if token.tk == "(" or token.tk == "[" or token.tk == "{" then
      stack[#stack + 1] = {token = token.tk, index = i}
    elseif token.tk == ")" or token.tk == "]" or token.tk == "}" then
      local open = stack[#stack]
      local expected = token.tk == ")" and "(" or token.tk == "]" and "[" or "{"
      if open and open.token == expected then
        out.closes[open.index] = i
        stack[#stack] = nil
      end
    end
  end
  return out
end

local function token_owned(snapshot: Snapshot, index: TokenIndex, node: Node): Range | nil
  local i = index.starts[position_key(node.y, node.x)]
  local token = i and snapshot.tokens[i] or nil
  if not token or (node.tk and node.tk ~= token.tk) then return nil end
  return position.from_positions(snapshot.line_starts, #snapshot.source + 1,
    token.y, token.x, token.y, token.x + #token.tk - 1)
end

local function index_parents(snapshot: Snapshot)
  local seen: {Node: boolean} = {[snapshot.node] = true}
  snapshot.roles[snapshot.node] = "root"
  local function descend(node: Node)
    for _, child in ipairs(children_mod.children(node)) do
      if not seen[child.node] then
        seen[child.node] = true
        snapshot.parents[child.node] = node
        snapshot.roles[child.node] = child.role
        descend(child.node)
      end
    end
  end
  descend(snapshot.node)
end

local function ranges_by_owner(snapshot: Snapshot): {Node: {Range}}
  local out: {Node: {Range}} = {}
  local function add(owner: Node, range: Range)
    local list = out[owner]
    if not list then list = {}; out[owner] = list end
    list[#list + 1] = range
  end
  for _, typ in ipairs(snapshot.types) do add(typ.owner, typ.range) end
  for _, attr in ipairs(snapshot.attributes) do add(attr.owner, attr.range) end
  for _, generic in ipairs(snapshot.generics) do add(generic.owner, generic.range) end
  return out
end

local function include(first: Range | nil, last: Range | nil,
    extra: Range): Range, Range
  if not first or extra.start_byte < first.start_byte then first = extra end
  if not last or extra.end_byte > last.end_byte then last = extra end
  return first, last
end

local function index_nodes(snapshot: Snapshot, index: TokenIndex)
  local seen: {Node: boolean} = {}
  local owned = ranges_by_owner(snapshot)
  local function build(node: Node): Range | nil
    if seen[node] then return snapshot.ranges[node] end
    seen[node] = true
    if not children_mod.is_known(node) then return nil end
    local first = token_owned(snapshot, index, node)
    local last = first
    local children = children_mod.children(node)
    if node.kind == "statements" and #children == 0 then
      local at = position.offset(snapshot.line_starts, node.y, node.x,
        #snapshot.source + 1)
      first = {start_byte = at, end_byte = at}; last = first
    end
    for _, child in ipairs(children) do
      local cr = build(child.node)
      if cr then first, last = include(first, last, cr) end
    end
    local extras = owned[node]
    if extras then
      for _, extra in ipairs(extras) do first, last = include(first, last, extra) end
    end
    local first_i = index.starts[position_key(node.y, node.x)]
    local back = (node.kind == "local_type" or node.kind == "global_type") and 2 or 1
    if first_i and (node.kind == "local_declaration" or node.kind == "local_type"
      or node.kind == "global_declaration" or node.kind == "global_type") then
      local keyword = snapshot.tokens[first_i - back]
      if keyword and (keyword.tk == "local" or keyword.tk == "global") then
        first = position.from_positions(snapshot.line_starts, #snapshot.source + 1,
          keyword.y, keyword.x, keyword.y, keyword.x + #keyword.tk - 1)
      end
    elseif first_i and node.kind == "goto" and snapshot.tokens[first_i + 1] then
      local token = snapshot.tokens[first_i + 1]
      last = position.from_positions(snapshot.line_starts, #snapshot.source + 1,
        token.y, token.x, token.y, token.x + #token.tk - 1)
    elseif first_i and node.kind == "label" and snapshot.tokens[first_i + 2]
    and snapshot.tokens[first_i + 2].tk == "::" then
      local token = snapshot.tokens[first_i + 2]
      last = position.from_positions(snapshot.line_starts, #snapshot.source + 1,
        token.y, token.x, token.y, token.x + #token.tk - 1)
    end
    if first_i and node.kind == "paren" then
      local close_i = index.closes[first_i]
      if close_i then
        local token = snapshot.tokens[close_i]
        last = position.from_positions(snapshot.line_starts, #snapshot.source + 1,
          token.y, token.x, token.y, token.x)
      end
    end
    local yend, xend = node.yend, node.xend
    local end_i = yend and xend and index.ends[position_key(yend, xend)] or nil
    local owns_end = node.kind == "if" or node.kind == "while" or node.kind == "do"
    or node.kind == "repeat" or node.kind == "forin" or node.kind == "fornum"
    or node.kind == "function" or node.kind == "local_function"
    or node.kind == "global_function" or node.kind == "record_function"
    or node.kind == "macroexp" or node.kind == "local_macroexp"
    or node.kind == "literal_table" or node.kind == "argument_list"
    or node.kind == "paren"
    local end_token = end_i and snapshot.tokens[end_i] or nil
    local closes_list = end_token and (end_token.tk == ")" or end_token.tk == "]"
      or end_token.tk == "}")
    if end_i and (owns_end or closes_list) then
      local token = snapshot.tokens[end_i]
      last = position.from_positions(snapshot.line_starts, #snapshot.source + 1,
        token.y, token.x, token.y, token.x + #token.tk - 1)
    end
    if node == snapshot.node then
      first = {start_byte = 1, end_byte = #snapshot.source + 1}; last = first
    end
    if first and last then
      local result = {start_byte = first.start_byte, end_byte = last.end_byte}
      snapshot.ranges[node] = result
      snapshot.owned_ranges[result] = true
      return result
    end
    return nil
  end
  build(snapshot.node)
end

local function issues_of(errors: {tl.Error}, phase: Phase, starts: {integer},
    text: string): {Issue}
  local issues: {Issue} = {}
  for _, err in ipairs(errors) do
    local line, column = err.y or 0, err.x or 0
    local at = position.offset(starts, line, column, #text + 1)
    issues[#issues + 1] = {phase = phase, message = err.msg or (phase .. " error"),
      line = line, column = column, range = {start_byte = at, end_byte = at}}
  end
  return issues
end

local function clone_tokens(tokens: {tl.Token}): {tl.Token}
  local out: {tl.Token} = {}
  for i, token in ipairs(tokens) do
    out[i] = {x = token.x, y = token.y, tk = token.tk, kind = token.kind,
      comments = token.comments}
  end
  return out
end

local function inspect(text: string, name: string, lang?: string): ParseResult
  local language, starts = detect_lang(name, lang), position.line_starts(text)
  local tokens, lex_errors = tl.lex(text, name)
  local issues = issues_of(lex_errors, "lex", starts, text)
  if #issues > 0 then return {snapshot = nil, issues = issues} end
  local parse_errors: {tl.Error} = {}
  local ast = tl.parse_program(clone_tokens(tokens), parse_errors, name, language) as Node -- cast: parser AST
  issues = issues_of(parse_errors, "parse", starts, text)
  if #issues > 0 then return {snapshot = nil, issues = issues} end
  local snapshot: Snapshot = {
    source = text, name = name, lang = language,
    id = hash.sha256_hex(name .. "\0" .. language .. "\0" .. text),
    node = ast, tokens = tokens, line_starts = starts, issues = issues,
    parents = {}, roles = {}, ranges = {}, owned_ranges = {},
    types = {}, attributes = {}, generics = {},
  }
  index_parents(snapshot)
  local function own(node: Node) index_owned_syntax(snapshot, node) end
  local function traverse(node: Node)
    own(node)
    for _, child in ipairs(children_mod.children(node)) do traverse(child.node) end
  end
  traverse(ast)
  index_nodes(snapshot, token_index(tokens))
  return {snapshot = snapshot, issues = issues}
end

local function parse(text: string, name: string, lang?: string): Snapshot | nil, string
  local result = inspect(text, name, lang)
  if result.snapshot then return result.snapshot, nil end
  local issue = result.issues[1]
  if not issue then return nil, name .. ": parse failed" end
  return nil, string.format("%s:%d:%d: %s", name, issue.line, issue.column,
    issue.message)
end

local function range(snapshot: Snapshot, node: Node): Range | nil, string
  local found = snapshot.ranges[node]
  if found then return found, nil end
  return nil, "unsupported or foreign syntax node"
end

local function range_bytes(snapshot: Snapshot, start_byte: integer,
    end_byte: integer): Range | nil, string
  if start_byte < 1 or end_byte < start_byte or end_byte > #snapshot.source + 1 then
    return nil, "range must be within the snapshot's 1-based half-open byte bounds"
  end
  local result = {start_byte = start_byte, end_byte = end_byte}
  snapshot.owned_ranges[result] = true
  return result, nil
end

local function parent(snapshot: Snapshot, node: Node): Node | nil
  return snapshot.parents[node]
end

local function role(snapshot: Snapshot, node: Node): string
  return snapshot.roles[node] or ""
end

local function type_syntax(snapshot: Snapshot, owner: Node,
    wanted_role?: string): TypeSyntax | nil
  for _, typ in ipairs(snapshot.types) do
    if typ.owner == owner and (not wanted_role or typ.role == wanted_role) then return typ end
  end
  return nil
end

local record SourceModule
  type Node = Node
  type Range = Range
  type Phase = Phase
  type Issue = Issue
  type TypeSyntax = TypeSyntax
  type AttributeSyntax = AttributeSyntax
  type GenericSyntax = GenericSyntax
  type Snapshot = Snapshot
  type ParseResult = ParseResult
  inspect: function(text: string, name: string, lang?: string): ParseResult
  parse: function(text: string, name: string, lang?: string): Snapshot | nil, string
  range: function(snapshot: Snapshot, node: Node): Range | nil, string
  range_bytes: function(snapshot: Snapshot, start_byte: integer,
  end_byte: integer): Range | nil, string
  parent: function(snapshot: Snapshot, node: Node): Node | nil
  role: function(snapshot: Snapshot, node: Node): string
  type_syntax: function(snapshot: Snapshot, owner: Node,
  wanted_role?: string): TypeSyntax | nil
end

local M: SourceModule = {inspect = inspect, parse = parse, range = range,
  range_bytes = range_bytes,
  parent = parent, role = role, type_syntax = type_syntax}
return M
