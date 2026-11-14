--- A small project as the tests of the resolvers build one ([`build.syntax_shape_specs`],
--- [`build.syntax_protobuf_specs`]). Test support.
local Driver = require("build.driver")
local Array = require("cosmic.array")
local Programs = require("lang.check_programs")

local record syntax_resolver_fixture
end

--- A build of the project `files` (name to text). `standard` holds the modules of the standard library the project
--- names, by text: they are lowered for their types and never checked.
function syntax_resolver_fixture.build_of(files: {string: string}, standard: {string: string}): Driver.Build
  local entries: mut {{string}} = {}
  for name, text in pairs(files) do
    entries[#entries + 1] = { name, text }
  end
  table.sort(entries, function(a: {string}, b: {string}): boolean
    -- Each entry is the `{ name, text }` pair pushed above.
    return Array.at(a, 1) < Array.at(b, 1)
  end)
  local index = Driver.index(entries, function(_file: string): boolean
    return false
  end)
  local build = Driver.new({
    globals = { Driver.declarations("std", "std.d.tl", Programs.library, {}) },
    adjust = nil, external = {}, types = false,
  })
  build:provide(Driver.files(index))
  build:provide(Driver.stubs(standard))
  return build
end

return syntax_resolver_fixture
