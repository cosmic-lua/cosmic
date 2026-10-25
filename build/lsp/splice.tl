--- The rewrite a build makes of a text before it checks it
--- ([`build.shape_specs`]), as `cosmic lsp` ([`build.lsp.check`]) finds it
--- of a document, quickly where it can, and a place in the rewritten text
--- read back into the document's own.

local ast = require("build.ast")
local lines = require("build.lsp.lines")
local shape_specs = require("build.shape_specs")
local source = require("build.lsp.source")
local stub = require("build.stub")
local type compiler = require("build.compiler")

local record splice
end

--- `splices`, found in `from`, moved to the same lines and columns of
--- `text`, which holds every token of `from` where `from` has it (a stub
--- of it, [`stub.made`]); nil where a splice does not follow the same
--- token in both.
local function moved(from: string, text: string, splices: {shape_specs.Splice}): {shape_specs.Splice}?
  local from_starts, starts = lines.checker_starts(from), lines.checker_starts(text)
  local out: mut {shape_specs.Splice} = {}
  for _, one in ipairs(splices) do
    local line = 1
    while true do
      local next_start = from_starts[line + 1]
      if next_start == nil or next_start > one.at then break end
      line = line + 1
    end
    local start, from_start = starts[line], from_starts[line]
    if start == nil or from_start == nil then return nil end
    local at = start + (one.at - from_start)
    local token = from:sub(from_start, one.at):match("[^%s]*$") or ""
    if text:sub(at - #token + 1, at) ~= token then return nil end
    out[#out + 1] = { at = at, text = one.text }
  end
  return out
end

--- What [`shape_specs.splices`] finds of `text`, the file `name`, the
--- module `path`. Where every call to resolve is a top-level statement's,
--- they are found in the text with every function body left out, which
--- the checker reads in a fraction of the time and which declares the
--- same records but where a body declares past itself ([`build.stub`]);
--- otherwise, or where that finds other calls, in the whole text. `tally`
--- counts which it was ([`source.Tally`]).
--
-- TODO: find the calls in the whole text where a body may declare past
-- itself, or in a stub that keeps every such body, once [`build.stub`]'s
-- TODO is done: until then a function a body adds to the record a call
-- names is not seen (a build refuses the call, this splices it), and
-- where a body's `local type` resolves a type the record's field names
-- and a later top-level declaration of that name exists, a build splices
-- the body's type and this the top-level one.
function splice.found(built: compiler, env: compiler.Env, name: string, text: string,
                      path: string, tally: source.Tally): shape_specs.Found
  local _, wanted = text:gsub("record_of%(", "")
  if wanted > 0 then
    local parsed, _ = ast.parse(built, text, name)
    if parsed ~= nil then
      local bodiless = stub.made(parsed, true).text
      local _, kept = bodiless:gsub("record_of%(", "")
      if kept == wanted then
        local found = shape_specs.splices(built, env, name, path, bodiless)
        if found.refusal == "" and #found.splices == wanted then
          local splices = moved(bodiless, text, found.splices)
          if splices ~= nil then
            tally.bodiless_splices = tally.bodiless_splices + 1
            return { splices = splices, refusal = "", line = 0 }
          end
        end
      end
    end
    tally.whole_splices = tally.whole_splices + 1
  end
  return shape_specs.splices(built, env, name, path, text)
end

--- The byte of the document's own text at byte `offset` of it as
--- spliced (`splices`, the last first, as [`shape_specs.splices`] answers
--- them). A byte a splice put in is the byte the splice follows.
function splice.unspliced(splices: {shape_specs.Splice}, offset: integer): integer
  local shift = 0
  for i = #splices, 1, -1 do
    local one = assert(splices[i])
    local first = one.at + shift + 1
    if offset < first then break end
    if offset < first + #one.text then return one.at end
    shift = shift + #one.text
  end
  return offset - shift
end

--- `served`, the module `name`, as a build rewrites it ([`shape_specs.resolve`]),
--- in `env` of `built`, or as it is before there are both. A rewrite
--- that fails leaves the text as it is: the module's refusal is its own,
--- not the document's.
function splice.rewritten(built: compiler?, env: compiler.Env?, name: string,
                          served: source.Served): string
  if built == nil or env == nil then return served.text end
  local ok, resolved, _ = pcall(shape_specs.resolve, built, env, served.file, name, served.text)
  if ok and resolved ~= nil then return resolved end
  return served.text
end

return splice
