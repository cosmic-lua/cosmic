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
    -- True when an `@overload fun(...): nil, <error> Errno` failure form is
    -- present, meaning the call returns `<value>, Errno` at runtime.
    fallible: boolean
    -- The LuaLS error type captured from the failure overload (e.g.
    -- "unix.Errno"), rendered as the trailing return alongside the success value.
    error_type: string
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

  -- A named type alias (`---@alias mod.Name <type>`). A literal-string
  -- union renders as a Teal enum; anything else as a transparent alias.
  record AliasDecl
    name: string -- bare name (module prefix stripped)
    module: string
    alias_type: string -- raw LuaLS right-hand side
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
    aliases: {AliasDecl}
  end

end

return gentype_types
