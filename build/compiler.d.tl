-- The part of the Teal compiler this tree uses. Nothing else
-- in the tree reaches into it. [`build.teal`] is what loads it.

local record compiler
  -- Plain comments, not docs: `cosmic docs` and the unresolved-name pointer
  -- look symbols up by their last name, and a field called `i` or `key` of the
  -- compiler's own records is none a program meant.
  --
  -- What an error is, so that a reader does not parse its message: a
  -- code names the kind, and the fields of [`Error`] named at it are set.
  -- `other` is every error nothing reads.
  enum ErrorCode
    -- a value of one type where another is wanted: `got`, `expected`
    "mismatch"
    -- a nominal type refused for another: `got`, `expected`
    "not_a"
    -- a `local type` require of a module that returns a value: `got`
    "require_not_type"
    -- the argument of `require`: `got`
    "require_argument"
    -- a key a record lacks: `key`, `variable`, `subject`, `members`, `fields`
    "invalid_key"
    -- a key read of a value that is no record: `key`, `variable`, `subject`, `members`
    "cannot_index_key"
    -- an index of a value of a type that takes none: `subject`, `members`
    "cannot_index_object"
    -- `<close>` on a type with no `__close`: `variable`, `subject`, `members`
    "not_closable"
    -- `ipairs` of a value that is no array: `subject`, `members`
    "not_array"
    -- `pairs` of a value that is no table: `subject`, `members`
    "pairs_of_non_table"
    -- a call that answers no value, assigned: `variable`; `callee` and
    -- `callee_never` where the call is one to a function that never returns
    "no_initial_value"
    -- a unary operator on a type that takes none: `operator`, `members`
    "operator_unary"
    -- a binary operator on types that take none: `operator`, `left`, `right`
    "operator_binary"
    -- a numeric `for` bound of a type that is no number: `index`, `members`
    "for_bound"
    -- a call with the wrong number of arguments: `given`, `expects`, `expects_most`
    "arity"
    -- a declaration that hides an earlier one: `variable`, `declares`, and
    -- `declared_before` where the earlier one is the program's own
    "shadows"
    -- a name that is declared nowhere: `variable`
    "unknown_variable"
    -- a declaration nothing uses: `variable`, `declares`
    "unused"
    -- the parser refusing a construct as a syntax error
    "syntax_error"
    -- the parser wanting `local` or `global` before a type declaration: `key`
    "declaration_scope"
    -- a type name that is declared nowhere: `names`, and `subject`, the
    -- type as shown (with its type arguments)
    "unknown_type"
    -- a field a table literal names that its record lacks: `key`, `subject`, `fields`
    "unknown_field"
    -- a `require` of a module nothing provides: `key`
    "module_not_found"
    -- a generic record named without its type arguments: `names`, `type_arguments`
    "missing_type_arguments"
    -- the parser wanting one of some tokens: `expected_tokens`
    "expected_one_of"
    -- the parser wanting a type list
    "type_list_expected"
    "other"
  end

  record Error
    filename: string
    y: integer
    x: integer
    msg: string
    -- The kind of a warning (`unused`, `redeclaration`, `hint`, ...); nil
    -- for an error.
    tag: string | nil
    -- Where the checker keeps an error while it sorts them.
    i: integer | nil
    -- For a key a record lacks (`invalid key ...`): the record's value
    -- fields, unordered.
    fields: {string} | nil
    -- Nil where the error was not made by the checker.
    code: ErrorCode | nil

    -- Where a value was wanted, as the message names it: "argument",
    -- "return", "self", or "in local declaration", "in assignment" and
    -- the like. `context_name` is the variable or field the message
    -- also names there, and `index` the position of an argument.
    context: string | nil
    context_name: string | nil
    index: integer | nil
    -- Whether words the message puts between its context and the error
    -- itself (a field that did not match, a type parameter) make the
    -- context something other than where the value was wanted.
    nested: boolean | nil
    -- The type parameter a type was refused for.
    type_parameter: string | nil
    -- The method of a record declared against an interface, and the
    -- record that declares it, when the error is that signature's.
    signature_of: string | nil
    declared_in: string | nil
    -- The kind (typename) of the record-like type a key was refused.
    resolved_kind: string | nil

    -- The types an error is about, as the checker shows them. A
    -- `*_members` list holds the members of a union (a type that is none
    -- holds itself), each shown alone; `got_kind` and `subject_kind` say
    -- what the type is (its typename), and `expected_names` the names of
    -- a nominal one.
    got: string | nil
    got_kind: string | nil
    got_members: {string} | nil
    expected: string | nil
    expected_members: {string} | nil
    expected_names: {string} | nil
    subject: string | nil
    subject_kind: string | nil
    members: {string} | nil
    left: string | nil
    left_members: {string} | nil
    left_is_generic_function: boolean | nil
    right: string | nil
    right_members: {string} | nil

    -- The names the error mentions.
    key: string | nil
    variable: string | nil
    operator: string | nil
    names: {string} | nil
    type_arguments: {string} | nil
    expected_tokens: {string} | nil

    -- What a declaration that is hidden or unused declares: "variable",
    -- "argument", "function", "type" or "label".
    declares: string | nil

    -- Whether the declaration a name hides is in the program itself.
    declared_before: boolean | nil

    -- The callee of a call, as written ([`Json.decode`], `obj:get`), and
    -- whether it never returns.
    callee: string | nil
    callee_never: boolean | nil

    -- A call's arguments: how many it was given, how many its callee
    -- takes when that is one number, and the largest number it names.
    given: integer | nil
    expects: integer | nil
    expects_most: integer | nil
    -- Whether `msg` has had advice appended.
    advised: boolean | nil
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
    defaults?: Defaults
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
  gen: function(input: string, env?: Env, options?: any,
                language?: string): string | nil, Result
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
