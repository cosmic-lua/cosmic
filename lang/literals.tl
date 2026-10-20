--- The literal arguments of the standard library that Lua reads at run time and raises on: the pattern of `find`,
--- `match`, `gmatch` and `gsub`, the replacement string of `gsub`, the format of `string.format` and the format of
--- `string.pack`, `unpack` and `packsize`. [`lang.check`] reads a literal one passes and refuses what Lua would raise
--- on, where the fork's `parse_pattern_string`, `parse_format_string` and `parse_pack_string` did, with the checks of
--- `lstrlib.c` in the Lua the tree is built with (5.5).
---
--- A reader walks the whole string, as the matcher would if it reached every part: Lua raises on a pattern only where
--- the match gets as far as the fault, which is a property of the subject, and a pattern that is wrong for some subject
--- is wrong. Each answers the first fault it finds, with what it is and the fix.
local Codes = require("lang.check_codes")

local record Literals
  --- What is wrong with a literal.
  record Problem
    --- What the fault is, in one line.
    msg: string
    --- How to put it right.
    fix: string
  end

  --- The captures of a pattern and its fault, if it has one.
  record PatternRead
    --- The kind of each capture, in order: `string` for `( ... )` and `position` for `()`.
    captures: {string}
    problem: Problem | nil
  end

  --- The values a format takes and its fault, if it has one.
  record FormatRead
    --- The type each argument after the format has, in order: `integer` (`c d i u o x X`), `number` (`a A e E f g G`), `any`
    --- (`s p`) or `quoted` (`q`, which writes a string, a number, a boolean or nil).
    kinds: {string}
    problem: Problem | nil
  end

  --- What a replacement string of `gsub` is, and its fault, if it has one.
  record PackRead
    --- The type each value has, in order, for `pack` (the arguments after the format) and `unpack` (its results before the
    --- position): `integer`, `number` or `string`.
    kinds: {string}
    --- Whether it holds an option whose size depends on the value (`s`, `z`), which `packsize` cannot answer.
    variable: boolean
    problem: Problem | nil
  end

  --- A fault found in the literal arguments of a call.
  record Finding
    --- The code of [`lang.check_codes`] it is reported with.
    code: Codes.Code
    --- The argument it is in, counting the receiver of a method call as the first.
    place: integer
    msg: string
    fix: string
  end

  --- The literal arguments of a call of a function of the string library, as the call is written: `fn` is its name
  --- (`find`, `match`, `gmatch`, `gsub`, `format`, `pack`, `unpack` or `packsize`), `literals` the text of each
  --- argument that is a string literal, or a name given one and never assigned, by its place (the receiver of a method
  --- call is the first). `plain` is the fourth argument of `find`: "none", "false", "true" or "other" for what is not a literal.
  record Call
    fn: string
    literals: {integer: string}
    plain: string
  end

  --- Reads `pattern` as the matcher of `find`, `match`, `gmatch` and `gsub` does.
  pattern: function(pattern: string): PatternRead

  --- Reads `replacement`, the string a `gsub` writes for each match, given the number of captures of its pattern.
  replacement: function(replacement: string, captures: integer): Problem | nil

  --- Reads `format` as `string.format` does.
  format: function(format: string): FormatRead

  --- Reads `format` as `string.pack`, `string.unpack` and `string.packsize` do.
  pack: function(format: string): PackRead

  --- The functions of the string library whose literal arguments are read, by name.
  functions: {string: boolean}

  --- The faults in the literal arguments of `call`, in the order of the arguments.
  check: function(call: Call): {Finding}

  --- The type of the keys of the table a `gsub` with the literal `pattern` looks its matches up in: `integer` where
  --- the first capture is a position `()`, and `string` otherwise (the whole match, or a captured text). Nil when
  --- the pattern is malformed.
  key: function(pattern: string): string | nil
end

--- `LUA_MAXCAPTURES`.
local MAX_CAPTURES <const> = 32
--- `MAXINTSIZE`: the most bytes an integer option may take.
local MAX_INT_SIZE <const> = 16
--- The alignment `!` sets when it names none: that of the widest type of the build (`LUAI_MAXALIGN` is a `long double`, 16
--- here and 8 on a host whose `long double` is a `double`). A host with less accepts what this refuses (`!i12` clamps to 8
--- there and raises here), so a format that depends on it is refused.
local NATIVE_ALIGN <const> = 16

local function at(i: integer): string
  return "at character " .. tostring(i)
end

local function problem(msg: string, fix: string): Literals.Problem
  return { msg = msg, fix = fix }
end

local function shown(c: string): string
  return "`" .. c .. "`"
end

-- patterns ---------------------------------------------------------------------------------------------------------

--- The index after the set that opens at `i` (a `[`), or nil when no `]` closes it. A `]` right after the opening
--- (or after `^`) belongs to the set, and a `%` skips the character after it. A repetition mark and a `$` are characters
--- like the rest to this walk, which looks for the faults of a pattern and not for what it matches.
local function set_end(pattern: string, i: integer): integer | nil
  local n = #pattern
  local p = i + 1
  if pattern:sub(p, p) == "^" then
    p = p + 1
  end
  repeat
    if p > n then
      return nil
    end
    local c = pattern:sub(p, p)
    p = p + 1
    if c == "%" then
      p = p + 1
    end
  until pattern:sub(p, p) == "]"
  return p + 1
end

local function read_pattern(pattern: string): Literals.PatternRead
  local n = #pattern
  local kinds: {string} = {}
  local closed: {integer: boolean} = {}
  local starts: {integer: integer} = {}
  local unfinished: {integer} = {}
  local function stop(msg: string, fix: string): Literals.PatternRead
    return { captures = kinds, problem = problem(msg, fix) }
  end
  local i = 1
  if pattern:sub(1, 1) == "^" then
    i = 2
  end
  while i <= n do
    local c = pattern:sub(i, i)
    if c == "(" then
      if #kinds >= MAX_CAPTURES then
        return stop("the pattern has more than " .. tostring(MAX_CAPTURES) .. " captures (" .. at(i) .. ")",
          "capture at most " .. tostring(MAX_CAPTURES) .. " parts, or match in two steps")
      end
      if pattern:sub(i + 1, i + 1) == ")" then
        kinds[#kinds + 1] = "position"
        closed[#kinds] = true
        i = i + 2
      else
        kinds[#kinds + 1] = "string"
        starts[#kinds] = i
        closed[#kinds] = false
        unfinished[#unfinished + 1] = #kinds
        i = i + 1
      end
    elseif c == ")" then
      local last = unfinished[#unfinished]
      if last == nil then
        return stop("`)` closes no capture (" .. at(i) .. "), and Lua raises \"invalid pattern capture\"",
          "escape it as `%)` to match the character, or open the capture with `(` before it; to search for the text " ..
            "itself, pass `true` as the plain argument of `find`")
      end
      table.remove(unfinished)
      closed[last] = true
      i = i + 1
    elseif c == "%" then
      local d = pattern:sub(i + 1, i + 1)
      if d == "" then
        return stop("the pattern ends with `%` (" .. at(i) .. "), and Lua raises \"malformed pattern (ends with '%')\"",
          "write `%%` to match a percent sign")
      elseif d == "b" then
        if i + 3 > n then
          return stop("`%b` is not followed by the two characters it balances (" .. at(i) .. "), and Lua raises " ..
              "\"malformed pattern (missing arguments to '%b')\"",
            "write the pair after it: `%b()` matches a balanced pair of parentheses")
        end
        i = i + 4
      elseif d == "f" then
        if pattern:sub(i + 2, i + 2) ~= "[" then
          return stop("`%f` is not followed by a set (" .. at(i) .. "), and Lua raises \"missing '[' after '%f' in " ..
              "pattern\"",
            "write the set after it: `%f[%w]` matches the start of a word")
        end
        local stopped = set_end(pattern, i + 2)
        if stopped == nil then
          return stop("the set of `%f` has no closing `]` (" .. at(i + 2) .. "), and Lua raises \"malformed pattern " ..
              "(missing ']')\"",
            "close the set with `]`")
        end
        i = stopped
      elseif d:find("^%d") ~= nil then
        local k = d:byte() - 48
        -- `closed` holds the captures a `)` has closed, so `%0` and an index past the captures are none
        if not closed[k] then
          return stop(shown("%" .. d) .. " refers to a capture that is not closed before it (" .. at(i) .. "), and Lua " ..
              "raises \"invalid capture index %" .. d .. "\"",
            "refer only to a capture that an earlier `( ... )` has closed (`%1` is the first), and write `%%` to match " ..
              "a percent sign")
        end
        i = i + 2
      else
        i = i + 2
      end
    elseif c == "[" then
      local stopped = set_end(pattern, i)
      if stopped == nil then
        return stop("the set has no closing `]` (" .. at(i) .. "), and Lua raises \"malformed pattern (missing ']')\"",
          "close the set with `]`, or escape the bracket as `%[` to match it; to search for the text itself, pass " ..
            "`true` as the plain argument of `find`")
      end
      i = stopped
    else
      i = i + 1
    end
  end
  local open = unfinished[1]
  if open ~= nil then
    return stop("capture " .. tostring(open) .. " is never closed (" .. at(starts[open] or 1) .. "), and Lua raises " ..
        "\"unfinished capture\"",
      "close it with `)`, or escape the parenthesis as `%(` to match it")
  end
  return { captures = kinds, problem = nil }
end

local function read_replacement(replacement: string, captures: integer): Literals.Problem | nil
  local n = #replacement
  local i = 1
  while i <= n do
    if replacement:sub(i, i) == "%" then
      local d = replacement:sub(i + 1, i + 1)
      if d:find("^%d") ~= nil then
        local k = d:byte() - 48
        -- `%1` is the whole match when the pattern has no capture
        if k > 1 and k > captures then
          return problem("`%" .. d .. "` is used, and the pattern has " .. (captures == 0 and "no capture" or
            tostring(captures) .. (captures == 1 and " capture" or " captures")) .. " (" .. at(i) .. "), where Lua raises " ..
              "\"invalid capture index %" .. d .. "\"",
            "use `%0` for the whole match and `%1` to `%" .. tostring(math.max(captures, 1)) .. "` for the captures")
        end
      elseif d ~= "%" then
        return problem("the replacement has a `%` that is followed by " .. (d == "" and "nothing" or shown(d)) .. " (" .. at(i) ..
            "), and Lua raises \"invalid use of '%' in replacement string\"",
          "write `%%` for a percent sign, or `%0` to `%9` for the match and the captures")
      end
      i = i + 2
    else
      i = i + 1
    end
  end
  return nil
end

-- formats ----------------------------------------------------------------------------------------------------------

--- The index after the run of `chars` (a set of single characters) in `s` from `i`, at most `limit` characters.
local function span(s: string, i: integer, chars: string, limit: integer): integer
  local j = i
  while j <= #s and j - i < limit and chars:find(s:sub(j, j), 1, true) ~= nil do
    j = j + 1
  end
  return j
end

--- The flags a conversion accepts, and whether it accepts a precision (`checkformat` of lstrlib.c).
local record Conversion
  flags: string
  precision: boolean
end

local CONVERSIONS <const>: {string: Conversion} = {
  c = { flags = "-", precision = false },
  d = { flags = "-+0 ", precision = true },
  i = { flags = "-+0 ", precision = true },
  u = { flags = "-0", precision = true },
  o = { flags = "-#0", precision = true },
  x = { flags = "-#0", precision = true },
  X = { flags = "-#0", precision = true },
  a = { flags = "-+#0 ", precision = true },
  A = { flags = "-+#0 ", precision = true },
  e = { flags = "-+#0 ", precision = true },
  E = { flags = "-+#0 ", precision = true },
  f = { flags = "-+#0 ", precision = true },
  g = { flags = "-+#0 ", precision = true },
  G = { flags = "-+#0 ", precision = true },
  p = { flags = "-", precision = false },
  s = { flags = "-", precision = true },
}

--- The type an argument has for each conversion.
local FORMAT_KINDS <const>: {string: string} = {
  c = "integer", d = "integer", i = "integer", u = "integer", o = "integer", x = "integer", X = "integer",
  a = "number", A = "number", e = "number", E = "number", f = "number", g = "number", G = "number",
  s = "any", p = "any", q = "quoted",
}

local function read_format(format: string): Literals.FormatRead
  local n = #format
  local kinds: {string} = {}
  local i = 1
  while i <= n do
    if format:sub(i, i) ~= "%" then
      i = i + 1
    elseif format:sub(i + 1, i + 1) == "%" then
      i = i + 2
    else
      local spec_at = span(format, i + 1, "-+#0 123456789.", n)
      local conversion = format:sub(spec_at, spec_at)
      kinds[#kinds + 1] = FORMAT_KINDS[conversion] or "any"
      local form = format:sub(i, spec_at)
      if spec_at - i >= 22 then
        return { kinds = kinds, problem = problem("the conversion `" .. form .. "...` is too long (" .. at(i) .. "), and " ..
            "Lua raises \"invalid format (too long)\"", "write flags, a width of at most two digits and a precision of at " ..
            "most two digits") }
      end
      if conversion == "q" then
        if spec_at - i > 1 then
          return { kinds = kinds, problem = problem("`" .. form .. "` has modifiers (" .. at(i) .. "), and Lua raises " ..
              "\"specifier '%q' cannot have modifiers\"", "write `%q` alone") }
        end
      else
        local rule = CONVERSIONS[conversion]
        if rule == nil then
          return { kinds = kinds, problem = problem("`" .. form .. "` is no conversion of `string.format` (" .. at(i) ..
              "), and Lua raises \"invalid conversion '" .. form .. "' to 'format'\"",
            "write `%d` or `%i` for an integer, `%f`, `%e` or `%g` for a number, `%s` for text, `%q` for a quoted " ..
              "string, `%x` for hexadecimal, `%c` for a character, or `%%` for a percent sign") }
        end
        -- after the flags the width may not begin with `0`, then at most two digits and a precision of at most two
        local p = span(format, i + 1, rule.flags, n)
        if format:sub(p, p) ~= "0" then
          p = span(format, p, "0123456789", 2)
          if format:sub(p, p) == "." and rule.precision then
            p = span(format, p + 1, "0123456789", 2)
          end
        end
        if p ~= spec_at then
          return { kinds = kinds, problem = problem("`" .. form .. "` has a flag, width or precision that `%" ..
              conversion .. "` does not take (" .. at(i) .. "), and Lua raises \"invalid conversion specification: '" .. form ..
              "'\"", "`%" .. conversion .. "` takes the flags `" .. rule.flags .. "`, a width of at most two digits" ..
              (rule.precision and " and a precision of at most two digits" or " and no precision")) }
        end
      end
      i = spec_at + 1
    end
  end
  return { kinds = kinds, problem = nil }
end

-- packed formats ---------------------------------------------------------------------------------------------------

--- What an option of a pack format is.
local record Option
  --- The letter read.
  kind: string
  --- Its size in bytes, which is the alignment it asks for.
  size: integer
  --- Whether it takes a value of `pack`.
  value: boolean
  --- Whether its size depends on the value (`s`, `z`).
  variable: boolean
  --- `c`, which needs no alignment.
  fixed_string: boolean
end

--- Where a walk of a format is.
local record PackState
  format: string
  --- The next character.
  i: integer
  variable: boolean
  --- The widest alignment `!` allows.
  max_align: integer
  --- The type of each value, in order.
  kinds: {string}
  --- The first fault.
  bad: Literals.Problem | nil
end

local SIZES <const>: {string: integer} = {
  b = 1, B = 1, h = 2, H = 2, l = 8, L = 8, j = 8, J = 8, T = 8, f = 4, n = 8, d = 8,
}

local function has_digit(s: PackState, i: integer): boolean
  return s.format:sub(i, i):find("^%d") ~= nil
end

--- The number at the walk, or `default`; the walk moves past it.
local function pack_number(s: PackState, default: integer): integer
  local value = 0
  local j = s.i
  while has_digit(s, j) do
    value = value * 10 + (s.format:byte(j) - 48)
    if value > 1000000 then
      value = 1000000
    end
    j = j + 1
  end
  if j == s.i then
    return default
  end
  s.i = j
  return value
end

local function pack_stop(s: PackState, msg: string, fix: string)
  if s.bad == nil then
    s.bad = problem(msg, fix)
  end
end

local function plain(kind: string, size: integer, value: boolean): Option
  return { kind = kind, size = size, value = value, variable = false, fixed_string = false }
end

--- Reads the option at the walk and moves past it. A fault is left in the state, and the option is then nil.
local function pack_option(s: PackState): Option | nil
  local at_i = s.i
  local c = s.format:sub(at_i, at_i)
  s.i = at_i + 1
  local fixed = SIZES[c]
  if fixed ~= nil then
    return plain(c, fixed, true)
  elseif c == "i" or c == "I" or c == "s" or c == "!" then
    local size = pack_number(s, c == "s" and 8 or c == "!" and NATIVE_ALIGN or 4)
    if size < 1 or size > MAX_INT_SIZE then
      pack_stop(s, "`" .. c .. tostring(size) .. "` is out of range (" .. at(at_i) .. "), and Lua raises \"integral size (" ..
          tostring(size) .. ") out of limits [1,16]\"", "write a size from 1 to 16 after `" .. c .. "`")
      return nil
    end
    if c == "s" then
      return { kind = c, size = size, value = true, variable = true, fixed_string = false }
    elseif c == "!" then
      s.max_align = size
      return plain(c, 0, false)
    end
    return plain(c, size, true)
  elseif c == "c" then
    if not has_digit(s, s.i) then
      pack_stop(s, "`c` has no size (" .. at(at_i) .. "), and Lua raises \"missing size for format option 'c'\"",
        "write the length of the string after it: `c8`")
      return nil
    end
    return { kind = c, size = pack_number(s, 0), value = true, variable = false, fixed_string = true }
  elseif c == "z" then
    return { kind = c, size = 0, value = true, variable = true, fixed_string = false }
  elseif c == "x" then
    return plain(c, 1, false)
  elseif c == "X" then
    return plain(c, 0, false)
  elseif c == " " or c == "<" or c == ">" or c == "=" then
    return plain(c, 0, false)
  end
  pack_stop(s, "`" .. c .. "` is no option of `string.pack` (" .. at(at_i) .. "), and Lua raises \"invalid format option '" ..
      c .. "'\"", "write one of `b B h H i I l L j J T f d n s z c x X < > = !` and a space, with a size after `i I s c !`")
  return nil
end

--- The type of the value of each option that takes one; the sized integers `b h i j l T` and their unsigned forms are `integer`.
local PACK_KINDS <const>: {string: string} = { f = "number", d = "number", n = "number", s = "string", z = "string", c = "string" }

local function read_pack(format: string): Literals.PackRead
  local s: PackState = { format = format, i = 1, kinds = {}, variable = false, max_align = 1, bad = nil }
  while s.i <= #format and s.bad == nil do
    local at_i = s.i
    local o = pack_option(s)
    if o ~= nil then
      local align = o.size
      if o.kind == "X" then
        local next_at = s.i
        local after: Option | nil = nil
        if next_at <= #format then
          after = pack_option(s)
        end
        if s.bad == nil and (after == nil or after.fixed_string or after.size == 0) then
          pack_stop(s, "`X` aligns to " .. (after == nil and "nothing" or "an option that has no alignment") .. " (" ..
              at(at_i) .. "), and Lua raises \"invalid next option for option 'X'\"",
            "follow `X` with an option of a size, such as `Xi4`")
        end
        align = after ~= nil and after.size or 0
      end
      if s.bad == nil and align > 1 and not o.fixed_string then
        if align > s.max_align then
          align = s.max_align
        end
        if align & (align - 1) ~= 0 then
          pack_stop(s, "an option asks for an alignment of " .. tostring(align) .. " (" .. at(at_i) .. "), and Lua raises " ..
              "\"format asks for alignment not power of 2\"", "use a size that is a power of 2 under `!`")
        end
      end
      if o.value then
        s.kinds[#s.kinds + 1] = PACK_KINDS[o.kind] or "integer"
      end
      s.variable = s.variable or o.variable
    end
  end
  return { kinds = s.kinds, variable = s.variable, problem = s.bad }
end

local PLAIN <const>: {string: boolean} = { none = true, ["false"] = true }

local function finding(code: Codes.Code, place: integer, what: string, fn: string, p: Literals.Problem): Literals.Finding
  return { code = code, place = place, msg = "the " .. what .. " of `" .. fn .. "` is malformed: " .. p.msg, fix = p.fix }
end

local function check(call: Literals.Call): {Literals.Finding}
  local found: {Literals.Finding} = {}
  local fn = call.fn
  local first = call.literals[1]
  local second = call.literals[2]
  if second ~= nil and (fn == "match" or fn == "gmatch" or fn == "gsub" or (fn == "find" and PLAIN[call.plain])) then
    local read = read_pattern(second)
    local trouble = read.problem
    if trouble ~= nil then
      found[#found + 1] = finding("pattern_malformed", 2, "pattern", fn, trouble)
    elseif fn == "gsub" then
      local replacement = call.literals[3]
      local bad = replacement ~= nil and read_replacement(replacement, #read.captures) or nil
      if bad ~= nil then
        found[#found + 1] = finding("pattern_malformed", 3, "replacement", fn, bad)
      end
    end
  end
  if first ~= nil and fn == "format" then
    local read = read_format(first)
    local trouble = read.problem
    if trouble ~= nil then
      found[#found + 1] = finding("format_malformed", 1, "format", "string.format", trouble)
    end
  elseif first ~= nil and (fn == "pack" or fn == "unpack" or fn == "packsize") then
    local read = read_pack(first)
    local name = "string." .. fn
    local trouble = read.problem
    if trouble ~= nil then
      found[#found + 1] = finding("pack_malformed", 1, "format", name, trouble)
    elseif fn == "packsize" and read.variable then
      found[#found + 1] = { code = "pack_malformed", place = 1,
        msg = "the format of `string.packsize` has a variable-size option (`s` or `z`), and Lua raises \"variable-length format\"",
        fix = "`packsize` answers the size of fixed options only: use `c<n>` for a string of known length, or pack the value " ..
          "and take its length" }
    end
  end
  return found
end

local function key_of(pattern: string): string | nil
  local read = read_pattern(pattern)
  if read.problem ~= nil then
    return nil
  end
  return read.captures[1] == "position" and "integer" or "string"
end

Literals.pattern = read_pattern
Literals.replacement = read_replacement
Literals.format = read_format
Literals.pack = read_pack
Literals.check = check
Literals.functions = {
  find = true, match = true, gmatch = true, gsub = true, format = true, pack = true, unpack = true, packsize = true,
}
Literals.key = key_of

return Literals
