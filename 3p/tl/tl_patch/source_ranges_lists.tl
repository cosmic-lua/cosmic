-- Parsed type-list, body, and declaration source ranges.
return {
  ["source-range-type-list"] = {
    file = "tl.lua",
    note = "parsed type lists retain exact source ownership without the leading colon",
    find = [=====[   parse_type_list = function(ps, i, mode)
      local t, list = new_tuple(ps, i)

      local first_token = ps.tokens[i].tk
]=====],
    replace = [=====[   parse_type_list = function(ps, i, mode)
      local t, list = new_tuple(ps, i)

      local first_token = ps.tokens[i].tk
]=====],
  },
  ["source-range-type-list-start"] = {
    file = "tl.lua",
    note = "type list range starts after its declaration colon",
    find = [=====[            i = i + 1
         else
            return i, t
         end
      end

      local optional_paren = false
]=====],
    replace = [=====[            i = i + 1
         else
            return i, t
         end
      end

      local source_start = i
      local optional_paren = false
]=====],
  },
  ["source-range-type-list-return"] = {
    file = "tl.lua",
    note = "type list range includes its optional parentheses and ellipsis",
    find = [=====[      if optional_paren then
         i = verify_tk(ps, i, ")")
      end

      return i, t
   end
]=====],
    replace = [=====[      if optional_paren then
         i = verify_tk(ps, i, ")")
      end

      if #list > 0 then source_range(ps, source_start, i, t) end
      return i, t
   end
]=====],
  },
  ["source-range-type-list-tl-tl"] = {
    file = "tl.tl",
    note = "parsed type lists retain exact source ownership without the leading colon",
    find = [=====[   local optional_paren = false
   if ps.tokens[i].tk == "(" then
]=====],
    replace = [=====[   local source_start = i
   local optional_paren = false
   if ps.tokens[i].tk == "(" then
]=====],
  },
  ["source-range-type-list-return-tl-tl"] = {
    file = "tl.tl",
    note = "type list range includes its optional parentheses and ellipsis",
    find = [=====[   if optional_paren then
      i = verify_tk(ps, i, ")")
   end

   return i, t
end
]=====],
    replace = [=====[   if optional_paren then
      i = verify_tk(ps, i, ")")
   end

   if #list > 0 then source_range(ps, source_start, i, t) end
   return i, t
end
]=====],
  },
  ["source-range-typearg"] = {
    file = "tl.lua",
    note = "generic parameters retain names and constraint ranges",
    find = [=====[   local function parse_typearg(ps, i)
      local name = ps.tokens[i].tk
]=====],
    replace = [=====[   local function parse_typearg(ps, i)
      local istart = i
      local name = ps.tokens[i].tk
]=====],
  },
  ["source-range-typearg-return"] = {
    file = "tl.lua",
    note = "generic parameters retain names and constraint ranges",
    find = [=====[      t.typearg = name
      t.constraint = constraint
      return i, t
   end
]=====],
    replace = [=====[      t.typearg = name
      t.constraint = constraint
      return source_range(ps, istart, i, t)
   end
]=====],
  },
  ["source-range-typearg-tl-tl"] = {
    file = "tl.tl",
    note = "generic parameters retain names and constraint ranges",
    find = [=====[local function parse_typearg(ps: ParseState, i: integer): integer, TypeArgType, integer
   local name = ps.tokens[i].tk
]=====],
    replace = [=====[local function parse_typearg(ps: ParseState, i: integer): integer, TypeArgType, integer
   local istart = i
   local name = ps.tokens[i].tk
]=====],
  },
  ["source-range-typearg-return-tl-tl"] = {
    file = "tl.tl",
    note = "generic parameters retain names and constraint ranges",
    find = [=====[   t.typearg = name
   t.constraint = constraint
   return i, t
end
]=====],
    replace = [=====[   t.typearg = name
   t.constraint = constraint
   return source_range(ps, istart, i, t)
end
]=====],
  },
  ["source-range-type-body"] = {
    file = "tl.lua",
    note = "record/interface/enum type bodies retain their owned end token",
    find = [=====[      if typeargs then
         return i, new_generic(ps, istart, typeargs, def)
      end

      return i, def
   end
]=====],
    replace = [=====[      if typeargs then
         return source_range(ps, istart, i, new_generic(ps, istart, typeargs, def))
      end

      return source_range(ps, istart, i, def)
   end
]=====],
  },
  ["source-range-type-body-tl-tl"] = {
    file = "tl.tl",
    note = "record/interface/enum type bodies retain their owned end token",
    find = [=====[   if typeargs then
      return i, new_generic(ps, istart, typeargs, def)
   end

   return i, def
end
]=====],
    replace = [=====[   if typeargs then
      return source_range(ps, istart, i, new_generic(ps, istart, typeargs, def))
   end

   return source_range(ps, istart, i, def)
end
]=====],
  },
  ["source-range-newtype"] = {
    file = "tl.lua",
    note = "type declaration wrapper retains the full type value range",
    find = [=====[      node.newtype = new_typedecl(ps, istart, def)

      if def.typename == "nominal" then
]=====],
    replace = [=====[      node.newtype = new_typedecl(ps, istart, def)
      source_range(ps, istart, i, node.newtype)

      if def.typename == "nominal" then
]=====],
  },
  ["source-range-newtype-tl-tl"] = {
    file = "tl.tl",
    note = "type declaration wrapper retains the full type value range",
    find = [=====[   node.newtype = new_typedecl(ps, istart, def)

   if def is NominalType then
]=====],
    replace = [=====[   node.newtype = new_typedecl(ps, istart, def)
   source_range(ps, istart, i, node.newtype)

   if def is NominalType then
]=====],
  },
  ["source-range-attribute"] = {
    file = "tl.lua",
    note = "variable declaration attributes retain exact angle-bracket ranges",
    find = [=====[      if not node then
         return i
      end
      if ps.tokens[i].tk == "<" then
         i = i + 1
]=====],
    replace = [=====[      if not node then
         return i
      end
      if ps.tokens[i].tk == "<" then
         local attribute_start = i
         i = i + 1
]=====],
  },
  ["source-range-attribute-end"] = {
    file = "tl.lua",
    note = "variable declaration attributes retain exact angle-bracket ranges",
    find = [=====[         i = verify_tk(ps, i, ">")
      end
      return i, node
   end
]=====],
    replace = [=====[         i = verify_tk(ps, i, ">")
         local first = ps.tokens[attribute_start]
         local last = ps.tokens[i - 1]
         node.attribute_y, node.attribute_x = first.y, first.x
         node.attribute_yend, node.attribute_xend = last.y, last.x + #last.tk - 1
      end
      return i, node
   end
]=====],
  },
  ["source-range-attribute-tl-tl"] = {
    file = "tl.tl",
    note = "variable declaration attributes retain exact angle-bracket ranges",
    find = [=====[   if not node then
      return i
   end
   if ps.tokens[i].tk == "<" then
      i = i + 1
]=====],
    replace = [=====[   if not node then
      return i
   end
   if ps.tokens[i].tk == "<" then
      local attribute_start = i
      i = i + 1
]=====],
  },
  ["source-range-attribute-end-tl-tl"] = {
    file = "tl.tl",
    note = "variable declaration attributes retain exact angle-bracket ranges",
    find = [=====[      i = verify_tk(ps, i, ">")
   end
   return i, node
end
]=====],
    replace = [=====[      i = verify_tk(ps, i, ">")
      local first = ps.tokens[attribute_start]
      local last = ps.tokens[i - 1]
      node.attribute_y, node.attribute_x = first.y, first.x
      node.attribute_yend, node.attribute_xend = last.y, last.x + #last.tk - 1
   end
   return i, node
end
]=====],
  },
}
