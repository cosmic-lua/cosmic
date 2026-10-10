-- The part of the vendored Teal compiler this tree uses. Nothing else
-- in the tree reaches into it. [`build.teal`] is what loads it.

local record compiler
  record Error
    filename: string
    y: integer
    x: integer
    msg: string
    -- For a key a record lacks (`invalid key ...`): the record's value
    -- fields, unordered (patch/tl/33a).
    fields: {string} | nil
  end

  -- TODO: declare `ast`, `type`, [`Env.modules`], the reporter's
  -- collector and [`parse_program`]'s answer as the records build.ast
  -- (Node) and build.receivers (Type) declare, moved here, so the casts
  -- build/contracts.tl's casts table lets build.ast.node,
  -- build.receivers and build.contracts (the module's own answer, for
  -- rules 10 and 11) make at this boundary go, and build.importer's `is`
  -- check of the tree; the records would first have to stop requiring
  -- this declaration themselves.
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

  -- A record global's type: its fields as a table and in declaration
  -- order.
  record GlobalType
    fields: {string:any} | nil
    field_order: {string} | nil
  end

  -- The declaration of a record global, whose `def` is its type.
  record GlobalDeclaration
    def: GlobalType | nil
  end

  -- One global of the checker's environment.
  record Global
    t: GlobalDeclaration | nil
  end

  record Env
    defaults: Defaults
    globals: {string:Global}
    modules: {string:any}
    -- When set, the checker hands every node's type to `reporter`'s
    -- collector as it checks; see [`build.receivers`].
    report_types: boolean | nil
    reporter: any
  end

  -- One comment tl's lexer attached to the token that follows it.
  record Comment
    x: integer
    y: integer
    text: string
  end

  -- One lexed token. Only the fields the tree reads: a leaf's own text,
  -- its kind ("identifier", "keyword", "string", ...), its position, and
  -- the comments it carries.
  record Token
    tk: string
    kind: string
    y: integer
    x: integer
    comments: {Comment} | nil
  end

  -- Where the checker looks for a module it has not been given. The
  -- entries are package.path-shaped: a `?` stands for the module's
  -- name with its dots turned into slashes, and the `.lua` suffix is
  -- replaced with `.tl` or `.d.tl`.
  path: string

  -- How the checker finds a module it has not been given: the name it
  -- was found under and a handle that reads the whole source with
  -- `read("*a")` and then closes. An ordinary field, so the build
  -- replaces it with one that answers from the staged tree; `path`
  -- above is only what the compiler's own looks at.
  search_module: function(name: string, search_all: boolean): string | nil, any

  new_env: function(Options): Env | nil, string
  -- The Lua source for a Teal source, and what the checker found. The
  -- code is nil when the input did not parse.
  gen: function(input: string, env: Env, options: any,
                language: string): string | nil, Result
  -- Checks `input` as the module `filename`: every position the checker
  -- records (a type's, an error's) carries that name, which is how it
  -- tells one module's types from another's. [`gen`] checks under the
  -- empty name, so a type a module declares looks to the checker of the
  -- module that uses it as declared in the same file.
  check_string: function(input: string, env: Env, filename: string,
                         language: string): Result
  -- The Lua source for the syntax tree a [`check_string`] answers, nil
  -- and why when it cannot be written.
  generate: function(ast: any, target: string, options: any): string | nil, string
  -- Lexes `source` into its token stream plus any lex errors. `lex`
  -- itself never fails outright: unlexable bytes still come back as
  -- (possibly partial) tokens, with the trouble recorded in the second
  -- return.
  lex: function(source: string, name: string): {Token}, {Error}
  -- Parses an already-lexed token stream. The AST comes back erased to
  -- `any` -- [`build.ast.node`] is what casts it to a real shape, once,
  -- for every later consumer -- and parse errors are appended to
  -- `errs`, the same table `lex` populated with its own lex errors.
  parse_program: function(tokens: {Token}, errs: {Error}, name: string,
                          lang?: string): any
end

return compiler
