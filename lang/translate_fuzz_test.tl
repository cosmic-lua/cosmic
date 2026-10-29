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
  local k = src:int(1, if depth > 0 then 9 else 7 end)
  if k <= 7 then
    return Fuzz.pick(src, BASES)
  elseif k == 8 then
    return "{" .. gen_type(src, depth - 1) .. "}"
  end
  local params: mut {string} = {}
  while Fuzz.more(src, #params, 3) do
    local form = src:int(1, 4)
    local t = gen_type(src, depth - 1)
    if form == 1 then
      table.insert(params, "p" .. tostring(#params) .. ": " .. t)
    elseif form == 2 then
      params[#params + 1] = "? " .. t
    elseif form == 3 then
      params[#params + 1] = t .. "..."
    else
      params[#params + 1] = t
    end
  end
  return "function(" .. table.concat(params, ", ") .. ")" .. (if src:int(0, 1) == 1 then ": " .. gen_type(src, depth - 1) else "" end)
end

--- A type, often a union with `nil` and sometimes a parenthesized one.
gen_type = function(src: Fuzz.Source, depth: integer): string
  local members: mut {string} = { gen_base(src, depth) }
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
  local out: mut {string} = {}
  local arms = src:int(1, 3)
  for _ = 1, arms do
    out[#out + 1] = Fuzz.pick(src, OPERANDS) .. " and " .. Fuzz.pick(src, OPERANDS) .. " or "
  end
  out[#out + 1] = Fuzz.pick(src, OPERANDS)
  return table.concat(out)
end

--- One top-level statement, ended by a line break, and the comment it carries.
local function gen_statement(src: Fuzz.Source, n: integer, out: mut {string}, classes: mut {integer})
  local k = src:int(1, 21)
  local tag = "-- c" .. tostring(n)
  if k <= 3 then
    table.insert(out, "local v" .. tostring(n) .. ": " .. gen_type(src, 1) .. " " .. tag)
  elseif k == 4 then
    table.insert(out, "local function f" .. tostring(n) .. "(a: " .. gen_type(src, 1) .. "): " .. gen_type(src, 1) .. ", string " .. tag)
    out[#out + 1] = "  return nil, \"\""
    out[#out + 1] = "end"
  elseif k == 5 or k == 6 then
    table.insert(out, "local t" .. tostring(n) .. " = " .. gen_ternary(src) .. "; " .. tag)
  elseif k == 7 then
    table.insert(out, if Fuzz.pick(src, { "for", "while", "repeat" }) == "repeat" then "repeat" else "for i = 1, 3 do " .. tag end)
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
    table.insert(out, "local type R" .. tostring(n) .. " = " .. Fuzz.pick(src, { "record", "enum" }) .. " " .. tag)
    table.insert(out, "  " .. (if out[#out]:find("enum", 1, true) then "\"a\"" else "x: " .. gen_type(src, 1) end))
    out[#out + 1] = "end"
  elseif k == 9 then
    table.insert(out, "local n" .. tostring(n) .. " = " .. Fuzz.pick(src, { "1_000", "0x1p4", "0xFF_FF", "3" }) .. " " .. tag)
  elseif k == 10 then
    table.insert(out, "--[[ long " .. tostring(n) .. " ]]")
    out[#out + 1] = "--[==["
    table.insert(out, "  more " .. tostring(n))
    table.insert(out, "]==] -- c" .. tostring(n))
  elseif k == 11 then
    table.insert(out, "local g" .. tostring(n) .. ": " .. gen_type(src, 1) .. " = " .. Fuzz.pick(src, { "nil", "x as " .. gen_type(src, 0) }) .. " " .. tag)
  elseif k == 12 then
    table.insert(out, "local record P" .. tostring(n) .. " " .. tag)
    table.insert(out, "  metamethod __close: function(P" .. tostring(n) .. ")")
    table.insert(out, "  v: " .. gen_type(src, 1))
    out[#out + 1] = "  readonly w: integer"
    out[#out + 1] = "end"
  elseif k == 15 then
    -- An interface and two records that implement it: one write makes all three `mut`.
    classes[2] = classes[2] + 1
    table.insert(out, "local interface I" .. tostring(n) .. " " .. tag)
    out[#out + 1] = "  v: integer"
    out[#out + 1] = "end"
    table.insert(out, "local record A" .. tostring(n) .. " is I" .. tostring(n))
    out[#out + 1] = "  v: integer"
    out[#out + 1] = "end"
    table.insert(out, "local record B" .. tostring(n) .. " is I" .. tostring(n))
    out[#out + 1] = "  v: integer"
    out[#out + 1] = "end"
    table.insert(out, "local function g" .. tostring(n) .. "(a: A" .. tostring(n) .. ")")
    out[#out + 1] = "  a.v = 1"
    out[#out + 1] = "end"
  elseif k == 16 then
    -- A name declared before a record and again between it and its method.
    classes[1] = classes[1] + 1
    table.insert(out, "local x" .. tostring(n) .. " = 1")
    table.insert(out, "local record S" .. tostring(n) .. " " .. tag)
    out[#out + 1] = "  n: integer"
    out[#out + 1] = "end"
    if src:int(0, 1) == 1 then
      table.insert(out, "local x" .. tostring(n) .. " = 2")
    end
    table.insert(out, "function S" .. tostring(n) .. ":get(): integer")
    table.insert(out, "  return x" .. tostring(n) .. " + self.n")
    out[#out + 1] = "end"
  elseif k == 17 then
    local items = src:int(2, 5)
    local parts: mut {string} = {}
    local keyed = src:int(0, 1) == 1
    for i = 1, items do
      parts[i] = if keyed then "k" .. tostring(i) .. " = " .. tostring(i) else tostring(i) end
    end
    table.insert(out, "local t" .. tostring(n) .. " = { " .. table.concat(parts, "; ") .. (if src:int(0, 1) == 1 then ";" else "" end) .. " } " .. tag)
  elseif k == 18 then
    table.insert(out, "--[[ a" .. tostring(n) .. " ]] --[==[ b ]==] " .. tag)
    table.insert(out, "local y" .. tostring(n) .. " = 1")
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
    local parts: mut {string} = {}
    for i = 1, src:int(2, 4) do
      local form = src:int(1, 3)
      if form == 1 then
        parts[i] = "{ " .. tostring(src:int(1, 9)) .. "; " .. tostring(src:int(1, 9)) .. " }"
      elseif form == 2 then
        parts[i] = "{ k = { " .. tostring(src:int(1, 9)) .. "; " .. tostring(src:int(1, 9)) .. " }; z = 1 }"
      else
        parts[i] = tostring(src:int(1, 9))
      end
    end
    table.insert(out, "local nest" .. tostring(n) .. " = { " .. table.concat(parts, "; ") .. " } " .. tag)
  elseif k == 21 then
    -- An interface nested in a record of the same file, named with its qualifier.
    table.insert(out, "local record Stream" .. tostring(n) .. " " .. tag)
    table.insert(out, "  interface Reader" .. tostring(n))
    out[#out + 1] = "    w: integer"
    out[#out + 1] = "  end"
    out[#out + 1] = "end"
    table.insert(out, "local record Fd" .. tostring(n) .. " is Stream" .. tostring(n) .. ".Reader" .. tostring(n))
    out[#out + 1] = "  w: integer"
    out[#out + 1] = "end"
    table.insert(out, "local function use" .. tostring(n) .. "(f: Fd" .. tostring(n) .. ")")
    out[#out + 1] = "  f.w = 1"
    out[#out + 1] = "end"
  else
    -- A record with methods, which becomes a class.
    classes[1] = classes[1] + 1
    table.insert(out, "local record C" .. tostring(n) .. " " .. tag)
    out[#out + 1] = "  count: integer"
    out[#out + 1] = "  items: {string}"
    -- the method gives the field's results, since a field that disagrees with its method is refused
    local rets = gen_type(src, 1)
    table.insert(out, "  bump: function(C" .. tostring(n) .. "): " .. rets)
    out[#out + 1] = "end"
    table.insert(out, "function C" .. tostring(n) .. ":bump(): " .. rets)
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
  local out: mut {string} = {}
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
  local out: mut {string} = {}
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
        return false, "the translation has the error " .. e.code .. " at " .. tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg .. "\n" .. first.text
      end
      local second = Translate.translate(first.text, "f.tl")
      if second.text ~= first.text then
        return false, "translating again changes the text:\n" .. first.text .. "\nto\n" .. second.text
      end
      local classes = first.counts["class"] or 0
      if classes == 0 and lines_of(first.text) ~= lines_of(input) then
        return false, "the lines moved from " .. tostring(lines_of(input)) .. " to " .. tostring(lines_of(first.text)) .. ":\n" .. first.text
      end
      if marks(first.text) ~= marks(input) and classes == 0 then
        return false, "the comments changed: " .. marks(input) .. " to " .. marks(first.text)
      end
      -- An interface and the records that implement it are given `mut` together.
      local _, interfaces = input:gsub("interface I%d+", "")
      local _, muts = first.text:gsub("mut v: integer", "")
      if muts ~= 3 * interfaces then
        return false, "the interface and its records do not agree on mut: " .. tostring(muts) .. " of " .. tostring(3 * interfaces) .. "\n" .. first.text
      end
      local _, streams = input:gsub("record Stream%d+", "")
      local _, wmuts = first.text:gsub("mut w: integer", "")
      if wmuts ~= 2 * streams then
        return false, "a qualified interface and its record do not agree on mut: " .. tostring(wmuts) .. " of " .. tostring(2 * streams)
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
  local out: mut {string} = {}
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
  Fuzz.label(if #result.errors == 0 then "clean" else "refused" end)
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
