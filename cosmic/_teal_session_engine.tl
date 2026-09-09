--- Checked-AST engine for semantic sessions.
---
--- Kept additive so the already-shipped `_teal_engine` record does not need a
--- new runtime member during generation-one bootstrap.

local engine = require("cosmic._teal_engine")
local type ProcessResult = engine.ProcessResult
local type TlResult = engine.TlResult

--- Check an already parsed, checker-owned AST in a fresh strict environment.
local function process_ast(ast: any, name: string,
    include_dirs: {string}): ProcessResult
  local tl = require("tl")
  local saved_tl_path = tl.path
  tl.path = engine.assemble_tl_path(include_dirs)

  local env, env_err = require("cosmic._teal_ast").new_env({
      feat_lax = "off",
      feat_arity = "on",
      gen_target = engine.DEFAULT_GEN_TARGET,
      gen_compat = engine.DEFAULT_GEN_COMPAT,
    })
  if not env then
    tl.path = saved_tl_path
    return {error = {file = name, line = 0, column = 0,
        message = "tl.new_env: " .. (env_err or "unknown error"),
        severity = "error"}}
  end
  env.report_types = true
  local ok, result_or_err, check_err = pcall(tl.check, ast, name, nil, env)
  tl.path = saved_tl_path
  if not ok then
    return {error = {file = name, line = 0, column = 0,
        message = tostring(result_or_err), severity = "error"}}
  end
  if not result_or_err then
    return {error = {file = name, line = 0, column = 0,
        message = check_err or "checking failed", severity = "error"}}
  end
  -- cast: successful pcall slot is the Result returned by tl.check
  local result = result_or_err as TlResult
  return {tl_result = result, env = env}
end

local record SessionEngineModule
  process_ast: function(ast: any, name: string,
  include_dirs: {string}): ProcessResult
end

local M: SessionEngineModule = {process_ast = process_ast}
return M
