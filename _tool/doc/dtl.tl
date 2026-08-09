--- Parsing for `.d.tl` type declaration files.
---
--- The rendering that used to sit beside this is gone: pages come
--- from `cosmic.doc.render_module`, the one renderer.

local doc_types = require("cosmic.doc")
local type FunctionDoc = doc_types.FunctionDoc
local type ModuleDoc = doc_types.ModuleDoc

local doc_comments = require("_tool.doc.comments")
local extract_doc_comment = doc_comments.extract_doc_comment
local parse_annotations = doc_comments.parse_annotations

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

local record DtlModule
  parse_dtl: function(source: string, file_path: string): ModuleDoc
end

local M: DtlModule = {
  parse_dtl = parse_dtl,
}

return M
