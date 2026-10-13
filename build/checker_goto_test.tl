--- A `goto` is a continue and nothing else: the checker refuses a `goto`
--- unless it jumps forward to the label that is the last statement of the
--- body of the innermost loop around it, in the same function, and a label
--- no such `goto` names. Each way to miss that is refused here, and each
--- loop kind with a continue is accepted, so a rule that refuses too much
--- or too little fails one side.
local type compiler = require("build.compiler")
local teal = require("build.teal")

--- The type errors the checker reports for `source`.
local function type_errors(source: string): {compiler.Error}
  local built = assert(teal.load(true))
  local _, result = built.gen(source, nil, nil, "tl")
  return assert(result).type_errors
end

--- What every program here is written against: three lines.
local head <const> = "local function use(_: any) end\n" ..
  "local function cond(): boolean return true end\n" ..
  "local items: {integer} = {}\n"

--- `body` as the body of a function after [`head`]; its first line is the
--- fifth of the program.
local function program(body: string): string
  return head .. "local function f()\n" .. body .. "\nend\nuse(f)\n"
end

--- Where the `occurrence`th `needle` of `source` begins, as `line:column`.
local function at(source: string, needle: string, occurrence?: integer): string
  local from = 1
  local found: integer = nil
  for _ = 1, occurrence or 1 do
    found = assert(source:find(needle, from, true), needle)
    from = found + 1
  end
  local line = 1
  local line_start = 1
  for i = 1, found - 1 do
    if source:sub(i, i) == "\n" then
      line = line + 1
      line_start = i + 1
    end
  end
  return tostring(line) .. ":" .. tostring(found - line_start + 1)
end

--- A refusal as the test compares it: `goto G -> L` where the `goto` is at
--- `G` and names the label at `L` (`-` where it names none), or `label L`
--- for a label no continue names.
local function shown(e: compiler.Error): string
  local function place(y: integer | nil, x: integer | nil): string
    return y ~= nil and tostring(y) .. ":" .. tostring(x) or "-"
  end
  if e.goto_y == nil then
    return "label " .. place(e.label_y, e.label_x)
  end
  return "goto " .. place(e.goto_y, e.goto_x) .. " -> " .. place(e.label_y, e.label_x)
end

--- The refusals of the rule in `source`, in source order, after holding
--- every one to carry its code, the label's name and the place the error
--- is reported at.
local function refusals(source: string): {string}
  local out: {string} = {}
  for _, e in ipairs(type_errors(source)) do
    if e.code == "goto_not_continue" then
      assert(e.variable ~= nil and e.variable ~= "", e.msg)
      assert(e.y == (e.goto_y or e.label_y) and e.x == (e.goto_x or e.label_x), e.msg)
      out[#out + 1] = shown(e)
    end
  end
  return out
end

--- Holds `body`, a function body, to be accepted: no error at all.
local function accepts(body: string)
  local source = program(body)
  local errors = type_errors(source)
  local lines: {string} = {}
  for _, e in ipairs(errors) do
    lines[#lines + 1] = tostring(e.y) .. ":" .. tostring(e.x) .. " " .. tostring(e.code) .. " " .. e.msg
  end
  assert(#errors == 0, table.concat(lines, "\n") .. "\n" .. source)
end

--- Holds `body` to be refused exactly as `want` says.
local function refuses(body: string, want: {string})
  local source = program(body)
  local got = refusals(source)
  assert(table.concat(got, "; ") == table.concat(want, "; "),
    table.concat(got, "; ") .. " is not " .. table.concat(want, "; ") .. "\n" .. source)
end

local function test_a_continue_is_accepted_in_every_kind_of_loop()
  accepts("for i = 1, 3 do\n  if cond() then goto continue end\n  use(i)\n  ::continue::\nend")
  accepts("for _, v in ipairs(items) do\n  if v == 2 then goto continue end\n  use(v)\n  ::continue::\nend")
  accepts("while cond() do\n  if cond() then goto continue end\n  use(1)\n  ::continue::\nend")
  accepts("repeat\n  if cond() then goto continue end\n  use(1)\n  ::continue::\nuntil cond()")
end

local function test_the_name_of_the_label_does_not_matter()
  accepts("for i = 1, 3 do\n  if cond() then goto next end\n  use(i)\n  ::next::\nend")
end

local function test_a_continue_may_be_made_from_inside_nested_statements_and_more_than_once()
  accepts("for i = 1, 3 do\n  if cond() then\n    do\n      if i == 2 then goto continue end\n    end\n  elseif i == 3 then\n" ..
      "    goto continue\n  end\n  use(i)\n  goto continue\n  ::continue::\nend")
end

local function test_nested_loops_each_have_a_continue_of_their_own()
  accepts("for i = 1, 3 do\n  for j = 1, 3 do\n    if j == i then goto continue end\n    use(j)\n    ::continue::\n  end\n" ..
      "  if i == 2 then goto continue end\n  use(i)\n  ::continue::\nend")
  accepts("for i = 1, 3 do\n  while cond() do\n    if cond() then goto skip end\n    ::skip::\n  end\n  if i == 2 then goto next end\n" ..
      "  ::next::\nend")
end

local function test_a_function_in_a_loop_has_its_own_loops()
  accepts("for i = 1, 3 do\n  local g = function()\n    for j = 1, 3 do\n      if j == i then goto continue end\n" ..
      "      ::continue::\n    end\n  end\n  use(g)\n  if cond() then goto continue end\n  ::continue::\nend")
end

local function test_a_continue_is_accepted_in_a_method()
  local source = head .. "local record R end\nfunction R.m()\n  for i = 1, 3 do\n    if cond() then goto continue end\n" ..
    "    use(i)\n    ::continue::\n  end\nend\nuse(R)\n"
  assert(#type_errors(source) == 0)
end

local function test_a_jump_back_is_refused()
  local source = program("while cond() do\n  ::top::\n  use(1)\n  if cond() then goto top end\nend")
  refuses("while cond() do\n  ::top::\n  use(1)\n  if cond() then goto top end\nend",
    { "label " .. at(source, "::top::"), "goto " .. at(source, "goto top") .. " -> " .. at(source, "::top::") })
end

local function test_a_jump_back_to_a_label_before_a_loop_is_refused()
  local source = program("::again::\nfor i = 1, 3 do\n  use(i)\n  if cond() then goto again end\nend")
  refuses("::again::\nfor i = 1, 3 do\n  use(i)\n  if cond() then goto again end\nend",
    { "label " .. at(source, "::again::"), "goto " .. at(source, "goto again") .. " -> " .. at(source, "::again::") })
end

local function test_a_jump_forward_to_a_label_not_at_the_end_of_the_body_is_refused()
  local body = "while cond() do\n  if cond() then goto skip end\n  use(1)\n  ::skip::\n  use(2)\nend"
  local source = program(body)
  refuses(body, { "goto " .. at(source, "goto skip") .. " -> " .. at(source, "::skip::"), "label " .. at(source, "::skip::") })
end

local function test_a_jump_out_of_a_loop_is_refused()
  local body = "while cond() do\n  if cond() then goto out end\nend\n::out::\nuse(1)"
  local source = program(body)
  refuses(body, { "goto " .. at(source, "goto out") .. " -> " .. at(source, "::out::"), "label " .. at(source, "::out::") })
end

local function test_a_jump_from_a_nested_function_is_refused()
  local body = "for i = 1, 3 do\n  local g = function()\n    goto continue\n  end\n  use(g)\n  ::continue::\nend"
  local source = program(body)
  refuses(body, { "goto " .. at(source, "goto continue") .. " -> -", "label " .. at(source, "::continue::") })
end

local function test_a_jump_to_the_end_of_an_outer_loop_is_refused()
  local body = "for i = 1, 3 do\n  for j = 1, 3 do\n    if j == i then goto continue end\n    use(j)\n  end\n  ::continue::\nend"
  local source = program(body)
  refuses(body, { "goto " .. at(source, "goto continue") .. " -> " .. at(source, "::continue::"),
    "label " .. at(source, "::continue::") })
end

local function test_a_label_in_a_block_that_is_not_the_loop_body_is_refused()
  local body = "for i = 1, 3 do\n  if cond() then\n    goto continue\n    ::continue::\n  end\nend"
  local source = program(body)
  refuses(body, { "goto " .. at(source, "goto continue") .. " -> " .. at(source, "::continue::"),
    "label " .. at(source, "::continue::") })
end

local function test_a_goto_outside_any_loop_is_refused()
  local body = "if cond() then goto done end\nuse(1)\n::done::"
  local source = program(body)
  refuses(body, { "goto " .. at(source, "goto done") .. " -> " .. at(source, "::done::"), "label " .. at(source, "::done::") })
end

local function test_a_goto_to_another_label_than_the_one_ending_the_body_is_refused()
  local body = "for i = 1, 3 do\n  if cond() then goto skip end\n  use(i)\n  ::next::\nend"
  local source = program(body)
  refuses(body, { "goto " .. at(source, "goto skip") .. " -> -", "label " .. at(source, "::next::") })
end

local function test_a_label_nothing_continues_to_is_refused()
  local body = "for i = 1, 3 do\n  use(i)\n  ::continue::\nend"
  local source = program(body)
  refuses(body, { "label " .. at(source, "::continue::") })
  local lonely = program("use(1)\n::lonely::")
  refuses("use(1)\n::lonely::", { "label " .. at(lonely, "::lonely::") })
end

local function test_a_refused_goto_has_a_hint_that_says_how_to_restructure()
  local body = "while cond() do\n  if cond() then goto skip end\n  use(1)\n  ::skip::\n  use(2)\nend"
  local source = program(body)
  local found: compiler.Error = nil
  for _, e in ipairs(type_errors(source)) do
    if e.code == "goto_not_continue" and e.goto_y ~= nil then
      found = e
    end
  end
  assert(found ~= nil)
  assert(found.variable == "skip" and found.label_y ~= nil)
  local hint = assert(teal.replacement(found, source), "no hint")
  assert(hint:find("restructure with an `if`", 1, true) ~= nil, hint)
  assert(hint:find("move the body into a function", 1, true) ~= nil, hint)
  assert(hint:find("goto skip", 1, true) ~= nil, hint)
  local unused = program("for i = 1, 3 do\n  use(i)\n  ::end_of_pass::\nend")
  for _, e in ipairs(type_errors(unused)) do
    if e.code == "goto_not_continue" then
      local label_hint = assert(teal.replacement(e, unused), "no hint")
      assert(label_hint:find("::end_of_pass::", 1, true) ~= nil, label_hint)
      assert(label_hint:find("`if`", 1, true) ~= nil, label_hint)
    end
  end
end
