--- Examples for the cosmic.ast module.

-- Parse a Teal snippet, walk it, and match a pattern with captures.
local function Example_find_calls()
  local ast = require("cosmic.ast")
  local check = require("cosmic.check")

  local source = [[
local function greet(name: string)
  print("hello, " .. name)
  os.execute("true")
end
]]
  local parsed = check.must(ast.parse(source, "greet.tl"))
  local pattern = check.must(ast.compile_pattern("os.execute($CMD)"))

  local hits = 0
  ast.walk(parsed.node, function(node: ast.Node)
      local captures = ast.match(pattern, node)
      if captures then
        hits = hits + 1
        local line, col = ast.span_start(node)
        print(("os.execute at %d:%d, argument kind %s"):format(
            line, col, captures["_CMD"].kind))
      end
    end)
  print("hits:", hits)
end

-- Splice a replacement template over one hit and print the result.
local function Example_rewrite()
  local ast = require("cosmic.ast")
  local check = require("cosmic.check")

  local source = 'os.execute("true")\n'
  local pattern = check.must(ast.compile_pattern("os.execute($CMD)"))
  local result = check.must(ast.rewrite(source, "cmd.tl", pattern,
      "assert(os.execute($CMD))"))
  print(result.code)
end

-- Suppress unused warnings for examples
local _ = {Example_find_calls, Example_rewrite}
