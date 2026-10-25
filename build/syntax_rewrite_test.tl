--- Correctness probes for raw structural splices and comment-loss refusals in [`build.syntax_rewrite`].
local Ast = require("lang.ast")
local Match = require("build.syntax_match")
local Node = require("build.syntax_node")
local Rewrite = require("build.syntax_rewrite")
local Test = require("cosmic.test")

Test.policy{}

local function pattern_ok(source: string): Match.Pattern
  local pattern, why = Match.compile(source)
  return (assert(pattern, why))
end

local function rewritten(source: string, pattern: string, replacement: string, keep?: function(Ast.Node): boolean):
    Rewrite.Result
  local result, why = Rewrite.rewrite(source, "t.tl", pattern_ok(pattern), replacement, keep)
  return (assert(result, why))
end

local function test_a_clean_splice_is_byte_exact()
  local result = rewritten("os.execute(cmd)\n", "os.execute($X)", "assert(os.execute($X))")
  assert(result.code == "assert(os.execute(cmd))\n" and #result.refused == 0, result.code)
end

local function test_a_capture_name_that_prefixes_another_is_not_corrupted()
  local result = rewritten("return x + xs\n", "return $X + $XS", "return $XS - $X")
  assert(#result.refused == 0 and result.code == "return xs - x\n", result.code)
end

local function test_both_hits_of_a_two_hit_source_are_applied()
  local result = rewritten("os.execute(cmd1)\nos.execute(cmd2)\n", "os.execute($X)", "assert(os.execute($X))")
  assert(result.code == "assert(os.execute(cmd1))\nassert(os.execute(cmd2))\n", result.code)
end

local function test_a_hit_that_would_drop_a_comment_is_refused_and_left_as_it_was()
  local source = "return a -- keep this\n  + b\n"
  local result = rewritten(source, "return $A + $B", "return $B + $A")
  assert(#result.refused == 1 and result.refused[1].comments[1] == "-- keep this", tostring(result.refused[1]))
  assert(result.code == source and #result.edits == 0)
end

local function test_a_comment_inside_a_kept_capture_is_carried_forward()
  local source = "os.execute(f(a, -- keep\n  b))\n"
  local result = rewritten(source, "os.execute($X)", "assert(os.execute($X))")
  assert(#result.refused == 0 and result.code == "assert(os.execute(f(a, -- keep\n  b)))\n", result.code)
end

local function test_a_comment_outside_every_kept_capture_refuses_the_hit()
  local source = "os.execute(a -- keep\n)\n"
  local result = rewritten(source, "os.execute($X)", "assert(os.execute($X))")
  assert(#result.refused == 1 and result.refused[1].comments[1] == "-- keep" and result.code == source)
end

local function test_a_call_statement_is_deleted_with_its_line()
  local result = rewritten("run()\ntest_a()\nrun()\n", "$F:^test_()", "")
  assert(#result.refused == 0 and result.code == "run()\nrun()\n", result.code)
end

local function test_deleting_a_statement_refuses_a_trailing_comment_on_its_line()
  local source = "test_a() -- keep this\nrun()\n"
  local result = rewritten(source, "$F:^test_()", "")
  assert(#result.refused == 1 and result.refused[1].comments[1] == "-- keep this")
  assert(result.code == source)
end

local function test_a_call_inside_a_larger_statement_is_deleted_by_its_bytes_only()
  local result = rewritten("local x = f(1)\nrun()\n", "f($X)", "")
  assert(#result.refused == 0 and result.code == "local x = \nrun()\n", result.code)
end

local function test_the_accepted_hits_are_reported_in_source_order_with_their_nodes()
  local source = "os.execute(a)\nos.execute(f(b, -- keep\n  c))\nos.execute(d)\n"
  local result = rewritten(source, "os.execute($CMD)", "assert(os.execute($CMD))")
  assert(#result.refused == 0, "the comment is in a capture the template reuses")
  local chunk = assert(Node.parse(source, "t.tl"))
  local lines: mut {integer} = {}
  for _, edit in ipairs(result.edits) do
    lines[#lines + 1] = Node.span(chunk, edit.node).y
  end
  assert(table.concat(lines, " ") == "1 2 4", table.concat(lines, " "))
  local dropped = rewritten("os.execute(a)\nos.execute(b) -- keep\n", "os.execute($CMD)", "")
  assert(#dropped.refused == 1 and #dropped.edits == 1 and dropped.code == "os.execute(b) -- keep\n", dropped.code)
end

local function test_keep_narrows_the_hits_and_an_empty_replacement_is_an_accepted_edit()
  local chunk = assert(Node.parse("f(1)\nf(2)\n", "t.tl"))
  local second = Node.base(chunk.body.stats[2]).first
  local result = rewritten("f(1)\nf(2)\n", "f($X)", "g($X)", function(node: Ast.Node): boolean
    return Node.base(node).first >= second
  end)
  assert(result.code == "f(1)\ng(2)\n" and #result.edits == 1, result.code)
  local deleted = rewritten("test_a()\n", "$F:^test_()", "")
  assert(#deleted.edits == 1 and deleted.code == "", deleted.code)
end

local function test_a_deleted_line_runs_to_the_lexers_line_break_of_any_spelling()
  for _, break_with in ipairs({ "\n", "\r", "\r\n", "\n\r" }) do
    local source = "run()" .. break_with .. "test_a()" .. break_with .. "run()" .. break_with
    local result = rewritten(source, "$F:^test_()", "")
    assert(result.code == "run()" .. break_with .. "run()" .. break_with, ("%q"):format(result.code))
  end
end

local function test_a_source_that_does_not_parse_is_refused()
  local result, why = Rewrite.rewrite("if x then", "t.tl", pattern_ok("f($X)"), "g($X)")
  assert(result == nil and why:find("t.tl:", 1, true) ~= nil, why)
end
