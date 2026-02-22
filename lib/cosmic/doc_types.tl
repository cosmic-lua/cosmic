--- Shared type definitions for the doc and docs modules.

local record doc_types

  --- A function parameter with type and description.
  record Param
    name: string
    param_type: string
    description: string
  end

  --- A function return value with type and description.
  record Return
    return_type: string
    description: string
  end

  --- Documentation for a function.
  record FunctionDoc
    name: string
    description: string
    params: {Param}
    returns: {Return}
    signature: string
    line: integer
    is_local: boolean
  end

  --- Documentation for a record type.
  record RecordDoc
    name: string
    description: string
    fields: {{string, string, string}} -- name, type, description
    line: integer
  end

  --- Documentation for an example function.
  record ExampleDoc
    name: string
    description: string
    body: string
    expected_output: string
    line: integer
  end

  --- Complete documentation for a module.
  record ModuleDoc
    file: string
    module_doc: string
    functions: {FunctionDoc}
    records: {RecordDoc}
    examples: {ExampleDoc}
  end

  --- A documentation index containing all modules.
  record DocIndex
    modules: {string: ModuleDoc}
  end

  --- Search result entry.
  record SearchResult
    module_name: string
    symbol_name: string
    symbol_type: string
    description: string
    match_score: integer
  end

  --- Entry for examples list.
  record ExampleEntry
    module_name: string
    example_name: string
    description: string
  end

  --- Result from a docs operation.
  record DocsResult
    ok: boolean
    output: string
  end

end

return doc_types
