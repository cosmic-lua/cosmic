--- The wrapper that joins the checker's parts into the one Lua text the
--- tool carries: [`build/compiler_test.tl`] and
--- [`build/compile_checker_test.tl`] each build the carried compiler from the
--- Lua of `checker/*.tl` with it.

local record checker_wrapper
end

--- `code`, a compiled checker, as the bridge starts it: `declarations`
--- quoted on one line as the local `stdlib`, and `modules`, the Lua of
--- each other file as `{ name, Lua, path }`, quoted on the same line
--- under the local `require`, so no line of `code` moves.
function checker_wrapper.wrapped(code: string, declarations: string, modules: {{string}}): string
  local function quoted(text: string): string
    return (string.format("%q", text):gsub("\\\n", "\\n"))
  end
  local sources: {string} = {}
  for index, module in ipairs(modules) do
    sources[index] = "[" .. quoted(module[1]) .. "] = {" .. quoted(module[3]) ..
      ", " .. quoted(module[2]) .. "}"
  end
  return "local stdlib, require = " .. quoted(declarations) ..
    ", (function(parts, env) local loaded, part_env = {}, nil " ..
    "local function req(name) local module = loaded[name] if module == nil then " ..
    "local part = parts[name] if part == nil then return require(name) end " ..
    "module = assert(load(part[2], \"@\" .. part[1], \"t\", part_env))() loaded[name] = module " ..
    "end return module end " ..
    "part_env = setmetatable({ require = req }, { __index = env }) return req end)" ..
    "({" .. table.concat(sources, ", ") .. "}, _ENV) " .. code
end

return checker_wrapper
