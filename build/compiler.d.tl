-- The part of the vendored Teal compiler this tree uses. Nothing else
-- in the tree reaches into it. `build.teal` is what loads it.

local record compiler
  record Error
    filename: string
    y: integer
    x: integer
    msg: string
  end

  record Result
    ast: any
    type: any
    syntax_errors: {Error}
    type_errors: {Error}
    warnings: {Error}
  end

  record Defaults
    feat_lax: string
    gen_compat: string
    gen_target: string
  end

  record Options
    defaults: Defaults
  end

  record Env
    modules: {string:any}
    module_filenames: {string:string}
    loaded: {string:any}
    defaults: Defaults
  end

  -- Where the checker looks for a module it has not been given. The
  -- entries are package.path-shaped: a `?` stands for the module's
  -- name with its dots turned into slashes, and the `.lua` suffix is
  -- replaced with `.tl` or `.d.tl`.
  path: string

  new_env: function(Options): Env | nil, string
  -- The Lua source for a Teal source, and what the checker found. The
  -- code is nil when the input did not parse.
  gen: function(input: string, env: Env, options: any, language: string): string | nil, Result
  version: function(): string
end

return compiler
