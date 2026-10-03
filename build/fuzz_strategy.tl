--- Composable generators. A generator is an ordinary function of a
--- Source; closures can draw a field and use it to choose the next
--- field's domain. `draw` records their named structure for shrinking.
local Fuzz = require("build.fuzz")

local record Strategy
  type Gen<T> = function(Fuzz.Source): T
end

--- Draw a named value, including every nested draw in its span.
function Strategy.draw<T>(src: Fuzz.Source, name: string, gen: Strategy.Gen<T>): T
  src:begin_span(name)
  local value = gen(src)
  src:end_span()
  return value
end

--- A boolean, simplifying toward false.
function Strategy.boolean(src: Fuzz.Source): boolean
  return src:int(0, 1) ~= 0
end

--- Integers with half the draws uniform and half at domain boundaries,
--- zero, units, or powers of two and their neighbors. The full domain
--- remains reachable. Simplification prefers zero when it is in range.
function Strategy.integer(min: integer, max: integer): Strategy.Gen<integer>
  assert(min <= max, "strategy: empty integer domain")
  local target = math.max(min, math.min(max, 0))
  local special: {integer} = {}
  local seen: {integer: boolean} = {}
  local function add(n: integer)
    if n >= min and n <= max and not seen[n] then
      special[#special + 1], seen[n] = n, true
    end
  end
  add(target)
  add(min)
  add(max)
  add(-1)
  add(1)
  for bit = 1, 62 do
    local n = 1 << bit
    add(n - 1)
    add(n)
    add(n + 1)
    add(-n - 1)
    add(-n)
    add(-n + 1)
    if n >= max and -n <= min then break end
  end
  return function(src: Fuzz.Source): integer
    if src:int(0, 1) == 0 then return src:int(min, max, target) end
    return special[src:int(1, #special)]
  end
end

--- A choice of generators, ordered from simpler to more complex.
function Strategy.one_of<T>(choices: {Strategy.Gen<T>}): Strategy.Gen<T>
  assert(#choices > 0, "strategy: no alternatives")
  return function(src: Fuzz.Source): T
    return Strategy.draw(src, "alternative", choices[src:int(1, #choices)])
  end
end

--- Up to max non-nil values. Each element span includes its continuation draw,
--- letting the reducer delete an entire element without changing later
--- elements' interpretation.
function Strategy.list<T>(element: Strategy.Gen<T>, max: integer): Strategy.Gen<{T}>
  assert(max >= 0, "strategy: negative list limit")
  return function(src: Fuzz.Source): {T}
    local out: {T} = {}
    while #out < max do
      src:begin_span("element")
      if not Fuzz.more(src, #out, max) then
        src:end_span()
        break
      end
      local value = element(src)
      assert(value ~= nil, "strategy: list element is nil")
      out[#out + 1] = value
      src:end_span()
    end
    return out
  end
end

--- Arbitrary bytes; list structure is retained for shrinking.
function Strategy.bytes(max: integer): Strategy.Gen<string>
  local items = Strategy.list(function(src: Fuzz.Source): string
    return string.char(src:int(0, 255))
  end, max)
  return function(src: Fuzz.Source): string return table.concat(items(src)) end
end

--- Text from an explicit alphabet of strings (bytes or UTF-8 codepoints).
--- No encoding is inferred or repaired; the caller defines the domain.
function Strategy.text(alphabet: {string}, max: integer): Strategy.Gen<string>
  assert(#alphabet > 0, "strategy: empty alphabet")
  local items = Strategy.list(function(src: Fuzz.Source): string
    return Fuzz.pick(src, alphabet)
  end, max)
  return function(src: Fuzz.Source): string return table.concat(items(src)) end
end

--- A bounded recursive generator. Each level chooses a leaf twice as
--- often as an extension to limit growth of branching structures; depth
--- zero can only draw leaves.
function Strategy.recursive<T>(leaf: Strategy.Gen<T>,
    extend: function(Strategy.Gen<T>): Strategy.Gen<T>, depth: integer): Strategy.Gen<T>
  assert(depth >= 0, "strategy: negative recursion limit")
  local gen = leaf
  for _ = 1, depth do gen = Strategy.one_of({ leaf, leaf, extend(gen) }) end
  return gen
end

return Strategy
