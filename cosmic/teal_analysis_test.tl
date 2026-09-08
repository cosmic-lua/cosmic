#!/usr/bin/env cosmic
-- Public optional semantic analysis over actual source snapshots.

local fs = require("cosmic.fs")
local source = require("cosmic.ast.source")
local walk = require("cosmic.ast.walk")
local teal = require("cosmic.teal")
local semantics = require("cosmic.teal.analysis")
local type Node = source.Node
local type Snapshot = source.Snapshot
local type Analysis = semantics.Analysis
local type Map = {any: any}

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function parsed(text: string, name?: string): Snapshot
  return assert(source.parse(text, name or "analysis_fixture.tl", "tl"))
end

local function find(snapshot: Snapshot, kind: string,
    token?: string): Node | nil
  local found: Node = nil
  walk.walk(snapshot.node, function(node: Node)
      if not found and node.kind == kind and (not token or node.tk == token) then
        found = node
      end
    end)
  return found
end

local function enclosing_call(snapshot: Snapshot, token: string): Node
  local node = assert(find(snapshot, "variable", token))
  while node do
    if node.kind == "op" and node.op
    and (node.op.op == "@funcall" or node.op.op == "@method") then
      return node
    end
    node = source.parent(snapshot, node)
  end
  error("no call for " .. token) -- throws: test fixture contract
end

local function has_error(analysis: Analysis, needle: string): boolean
  for _, issue in ipairs(analysis.diagnostics) do
    if issue.severity == "error" and issue.message:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function test_checked_snapshot_is_not_reparsed_or_mutated()
  local snapshot = parsed([[
local function f(v: string): string | nil, string
  return v
end
local maybe = f("ok")
print(maybe)
]])
  local literal = assert(find(snapshot, "string", '"ok"'))
  local raw_literal = literal as Map -- cast: test observes checker-only AST fields
  assert(raw_literal["known"] == nil)

  local tl = require("tl")
  local old_lex, old_parse = tl.lex, tl.parse_program
  local lexes, parses = 0, 0
  tl.lex = function(input: string, name: string): {tl.Token}, {tl.Error}
    lexes = lexes + 1
    local tokens, errors = old_lex(input, name)
    return tokens, errors
  end
  tl.parse_program = function(tokens: {tl.Token}, errors: {tl.Error},
      name?: string, lang?: string): any, {string}
    parses = parses + 1
    local ast, modules = old_parse(tokens, errors, name, lang)
    return ast, modules
  end
  local ok, result = pcall(function(): Analysis
      return semantics.session():analyze(snapshot)
    end)
  tl.lex, tl.parse_program = old_lex, old_parse
  assert(ok, tostring(result))
  local analysis = result as Analysis -- cast: guarded pcall result
  assert(analysis.complete)
  assert(lexes == 0 and parses == 0,
    "tl.check on the checker-owned graph must not reparse the root")
  assert(raw_literal["known"] == nil,
    "checking must not attach inference fields to immutable syntax")
end

local function test_type_queries_and_revision_cache()
  local snapshot = parsed([[
local function f(v: string): string | nil, string
  return v
end
local maybe: string | nil = f("ok")
print(maybe)
]])
  local session = semantics.session()
  local analysis = session:analyze(snapshot)
  assert(analysis.complete)
  local maybe = assert(find(snapshot, "identifier", "maybe"))
  local declared = analysis:declared_type(maybe)
  assert(declared.state == "known" and declared.value)
  local declared_value = assert(declared.value)
  local nilable = analysis:contains_nil(declared_value)
  assert(nilable.state == "known" and nilable.value,
    "nilability: " .. tostring(nilable.reason)
    .. " type=" .. analysis:describe(declared_value))

  local call = enclosing_call(snapshot, "f")
  local signature = analysis:callee_signature(call)
  assert(signature.state == "known" and signature.value)
  local signature_value = assert(signature.value)
  local rets = analysis:returns(signature_value)
  local values = rets.values
  assert(rets.state == "known")
  assert(values and #values == 2)
  assert(analysis:describe(values[2]) == "string")

  local cached = session:analyze(snapshot)
  assert(cached == analysis and cached.revision == analysis.revision)

  local reparsed = parsed(snapshot.source, snapshot.name)
  assert(reparsed.id == snapshot.id and reparsed ~= snapshot)
  local rebound = session:analyze(reparsed)
  assert(rebound ~= analysis and rebound.revision > analysis.revision)
  local rebound_maybe = assert(find(reparsed, "identifier", "maybe"))
  assert(rebound:declared_type(rebound_maybe).state == "known")
end

local function test_missing_and_foreign_node_queries_are_unknown()
  local snapshot = parsed("local x = 1\nprint(x)\n")
  local analysis = semantics.session():analyze(snapshot)
  local other = parsed("local y = 2\n", "other.tl")
  local foreign = assert(find(other, "integer", "2"))
  local query = analysis:type_of(foreign)
  assert(query.state == "unknown" and query.value == nil)

  local statements = snapshot.node
  local unsupported = analysis:type_of(statements)
  assert(unsupported.state == "unknown" and unsupported.value == nil)
  local unannotated = assert(find(snapshot, "identifier", "x"))
  local missing_decl = analysis:declared_type(unannotated)
  assert(missing_decl.state == "unknown" and missing_decl.value == nil)
end

local function test_dependency_edit_rebuilds_fresh_environment()
  local dir = fs.join(tmpdir, "teal_analysis_deps")
  assert(fs.make_dirs(dir))
  local dep = fs.join(dir, "dep.tl")
  local root = fs.join(dir, "root.tl")
  assert(fs.write(dep, "return {value = 'ok'}\n"))
  local snapshot = parsed([[
local dep = require("dep")
local value: string = dep.value
print(value)
]], root)
  local session = semantics.session({include_dirs = {dir}})
  local first = session:analyze(snapshot)
  assert(first.complete, teal.format_issues(first.diagnostics))
  assert(fs.write(dep, "return {value = 42}\n"))
  local second = session:analyze(snapshot)
  assert(second.revision > first.revision,
    "dependency content change must create a semantic revision")
  assert(not second.complete)
  assert(has_error(second, "string"), teal.format_issues(second.diagnostics))
end

local function test_incomplete_missing_import_is_not_cached()
  local dir = fs.join(tmpdir, "teal_analysis_missing")
  assert(fs.remove_all(dir))
  assert(fs.make_dirs(dir))
  local root = fs.join(dir, "root.tl")
  local snapshot = parsed([[
local added = require("added_later")
print(added.value)
]], root)
  local session = semantics.session({include_dirs = {dir}})
  local first = session:analyze(snapshot)
  assert(not first.complete)
  assert(fs.write(fs.join(dir, "added_later.tl"),
      "return {value = 'now present'}\n"))
  local second = session:analyze(snapshot)
  assert(second.revision > first.revision)
  assert(second.complete, teal.format_issues(second.diagnostics))
end
