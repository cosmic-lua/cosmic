--- Fuzz properties for the translator ([`lang.translate`]). A Teal module
--- drawn from the forms the translator rewrites translates to a module that
--- parses with no error, is its own translation, keeps every comment and,
--- unless a method moved into a class, every line. The same module with a few
--- bytes changed, and any run of the forms' pieces, translate without
--- raising to text whose tokens tile it ([`lang.lexer_cover`]).
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
local Cover = require("lang.lexer_cover")
local Fuzz = require("build.fuzz")
local Lexer = require("lang.lexer")
local Translate = require("lang.translate")

local BASES <const>: {string} = { "string", "integer", "A", "Stream.Reader", "{string}", "{string: integer}", "Cache<K, V>" }

local gen_type: function(src: Fuzz.Source, depth: integer): string

--- A base type, a function type among them.
local function gen_base(src: Fuzz.Source, depth: integer): string
  local k = src:int(1, depth > 0 and 9 or 7)
  if k <= 7 then
    return Fuzz.pick(src, BASES)
  elseif k == 8 then
    return "{" .. gen_type(src, depth - 1) .. "}"
  end
  local params: {string} = {}
  while Fuzz.more(src, #params, 3) do
    local form = src:int(1, 4)
    local t = gen_type(src, depth - 1)
    if form == 1 then
      params[#params + 1] = "p" .. #params .. ": " .. t
    elseif form == 2 then
      params[#params + 1] = "? " .. t
    elseif form == 3 then
      params[#params + 1] = t .. "..."
    else
      params[#params + 1] = t
    end
  end
  return "function(" .. table.concat(params, ", ") .. ")" .. (src:int(0, 1) == 1 and ": " .. gen_type(src, depth - 1) or "")
end

--- A type, often a union with `nil` and sometimes a parenthesized one.
gen_type = function(src: Fuzz.Source, depth: integer): string
  local members: {string} = { gen_base(src, depth) }
  local nil_at = src:int(0, 3)
  while Fuzz.more(src, #members, 3) do
    members[#members + 1] = gen_base(src, depth)
  end
  if nil_at == 1 then
    table.insert(members, 1, "nil")
  elseif nil_at == 2 then
    table.insert(members, "nil")
  elseif nil_at == 3 and #members > 1 then
    table.insert(members, 2, "nil")
  end
  -- A function type takes `|` into its return list, so one that is a member
  -- of a union stands last.
  for i = 1, #members - 1 do
    if members[i]:find("^function") then
      table.insert(members, table.remove(members, i))
    end
  end
  local text = table.concat(members, " | ")
  return text
end

local OPERANDS <const>: {string} = { "x", "y", "f()", "n == 1", "a.b", "\"s\"", "1", "{ 1 }", "2 + n", "s .. \"z\"", "nil" }

local function gen_ternary(src: Fuzz.Source): string
  local out: {string} = {}
  local arms = src:int(1, 3)
  for _ = 1, arms do
    out[#out + 1] = Fuzz.pick(src, OPERANDS) .. " and " .. Fuzz.pick(src, OPERANDS) .. " or "
  end
  out[#out + 1] = Fuzz.pick(src, OPERANDS)
  return table.concat(out)
end

--- One top-level statement, ended by a line break, and the comment it carries.
local function gen_statement(src: Fuzz.Source, n: integer, out: {string}, classes: {integer})
  local k = src:int(1, 21)
  local tag = "-- c" .. n
  if k <= 3 then
    out[#out + 1] = "local v" .. n .. ": " .. gen_type(src, 1) .. " " .. tag
  elseif k == 4 then
    out[#out + 1] = "local function f" .. n .. "(a: " .. gen_type(src, 1) .. "): " .. gen_type(src, 1) .. ", string " .. tag
    out[#out + 1] = "  return nil, \"\""
    out[#out + 1] = "end"
  elseif k == 5 or k == 6 then
    out[#out + 1] = "local t" .. n .. " = " .. gen_ternary(src) .. "; " .. tag
  elseif k == 7 then
    out[#out + 1] = Fuzz.pick(src, { "for", "while", "repeat" }) == "repeat" and "repeat" or "for i = 1, 3 do " .. tag
    local last = out[#out]
    if last == "repeat" then
      out[#out] = "repeat " .. tag
      out[#out + 1] = "  if f() then goto continue end"
      out[#out + 1] = "  ::continue::"
      out[#out + 1] = "until x"
    else
      out[#out + 1] = "  if f() then goto continue end"
      out[#out + 1] = "  ::continue::"
      out[#out + 1] = "end"
    end
  elseif k == 8 then
    out[#out + 1] = "local type R" .. n .. " = " .. Fuzz.pick(src, { "record", "enum" }) .. " " .. tag
    out[#out + 1] = "  " .. (out[#out]:find("enum", 1, true) and "\"a\"" or "x: " .. gen_type(src, 1))
    out[#out + 1] = "end"
  elseif k == 9 then
    out[#out + 1] = "local n" .. n .. " = " .. Fuzz.pick(src, { "1_000", "0x1p4", "0xFF_FF", "3" }) .. " " .. tag
  elseif k == 10 then
    out[#out + 1] = "--[[ long " .. n .. " ]]"
    out[#out + 1] = "--[==["
    out[#out + 1] = "  more " .. n
    out[#out + 1] = "]==] -- c" .. n
  elseif k == 11 then
    out[#out + 1] = "local g" .. n .. ": " .. gen_type(src, 1) .. " = " .. Fuzz.pick(src, { "nil", "x as " .. gen_type(src, 0) }) .. " " .. tag
  elseif k == 12 then
    out[#out + 1] = "local record P" .. n .. " " .. tag
    out[#out + 1] = "  metamethod __close: function(P" .. n .. ")"
    out[#out + 1] = "  v: " .. gen_type(src, 1)
    out[#out + 1] = "  readonly w: integer"
    out[#out + 1] = "end"
  elseif k == 15 then
    -- An interface and two records that implement it: one write makes all three `mut`.
    classes[2] = classes[2] + 1
    out[#out + 1] = "local interface I" .. n .. " " .. tag
    out[#out + 1] = "  v: integer"
    out[#out + 1] = "end"
    out[#out + 1] = "local record A" .. n .. " is I" .. n
    out[#out + 1] = "  v: integer"
    out[#out + 1] = "end"
    out[#out + 1] = "local record B" .. n .. " is I" .. n
    out[#out + 1] = "  v: integer"
    out[#out + 1] = "end"
    out[#out + 1] = "local function g" .. n .. "(a: A" .. n .. ")"
    out[#out + 1] = "  a.v = 1"
    out[#out + 1] = "end"
  elseif k == 16 then
    -- A name declared before a record and again between it and its method.
    classes[1] = classes[1] + 1
    out[#out + 1] = "local x" .. n .. " = 1"
    out[#out + 1] = "local record S" .. n .. " " .. tag
    out[#out + 1] = "  n: integer"
    out[#out + 1] = "end"
    if src:int(0, 1) == 1 then
      out[#out + 1] = "local x" .. n .. " = 2"
    end
    out[#out + 1] = "function S" .. n .. ":get(): integer"
    out[#out + 1] = "  return x" .. n .. " + self.n"
    out[#out + 1] = "end"
  elseif k == 17 then
    local items = src:int(2, 5)
    local parts: {string} = {}
    local keyed = src:int(0, 1) == 1
    for i = 1, items do
      parts[i] = keyed and "k" .. i .. " = " .. i or tostring(i)
    end
    out[#out + 1] = "local t" .. n .. " = { " .. table.concat(parts, "; ") .. (src:int(0, 1) == 1 and ";" or "") .. " } " .. tag
  elseif k == 18 then
    out[#out + 1] = "--[[ a" .. n .. " ]] --[==[ b ]==] " .. tag
    out[#out + 1] = "local y" .. n .. " = 1"
  elseif k == 19 then
    out[#out + 1] = "for i = 1, 3 do " .. tag
    out[#out + 1] = "  if f() then goto continue end"
    out[#out + 1] = "  for j = 1, 3 do"
    out[#out + 1] = "    if g() then goto continue end"
    out[#out + 1] = "    ::continue::"
    out[#out + 1] = "  end"
    out[#out + 1] = "  ::continue::"
    out[#out + 1] = "end"
  elseif k == 20 then
    local parts: {string} = {}
    for i = 1, src:int(2, 4) do
      local form = src:int(1, 3)
      if form == 1 then
        parts[i] = "{ " .. src:int(1, 9) .. "; " .. src:int(1, 9) .. " }"
      elseif form == 2 then
        parts[i] = "{ k = { " .. src:int(1, 9) .. "; " .. src:int(1, 9) .. " }; z = 1 }"
      else
        parts[i] = tostring(src:int(1, 9))
      end
    end
    out[#out + 1] = "local nest" .. n .. " = { " .. table.concat(parts, "; ") .. " } " .. tag
  elseif k == 21 then
    -- An interface nested in a record of the same file, named with its qualifier.
    out[#out + 1] = "local record Stream" .. n .. " " .. tag
    out[#out + 1] = "  interface Reader" .. n
    out[#out + 1] = "    w: integer"
    out[#out + 1] = "  end"
    out[#out + 1] = "end"
    out[#out + 1] = "local record Fd" .. n .. " is Stream" .. n .. ".Reader" .. n
    out[#out + 1] = "  w: integer"
    out[#out + 1] = "end"
    out[#out + 1] = "local function use" .. n .. "(f: Fd" .. n .. ")"
    out[#out + 1] = "  f.w = 1"
    out[#out + 1] = "end"
  else
    -- A record with methods, which becomes a class.
    classes[1] = classes[1] + 1
    out[#out + 1] = "local record C" .. n .. " " .. tag
    out[#out + 1] = "  count: integer"
    out[#out + 1] = "  items: {string}"
    -- the method gives the field's results, since a field that disagrees with its method is refused
    local rets = gen_type(src, 1)
    out[#out + 1] = "  bump: function(C" .. n .. "): " .. rets
    out[#out + 1] = "end"
    out[#out + 1] = "function C" .. n .. ":bump(): " .. rets
    out[#out + 1] = "  self.count = self.count + 1"
    out[#out + 1] = "  table.insert(self.items, \"x\")"
    out[#out + 1] = "  return nil"
    out[#out + 1] = "end"
  end
end

--- A Teal module of some statements.
local function gen_module(src: Fuzz.Source): string
  local out: {string} = {}
  local classes: {integer} = { 0, 0 }
  local n = 0
  while n == 0 or Fuzz.more(src, n, 12) do
    n = n + 1
    gen_statement(src, n, out, classes)
  end
  return table.concat(out, "\n") .. "\n"
end

local function lines_of(text: string): integer
  local _, n = text:gsub("\n", "")
  return n
end

--- The comments `-- cN` that `text` holds.
local function marks(text: string): string
  local out: {string} = {}
  for mark in text:gmatch("%-%- (c%d+)") do
    out[#out + 1] = mark
  end
  return table.concat(out, " ")
end

--- The names the respellings write or drop, which a comparison leaves out.
local OWN <const>: {string: boolean} = {
  type = true, record = true, enum = true, class = true, interface = true, metamethod = true, readonly = true,
  self = true,
}

--- The names and strings of `text` in order, less those the rows add or drop: the
--- sequence a respelling must not change.
local function spelled(text: string): string
  local out: {string} = {}
  local tokens = Lexer.lex(text, "f.tl").tokens
  for i, kind in ipairs(tokens.kind) do
    local word = Lexer.text(tokens, i)
    if kind == "identifier" and not OWN[word] and not word:find("^arg%d+_*$") then
      out[#out + 1] = word
    elseif kind == "string" then
      out[#out + 1] = word
    end
  end
  return table.concat(out, " ")
end

local function test_a_teal_module_translates_to_a_module_that_parses_and_is_its_own_translation(tmp: string)
  Fuzz.run({
    name = "translate a teal module",
    dir = tmp,
    gen = gen_module,
    check = function(input: string): boolean, string
      local first = Translate.translate(input, "f.tl")
      local e = first.errors[1]
      if e ~= nil then
        return false, "the translation has the error " .. e.code .. " at " .. e.y .. ":" .. e.x .. ": " .. e.msg .. "\n" .. first.text
      end
      local second = Translate.translate(first.text, "f.tl")
      if second.text ~= first.text then
        return false, "translating again changes the text:\n" .. first.text .. "\nto\n" .. second.text
      end
      local classes = first.counts["class"] or 0
      if classes == 0 and lines_of(first.text) ~= lines_of(input) then
        return false, "the lines moved from " .. lines_of(input) .. " to " .. lines_of(first.text) .. ":\n" .. first.text
      end
      if marks(first.text) ~= marks(input) and classes == 0 then
        return false, "the comments changed: " .. marks(input) .. " to " .. marks(first.text)
      end
      -- An interface and the records that implement it are given `mut` together.
      local _, interfaces = input:gsub("interface I%d+", "")
      local _, muts = first.text:gsub("mut v: integer", "")
      if muts ~= 3 * interfaces then
        return false, "the interface and its records do not agree on mut: " .. muts .. " of " .. 3 * interfaces .. "\n" .. first.text
      end
      local _, streams = input:gsub("record Stream%d+", "")
      local _, wmuts = first.text:gsub("mut w: integer", "")
      if wmuts ~= 2 * streams then
        return false, "a qualified interface and its record do not agree on mut: " .. wmuts .. " of " .. 2 * streams
      end
      -- The names, the strings and the keywords are the translation's own
      -- or the source's: nothing else is written or lost.
      if classes == 0 then
        local want, got = spelled(input), spelled(first.text)
        if want ~= got then
          return false, "the names and strings differ:\n" .. want .. "\n" .. got .. "\n" .. first.text
        end
      end
      for _, row in ipairs(Translate.rows) do
        if first.counts[row] ~= nil then
          Fuzz.label(row)
        end
      end
      if #first.hazards > 0 then
        Fuzz.label("hazard")
      end
      return true, ""
    end,
    requires = { "nil_union", "variadic_type", "optional_type", "continue", "semicolon", "long_comment",
      "digit_separator", "hex_float", "type_declaration", "metamethod", "readonly", "ternary", "class", "mut_field",
      "mut_collection", "hazard" },
    shares = { nil_union = 0.5, ternary = 0.15, class = 0.2 },
  })
end

--- A module with a few bytes changed, a prefix of it, or a run of pieces.
local function gen_mutated(src: Fuzz.Source): string
  return Fuzz.mutate(src, gen_module(src), 6)
end

local PIECES <const>: {string} = {
  "local", "function", "end", "record", "class", "type", "x", ":", "|", "nil", "?", "...", "(", ")", "{", "}", ",",
  "string", "goto", "continue", "::continue::", "::l::", ";", "and", "or", "if", "then", "else", "for", "do", "while",
  "self", "=", "\n", " ", "--[[ c ]]", "--[==[", "]==]", "1_0", "0x1p1", "metamethod", "readonly", "as", "is", "mut",
}

local function gen_pieces(src: Fuzz.Source): string
  local out: {string} = {}
  while Fuzz.more(src, #out, 60) do
    out[#out + 1] = Fuzz.pick(src, PIECES)
    out[#out + 1] = " "
  end
  return table.concat(out)
end

local function tiles(input: string): (boolean, string)
  local result = Translate.translate(input, "f.tl")
  local ok, why = Cover.check(result.text, Lexer.lex(result.text, "f.tl"))
  if not ok then
    return false, why
  end
  Fuzz.label(#result.errors == 0 and "clean" or "refused")
  return true, ""
end

local function test_a_changed_module_translates_to_text_whose_tokens_tile_it(tmp: string)
  Fuzz.run({
    name = "translate a changed module",
    dir = tmp,
    gen = gen_mutated,
    check = tiles,
    requires = { "clean", "refused" },
    shares = { refused = 0.2 },
  })
end

local function test_any_run_of_pieces_translates_to_text_whose_tokens_tile_it(tmp: string)
  Fuzz.run({
    name = "translate any pieces",
    dir = tmp,
    gen = gen_pieces,
    check = tiles,
    requires = { "refused" },
    shares = { refused = 0.5 },
  })
end
