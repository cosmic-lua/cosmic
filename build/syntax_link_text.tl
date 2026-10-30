--- The links of a source's comments, read off the new syntax tree: the part of [`build.link_text`] that reads a Teal
--- source rather than prose. [`build.link_text`] finds the links in a text and keeps the text rules; this module reads
--- the comments of a tree ([`lang.lexer`]'s tokens carry them), what the file declares where each comment stands, and
--- the links the build records of a source ([`SyntaxLinkText.found`]).
---
--- It replaced the functions [`build.link_text`] had for the fork's tree and tokens ([`comments_of`],
--- `teal_comments`, `declarations`, `found`). What a comment sees is the same: the
--- names its top-level block binds, those a nested block binds where Lua has them in scope, and each function by its
--- path and each top-level type's members. A class is read as the record and the `function R:m()` methods the fork's
--- source wrote.
local Ast = require("lang.ast")
local Lexical = require("build.syntax_scopes")
local LinkText = require("build.link_text")
local Lexer = require("lang.lexer")
local Node = require("build.syntax_node")
local Scopes = require("lang.scopes")

local record SyntaxLinkText
  --- The line comments `tokens` carry, in the order of their lines, markers taken off. A source that does not parse has
  --- its comments too ([`lang.lexer`] lexes whatever it is given).
  comments_of: function(tokens: Lexer.Tokens): {LinkText.Comment}

  --- What `chunk` declares where each of its comments stands, and what it declares at its top level and nowhere else;
  --- `scoped` is the resolution of its names ([`Node.scope`]). See [`build.link_text`]'s `declarations`.
  declarations: function(chunk: Ast.Chunk, scoped: Scopes.Scoped): LinkText.Declarations

  --- The links of `source`'s comments, `chunk` its tree, as the build records them: every link but a definition,
  --- whose target a reference link carries.
  found: function(chunk: Ast.Chunk, scoped: Scopes.Scoped, source: string): {LinkText.Found}
end

function SyntaxLinkText.comments_of(tokens: Lexer.Tokens): {LinkText.Comment}
  local comments: mut {LinkText.Comment} = {}
  for token = 1, #tokens.kind do
    for _, comment in ipairs(tokens.comments[token] or {}) do
      local text = comment.text
      local body = text:gsub("^%-%-+", "")
      local gone = #text - #body
      comments[#comments + 1] = { line = comment.y, lines = { body }, doc = text:match("^%-%-%-") ~= nil,
        column = comment.x + gone, starts = { comment.offset + gone } }
    end
  end
  table.sort(comments, function(a: LinkText.Comment, b: LinkText.Comment): boolean
    return a.line < b.line
  end)
  return comments
end

--- The names a type declaration's members declare, spelled in full under `prefix` and, for a type or a function, by
--- their own names: `declare(name, top, scoped)` is the declaration of a name that `scoped` says a scope holds.
local function declare_members(prefix: string, members: {Ast.Member}, depth: integer,
                               declare: function(name: string, top: boolean, scoped: boolean))
  if depth > 16 then
    return
  end
  for _, member in ipairs(members) do
    local declared = Node.declared(member)
    if (member.kind == "FieldDecl") then
      local name = member.name.name
      declare(prefix .. "." .. name, true, false)
      local field_type = member.type
      if name:sub(1, 2) ~= "__" then
        declare(name, (field_type.kind == "TypeFunction"), false)
      end
    elseif (member.kind == "Method") then
      declare(prefix .. "." .. member.name.name, true, false)
      declare(member.name.name, true, false)
    elseif declared ~= nil then
      local name = declared.name.name
      declare(prefix .. "." .. name, true, false)
      declare(name, true, false)
      if (member.kind == "Record") or (member.kind == "Interface") or (member.kind == "Class") then
        declare_members(prefix .. "." .. name, member.members, depth + 1, declare)
      elseif (member.kind == "Enum") then
        for _, value in ipairs(member.values) do
          declare(prefix .. "." .. name .. "." .. value.value, true, false)
        end
      end
    end
  end
end

function SyntaxLinkText.declarations(chunk: Ast.Chunk, scoped: Scopes.Scoped): LinkText.Declarations
  -- `names` holds what no scope does; `top` and `inner` say where each name is declared, for `module_level`.
  local names: mut {string: boolean} = {}
  local top: mut {string: boolean} = {}
  local inner: mut {string: boolean} = {}
  local function declare(name: string, at_top: boolean, scope_held: boolean)
    if name == "" then
      return
    end
    if not scope_held then
      names[name] = true
    end
    if at_top then
      top[name] = true
    else
      inner[name] = true
    end
  end
  -- A statement of the chunk's own block is at the top; one nested in a body is not.
  local at_top: mut {integer: boolean} = {}
  for _, stat in ipairs(chunk.body.stats) do
    at_top[Node.base(stat).id] = true
  end
  for _, stat in ipairs(chunk.body.stats) do
    local declared = Node.declared(stat)
    if declared ~= nil and declared.scope ~= "global" then
      if (stat.kind == "Record") or (stat.kind == "Interface") or (stat.kind == "Class") then
        declare_members(declared.name.name, stat.members, 0, declare)
      elseif (stat.kind == "Enum") then
        for _, value in ipairs(stat.values) do
          declare(declared.name.name .. "." .. value.value, true, false)
        end
      end
    end
  end
  Node.walk(chunk.body, function(node: Ast.Node)
    local here = at_top[Node.base(node).id] == true
    if (node.kind == "Local") then
      for _, binding in ipairs(node.bindings) do
        declare(binding.name, false, true)
      end
    elseif (node.kind == "LocalFunction") then
      declare(node.name.name, here, true)
    elseif (node.kind == "Function") then
      local path: mut {string} = {}
      for i, name in ipairs(node.path) do
        path[i] = name.text
      end
      declare(table.concat(path, "."), here, false)
      local last = path[#path]
      if last ~= nil then declare(last, here, false) end
    elseif (node.kind == "ForNum") then
      declare(node.var.name, false, true)
    elseif (node.kind == "ForIn") then
      for _, var in ipairs(node.vars) do
        declare(var.name, false, true)
      end
    elseif (node.kind == "Param") then
      -- A parameter is held by its scope; only a typed one is looked for.
      local param = node.name
      if param ~= nil and (node.type ~= nil or node.optional) then
        declare(param.name, false, true)
      end
    elseif (node.kind == "PType") then
      local param = node.name
      if param ~= nil then
        declare(param, false, true)
      end
    else
      local declared = Node.declared(node)
      if declared ~= nil and declared.scope == "local" then
        declare(declared.name.name, here and not ((node.kind == "Import")), true)
      end
    end
  end)
  -- The words a comment is read at: the token each comment's line stands before, and whether it is a doc comment's.
  local before: mut {integer: integer} = {}
  local doc: mut {integer: boolean} = {}
  for token = 1, #chunk.tokens.kind do
    for _, comment in ipairs(chunk.tokens.comments[token] or {}) do
      before[comment.y] = token
      doc[comment.y] = comment.text:match("^%-%-%-") ~= nil
    end
  end
  local module_level: mut {string: boolean} = {}
  for name in pairs(top) do
    if inner[name] == nil then
      module_level[name] = true
    end
  end
  local bindings: mut {{Lexical.Binding}} = {}
  -- What every comment sees: `names`, the top-level block's bindings, and its aliases, the first binding of each name
  -- deciding before a later one is in scope.
  local everywhere: mut {string: boolean} = {}
  local top_aliases: mut {string: string} = {}
  local function held(): {Lexical.Binding}
    local found = bindings[1]
    if found == nil then
      found = Lexical.bindings_of(chunk, scoped)
      bindings[1] = found
      for _, each in ipairs(found) do
        if each.top and everywhere[each.name] == nil then
          everywhere[each.name] = true
          if each.module ~= "" then
            top_aliases[each.name] = each.module
          end
        end
      end
      for name in pairs(names) do
        everywhere[name] = true
      end
    end
    return found
  end
  local seen: mut {integer: LinkText.Declared} = {}
  local function at(line: integer): LinkText.Declared
    local token = before[line]
    local y, x = line, 0
    if token ~= nil then
      y, x = Lexer.y(chunk.tokens, token), Lexer.x(chunk.tokens, token)
    end
    local doc_line = doc[line] == true
    local place = Lexical.position(y, x) * 2
    if doc_line then
      place = place + 1
    end
    local known = seen[place]
    if known ~= nil then
      return known
    end
    local in_scope = Lexical.in_scope(held(), y, x, doc_line)
    local here: mut {string: boolean} = setmetatable({}, { __index = everywhere })
    local aliases: mut {string: string} = {}
    -- A name bound here is no alias of the top level's, whatever it is bound to.
    for name, module in pairs(top_aliases) do
      if in_scope[name] == nil then
        aliases[name] = module
      end
    end
    for name, module in pairs(in_scope) do
      here[name] = true
      if module ~= "" then
        aliases[name] = module
      end
    end
    known = { names = here, aliases = aliases }
    seen[place] = known
    return known
  end
  return { at = at, module_level = module_level }
end

function SyntaxLinkText.found(chunk: Ast.Chunk, scoped: Scopes.Scoped, source: string): {LinkText.Found}
  local out: mut {LinkText.Found} = {}
  if not LinkText.may_link(source) then
    return out
  end
  local comments = SyntaxLinkText.comments_of(chunk.tokens)
  local doc: mut {integer: boolean} = {}
  local column: mut {integer: integer} = {}
  for _, comment in ipairs(comments) do
    doc[comment.line] = comment.doc
    local at = comment.column
    if at ~= nil then column[comment.line] = at end
  end
  local known: mut {LinkText.Declarations} = {}
  local function declared(line: integer): LinkText.Declared
    local found = known[1] or SyntaxLinkText.declarations(chunk, scoped)
    known[1] = found
    return found.at(line)
  end
  for _, link in ipairs(LinkText.in_blocks(LinkText.blocks_of(comments))) do
    if link.form ~= "definition" then
      local own, alias = false, ""
      local named = LinkText.name_of(link.target)
      if named ~= nil then
        local path = named:gsub(":", ".")
        local here = declared(link.line)
        own = here.names[path] == true
        local first = path:match("^([%a_][%w_]*)%.")
        if first ~= nil then
          alias = here.aliases[first] or ""
        end
      end
      -- The link's column in its file, not in its comment's text.
      local placed: LinkText.Link = { line = link.line, column = link.column + (column[link.line] or 1) - 1,
        form = link.form, text = link.text, target = link.target, label = link.label }
      out[#out + 1] = { link = placed, doc = doc[link.line] == true, own = own, alias = alias }
    end
  end
  return out
end

return SyntaxLinkText
