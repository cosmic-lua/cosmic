--- Fuzz properties for [`build.fix.format`], over programs of the grammar ([`build.parser_programs`]) written with
--- comments, doc comments, blank lines, tabs, `\r\n` and shebang lines in the gaps between their tokens, and the same
--- programs with a few tokens deleted, repeated, swapped or replaced. For each input, `format` either refuses it as a
--- source with a syntax error, or returns a layout that has the tokens (but for the comma a table ends with), the
--- comments, the tree and the doc comments of the source, and formatting the layout changes nothing. A refusal of any
--- other kind is a fault of the layout, and fails the property: the guard of `format` is what stops a faulty layout
--- from being written, not what the property relies on. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- ([`build.fuzz`]).
local Ast = require("lang.ast")
local Check = require("build.fix.layout_check")
local Equiv = require("build.fix.equiv")
local Format = require("build.fix.format")
local Fuzz = require("build.fuzz")
local Lexer = require("lang.lexer")
local Programs = require("build.parser_programs")
local Test = require("cosmic.test")

Test.policy{}

--- What may stand between two tokens, a plain space the most often.
local GAPS <const>: {string} = {
  " ", " ", " ", " ", "  ", "\t", "\n", "\n", "\n\n", "\r\n", " -- c\n", "\n-- own\n", "\n\n-- own\n\n", "\n--- doc\n",
  " -- trailing  \n", "\n  -- own\n    ", "\n\n\n", "\n \n",
}

--- The first lines a source may begin with.
local HEADS <const>: {string} = { "", "", "", "#!/bin/cosmic\n", "-- head\n", "\n\n", "--- doc\n" }

--- What a source may end with.
local TAILS <const>: {string} = { "", "", "\n", "\n\n\n", " -- end", "\n-- end\n", "\n--- end" }

--- `tokens` joined by gaps drawn from `src`: a token is followed by a gap of one of the kinds above, or by the gap
--- the grammar gives it (a space) where `plain` is set.
local function dressed(src: Fuzz.Source, tokens: {string}, plain: boolean): string
  local out: mut {string} = { Fuzz.pick(src, HEADS) }
  for i, token in ipairs(tokens) do
    if i > 1 then
      out[#out + 1] = if plain then " " else Fuzz.pick(src, GAPS) end
    end
    out[#out + 1] = token
  end
  out[#out + 1] = Fuzz.pick(src, TAILS)
  return table.concat(out)
end

--- A program of the grammar written with the gaps above.
local function gen_dressed(src: Fuzz.Source): string
  return dressed(src, Programs.program(src), src:int(1, 4) == 1)
end

--- A program with a few of its tokens changed, then written with gaps where it had a space.
local function gen_mutated(src: Fuzz.Source): string
  local tokens: mut {string} = {}
  for token in Programs.mutated(src):gmatch("%S+") do
    tokens[#tokens + 1] = token
  end
  return dressed(src, tokens, false)
end

--- What `input` reached, as labels, so that a property can hold the generator to what it is meant to exercise.
local function reached(input: string)
  if input:find("--", 1, true) ~= nil then
    Fuzz.label("comment")
  end
  if input:find("\n\n", 1, true) ~= nil then
    Fuzz.label("blank line")
  end
  if input:find("--- ", 1, true) ~= nil then
    Fuzz.label("doc comment")
  end
  if input:find("\r\n", 1, true) ~= nil then
    Fuzz.label("carriage return")
  end
  if input:find("#!", 1, true) == 1 then
    Fuzz.label("shebang")
  end
  for _, word in ipairs({ "match", "class", "record", "function", "if" }) do
    if input:find(word .. " ", 1, true) ~= nil then
      Fuzz.label(word)
    end
  end
end

--- Whether `format` of `input` holds what it promises, and why not.
local function holds(input: string, name: string): boolean, string
  reached(input)
  local got = Format.format(input, name)
  local text = got.text
  if text == nil then
    local kind = got.kind
    Fuzz.label("refused " .. (kind or "?"))
    if kind ~= "syntax" then
      return false, got.why
    end
    return true, ""
  end
  Fuzz.label("laid")
  -- The checks of `format`, made again from outside it, and the properties of the layout ([`build.fix.layout_check`]).
  local why = Equiv.difference(Equiv.read(input, name, "tl"), Equiv.read(text, name, "tl"))
  if why ~= nil then
    return false, "not the same as the source: " .. why
  end
  local again = Format.format(text, name)
  if again.text ~= text then
    return false, "formatting the layout gives " .. string.format("%q", tostring(again.text))
  end
  local checked = Check.laid(input)
  if checked ~= text then
    return false, "the layout of the checks differs: " .. string.format("%q", checked)
  end
  return true, ""
end

--- A layout that is `laid`, whatever the source: the seam of [`build.fix.format`] for a layout that is faulty.
local function giving(laid: string): Format.Layouter
  return function(_source: string, _name: string, _dialect?: Ast.Dialect): string?, string
    return laid, ""
  end
end

--- `text` with the bytes from `from` for `length` bytes cut out.
local function without(text: string, from: integer, length: integer): string
  return text:sub(1, from - 1) .. text:sub(from + length)
end

--- A layout spoilt in the way `kind` says.
local record Spoilt
  kind: string
  text: string
end

--- Spoilt copies of `laid`, the layout of a program, each of a kind a faulty layout could produce and each one
--- meaning something other than `laid`: each comment cut out, some tokens cut out, and each comment on a line of its
--- own swapped with the code line next to it.
local function spoilt(laid: string): {Spoilt}
  local out: mut {Spoilt} = {}
  local tokens = Lexer.lex(laid, "f.tl").tokens
  local count = Lexer.count(tokens)
  for i = 1, count do
    for _, comment in ipairs(tokens.comments[i] or {}) do
      out[#out + 1] = { kind = "cut comment", text = without(laid, comment.offset, comment.length) }
    end
  end
  local step = math.max(1, (count - 1) // 8)
  for i = 1, count - 1, step do
    out[#out + 1] = { kind = "cut token", text = without(laid, Lexer.offset(tokens, i), #Lexer.text(tokens, i)) }
  end
  local lines: mut {string} = {}
  for line in (laid .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  for i = 1, #lines - 1 do
    local own, code = lines[i] or "", lines[i + 1] or ""
    if own:find("^%s*%-%-") ~= nil and code:find("%S") ~= nil and code:find("^%s*%-%-") == nil then
      local swapped: mut {string} = {}
      for k, line in ipairs(lines) do
        swapped[#swapped + 1] = if k == i then code elseif k == i + 1 then own else line end
      end
      out[#out + 1] = { kind = "swapped comment", text = table.concat(swapped, "\n") }
    end
  end
  return out
end

local function test_a_layout_that_loses_a_token_or_a_comment_or_moves_a_comment_across_code_is_refused(tmp: string)
  Fuzz.run({
    name = "format refuses a spoilt layout",
    dir = tmp,
    gen = gen_dressed,
    check = function(input: string): boolean, string
      local laid = Format.format(input, "f.tl").text
      if laid == nil then
        Fuzz.label("no layout")
        return true, ""
      end
      for _, bad in ipairs(spoilt(laid)) do
        if bad.text ~= laid then
          Fuzz.label(bad.kind)
          local got = Format.format(input, "f.tl", giving(bad.text))
          if got.text ~= nil then
            return false, string.format("a layout with a %s was taken: %q for %q", bad.kind, bad.text, input)
          end
        end
      end
      return true, ""
    end,
    requires = { "cut comment", "cut token", "swapped comment" },
    shares = { ["cut comment"] = 0.1, ["cut token"] = 0.2, ["swapped comment"] = 0.05 },
  })
end

local function test_format_of_a_program_written_with_comments_and_blank_lines_is_the_same_and_a_fixed_point(tmp: string)
  Fuzz.run({
    name = "format keeps a program",
    dir = tmp,
    gen = gen_dressed,
    check = function(input: string): boolean, string
      return holds(input, "f.tl")
    end,
    requires = { "laid", "comment", "blank line", "doc comment", "carriage return", "shebang", "match", "class", "record" },
    shares = { laid = 0.5, comment = 0.5 },
  })
end

local function test_format_of_a_program_with_a_few_tokens_changed_is_refused_as_a_syntax_error_or_is_the_same(tmp: string)
  Fuzz.run({
    name = "format keeps a mutated program",
    dir = tmp,
    gen = gen_mutated,
    check = function(input: string): boolean, string
      return holds(input, "f.tl")
    end,
    requires = { "laid", "refused syntax", "comment" },
    shares = { laid = 0.1, ["refused syntax"] = 0.1 },
  })
end

local function test_format_of_any_run_of_tokens_is_refused_as_a_syntax_error_or_is_the_same(tmp: string)
  Fuzz.run({
    name = "format keeps any tokens",
    dir = tmp,
    gen = Programs.pieces,
    check = function(input: string): boolean, string
      return holds(input, "f.tl")
    end,
    requires = { "refused syntax" },
    shares = { ["refused syntax"] = 0.5 },
  })
end

local function test_format_of_a_program_read_as_a_declaration_file_is_the_same_or_refused_as_a_syntax_error(tmp: string)
  Fuzz.run({
    name = "format keeps a declaration file",
    dir = tmp,
    gen = gen_dressed,
    check = function(input: string): boolean, string
      reached(input)
      local got = Format.format(input, "f.d.tl")
      local text = got.text
      if text == nil then
        Fuzz.label("refused " .. (got.kind or "?"))
        return got.kind == "syntax", got.why
      end
      Fuzz.label("laid")
      local why = Equiv.difference(Equiv.read(input, "f.d.tl", "decl"), Equiv.read(text, "f.d.tl", "decl"))
      if why ~= nil then
        return false, "not the same as the source: " .. why
      end
      return Format.format(text, "f.d.tl").text == text, "the layout is not a fixed point"
    end,
    requires = { "laid", "refused syntax" },
    shares = { ["refused syntax"] = 0.2 },
  })
end
