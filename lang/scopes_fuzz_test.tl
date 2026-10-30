--- Fuzz properties for the scope builder ([`lang.scopes`]). A program drawn
--- from [`lang.scopes_programs`] resolves every name as a second, plainer
--- implementation of Lua's scoping does (a persistent list of declarations
--- threaded through the tree), and the errors the builder gives are the ones
--- that implementation expects, with the same places. The same program with a
--- few tokens deleted, repeated, swapped or replaced, and any run of tokens of
--- the grammar's vocabulary, build scopes that [`lang.scopes_cover`] holds
--- consistent with the tree whatever errors they make, and never raise or run
--- past the instruction budget. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).
local Ast = require("lang.ast")
local Cover = require("lang.scopes_cover")
local Fuzz = require("build.fuzz")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Programs = require("lang.scopes_programs")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")

Test.policy{}

local GLOBALS <const>: {string: Scopes.Global} = {
  print = { space = "value", const = true },
  pairs = { space = "value", const = true },
}

-- The reference ------------------------------------------------------------

--- A declaration in scope: a list, the newest first.
local record Decl
  name: string
  id: integer
  --- The function that declares it.
  fn: integer
  readonly: boolean
  next: Decl?
end

--- What the reference finds in a tree.
local record Reference
  tokens: Lexer.Tokens
  --- For each name, the id of its declaration, 0 for a global.
  bound: mut {integer: integer}
  --- The errors expected, as `code y:x`.
  errors: mut {string}
  --- The assignment statement of each name it assigns, and the names a function assigns that it does not declare.
  assigns: mut {integer: Ast.Assign}
  foreign: mut {integer: boolean}
end

local function find(env: Decl?, name: string): Decl?
  local at = env
  while at ~= nil do
    if at.name == name then
      return at
    end
    at = at.next
  end
  return nil
end

local ref_exp: function(r: Reference, e: Ast.Node, env: Decl?, fn: integer)
local ref_block: function(r: Reference, stats: {Ast.Stat}, env: Decl?, fn: integer): Decl?

local function expect(r: Reference, code: string, token: integer)
  table.insert(r.errors, code .. " " .. r.tokens.y[token] .. ":" .. tostring(Lexer.x(r.tokens, token)))
end

--- The environment after declaring `binding`, and the error a shadow is.
local function push(r: Reference, env: Decl?, binding: Ast.Binding, fn: integer, readonly: boolean,
                    hidden: Decl?, copies?: boolean): Decl
  local name = binding.name
  if not copies and name:sub(1, 1) ~= "_" and name ~= "self" and (hidden ~= nil or GLOBALS[name] ~= nil) then
    expect(r, "shadows", binding.first)
  end
  return { name = name, id = binding.id, fn = fn, readonly = readonly, next = env }
end

local function use(r: Reference, n: Ast.Name, env: Decl?, fn: integer, write: boolean)
  local found = find(env, n.text)
  r.bound[n.id] = found ~= nil and found.id or 0
  if found == nil then
    if GLOBALS[n.text] == nil then
      expect(r, "unknown_variable", n.first)
    end
  elseif write and found.readonly then
    expect(r, "const_assigned", n.first)
    r.foreign[n.id] = true
  elseif write and found.fn ~= fn then
    -- Taken, and left out of the writes that [`Capture.after`] counts.
    r.foreign[n.id] = true
  end
end

local function ref_function(r: Reference, f: Ast.Fn, env: Decl?, own: Decl?)
  local inner = env
  -- The parameters of a `local function` are declared before its name: they shadow what it hid.
  for _, p in ipairs(f.params) do
    local binding = p.name
    if binding ~= nil then
      local hidden = find(inner, binding.name)
      if hidden ~= nil and own ~= nil and hidden == own then
        hidden = find(own.next, binding.name)
      end
      inner = push(r, inner, binding, f.id, false, hidden)
    end
  end
  ref_block(r, f.body.stats, inner, f.id)
end

ref_exp = function(r: Reference, e: Ast.Node, env: Decl?, fn: integer)
  if (e.kind == "Name") then
    use(r, e, env, fn, false)
  elseif (e.kind == "FunctionLit") then
    ref_function(r, e.fn, env, nil)
  else
    Ast.children(e, function(child: Ast.Node)
      ref_exp(r, child, env, fn)
    end)
  end
end

ref_block = function(r: Reference, stats: {Ast.Stat}, env: Decl?, fn: integer): Decl?
  local scope = env
  for _, s in ipairs(stats) do
    if (s.kind == "Local") then
      for _, v in ipairs(s.values) do
        ref_exp(r, v, scope, fn)
      end
      local after = scope
      for i, b in ipairs(s.bindings) do
        local value = s.values[i]
        local copies = value ~= nil and (value.kind == "Name") and value.text == b.name
        after = push(r, after, b, fn, b.attr ~= nil, find(after, b.name), copies)
      end
      scope = after
    elseif (s.kind == "LocalFunction") then
      local hidden = find(scope, s.name.name)
      scope = push(r, scope, s.name, fn, false, hidden)
      ref_function(r, s.fn, scope, scope)
    elseif (s.kind == "Assign") then
      for _, v in ipairs(s.values) do
        ref_exp(r, v, scope, fn)
      end
      for _, t in ipairs(s.targets) do
        if (t.kind == "Name") then
          r.assigns[t.id] = s
          use(r, t, scope, fn, true)
        else
          ref_exp(r, t, scope, fn)
        end
      end
    elseif (s.kind == "Do") then
      ref_block(r, s.body.stats, scope, fn)
    elseif (s.kind == "If") then
      for _, arm in ipairs(s.arms) do
        ref_exp(r, arm.cond, scope, fn)
        ref_block(r, arm.body.stats, scope, fn)
      end
      local other = s.else_body
      if other ~= nil then
        ref_block(r, other.stats, scope, fn)
      end
    elseif (s.kind == "While") then
      ref_exp(r, s.cond, scope, fn)
      ref_block(r, s.body.stats, scope, fn)
    elseif (s.kind == "Repeat") then
      local inside = ref_block(r, s.body.stats, scope, fn)
      ref_exp(r, s.cond, inside, fn)
    elseif (s.kind == "ForNum") then
      ref_exp(r, s.from, scope, fn)
      ref_exp(r, s.to, scope, fn)
      local inside = push(r, scope, s.var, fn, true, find(scope, s.var.name))
      ref_block(r, s.body.stats, inside, fn)
    elseif (s.kind == "ForIn") then
      for _, it in ipairs(s.iterators) do
        ref_exp(r, it, scope, fn)
      end
      local inside = scope
      for i, b in ipairs(s.vars) do
        inside = push(r, inside, b, fn, i == 1, find(inside, b.name))
      end
      ref_block(r, s.body.stats, inside, fn)
    else
      Ast.children(s, function(child: Ast.Node)
        ref_exp(r, child, scope, fn)
      end)
    end
  end
  return scope
end

local function reference(chunk: Ast.Chunk): Reference
  local r: Reference = { tokens = chunk.tokens, bound = {}, errors = {}, assigns = {}, foreign = {} }
  ref_block(r, chunk.body.stats, nil, chunk.id)
  table.sort(r.errors)
  return r
end

--- The first way [`Capture.after`] differs from the rule stated on the tokens: an assignment may
--- run after a function is made if its statement ends at or after the function's end, or a loop
--- that begins after the variable is declared holds the statement and the function.
local function naive_after(chunk: Ast.Chunk, scoped: Scopes.Scoped, r: Reference): string
  local loops: mut {Ast.Base} = {}
  local spans: mut {integer: Ast.Base} = {}
  local stack: mut {Ast.Node} = { chunk }
  while #stack > 0 do
    local node = stack[#stack]
    stack[#stack] = nil
    local base: Ast.Base = node
    if (node.kind == "Fn") then
      spans[base.id] = base
    elseif (node.kind == "While") or (node.kind == "Repeat") or (node.kind == "ForNum") or (node.kind == "ForIn") then
      loops[#loops + 1] = base
    end
    Ast.children(node, function(child: Ast.Node)
      stack[#stack + 1] = child
    end)
  end
  for _, v in ipairs(scoped.list) do
    for _, c in ipairs(v.captures) do
      local fn = spans[c.fn]
      local after = false
      for _, w in ipairs(v.writes) do
        local assign = r.assigns[w]
        if assign ~= nil and not r.foreign[w] and fn ~= nil then
          after = after or assign.last >= fn.last
          for _, loop in ipairs(loops) do
            after = after or (loop.first > v.declared and loop.first <= math.min(assign.first, fn.first) and
              loop.last >= math.max(assign.last, fn.last))
          end
        end
      end
      if after ~= c.after then
        return "the capture of `" .. v.name .. "` by the function at token " .. tostring(c.fn) .. " is " .. (if c.after then "" else "not " end) ..
          "followed by an assignment, the rule on tokens says " .. (if after then "it is" else "it is not" end)
      end
    end
  end
  return ""
end

-- The properties ------------------------------------------------------------

local function parse(input: string): Parser.Parsed
  return Parser.parse(Lexer.lex(input, "f.tl"), "f.tl", "tl")
end

local function draw(src: Fuzz.Source): function(min: integer, max: integer): integer
  return function(min: integer, max: integer): integer
    return src:int(min, max)
  end
end

local function gen_program(src: Fuzz.Source): string
  return Programs.generate(draw(src), { loop_writes = true, unknown = true })
end

--- The errors of `scoped` as `code y:x`, sorted.
local function listed(scoped: Scopes.Scoped): {string}
  local out: mut {string} = {}
  for _, e in ipairs(scoped.errors) do
    out[#out + 1] = e.code .. " " .. tostring(e.y) .. ":" .. tostring(e.x)
  end
  table.sort(out)
  return out
end

local function test_every_name_of_a_program_resolves_as_the_reference_says(tmp: string)
  Fuzz.run({
    name = "scopes resolve as the reference",
    dir = tmp,
    gen = gen_program,
    check = function(input: string): boolean, string
      local parsed = parse(input)
      local e = parsed.errors[1]
      if e ~= nil then
        return false, e.code .. " at " .. tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg
      end
      local scoped = Scopes.build(parsed.chunk, "f.tl", GLOBALS)
      local ok, why = Cover.check(parsed.chunk, scoped, GLOBALS)
      if not ok then
        return false, why
      end
      local expected = reference(parsed.chunk)
      for id, decl in pairs(expected.bound) do
        local got = scoped.resolved[id]
        if (got or 0) ~= decl then
          return false, "the name with id " .. tostring(id) .. " is bound to " .. tostring(got) .. ", the reference says " .. tostring(decl)
        end
      end
      local got, want = table.concat(listed(scoped), "; "), table.concat(expected.errors, "; ")
      if got ~= want then
        return false, "errors differ\n  got:  " .. got .. "\n  want: " .. want
      end
      local late = naive_after(parsed.chunk, scoped, expected)
      if late ~= "" then
        return false, late
      end
      for _, error_found in ipairs(scoped.errors) do
        Fuzz.label(error_found.code)
      end
      for _, v in ipairs(scoped.list) do
        for _, c in ipairs(v.captures) do
          Fuzz.label(if c.after then "captured, then assigned" else "captured" end)
        end
        if v.closure_assigned then
          Fuzz.label("closure assigned")
        end
        if v.copies ~= nil then
          Fuzz.label("copy")
        end
      end
      if input:find("repeat", 1, true) then
        Fuzz.label("repeat")
      end
      return true, ""
    end,
    requires = { "shadows", "unknown_variable", "const_assigned", "captured", "closure assigned",
      "captured, then assigned", "copy", "repeat" },
  })
end

local PIECES <const>: {string} = {
  "local", "function", "end", "if", "then", "else", "elseif", "while", "do", "for", "in", "repeat", "until", "return",
  "break", "match", "class", "record", "enum", "type", "require", "a", "b", "c", "self", "T", "1", "\"s\"", "nil", "true",
  "=", ",", ":", ".", "(", ")", "{", "}", "[", "]", "<const>", "<close>", "is", "mut", "asserts", "\n", "|",
}

--- The tokens of `input` with a few deleted, repeated, swapped or replaced.
local function gen_mutated(src: Fuzz.Source): string
  local tokens: mut {string} = {}
  for piece in gen_program(src):gmatch("%S+") do
    tokens[#tokens + 1] = piece
  end
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

local function gen_pieces(src: Fuzz.Source): string
  local out: mut {string} = {}
  while Fuzz.more(src, #out, 60) do
    out[#out + 1] = Fuzz.pick(src, PIECES)
  end
  return table.concat(out, " ")
end

--- Whether the scopes of `input`, as a program or a declaration file, are consistent with its tree.
local function holds(input: string): boolean, string
  local dialect: Ast.Dialect = if #input % 2 == 0 then "tl" else "decl" end
  local parsed = Parser.parse(Lexer.lex(input, "f.tl"), "f.tl", dialect)
  local scoped = Scopes.build(parsed.chunk, "f.tl", GLOBALS)
  local ok, why = Cover.check(parsed.chunk, scoped, GLOBALS)
  if not ok then
    return false, why
  end
  Fuzz.label(if #scoped.errors == 0 then "clean" else "refused" end)
  for _, e in ipairs(scoped.errors) do
    Fuzz.label(e.code)
  end
  return true, ""
end

local function test_a_program_with_a_few_tokens_changed_builds_consistent_scopes(tmp: string)
  Fuzz.run({
    name = "scopes of a mutated program",
    dir = tmp,
    gen = gen_mutated,
    check = holds,
    requires = { "clean", "refused", "unknown_variable", "shadows" },
    shares = { refused = 0.3 },
  })
end

local function test_any_run_of_tokens_builds_consistent_scopes(tmp: string)
  Fuzz.run({
    name = "scopes of any tokens",
    dir = tmp,
    gen = gen_pieces,
    check = holds,
    requires = { "refused", "unknown_variable" },
    shares = { refused = 0.5 },
  })
end
