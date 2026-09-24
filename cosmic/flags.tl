--- A command line's options and the words among them. A spec names each
--- option and whether it takes a value; everything else that begins with
--- "-" is refused, so a mistyped option is never read as a path.
---
---     local got, why = Flags.parse(argv, 2, { ["--check"] = false, ["--jobs"] = true })
---     -- cosmic fix --check a.tl  => got.set["--check"], got.words = { "a.tl" }

local record Flags
  --- What a command line held.
  record Parsed
    --- Each option given that takes no value.
    set: {string:boolean}
    --- Each option given with a value, by name; the last one given wins.
    values: {string:string}
    --- Every other word, in order.
    words: {string}
  end
end

--- Reads `argv` from slot `from` on: 1 for a program's own `argv`, 2
--- for a verb's, whose slot 1 is the verb. `spec` maps each option,
--- written as it is typed ("--check", "-v"), to whether it takes a value:
--- the next word, or for a "--" option also what follows "=" in the same
--- word ("--jobs=4"). A lone "-" is a word, and "--" ends the options:
--- every word after it is a word even when it begins with "-", as a
--- negative number must. Answers nil and why for an option the spec does
--- not name, a value given to one that takes none, or one whose value is
--- missing -- the end of the line, "--", or another option the spec
--- names. A spec key that is not an option ("x", "-", "--") raises.
--- @param argv {integer:string} The command line
--- @param from integer The first slot to read
--- @param spec {string:boolean} Each option, and whether it takes a value
--- @return Parsed | nil What the line held
--- @return string Why it was refused, or "" when it was not
function Flags.parse(argv: {integer:string}, from: integer,
    spec: {string:boolean}): Flags.Parsed | nil, string
  for name in pairs(spec) do
    if name:sub(1, 1) ~= "-" or name == "-" or name == "--" then
      error("flags: " .. name .. " is not an option a spec can name", 2)
    end
  end
  local parsed: Flags.Parsed = { set = {}, values = {}, words = {} }
  local slot = from
  local options = true
  while argv[slot] ~= nil do
    local word = argv[slot]
    if not options or word == "-" or word:sub(1, 1) ~= "-" then
      parsed.words[#parsed.words + 1] = word
    elseif word == "--" then
      options = false
    else
      local name, value = word:match("^(%-%-[^=]+)=(.*)$")
      if name == nil then name = word end
      local takes = spec[name]
      if takes == nil then
        return nil, "no such option: " .. name
      elseif takes then
        if value == nil then
          slot = slot + 1
          value = argv[slot]
          if value == nil or value == "--" or spec[value] ~= nil then
            return nil, name .. " needs a value"
          end
        end
        parsed.values[name] = value
      elseif value ~= nil then
        return nil, name .. " takes no value"
      else
        parsed.set[name] = true
      end
    end
    slot = slot + 1
  end
  return parsed, ""
end

return Flags
