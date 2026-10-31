--- Nodes written by hand, for tests of what reads a record's structure (the form and query binders of cosmic.web): the binders take the
--- node a record's spec describes, and a test of one that no declared record has the shape of draws its own. A node
--- checks nothing; [`ShapeNodes.loose`] pairs one with a check that admits any table, so a binder's tree is only bound.
local Shape = require("cosmic.shape")

local record ShapeNodes
  mut string: Shape.Node
  mut number: Shape.Node
  mut integer: Shape.Node
  mut boolean: Shape.Node
  list: function(of: Shape.Node): Shape.Node
  map: function(of: Shape.Node): Shape.Node
  optional: function(of: Shape.Node): Shape.Node
  one_of: function(...: string | number | boolean): Shape.Node
  record: function(fields: {string: Shape.Node}): Shape.Node
  strict_record: function(fields: {string: Shape.Node}): Shape.Node
  --- `node` as a spec of a table of untrusted values: it describes `node` and admits any table.
  loose: function(node: Shape.Node): Shape.Spec<{string: any}>
end

local function leaf(kind: Shape.Kind): Shape.Node
  return { kind = kind, optional = false }
end

local function record_node(fields: {string: Shape.Node}, strict: boolean): Shape.Node
  return { kind = "record", optional = false, fields = fields, strict = strict }
end

ShapeNodes.string, ShapeNodes.number, ShapeNodes.integer = leaf("string"), leaf("number"), leaf("integer")
ShapeNodes.boolean = leaf("boolean")
function ShapeNodes.list(of: Shape.Node): Shape.Node
  return { kind = "list", optional = false, of = of }
end
function ShapeNodes.map(of: Shape.Node): Shape.Node
  return { kind = "map", optional = false, of = of }
end
function ShapeNodes.optional(of: Shape.Node): Shape.Node
  return { kind = of.kind, optional = true, of = of.of, fields = of.fields, strict = of.strict,
    values = of.values }
end
function ShapeNodes.one_of(...: string | number | boolean): Shape.Node
  local values: {string | number | boolean} = { ... }
  return { kind = "one_of", optional = false, values = values }
end
function ShapeNodes.record(fields: {string: Shape.Node}): Shape.Node
  return record_node(fields, false)
end
function ShapeNodes.strict_record(fields: {string: Shape.Node}): Shape.Node
  return record_node(fields, true)
end

function ShapeNodes.loose(node: Shape.Node): Shape.Spec<{string: any}>
  local anything = Shape.map(Shape.optional(Shape.any))
  return { check = anything.check, describe = function(): Shape.Node return node end }
end

return ShapeNodes
