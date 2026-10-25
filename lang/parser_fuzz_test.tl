--- Fuzz properties for the new checker's parser ([`lang.parser`]), over three
--- kinds of input. A program drawn from the grammar parses with no error and
--- the same tree every time, and each of its statements, cut out by its
--- tokens, parses alone to the tree it has in place. The same program with a
--- few tokens deleted, repeated or swapped, and any run of tokens of the
--- grammar's vocabulary, parse to a tree over their tokens
--- ([`lang.parser_cover`]) whatever errors they make, and never raise or run
--- past the instruction budget. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).
local Ast = require("lang.ast")
local Cover = require("lang.parser_cover")
local Dump = require("lang.ast_dump")
local Fuzz = require("build.fuzz")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")

local NAMES <const>: {string} = { "a", "b", "c", "x", "y", "t", "f", "g", "n", "self" }
local TYPES <const>: {string} = { "string", "integer", "boolean", "any", "T", "Reader", "Stream.Reader" }
local BINARY <const>: {string} = {
  "or", "and", "<", ">", "<=", ">=", "~=", "==", "|", "~", "&", "<<", ">>", "..", "+", "-", "*", "/", "//", "%", "^",
}

local gen_exp: function(src: Fuzz.Source, depth: integer, out: {string})
local gen_type: function(src: Fuzz.Source, depth: integer, out: {string})
local gen_block: function(src: Fuzz.Source, depth: integer, loop: boolean, out: {string})

local function name(src: Fuzz.Source): string
  return Fuzz.pick(src, NAMES)
end

local function add(out: mut {string}, ...: string)
  for i = 1, select("#", ...) do
    out[#out + 1] = (select(i, ...))
  end
end

--- Between one and `max` of what `item` writes, separated by `,`.
local function gen_list(src: Fuzz.Source, max: integer, out: {string}, item: function(i: integer))
  local n = 0
  while n == 0 or Fuzz.more(src, n, max) do
    if n > 0 then add(out, ",") end
    n = n + 1
    item(n)
  end
end

--- Writes a type that is not a union or an optional. Answers whether `?` and `|` may follow it: a
--- function type takes them into its return list.
local function gen_base_type(src: Fuzz.Source, depth: integer, out: {string}): boolean
  local k = src:int(1, if depth > 0 then 9 else 3 end)
  if k <= 3 then
    add(out, Fuzz.pick(src, TYPES))
  elseif k == 4 then
    add(out, Fuzz.pick(src, TYPES), "<")
    gen_list(src, 3, out, function() gen_type(src, depth - 1, out) end)
    add(out, ">")
  elseif k == 5 then
    add(out, "{")
    gen_type(src, depth - 1, out)
    add(out, "}")
  elseif k == 6 then
    add(out, "{", Fuzz.pick(src, TYPES), ":")
    gen_type(src, depth - 1, out)
    add(out, "}")
  elseif k == 7 then
    add(out, "mut", "{")
    gen_type(src, depth - 1, out)
    add(out, "}")
  elseif k == 8 then
    add(out, "function", "(")
    gen_list(src, 3, out, function(i: integer)
      local form = src:int(1, 4)
      if form == 1 then
        add(out, "p" .. i, ":")
      elseif form == 2 then
        add(out, "p" .. i, "?", ":")
      elseif form == 3 and i == 3 then
        add(out, "...", ":")
      end
      gen_type(src, depth - 1, out)
    end)
    add(out, ")")
    local rets = src:int(1, 5)
    if rets == 2 then
      add(out, ":")
      gen_type(src, depth - 1, out)
    elseif rets == 3 then
      add(out, ":", "(", "true", ",")
      gen_type(src, depth - 1, out)
      add(out, ")", "|", "(", "false", ",")
      gen_type(src, depth - 1, out)
      add(out, ")")
    elseif rets == 4 then
      add(out, ":", "(")
      gen_list(src, 2, out, function() gen_type(src, depth - 1, out) end)
      add(out, ")")
    end
    return false
  else
    add(out, "(", Fuzz.pick(src, TYPES), "|", Fuzz.pick(src, TYPES), ")")
  end
  return true
end

gen_type = function(src: Fuzz.Source, depth: integer, out: {string})
  if not gen_base_type(src, depth, out) then
    return
  end
  if src:int(1, 4) == 1 then
    add(out, "?")
  end
  if src:int(1, 5) == 1 then
    add(out, "|")
    gen_base_type(src, depth - 1, out)
  end
end

local function gen_args(src: Fuzz.Source, depth: integer, out: {string})
  add(out, "(")
  if src:int(1, 3) > 1 then
    gen_list(src, 3, out, function() gen_exp(src, depth - 1, out) end)
  end
  add(out, ")")
end

gen_exp = function(src: Fuzz.Source, depth: integer, out: {string})
  local k = src:int(1, if depth > 0 then 17 else 6 end)
  if k <= 3 then
    add(out, name(src))
  elseif k == 4 then
    add(out, src:int(1, 2) == 1 and tostring(src:int(0, 999)) or src:int(0, 99) .. ".5")
  elseif k == 5 then
    add(out, "\"s\\n\"")
  elseif k == 6 then
    add(out, Fuzz.pick(src, { "nil", "true", "false", "..." }))
  elseif k == 7 then
    gen_exp(src, depth - 1, out)
    add(out, Fuzz.pick(src, BINARY))
    gen_exp(src, depth - 1, out)
  elseif k == 8 then
    add(out, Fuzz.pick(src, { "not", "#", "-", "~" }))
    gen_exp(src, depth - 1, out)
  elseif k == 9 then
    add(out, name(src))
    gen_args(src, depth, out)
  elseif k == 10 then
    add(out, name(src), ":", "m")
    gen_args(src, depth, out)
  elseif k == 11 then
    add(out, name(src), if src:int(1, 2) == 1 then "." else "[" end, "k")
    if out[#out - 1] == "[" then add(out, "]") end
  elseif k == 12 then
    add(out, "{")
    gen_list(src, 3, out, function(i: integer)
      local form = src:int(1, 3)
      if form == 1 then
        add(out, "k" .. i, "=")
      elseif form == 2 then
        add(out, "[", tostring(i), "]", "=")
      end
      gen_exp(src, depth - 1, out)
    end)
    add(out, "}")
  elseif k == 13 then
    add(out, "function", "(", "a", ")", "\n")
    gen_block(src, depth - 1, false, out)
    add(out, "end")
  elseif k == 14 then
    add(out, "if")
    gen_exp(src, depth - 1, out)
    add(out, "then")
    gen_exp(src, depth - 1, out)
    add(out, "else")
    gen_exp(src, depth - 1, out)
    add(out, "end")
  elseif k == 15 then
    add(out, "(")
    gen_exp(src, depth - 1, out)
    add(out, ")")
  elseif k == 16 then
    add(out, "(", name(src), "is")
    gen_base_type(src, depth - 1, out)
    add(out, ")")
  else
    add(out, "(", name(src), "as")
    gen_type(src, depth - 1, out)
    add(out, ")")
  end
end

local function gen_declaration(src: Fuzz.Source, depth: integer, out: {string})
  local k = src:int(1, 6)
  if k <= 2 then
    add(out, "local", if k == 1 then "record" else "interface" end, "R", if src:int(1, 3) == 1 then "<T>" else "" end, "\n")
    for i = 1, src:int(0, 3) do
      add(out, if src:int(1, 3) == 1 then "mut" else "" end, "f" .. i, if src:int(1, 3) == 1 then "?" else "" end, ":")
      gen_type(src, depth - 1, out)
      add(out, "\n")
    end
    add(out, "end")
  elseif k == 3 then
    add(out, "local", "class", "C", "\n", "mut", "count", ":", "integer", "\n")
    for i = 1, src:int(0, 2) do
      add(out, "function", "m" .. i, "(", "self", ",", "a", ":", "integer", ")", ":", "integer", "\n")
      gen_block(src, depth - 1, false, out)
      add(out, "end", "\n")
    end
    add(out, "end")
  elseif k == 4 then
    add(out, "local", "enum", "E", "\"a\"", "\"b\"", "end")
  elseif k == 5 then
    add(out, "local", "type", "A", "=")
    gen_type(src, depth - 1, out)
  else
    add(out, "local", "type", "m", "=", "require", "(", "\"mod\"", ")")
  end
end

local function gen_statement(src: Fuzz.Source, depth: integer, loop: boolean, out: {string})
  local k = src:int(1, if depth > 0 then 17 else 4 end)
  if k == 1 then
    add(out, "local", name(src))
    if src:int(1, 3) == 1 then
      add(out, ":")
      gen_type(src, depth - 1, out)
    end
    add(out, "=")
    gen_exp(src, depth, out)
  elseif k == 2 then
    add(out, name(src), "=")
    gen_exp(src, depth, out)
  elseif k == 3 or k == 4 then
    add(out, name(src))
    gen_args(src, depth, out)
  elseif k == 5 then
    add(out, "do", "\n")
    gen_block(src, depth - 1, loop, out)
    add(out, "end")
  elseif k == 6 then
    add(out, "if")
    gen_exp(src, depth - 1, out)
    add(out, "then", "\n")
    gen_block(src, depth - 1, loop, out)
    if src:int(1, 2) == 1 then
      add(out, "elseif")
      gen_exp(src, depth - 1, out)
      add(out, "then", "\n")
      gen_block(src, depth - 1, loop, out)
    end
    if src:int(1, 2) == 1 then
      add(out, "else", "\n")
      gen_block(src, depth - 1, loop, out)
    end
    add(out, "end")
  elseif k == 7 then
    add(out, "while")
    gen_exp(src, depth - 1, out)
    add(out, "do", "\n")
    gen_block(src, depth - 1, true, out)
    add(out, "end")
  elseif k == 8 then
    add(out, "for", "i", "=", "1", ",", "n", "do", "\n")
    gen_block(src, depth - 1, true, out)
    add(out, "end")
  elseif k == 9 then
    add(out, "for", "k", ",", "v", "in", "pairs", "(", "t", ")", "do", "\n")
    gen_block(src, depth - 1, true, out)
    add(out, "end")
  elseif k == 10 then
    add(out, "repeat", "\n")
    gen_block(src, depth - 1, false, out)
    add(out, "until")
    gen_exp(src, depth - 1, out)
  elseif k == 11 then
    add(out, "local", "function", "h", "(", "a", ":", "integer", ",", "...", ":", "any", ")", ":", "integer", "\n")
    gen_block(src, depth - 1, false, out)
    add(out, "end")
  elseif k == 12 then
    add(out, "function", "R", ".", "m", "(", "a", ")", "\n")
    gen_block(src, depth - 1, false, out)
    add(out, "end")
  elseif k == 13 then
    add(out, "match", "f", "(", ")", "do", "\n")
    for _ = 1, src:int(1, 2) do
      add(out, "|", "(", "true", ",", "v", ")", "then", "\n")
      gen_block(src, depth - 1, loop, out)
    end
    add(out, "end")
  elseif k == 14 and loop then
    add(out, if src:int(1, 2) == 1 then "break" else "continue" end)
  else
    gen_declaration(src, depth, out)
  end
  add(out, "\n")
end

gen_block = function(src: Fuzz.Source, depth: integer, loop: boolean, out: {string})
  local n = 0
  while Fuzz.more(src, n, 4) do
    n = n + 1
    gen_statement(src, depth, loop, out)
  end
  if src:int(1, 8) == 1 then
    add(out, "return")
    if src:int(1, 2) == 1 then
      gen_exp(src, depth - 1, out)
    end
    add(out, "\n")
  end
end

--- A program of the grammar, as the tokens it is written in.
local function gen_program(src: Fuzz.Source): {string}
  local out: {string} = {}
  gen_block(src, 3, false, out)
  return out
end

local function gen_valid(src: Fuzz.Source): string
  return table.concat(gen_program(src), " ")
end

--- Tokens that make the parser meet each of its branches, well and ill placed.
local PIECES <const>: {string} = {
  "local", "function", "end", "if", "then", "else", "elseif", "while", "do", "for", "in", "repeat", "until", "return",
  "break", "continue", "match", "goto", "global", "mut", "is", "as", "userdata", "record", "interface", "class", "enum",
  "type", "require", "x", "y", "self", "T", "1", "2.5", "\"s\"", "[[l]]", "nil", "true", "false", "...", "+", "-", "*",
  "..", "==", "<", ">", ">>", "|", "?", "#", "~", "=", ",", ":", ".", "(", ")", "{", "}", "[", "]", "<const>", "\n",
  "-- c\n", "metamethod", "asserts", ";", "@", "'", "::",
}

local function gen_pieces(src: Fuzz.Source): string
  local out: mut {string} = {}
  while Fuzz.more(src, #out, 60) do
    out[#out + 1] = Fuzz.pick(src, PIECES)
  end
  return table.concat(out, " ")
end

--- A program with a few of its tokens deleted, repeated, swapped or replaced.
local function gen_mutated(src: Fuzz.Source): string
  local tokens = gen_program(src)
  for _ = 1, src:int(1, 3) do
    local n = #tokens
    if n > 0 then
      local at = src:int(1, n)
      local edit = src:int(1, 4)
      if edit == 1 then
        table.remove(tokens, at)
      elseif edit == 2 then
        table.insert(tokens, at, tokens[at])
      elseif edit == 3 and at < n then
        tokens[at], tokens[at + 1] = tokens[at + 1], tokens[at]
      else
        tokens[at] = Fuzz.pick(src, PIECES)
      end
    end
  end
  return table.concat(tokens, " ")
end

local function gen_bytes(src: Fuzz.Source): string
  return Fuzz.bytes(src, 100)
end

local function dialect_of(input: string): Ast.Dialect
  return if #input % 2 == 0 then "tl" else "decl" end
end

local function parse(input: string, dialect: Ast.Dialect): Parser.Parsed
  return Parser.parse(Lexer.lex(input, "f.tl"), "f.tl", dialect)
end

--- Whether parsing `input` as `dialect` makes a tree over its tokens.
local function holds(input: string, dialect: Ast.Dialect): boolean, string
  local parsed = parse(input, dialect)
  local ok, why = Cover.check(input, parsed)
  if not ok then
    return false, why
  end
  Fuzz.label(if #parsed.errors == 0 then "clean" else "refused" end)
  for _, e in ipairs(parsed.errors) do
    Fuzz.label(e.code)
  end
  return true, ""
end

local function test_a_program_of_the_grammar_parses_with_no_error_and_the_same_tree_every_time(tmp: string)
  Fuzz.run({
    name = "parser reads the grammar",
    dir = tmp,
    gen = gen_valid,
    check = function(input: string): boolean, string
      local first = parse(input, "tl")
      local e = first.errors[1]
      if e ~= nil then
        return false, e.code .. " at " .. e.y .. ":" .. e.x .. ": " .. e.msg
      end
      local ok, why = Cover.check(input, first)
      if not ok then
        return false, why
      end
      local before = Dump.dump(first.chunk)
      -- Each statement alone, cut out by its tokens, makes the tree it makes in place.
      local tokens = first.chunk.tokens
      for _, stat in ipairs(first.chunk.body.stats) do
        local base: Ast.Base = stat
        local from, to = base.first, base.last
        local alone = parse(input:sub(Lexer.offset(tokens, from), Lexer.stop(tokens, to) - 1), "tl")
        local one = alone.chunk.body.stats[1]
        if #alone.errors > 0 or #alone.chunk.body.stats ~= 1 or one == nil or Dump.dump(one) ~= Dump.dump(stat) then
          return false, "the statement at " .. tokens.y[from] .. ":" .. Lexer.x(tokens, from) .. " differs when parsed alone"
        end
      end
      local second = parse("local z = 1", "tl")
      assert(#second.errors == 0)
      if Dump.dump(parse(input, "tl").chunk) ~= before then
        return false, "a second parse differs from the first"
      end
      for _, word in ipairs({ "match", "class", "record", "interface", "enum", "repeat", "for", "function", "if" }) do
        if input:find(word .. " ", 1, true) then
          Fuzz.label(word)
        end
      end
      return true, ""
    end,
    requires = { "match", "class", "record", "interface", "enum", "repeat", "for", "function", "if" },
  })
end

local function test_a_program_with_a_few_tokens_changed_parses_to_a_tree_over_its_tokens(tmp: string)
  Fuzz.run({
    name = "parser tiles a mutated program",
    dir = tmp,
    gen = gen_mutated,
    check = function(input: string): boolean, string
      return holds(input, dialect_of(input))
    end,
    requires = { "clean", "refused", "unclosed", "expected_expression" },
    shares = { refused = 0.3 },
  })
end

local function test_any_run_of_tokens_parses_to_a_tree_over_its_tokens(tmp: string)
  Fuzz.run({
    name = "parser tiles any tokens",
    dir = tmp,
    gen = gen_pieces,
    check = function(input: string): boolean, string
      return holds(input, dialect_of(input))
    end,
    requires = { "refused", "unexpected_token", "unclosed" },
    shares = { refused = 0.8 },
  })
end

local function test_any_bytes_parse_to_a_tree_over_their_tokens(tmp: string)
  Fuzz.run({
    name = "parser tiles any bytes",
    dir = tmp,
    gen = gen_bytes,
    check = function(input: string): boolean, string
      return holds(input, dialect_of(input))
    end,
    requires = { "stray_byte" },
  })
end

local function test_a_source_cut_at_any_token_still_parses_to_a_tree_over_its_tokens()
  local source = "local class C is D\n  mut n: integer\n  function m(self, a: {T}?): (true, T) | (false, E)\n" ..
    "    match f(a) do\n      | (true, v) then return if v then 1 else 2 end\n    end\n  end\nend\nlocal t = { 1, [k] = f{ 2 } }"
  local tokens = Lexer.lex(source, "f.tl").tokens
  for cut = 1, Lexer.count(tokens) do
    local piece = source:sub(1, Lexer.stop(tokens, cut) - 1)
    local ok, why = holds(piece, "tl")
    assert(ok, "cut at token " .. cut .. ": " .. why)
  end
end
