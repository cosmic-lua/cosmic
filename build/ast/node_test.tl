--- Conformance probes for [`build.ast.node`]'s `Node` record: parse small
--- fixtures against the tree's pinned compiler and assert that the
--- fields `Node` names appear with the expected shape. A change to the
--- checker that reshapes one fails here rather than in a consumer.
local teal = require("build.teal")
local node_mod = require("build.ast.node")

local built = assert(teal.load())

--- Parse `source`, asserting the parse itself succeeded.
--- @param source string Source text
--- @param name string Filename for diagnostics
--- @return node_mod.Node The AST root
local function parse_ok(source: string, name: string): node_mod.Node
  local parsed, err = node_mod.parse(built, source, name)
  assert(parsed ~= nil, "parse failed: " .. tostring(err))
  return parsed.node
end

--- One call `print(x.y, "hi")`, reached as `root[1]`: an "op" funcall
--- of "print" over an expression_list holding a "." index op (whose
--- own e2 is an "identifier") and a "string" literal. Covers op,
--- variable, identifier, string, and expression_list in one fixture.
local function test_funcall_index_and_string_literal()
  local root = parse_ok('print(x.y, "hi")', "funcall.tl")
  assert(root.kind == "statements", "root kind: " .. tostring(root.kind))

  local call = root[1]
  assert(call.kind == "op", "call kind: " .. tostring(call.kind))
  assert(call.tk == nil, "an op node must carry no tk")
  local op = call.op
  assert(op, "call.op must not be nil")
  assert(op.op == "@funcall", "call.op.op: " .. tostring(op.op))
  local e1 = call.e1
  assert(e1, "call.e1 must not be nil")
  assert(e1.kind == "variable" and e1.tk == "print",
    "call.e1 not the 'print' variable")

  local e2 = call.e2
  assert(e2, "call.e2 must not be nil")
  assert(e2.kind == "expression_list", "call.e2 kind: " .. tostring(e2.kind))

  local index = e2[1]
  assert(index.kind == "op", "index kind: " .. tostring(index.kind))
  local index_op = index.op
  assert(index_op, "index.op must not be nil")
  assert(index_op.op == ".", "index.op.op: " .. tostring(index_op.op))
  local index_e1 = index.e1
  assert(index_e1, "index.e1 must not be nil")
  assert(index_e1.kind == "variable" and index_e1.tk == "x",
    "index.e1 not the 'x' variable")
  local index_e2 = index.e2
  assert(index_e2, "index.e2 must not be nil")
  assert(index_e2.kind == "identifier" and index_e2.tk == "y",
    "index.e2 not the 'y' identifier")

  local str = e2[2]
  assert(str.kind == "string", "str kind: " .. tostring(str.kind))
  assert(str.tk == "\"hi\"", "str.tk: " .. tostring(str.tk))
  assert(str.conststr == "hi", "str.conststr: " .. tostring(str.conststr))
  assert(str.is_longstring == false, "str.is_longstring: " .. tostring(str.is_longstring))
end

--- `if x then return 1 end`, reached as `root[1]`: an "if" over one
--- "if_block" whose `if_parent` cycles back to it, whose `exp` is the
--- "variable" condition, and whose `body` is a "statements" node
--- holding a "return". Covers if, if_block, if_parent (a real cycle,
--- not shared-table aliasing), statements, and return/expression_list.
local function test_if_block_cycle_and_return()
  local root = parse_ok("if x then return 1 end", "if.tl")
  assert(root.kind == "statements", "root kind: " .. tostring(root.kind))

  local if_stmt = root[1]
  assert(if_stmt.kind == "if", "if_stmt kind: " .. tostring(if_stmt.kind))
  local if_blocks = if_stmt.if_blocks
  assert(if_blocks, "if_stmt.if_blocks must not be nil")
  assert(#if_blocks == 1, "expected exactly one if_block")

  local blk = if_blocks[1]
  assert(blk.kind == "if_block", "blk kind: " .. tostring(blk.kind))
  assert(blk.if_block_n == 1, "blk.if_block_n: " .. tostring(blk.if_block_n))
  assert(blk.if_parent == if_stmt,
    "if_block.if_parent must be the SAME table as its enclosing if (a real cycle)")
  local exp = blk.exp
  assert(exp, "blk.exp must not be nil")
  assert(exp.kind == "variable" and exp.tk == "x", "blk.exp not the 'x' variable")

  local body = blk.body
  assert(body, "blk.body must not be nil")
  assert(body.kind == "statements", "blk.body kind: " .. tostring(body.kind))

  local ret = body[1]
  assert(ret.kind == "return", "ret kind: " .. tostring(ret.kind))
  local exps = ret.exps
  assert(exps, "ret.exps must not be nil")
  assert(exps.kind == "expression_list", "ret.exps kind: " .. tostring(exps.kind))
  assert(#exps == 1, "expected one returned expression")
end

--- `local function test_foo() end`, reached as `root[1]`: a
--- "local_function" whose own `name` is an "identifier" node carrying
--- the declared name, which [`build.analyzer.analysis_of`] reads to find
--- a file's top-level tests.
local function test_local_function_name()
  local root = parse_ok("local function test_foo()\nend\n", "local_function.tl")
  local fn = root[1]
  assert(fn.kind == "local_function", "fn kind: " .. tostring(fn.kind))
  local name = fn.name
  assert(name, "fn.name must not be nil")
  assert(name.kind == "identifier" and name.tk == "test_foo",
    "fn.name: " .. tostring(name.kind) .. " " .. tostring(name.tk))
end

--- `Parsed` carries the token stream from the same parse. This checks
--- it directly, since [`parse_ok`] discards it, so a `parse()` that drops
--- or mismatches `tokens` fails here.
local function test_parse_returns_matching_tokens()
  local parsed, err = node_mod.parse(built, 'print("hi")', "tokens.tl")
  assert(parsed ~= nil, "parse failed: " .. tostring(err))
  assert(#parsed.tokens > 0, "expected a non-empty token stream")
  assert(parsed.tokens[1].tk == "print",
    "tokens[1].tk: " .. tostring(parsed.tokens[1].tk))
  assert(parsed.node.kind == "statements", "node.kind: " .. tostring(parsed.node.kind))
end

--- A parse failure returns nil plus a message naming the file. A
--- change that swallows parse errors, or returns a half-built `Parsed`
--- on failure, fails here.
local function test_parse_failure_reports_nil_and_message()
  local parsed, err = node_mod.parse(built, "if x then", "unclosed.tl")
  assert(parsed == nil, "expected nil Parsed on a syntax error")
  assert(err ~= nil and err:find("unclosed.tl", 1, true) ~= nil,
    "error should name the file: " .. tostring(err))
end

--- A type declared under a dotted name, which the parser refuses, is
--- told to nest it in the module's record; any other refusal is not.
local function test_a_dotted_type_declaration_is_told_to_nest()
  local nest = " -- declare `record Month ... end` inside `local record Ledger ... end`: " ..
    "it is then Ledger.Month, here and in every module that requires this one"
  local _, local_err = node_mod.parse(built,
    "local record Ledger\nend\nlocal record Ledger.Month\n  total: integer\nend\nreturn Ledger\n",
    "ledger.tl")
  assert(local_err == "ledger.tl:3:20: syntax error, expected identifier" .. nest, local_err)
  local _, bare_err = node_mod.parse(built,
    "local record Ledger\nend\nrecord Ledger.Month\n  total: integer\nend\nreturn Ledger\n",
    "ledger.tl")
  assert(bare_err == "ledger.tl:3:1: record needs to be declared with 'local record' or " ..
      "'global record'" .. nest, bare_err)
  local _, global_err = node_mod.parse(built,
    "local record Ledger\nend\nglobal record Ledger.Month\nend\nreturn Ledger\n", "ledger.tl")
  assert(global_err == "ledger.tl:3:21: syntax error, expected identifier" .. nest, global_err)
  local _, enum_err = node_mod.parse(built,
    "local record Ledger\nend\nlocal enum Ledger.Month\n  \"may\"\nend\nreturn Ledger\n",
    "ledger.tl")
  assert(enum_err == "ledger.tl:3:18: syntax error, expected string -- declare " ..
      "`enum Month ... end` inside `local record Ledger ... end`: it is then Ledger.Month, " ..
      "here and in every module that requires this one", enum_err)
  local _, type_err = node_mod.parse(built,
    "local record Ledger\nend\nlocal type Ledger.Day = integer\nreturn Ledger\n", "ledger.tl")
  assert(type_err == "ledger.tl:3:18: syntax error, expected '=' -- declare " ..
      "`type Day = ...` inside `local record Ledger ... end`: it is then Ledger.Day, " ..
      "here and in every module that requires this one", type_err)
  -- Another module's record is not this file's to declare in.
  local _, bound_err = node_mod.parse(built,
    'local Http = require("cosmic.http")\nlocal record Http.Extra\nend\nreturn Http\n', "x.tl")
  assert(bound_err == "x.tl:2:18: syntax error, expected identifier", bound_err)
  local _, plain_err = node_mod.parse(built, "local record\nend\n", "plain.tl")
  assert(plain_err ~= nil and plain_err:find(" -- ", 1, true) == nil, plain_err)
end

--- A vararg given a name is refused with the hint that it takes none,
--- here where a file run and `fix` first parse it, not only where the
--- checker's errors are rendered; another missing comma is told nothing.
local function test_a_named_vararg_is_told_it_takes_no_name()
  local _, err = node_mod.parse(built, "local function pick(t: {string:any}, ...names: string) end\n",
    "pick.tl")
  assert(err == "pick.tl:1:41: syntax error, expected one of: ')', ',' -- a vararg takes no name: " ..
      "write `...: string` and read it as `{ ... }`, or `select(\"#\", ...)` where a nil may be " ..
      "among them", err)
  local _, plain_err = node_mod.parse(built, "local function f(a b) end\n", "plain.tl")
  assert(plain_err ~= nil and plain_err:find(" -- ", 1, true) == nil, plain_err)
end
