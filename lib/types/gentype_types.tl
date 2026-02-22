--- Shared type definitions for gentype and gentype_render.

local record gentype_types

  record Param
    name: string
    param_type: string
    description: string
    optional: boolean
  end

  record Return
    return_type: string
    description: string
  end

  record FuncDecl
    name: string
    module: string
    description: {string}
    params: {Param}
    returns: {Return}
    is_method: boolean
    class_name: string
    nodiscard: boolean
  end

  record Constant
    name: string
    const_type: string
    description: {string}
  end

  record Field
    name: string
    field_type: string
    description: {string}
  end

  record ClassDecl
    name: string
    module: string
    parent: string
    fields: {Field}
    methods: {FuncDecl}
    description: {string}
  end

  record ModuleDecl
    name: string
    description: {string}
    functions: {FuncDecl}
    classes: {ClassDecl}
    constants: {Constant}
  end

end

return gentype_types
