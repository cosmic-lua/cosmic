--- Thaw the pre-parsed tl stdlib ASTs the artifact carries, and build
--- tl envs with them.
---
--- `_types/tlast_gen.tl` serializes the pinned tl's parsed prelude and
--- stdlib d.tl programs into `/zip/.tl_ast.luac`; this module loads
--- that chunk once per process and hands the rebuilt programs to
--- `tl.new_env` (carried patch, `3p/tl/tl_patch.tl` ast-cache-*),
--- skipping the parse that dominates a fresh process's first env —
--- ~11 of ~16 ms per compile child.
---
--- Fail-soft everywhere: a missing cache, an unpatched tl, or a chunk
--- that will not load or run simply yields no programs, and new_env
--- takes tl's own parse path — behavior identical, just slower. That
--- covers older pins, stripped artifacts, and local tl overrides.

local fs = require("cosmic.fs")
local tl = require("tl")

local CACHE_PATH < const > = "/zip/.tl_ast.luac"

local record teal_ast
  new_env: function(defaults: tl.CheckOptions): any, string
end

local cached_prelude: any = nil
local cached_stdlib: any = nil
local tried = false

--- The thawed programs, memoized for the process. Both nil when the
--- cache is unavailable in any way.
--- @return any The prelude program, or nil
--- @return any The stdlib program, or nil
local function programs(): any, any
  if tried then
    return cached_prelude, cached_stdlib
  end
  tried = true
  local hooks = tl.ast_hooks
  if hooks == nil then
    return nil, nil
  end
  local bytecode = fs.read(CACHE_PATH)
  if not bytecode then
    return nil, nil
  end
  local chunk = load(bytecode, "=.tl_ast", "b")
  if not chunk then
    return nil, nil
  end
  local ok, thaw = pcall(chunk)
  if not ok or type(thaw) ~= "function" then
    return nil, nil
  end
  -- cast: the chunk's contract, guarded as a function just above
  local thaw_fn = thaw as function({string: any}): (any, any)
  local tok, prelude_ast, stdlib_ast = pcall(thaw_fn, hooks)
  if not tok or prelude_ast == nil or stdlib_ast == nil then
    return nil, nil
  end
  cached_prelude, cached_stdlib = prelude_ast, stdlib_ast
  return cached_prelude, cached_stdlib
end

--- tl.new_env with the artifact's pre-parsed stdlib when available.
--- Same contract as tl.new_env: the env, or nil plus a message.
--- @param defaults CheckOptions The per-env feature/codegen defaults
--- @return any The tl env, or nil
--- @return string Error message on failure
function teal_ast.new_env(defaults: tl.CheckOptions): any, string
  local prelude_ast, stdlib_ast = programs()
  return tl.new_env({
      defaults = defaults,
      parsed_prelude = prelude_ast,
      parsed_stdlib = stdlib_ast,
    })
end

return teal_ast
