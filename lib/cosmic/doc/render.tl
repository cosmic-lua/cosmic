--- Rendering and .d.tl parsing for the doc module.
--- Contains the markdown renderer and the type declaration file parser.

local types = require("cosmic.doc.types")
local Param = types.Param
local Return = types.Return
local FunctionDoc = types.FunctionDoc
local RecordDoc = types.RecordDoc
local ExampleDoc = types.ExampleDoc
local ModuleDoc = types.ModuleDoc

--- Extract leading doc comment before a position.
local function extract_doc_comment(source: string, pos: integer, allow_regular_comments?: boolean): string
  local line_start = pos
  while line_start > 1 and source:sub(line_start - 1, line_start - 1) ~= "\n" do
    line_start = line_start - 1
  end
  local doc_lines: {string} = {}
  local check_pos = line_start - 1
  while check_pos > 0 do
    local prev_line_start = check_pos
    while prev_line_start > 1 and source:sub(prev_line_start - 1, prev_line_start - 1) ~= "\n" do
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

--- Render documentation as markdown.
local function render(doc: ModuleDoc): string
  local lines: {string} = {}
  local module_name = doc.file:match("([^/]+)%.d%.tl$") or doc.file:match("([^/]+)%.tl$") or doc.file
  if module_name == "init" then
    -- A directory module's init shard is the module: title the page by
    -- the directory name (fs/init.tl -> fs), not the shard filename.
    module_name = doc.file:match("([^/]+)/init%.tl$") or module_name
  end
  table.insert(lines, "# " .. module_name)
  table.insert(lines, "")
  if doc.module_doc then
    table.insert(lines, doc.module_doc)
    table.insert(lines, "")
  end
  if #doc.records > 0 then
    table.insert(lines, "## Types")
    table.insert(lines, "")
    for _, rec in ipairs(doc.records) do
      table.insert(lines, "### " .. rec.name)
      table.insert(lines, "")
      if rec.description then
        table.insert(lines, rec.description)
        table.insert(lines, "")
      end
      if #rec.fields > 0 then
        table.insert(lines, "```teal")
        table.insert(lines, "local record " .. rec.name)
        for _, field in ipairs(rec.fields) do
          local field_name, field_type, field_desc = field[1], field[2], field[3]
          if field_desc and field_desc ~= "" then
            for desc_line in field_desc:gmatch("[^\n]+") do
              table.insert(lines, "  -- " .. desc_line)
            end
          end
          table.insert(lines, "  " .. field_name .. ": " .. field_type)
        end
        table.insert(lines, "end")
        table.insert(lines, "```")
        table.insert(lines, "")
      end
    end
  end
  -- Functions
  local exported_names: {string: boolean} = {}
  for _, rec in ipairs(doc.records) do
    if rec.name:match("Module$") then
      for _, field in ipairs(rec.fields) do
        if field[2]:match("^function") then
          exported_names[field[1]] = true
        end
      end
    end
  end
  local exported_functions: {FunctionDoc} = {}
  for _, func in ipairs(doc.functions) do
    if not func.is_local or exported_names[func.name] then
      table.insert(exported_functions, func)
    end
  end
  if #exported_functions > 0 then
    table.insert(lines, "## Functions")
    table.insert(lines, "")
    for _, func in ipairs(exported_functions) do
      table.insert(lines, "### " .. func.name)
      table.insert(lines, "")
      if func.signature then
        table.insert(lines, "```teal")
        table.insert(lines, "function " .. func.name .. func.signature)
        table.insert(lines, "```")
        table.insert(lines, "")
      end
      if func.description then
        table.insert(lines, func.description)
        table.insert(lines, "")
      end
      if #func.params > 0 then
        table.insert(lines, "**Parameters:**")
        table.insert(lines, "")
        for _, param in ipairs(func.params) do
          local param_line = "- `" .. param.name .. "` (" .. param.param_type .. ")"
          if param.description then param_line = param_line .. " - " .. param.description end
          table.insert(lines, param_line)
        end
        table.insert(lines, "")
      end
      if #func.returns > 0 then
        table.insert(lines, "**Returns:**")
        table.insert(lines, "")
        for _, ret in ipairs(func.returns) do
          local ret_line = "- " .. ret.return_type
          if ret.description then ret_line = ret_line .. " - " .. ret.description end
          table.insert(lines, ret_line)
        end
        table.insert(lines, "")
      end
    end
  end
  -- Examples
  if #doc.examples > 0 then
    table.insert(lines, "## Examples")
    table.insert(lines, "")
    for _, example in ipairs(doc.examples) do
      local title = example.name:gsub("^Example_?", ""):gsub("_", " ")
      if title == "" then title = "Basic usage" end
      table.insert(lines, "### " .. title)
      table.insert(lines, "")
      if example.description then
        table.insert(lines, example.description)
        table.insert(lines, "")
      end
      table.insert(lines, "```teal")
      local body = example.body
      local output_start = body:find("%-%-%s*Output:")
      if output_start then body = body:sub(1, output_start - 1) end
      body = body:gsub("^%s*\n", ""):gsub("\n%s*$", "")
      table.insert(lines, body)
      table.insert(lines, "```")
      table.insert(lines, "")
      if example.expected_output then
        table.insert(lines, "Output:")
        table.insert(lines, "```")
        table.insert(lines, example.expected_output)
        table.insert(lines, "```")
        table.insert(lines, "")
      end
    end
  end
  return table.concat(lines, "\n")
end

--- Parse a .d.tl type declaration file and extract documentation.
local function parse_dtl(source: string, file_path: string): ModuleDoc
  local doc: ModuleDoc = {
    file = file_path, module_doc = nil, functions = {}, records = {}, examples = {},
  }
  local module_name = source:match("^%-%- type declarations for cosmo%.([%w_]+)")
  if module_name then
    doc.module_doc = "Type declarations for the `" .. module_name .. "` module."
  end
  local return_record = source:match("return%s+([%w_]+)%s*$")

  local pos = 1
  while pos <= #source do
    local rec_start, rec_end, rec_name = source:find("local%s+record%s+([%w_]+)", pos)
    if not rec_start then break end
    local depth = 1
    local i = rec_end + 1
    local record_body_start = i
    while i <= #source and depth > 0 do
      if source:sub(i, i) == '"' or source:sub(i, i) == "'" then
        local quote = source:sub(i, i)
        i = i + 1
        while i <= #source do
          if source:sub(i, i) == "\\" then i = i + 2
          elseif source:sub(i, i) == quote then i = i + 1; break
          else i = i + 1 end
        end
      elseif source:sub(i, i + 1) == "--" then
        local newline = source:find("\n", i)
        i = newline and newline + 1 or #source + 1
      else
        local word_start, word_end, word = source:find("(%a+)", i)
        if word_start == i then
          if word == "record" or word == "enum" then depth = depth + 1
          elseif word == "end" then depth = depth - 1 end
          i = word_end + 1
        else i = i + 1 end
      end
    end
    local record_body_end = i - 4
    local record_body = source:sub(record_body_start, record_body_end)
    local rec_doc = extract_doc_comment(source, rec_start)
    local _, _, rec_description = parse_annotations(rec_doc)
    local fields: {{string, string, string}} = {}
    local methods: {FunctionDoc} = {}
    local line_start = 1
    while line_start <= #record_body do
      local line_end = record_body:find("\n", line_start) or #record_body + 1
      local line = record_body:sub(line_start, line_end - 1)
      local field_name, field_type = line:match("^%s*([%w_]+):%s*(.+)%s*$")
      if field_name and not line:match("^%s*%-%-") then
        local field_absolute_pos = record_body_start + line_start - 1
        local field_doc = extract_doc_comment(source, field_absolute_pos)
        if field_type:match("^function") then
          local params, returns, description = parse_annotations(field_doc)
          if #params == 0 then
            local sig_params = field_type:match("^function%((.-)%)")
            if sig_params and sig_params ~= "" then
              for param_part in sig_params:gmatch("[^,]+") do
                param_part = param_part:match("^%s*(.-)%s*$")
                if not param_part:match("^self:") then
                  local pname, ptype = param_part:match("^([%w_%.]+)%??:%s*(.+)$")
                  if pname then
                    table.insert(params, {name = pname, param_type = ptype, description = nil})
                  end
                end
              end
            end
          end
          if #returns == 0 then
            local ret_type = field_type:match("%):%s*(.+)$")
            if ret_type then
              for ret_part in ret_type:gmatch("[^,]+") do
                ret_part = ret_part:match("^%s*(.-)%s*$")
                if ret_part ~= "" then
                  table.insert(returns, {return_type = ret_part, description = nil})
                end
              end
            end
          end
          table.insert(methods, {
              name = field_name, description = description, params = params,
              returns = returns, signature = field_type:match("^function(.+)$") or "()",
              line = 0, is_local = false,
            })
        else
          local _, _, field_description = parse_annotations(field_doc)
          table.insert(fields, {field_name, field_type, field_description or ""})
        end
      end
      line_start = line_end + 1
    end
    if rec_name == return_record then
      for _, method in ipairs(methods) do table.insert(doc.functions, method) end
      if #fields > 0 then
        table.insert(doc.records, {
            name = rec_name .. " Constants",
            description = "Constants defined in the " .. rec_name .. " module.",
            fields = fields, line = 0,
          })
      end
    else
      local all_fields: {{string, string, string}} = {}
      for _, f in ipairs(fields) do table.insert(all_fields, f) end
      for _, m in ipairs(methods) do
        table.insert(all_fields, {m.name, "function" .. m.signature, m.description or ""})
      end
      table.insert(doc.records, {
          name = rec_name, description = rec_description,
          fields = all_fields, line = 0,
        })
    end
    pos = i + 1
  end
  return doc
end

local record DocRenderModule
  render: function(doc: ModuleDoc): string
  parse_dtl: function(source: string, file_path: string): ModuleDoc
end

local M: DocRenderModule = {
  render = render,
  parse_dtl = parse_dtl,
}

return M
