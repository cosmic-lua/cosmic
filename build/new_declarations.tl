--- The declarations of cosmic's own modules that the new checker reads in the new grammar and the fork cannot read at
--- all: a line of the module, as [`lang.translate`] spells the fork's Teal, that the new checker reads as another.
---
--- [`Json.Value`] is `string | number | boolean | Json.Null | {Json.Value} | {string: Json.Value}`: an alias that reaches
--- itself through the element of an array and the value of a map ([`lang.declarations`]). The fork refuses a union of an
--- array and a map ("cannot discriminate a union between multiple table types") and cannot relate a recursive alias, so
--- cosmic/json.tl declares [`Json.Value`] as `any` for it, and the parameters that take a [`Json.Value`] ([`Json.encode`],
--- `Web.json`) take `any` in the fork's check of the tree. The new checker reads the line below in place: its text after
--- the module is translated ([`lang.translate`]) and before it is parsed, for the tree's own modules ([`build.tree_program`])
--- and for the standard library a project's check reads ([`build.driver`]'s `standard`).
---
--- A line is replaced whole, by the line it is when it is the one the table names, once. [`NewDeclarations.missing`] says
--- which a text lacks, so that a test holds each to the file it is about; an edit to the file that this does not know of
--- leaves the line as it was and the test fails.
--
-- TODO: write these declarations in the files and delete this module, once the new checker replaces the fork
-- (doc/plans/strict-teal.md, "the switch"): the fork refuses the lines, and until then they are read here.
local record NewDeclarations
  --- A line of a file in the fork's Teal and the lines the new grammar reads in its place.
  record Edit
    was: string
    now: string
    --- Why the fork cannot read `now`.
    why: string
  end

  --- The edits, by the path of the file below the root of the tree.
  files: {string: {Edit}}

  --- Whether the file `file` (a path below the root of the tree) has an edit.
  edited: function(file: string): boolean

  --- `text`, the translated text of the file `file`, with its edits made: the same text where it has none. With `strict` it
  --- raises where a line an edit names is not in `text` exactly once, since the file has drifted from the table; a stub of
  --- the module, which may leave a line out, is read without it.
  apply: function(file: string, text: string, strict?: boolean): string

  --- The lines of the edits of `file` that `text`, its source, does not hold exactly once.
  missing: function(file: string, text: string): {string}
end

NewDeclarations.files = {
  ["cosmic/json.tl"] = {
    {
      was = "  type Value = any",
      now = "  type Value = string | number | boolean | Json.Null | {Json.Value} | {string: Json.Value}",
      why = "a union of an array and a map, and an alias that reaches itself",
    },
    {
      was = "  null: any",
      now = "  null: Json.Null",
      why = "the fork compares a table with a `Json.Null` as it compares any two types that cannot be equal, and refuses",
    },
    {
      was = "    null_value?: any",
      now = "    null_value?: Json.Value",
      why = "a `Json.Null` is not stored as `any` ([`Json.Value`] is what `Json.null` is a part of)",
    },
    {
      was = "    null_value: any",
      now = "    null_value: Json.Value?",
      why = "a `Json.Null` is not stored as `any`",
    },
    {
      was = "  null_value: any",
      now = "  null_value: Json.Value?",
      why = "a `Json.Null` is not stored as `any`",
    },
    {
      was = "                           null_value?: any): any?, string",
      now = "                           null_value?: Json.Value): any?, string",
      why = "a `Json.Null` is not stored as `any`",
    },
    {
      was = "function Json.array(t?: {any}): {any}",
      now = "function Json.array(t?: {Json.Value}): {Json.Value}",
      why = "the fork's `{any}` takes any array, and its `Json.Value` is `any`, which it does not relate to an array",
    },
    {
      was = "function Json.encode(value: any, opts?: Json.EncodeOptions): string?, string",
      now = "function Json.encode(value: Json.Value, opts?: Json.EncodeOptions): string?, string",
      why = "the fork takes a record for any alias of `any`, which it does not relate to a record",
    },
  },
  ["cosmic/web/response.tl"] = {
    {
      was = "function Response.json(value: any, opts?: Types.ResponseOptions): Types.Response",
      now = "function Response.json(value: Json.Value, opts?: Types.ResponseOptions): Types.Response",
      why = "the fork takes a record for any alias of `any`, which it does not relate to a record",
    },
  },
  ["cosmic/web/htmx.tl"] = {
    {
      was = "    detail: any",
      now = "    detail: Json.Value?",
      why = "the fork takes a record for any alias of `any`, which it does not relate to a record",
    },
  },
  ["cosmic/web/types.tl"] = {
    {
      was = "local Stream = require(\"cosmic.stream\")",
      now = "local Stream = require(\"cosmic.stream\") local type Json = require(\"cosmic.json\")",
      why = "the module is required here for the type of `json` below, which the fork reads as `any`",
    },
    {
      was = "    json?: any",
      now = "    json?: Json.Value",
      why = "the fork takes a record for any alias of `any`, which it does not relate to a record",
    },
  },
  ["cosmic/web/init.tl"] = {
    {
      was = "local Stream = require(\"cosmic.stream\")",
      now = "local Stream = require(\"cosmic.stream\") local type Json = require(\"cosmic.json\")",
      why = "the module is required here for the type of `json` below, which the fork reads as `any`",
    },
    {
      was = "  json: function(value: any, opts?: Types.ResponseOptions): Types.Response",
      now = "  json: function(value: Json.Value, opts?: Types.ResponseOptions): Types.Response",
      why = "the fork takes a record for any alias of `any`, which it does not relate to a record",
    },
  },
}

--- The number of times the line `line` is a whole line of `text`.
local function times(text: string, line: string): integer
  local n = 0
  for held in (text .. "\n"):gmatch("([^\n]*)\n") do
    if held == line then
      n = n + 1
    end
  end
  return n
end

function NewDeclarations.edited(file: string): boolean
  return NewDeclarations.files[file] ~= nil
end

function NewDeclarations.apply(file: string, text: string, strict?: boolean): string
  local edits = NewDeclarations.files[file]
  if edits == nil then
    return text
  end
  if strict then
    local lost = NewDeclarations.missing(file, text)
    if #lost > 0 then
      error("new_declarations: " .. file .. " lacks, or repeats, the line " .. string.format("%q", lost[1]) ..
          " that build/new_declarations.tl edits: change the table with the file", 0)
    end
  end
  local out: {string} = {}
  local replaced: {string: boolean} = {}
  for held in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = held
    for _, edit in ipairs(edits) do
      if held == edit.was and not replaced[edit.was] then
        replaced[edit.was] = true
        line = edit.now
      end
    end
    out[#out + 1] = line
  end
  -- The text was split at every newline with one more added, so that the lines joined by newlines are the text.
  return table.concat(out, "\n")
end

function NewDeclarations.missing(file: string, text: string): {string}
  local out: {string} = {}
  for _, edit in ipairs(NewDeclarations.files[file] or {}) do
    if times(text, edit.was) ~= 1 then
      out[#out + 1] = edit.was
    end
  end
  return out
end

return NewDeclarations
