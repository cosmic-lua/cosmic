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
    -- a use refused because the narrowing of a place was dropped before
    -- it: `dropped_place`, `dropped_kind`, `dropped_by`, `dropped_y`,
    -- `dropped_x`, and the fields of the refusal it was
    "narrowing_dropped"
    -- the note on a use of a field or a global that a test of narrowed
    -- nothing (only a local is narrowed): the error keeps its own code and
    -- carries this one as `also`, with `dropped_place`, `dropped_kind` (`field`,
    -- `global`, or `captured` for a local the code around a function assigns
    -- after the function is made), `dropped_by` (the place, or the assignment
    -- as written), `dropped_y`, `dropped_x` and `dropped_copy`. It is a note: the use may
    -- not rely on the test
    "narrowing_not_local"
    -- a local read where a path from its declaration has not assigned it:
    -- `variable`, `closure` where the read is a function literal that
    -- names it with `ran_kind`, `ran_y`, `ran_x` for what may call it, and
    -- `skipped_kind`, `skipped_y`, `skipped_x` for the statement a path
    -- went by that skipped the assignment
    "not_assigned"
    -- a local declared with neither a type nor a value: `variable`
    "no_type"
    -- a function literal assigning a local declared outside it: `variable`,
    -- and `declared_y`, `declared_x` where that local is declared
    "captured_assigned"
    -- a `goto` that is not a jump forward to the label that ends the body of
    -- the loop around it, or a label no such `goto` names: `variable` (the
    -- label's name), `goto_y`, `goto_x` (none for a label), and `label_y`,
    -- `label_x` (none where the `goto` names no label), and `local_y`, `local_x`
    -- where a `repeat` continue jumps over a local its `until` sees
    "goto_not_continue"
    -- an assignment to a field its record declares `readonly`: `key` (the
    -- field, the first when `fields` lists several) and `subject` (the
    -- record, as it is named)
    "readonly_field"
    -- a record and an interface it takes a field from that disagree on
    -- `readonly`: `key`, `subject` (the record), `declared_in` (the
    -- interface), `expected` (the field's type) and `readonly_in`
    -- (`record` or `interface`, the one that declares it read-only)
    "readonly_disagrees"
    -- a table made without the type of a record with a read-only field, taken
    -- for that record: `key` (the field, the first when `fields` lists
    -- several), `subject` (the record) and `variable` (the name the table
    -- is held by, where it has one)
    "readonly_literal"
    -- a table literal checked against a record that leaves out a read-only
    -- field: `key` (the field, the first when `fields` lists several) and
    -- `subject` (the record)
    "readonly_missing"
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
    -- For a field a record and its interface disagree on: which of them
    -- declares it read-only, `record` or `interface`.
    readonly_in: string | nil
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
    -- "argument", "function" or "type".
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

    -- For a refusal of a place whose narrowing was dropped: the place
    -- (`r.n`), what dropped it (`assignment`, `write`, `call`,
    -- `operator` or `loop`), that expression as written, and where it is.
    -- For a use of a field or a global a test of narrowed nothing (`also`
    -- is `narrowing_not_local`): the place, `field`, `global` or `captured`,
    -- the place (or the assignment `g = ...`) as written, and where the test is.
    dropped_place: string | nil
    dropped_kind: string | nil
    dropped_by: string | nil
    -- A name for the local to copy the place to (`also` is
    -- `narrowing_not_local`): one that no name in scope, global, builtin,
    -- keyword or later declaration of the function around it has.
    dropped_copy: string | nil
    -- A second code the error carries beside `code`: `narrowing_not_local`
    -- on a use that reads a place a test of narrowed nothing.
    also: ErrorCode | nil
    dropped_y: integer | nil
    dropped_x: integer | nil
    -- For a loop's refusal: the kind of the drop its pass ran.
    dropped_via: string | nil

    -- For a local read before it is assigned: whether the read is a
    -- function literal that names it, what may call that function before
    -- the assignment (`ran_kind`: `call`, `operator`, `iterator`,
    -- `return`, `never` or `scope`, at `ran_y`, `ran_x` unless it is the end
    -- of the scope), and the statement a path went by that skipped the
    -- assignment (`branch`, `if` or `loop`), and where.
    closure: boolean | nil
    ran_kind: string | nil
    ran_y: integer | nil
    ran_x: integer | nil
    skipped_kind: string | nil
    skipped_y: integer | nil
    skipped_x: integer | nil

    -- For a function literal that assigns a local declared outside it: where
    -- that local is declared.
    declared_y: integer | nil
    declared_x: integer | nil
    -- For a `goto` or a label that is not a continue: where the `goto` is
    -- and where the label it names is.
    goto_y: integer | nil
    goto_x: integer | nil
    label_y: integer | nil
    label_x: integer | nil
    -- For a `goto` of a `repeat` that jumps past a local its `until` can
    -- see: where the local is declared.
    local_y: integer | nil
    local_x: integer | nil
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
    -- Whether the Lua generated checks a value against the kind of its
    -- declared type at a declared parameter, return value and record
    -- field write.
    runtime_checks?: boolean
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
    -- When set, the checker appends `name=key` to it for each variable it
    -- finds: the name and the key of the binding it stands for, so that a
    -- test sees which binding a name was read as.
    key_trace: {string} | nil
    -- When set, the checker compares the type its facts gave each read with
    -- the one the narrowing on its scopes would have given, and appends
    -- `y:x place: shadow T, old U` to it for each read where the two
    -- disagree.
    shadow_mismatches: {string} | nil
    -- How many reads that took, so that none found does not mean none looked at.
    shadow_reads: integer | nil
    -- How many of those were reads of a field path.
    shadow_field_reads: integer | nil
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

  -- How the checker finds a module it has not been given: the name it
  -- was found under and a handle that reads the whole source with
  -- `read("*a")` and then closes. An ordinary field, so the build
  -- replaces it with one that answers from the staged tree; the
  -- compiler's own finds nothing.
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
