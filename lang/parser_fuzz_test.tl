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
local Programs = require("build.parser_programs")

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
    gen = Programs.valid,
    check = function(input: string): boolean, string
      local first = parse(input, "tl")
      local e = first.errors[1]
      if e ~= nil then
        return false, e.code .. " at " .. tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg
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
          return false, "the statement at " .. tostring(assert(tokens.y[from])) .. ":" .. tostring(Lexer.x(tokens, from)) .. " differs when parsed alone"
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
    gen = Programs.mutated,
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
    gen = Programs.pieces,
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
    gen = Programs.bytes,
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
    assert(ok, "cut at token " .. tostring(cut) .. ": " .. why)
  end
end
