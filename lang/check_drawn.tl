--- The programs the fork's narrowing fuzz test draws ([`build.check_draws`]), put where the new checker can take
--- them: its header and shapes are Teal, and the new grammar has no `goto` label, no `metamethod` keyword, no `T | nil` (it
--- is `T?`), a record whose fields the programs change must declare them `mut`, and it has no record literal that leaves a
--- field out. The properties that draw them ([`lang.check_flow_fuzz_test`], [`lang.check_total_fuzz_test`]) share this.
local record Drawn
  --- The drawn program as the new grammar takes it: the labels `continue`, an array of integers, every field of a record
  --- literal given, and the body in a function so that its `return`s are a function's. Nil where the program has not the
  --- header (a cut that took part of it away).
  adapted: function(source: string): string?
end

--- The last declaration of the header every drawn program starts with.
local HEADER_END <const> = "local function id(v: integer?): integer?\n  return v\nend\n"

function Drawn.adapted(source: string): string?
  local text = source:gsub("local opts: {integer | nil}", "local opts: {integer}")
  -- A label ends the body of a loop, so the jump to it is a `continue`.
  text = text:gsub("goto next%d+", "continue"):gsub("::next%d+::", "")
  text = text:gsub("metamethod ", "")
  text = text:gsub("([%w_]+) | nil", "%1?")
  text = text:gsub("local r: R = { a = 1, n = 0 }", "local r: R = { a = 1, b = nil, n = 0 }")
  text = text:gsub("local s: R = { b = 2, n = 0 }", "local s: R = { a = nil, b = 2, n = 0 }")
  local _, stop = text:find(HEADER_END, 1, true)
  if stop == nil then
    return nil
  end
  -- The records of the header are changed by the programs, so their fields are `mut`.
  local header = text:sub(1, stop):gsub("\n  (%w+): ", "\n  mut %1: ")
  return header .. "local function main(): integer\n" .. text:sub(stop + 1) .. "end\nlocal _ = main()\n"
end

return Drawn
