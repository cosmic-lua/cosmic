--- Reads the refusals the fork's checker can emit as templates, from its source ([`checker/tl.tl`]): the message of each
--- call that reports an error, with the parts that vary (a type, a name, a count) written `%s`. The switch's gate
--- ([`doc/plans/strict-teal.md`], "the switch") needs the new checker to be as sound as the fork, and a program the fork
--- refuses that no gate program contains is a refusal the gate never asks the new checker about.
--- [`testdata/gate/fork_refusals.json`] lists the templates, and each is covered by a row of the verdict table that the fork's
--- error matches (`matches`) or says why it can have none ([`lang.check_verdicts`]'s `refusal_problems`).
---
--- `bin/cosmic build/gate_refusals.tl` writes the list again, keeping the reasons already given.
---
-- TODO: delete this module, build/gate_refusals.tl and build/fork_refusals_test.tl once the fork is deleted at the switch: the
-- list in testdata/gate/fork_refusals.json is then frozen data, and lang/check_verdicts_test.tl holds it to the verdict table.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")

--- A token of the checker's source: a name, a string (its value) or a symbol.
local record Token
  kind: string
  text: string
  line: integer
end

--- A place the checker's source spells a message, and the template it is.
local record Site
  --- The file of the source.
  file: string
  --- The line of the call's name, or of the string that starts the message.
  line: integer
  --- What spells it: the name of the call that reports it, or `return`, `=` or `line` where a function hands the message
  --- on (to a call that reports what it is given) or an extra line names it.
  head: string
  --- "syntax" for a parser or lexer error, "type" for the checker's, "internal" for an assertion.
  kind: string
  --- The template the message is.
  template: string
end

--- A template and the places it is reported from.
local record Refusal
  id: string
  kind: string
  template: string
  --- Where it is spelled, each as `file:line`.
  sites: {string}
end

--- What the tool is told of one source that its rules do not see.
local record Notes
  --- Lines that spell a message in a choice, or hand it on in a call that is no report.
  extra: {integer: boolean}
  --- Lines the rules read as a message that is none: a message about a file or an option, not about a program, or a sentinel.
  skipped: {integer: boolean}
end

--- What `collect` found.
local record Collected
  refusals: {Refusal}
  --- The calls that report a message the tool cannot read, one line each: a message that is a choice of strings, which
  --- `NOTES` names the lines of.
  trouble: {string}
end

local record ForkRefusals
  type Token = Token
  type Site = Site
  type Refusal = Refusal
  type Collected = Collected
  type Notes = Notes

  --- The tokens of Lua or Teal source `text`: comments dropped, a string's value decoded.
  tokens: function(text: string): {Token}

  --- Every place `tokens` spells a message: the calls that report one, and the functions that hand one to those:
  --- `return nil, "..."`, `return false, "..."`, an assignment of a string to `errm`, `msg` and the like, and the lines of
  --- `notes.extra`, less those of `notes.skipped`.
  sites: function(tokens: {Token}, notes: Notes): {Site}

  --- The templates of `sites` once each, in the order of their first site, with every site each is spelled at.
  collect: function(sites: {Site}): Collected

  --- The templates of the fork's source: those of every file of `FILES`, read from the checkout.
  read: function(): Collected | nil, string

  --- The ids of the templates `message` is: of those in `refusals` of `kind`, the ones it matches that no other it matches
  --- is the specific case of. None where it matches no template.
  best: function(refusals: {Refusal}, kind: string, message: string): {string}

  --- The id a template is named by.
  id: function(kind: string, template: string): string

  --- Whether `message` is one the template could have made: its fixed parts occur in `message` in order.
  matches: function(template: string, message: string): boolean

  --- The number of characters a template fixes, which ranks the templates a message matches.
  fixed: function(template: string): integer
end

--- The token that stands for any place there is none, so that a read past either end of the tokens answers a token that is no name,
--- string or symbol.
local EOF <const>: Token = { kind = "eof", text = "", line = 0 }

--- The token at `at`, or the end token where there is none.
local function token_at(tokens: {Token}, at: integer): Token
  return tokens[at] or EOF
end

local ESCAPES <const>: {string: string} = { n = "\n", t = "\t", ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }

local function unescape(body: string): string
  local text = body:gsub("\\(.)", function(c: string): string
    return ESCAPES[c] or c
  end)
  return text
end

function ForkRefusals.tokens(text: string): {Token}
  local out: {Token} = {}
  local at, line, size = 1, 1, #text
  while at <= size do
    local c = text:sub(at, at)
    if c == "\n" then
      line = line + 1
      at = at + 1
    elseif c:find("%s") then
      at = at + 1
    elseif text:sub(at, at + 1) == "--" then
      local level = text:match("^%-%-%[(=*)%[", at)
      if level ~= nil then
        local close = "]" .. level .. "]"
        local _, stop = text:find(close, at, true)
        stop = stop or size
        local _, lines = text:sub(at, stop):gsub("\n", "")
        line = line + lines
        at = stop + 1
      else
        local stop = text:find("\n", at, true) or size + 1
        at = stop
      end
    elseif c == '"' or c == "'" then
      local stop = at + 1
      while stop <= size and text:sub(stop, stop) ~= c do
        if text:sub(stop, stop) == "\\" then
          stop = stop + 1
        end
        stop = stop + 1
      end
      out[#out + 1] = { kind = "string", text = unescape(text:sub(at + 1, stop - 1)), line = line }
      at = stop + 1
    elseif c == "[" and text:match("^%[=*%[", at) ~= nil then
      local level = (assert(text:match("^%[(=*)%[", at)))
      local close = "]" .. level .. "]"
      local _, stop = text:find(close, at, true)
      stop = stop or size
      local body = text:sub(at + #level + 2, stop - #level - 2)
      out[#out + 1] = { kind = "string", text = body, line = line }
      local _, lines = text:sub(at, stop):gsub("\n", "")
      line = line + lines
      at = stop + 1
    elseif c:find("[%a_]") then
      local word = (assert(text:match("^[%w_]+", at)))
      out[#out + 1] = { kind = "name", text = word, line = line }
      at = at + #word
    elseif c:find("%d") then
      local word = (assert(text:match("^%d[%w_]*", at)))
      out[#out + 1] = { kind = "number", text = word, line = line }
      at = at + #word
    else
      local symbol = text:match("^%.%.%.", at) or text:match("^%.%.", at) or text:match("^[=~<>]=", at) or
        text:match("^::", at) or c
      out[#out + 1] = { kind = "symbol", text = symbol, line = line }
      at = at + #symbol
    end
  end
  return out
end

--- How a call reports: the kind of its error and the position of the message among its arguments.
local record Head
  kind: string
  message: integer
end

local HEADS <const>: {string: Head} = {
  add = { kind = "type", message = 2 },
  add_coded = { kind = "type", message = 3 },
  invalid_at = { kind = "type", message = 2 },
  invalid_coded = { kind = "type", message = 3 },
  invalid_key_at = { kind = "type", message = 3 },
  add_in_context = { kind = "type", message = 3 },
  add_coded_in_context = { kind = "type", message = 4 },
  Err = { kind = "type", message = 1 },
  Err_at = { kind = "type", message = 2 },
  coded = { kind = "type", message = 2 },
  fail = { kind = "syntax", message = 3 },
  failskip = { kind = "syntax", message = 3 },
  add_syntax_error = { kind = "syntax", message = 1 },
  error = { kind = "internal", message = 1 },
}

--- The receivers a method of `HEADS` is called on to report: the checker's errors, never some other object's `add`.
local RECEIVERS <const>: {string: boolean} = { errs = true, Errors = true, self = true }

--- The names a function keeps a message in before it hands it on (`errm, erra = "..."`, `msg = "..."`).
local KEEPERS <const>: {string: boolean} = {
  errm = true, msg = true, errmsg = true, said = true, assert_spill_message = true,
}

local OPENERS <const>: {string: boolean} = { ["("] = true, ["{"] = true, ["["] = true }
local CLOSERS <const>: {string: boolean} = { [")"] = true, ["}"] = true, ["]"] = true }

local function symbol_is(token: Token | nil, text: string): boolean
  return token ~= nil and token.kind == "symbol" and token.text == text
end

--- The index of the bracket that closes the one at `open`.
local function closing(tokens: {Token}, open: integer): integer
  local depth = 0
  for at = open, #tokens do
    local token = token_at(tokens, at)
    if token.kind == "symbol" and OPENERS[token.text] == true then
      depth = depth + 1
    elseif token.kind == "symbol" and CLOSERS[token.text] == true then
      depth = depth - 1
      if depth == 0 then
        return at
      end
    end
  end
  return #tokens
end

--- The index of the last token of the operand that starts at `at`: a string, a number, a name with the calls, fields and
--- indexes after it, or a bracket, each after any `not`, `#` or `-`.
local function operand_end(tokens: {Token}, at: integer): integer
  local token = token_at(tokens, at)
  while (token.kind == "name" and token.text == "not") or symbol_is(token, "#") or symbol_is(token, "-") do
    at = at + 1
    token = token_at(tokens, at)
  end
  local last = at
  if symbol_is(token, "(") then
    last = closing(tokens, at)
  elseif token.kind == "name" then
    last = at
  end
  while true do
    local following = token_at(tokens, last + 1)
    if symbol_is(following, "(") or symbol_is(following, "[") then
      last = closing(tokens, last + 1)
    elseif (symbol_is(following, ".") or symbol_is(following, ":")) and
        token_at(tokens, last + 2).kind == "name" then
      last = last + 2
    else
      return last
    end
  end
end

--- The index of the last token of the concatenation that starts at `at`.
local function expression_end(tokens: {Token}, at: integer): integer
  local last = operand_end(tokens, at)
  while symbol_is(token_at(tokens, last + 1), "..") do
    last = operand_end(tokens, last + 2)
  end
  return last
end

--- The template the tokens `from` to `to` spell: the strings of a concatenation joined, every run of other operands
--- `%s`, a `("..."):format(...)` as the string it holds, and `%d` and `%s` as one placeholder. Empty where there is no
--- string at all, and the second answer says it is because the expression is a choice (`and`, `or`) of operands.
local function template_of(tokens: {Token}, from: integer, to: integer): string, boolean
  local current: {Token} = {}
  local operands: {{Token}} = { current }
  local depth = 0
  for at = from, to do
    local token = token_at(tokens, at)
    local symbol = token.kind == "symbol"
    if symbol and OPENERS[token.text] == true then
      depth = depth + 1
    elseif symbol and CLOSERS[token.text] == true then
      depth = depth - 1
    end
    if depth == 0 and token.kind == "name" and (token.text == "and" or token.text == "or") then
      return "", true
    end
    if depth == 0 and symbol and token.text == ".." then
      current = {}
      operands[#operands + 1] = current
    else
      current[#current + 1] = token
    end
  end
  local parts: {string} = {}
  local strings = 0
  for _, operand in ipairs(operands) do
    local held: Token | nil = nil
    if #operand == 1 and token_at(operand, 1).kind == "string" then
      held = token_at(operand, 1)
    elseif #operand >= 3 and symbol_is(token_at(operand, 1), "(") and token_at(operand, 2).kind == "string" and symbol_is(token_at(operand, 3), ")") and
        (#operand == 3 or (symbol_is(token_at(operand, 4), ":") and token_at(operand, 5).text == "format")) then
      held = token_at(operand, 2)
    end
    if held ~= nil then
      parts[#parts + 1] = held.text
      strings = strings + 1
    elseif parts[#parts] ~= "%s" or #parts == 0 then
      parts[#parts + 1] = "%s"
    end
  end
  if strings == 0 then
    return "", false
  end
  local text = table.concat(parts):gsub("%%d", "%%s"):gsub("%%s%%s", "%%s")
  return text, false
end

--- Whether the tokens `from` to `to` hold a string.
local function has_string(tokens: {Token}, from: integer, to: integer): boolean
  for at = from, to do
    if token_at(tokens, at).kind == "string" then
      return true
    end
  end
  return false
end

--- The name chain a call is made on: the last token of the receiver, and the index before the whole chain.
local function receiver_of(tokens: {Token}, at: integer): string, integer
  local before = at - 1
  local receiver = ""
  if before >= 1 and (symbol_is(token_at(tokens, before), ":") or symbol_is(token_at(tokens, before), ".")) then
    receiver = token_at(tokens, before - 1).text
    before = before - 2
    while before >= 2 and (symbol_is(token_at(tokens, before), ".") or symbol_is(token_at(tokens, before), ":")) do
      before = before - 2
    end
  end
  return receiver, before
end

function ForkRefusals.sites(tokens: {Token}, notes: Notes): {Site}
  local extra_lines = notes.extra
  local out: {Site} = {}
  local function kind_of(line: integer): string
    return line < 4800 and "syntax" or "type"
  end
  local function named_between(from: integer, to: integer): boolean
    for line = from, to do
      if extra_lines[line] == true then
        return true
      end
    end
    return false
  end
  local function spell(start: integer, head: string, kind: string)
    local from = start
    if symbol_is(token_at(tokens, start - 1), "(") and symbol_is(token_at(tokens, start + 1), ")") then
      from = start - 1
    end
    local template, _ = template_of(tokens, from, expression_end(tokens, from))
    if template ~= "" and notes.skipped[token_at(tokens, start).line] ~= true then
      out[#out + 1] = { file = "", line = token_at(tokens, start).line, head = head, kind = kind, template = template }
    end
  end
  for at, token in ipairs(tokens) do
    local head = HEADS[token.text]
    local following = token_at(tokens, at + 1)
    if token.kind == "name" and head ~= nil and symbol_is(following, "(") then
      local receiver, before = receiver_of(tokens, at)
      local declared = token_at(tokens, before).text == "function"
      local method = symbol_is(token_at(tokens, at - 1), ":") or symbol_is(token_at(tokens, at - 1), ".")
      local reports = true
      if declared then
        reports = false
      elseif head.kind == "type" and token.text ~= "Err" and token.text ~= "Err_at" then
        reports = RECEIVERS[receiver] == true
      elseif head.kind == "internal" then
        reports = not method
      end
      if reports then
        local close = closing(tokens, at + 1)
        local from = at + 2
        local index = 1
        local first = from
        local message_from, message_to = 0, 0
        local depth = 0
        for k = from, close do
          local t = token_at(tokens, k)
          if t.kind == "symbol" and OPENERS[t.text] == true then
            depth = depth + 1
          elseif t.kind == "symbol" and CLOSERS[t.text] == true then
            depth = depth - 1
          end
          if (depth == 0 and symbol_is(t, ",") and k < close) or k == close then
            if index == head.message and k > first then
              message_from, message_to = first, k - 1
            end
            index = index + 1
            first = k + 1
          end
        end
        if message_to > 0 then
          local template, choice = template_of(tokens, message_from, message_to)
          if template ~= "" then
            out[#out + 1] = { file = "", line = token.line, head = token.text, kind = head.kind, template = template }
          elseif choice and has_string(tokens, message_from, message_to) and not named_between(token.line, token_at(tokens, close).line) then
            out[#out + 1] = { file = "", line = token.line, head = token.text, kind = head.kind, template = "" }
          end
        end
      end
    elseif token.kind == "name" and token.text == "return" and
        (following.text == "nil" or following.text == "false" or following.text == "true") and symbol_is(token_at(tokens, at + 2), ",") then
      local start = at + 3
      if token_at(tokens, start).text == "nil" and symbol_is(token_at(tokens, start + 1), ",") then
        start = start + 2
      end
      if token_at(tokens, start).kind == "string" then
        spell(start, "return", kind_of(token_at(tokens, start).line))
      end
    elseif symbol_is(token, "=") and token_at(tokens, at - 1).kind == "name" then
      -- the first name of the targets, `errm` in `errm, erra = ...`
      local first = at - 1
      while first >= 3 and symbol_is(token_at(tokens, first - 1), ",") and token_at(tokens, first - 2).kind == "name" do
        first = first - 2
      end
      while first >= 3 and (symbol_is(token_at(tokens, first - 1), ".") or symbol_is(token_at(tokens, first - 1), ":")) and
          token_at(tokens, first - 2).kind == "name" do
        first = first - 2
      end
      local start = at + 1
      if symbol_is(token_at(tokens, start), "(") then
        start = start + 1
      end
      local target = token_at(tokens, first).text
      local lone = token_at(tokens, at - 1).text
      if (KEEPERS[target] == true or KEEPERS[lone] == true or (target == "emitted" and lone == "err")) and token_at(tokens, start).kind == "string" then
        spell(start, "=", kind_of(token_at(tokens, start).line))
      end
    end
  end
  -- the lines that name a message the rules above do not: its first string not joined to one before it
  for at, token in ipairs(tokens) do
    if extra_lines[token.line] == true and token.kind == "string" and not symbol_is(token_at(tokens, at - 1), "..") then
      spell(at, "line", kind_of(token.line))
    end
  end
  return out
end

--- The files the fork's messages are spelled in, and what each needs told of it. Every line named is a line of the
--- checker as it is: [`build/fork_refusals_test.tl`] holds each to a string, so a line that moves is seen.
local FILES <const>: {string} = {
  "checker/tl.tl", "checker/facts.tl", "checker/flow.tl", "checker/narrowing.tl", "checker/captures.tl",
}

local function lines_of(list: {integer}): {integer: boolean}
  local out: {integer: boolean} = {}
  for _, line in ipairs(list) do
    out[line] = true
  end
  return out
end

local NOTES <const>: {string: Notes} = {
  ["checker/tl.tl"] = {
    -- the default message of the lexer's `add_syntax_error`, a message the parser gives when it has none, the two
    -- messages of a choice in `parse_table_value` and `is_a`'s record against userdata, the suffix of a record's key
    -- types that disagree and the message `match_record_key`'s caller gives for an enum
    extra = lines_of({ 1038, 2371, 2630, 2631, 10594, 10595, 12913, 13057 }),
    -- the options' and the file reader's messages are not about a program; "missing" is a sentinel `check_assignment`
    -- answers and no message
    skipped = lines_of({ 8106, 16205, 19056, 19190, 19196 }),
  },
}

function ForkRefusals.id(kind: string, template: string): string
  return Hash.hex_sha256(kind .. "\n" .. template):sub(1, 12)
end

function ForkRefusals.collect(sites: {Site}): Collected
  local out: {Refusal} = {}
  local known: {string: Refusal} = {}
  local trouble: {string} = {}
  for _, site in ipairs(sites) do
    if site.template == "" then
      trouble[#trouble + 1] = "line " .. tostring(site.line) .. ": " .. site.head .. " gives a choice of messages"
    else
      local id = ForkRefusals.id(site.kind, site.template)
      local here = site.file .. ":" .. tostring(site.line)
      local before = known[id]
      if before == nil then
        local made: Refusal = { id = id, kind = site.kind, template = site.template, sites = { here } }
        known[id] = made
        out[#out + 1] = made
      else
        local spelled = before.sites
        if spelled[#spelled] ~= here then
          spelled[#spelled + 1] = here
        end
      end
    end
  end
  return { refusals = out, trouble = trouble }
end

--- The fixed parts of a template, in order.
local function pieces(template: string): {string}
  local out: {string} = {}
  local rest = template
  while true do
    local stop = rest:find("%s", 1, true)
    if stop == nil then
      out[#out + 1] = rest
      return out
    end
    out[#out + 1] = rest:sub(1, stop - 1)
    rest = rest:sub(stop + 2)
  end
end

function ForkRefusals.read(): Collected | nil, string
  local all: {Site} = {}
  for _, file in ipairs(FILES) do
    local text, why = Fs.read(file)
    if text == nil then
      return nil, why
    end
    local notes = NOTES[file] or { extra = {}, skipped = {} }
    for _, site in ipairs(ForkRefusals.sites(ForkRefusals.tokens(text), notes)) do
      all[#all + 1] = { file = file, line = site.line, head = site.head, kind = site.kind, template = site.template }
    end
  end
  return ForkRefusals.collect(all), ""
end

function ForkRefusals.fixed(template: string): integer
  local n = 0
  for _, piece in ipairs(pieces(template)) do
    n = n + #piece
  end
  return n
end

function ForkRefusals.matches(template: string, message: string): boolean
  local at = 1
  for _, piece in ipairs(pieces(template)) do
    local found, stop = message:find(piece, at, true)
    if found == nil or stop == nil then
      return false
    end
    at = stop + 1
  end
  return true
end

function ForkRefusals.best(refusals: {Refusal}, kind: string, message: string): {string}
  local matching: {Refusal} = {}
  for _, refusal in ipairs(refusals) do
    if refusal.kind == kind and ForkRefusals.matches(refusal.template, message) then
      matching[#matching + 1] = refusal
    end
  end
  -- A template whose fixed parts all occur in another matching template is that one's general case (`got %s, expected
  -- %s` in `in tuple entry %s: got %s, expected %s`), and the message is the specific one's. Templates neither holds
  -- the other (`in map key: %s` wraps the message `got %s, expected %s` gives) are both the message's.
  local found: {string} = {}
  for _, refusal in ipairs(matching) do
    local general = false
    for _, other in ipairs(matching) do
      if other ~= refusal and ForkRefusals.matches(refusal.template, other.template) then
        general = true
      end
    end
    if not general then
      found[#found + 1] = refusal.id
    end
  end
  return found
end

return ForkRefusals
