--- The pinned pre-install boundary: parser, root discovery and searcher
--- compiler capsule only. Do not import _make or CLI handlers here.
local parse = require("_cli.parse")
local selected_root: string | nil

--- Mirrors dispatcher precedence AFTER its environment fallbacks.
local function effective_make(opts: parse.Options): boolean
  return opts.make_verb ~= nil and opts.make_verb ~= "help" and
  not (opts.error or opts.version or opts.help or opts.welcome or
    opts.compile or opts.compile_strict or #opts.format > 0 or #opts.fix > 0 or
    opts.check_kind or opts.find_pattern or opts.rewrite_pattern or
    #opts.embed > 0 or opts.extract or opts.examples ~= nil or
    opts.benchmark or opts.docs ~= nil or opts.test_argv or
    opts.report_paths or opts.coverage_report_paths or opts.recipe ~= nil)
end

--- Discover without chdir; make still resolves self/COSMIC_MAKE in the
--- caller's cwd. Failure is deferred to its existing verb/root diagnostics.
local function prepare(opts: parse.Options, explicit_manifest: boolean): boolean, string
  if explicit_manifest or not effective_make(opts) then return true end
  local root = require("_make.root").discover(opts.make_verb)
  if not root then return true end
  local ok, err = require("cosmic.searcher").install_make_root(root)
  if not ok then return false, err end
  selected_root = root
  return true
end

local function get_root(): string | nil
  return selected_root
end

local record Startup
  effective_make: function(opts: parse.Options): boolean
  prepare: function(opts: parse.Options, explicit_manifest: boolean): boolean, string
  get_root: function(): string | nil
end

local M: Startup = {effective_make = effective_make, prepare = prepare, get_root = get_root}
return M
