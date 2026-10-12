--- Reachability, [`checker/flow.tl`]: which statements end their block.
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

local built: compiler
local flow: Flow

--- The carried compiler, and [`checker/flow.tl`] compiled by it and loaded.
local function setup()
  if built ~= nil then
    return
  end
  built = assert(teal.load(true))
  local env = assert(built.new_env({ defaults = {
    feat_lax = "off", gen_compat = "off", gen_target = "5.4",
  } }))
  local code, result = built.gen(assert(Fs.read("checker/flow.tl")), env, nil, "tl")
  assert(code ~= nil and #result.type_errors == 0, "checker/flow.tl does not compile")
  local chunk = assert(load(code, "@checker/flow.tl", "t"))
  local loaded: any = chunk()
  flow = loaded as Flow
end

--- `source` checked as a program, and what the checker said of it.
local function check(source: string): Node, {string}
  setup()
  local env = assert(built.new_env({ defaults = {
    feat_lax = "off", gen_compat = "off", gen_target = "5.4",
  } }))
  local code, result = built.gen(source, env, nil, "tl")
  assert(code ~= nil, "the program did not parse: " .. source)
  local messages: {string} = {}
  for _, e in ipairs(result.type_errors) do
    messages[#messages + 1] = e.msg
  end
  return result.ast as Node, messages
end

--- The first node of `kind` in `node`, in source order.
local function find(node: Node, kind: string): Node
  if node.kind == kind then
    return node
  end
  local children: {Node} = {}
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
  return flow.ends(node)
end

local function expect(want: boolean, cases: {string})
  for _, statement in ipairs(cases) do
    assert(ends(statement) == want, (want and "does not end: " or "ends: ") .. statement)
  end
end

local function test_return_break_and_goto_end_their_block()
  expect(true, { "return", "return 1", "do return end" })
  assert(ends("while x do break end", "break"))
  assert(ends("goto done\n::done::", "goto"))
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
  assert(not ends("::top::\nx = not x\nif x then goto top end"))
end

--- The limit [`checker/flow.tl`] holds a TODO for: a `goto` ends its block
--- whatever its label, so one out of an endless loop does not stop the
--- loop ending the block.
local function test_a_goto_out_of_an_endless_loop_still_ends_it()
  assert(ends("while true do goto out end\n::out::", "while"))
  assert(ends("do goto out end\n::out::", "do"))
end

--- Whether `statement`, the last statement of a function's body, leaves
--- for good: control reaches nothing after the block that holds it, which a
--- `break` or a `goto` does not promise.
local function leaves(statement: string): boolean
  local ast = check(prelude .. "local function g()\n" .. statement .. "\nend")
  local body = ast[#ast].body
  return flow.leaves(body[#body])
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
  for _, statement in ipairs({ "while x do break end", "goto out\n::out::" }) do
    local kind = statement:find("break", 1, true) and "break" or "goto"
    local ast = check(prelude .. "local function g()\n" .. statement .. "\nend")
    local jump = find(ast[#ast].body, kind)
    assert(flow.ends(jump) and not flow.leaves(jump), kind)
  end
  -- A branch is one that leaves by its last statement.
  assert(flow.leaves(find(check(prelude .. "local function g()\nif x then x = true; return end\nend"), "if_block")))
  assert(not flow.leaves(find(check(prelude .. "local function g()\nwhile x do if y then break end end\nend"), "if_block")))
end

local function test_leaves_body_reads_the_last_statement()
  local ast = check(prelude .. "local function g()\nx = true\nreturn\nend\n" ..
      "local function h()\ndo return end\nx = true\nend\nlocal function e()\nend")
  local g, h, e = ast[#ast - 2], ast[#ast - 1], ast[#ast]
  assert(flow.leaves_body(g.body) and not flow.leaves_body(h.body) and not flow.leaves_body(e.body))
end

local function test_ends_body_reads_the_last_statement()
  local ast = check(prelude .. "local function g()\nx = true\nreturn\nend\n" ..
      "local function h()\ndo return end\nx = true\nend\nlocal function e()\nend")
  local g, h, e = ast[#ast - 2], ast[#ast - 1], ast[#ast]
  assert(flow.ends_body(g.body) and not flow.ends_body(h.body) and not flow.ends_body(e.body))
end

local function test_ends_all_asks_every_branch()
  local open = find(check(prelude .. "local function g()\nif x then return elseif y then return else x = true end\nend"), "if")
  assert(not flow.ends_all(open.if_blocks))
  local closed = find(check(prelude .. "local function g()\nif x then return elseif y then return end\nend"), "if")
  assert(flow.ends_all(closed.if_blocks))
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
