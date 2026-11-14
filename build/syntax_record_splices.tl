--- Every call of a module that the build completes from a record's declaration, resolved together:
--- [`Shape.record_of`] by [`build.syntax_shape_specs`], and [`Schema.message_of`] and [`Schema.enum_of`] by
--- [`build.syntax_protobuf_specs`]. A compile and the language server ask here, so that a resolver added is one both
--- run.
local Driver = require("build.driver")
local ProtobufSpecs = require("build.syntax_protobuf_specs")
local RecordCalls = require("build.syntax_record_calls")
local ShapeSpecs = require("build.syntax_shape_specs")

local record RecordSplices
  --- Whether `source` may hold a call a resolver completes: a test of its text, before any of it is parsed.
  mentions: function(source: string): boolean

  --- What the resolvers splice into `source`, the text `module` of `build` was read from, the last in the source
  --- first. Where a call cannot be resolved, none, and the first refusal and its line.
  splices: function(build: Driver.Build, module: string, file: string, source: string): ShapeSpecs.Found

  --- `source` with every call resolved, or nil and the refusal, as the compiler words one.
  resolve: function(build: Driver.Build, module: string, file: string, source: string): string?, string
end

function RecordSplices.mentions(source: string): boolean
  return source:find("record_of", 1, true) ~= nil or ProtobufSpecs.mentions(source)
end

function RecordSplices.splices(build: Driver.Build, module: string, file: string, source: string): ShapeSpecs.Found
  local shapes = ShapeSpecs.splices(build, module, file, source)
  if shapes.refusal ~= "" then return shapes end
  local messages = ProtobufSpecs.splices(build, module, file, source)
  if messages.refusal ~= "" then
    return { splices = {}, refusal = messages.refusal, line = messages.line }
  end
  if #messages.splices == 0 then return shapes end
  local all: mut {RecordCalls.Splice} = {}
  for _, splice in ipairs(shapes.splices) do all[#all + 1] = splice end
  for _, splice in ipairs(messages.splices) do all[#all + 1] = splice end
  table.sort(all, function(a: RecordCalls.Splice, b: RecordCalls.Splice): boolean
    return a.at > b.at
  end)
  return { splices = all, refusal = "", line = 0 }
end

function RecordSplices.resolve(build: Driver.Build, module: string, file: string, source: string): string?, string
  local found = RecordSplices.splices(build, module, file, source)
  if found.refusal ~= "" then return nil, found.refusal end
  return RecordCalls.spliced(source, found.splices), ""
end

return RecordSplices
