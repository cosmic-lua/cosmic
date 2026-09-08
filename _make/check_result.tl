--- Machine-readable scoped checking results, written only on explicit request.
local fs = require("cosmic.fs")
local json = require("cosmic.json")
local teal = require("cosmic.teal")

local record Failure
  file: string
  message: string
end

local record Result
  version: integer
  root: string
  complete: boolean
  ok: boolean
  changed: boolean
  conservative: boolean
  reason: string
  roots: {string}
  selected: {string}
  dependencies: {string}
  excluded: {string}
  proved: {string}
  checked: {string}
  diagnostics: {teal.Issue}
  failures: {Failure}
end

local function new(root: string): Result
  return {version = 1, root = root, complete = true, ok = true,
    changed = false, conservative = false, reason = "", roots = {},
    selected = {}, dependencies = {}, excluded = {}, proved = {}, checked = {},
    diagnostics = {}, failures = {}}
end

local function failure(result: Result, file: string, message: string)
  result.complete = false
  result.ok = false
  result.failures[#result.failures + 1] = {file = file, message = message}
end

local function write(result: Result, path: string): boolean, string
  local encoded, err = json.encode(result)
  if not encoded then return false, err end
  return fs.write(path, encoded .. "\n")
end

local record ResultModule
  type Result = Result
  type Failure = Failure
  new: function(root: string): Result
  failure: function(result: Result, file: string, message: string)
  write: function(result: Result, path: string): boolean, string
end
local M: ResultModule = {new = new, failure = failure, write = write}
return M
