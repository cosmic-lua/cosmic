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

-- Find every cast, then narrow to one rendered type: `$X as $T`
-- matches a cast to ANY type, capturing the site's own `cast` node;
-- `$X as integer` instead matches only a cast whose rendered type
-- text is exactly "integer".
local function Example_find_casts()
  local ast = require("cosmic.ast")
  local check = require("cosmic.check")

  local source = [[
local v: any = 1
local a = v as integer
local b = v as {string: any}
]]
  local parsed = check.must(ast.parse(source, "casts.tl"))

  local any_cast = check.must(ast.compile_pattern("$X as $T"))
  for _, hit in ipairs(ast.find_all(parsed.node, any_cast)) do
    local line, col = ast.span_start(hit.node)
    print(("cast at %d:%d, opens on %s"):format(line, col, hit.caps["_T"].tk))
  end

  local integer_cast = check.must(ast.compile_pattern("$X as integer"))
  print("casts to integer:", #ast.find_all(parsed.node, integer_cast))
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
local _ = {Example_find_calls, Example_find_casts, Example_rewrite}
