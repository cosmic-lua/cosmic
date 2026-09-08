-- Exact source ranges for parsed type syntax. Teal's type objects are not
-- expression Nodes, and most of them historically retained only their first
-- token. These parser-owned coordinates let syntax consumers distinguish
-- source annotations from inferred types without reparsing the type grammar.
return {
  ["source-range-helper"] = {
    file = "tl.lua",
    note = "shared syntax snapshots need exact parser-owned type ranges",
    find = [=====[   local function end_at(node, tk)
      node.yend = tk.y
      node.xend = tk.x + #tk.tk - 1
   end
]=====],
    replace = [=====[   local function end_at(node, tk)
      node.yend = tk.y
      node.xend = tk.x + #tk.tk - 1
   end

   -- cosmic carried patch: exact inclusive source coordinates for type
   -- syntax. `after_i` is the parser cursor immediately after the range.
   local function source_range(ps, first_i, after_i, value)
      if value and after_i > first_i then
         local first = ps.tokens[first_i]
         local last = ps.tokens[after_i - 1]
         value.syntax_y = first.y
         value.syntax_x = first.x
         value.syntax_yend = last.y
         value.syntax_xend = last.x + #last.tk - 1
      end
      return after_i, value
   end
]=====],
  },
  ["source-range-type-interface"] = {
    file = "tl.tl",
    note = "shared syntax snapshots need typed parser-owned type ranges",
    find = [=====[   typename: TypeName    -- discriminator
   typeid: integer       -- unique identifier
   inferred_at: Where    -- for error messages
]=====],
    replace = [=====[   typename: TypeName    -- discriminator
   typeid: integer       -- unique identifier
   inferred_at: Where    -- for error messages

   -- cosmic carried patch: inclusive source coordinates exist only on
   -- parsed type syntax; inferred/synthetic types leave these absent.
   syntax_y: integer
   syntax_x: integer
   syntax_yend: integer
   syntax_xend: integer
]=====],
  },
  ["source-range-helper-tl-tl"] = {
    file = "tl.tl",
    note = "shared syntax snapshots need exact parser-owned type ranges",
    find = [=====[local function end_at(node: Node, tk: Token)
   node.yend = tk.y
   node.xend = tk.x + #tk.tk - 1
end
]=====],
    replace = [=====[local function end_at(node: Node, tk: Token)
   node.yend = tk.y
   node.xend = tk.x + #tk.tk - 1
end

-- cosmic carried patch: exact inclusive source coordinates for type
-- syntax. `after_i` is the parser cursor immediately after the range.
local function source_range(ps: ParseState, first_i: integer, after_i: integer,
   value: any): integer, any
   if value and after_i > first_i then
      local first = ps.tokens[first_i]
      local last = ps.tokens[after_i - 1]
      value.syntax_y = first.y
      value.syntax_x = first.x
      value.syntax_yend = last.y
      value.syntax_xend = last.x + #last.tk - 1
   end
   return after_i, value
end
]=====],
  },
  ["source-range-angle-list"] = {
    file = "tl.lua",
    note = "generic syntax owns exact angle brackets including nested closers",
    find = [=====[   local function parse_anglebracket_list(ps, i, parse_item)
      local second = ps.tokens[i + 1]
      if second.tk == ">" then
         return fail(ps, i + 1, "type argument list cannot be empty")
      elseif second.tk == ">>" then

         second.tk = ">"
         fail(ps, i + 1, "type argument list cannot be empty")
         return i + 1
      end

      local types = {}
      i = verify_tk(ps, i, "<")
      i = parse_list(ps, i, types, { [">"] = true, [">>"] = true }, "sep", parse_item)
      if ps.tokens[i].tk == ">" then
         i = i + 1
      elseif ps.tokens[i].tk == ">>" then

         ps.tokens[i].tk = ">"
      else
         return fail(ps, i, "syntax error, expected '>'")
      end
      return i, types
   end
]=====],
    replace = [=====[   local function parse_anglebracket_list(ps, i, parse_item)
      local istart = i
      local second = ps.tokens[i + 1]
      if second.tk == ">" then
         return fail(ps, i + 1, "type argument list cannot be empty")
      elseif second.tk == ">>" then

         second.tk = ">"
         fail(ps, i + 1, "type argument list cannot be empty")
         return i + 1
      end

      local types = {}
      i = verify_tk(ps, i, "<")
      i = parse_list(ps, i, types, { [">"] = true, [">>"] = true }, "sep", parse_item)
      if ps.tokens[i].tk == ">" then
         i = i + 1
      elseif ps.tokens[i].tk == ">>" then

         -- cosmic carried patch: retain both source positions instead of
         -- mutating `>>` into one `>` at the first generic close.
         local both = ps.tokens[i]
         both.tk = ">"
         table.insert(ps.tokens, i + 1, {
            y = both.y, x = both.x + 1, tk = ">", kind = both.kind,
         })
         i = i + 1
      else
         return fail(ps, i, "syntax error, expected '>'")
      end
      source_range(ps, istart, i, types)
      return i, types
   end
]=====],
  },
  ["source-range-angle-list-tl-tl"] = {
    file = "tl.tl",
    note = "generic syntax owns exact angle brackets including nested closers",
    find = [=====[local function parse_anglebracket_list<T is Type>(ps: ParseState, i: integer, parse_item: ParseItem<T>): integer, {T}
   local second = ps.tokens[i+1]
]=====],
    replace = [=====[local function parse_anglebracket_list<T is Type>(ps: ParseState, i: integer, parse_item: ParseItem<T>): integer, {T}
   local istart = i
   local second = ps.tokens[i+1]
]=====],
  },
  ["source-range-angle-close-tl-tl"] = {
    file = "tl.tl",
    note = "generic syntax owns exact nested closer positions",
    find = [=====[   elseif ps.tokens[i].tk == ">>" then
      -- tokenizer hack: consume one bracket from '>>', don't increment i
      ps.tokens[i].tk = ">"
   else
      return fail(ps, i, "syntax error, expected '>'")
   end
   return i, types
end
]=====],
    replace = [=====[   elseif ps.tokens[i].tk == ">>" then
      -- cosmic carried patch: retain both source positions instead of
      -- mutating `>>` into one `>` at the first generic close.
      local both = ps.tokens[i]
      both.tk = ">"
      table.insert(ps.tokens, i + 1, {
         y = both.y, x = both.x + 1, tk = ">", kind = both.kind,
      })
      i = i + 1
   else
      return fail(ps, i, "syntax error, expected '>'")
   end
   source_range(ps, istart, i, types)
   return i, types
end
]=====],
  },
  ["source-range-type"] = {
    file = "tl.lua",
    note = "parsed type objects retain exact source ownership",
    find = [=====[   parse_type = function(ps, i)
      if ps.tokens[i].tk == "(" then
         i = i + 1
         local t
         i, t = parse_type(ps, i)
         i = verify_tk(ps, i, ")")
         return i, t
      end

      local bt
      local istart = i
      i, bt = parse_base_type(ps, i)
      if not bt then
         return i
      end
      if ps.tokens[i].tk == "|" then
         local u = new_type(ps, istart, "union")
         u.types = { bt }
         while ps.tokens[i].tk == "|" do
            i = i + 1
            i, bt = parse_base_type(ps, i)
            if not bt then
               return i
            end
            table.insert(u.types, bt)
         end
         bt = u
      end
      return i, bt
   end
]=====],
    replace = [=====[   parse_type = function(ps, i)
      local istart = i
      if ps.tokens[i].tk == "(" then
         i = i + 1
         local t
         i, t = parse_type(ps, i)
         i = verify_tk(ps, i, ")")
         return source_range(ps, istart, i, t)
      end

      local bt
      i, bt = parse_base_type(ps, i)
      if not bt then
         return i
      end
      if ps.tokens[i].tk == "|" then
         local u = new_type(ps, istart, "union")
         u.types = { bt }
         while ps.tokens[i].tk == "|" do
            i = i + 1
            i, bt = parse_base_type(ps, i)
            if not bt then
               return i
            end
            table.insert(u.types, bt)
         end
         bt = u
      end
      return source_range(ps, istart, i, bt)
   end
]=====],
  },
  ["source-range-type-tl-tl"] = {
    file = "tl.tl",
    note = "parsed type objects retain exact source ownership",
    find = [=====[parse_type = function(ps: ParseState, i: integer): integer, FirstClassType, integer
   if ps.tokens[i].tk == "(" then
]=====],
    replace = [=====[parse_type = function(ps: ParseState, i: integer): integer, FirstClassType, integer
   local istart = i
   if ps.tokens[i].tk == "(" then
]=====],
  },
  ["source-range-type-return-tl-tl"] = {
    file = "tl.tl",
    note = "parsed type objects retain exact source ownership",
    find = [=====[      i = verify_tk(ps, i, ")")
      return i, t
   end

   local bt: FirstClassType
   local istart = i
]=====],
    replace = [=====[      i = verify_tk(ps, i, ")")
      return source_range(ps, istart, i, t)
   end

   local bt: FirstClassType
]=====],
  },
  ["source-range-type-final-tl-tl"] = {
    file = "tl.tl",
    note = "parsed type objects retain exact source ownership",
    find = [=====[   return i, bt
end

parse_type_list = function(ps: ParseState, i: integer, mode: ParseTypeListMode): integer, TupleType
]=====],
    replace = [=====[   return source_range(ps, istart, i, bt)
end

parse_type_list = function(ps: ParseState, i: integer, mode: ParseTypeListMode): integer, TupleType
]=====],
  },
}
