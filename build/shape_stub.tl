--- The [`cosmic.shape`] that the build's tests of a module resolving `record_of` read in place of the library: the names the
--- code the build writes for a record refers to, and no more.
local record ShapeStub
end

--- The text of the stub, by the name of the module it stands for.
function ShapeStub.standard(): {string: string}
  return {
    ["cosmic.shape"] = [[
local record Shape
  record Node
    kind: string
    optional: boolean
    of?: Node
    fields?: {string: Node}
    strict?: boolean
    values?: {string | number | boolean}
  end
  record Spec<T>
    check: function(value: any, path: string): T?, string
  end
  record Build
    object: function(value: any, path: string, names: {string}, strict: boolean): {any: any}?, string
    get: function(t: {any: any}, name: string): any
    step: function(path: string, name: string): string
    failed: function(why: string, path: string): string
    not_one_of: function(path: string, value: any, ...: string): string
  end
  build: Build
  integer: Spec<integer>
  record_of: function<T>(name: string, make?: function(strict: boolean): Spec<T>, node?: Node): any
end
return Shape
]],
  }
end

return ShapeStub
