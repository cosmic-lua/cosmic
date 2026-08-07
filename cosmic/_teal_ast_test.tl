#!/usr/bin/env cosmic
-- The tl stdlib AST cache: the artifact carries /zip/.tl_ast.luac
-- (_types/tlast_gen.tl), the carried tl patch exposes the thaw hooks,
-- and cosmic._teal_ast builds envs from the pre-parsed programs. These
-- pin the pieces separately so a regression names its own layer.
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local teal_ast = require("cosmic._teal_ast")
local tl = require("tl")

-- The carried patch's surface: without it the cache cannot thaw and
-- every compile silently pays the parse again — a perf regression no
-- functional test would otherwise catch.
local function test_tl_exposes_ast_hooks()
  local hooks = check.must(tl.ast_hooks, "tl.ast_hooks missing: tl patch not applied")
  assert(type(hooks["type_mt"]) == "table", "ast_hooks.type_mt should be a metatable")
  assert(type(hooks["node_mt"]) == "table", "ast_hooks.node_mt should be a metatable")
  assert(type(hooks["new_typeid"]) == "function", "ast_hooks.new_typeid should be a function")
end
test_tl_exposes_ast_hooks()

-- The artifact ships the cache and it thaws: two program ASTs whose
-- roots look like parser output (statement-list nodes with children).
local function test_artifact_cache_thaws()
  local bytecode = check.must(fs.read("/zip/.tl_ast.luac"),
    "artifact should carry the tl AST cache")
  local chunk = check.must(load(bytecode, "=.tl_ast", "b"))
  local thaw = chunk()
  assert(type(thaw) == "function", "cache chunk should return the thaw function")
  -- cast: the chunk's contract, guarded as a function above
  local thaw_fn = thaw as function({string: any}): (any, any)
  local hooks = check.must(tl.ast_hooks, "tl.ast_hooks missing: tl patch not applied")
  local prelude_ast, stdlib_ast = thaw_fn(hooks)
  local prelude_node = prelude_ast as {any: any} -- cast: AST node from thaw
  local stdlib_node = stdlib_ast as {any: any} -- cast: AST node from thaw
  assert(prelude_node ~= nil and stdlib_node ~= nil, "thaw should yield both programs")
  assert(#(stdlib_node as {any}) > 0, -- cast: array view of a statement list
    "stdlib program should have top-level statements")
end
test_artifact_cache_thaws()

-- The env built from the cache is a real stdlib env: checking a
-- snippet against it resolves string.* types and reports a genuine
-- type error at the right place, identically to the parse path.
local function test_new_env_checks_like_the_parse_path()
  local env = check.must(teal_ast.new_env({
      feat_lax = "off",
      feat_arity = "on",
      gen_target = "5.4",
      gen_compat = "off",
    }))
  local code = "local s: string = string.rep(\"x\", \"not a number\")\n"
  local result = tl.process_string(code, false, env, "probe.tl")
  assert(#result.type_errors == 1,
    "expected exactly one type error, got " .. #result.type_errors)
  local first = result.type_errors[1]
  assert(first.y == 1, "error should be on line 1")
  assert(first.msg:find("string", 1, true) ~= nil,
    "the stdlib types should name the mismatch, got: " .. first.msg)
end
test_new_env_checks_like_the_parse_path()
