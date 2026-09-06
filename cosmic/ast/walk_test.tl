#!/usr/bin/env cosmic
--- Regression probes for `cosmic.ast.walk`, one per bug this module's
--- port of `docs/design/ast-rewrite/tlgrep.tl` found and fixed by
--- actually running the spike against real source, not by reading
--- tl's parser alone.
local check = require("cosmic.check")
local node_mod = require("cosmic.ast.node")
local walk_mod = require("cosmic.ast.walk")

--- Parse `source`, asserting the parse itself succeeded.
--- @param source string Source text
--- @param name string Filename for diagnostics
--- @return node_mod.Parsed The AST root plus its token stream
local function parse_ok(source: string, name: string): node_mod.Parsed
  return check.must(node_mod.parse(source, name))
end

--- `walk` reaches every node depth-first, `node` itself first, and the
--- identity cycle guard stops it descending forever through an
--- "if_block"'s `if_parent` back-reference -- a REAL cycle (the same
--- table, not a copy), so an unguarded walk started at the root would
--- reach the "if" statement, its "if_block", back to the "if"
--- statement, forever.
local function test_walk_visits_every_node_once_through_a_real_cycle()
  local parsed = parse_ok("if x then return 1 end", "cycle.tl")
  local kinds: {string} = {}
  local visits: {node_mod.Node: integer} = {}
  walk_mod.walk(parsed.node, function(n: node_mod.Node)
      kinds[#kinds + 1] = n.kind
      visits[n] = (visits[n] or 0) + 1
    end)
  for n, count in pairs(visits) do
    assert(count == 1, "node visited " .. count .. " times: " .. tostring(n.kind))
  end
  local saw_if, saw_if_block, saw_return = false, false, false
  for _, k in ipairs(kinds) do
    if k == "if" then saw_if = true end
    if k == "if_block" then saw_if_block = true end
    if k == "return" then saw_return = true end
  end
  assert(saw_if and saw_if_block and saw_return,
    "expected if/if_block/return among: " .. table.concat(kinds, ","))
end

--- `walk` must actually descend into a BARE-ARRAY named field
--- (`if_blocks`), not just the array part every node's own `{Node}`
--- shape already covers. The first version of this walk never did:
--- Teal's `is` on a generic map type matches any table at runtime, so
--- an `elseif v is {any} then ...` fallback placed after an
--- `is {any: any}` branch was unreachable dead code, and `if_blocks`
--- was silently skipped. Confirmed by instrumenting the actual spike,
--- not assumed from reading tl's grammar.
local function test_walk_descends_into_if_blocks()
  local parsed = parse_ok("if x then return 1 elseif y then return 2 end",
    "if_blocks.tl")
  local if_block_count = 0
  walk_mod.walk(parsed.node, function(n: node_mod.Node)
      if n.kind == "if_block" then
        if_block_count = if_block_count + 1
      end
    end)
  assert(if_block_count == 2,
    "expected both if_blocks reached, got " .. if_block_count)
end

--- `return a --[[ keep this ]] + b`, three source lines above the
--- enclosing block's `end`: `span_end` on the "return" statement must
--- land on `b`'s own last character, not on that `end`. The "return"
--- node itself carries no `yend`/`xend` at all; its `exps` (an
--- "expression_list") does, but stamped from the ENCLOSING block's
--- terminator three lines down, not a delimiter of its own -- trusting
--- it unconditionally (as the untouched `yend`/`xend` would) lands on
--- `end` instead of `b`.
local function test_span_end_return_lands_on_last_operand_not_the_block_end()
  local source = table.concat({
      "local function f(a: integer, b: integer): integer",
      "  return a --[[ keep this ]] + b",
      "",
      "",
      "end",
    }, "\n")
  local parsed = parse_ok(source, "return_span.tl")
  local fn = parsed.node[1]
  local body = fn.body
  assert(body ~= nil, "expected local_function to carry a body")
  local ret = body[1]
  assert(ret.kind == "return", "ret.kind: " .. tostring(ret.kind))

  local ey, ex = walk_mod.span_end(ret, parsed.tokens)
  assert(ey == 2 and ex == 32,
    string.format("span_end(return) = %d:%d, want 2:32 (b's own last column)",
      ey, ex))
end

--- `os.execute(cmd)`: `span_end` on the OUTER call ("op"/"@funcall")
--- must land on its own closing `)`, not on `cmd`'s last character.
--- The call's argument list (`expression_list`, kind shared with a
--- bare `return` list above) IS closed by a real delimiter of its own
--- here, so its `yend`/`xend` must be trusted -- the opposite call from
--- the return case, on the identical `kind`.
local function test_span_end_call_lands_on_its_own_close_paren()
  local source = "os.execute(cmd)\n"
  local parsed = parse_ok(source, "call_span.tl")
  local call = parsed.node[1]
  assert(call.kind == "op" and call.op ~= nil and call.op.op == "@funcall",
    "expected the outer call node")

  local ey, ex = walk_mod.span_end(call, parsed.tokens)
  assert(ey == 1 and ex == 15,
    string.format("span_end(call) = %d:%d, want 1:15 (the closing ')')", ey, ex))
  assert(source:sub(ex, ex) == ")",
    "column " .. ex .. " is not the closing paren: " .. source:sub(ex, ex))
end

--- `if v == nil then return 1 end`: `span_end` on the "if" statement
--- must land on its own closing `end`, recovered via the `if_block`'s
--- `body` (a "statements" node, trusted directly by kind) rather than
--- the "if" node's own `yend`/`xend` -- also stamped at that same
--- `end`, but by a NON-bracket token, so the bracket gate alone would
--- reject it if the "statements" recovery path were not there to
--- supply the same answer from underneath.
local function test_span_end_if_recovers_end_through_its_block_body()
  local source = "if v == nil then return 1 end\n"
  local parsed = parse_ok(source, "if_span.tl")
  local if_stmt = parsed.node[1]
  assert(if_stmt.kind == "if", "if_stmt.kind: " .. tostring(if_stmt.kind))

  local ey, ex = walk_mod.span_end(if_stmt, parsed.tokens)
  assert(ey == 1 and ex == 29,
    string.format("span_end(if) = %d:%d, want 1:29 (its own closing 'end')",
      ey, ex))
  assert(source:sub(ex - 2, ex) == "end",
    "columns " .. (ex - 2) .. "-" .. ex .. " are not 'end': "
    .. source:sub(ex - 2, ex))
end

--- `span_start` finds the leftmost position over the WHOLE subtree,
--- not just the compound node's own `y`/`x` -- an "op"/"@funcall" node
--- records its position right after `(`, not at `os`'s own column.
local function test_span_start_call_lands_on_its_leftmost_leaf()
  local parsed = parse_ok("os.execute(cmd)\n", "start_span.tl")
  local call = parsed.node[1]
  assert(call.y == 1 and call.x == 11,
    "expected the call's own y/x to be mid-expression: " .. call.x)

  local sy, sx = walk_mod.span_start(call)
  assert(sy == 1 and sx == 1,
    string.format("span_start(call) = %d:%d, want 1:1 (leftmost, at 'os')", sy, sx))
end
