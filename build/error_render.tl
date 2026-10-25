--- A module's errors and warnings from the new checker ([`build.driver`]), as the lines a build prints.
---
--- One line for each problem, the errors first and then the warnings, each in source order:
---
---     file:line:column: what is wrong (code): the change that fixes it
---
--- The place is the file's, the code is the key of `cosmic docs <code>` ([`build.error_catalog`]) and the fix is written
--- against the program's own names; an error about a name cosmic removed carries what to write instead as its fix
--- ([`build.removed_fix`]). This is the layout of [`build.importer`]'s `complain`, with the fork's message and hint
--- replaced by the checker's message and fix.
---
--- A fix repeated word for word in one file (the same advice for several unused functions) is printed on the first line
--- that has it, with how many more lines it holds for, and those lines carry the message and the code alone.
---
--- A name the checker could not resolve is followed by what `cosmic docs` answers for it (`-- see also in docs: cosmic.fs`), and
--- a call or a field the checker refused by the worked example that teaches the form (`-- see also: cosmic docs
--- records_interfaces_methods`), when the databases the caller hands over hold them.
---
--- The build prints the errors of a compile through [`ErrorRender.line`] ([`build.pipeline`]).
--
-- TODO: list the fields a record declares in the fix of `field_unknown` where none is near (`R's fields: y`, which the
-- checker's fix does not say), once lang/check.tl's fix names them; this prints the checker's fix as
-- it is.
--
-- TODO: point a `not_assignable` of an argument of a call of a standard-library function to `cosmic docs
-- generics_functions_returns`, as the fork's message did (only `arity`, `overload_none` and `field_unknown` point today,
-- in [`example_query`]), once [`Driver.Problem`] says a problem is an argument's: it carries a code, a message and a place
-- and no marker of the call, and the message cannot be read for it.
local Driver = require("build.driver")
local RemovedFix = require("build.removed_fix")
local Sqlite = require("cosmic.sqlite")
local symbols = require("build.symbols")

local record ErrorRender
  --- The databases a pointer looks a name up in, and whether each is read as the public standard library, asked for only
  --- when a problem earns a pointer: a handle on the store's databases is one a test worker's hold on the store
  --- refuses, which a build that checks clean never asks for.
  type Hints = function(): {Sqlite.Handle}, {boolean}

  --- The worked examples a diagnostic points its reader to (`cosmic docs <name>`), by the kind of diagnostic.
  record Queries
    --- For a call refused for its arguments.
    arguments: string
    --- For a field a record lacks.
    record_key: string
  end
  queries: Queries

  --- The line for `problem` of the file `file`, its fix included: `file:line:column: message (code): fix`.
  line: function(file: string, problem: Driver.Problem): string

  --- What `hints` points a reader of `problem` to, to append to its line: ` -- see also in docs: <names>` for a name the
  --- checker could not resolve that `cosmic docs` answers, ` -- see also: cosmic docs <example>` for a call or a field it
  --- refused that a worked example teaches; "" for any other problem.
  pointers: function(result: Driver.Outcome, problem: Driver.Problem, hints: Hints): string

  --- The lines for the errors and then the warnings of `result`, with the pointers `hints` finds when it is given.
  lines: function(result: Driver.Outcome, hints?: Hints): {string}

  --- [`ErrorRender.lines`] as one string, a line each: "" where the module has no error and no warning.
  complain: function(result: Driver.Outcome, hints?: Hints): string
end

ErrorRender.queries = {
  arguments = "generics_functions_returns",
  record_key = "records_interfaces_methods",
}

--- A problem without its fix: `file:line:column: message (code)`.
local function head_of(file: string, problem: Driver.Problem): string
  return file .. ":" .. tostring(problem.y) .. ":" .. tostring(problem.x) .. ": " .. problem.msg .. " (" .. problem.code .. ")"
end

function ErrorRender.line(file: string, problem: Driver.Problem): string
  return head_of(file, problem) .. ": " .. problem.fix
end

--- The name an error about an unresolved name is about: the name read, or the module `require`d. nil for any other error.
local function unresolved_name(result: Driver.Outcome, problem: Driver.Problem): string?
  if problem.code ~= "unknown_variable" and problem.code ~= "require_unknown" then
    return nil
  end
  local tokens = result.chunk.tokens
  local at = RemovedFix.token_at(tokens, problem.offset)
  if at == nil then
    return nil
  end
  local text = tokens.text[at]
  if text ~= nil and problem.code == "unknown_variable" then
    return text
  end
  if tokens.kind[at + 2] == "string" then
    return tokens.value[at + 2]
  end
  return nil
end

--- What `cosmic docs` answers, exactly, for the name an unresolved-name error is about, as a pointer.
local function docs_pointer(result: Driver.Outcome, problem: Driver.Problem, hints: ErrorRender.Hints): string
  local name = unresolved_name(result, problem)
  if name == nil then
    return ""
  end
  local databases, public = hints()
  local found = symbols.named(databases, public, name)
  if #found == 0 then
    return ""
  end
  return " -- see also in docs: " .. table.concat(found, ", ")
end

--- The worked example that teaches the form a problem is about, by the query that finds it: nil for a problem of no form.
local function example_query(problem: Driver.Problem): string?
  if problem.code == "arity" or problem.code == "overload_none" then
    return ErrorRender.queries.arguments
  elseif problem.code == "field_unknown" then
    return ErrorRender.queries.record_key
  end
  return nil
end

--- The worked example a refused call or field points to, as a pointer, when a database holds it. A problem whose fix is
--- what cosmic replaced a removed name with is given none: the replacement is the answer.
local function example_pointer(problem: Driver.Problem, hints: ErrorRender.Hints): string
  local query = example_query(problem)
  if problem.removed or query == nil then
    return ""
  end
  local databases, public = hints()
  if not symbols.has_example_query(databases, public, query) then
    return ""
  end
  return " -- see also: cosmic docs " .. query
end

function ErrorRender.pointers(result: Driver.Outcome, problem: Driver.Problem, hints: ErrorRender.Hints): string
  return docs_pointer(result, problem, hints) .. example_pointer(problem, hints)
end

function ErrorRender.lines(result: Driver.Outcome, hints?: ErrorRender.Hints): {string}
  local file = result.source.filename
  local out: mut {string} = {}
  local first: mut {string: integer} = {}
  local repeats: mut {integer: integer} = {}
  local groups: {{Driver.Problem}} = { result.errors, result.warnings }
  for _, group in ipairs(groups) do
    for _, problem in ipairs(group) do
      local pointers = ""
      if hints ~= nil then
        pointers = ErrorRender.pointers(result, problem, hints)
      end
      local at = first[problem.fix]
      if at ~= nil then
        repeats[at] = (repeats[at] or 0) + 1
        out[#out + 1] = head_of(file, problem) .. pointers
      else
        first[problem.fix] = #out + 1
        out[#out + 1] = ErrorRender.line(file, problem) .. pointers
      end
    end
  end
  local lines: mut {string} = {}
  for at, text in ipairs(out) do
    local more = repeats[at]
    if more ~= nil then
      lines[#lines + 1] = text .. " (same for " .. tostring(more) .. " more)"
    else
      lines[#lines + 1] = text
    end
  end
  return lines
end

function ErrorRender.complain(result: Driver.Outcome, hints?: ErrorRender.Hints): string
  return table.concat(ErrorRender.lines(result, hints), "\n")
end

return ErrorRender
