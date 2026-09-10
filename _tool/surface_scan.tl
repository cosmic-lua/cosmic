--- Lex record fields and enum values without resolving names or modules.
--- Syntax validation uses Teal's parser; type spans use _cli.returns.
local tl = require("tl")
local returns = require("_cli.returns")
local literal = require("cosmic.literal")
local url = require("cosmic.url")

local type Token = tl.Token

--- One declaration member, in source order. Nested owners are dotted.
local record Member
  kind: string
  declaration: string
  name: string
  canonical_type: string
  line: integer
  column: integer
end

local record Scanner
  tokens: {Token}
  members: {Member}
  path: string
  next: integer
end

local function diagnostic(path: string, token: Token, message: string): string
  return string.format("%s:%d:%d: %s", path, token.y, token.x, message)
end

--- Decode data, never execute the token as source.
local function string_value(token: Token): string | nil, string
  local value, err = literal.parse("return {value = " .. token.tk .. "}")
  if not value then
    return nil, err
  end
  local decoded = value.value
  if decoded is string then
    return decoded
  end
  return nil, "expected a string literal"
end

local function append(scanner: Scanner, kind: string, owner: string,
    name: string, canonical_type: string, token: Token)
  scanner.members[#scanner.members + 1] = {
    kind = kind,
    declaration = owner,
    name = name,
    canonical_type = canonical_type,
    line = token.y,
    column = token.x,
  }
end

local body: function(scanner: Scanner, parent: string): boolean, string

--- Consume exactly one record field, including its multiline type.
local function field(scanner: Scanner, owner: string): boolean, string
  local tokens = scanner.tokens
  local i = scanner.next
  if tokens[i].tk == "metamethod" and tokens[i + 1]
  and tokens[i + 1].tk ~= ":" then
    i = i + 1
  end
  local token = tokens[i]
  local name = token.tk
  if token.tk == "[" and tokens[i + 1] and tokens[i + 1].kind == "string"
  and tokens[i + 2] and tokens[i + 2].tk == "]" then
    local decoded, err = string_value(tokens[i + 1])
    if decoded == nil then
      return false, diagnostic(scanner.path, token, err)
    end
    name = decoded
    i = i + 2
  elseif token.kind ~= "identifier" then
    return false, diagnostic(scanner.path, token, "ambiguous record member")
  end
  if not tokens[i + 1] or tokens[i + 1].tk ~= ":" then
    return false, diagnostic(scanner.path, token, "ambiguous record member")
  end
  local first = i + 2
  -- parse_type delegates function returns to the shared parse_list.
  local after = returns.parse_type(tokens, first)
  if after <= first then
    return false, diagnostic(scanner.path, token, "cannot read field type")
  end
  local parts: {string} = {}
  for j = first, after - 1 do
    parts[#parts + 1] = tokens[j].tk
  end
  append(scanner, "record", owner, name, table.concat(parts, " "), token)
  scanner.next = after
  return true
end

--- Consume a declaration and its nested declarations as one body.
body = function(scanner: Scanner, parent: string): boolean, string
  local tokens = scanner.tokens
  local start = tokens[scanner.next]
  local kind = start.tk
  local name = tokens[scanner.next + 1]
  if not name or name.kind ~= "identifier" then
    return false, diagnostic(scanner.path, start, "expected declaration name")
  end
  local owner = parent == "" and name.tk or parent .. "." .. name.tk
  scanner.next = scanner.next + 2
  if tokens[scanner.next] and tokens[scanner.next].tk == "<" then
    scanner.next = returns.skip_balanced(tokens, scanner.next, "<", ">")
    if scanner.next == 0 then
      return false, diagnostic(scanner.path, start, "unbalanced generic parameters")
    end
  end
  if kind == "record" and tokens[scanner.next] and tokens[scanner.next].tk == "is" then
    local slots, after = returns.parse_list(tokens, scanner.next + 1)
    if #slots == 0 then
      return false, diagnostic(scanner.path, start, "cannot read record interfaces")
    end
    scanner.next = after
  end
  while tokens[scanner.next] do
    local token = tokens[scanner.next]
    if token.tk == "end" and token.kind == "keyword" then
      scanner.next = scanner.next + 1
      return true
    elseif token.kind == "$EOF$" then
      break
    elseif kind == "record" and token.tk == "userdata"
    and tokens[scanner.next + 1] and tokens[scanner.next + 1].tk ~= ":" then
      scanner.next = scanner.next + 1
    elseif kind == "enum" then
      if token.kind ~= "string" then
        return false, diagnostic(scanner.path, token, "ambiguous enum value")
      end
      local decoded, err = string_value(token)
      if decoded == nil then
        return false, diagnostic(scanner.path, token, err)
      end
      append(scanner, kind, owner, url.escape_segment(decoded), "enum", token)
      scanner.next = scanner.next + 1
    elseif token.kind == "identifier"
    and (token.tk == "record" or token.tk == "enum")
    and tokens[scanner.next + 1] and tokens[scanner.next + 1].kind == "identifier" then
      local ok, err = body(scanner, owner)
      if not ok then
        return false, err
      end
    else
      local ok, err = field(scanner, owner)
      if not ok then
        return false, err
      end
    end
  end
  return false, diagnostic(scanner.path, start, "missing declaration end")
end

--- Read canonical members, failing atomically on errors or unsupported syntax.
--- @param source string Teal source bytes
--- @param path string Source name for diagnostics
--- @return {Member}|nil Members in source order, or nil on failure
--- @return string Diagnostic on failure
local function scan(source: string, path: string): {Member} | nil, string
  local tokens, errors = tl.lex(source, path)
  if #errors > 0 then
    local err = errors[1]
    return nil, string.format("%s:%d:%d: %s", path, err.y, err.x, err.msg)
  end
  -- Teal's parser edits tokens (notably >>). Validate a second stream
  -- so canonical text still reflects the original token spellings.
  local validation = tl.lex(source, path)
  tl.parse_program(validation, errors, path)
  if #errors > 0 then
    local err = errors[1]
    return nil, string.format("%s:%d:%d: %s", path, err.y, err.x, err.msg)
  end
  local scanner: Scanner = {tokens = tokens, members = {}, path = path, next = 1}
  while scanner.next <= #tokens do
    local i = scanner.next
    local token = tokens[i]
    local previous = tokens[i - 1]
    if token.kind == "identifier" and (token.tk == "record" or token.tk == "enum")
    and previous and (previous.tk == "local" or previous.tk == "global")
    and tokens[i + 1] and tokens[i + 1].kind == "identifier" then
      local ok, err = body(scanner, "")
      if not ok then
        return nil, err
      end
    else
      scanner.next = i + 1
    end
  end
  return scanner.members
end

local record SurfaceScan
  type Member = Member
  scan: function(source: string, path: string): {Member} | nil, string
end

local M: SurfaceScan = {scan = scan}
return M
