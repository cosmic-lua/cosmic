--- Executable-line analysis for coverage reporting.
--- Parses Lua or Teal source with the Teal compiler and collects the
--- lines where statements begin: the set of lines a Lua line hook is
--- expected to reach when the code runs. Function definition statements
--- are deliberately not collected because the VM attributes the closure
--- instruction to the `end` line, not the definition line; a
--- never-called function is reported through its body lines instead.
local tl = require("tl")

--- Statement kinds that always begin an executable statement at their line.
local exec_kinds: {string: boolean} = {
  ["local_declaration"] = true,
  ["assignment"] = true,
  ["while"] = true,
  ["fornum"] = true,
  ["forin"] = true,
  ["return"] = true,
  ["break"] = true,
  ["goto"] = true,
  -- expression statements: a function or method call
  ["op"] = true,
  ["paren"] = true,
}

--- Mark the line where one statement starts executing, if any.
--- @param node {any:any} A statement node (direct child of a statements block)
--- @param out {integer: boolean} Set of executable lines to add to
local function mark_statement(node: {any: any}, out: {integer: boolean})
  local kind = node["kind"] as string
  local y = node["y"] as integer
  if not kind or not y then
    return
  end
  if exec_kinds[kind] then
    out[y] = true
  elseif kind == "global_declaration" then
    -- `global x: T` without a value emits no code
    if node["exps"] then
      out[y] = true
    end
  elseif kind == "repeat" then
    -- the VM attributes the loop test to the `until` line; the
    -- `repeat` line itself carries no instructions
    local exp = node["exp"] as {any: any}
    if exp and exp["y"] then
      out[exp["y"] as integer] = true
    end
  elseif kind == "if" then
    -- each `if`/`elseif` line evaluates its condition; a bare `else`
    -- carries no instructions
    local blocks = node["if_blocks"] as {{any: any}}
    if blocks then
      for _, block in ipairs(blocks) do
        if block["exp"] and block["y"] then
          out[block["y"] as integer] = true
        end
      end
    end
  end
  -- function definitions ("local_function", "global_function",
  -- "record_function"), "do" blocks, labels, and type declarations emit
  -- no instruction on their first line and stay unmarked.
end

--- Recursively walk an AST, collecting statement lines into out.
--- @param node {any:any} An AST node
--- @param seen {any: boolean} Nodes already visited (cycle guard)
--- @param out {integer: boolean} Set of executable lines to add to
local function walk(node: {any: any}, seen: {any: boolean}, out: {integer: boolean})
  if seen[node] then
    return
  end
  seen[node] = true
  if node["kind"] == "statements" then
    for _, child in ipairs(node as {any}) do
      if child is {any: any} then
        mark_statement(child, out)
      end
    end
  end
  for _, v in pairs(node) do
    if v is {any: any} then
      if v["kind"] then
        walk(v, seen, out)
      else
        -- kindless container (e.g. the if_blocks array): walk node elements
        for _, e in ipairs(v as {any}) do
          if e is {any: any} and e["kind"] then
            walk(e, seen, out)
          end
        end
      end
    end
  end
end

--- Compute the set of executable lines for Lua or Teal source text.
--- Uses parse only (no type checking), so lax and broken-typing code
--- still analyzes; a syntax error is the only failure mode.
--- @param source string The source text
--- @param name string Chunk name for error messages; a name ending in
--- .lua parses as Lua, anything else as Teal
--- @return {integer: boolean} | nil Set of executable lines, or nil on parse failure
--- @return string? Error message if parsing failed
local function executable_lines(source: string, name: string): {integer: boolean} | nil, string
  local lang = name:match("%.lua$") and "lua" or "tl"
  local tokens, lex_errs = tl.lex(source, name)
  if not tokens then
    return nil, name .. ": lexer failed"
  end
  if lex_errs and #lex_errs > 0 then
    local e = lex_errs[1]
    return nil, string.format("%s:%d: %s", name, (e.y or 0) as integer, e.msg or "lex error")
  end
  local parse_errs: {tl.Error} = {}
  local ast = tl.parse_program(tokens, parse_errs, name, lang)
  if #parse_errs > 0 then
    local e = parse_errs[1]
    return nil, string.format("%s:%d: %s", name, (e.y or 0) as integer, e.msg or "parse error")
  end
  local out: {integer: boolean} = {}
  walk(ast as {any: any}, {}, out)
  return out
end

local record LinesModule
  executable_lines: function(source: string, name: string): {integer: boolean} | nil, string
end

local M: LinesModule = {
  executable_lines = executable_lines,
}

return M
