--- `--rewrite PATTERN [PATH...]` delegates to `--find`; with a
--- replacement plus `--preview` or `--apply`, it plans each selected file
--- once and either reports that plan or commits it. Preview never has a
--- write path; apply intentionally remains partial across file failures.
local ast = require("cosmic.ast")
local fs = require("cosmic.fs")
local json = require("cosmic.json")
local find = require("_cli.find")

local type Node = ast.Node

local record RefusalPreview
  line: integer
  column: integer
  comments: integer
end

--- One file's complete, non-writing rewrite decision. `error` replaces a
--- result for a failed read, source parse, substitution, or formatting pass.
local record Plan
  source: string
  matches: integer
  result: ast.RewriteResult
  error: string
end

--- The preview stream is deliberately tiny and injectable: a report is only
--- successful once both its bytes and their flush reached stdout.
local record ReportIo
  write: function(text: string): boolean, string
  flush: function(): boolean, string
end

local function stdout_write(text: string): boolean, string
  local file, err = io.stdout:write(text)
  if not file then return false, err or "stdout write failed" end
  return true
end

local function stdout_flush(): boolean, string
  local ok, err = io.stdout:flush()
  if not ok then return false, err or "stdout flush failed" end
  return true
end

local report_io: ReportIo = {write = stdout_write, flush = stdout_flush}

local function set_report_io(reporter: ReportIo): ReportIo
  local previous = report_io
  report_io = reporter
  return previous
end

local function emit_preview(text: string): boolean, string
  local written, write_err = report_io.write(text)
  if not written then return false, write_err end
  return report_io.flush()
end

--- Parse a template as a complete chunk, then as an expression if needed.
--- Empty/whitespace/comment-only chunks are deliberately valid: deletion is
--- part of rewrite's public contract.
local function validate_template(replacement: string): boolean, string
  local desugared = ast.desugar(replacement)
  local _, chunk_err = ast.parse(desugared, "replacement")
  if not chunk_err then return true end
  local _, expr_err = ast.parse("return " .. desugared, "replacement")
  if not expr_err then return true end
  return false, expr_err
end

--- Read, count original matches, and attempt one rewrite. This owns no mode
--- and writes nothing, so preview and apply can never drift in their output.
local function plan_one(pattern: Node, replacement: string, path: string): Plan
  local source, read_err = fs.read(path)
  if not source then
    return {matches = 0, error = read_err or "read failed"}
  end
  local parsed, parse_err = ast.parse(source, path)
  if not parsed then
    return {source = source, matches = 0, error = parse_err}
  end
  local matches = #ast.find_all(parsed.node, pattern)
  local result, rewrite_err = ast.rewrite(source, path, pattern, replacement)
  if not result then
    return {source = source, matches = matches, error = rewrite_err}
  end
  return {source = source, matches = matches, result = result}
end

local function report_refusals(path: string, result: ast.RewriteResult)
  for _, refusal in ipairs(result.refused) do
    local y, x = ast.span_start(refusal.node)
    io.stderr:write("rewrite: refused " .. path .. ":" .. y .. ":" .. x
      .. ": would drop " .. #refusal.comments .. " comment(s)\n")
  end
end

--- The preview contract sorts refusals by original position without changing
--- the AST library's existing reverse-splice refusal order.
local function refused_json(result: ast.RewriteResult): {any}
  local refused: {RefusalPreview} = {}
  for _, refusal in ipairs(result.refused) do
    local line, column = ast.span_start(refusal.node)
    refused[#refused + 1] = {line = line, column = column,
      comments = #refusal.comments}
  end
  table.sort(refused, function(a: RefusalPreview, b: RefusalPreview): boolean
      return a.line < b.line or (a.line == b.line and a.column < b.column)
    end)
  local values: {any} = {}
  for _, refusal in ipairs(refused) do
    values[#values + 1] = {line = refusal.line, column = refusal.column,
      comments = refusal.comments}
  end
  return json.array(values)
end

local function proposed_json(result: ast.RewriteResult): {any}
  local proposed: {any} = {}
  for _, edit in ipairs(result.edits) do
    local line, column = ast.span_start(edit.node)
    proposed[#proposed + 1] = {line = line, column = column}
  end
  return json.array(proposed)
end

--- Emit exactly one preview record. Encoding normally cannot fail for this
--- primitive-shaped data, but make the failure honest if that assumption ever
--- changes.
local function print_preview_plan(path: string, plan: Plan): boolean, string
  local result = plan.result
  if result then
    local encoded, err = json.encode({
        changed = result.code ~= plan.source,
        code = result.code,
        kind = "rewrite-plan",
        matches = plan.matches,
        path = path,
        proposed = proposed_json(result),
        refused = refused_json(result),
      })
    if not encoded then return false, err or "could not encode rewrite plan" end
    return emit_preview(encoded .. "\n")
  end
  local encoded, err = json.encode({kind = "rewrite-error", matches = plan.matches,
      message = plan.error, path = path})
  if not encoded then return false, err or "could not encode rewrite error" end
  return emit_preview(encoded .. "\n")
end

--- Run search, preview, or partial apply.
--- @param pattern_src string Pattern source, `$NAME`/`$$$NAME` metavariables
--- @param paths {string} PATH... in search mode, else REPL followed by PATH...
--- @param apply boolean Whether `--apply` was given
--- @param preview boolean? Whether `--preview` was given
local function run(pattern_src: string, paths: {string}, apply: boolean,
    preview?: boolean): integer
  local is_preview = preview or false
  if not apply and not is_preview then
    return find.run(pattern_src, paths)
  end
  if #paths < 2 then
    io.write("rewrite: refused: " .. (is_preview and "--preview" or "--apply") ..
      " requires a replacement and at least one path\n")
    return 2
  end
  local replacement = paths[1]
  local real_paths: {string} = {}
  for i = 2, #paths do real_paths[#real_paths + 1] = paths[i] end

  local pattern, compile_err = ast.compile_pattern(pattern_src)
  if not pattern then
    io.write("rewrite: refused: " .. compile_err .. "\n")
    return 2
  end
  local valid, template_err = validate_template(replacement)
  if not valid then
    io.write("rewrite: refused: replacement: " .. template_err .. "\n")
    return 2
  end
  local files, files_err = find.files_for(real_paths)
  if not files then
    io.write("rewrite: refused: " .. files_err .. "\n")
    return 2
  end

  local matches, accepted, refused, failed = 0, 0, 0, 0
  for _, path in ipairs(files) do
    local plan = plan_one(pattern, replacement, path)
    matches = matches + plan.matches
    if plan.error then
      failed = failed + 1
      if is_preview then
        local ok, report_err = print_preview_plan(path, plan)
        if not ok then
          io.stderr:write("rewrite: " .. path .. ": " .. report_err .. "\n")
        end
      end
      io.stderr:write("rewrite: " .. path .. ": " .. plan.error .. "\n")
    else
      local result = plan.result
      report_refusals(path, result)
      refused = refused + #result.refused
      if is_preview then
        local ok, report_err = print_preview_plan(path, plan)
        if not ok then
          failed = failed + 1
          io.stderr:write("rewrite: " .. path .. ": " .. report_err .. "\n")
        else
          accepted = accepted + #result.edits
        end
      else
        -- The commit follows this file's fully formed plan. Do not preplan
        -- later files: a later failure must not roll back earlier writes.
        local ok, write_err = fs.write(path, result.code)
        if not ok then
          failed = failed + 1
          io.stderr:write("rewrite: " .. path .. ": " .. tostring(write_err) .. "\n")
        else
          accepted = accepted + #result.edits
        end
      end
    end
  end

  if is_preview then
    local reported, report_err = emit_preview("rewrite: preview: " .. matches .. " match(es), " .. accepted ..
      " proposed, " .. refused .. " refused, " .. failed .. " failed in " ..
      #files .. " file(s)\n")
    if not reported then
      io.stderr:write("rewrite: preview: " .. report_err .. "\n")
      return 2
    end
  else
    io.write("rewrite: " .. accepted .. " applied, " .. refused ..
      " refused in " .. #files .. " file(s)\n")
  end
  if failed > 0 then return 2 end
  if refused > 0 or accepted == 0 then return 1 end
  return 0
end

local record RewriteModule
  run: function(pattern_src: string, paths: {string}, apply: boolean,
  preview?: boolean): integer
  set_report_io: function(next: ReportIo): ReportIo
end

local M: RewriteModule = {run = run, set_report_io = set_report_io}

return M
