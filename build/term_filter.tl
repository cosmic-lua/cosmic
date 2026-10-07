--- The filter `cosmic sandbox` puts between a sandboxed program's
--- terminal and the caller's own: a stateful reader of the bytes the
--- program wrote to its pty, answering the bytes safe to write on to the
--- caller's terminal. What the program writes is untrusted: a terminal
--- obeys control sequences that set its title, write the user's
--- clipboard (OSC 52), ask it questions whose answers arrive as input,
--- or reset it, so nothing passes but text and the few sequences a
--- program draws a screen with.
---
--- WHAT PASSES: printable ASCII; valid UTF-8 (overlong forms, surrogates
--- and anything past U+10FFFF dropped, and the C1 controls U+0080 to
--- U+009F too, which a UTF-8 terminal obeys as their 8-bit forms);
--- carriage return, line feed, tab, backspace and BEL; ESC 7 and ESC 8
--- (save and restore the cursor); and the CSI sequences of
--- [`TermFilter.new`], each whole and byte for byte as it was written.
---
--- WHAT DOES NOT: every other byte, and every sequence not named above,
--- is dropped whole: OSC, DCS, APC, PM and SOS strings, every other ESC
--- sequence (the 7-bit forms of C1 controls among them), a CSI with an
--- intermediate byte, a private prefix other than `?` on a mode, an
--- unlisted final byte, a parameter the listing does not allow, or more
--- parameters or bytes than the listing's bounds, and the 8-bit C1
--- controls. A sequence is never passed in part: the terminal's parser is
--- in its ground state whenever this filter has passed anything, so
--- nothing it reads of a sequence can be completed by what follows. A
--- sequence that is cut short by ESC, CAN, SUB or any other control byte
--- is dropped and the byte that cut it is read afresh.
---
--- QUERIES are answered here and never passed: `CSI 6n` (cursor
--- position) and `CSI c` or `CSI 0 c` (primary device attributes) give
--- the second result of [`TermFilter.Filter.feed`], which the relay writes
--- back to the program as its terminal's input. The position answered is
--- a fixed `1;1`, not the cursor's: the filter does not track it (it
--- would have to know every width, wrap and scroll the terminal does),
--- and a position the program cannot trust is safer than one that is
--- wrong in a way it acts on. The attributes answered are those of a
--- VT100 with the advanced video option, `CSI ? 1 ; 2 c`, which claims
--- no feature the filter does not pass. Every other query (`CSI 5n`, `CSI
--- > c`, a mode report, a window report) is dropped without an answer.
---
--- WHAT A PROGRAM CAN STILL DO with what passes: cursor addressing and
--- erasing (CUP, ED, EL) let it overwrite text already on the screen
--- with text of its own, which a terminal's output cannot be kept from
--- while it draws a screen at all.
---
--- COST is linear in the bytes fed: each byte is read once, a run of
--- ordinary bytes is skipped by one pattern match from where the last
--- ended, and nothing a sequence holds grows past a fixed bound
--- (128 bytes). A string being dropped holds
--- nothing at all, as a terminal's own parser does, and ends at its
--- terminator: ST, BEL for an OSC, or ESC.
---
--- The filter is a state: feed it the chunks in order, split anywhere.
--- What it passes does not depend on where the chunks end, but for a
--- UTF-8 character or a sequence cut by the end of a chunk, which waits
--- for the next.

local byte <const> = string.byte
local find <const> = string.find
local sub <const> = string.sub
local char <const> = string.char
local concat <const> = table.concat

local ESC <const> = 0x1b
local CAN <const> = 0x18
local SUB_CONTROL <const> = 0x1a
local BEL <const> = 0x07

local GROUND <const> = 0
local AFTER_ESC <const> = 1
local IN_CSI <const> = 2
local IGNORING_CSI <const> = 3
local IGNORING_ESC <const> = 4
local IN_STRING <const> = 5
local STRING_ESC <const> = 6

--- Mode defaults a terminal starts in, and so the modes a program
--- may set and the state `restore` returns each to.
local MODE_DEFAULTS <const>: {integer:boolean} = {
  [1] = false, [7] = true, [25] = true, [47] = false, [1047] = false, [1049] = false,
  [2004] = false,
}

--- The answers to the queries the filter takes.
local CURSOR_REPORT <const> = "\27[1;1R"
local DEVICE_ATTRIBUTES <const> = "\27[?1;2c"

--- The most bytes of parameters a CSI holds, and so of all that follows
--- its `[` before its final byte: 128 is room for a true-colour
--- foreground and background and a handful of attributes. A sequence past
--- it is dropped whole.
local MOST_PARAMETER_BYTES <const> = 128

--- The most parameters a sequence may carry: of an SGR, 32; of a mode, 8;
--- the other listed sequences have one or two (their patterns say).
local MOST_SGR_PARAMETERS <const> = 32
local MOST_MODES <const> = 8

--- What the filter's terminal state was left as, for `restore`.
local record Filter
  --- Reads `chunk`, the next bytes the program wrote, and answers what
  --- may be written to the caller's terminal, and what to answer the
  --- program's queries with (written to the pty's master). Either may be
  --- empty. Total over any bytes: it never raises for its input.
  feed: function(Filter, chunk: string): string, string
  --- The sequences that return the terminal to the state it started in
  --- as far as what this filter passed changed it: attributes, scroll
  --- region and the private modes. Empty when nothing
  --- passed changed any. The filter is then as new, but for a sequence it
  --- holds the start of, which is dropped.
  restore: function(Filter): string
end

--- A filter for the output of one program, from [`TermFilter.new`].
local record TermFilter
  --- A filter at the start of the program's output. The CSI sequences that
  --- pass are, by final byte: `m` (SGR: numbers, at most 32, between `;`
  --- or `:`); `A B C D E F G d` (a number); `H f r` (two numbers); `J`
  --- (0 to 2: never 3, which erases the scrollback for good) and `K` (0 to 2); `L M P @ X` (a number); `s` and `u` (no
  --- parameters); and `h` and `l` after `?` for the private modes
  --- application cursor keys (1), wrap (7), cursor visibility (25), the
  --- alternate screen (47, 1047, 1049) and bracketed paste (2004), at
  --- most eight to a sequence. A number has at most five digits, and the
  --- parameters of a sequence at most 128 bytes. None passes with an
  --- intermediate byte or another private prefix.
  new: function(): Filter
  type Filter = Filter
end

--- Whether `text` holds a number of more than five digits.
local function long_number(text: string): boolean
  return find(text, "%d%d%d%d%d%d") ~= nil
end

--- How many parameters `text`, of numbers between `;` or `:`, holds.
local function count_parameters(text: string): integer
  local count = 1
  for _ in text:gmatch("[;:]") do count = count + 1 end
  return count
end

--- A filter at the start of the program's output.
function TermFilter.new(): Filter
  local state = GROUND
  --- The UTF-8 character begun and not yet complete: its bytes so far, how
  --- many continuation bytes it still needs, and the range its next
  --- continuation byte must be in (the first one's narrows for the forms
  --- that would be overlong, surrogate, past U+10FFFF or a C1 control).
  local held: string = ""
  local needed = 0
  local low, high = 0x80, 0xbf
  --- The CSI being read: its private prefix ("" or one of `<=>?`) and the
  --- parameter bytes so far, and the one string's kind being dropped.
  local prefix = ""
  local parameters = ""
  local ends_at_bel = false
  local out: {string} = {}
  local answers: {string} = {}
  local modes: {integer:boolean} = {}
  for number, default in pairs(MODE_DEFAULTS) do modes[number] = default end
  local attributes_set = false
  local region_set = false

  local ground: function(integer)

  local function drop_held()
    held, needed = "", 0
  end

  --- The sequence read, `prefix`, `parameters` and `final`, is passed or
  --- dropped, or answered.
  local function dispatch(final: integer)
    local f = char(final)
    local p = parameters
    local pre = prefix
    prefix, parameters = "", ""
    if pre == "" then
      if f == "m" then
        if not long_number(p) and count_parameters(p) <= MOST_SGR_PARAMETERS then
          attributes_set = attributes_set or (p ~= "" and p ~= "0")
          out[#out + 1] = "\27[" .. p .. "m"
        end
        return
      end
      local pass = false
      if f == "A" or f == "B" or f == "C" or f == "D" or f == "E" or f == "F" or f == "G" or
          f == "d" or f == "L" or f == "M" or f == "P" or f == "@" or f == "X" then
        pass = find(p, "^%d*$") ~= nil and not long_number(p)
      elseif f == "H" or f == "f" or f == "r" then
        pass = find(p, "^%d*;?%d*$") ~= nil and not long_number(p)
        if pass and f == "r" then region_set = true end
      elseif f == "J" then
        pass = find(p, "^[0-2]?$") ~= nil
      elseif f == "K" then
        pass = find(p, "^[0-2]?$") ~= nil
      elseif f == "s" or f == "u" then
        pass = p == ""
      elseif f == "n" then
        if p == "6" then answers[#answers + 1] = CURSOR_REPORT end
      elseif f == "c" then
        if p == "" or p == "0" then answers[#answers + 1] = DEVICE_ATTRIBUTES end
      end
      if pass then out[#out + 1] = "\27[" .. p .. f end
    elseif pre == "?" and (f == "h" or f == "l") then
      if p == "" or count_parameters(p) > MOST_MODES or find(p, "^[%d;]+$") == nil then return end
      local listed: {integer} = {}
      for digits in (p .. ";"):gmatch("([^;]*);") do
        local number = digits ~= "" and #digits <= 4 and math.tointeger(tonumber(digits)) or nil
        if number == nil or MODE_DEFAULTS[number] == nil then return end
        listed[#listed + 1] = number
      end
      for _, number in ipairs(listed) do modes[number] = f == "h" end
      out[#out + 1] = "\27[?" .. p .. f
    end
  end

  --- Reads `b` with nothing begun: text, a control, or the start of a
  --- sequence or character.
  ground = function(b: integer)
    if needed > 0 then
      local first = #held == 1
      if b >= (first and low or 0x80) and b <= (first and high or 0xbf) then
        held = held .. char(b)
        needed = needed - 1
        if needed == 0 then
          out[#out + 1] = held
          held = ""
        end
        return
      end
      drop_held()
    end
    if b >= 0x20 and b <= 0x7e then
      out[#out + 1] = char(b)
    elseif b == ESC then
      state = AFTER_ESC
    elseif b == BEL or b == 8 or b == 9 or b == 10 or b == 13 then
      out[#out + 1] = char(b)
    elseif b >= 0xc2 and b <= 0xf4 then
      held = char(b)
      low, high = 0x80, 0xbf
      if b <= 0xdf then
        needed = 1
        -- C2 80 to C2 9F is U+0080 to U+009F, the C1 controls.
        if b == 0xc2 then low = 0xa0 end
      elseif b <= 0xef then
        needed = 2
        if b == 0xe0 then low = 0xa0 elseif b == 0xed then high = 0x9f end
      else
        needed = 3
        if b == 0xf0 then low = 0x90 elseif b == 0xf4 then high = 0x8f end
      end
    end
  end

  local function feed(_self: Filter, chunk: string): string, string
    local at, size = 1, #chunk
    while at <= size do
      if state == GROUND then
        if needed == 0 then
          local first, last = find(chunk, "^[ -~]+", at)
          if first ~= nil then
            out[#out + 1] = sub(chunk, first, last)
            at = last + 1
          end
        end
      elseif state == IN_CSI then
        local first, last = find(chunk, "^[0-9;:]+", at)
        if first ~= nil then
          if #parameters + (last - first + 1) > MOST_PARAMETER_BYTES then
            state = IGNORING_CSI
            prefix, parameters = "", ""
          else
            parameters = parameters .. sub(chunk, first, last)
          end
          at = last + 1
        end
      elseif state == IGNORING_CSI then
        local _, last = find(chunk, "^[ -?]+", at)
        if last ~= nil then at = last + 1 end
      elseif state == IN_STRING then
        local _, last = find(chunk, "^[^\27\24\26\7]+", at)
        if last ~= nil then at = last + 1 end
      end
      if at <= size then
        local b = byte(chunk, at)
        at = at + 1
        if state == GROUND then
          ground(b)
        elseif state == AFTER_ESC then
          if b == 0x5b then
            state, prefix, parameters = IN_CSI, "", ""
          elseif b == 0x5d then
            state, ends_at_bel = IN_STRING, true
          elseif b == 0x50 or b == 0x58 or b == 0x5e or b == 0x5f then
            state, ends_at_bel = IN_STRING, false
          elseif b == 0x37 or b == 0x38 then
            out[#out + 1] = "\27" .. char(b)
            state = GROUND
          elseif b >= 0x20 and b <= 0x2f then
            state = IGNORING_ESC
          elseif b >= 0x30 and b <= 0x7e then
            state = GROUND
          elseif b ~= ESC then
            state = GROUND
            if b ~= CAN and b ~= SUB_CONTROL and b ~= 0x7f then ground(b) end
          end
        elseif state == IN_CSI then
          if b >= 0x40 and b <= 0x7e then
            state = GROUND
            dispatch(b)
          elseif b >= 0x3c and b <= 0x3f and prefix == "" and parameters == "" then
            prefix = char(b)
          elseif b >= 0x20 and b <= 0x3f then
            -- An intermediate byte, or a parameter byte out of place.
            state = IGNORING_CSI
            prefix, parameters = "", ""
          elseif b == ESC then
            state = AFTER_ESC
          else
            state = GROUND
            if b ~= CAN and b ~= SUB_CONTROL and b ~= 0x7f then ground(b) end
          end
        elseif state == IGNORING_CSI then
          if b >= 0x40 and b <= 0x7e then
            state = GROUND
          elseif b == ESC then
            state = AFTER_ESC
          else
            state = GROUND
            if b ~= CAN and b ~= SUB_CONTROL and b ~= 0x7f then ground(b) end
          end
        elseif state == IGNORING_ESC then
          if b >= 0x30 and b <= 0x7e then
            state = GROUND
          elseif b == ESC then
            state = AFTER_ESC
          elseif b < 0x20 or b > 0x2f then
            state = GROUND
            if b ~= CAN and b ~= SUB_CONTROL and b ~= 0x7f then ground(b) end
          end
        elseif state == IN_STRING then
          if b == ESC then
            state = STRING_ESC
          elseif b == BEL and ends_at_bel then
            state = GROUND
          elseif b == CAN or b == SUB_CONTROL then
            state = GROUND
          end
        else
          -- ESC in a string: ST ends it, and anything else is the
          -- start of a sequence of its own.
          if b == 0x5c then
            state = GROUND
          else
            state = AFTER_ESC
            at = at - 1
          end
        end
      end
    end
    local passed, replies = concat(out), concat(answers)
    if #out > 0 then out = {} end
    if #answers > 0 then answers = {} end
    return passed, replies
  end

  local function restore(_self: Filter): string
    local resets: {string} = {}
    if attributes_set then resets[#resets + 1] = "\27[0m" end
    -- DECSTBM homes the cursor, so the cursor is saved around it.
    if region_set then resets[#resets + 1] = "\0277\27[r\0278" end
    local numbers: {integer} = {}
    for number in pairs(modes) do numbers[#numbers + 1] = number end
    table.sort(numbers)
    for _, number in ipairs(numbers) do
      if modes[number] ~= MODE_DEFAULTS[number] then
        resets[#resets + 1] = "\27[?" .. number .. (MODE_DEFAULTS[number] and "h" or "l")
        modes[number] = MODE_DEFAULTS[number]
      end
    end
    attributes_set, region_set = false, false
    state = GROUND
    prefix, parameters = "", ""
    drop_held()
    return concat(resets)
  end

  return { feed = feed, restore = restore }
end

return TermFilter
