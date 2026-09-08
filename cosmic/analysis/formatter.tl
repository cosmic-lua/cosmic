--- Typed boundary for the formatter's additive parsed-snapshot entry point.
--- The formatter agent supplies `cosmic.format_snapshot`; keeping this
--- adapter typed avoids widening the legacy `cosmic.format` module.
local formatter = require("cosmic.format_snapshot")
local source = require("cosmic.ast.source")

local type Snapshot = source.Snapshot
local type FormatResult = formatter.FormatResult

local record FormatterModule
  type FormatResult = FormatResult
  format_snapshot: function(Snapshot): FormatResult, Snapshot | nil
end
local M: FormatterModule = {format_snapshot = formatter.format_snapshot}
return M
