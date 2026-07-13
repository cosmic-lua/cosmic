--- Extract documentation from Teal files and render as markdown.
--- Parses doc comments, records, functions, and examples from .tl files.

local types = require("cosmic.doc.types")
local Param = types.Param
local Return = types.Return
local ModuleDoc = types.ModuleDoc

local doc_render = require("cosmic.doc.render")

local BYTE_NEWLINE = string.byte("\n")
local BYTE_LPAREN = string.byte("(")
local BYTE_RPAREN = string.byte(")")
local BYTE_DQUOTE = string.byte('"')
local BYTE_SQUOTE = string.byte("'")
local BYTE_BACKSLASH = string.byte("\\")

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

--- Extract function signature starting from a given position.
--- @param source string The source code
--- @param start_pos integer Position to start searching from
--- @return string The extracted signature
local function extract_signature(source: string, start_pos: integer): string
  local sig_start = source:find("%(", start_pos)
  if not sig_start then return "()" end
  local sig_end = sig_start
  local depth = 0
  for i = sig_start, #source do
    local b = source:byte(i)
    if b == BYTE_LPAREN then depth = depth + 1
    elseif b == BYTE_RPAREN then
      depth = depth - 1
      if depth == 0 then
        sig_end = i
        local j = i + 1
        while j <= #source do
          if source:byte(j) == BYTE_NEWLINE then break end
          sig_end = j
          j = j + 1
        end
        break
      end
    end
  end
  return source:sub(sig_start, sig_end)
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

--- Parse `name: type` fields from a record body.
--- @param source string The full source (for doc-comment lookup)
--- @param body string The record body text
--- @param body_start integer Absolute position of body within source
--- @return {{string, string, string}} List of {name, type, description}
local function parse_record_fields(source: string, body: string, body_start: integer): {{string, string, string}}
  local fields: {{string, string, string}} = {}
  local field_pos = 1
  while field_pos <= #body do
    local fstart, fend, fname, ftype = body:find("%s*([%w_]+)%s*:%s*([^\n]+)", field_pos)
    if not fstart then break end
    -- Find the start of the line where fname begins (skip leading whitespace in fstart)
    local fname_pos = fstart + body:sub(fstart, fend):find(fname, 1, true) - 1
    local fname_line_start = fname_pos
    while fname_line_start > 1 and body:byte(fname_line_start - 1) ~= BYTE_NEWLINE do
      fname_line_start = fname_line_start - 1
    end
    local line_text = body:sub(fname_line_start, fname_pos - 1)
    if line_text:match("^%s*%-%-") then
      field_pos = fend + 1
      goto continue_field
    end
    do
      local field_absolute_pos = body_start + fname_pos
      local field_doc = extract_doc_comment(source, field_absolute_pos)
      local _, _, field_description = parse_annotations(field_doc)
      local clean_type = ftype:match("^%s*(.-)%s*$")
      if clean_type:match("%-%-%s*.*$") then
        clean_type = clean_type:gsub("%s*%-%-.*$", "")
      end
      table.insert(fields, {fname, clean_type, field_description or ""})
    end
    field_pos = fend + 1
    ::continue_field::
  end
  return fields
end

--- Find the end of a record block via record/enum vs end depth tracking.
--- @param text string The text to scan
--- @param start integer Position just inside the record (after its header line)
--- @return integer Position of the last body character (before `end`)
--- @return integer Position just past the closing `end`
local function find_record_end(text: string, start: integer): integer, integer
  local depth = 1
  local i = start
  local rec_end = i
  while i <= #text and depth > 0 do
    local word_start, word_end, word = text:find("(%a+)", i)
    if word_start == i then
      if word == "record" or word == "enum" then depth = depth + 1
      elseif word == "end" then
        depth = depth - 1
        if depth == 0 then rec_end = word_start - 1 end
      end
      i = word_end + 1
    else i = i + 1 end
  end
  return rec_end, i
end

--- Parse a .tl file and extract documentation.
--- @param source string The source code to parse
--- @param file_path string Path to the file being parsed
--- @return ModuleDoc Complete documentation for the module
local function parse(source: string, file_path: string): ModuleDoc
  local doc: ModuleDoc = {
    file = file_path, module_doc = nil, functions = {}, records = {}, examples = {},
  }
  -- Extract module-level doc comment
  local first_doc = source:match("^%s*(%-%-%-[^\n]*)")
  if first_doc then
    local module_doc_lines: {string} = {}
    local pos = 1
    while true do
      local line_end = source:find("\n", pos)
      if not line_end then break end
      local line = source:sub(pos, line_end - 1)
      local doc_content = line:match("^%s*%-%-%-(.*)$")
      if doc_content then
        table.insert(module_doc_lines, doc_content)
        pos = line_end + 1
      else break end
    end
    if #module_doc_lines > 0 then
      doc.module_doc = table.concat(module_doc_lines, "\n")
    end
  end
  -- Find functions
  local line_num = 1
  local last_pos = 1
  local function update_line_num(new_pos: integer)
    for i = last_pos, new_pos - 1 do
      if source:byte(i) == BYTE_NEWLINE then line_num = line_num + 1 end
    end
    last_pos = new_pos
  end
  -- Local functions
  for func_start, is_local, func_name in source:gmatch("()(local%s+)function%s+([%w_:]+)<?[^>%(]*>?%s*%(") do
    update_line_num(func_start as integer)
    local line_start = func_start as integer
    while line_start > 1 and source:byte(line_start - 1) ~= BYTE_NEWLINE do
      line_start = line_start - 1
    end
    local line_prefix = source:sub(line_start, (func_start as integer) - 1)
    if line_prefix:match("^%s*%-%-") then goto continue_local end
    if not (func_name as string):match("^Example") then
      local signature = extract_signature(source, func_start as integer)
      local func_doc = extract_doc_comment(source, func_start as integer)
      local params, returns, description = parse_annotations(func_doc)
      table.insert(doc.functions, {
          name = func_name as string, description = description,
          params = params, returns = returns, signature = signature,
          line = line_num, is_local = is_local ~= nil,
        })
    end
    ::continue_local::
  end
  -- Non-local functions
  line_num = 1
  last_pos = 1
  for func_start, func_name in source:gmatch("()function%s+([%w_:]+)<?[^>%(]*>?%s*%(") do
    local line_start = func_start as integer
    while line_start > 1 and source:byte(line_start - 1) ~= BYTE_NEWLINE do
      line_start = line_start - 1
    end
    local line_prefix = source:sub(line_start, (func_start as integer) - 1)
    if line_prefix:match("^%s*%-%-") then goto continue_nonlocal end
    local before = source:sub(math.max(1, (func_start as integer) - 20), (func_start as integer) - 1)
    if not before:match("local%s*$") and not before:match(":%s*$") then
      update_line_num(func_start as integer)
      if not (func_name as string):match("^Example") then
        local signature = extract_signature(source, func_start as integer)
        local func_doc = extract_doc_comment(source, func_start as integer)
        local params, returns, description = parse_annotations(func_doc)
        table.insert(doc.functions, {
            name = func_name as string, description = description,
            params = params, returns = returns, signature = signature,
            line = line_num, is_local = false,
          })
      end
    end
    ::continue_nonlocal::
  end
  -- Records
  line_num = 1
  last_pos = 1
  for rec_start, rec_name in source:gmatch("()local%s+record%s+([%w_]+)") do
    update_line_num(rec_start as integer)
    local rec_doc = extract_doc_comment(source, rec_start as integer)
    local _, _, description = parse_annotations(rec_doc)
    local fields: {{string, string, string}} = {}
    local body_start = source:find("\n", rec_start as integer)
    if body_start then
      local record_end, _ = find_record_end(source, body_start + 1)
      local body = source:sub(body_start, record_end)
      -- Extract nested `record Name ... end` blocks as their own entries
      -- (e.g. cosmic.fs.types.WalkStat), then blank them out so their
      -- fields are not misattributed to the parent record.
      local search_pos = 1
      while true do
        local n_start, n_header_end, n_name = body:find("\n%s*record%s+([%w_]+)", search_pos)
        if not n_start then break end
        local n_body_start = body:find("\n", n_header_end + 1)
        if not n_body_start then break end
        local n_rec_end, n_past_end = find_record_end(body, n_body_start + 1)
        local n_body = body:sub(n_body_start, n_rec_end)
        local n_doc = extract_doc_comment(source, body_start + n_start)
        local _, _, n_description = parse_annotations(n_doc)
        table.insert(doc.records, {
            name = n_name as string, description = n_description,
            fields = parse_record_fields(source, n_body, body_start + n_body_start - 1),
            line = line_num,
          })
        local blanked = body:sub(n_start, n_past_end - 1):gsub("[^\n]", " ")
        body = body:sub(1, n_start - 1) .. blanked .. body:sub(n_past_end)
        search_pos = n_past_end
      end
      fields = parse_record_fields(source, body, body_start)
    end
    table.insert(doc.records, {
        name = rec_name as string, description = description,
        fields = fields, line = line_num,
      })
  end
  -- Examples
  line_num = 1
  last_pos = 1
  for func_start, func_name in source:gmatch("()local%s+function%s+(Example[%w_]*)%s*%(") do
    update_line_num(func_start as integer)
    local example_doc = extract_doc_comment(source, func_start as integer, true)
    local _, _, example_description = parse_annotations(example_doc)
    local body_start = source:find("%)", func_start as integer) + 1
    local depth = 1
    local i = body_start
    while i <= #source and depth > 0 do
      local b = source:byte(i)
      if b == BYTE_DQUOTE or b == BYTE_SQUOTE then
        local quote = b
        i = i + 1
        while i <= #source do
          if source:byte(i) == BYTE_BACKSLASH then i = i + 2
          elseif source:byte(i) == quote then i = i + 1; break
          else i = i + 1 end
        end
      elseif source:sub(i, i + 1) == "--" then
        local newline = source:find("\n", i)
        i = newline and newline + 1 or #source + 1
      else
        local word_start, word_end, word = source:find("(%a+)", i)
        if word_start == i then
          if word == "function" or word == "if" or word == "for" or word == "while" then depth = depth + 1
          elseif word == "until" or word == "end" then depth = depth - 1 end
          i = word_end + 1
        else i = i + 1 end
      end
    end
    local body_end = i - 4
    local body = source:sub(body_start, body_end)
    local expected: string = nil
    local output_start = body:find("%-%-%s*Output:")
    if output_start then
      local output_lines: {string} = {}
      local output_pos = output_start
      local line_end = body:find("\n", output_pos)
      if line_end then
        output_pos = line_end + 1
        while true do
          local cs, _, prefix, content = body:find("^(%s*%-%-%s?)(.*)\n?", output_pos)
          if cs == output_pos and prefix then
            table.insert(output_lines, content)
            output_pos = output_pos + #prefix + #content
            if body:sub(output_pos, output_pos) == "\n" then output_pos = output_pos + 1
            else break end
          else break end
        end
      end
      expected = table.concat(output_lines, "\n")
    end
    table.insert(doc.examples, {
        name = func_name as string, description = example_description,
        body = body, expected_output = expected, line = line_num,
      })
  end
  return doc
end

--- Parse a file and return structured documentation.
local function parse_file(file_path: string): ModuleDoc | nil, string
  local f, err = io.open(file_path, "r")
  if not f then return nil, "cannot open file: " .. (err or "unknown") end
  local source = f:read("*a")
  f:close()
  if file_path:match("%.d%.tl$") then
    return doc_render.parse_dtl(source, file_path), nil
  else
    return parse(source, file_path), nil
  end
end

--- Main entry point: parse file and render markdown.
local function render_file(file_path: string): boolean, string
  local f, err = io.open(file_path, "r")
  if not f then return false, "cannot open file: " .. (err or "unknown") end
  local source = f:read("*a")
  f:close()
  local doc: ModuleDoc
  if file_path:match("%.d%.tl$") then
    doc = doc_render.parse_dtl(source, file_path)
  else
    doc = parse(source, file_path)
  end
  return true, doc_render.render(doc)
end

local cosmo = require("cosmo")

--- Serialize a ModuleDoc to Lua source code.
local function serialize(doc: ModuleDoc): string
  return (cosmo.EncodeLua(doc as table))
end

--- A documentation index containing all modules (the shared record from
--- cosmic.doc.types, so extraction and query agree on the type).
local type DocIndex = types.DocIndex

local function serialize_index(index: DocIndex): string
  return (cosmo.EncodeLua(index as table))
end

local function load_index(source: string): DocIndex | nil, string
  local chunk, err = load("return " .. source, "=docindex", "t", {})
  if not chunk then return nil, "failed to parse index: " .. (err or "unknown") end
  local ok, result = pcall(chunk)
  if not ok then return nil, "failed to load index: " .. tostring(result) end
  return result as DocIndex, nil
end

-- The query half of the module (issue #557: `doc` and `docs` converged
-- into one family): lookup and search over the index embedded in the
-- binary, behind the `--docs` CLI.
local query = require("cosmic.doc.query")
local DocsResult = types.DocsResult
local SearchResult = types.SearchResult

local record DocModule
  -- Extraction: parse Teal source and render/serialize documentation.
  parse: function(source: string, file_path: string): ModuleDoc
  parse_dtl: function(source: string, file_path: string): ModuleDoc
  parse_file: function(file_path: string): ModuleDoc | nil, string
  render: function(doc: ModuleDoc): string
  render_file: function(file_path: string): boolean, string
  serialize: function(doc: ModuleDoc): string
  serialize_index: function(index: DocIndex): string
  load_index: function(source: string): DocIndex | nil, string

  -- Query: the index embedded in the binary (`--docs`).
  run: function(query?: string): DocsResult
  has_docs: function(): boolean
  list_topics: function(include_cosmo?: boolean): {{string, string}}
  embedded_index: function(): DocIndex | nil, string
  render_module: function(name: string, doc: ModuleDoc): string
  search: function(query: string, include_cosmo?: boolean): {SearchResult}
  render_search_results: function(results: {SearchResult}, query: string): string
  show_module_examples: function(query: string): DocsResult
  show_guide: function(topic: string): DocsResult
  list_guide_topics: function(): {string}
  list_guides: function(): {{string, string}}
  strip_frontmatter: function(content: string): string
end

local M: DocModule = {
  parse = parse,
  parse_dtl = doc_render.parse_dtl,
  parse_file = parse_file,
  render = doc_render.render,
  render_file = render_file,
  serialize = serialize,
  serialize_index = serialize_index,
  load_index = load_index,

  run = query.run,
  has_docs = query.has_docs,
  list_topics = query.list_topics,
  embedded_index = query.embedded_index,
  render_module = query.render_module,
  search = query.search,
  render_search_results = query.render_search_results,
  show_module_examples = query.show_module_examples,
  show_guide = query.show_guide,
  list_guide_topics = query.list_guide_topics,
  list_guides = query.list_guides,
  strip_frontmatter = query.strip_frontmatter,
}

return M
