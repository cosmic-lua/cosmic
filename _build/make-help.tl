#!/usr/bin/env cosmic
-- Parse Makefile targets and extract documentation comments

local proc = require("cosmic.proc")
local fs = require("cosmic.fs")

-- The module record is declared UP HERE so `Item` is a type a caller
-- can name (`help.Item`). _types/make-help.d.tl used to publish that
-- shape while the source kept Item as a bare local; deleting the
-- declaration (once the bare `require("make-help")` became
-- `_build.make-help`) meant the source had to actually expose what the
-- declaration had been promising.
local record MakeHelp
  record Item
    type: string
    name: string
    description: string
  end

  record FormatOptions
    width: number
  end

  parse_makefile: function(content: string): {Item}
  format_help: function(items: {Item}, options?: FormatOptions): string
  parse_phony_targets: function(content: string): {string: boolean}
end

local type Item = MakeHelp.Item
local type FormatOptions = MakeHelp.FormatOptions

-- Parse a makefile and extract documented targets and options
-- Supports: ## description (line before target or variable)
local function parse_makefile(content: string): {Item}
  local items: {Item} = {}
  local pending_comment: string = nil

  for line in content:gmatch("[^\r\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")

    -- Comment line: ## description
    local comment = trimmed:match("^##%s*(.*)$")
    if comment then
      if pending_comment then
        pending_comment = pending_comment .. " " .. comment
      else
        pending_comment = comment
      end
      goto continue
    end

    -- Target line: target: deps
    local target_match = trimmed:match("^([a-zA-Z_][a-zA-Z0-9_-]*):%s*(.*)$")
    if target_match then
      if pending_comment then
        table.insert(items, {
            type = "target",
            name = target_match,
            description = pending_comment,
          })
      end
      pending_comment = nil
      goto continue
    end

    -- Variable assignment: name = value or name := value or name ?= value
    local var_match = trimmed:match("^([a-zA-Z_][a-zA-Z0-9_-]*)%s*[?:]?=%s*")
    if var_match then
      if pending_comment then
        table.insert(items, {
            type = "option",
            name = var_match,
            description = pending_comment,
          })
      end
      pending_comment = nil
      goto continue
    end

    -- Non-comment, non-target line resets pending comment
    -- But allow common Makefile directives like .PHONY, .PRECIOUS, etc
    if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%.") then
      pending_comment = nil
    end

    ::continue::
  end

  return items
end

-- Format help output
local function format_help(items: {Item}, options?: FormatOptions): string
  options = options or {}
  local width = options.width or 20

  local output: {string} = {}
  local targets: {Item} = {}
  local vars: {Item} = {}

  -- Separate targets and options
  for _, item in ipairs(items) do
    if item.type == "target" then
      table.insert(targets, item)
    elseif item.type == "option" then
      table.insert(vars, item)
    end
  end

  table.insert(output, "Usage: make [target] [options]")
  table.insert(output, "")
  table.insert(output, "Targets:")

  for _, item in ipairs(targets) do
    local pad_len = math.max(0, width - #item.name) as integer -- cast: number to integer
    table.insert(output, "  " .. item.name .. string.rep(" ", pad_len) .. item.description)
  end

  -- Add options section if we have any
  if #vars > 0 then
    table.insert(output, "")
    table.insert(output, "Options:")
    for _, item in ipairs(vars) do
      -- cast: number to integer
      local pad_len = math.max(0, width - #item.name) as integer
      table.insert(output, "  " .. item.name .. string.rep(" ", pad_len) .. item.description)
    end
  end

  return table.concat(output, "\n")
end

-- Main execution
local function main(args: {string}): number, string
  local makefiles: {string} = {}
  for _, a in ipairs(args) do
    table.insert(makefiles, a)
  end
  if #makefiles == 0 then
    makefiles = {"Makefile"}
  end

  -- Aggregate documented targets and options across every makefile given
  -- (make passes $(MAKEFILE_LIST), so included cook.mk files count too).
  local items: {Item} = {}
  for _, makefile in ipairs(makefiles) do
    local content, read_err = fs.read(makefile)
    if not content then
      return 1, "Failed to read " .. makefile .. ": " .. (read_err or "unknown error")
    end
    for _, item in ipairs(parse_makefile(content)) do
      table.insert(items, item)
    end
  end

  print(format_help(items))
  return 0
end

if proc.is_main() then
  local exit_code, err = main(arg)
  if err then
    io.stderr:write(err .. "\n")
  end
  os.exit(exit_code as integer) -- cast: number to integer
end

-- Extract all .PHONY targets from makefile content
local function parse_phony_targets(content: string): {string: boolean}
  local targets: {string: boolean} = {}
  for line in content:gmatch("[^\r\n]+") do
    local phony = line:match("^%.PHONY:%s*(.+)$")
    if phony then
      for target in phony:gmatch("%S+") do
        targets[target] = true
      end
    end
  end
  return targets
end

local M: MakeHelp = {
  parse_makefile = parse_makefile,
  format_help = format_help,
  parse_phony_targets = parse_phony_targets,
}

return M
