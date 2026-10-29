--- Programs for the tests of [`lang.scopes`]: a generator of programs that
--- bind and use names in every way Lua's scoping allows (nested blocks and
--- functions, shadowing, `local x = x`, `repeat ... until`, loop variables,
--- assignments to names of the enclosing function), written in the part of
--- the grammar that Teal shares, so that the fork and the new checker read
--- the same text. Names come from a small pool, so that one is often bound
--- twice and used from a function inside the scope that binds it, and now
--- and then a name that nothing binds, which is a global.
local record Programs
  record Options
    --- Whether a program may assign a loop's control variable, which Lua 5.5 refuses.
    loop_writes: boolean
    --- Whether a program may use a name that nothing declares.
    unknown: boolean
  end

  --- A program from the integers `draw` hands out, one in the range asked for each time.
  generate: function(draw: function(min: integer, max: integer): integer, options: Options): string
end

local POOL <const>: {string} = { "a", "b", "c", "d", "e", "f", "g", "h" }

local record Gen
  draw: function(min: integer, max: integer): integer
  out: mut {string}
  --- The names in scope as the draw sees them, innermost last, and whether each is a loop's control variable.
  seen: mut {string}
  readonly: mut {boolean}
  options: Programs.Options
end

local gen_exp: function(g: Gen, depth: integer)
local gen_block: function(g: Gen, depth: integer, loop: boolean, keep?: boolean)

local function pick(g: Gen, choices: {string}): string
  return choices[g.draw(1, #choices)]
end

--- Whether a list that holds `have` elements of at most `max` takes one more: a draw before
--- each, so that a shrinking input can drop any one.
local function more(g: Gen, have: integer, max: integer): boolean
  return have < max and g.draw(0, math.max(1, (max + 1) // 2)) ~= 0
end

local function add(g: Gen, ...: string)
  for i = 1, select("#", ...) do
    local appended = (select(i, ...))
    g.out[#g.out + 1] = appended
  end
end

local function declare(g: Gen, name: string, readonly: boolean)
  g.seen[#g.seen + 1] = name
  g.readonly[#g.seen] = readonly
end

local function forget(g: Gen, mark: integer)
  for i = #g.seen, mark + 1, -1 do
    g.seen[i] = nil
    g.readonly[i] = nil
  end
end

--- A name to read: mostly one in scope, sometimes any of the pool.
local function use(g: Gen): string
  local n = #g.seen
  if n > 0 and g.draw(1, 10) <= 8 then
    return g.seen[g.draw(1, n)]
  end
  local name = pick(g, POOL)
  if not g.options.unknown then
    for i = n, 1, -1 do
      if g.seen[i] == name then
        return name
      end
    end
    return n > 0 and g.seen[g.draw(1, n)] or "print"
  end
  return name
end

local function gen_list(g: Gen, depth: integer, max: integer)
  local n = 0
  while n == 0 or more(g, n, max) do
    if n > 0 then
      add(g, ",")
    end
    n = n + 1
    gen_exp(g, depth)
  end
end

--- A function literal or the rest of a `local function`: `(params) body end`.
local function gen_function(g: Gen, depth: integer)
  local mark = #g.seen
  add(g, "(")
  for i = 1, g.draw(0, 2) do
    local name = pick(g, POOL)
    add(g, if i > 1 then "," else "" end, name)
    declare(g, name, false)
  end
  add(g, ")", "\n")
  gen_block(g, depth - 1, false)
  add(g, "end")
  forget(g, mark)
end

gen_exp = function(g: Gen, depth: integer)
  local k = g.draw(1, if depth > 0 then 9 else 3 end)
  if k <= 3 then
    add(g, use(g))
  elseif k == 4 then
    add(g, tostring(g.draw(0, 99)))
  elseif k == 5 then
    gen_exp(g, depth - 1)
    add(g, pick(g, { "+", "..", "==", "and", "or" }))
    gen_exp(g, depth - 1)
  elseif k == 6 then
    add(g, use(g), "(")
    gen_list(g, depth - 1, 2)
    add(g, ")")
  elseif k == 7 then
    add(g, "function")
    gen_function(g, depth)
  elseif k == 8 then
    add(g, "{")
    gen_list(g, depth - 1, 3)
    add(g, "}")
  else
    add(g, use(g), ".", "k")
  end
end

local function gen_statement(g: Gen, depth: integer, loop: boolean)
  local k = g.draw(1, if depth > 0 then 13 else 4 end)
  local mark = #g.seen
  if k <= 3 then
    local names: mut {string} = {}
    for i = 1, g.draw(1, 3) do
      names[i] = pick(g, POOL)
    end
    -- `local x = x`, the copy that does not shadow.
    local copy = #g.seen > 0 and g.draw(1, 5) == 1
    if copy then
      names = { g.seen[g.draw(1, #g.seen)] }
    end
    add(g, "local", table.concat(names, ", "), "=")
    if copy then
      add(g, names[1])
    else
      gen_list(g, depth, 3)
    end
    for _, name in ipairs(names) do
      declare(g, name, false)
    end
    return
  elseif k == 4 then
    local name = use(g)
    for i = #g.seen, 1, -1 do
      if g.seen[i] == name and g.readonly[i] == true and not g.options.loop_writes then
        add(g, "print", "(", name, ")")
        return
      end
    end
    -- A first target that is an index holding a function, which assigns names of its own.
    local indexed = depth > 0 and g.draw(1, 4) == 1
    if indexed then
      add(g, use(g), "[", "function")
      gen_function(g, depth)
      add(g, "]", ",")
    end
    add(g, name, "=")
    gen_exp(g, depth)
    if indexed then
      add(g, ",")
      gen_exp(g, depth)
    end
  elseif k == 5 then
    add(g, use(g), "(")
    gen_list(g, depth - 1, 2)
    add(g, ")")
  elseif k == 6 then
    local name = pick(g, POOL)
    add(g, "local", "function", name)
    declare(g, name, false)
    gen_function(g, depth)
    return
  elseif k == 7 then
    add(g, "do", "\n")
    gen_block(g, depth - 1, loop)
    add(g, "end")
  elseif k == 8 then
    add(g, "if")
    gen_exp(g, depth - 1)
    add(g, "then", "\n")
    gen_block(g, depth - 1, loop)
    if g.draw(1, 2) == 1 then
      add(g, "elseif")
      gen_exp(g, depth - 1)
      add(g, "then", "\n")
      gen_block(g, depth - 1, loop)
    end
    if g.draw(1, 2) == 1 then
      add(g, "else", "\n")
      gen_block(g, depth - 1, loop)
    end
    add(g, "end")
  elseif k == 9 then
    add(g, "while")
    gen_exp(g, depth - 1)
    add(g, "do", "\n")
    gen_block(g, depth - 1, true)
    add(g, "end")
  elseif k == 10 then
    local name = pick(g, POOL)
    add(g, "for", name, "=", "1", ",", "#", "{")
    gen_exp(g, depth - 1)
    add(g, "}", "do", "\n")
    declare(g, name, true)
    gen_block(g, depth - 1, true)
    add(g, "end")
  elseif k == 11 then
    local first, second = pick(g, POOL), pick(g, POOL)
    add(g, "for", first, ",", second, "in", "pairs", "(", "{")
    gen_exp(g, depth - 1)
    add(g, "}", ")", "do", "\n")
    declare(g, first, true)
    declare(g, second, false)
    gen_block(g, depth - 1, true)
    add(g, "end")
  elseif k == 12 then
    -- The `until` reads the names of the body.
    add(g, "repeat", "\n")
    gen_block(g, depth - 1, true, true)
    add(g, "until")
    gen_exp(g, depth - 1)
  elseif loop then
    add(g, "break")
  else
    add(g, "print", "(")
    gen_exp(g, depth - 1)
    add(g, ")")
  end
  forget(g, mark)
end

gen_block = function(g: Gen, depth: integer, loop: boolean, keep?: boolean)
  local mark = #g.seen
  local n = 0
  while more(g, n, 5) do
    n = n + 1
    gen_statement(g, depth, loop)
    add(g, "\n")
  end
  if g.draw(1, 6) == 1 then
    add(g, "return")
    gen_exp(g, depth - 1)
    add(g, "\n")
  end
  if keep ~= true then
    forget(g, mark)
  end
end

function Programs.generate(draw: function(min: integer, max: integer): integer, options: Programs.Options): string
  local g: Gen = { draw = draw, out = {}, seen = {}, readonly = {}, options = options }
  gen_block(g, 3, false)
  return table.concat(g.out, " ")
end

return Programs
