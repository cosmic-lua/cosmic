--- Cast justification as an ordinary registered syntax rule.
local analysis = require("cosmic.analysis")
local source = require("cosmic.ast.source")
local policy = require("_cli.cast_policy")
local style = require("_tool.lint")
local str = require("cosmic.string")

local type Diagnostic = style.Diagnostic

local MESSAGE < const > = "`as` cast without justification: prefer `is` narrowing"
  .. " or check.must (see `cosmic --docs guide.checking`); a"
  .. " deliberate cast either matches an allowlisted kind in"
  .. " `_build/casts_kinds.tl` or takes a trailing `-- cast:"
  .. " <reason>` (or one on the line above)"

local function line_at(snapshot: source.Snapshot, at: integer): integer
  local lo, hi = 1, #snapshot.line_starts
  while lo <= hi do
    local mid = (lo + hi) // 2
    if snapshot.line_starts[mid] <= at then lo = mid + 1 else hi = mid - 1 end
  end
  return math.max(1, hi)
end

local function define(lines: {string}): analysis.Rule | nil, string
  local allowed = policy.load()
  if allowed.reason then return nil, allowed.reason end
  return analysis.define({
    id = "cast-justify", needs = {"syntax"}, kinds = {"cast"},
    visit = function(ctx: analysis.Context, hit: analysis.Hit)
      local range, err = source.range(ctx.snapshot, hit.node)
      if not range then
        ctx:incomplete(err, hit.node)
        return
      end
      local y = line_at(ctx.snapshot, range.start_byte)
      if not policy.allows(allowed, ctx.snapshot.name, str.trim(lines[y] or ""), hit.node)
      and not style.is_justified(lines, y, "cast") then
        ctx:report(MESSAGE, hit.node, "error")
      end
    end,
  })
end

--- Compatibility seam for the existing lint composition. The rule runner's
--- range is preferred when present; dependency diagnostics may only carry the
--- stable line/column pair, so preserve that as the fallback.
local function check_cast_justification(file: string, content: string,
    lines: {string}): {Diagnostic} | nil, string
  local rule, rule_err = define(lines)
  if not rule then return nil, rule_err end
  local snapshot, parse_err = source.parse(content, file)
  if not snapshot then return nil, parse_err end
  local result = analysis.run(snapshot, {rule}, {
      teal = false, bindings = false, format = false,
    })
  if not result.complete then return nil, result.error or "cast analysis incomplete" end
  local out: {Diagnostic} = {}
  for _, diagnostic in ipairs(result.diagnostics) do
    local y, x = diagnostic.line, diagnostic.column
    if diagnostic.range then
      y = line_at(snapshot, diagnostic.range.start_byte)
      x = diagnostic.range.start_byte - snapshot.line_starts[y] + 1
    end
    out[#out + 1] = {
      file = diagnostic.file,
      line = y,
      col = x,
      rule = diagnostic.rule,
      message = diagnostic.message,
    }
  end
  return out
end

local record CastRuleModule
  define: function(lines: {string}): analysis.Rule | nil, string
  line_at: function(snapshot: source.Snapshot, at: integer): integer
  check_cast_justification: function(file: string, content: string,
    lines: {string}): {Diagnostic} | nil, string
end
local M: CastRuleModule = {
  define = define,
  line_at = line_at,
  check_cast_justification = check_cast_justification,
}
return M
