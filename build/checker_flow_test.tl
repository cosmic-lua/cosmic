--- Reachability, `checker/flow.tl`: which statements end their block.
--- The module is compiled here by the compiler the tree carries and run
--- over programs that compiler has checked, so a node is marked as it is
--- when the checker asks about it. The cases pin what is decided today,
--- limits included, as the baseline later changes to the flow analysis are
--- held to.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local teal = require("build.teal")
local type compiler = require("build.compiler")

Test.policy{ grants = { { path = "checker/flow.tl", letters = "r" } } }

local record Node
  is {Node}
  kind: string
  body: Node
  exp: Node
  exps: Node
  e1: Node
  e2: Node
  if_blocks: {Node}
end

local record Flow
  ends: function(Node): boolean
  ends_body: function(Node): boolean
  ends_all: function({Node}): boolean
  leaves: function(Node): boolean
  leaves_body: function(Node): boolean
end

local built = { value = nil as compiler? }
local flow = { value = nil as Flow? }

--- The carried compiler, and `checker/flow.tl` compiled by it and loaded.
local function setup(): compiler, Flow
  local value = built.value
  local flow_value = flow.value
  if value ~= nil and flow_value ~= nil then
    return value, flow_value
  end
  local compiled = assert(teal.load(true))
  local env = assert(compiled.new_env({ defaults = teal.defaults() }))
  local code, result = compiled.gen(assert(Fs.read("checker/flow.tl")), env, nil, "tl")
  assert(code ~= nil and #result.type_errors == 0, "checker/flow.tl does not compile")
  local chunk = assert(load(code, "@checker/flow.tl", "t"))
  local loaded: any = chunk()
  built.value, flow.value = compiled, loaded as Flow
  return built.value, flow.value
end

--- `checker/flow.tl` as loaded.
local function flow_module(): Flow
  local _, loaded = setup()
  return loaded
end

--- `source` checked as a program, and what the checker said of it.
local function check(source: string): Node, {string}
  local compiled = setup()
  local env = assert(compiled.new_env({ defaults = teal.defaults() }))
  local code, result = compiled.gen(source, env, nil, "tl")
  assert(code ~= nil, "the program did not parse: " .. source)
  local messages: mut {string} = {}
  for _, e in ipairs(result.type_errors) do
    messages[#messages + 1] = e.msg
  end
  return result.ast as Node, messages
end

--- The first node of `kind` in `node`, in source order.
local function find(node: Node, kind: string): Node?
  if node.kind == kind then
    return node
  end
  local children: mut {Node} = {}
  for _, child in ipairs(node) do
    children[#children + 1] = child
  end
  for _, child in ipairs({ node.body, node.exp, node.exps, node.e1, node.e2 }) do
    children[#children + 1] = child
  end
  for _, child in ipairs(node.if_blocks or {}) do
    children[#children + 1] = child
  end
  for _, child in ipairs(children) do
    local found = find(child, kind)
    if found ~= nil then
      return found
    end
  end
  return nil
end

--- The statements around a case: `x` and `y` are booleans, `die` never
--- returns, and `f` returns.
local prelude <const> = [[
local x, y = true, false
local function die(): never
  error("die")
end
local function f(): integer
  return 1
end
]]

--- Whether `statement`, the last statement of a function's body, ends its
--- block; or, with `kind`, the first node of that kind in the body.
local function ends(statement: string, kind?: string): boolean
  local ast = check(prelude .. "local function g()\n" .. statement .. "\nend")
  local body = ast[#ast].body
  local node = body[#body]
  if kind ~= nil then
    node = find(body, kind)
    assert(node ~= nil, "no " .. kind .. " in " .. statement)
  end
  return flow_module().ends(node)
end

local function expect(want: boolean, cases: {string})
  for _, statement in ipairs(cases) do
    assert(ends(statement) == want, (if want then "does not end: " else "ends: " end) .. statement)
  end
end

local function test_return_break_and_goto_end_their_block()
  expect(true, { "return", "return 1", "do return end" })
  assert(ends("while x do break end", "break"))
  assert(ends("while x do goto continue\n::continue::\nend", "goto"))
end

local function test_a_call_of_a_never_function_ends_its_block()
  expect(true, { "die()", "error(\"x\")", "do die() end" })
  -- A call that returns, or one inside a larger statement, does not.
  expect(false, { "f()", "local n = f()", "x = f() > 0", "print(die ~= nil)" })
end

local function test_a_statement_that_is_not_a_jump_does_not_end_its_block()
  expect(false, {
    "local n = 1",
    "x = not x",
    "print(x)",
    "do end",
    "do x = true end",
    "for i = 1, 3 do return end",
    "for _ in pairs({}) do return end",
    "while x do return end",
    "repeat return until x",
  })
end

local function test_do_ends_when_its_last_statement_does()
  expect(true, { "do return end", "do do return end end", "do x = true; return end" })
  expect(false, { "do x = true end", "do end", "do if x then return end end" })
end

local function test_an_if_ends_only_with_an_else_and_every_branch_ending()
  expect(true, {
    "if x then return else return end",
    "if x then return elseif y then error(\"y\") else die() end",
    "if x then if y then return else return end else return end",
    "if x then do return end else return end",
  })
  expect(false, {
    "if x then return end",
    "if x then return elseif y then return end",
    "if x then return else x = false end",
    "if x then x = true else return end",
    "if x then return elseif y then x = true else return end",
    "if x then else return end",
  })
end

local function test_a_branch_ends_when_its_last_statement_does()
  assert(ends("if x then x = true; return end", "if_block"))
  assert(not ends("if x then x = true end", "if_block"))
  assert(not ends("if x then end", "if_block"))
end

local function test_a_loop_with_no_condition_to_leave_by_ends_unless_it_breaks()
  expect(true, {
    "while true do end",
    "repeat until false",
    "while true do x = not x end",
    "repeat x = not x until false",
    "while true do if x then return end end",
    -- A `break` of an inner loop leaves that loop alone.
    "while true do while x do break end end",
    "repeat for _ = 1, 2 do break end until false",
    "while true do local function h() while x do break end end end",
  })
  expect(false, {
    "while true do break end",
    "while true do if x then break end end",
    "while true do do break end end",
    "while true do if x then x = false elseif y then break end end",
    "while true do if x then if y then break end end end",
    "repeat break until false",
    "repeat if x then break end until false",
    "while x do end",
    "while false do end",
    "while not false do end",
    "while 1 == 1 do end",
    "repeat until true",
    "repeat until x",
    "repeat until not true",
  })
end

local function test_a_goto_to_a_label_in_the_loop_does_not_end_the_loop_body()
  -- `goto continue` ends the statement list it is in, but the label that
  -- follows it is the body's last statement and does not end.
  local loop = "for i = 1, 3 do\nif x then goto continue end\n::continue::\nend"
  assert(not ends(loop))
  assert(not ends(loop, "if"))
  assert(not ends(loop, "label"))
  assert(ends(loop, "goto"))
end

--- A `goto` only continues a loop, so one in an endless loop does not make
--- the loop leave: the loop still ends its block.
local function test_a_continue_in_an_endless_loop_does_not_make_it_leave()
  assert(ends("while true do if x then goto continue end\n::continue::\nend", "while"))
  assert(ends("repeat goto continue\n::continue::\nuntil false", "repeat"))
end

--- Whether `statement`, the last statement of a function's body, leaves
--- for good: control reaches nothing after the block that holds it, which a
--- `break` or a `goto` does not promise.
local function leaves(statement: string): boolean
  local ast = check(prelude .. "local function g()\n" .. statement .. "\nend")
  local body = ast[#ast].body
  return flow_module().leaves(body[#body])
end

local function test_return_and_a_call_that_never_returns_leave_and_break_and_goto_do_not()
  for _, statement in ipairs({ "return", "return 1", "die()", "error(\"x\")", "do return end",
      "do x = true; die() end", "if x then return else die() end", "if x then if y then return else return end else return end" }) do
    assert(leaves(statement), "does not leave: " .. statement)
  end
  for _, statement in ipairs({ "x = true", "f()", "if x then return end",
      "if x then return else x = true end", "while true do end", "repeat return until x", "do x = true end",
      "while x do if y then return else break end end" }) do
    assert(not leaves(statement), "leaves: " .. statement)
  end
  -- Neither a `break` nor a `goto` leaves for good, though each ends its block.
  for _, statement in ipairs({ "while x do break end", "while x do goto continue\n::continue::\nend" }) do
    local kind = if statement:find("break", 1, true) then "break" else "goto" end
    local ast = check(prelude .. "local function g()\n" .. statement .. "\nend")
    local jump = assert(find(ast[#ast].body, kind))
    assert(flow_module().ends(jump) and not flow_module().leaves(jump), kind)
  end
  -- A branch is one that leaves by its last statement.
  assert(flow_module().leaves(assert(find(check(prelude .. "local function g()\nif x then x = true; return end\nend"), "if_block"))))
  assert(not flow_module().leaves(assert(find(check(prelude .. "local function g()\nwhile x do if y then break end end\nend"), "if_block"))))
end

local function test_leaves_body_reads_the_last_statement()
  local ast = check(prelude .. "local function g()\nx = true\nreturn\nend\n" ..
      "local function h()\ndo return end\nx = true\nend\nlocal function e()\nend")
  local g, h, e = ast[#ast - 2], ast[#ast - 1], ast[#ast]
  assert(flow_module().leaves_body(g.body) and not flow_module().leaves_body(h.body) and not flow_module().leaves_body(e.body))
end

--- Whether the body of the first `if` branch of a function whose body is
--- `statement`, inside a loop, leaves.
local function branch_leaves(statement: string): boolean
  local ast = check(prelude .. "local function g()\nwhile x do\n" .. statement .. "\nend\nend")
  local branch = assert(find(ast, "if_block"))
  return flow_module().leaves_body(branch.body)
end

local function test_a_body_that_may_break_or_goto_out_does_not_leave()
  assert(branch_leaves("if x then f(); return end"))
  -- It ends in `return`, but a path through it goes out first.
  assert(not branch_leaves("if x then f(); if y then break end; return end"))
  assert(not branch_leaves("if x then if y then goto continue end; return end\n::continue::"))
  assert(not branch_leaves("if x then do if y then break end end; return end"))
  -- A `break` of a loop inside the body stays inside it.
  assert(branch_leaves("if x then while y do break end; return end"))
  assert(branch_leaves("if x then for _ = 1, 2 do if y then break end end; return end"))
  assert(branch_leaves("if x then repeat break until y; return end"))
  -- And so does a `goto` that continues a loop inside it.
  assert(branch_leaves("if x then while y do if x then goto continue end\n::continue::\nend; return end"))
end

local function test_ends_body_reads_the_last_statement()
  local ast = check(prelude .. "local function g()\nx = true\nreturn\nend\n" ..
      "local function h()\ndo return end\nx = true\nend\nlocal function e()\nend")
  local g, h, e = ast[#ast - 2], ast[#ast - 1], ast[#ast]
  assert(flow_module().ends_body(g.body) and not flow_module().ends_body(h.body) and not flow_module().ends_body(e.body))
end

local function test_ends_all_asks_every_branch()
  local open = assert(find(check(prelude .. "local function g()\nif x then return elseif y then return else x = true end\nend"), "if"))
  assert(not flow_module().ends_all(open.if_blocks))
  local closed = assert(find(check(prelude .. "local function g()\nif x then return elseif y then return end\nend"), "if"))
  assert(flow_module().ends_all(closed.if_blocks))
end

--- What the checker says of `header`, a function head, over `statements`.
local function errors_of(statements: string, header: string): {string}
  local _, messages = check(prelude .. header .. "\n" .. statements .. "\nend")
  return messages
end

local function mentions(messages: {string}, text: string): boolean
  for _, message in ipairs(messages) do
    if message:find(text, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function test_a_never_function_must_end_its_body()
  local header = "local function h(): never"
  assert(#errors_of("error(\"a\")", header) == 0)
  assert(#errors_of("while true do end", header) == 0)
  assert(#errors_of("if x then error(\"a\") else die() end", header) == 0)
  assert(mentions(errors_of("if x then error(\"a\") end", header), "can reach its end"))
  assert(mentions(errors_of("while true do break end", header), "can reach its end"))
  assert(mentions(errors_of("", header), "can reach its end"))
end

local function test_a_function_that_returns_a_value_must_not_reach_its_end()
  local header = "local h: function(boolean): integer = function(b: boolean)"
  assert(#errors_of("if b then return 1 else return 2 end", header) == 0)
  assert(#errors_of("while true do end", header) == 0)
  assert(#errors_of("if b then return 1 end die()", header) == 0)
  assert(mentions(errors_of("if b then return 1 end", header), "missing return"))
  assert(mentions(errors_of("if b then return 1 elseif x then return 2 end", header), "missing return"))
  assert(mentions(errors_of("f()", header), "missing return"))
end

local function test_a_branch_that_ends_narrows_what_follows()
  local header = "local function h(s: string | nil): integer"
  assert(#errors_of("if s == nil then return 0 end\nreturn #s", header) == 0)
  assert(#errors_of("if s == nil then die() end\nreturn #s", header) == 0)
  assert(#errors_of("if s == nil then error(\"no\") end\nreturn #s", header) == 0)
  assert(#errors_of("if s == nil then return 0 else return 1 end", header) == 0)
  assert(#errors_of("if s == nil then x = true end\nreturn #s", header) > 0)
  assert(#errors_of("if s == nil then if x then return 0 end end\nreturn #s", header) > 0)
end
