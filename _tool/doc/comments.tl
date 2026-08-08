--- Doc-comment extraction shared by the doc extractor (`cosmic.doc.init`)
--- and its `.d.tl` renderer (`cosmic.doc.render`). Internal by position
--- (`cosmic.doc.comments` is two segments under `cosmic/`; see
--- `cosmic/doc/visibility.tl`) — plumbing for those two, not published
--- API. Housed on its own (rather than in either of its callers) so
--- neither has to require the other: `doc.init` already requires
--- `doc.render` to render what it parses, so a copy living in either one
--- would force a cycle.

local doc_types = require("cosmic.doc")
local type Param = doc_types.Param
local type Return = doc_types.Return

local BYTE_NEWLINE = string.byte("\n")

--- Extract leading doc comment (--- or -- style) before a position.
--- @param source string The source code to search
--- @param pos integer The position to search backwards from
--- @param allow_regular_comments boolean If true, also extract -- style comments (default: false)
--- @return string The extracted doc comment, or nil if none found
local function extract_doc_comment(source: string, pos: integer, allow_regular_comments?: boolean): string
  local line_start = pos
  while line_start > 1 and source:byte(line_start - 1) ~= BYTE_NEWLINE do
    line_start = line_start - 1
  end
  local doc_lines: {string} = {}
  local check_pos = line_start - 1
  while check_pos > 0 do
    local prev_line_start = check_pos
    while prev_line_start > 1 and source:byte(prev_line_start - 1) ~= BYTE_NEWLINE do
      prev_line_start = prev_line_start - 1
    end
    local line = source:sub(prev_line_start, check_pos - 1)
    local doc_content = line:match("^%s*%-%-%-(.*)$")
    if doc_content then
      table.insert(doc_lines, 1, doc_content)
      check_pos = prev_line_start - 1
    elseif allow_regular_comments then
      local regular_comment = line:match("^%s*%-%-([^%-].*)$")
      if regular_comment then
        table.insert(doc_lines, 1, regular_comment)
        check_pos = prev_line_start - 1
      elseif line:match("^%s*$") then break
      else break end
    elseif line:match("^%s*$") then break
    else break end
  end
  if #doc_lines == 0 then return nil end
  return table.concat(doc_lines, "\n")
end

--- Parse @param and @return annotations from doc comment.
--- @param doc string The doc comment to parse
--- @return {Param} List of parameters
--- @return {Return} List of return values
--- @return string The description text
local function parse_annotations(doc: string): {Param}, {Return}, string
  if not doc then return {}, {}, nil end
  local params: {Param} = {}
  local returns: {Return} = {}
  local desc_lines: {string} = {}
  for line in doc:gmatch("[^\n]+") do
    local param_name, param_type, param_desc = line:match("^%s*@param%s+(%S+)%s+(%S+)%s*(.*)")
    if param_name then
      table.insert(params, {
          name = param_name, param_type = param_type,
          description = param_desc ~= "" and param_desc or nil,
        })
    else
      local ret_type, ret_desc = line:match("^%s*@return%s+(%S+)%s*(.*)")
      if ret_type then
        table.insert(returns, {
            return_type = ret_type, description = ret_desc ~= "" and ret_desc or nil,
          })
      else
        table.insert(desc_lines, line)
      end
    end
  end
  local description = #desc_lines > 0 and table.concat(desc_lines, "\n") or nil
  return params, returns, description
end

local record CommentsModule
  extract_doc_comment: function(source: string, pos: integer, allow_regular_comments?: boolean): string
  parse_annotations: function(doc: string): {Param}, {Return}, string
end

local M: CommentsModule = {
  extract_doc_comment = extract_doc_comment,
  parse_annotations = parse_annotations,
}

return M
