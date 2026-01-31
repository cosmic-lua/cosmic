--- Basic REPL (Read-Eval-Print Loop) for interactive Lua exploration.
--- Provides a simple interactive environment for testing and exploration.

local cosmo = require("cosmo")

--- Simple value inspector that converts values to readable strings.
--- @param value any The value to inspect
--- @param depth number Maximum recursion depth (default 3)
--- @return string String representation of the value
local function inspect(value: any, depth: number): string
  depth = depth or 3

  if depth <= 0 then
    return "..."
  end

  local t = type(value)

  if t == "nil" then
    return "nil"
  elseif t == "boolean" then
    return tostring(value)
  elseif t == "number" then
    return tostring(value)
  elseif t == "string" then
    return string.format("%q", value)
  elseif t == "function" then
    return "<function>"
  elseif t == "thread" then
    return "<thread>"
  elseif t == "userdata" then
    return "<userdata>"
  elseif t == "table" then
    local parts: {string} = {}
    local count = 0
    local max_items = 20

    -- Check if it's an array-like table
    local is_array = true
    local max_index = 0
    for k in pairs(value as {any:any}) do
      if type(k) ~= "number" then
        is_array = false
        break
      end
      local num_k = k as number
      if num_k <= 0 or num_k % 1 ~= 0 then
        is_array = false
        break
      end
      if num_k > max_index then
        max_index = num_k as integer
      end
    end

    if is_array and max_index > 0 then
      -- Array-like table
      for i = 1, max_index do
        if count >= max_items then
          table.insert(parts, "...")
          break
        end
        local v = (value as {any:any})[i]
        table.insert(parts, inspect(v, depth - 1))
        count = count + 1
      end
      return "{" .. table.concat(parts, ", ") .. "}"
    else
      -- Dictionary-like table
      for k, v in pairs(value as {any:any}) do
        if count >= max_items then
          table.insert(parts, "...")
          break
        end
        local key_str: string
        if type(k) == "string" then
          -- Check if key is a valid identifier
          if (k as string):match("^[%a_][%w_]*$") then
            key_str = k as string
          else
            key_str = "[" .. inspect(k, depth - 1) .. "]"
          end
        else
          key_str = "[" .. inspect(k, depth - 1) .. "]"
        end
        table.insert(parts, key_str .. " = " .. inspect(v, depth - 1))
        count = count + 1
      end
      if count == 0 then
        return "{}"
      end
      return "{" .. table.concat(parts, ", ") .. "}"
    end
  else
    return tostring(value)
  end
end

--- Try to evaluate input as an expression first, then as a statement.
--- @param input string The user input to evaluate
--- @param env table The environment table for variable persistence
--- @return boolean, any Success flag and result/error
local function try_eval(input: string, env: table): boolean, any
  -- First, try as expression (with return prefix)
  local expr_code = "return " .. input
  local expr_fn, expr_err = load(expr_code, "=stdin", "t", env)

  if expr_fn then
    -- It compiled as an expression
    local success, result = pcall(expr_fn)
    if success then
      return true, result
    else
      -- Runtime error
      return false, result
    end
  end

  -- Try as statement
  local stmt_fn, stmt_err = load(input, "=stdin", "t", env)

  if stmt_fn then
    local success, result = pcall(stmt_fn)
    if success then
      return true, nil -- Statements return nil
    else
      return false, result
    end
  end

  -- Both failed, return expression error (usually more informative)
  return false, expr_err
end

--- Run the REPL.
--- Loops reading input, evaluating it, and printing results until EOF (Ctrl-D).
local function run()
  io.write(_VERSION .. "  Copyright (C) 1994-2024 Lua.org, PUC-Rio\n")
  io.write("Type 'exit()' or press Ctrl-D to exit\n")

  -- Create environment table that inherits from _G
  local env: {string:any} = setmetatable({}, {__index = _G})

  while true do
    io.write("> ")
    io.flush()

    local line = io.read("*l")
    if not line then
      -- EOF (Ctrl-D)
      io.write("\n")
      break
    end

    -- Skip empty lines
    if line:match("^%s*$") then
      -- continue
    else
      local success, result = try_eval(line, env)

      if success then
        if result ~= nil then
          io.write(inspect(result, 3) .. "\n")
        end
      else
        -- Print error
        io.write("Error: " .. tostring(result) .. "\n")
      end
    end
  end
end

return {
  run = run,
  inspect = inspect,
}
