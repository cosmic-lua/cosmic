
local VERSION = "0.24.8"

-- These are definitions that are core to the language.
--
-- In Lua terms, these are definitions that fundamental to the
-- Lua language behavior itself, that is, which are valid
-- even before one does luaL_openlibs to load the standard
-- library.
local prelude = [=====[
do
   global interface any
   end
   global interface thread
   end
   global interface userdata
      is userdata
   end

   global record metatable<T>
      enum Mode
         "k" "v" "kv"
      end

      __call: function(T, any...): any...
      __mode: Mode
      __name: string
      __tostring: function(T): string
      __pairs: function<K, V>(T): function(): (K, V)

      __index: any --[[FIXME: function | table | anything with an __index metamethod]]
      __newindex: any --[[FIXME: function | table | anything with an __index metamethod]]

      __gc: function(T)
      __close: function(T)

      __add: function<A, B, C>(A, B): C
      __sub: function<A, B, C>(A, B): C
      __mul: function<A, B, C>(A, B): C
      __div: function<A, B, C>(A, B): C
      __idiv: function<A, B, C>(A, B): C
      __mod: function<A, B, C>(A, B): C
      __pow: function<A, B, C>(A, B): C
      __band: function<A, B, C>(A, B): C
      __bor: function<A, B, C>(A, B): C
      __bxor: function<A, B, C>(A, B): C
      __shl: function<A, B, C>(A, B): C
      __shr: function<A, B, C>(A, B): C
      __concat: function<A, B, C>(A, B): C

      __len: function<A>(T): A
      __unm: function<A>(T): A
      __bnot: function<A>(T): A

      __eq: function<A, B>(A, B): boolean
      __lt: function<A, B>(A, B): boolean
      __le: function<A, B>(A, B): boolean
   end
end
]=====]

-- The Lua standard library's declarations, checker/stdlib.d.tl: the
-- trust boundary of the type layer, the one typing the checker takes
-- without proof. This file does not hold them. The boot gives the compiled
-- checker a first line that makes their text the local `stdlib`
-- (core/bridge.lua's `bootstrap`), so the compiler the tool carries holds
-- the declarations it was compiled with; the declaration below is for the
-- checker that reads this file and emits nothing. Auditing or changing a
-- declaration is an edit of that file; the checker logic that treats some
-- of them as special cases, by name, is `tl.new_env`'s
-- `set_special_function` calls.
global stdlib: string

-- The checker is several files: this one is the entry, and each other
-- `checker/*.tl` is a module it requires by `checker.<name>` and the boot
-- compiles as a chunk of its own (core/bridge.lua's `bootstrap`). The
-- carried compiler holds every file's Lua; a `require` of one of them
-- is answered from it, never from the module system, which does not
-- exist when the checker runs first.
local flow = require("checker.flow")
local narrowing = require("checker.narrowing")

-- A local this file declares `local x: T = nil` is one whose value the code
-- after it assigns: a variable a closure reads before the assignment (a
-- function declared ahead of the one that calls it), or one set on some
-- paths and read where it is nil on the others. Its `= nil` states the
-- reliance on nil being in every type, which the checker holds the tree
-- to no more (a local with no value is refused there unless it is
-- `T | nil`, see [`flow.unassigned_read`]).
-- TODO: give each of them its honest type (`T | nil`, narrowed where it is
-- read) or a value, once nil is excluded from every type but one that names
-- it: the checker then refuses `local x: T = nil`, and the checker's own
-- source is the last of the tree to migrate (the roadmap's nil item).

-- The compiled checker's main chunk holds Lua's 200 local variables; about
-- 100 are taken, with the boot's `stdlib` and `require` locals among them.
-- A top-level `local` (a `local function` included, a type declaration
-- not) past the 200 fails the boot with "too many local variables".
-- TODO: split the rest of the checker into modules by concern (parser,
-- subtype relation, declarations, emitter) as checker/flow.tl was,
-- each with a main chunk of its own. It waits on seams between those
-- concerns, which the checker's source does not yet have.

-- Where a node or type is, which a guard carries to report at.
local type Where = narrowing.Where

local record Errors
   filename: string
   errors: {Error}
   warnings: {Error}
   unknown_dots: {string:boolean}
   -- Defined once `show_type` is: the members of a union, each shown alone.
   members: function(Type): {string}
end

local record tl
   enum LoadMode
      "b"
      "t"
      "bt"
      "cb"
      "ct"
      "cbt"
   end
   type LoadFunction = function(...:any): any...

   enum GenCompat
      "off"
      "optional"
      "required"
   end

   enum GenTarget
      "5.1"
      "5.3"
      "5.4"
   end

   enum Feat
      "on"
      "off"
   end

   record GenerateOptions
      preserve_indent: boolean
      preserve_newlines: boolean
      preserve_hashbang: boolean
   end

   record CheckOptions
      feat_lax: Feat
      feat_arity: Feat
      gen_compat: GenCompat
      gen_target: GenTarget
      run_internal_compiler_checks: boolean
      -- Annotates the syntax tree with the run-time checks a typed
      -- boundary asks for, which `generate` then writes (see
      -- `TypeChecker:runtime_kinds`).
      runtime_checks: boolean
   end

   record Env
      globals: {string:Variable}
      modules: {string:Type}
      module_filenames: {string:string}
      loaded: {string:Result}
      loaded_order: {string}
      reporter: TypeReporter
      keep_going: boolean
      report_types: boolean
      defaults: CheckOptions
   end

   record Result
      filename: string
      ast: Node
      type: Type
      syntax_errors: {Error}
      type_errors: {Error}
      gen_error: string
      warnings: {Error}
      env: Env
      dependencies: {string:string} -- module name, file found
   end

   enum WarningKind
      "unknown"
      "unused"
      "redeclaration"
      "branch"
      "hint"
      "debug"
      "unread"
   end
   warning_kinds: {WarningKind:boolean}

   -- What an error is, for a reader that must not parse `msg`. A code
   -- names the error kind, and the fields of `Error` named below it are
   -- set for it; `other` is every error no reader acts on.
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
      -- a local read where a path from its declaration has not assigned it:
      -- `variable`, `closure` where the read is a function literal that
      -- names it, and `skipped_kind`, `skipped_y`, `skipped_x` for the
      -- statement a path went by that skipped the assignment
      "not_assigned"
      -- a local declared with neither a type nor a value: `variable`
      "no_type"
      "other"
   end

   record Error
      y: integer
      x: integer
      msg: string
      filename: string

      tag: WarningKind

      -- For a key a record lacks: the record's value fields, unordered.
      fields: {string}

      code: ErrorCode

      -- Where a value was wanted, as the message names it: "argument",
      -- "return", "self", or "in local declaration", "in assignment" and
      -- the like. `context_name` is the variable or field the message
      -- also names there, and `index` the position of an argument.
      context: string
      context_name: string
      index: integer
      -- Whether words the message puts between its context and the
      -- error itself (a field that did not match, a type parameter)
      -- make the context something other than where the value was wanted.
      nested: boolean
      -- The type parameter a type was refused for.
      type_parameter: string
      -- The method of a record declared against an interface, and the
      -- record that declares it, when the error is that signature's.
      signature_of: string
      declared_in: string

      -- The kind of the record-like type a key was refused: its typename.
      resolved_kind: string

      -- The types an error is about, as the checker shows them. A
      -- `*_members` list holds the members of a union (a type that is
      -- none holds itself), each shown alone; `got_kind`, `subject_kind`
      -- and `expected_names` say what the type is (its typename; the names
      -- of a nominal type).
      got: string
      got_kind: string
      got_members: {string}
      expected: string
      expected_members: {string}
      expected_names: {string}
      subject: string
      subject_kind: string
      members: {string}
      left: string
      left_members: {string}
      left_is_generic_function: boolean
      right: string
      right_members: {string}

      -- The names the error mentions.
      key: string
      variable: string
      operator: string
      names: {string}
      type_arguments: {string}
      expected_tokens: {string}

      -- What a declaration that is hidden or unused declares: "variable",
      -- "argument", "function", "type" or "label".
      declares: string

      -- Whether the declaration a name hides is in the program itself.
      declared_before: boolean

      -- The callee of a call, as written (`Json.decode`, `obj:get`), and
      -- whether it never returns.
      callee: string
      callee_never: boolean

      -- A call's arguments: how many it was given, how many its callee
      -- takes when that is one number, and the largest number it names.
      given: integer
      expects: integer
      expects_most: integer
      -- Whether `msg` has had advice appended.
      advised: boolean

      -- For a refusal of a place whose narrowing was dropped: the place
      -- (`r.n`), what dropped it (`assignment`, `write`, `call`,
      -- `operator` or `loop`), that expression as written, and where it is.
      dropped_place: string
      dropped_kind: string
      dropped_by: string
      dropped_y: integer
      dropped_x: integer

      -- For a local read before it is assigned: whether the read is a
      -- function literal that names it, what may call that function before
      -- the assignment (`ran_kind`: `call`, `operator`, `iterator`, `return`,
      -- `goto`, `never` or `scope`, at `ran_y`, `ran_x` unless it is the end of the
      -- scope), and the statement a path went by that skipped the
      -- assignment (`branch`, `if` or `loop`), and where.
      closure: boolean
      ran_kind: string
      ran_y: integer
      ran_x: integer
      skipped_kind: string
      skipped_y: integer
      skipped_x: integer

      -- used temporarily for stable-sorting
      i: integer
   end

   type errors = Errors

   typecodes: {string:integer}

   record TypeInfo
      t: integer

      str: string
      file: string
      x: integer
      y: integer
      ref: integer -- NOMINAL
      typeargs: {{string, integer}} -- FUNCTION, RECORD (optional)
      fields: {string: integer} -- RECORD
      meta_fields: {string: integer} -- RECORD (optional)
      enums: {string} -- ENUM
      args: {{integer, string}} -- FUNCTION
      rets: {{integer, string}} -- FUNCTION
      vararg: boolean -- FUNCTION
      varret: boolean -- FUNCTION
      types: {integer} -- UNION, POLY, TUPLE
      keys: integer -- MAP
      values: integer -- MAP
      elements: integer -- ARRAY
   end

   record TypeReport
      type Symbol = {integer, integer, string, integer}

      by_pos: {string: {integer: {integer: integer}}}
      types: {integer: TypeInfo}
      symbols: {Symbol}
      symbols_by_file: {string: {Symbol}}
      globals: {string: integer}
   end

   record EnvOptions
      defaults: CheckOptions
      predefined_modules: {string}
   end

   -- abstract type
   interface Node
   end

   enum TokenKind
      "hashbang"
      "keyword"
      "op"
      "string"
      "[" "]" "(" ")" "{" "}" "," ":" "." ";" "?"
      "::"
      "..."
      "identifier"
      "number"
      "integer"
      "pragma"
      "pragma_identifier"
      "$ERR$"
      "$EOF$"
   end

   record Comment
      x: integer
      y: integer
      text: string
   end

   record Token
      x: integer
      y: integer
      tk: string
      kind: TokenKind
      comments: {Comment}
   end

   -----------------------------------------------------------------------------
   -- Public API
   -----------------------------------------------------------------------------

   check: function(Node, ? string, ? CheckOptions, ? Env): Result, string
   gen: function(string, ? Env, ? GenerateOptions): string, Result
   generate: function(ast: Node, gen_target: GenTarget, opts?: GenerateOptions): string, string
   get_token_at: function(tks: {Token}, y: integer, x: integer): string
   lex: function(input: string, filename: string): {Token}, {Error}
   load: function(string, ? string, ? LoadMode, ...: {any:any}): LoadFunction, string
   loader: function()
   new_env: function(? EnvOptions): Env, string
   parse: function(input: string, filename: string, parse_lang?: ParseLang): Node, {Error}, {string}
   parse_program: function(tokens: {Token}, errs: {Error}, filename?: string, parse_lang?: ParseLang): Node, {string}
   check_file: function(filename: string, env?: Env, fd?: FILE): (Result, string)
   check_string: function(input: string, env?: Env, filename?: string, parse_lang?: ParseLang): Result
   search_module: function(module_name: string, search_all: boolean): string, FILE, {string}
   symbols_in_scope: function(tr: TypeReport, y: integer, x: integer, filename: string): {string:integer}
   target_from_lua_version: function(str: string): GenTarget
   version: function(): string

   path: string -- if set be the user, this overrides package.path for Teal

   -----------------------------------------------------------------------------
   -- Deprecated, mantained for backwards compatibility:
   -----------------------------------------------------------------------------

   type CompatMode = GenCompat
   type PrettyPrintOptions = GenerateOptions
   type TargetMode = GenTarget

   record TypeCheckOptions
      lax: boolean
      filename: string
      module_name: string
      gen_compat: tl.CompatMode
      gen_target: tl.TargetMode
      env: Env
      run_internal_compiler_checks: boolean
   end

   init_env: function(? boolean, ? boolean | tl.CompatMode, ? tl.TargetMode, ? {string}): Env, string
   pretty_print_ast: function(ast: Node, gen_target?: tl.TargetMode, mode?: boolean | tl.PrettyPrintOptions): string, string
   process: function(filename: string, env?: Env, fd?: FILE): Result, string
   process_string: function(input: string, is_lua: boolean, env: Env, filename: string, _module_name: string): Result
   type_check: function(Node, TypeCheckOptions): Result, string

   -----------------------------------------------------------------------------
   -- Private data:
   -----------------------------------------------------------------------------

   package_loader_env: Env
   load_envs: { {any:any} : Env }
end

local record TypeReporter
   typeid_to_num: {integer: integer}
   typename_to_num: {TypeName: integer}
   next_num: integer
   tr: TypeReport

   get_typenum: function(self, Type): integer
end

local wk <total>: {tl.WarningKind:boolean} = {
   ["unknown"] = true,
   ["unused"] = true,
   ["redeclaration"] = true,
   ["branch"] = true,
   ["hint"] = true,
   ["debug"] = true,
   ["unread"] = true,
}
tl.warning_kinds = wk

-- Implementation rationale:
-- * bit 31: (MSB) special ("any", "unknown", "invalid")
--   * "any" satisfies all Lua masks
-- * bits 30-27: if valid: other Teal types ("nominal", "poly", "union", "typevar")
-- * bits 24-26: reserved
-- * bits 20-23: abstract types ("interface")
-- * bits 16-19: if valid: Teal types ("array", "record", "map", "tuple", "enum") that map to a Lua type ("table", "string")
-- * bit 15: if not valid: value is unknown
-- * bits 8-14: reserved
-- * bits 0-7: (LSB) Lua types, one bit for each ("nil", "number", "boolean", "string", table, "function", "userdata", "thread")
--   * every valid value has a Lua type bit set
tl.typecodes = {
   -- Lua types
   NIL                    = 0x00000001,
   NUMBER                 = 0x00000002,
   BOOLEAN                = 0x00000004,
   STRING                 = 0x00000008,
   TABLE                  = 0x00000010,
   FUNCTION               = 0x00000020,
   USERDATA               = 0x00000040,
   THREAD                 = 0x00000080,
   -- Teal types
   INTEGER                = 0x00010002,
   ENUM                   = 0x00010004,
   EMPTY_TABLE            = 0x00000008,
   ARRAY                  = 0x00010008,
   RECORD                 = 0x00020008,
   MAP                    = 0x00040008,
   TUPLE                  = 0x00080008,
   INTERFACE              = 0x00100008,
   SELF                   = 0x00200008,
   POLY                   = 0x20000020,
   UNION                  = 0x40000000,
   -- Indirect types
   NOMINAL                = 0x10000000,
   TYPE_VARIABLE          = 0x08000000,
   -- Special types
   ANY                    = 0xffffffff,
   UNKNOWN                = 0x80008000,
   INVALID                = 0x80000000,
}

local type Env = tl.Env
local type EnvOptions = tl.EnvOptions
local type Error = tl.Error
local type Feat = tl.Feat
local type GenCompat = tl.GenCompat
local type GenTarget = tl.GenTarget
local type LoadFunction = tl.LoadFunction
local type LoadMode = tl.LoadMode
local type GenerateOptions = tl.GenerateOptions
local type Result = tl.Result
local type CheckOptions = tl.CheckOptions
local type Token = tl.Token
local type TokenKind = tl.TokenKind
local type Comment = tl.Comment
local type TypeInfo = tl.TypeInfo
local type TypeReport = tl.TypeReport
local type WarningKind = tl.WarningKind

local DEFAULT_GEN_COMPAT <const>: GenCompat = "optional"
local DEFAULT_GEN_TARGET <const>: GenTarget = "5.3"

local enum Specialization
   "narrow"
   "narrowed_declaration"
   "localizing"
   "widen"
end

local record Variable
   t: Type
   attribute: Attribute
   needs_compat: boolean
   specialized_from: Type
   -- On a "widen" entry that a test or an assignment narrowed in the scope
   -- that widened it: the type it was widened to, which widening it again
   -- puts back (`widen_in_scope`).
   widened_from: Type
   is_specialized: Specialization
   declared_at: Node
   is_func_arg: boolean
   used_as_type: boolean
   aliasing: Variable
   implemented: {string:boolean}
   has_been_read_from: boolean
   has_been_written_to: boolean
   is_loop_control: boolean
   -- Whether no function literal assigns this local, so that a call
   -- leaves what is known of it; nil until a call asks.
   stable: boolean
end

-- Where the pre-pass (`TypeChecker:find_closure_assigned`) met a function
-- literal or an assignment to a local: how many statements, function
-- literals and assignments came before it in the text, and the loops around
-- it, outermost first.
local record Mark
   order: integer
   loops: {integer}
end

--------------------------------------------------------------------------------
-- Compiler debugging
--------------------------------------------------------------------------------

local TL_DEBUG = os.getenv("TL_DEBUG")
local TL_DEBUG_FACTS = os.getenv("TL_DEBUG_FACTS")
local TL_DEBUG_MAXLINE = math.maxinteger

if TL_DEBUG_FACTS and not TL_DEBUG then
   TL_DEBUG="1"
end

if TL_DEBUG then
   local max <const> = assert(tonumber(TL_DEBUG), "TL_DEBUG was defined, but not a number")
   if max < 0 then
      TL_DEBUG_MAXLINE = math.tointeger(-max)
   elseif max > 1 then
      local count = 0
      local skip: string = nil
      debug.sethook(function(event: debug.HookEvent)
         if event == "call" or event == "tail call" or event == "return" then
            local info <const> = debug.getinfo(2)

            if skip then
               if info.name == skip and event == "return" then
                  skip = nil
               end
               return
            elseif (info.name or "?"):match("^tl_debug_") and event == "call" then
               skip = info.name
               return
            end

            local name = info.name or "<anon>", info.currentline > 0 and "@" .. info.currentline or ""
            io.stderr:write(name, " :: ", event as string, "\n")
            io.stderr:flush()
         else
            count = count + 100
            if count > max then
               error("Too many instructions")
            end
         end
      end, "cr", 100)
   end
end

--------------------------------------------------------------------------------
-- Lexer
--------------------------------------------------------------------------------

do
   local enum LexState
      "start"
      "any"
      "identifier"
      "got -"
      "got --"
      "got ."
      "got .."
      "got ="
      "got ~"
      "got ["
      "got 0"
      "got <"
      "got >"
      "got /"
      "got :"
      "got --["
      "string single"
      "string single got \\"
      "string double"
      "string double got \\"
      "string long"
      "string long got ]"
      "comment short"
      "comment long"
      "comment long got ]"
      "number dec"
      "number decfloat"
      "number hex"
      "number hexfloat"
      "number power"
      "number powersign"
      "pragma"
      "pragma word"
      "pragma any"
   end

   local last_token_kind <total>: {LexState:TokenKind} = {
      ["start"] = nil, -- never in a token
      ["any"] = nil, -- never in a token
      ["identifier"] = "identifier",
      ["got -"] = "op",
      ["got --"] = nil, -- drop comment
      ["got ."] = ".",
      ["got .."] = "op",
      ["got ="] = "op",
      ["got ~"] = "op",
      ["got ["] = "[",
      ["got 0"] = "number",
      ["got <"] = "op",
      ["got >"] = "op",
      ["got /"] = "op",
      ["got :"] = "op",
      ["got --["] = nil, -- drop comment
      ["string single"] = "$ERR$",
      ["string single got \\"] = "$ERR$",
      ["string double"] = "$ERR$",
      ["string double got \\"] = "$ERR$",
      ["string long"] = "$ERR$",
      ["string long got ]"] = "$ERR$",
      ["comment short"] = nil, -- drop comment
      ["comment long"] = "$ERR$",
      ["comment long got ]"] = "$ERR$",
      ["number dec"] = "integer",
      ["number decfloat"] = "number",
      ["number hex"] = "integer",
      ["number hexfloat"] = "number",
      ["number power"] = "number",
      ["number powersign"] = "$ERR$",
      ["pragma"] = nil, -- drop comment
      ["pragma any"] = nil, -- never in a token
      ["pragma word"] = "pragma_identifier", -- never in a token
   }

   local keywords: {string:boolean} = {
      ["and"] = true,
      ["break"] = true,
      ["do"] = true,
      ["else"] = true,
      ["elseif"] = true,
      ["end"] = true,
      ["false"] = true,
      ["for"] = true,
      ["function"] = true,
      ["goto"] = true,
      ["if"] = true,
      ["in"] = true,
      ["local"] = true,
      ["nil"] = true,
      ["not"] = true,
      ["or"] = true,
      ["repeat"] = true,
      ["return"] = true,
      ["then"] = true,
      ["true"] = true,
      ["until"] = true,
      ["while"] = true,
   }

   local lex_any_char_states: {string:LexState} = {
      ["\""] = "string double",
      ["'"] = "string single",
      ["-"] = "got -",
      ["."] = "got .",
      ["0"] = "got 0",
      ["<"] = "got <",
      [">"] = "got >",
      ["/"] = "got /",
      [":"] = "got :",
      ["="] = "got =",
      ["~"] = "got ~",
      ["["] = "got [",
   }

   for c = string.byte("a"), string.byte("z") do
      lex_any_char_states[string.char(c)] = "identifier"
   end
   for c = string.byte("A"), string.byte("Z") do
      lex_any_char_states[string.char(c)] = "identifier"
   end
   lex_any_char_states["_"] = "identifier"

   for c = string.byte("1"), string.byte("9") do
      lex_any_char_states[string.char(c)] = "number dec"
   end

   local lex_word: {string:boolean} = {}
   for c = string.byte("a"), string.byte("z") do
      lex_word[string.char(c)] = true
   end
   for c = string.byte("A"), string.byte("Z") do
      lex_word[string.char(c)] = true
   end
   for c = string.byte("0"), string.byte("9") do
      lex_word[string.char(c)] = true
   end
   lex_word["_"] = true

   local lex_decimals: {string:boolean} = {}
   for c = string.byte("0"), string.byte("9") do
      lex_decimals[string.char(c)] = true
   end

   local lex_hexadecimals: {string:boolean} = {}
   for c = string.byte("0"), string.byte("9") do
      lex_hexadecimals[string.char(c)] = true
   end
   for c = string.byte("a"), string.byte("f") do
      lex_hexadecimals[string.char(c)] = true
   end
   for c = string.byte("A"), string.byte("F") do
      lex_hexadecimals[string.char(c)] = true
   end

   local lex_any_char_kinds: {string:TokenKind} = {}
   local single_char_kinds: {TokenKind} = {"[", "]", "(", ")", "{", "}", ",", ";", "?"}
   for _, c in ipairs(single_char_kinds) do
      lex_any_char_kinds[c] = c
   end
   for _, c in ipairs({"#", "+", "*", "|", "&", "%", "^"}) do
      lex_any_char_kinds[c] = "op"
   end

   local lex_space: {string:boolean} = {}
   for _, c in ipairs({" ", "\t", "\v", "\n", "\r"}) do
      lex_space[c] = true
   end

   local escapable_characters: {string:boolean} = {
      a = true,
      b = true,
      f = true,
      n = true,
      r = true,
      t = true,
      v = true,
      z = true,
      ["\\"] = true,
      ["\'"] = true,
      ["\""] = true,
      ["\r"] = true,
      ["\n"] = true,
   }

   local function lex_string_escape(input: string, i: integer, c: string): integer, boolean
      if escapable_characters[c] then
         return 0, true
      elseif c == "x" then
         return 2, (
            lex_hexadecimals[input:sub(i+1, i+1)] and
            lex_hexadecimals[input:sub(i+2, i+2)]
         )
      elseif c == "u" then
         if input:sub(i+1, i+1) == "{" then
            local p = i + 2
            if not lex_hexadecimals[input:sub(p, p)] then
               return 2, false
            end
            while true do
               p = p + 1
               c = input:sub(p, p)
               if not lex_hexadecimals[c] then
                  return p - i, c == "}"
               end
            end
         end
      elseif lex_decimals[c] then
         local len = lex_decimals[input:sub(i+1, i+1)]
                     and (lex_decimals[input:sub(i+2, i+2)] and 2 or 1)
                     or  0
         return len, tonumber(input:sub(i, i + len)) < 256
      else
         return 0, false
      end
   end

   local function lex_separators_between_digits(tk: string): boolean
      local digits = tk:match("^0[xX]") and lex_hexadecimals or lex_decimals
      local p = tk:find("_", 1, true)
      while p do
         if not (digits[tk:sub(p - 1, p - 1)] and digits[tk:sub(p + 1, p + 1)]) then
            return false
         end
         p = tk:find("_", p + 1, true)
      end
      return true
   end

   tl.lex = function(input: string, filename: string): {Token}, {Error}
      local tokens: {Token} = {}

      local state: LexState = "any"
      local fwd = true
      local y = 1
      local x = 0
      local i = 0
      local lc_open_lvl = 0
      local lc_close_lvl = 0
      local ls_open_lvl = 0
      local ls_close_lvl = 0
      local errs: {Error} = {}
      local nt = 0

      local tx: integer = nil
      local ty: integer = nil
      local ti: integer = nil
      local in_token = false

      local comments: {Comment} = nil

      local function begin_token()
         tx = x
         ty = y
         ti = i
         in_token = true
      end

      local function end_token(kind: TokenKind, tk: string)
         nt = nt + 1
         tokens[nt] = {
            x = tx,
            y = ty,
            tk = tk,
            kind = kind,
            comments = comments,
         }
         comments = nil
         in_token = false
      end

      local function end_token_identifier()
         local tk = input:sub(ti, i - 1)
         nt = nt + 1
         tokens[nt] = {
            x = tx,
            y = ty,
            tk = tk,
            kind = keywords[tk] and "keyword" or "identifier",
            comments = comments,
         }
         comments = nil
         in_token = false
      end

      local function end_token_prev(kind: TokenKind)
         local tk = input:sub(ti, i - 1)
         nt = nt + 1
         tokens[nt] = {
            x = tx,
            y = ty,
            tk = tk,
            kind = kind,
            comments = comments,
         }
         comments = nil
         in_token = false
         if (kind == "integer" or kind == "number") and not lex_separators_between_digits(tk) then
            table.insert(errs, {
               filename = filename,
               y = ty,
               x = tx,
               code = "other",
               msg = "malformed number '" .. tk .. "': a '_' in a number goes between two digits",
            })
         end
      end

      local function end_token_here(kind: TokenKind)
         local tk = input:sub(ti, i)
         nt = nt + 1
         tokens[nt] = {
            x = tx,
            y = ty,
            tk = tk,
            kind = kind,
            comments = comments,

         }
         comments = nil
         in_token = false
      end

      local function drop_token()
         in_token = false
      end

      local function add_syntax_error(msg?: string)
         local t = tokens[nt]
         table.insert(errs, {
            filename = filename,
            y = t.y,
            x = t.x,
            code = "other",
            msg = msg or "invalid token '" .. t.tk .. "'",
         })
      end

      local function add_comment(text: string)
         if not comments then
            comments = {}
         end
         comments[#comments + 1] = {
            x = tx,
            y = ty,
            text = text,
         }
      end

      local len = #input
      if input:sub(1,2) == "#!" then
         begin_token()
         i = input:find("\n")
         if not i then
            i = len + 1
         end
         end_token_prev("hashbang")
         y = 2
         x = 0
      end
      state = "any"

      while i <= len do
         if fwd then
            i = i + 1
            if i > len then
               break
            end
         end

         local c: string = input:sub(i, i)

         if fwd then
            if c == "\n" then
               y = y + 1
               x = 0
            else
               x = x + 1
            end
         else
            fwd = true
         end

         if state == "any" then
            local st = lex_any_char_states[c]
            if st then
               state = st
               begin_token()
            else
               local k = lex_any_char_kinds[c]
               if k then
                  begin_token()
                  end_token(k, c)
               elseif not lex_space[c] then
                  begin_token()
                  end_token_here("$ERR$")
                  add_syntax_error()
               end
            end
         elseif state == "identifier" then
            if not lex_word[c] then
               end_token_identifier()
               fwd = false
               state = "any"
            end
         elseif state == "string double" then
            if c == "\\" then
               state = "string double got \\"
            elseif c == "\"" then
               end_token_here("string")
               state = "any"
            end
         elseif state == "comment short" then
            if c == "\n" then
               add_comment(input:sub(ti, i - 1))
               state = "any"
            end
         elseif state == "got =" then
            local t: string
            if c == "=" then
               t = "=="
            else
               t = "="
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "got ." then
            if c == "." then
               state = "got .."
            elseif lex_decimals[c] then
               state = "number decfloat"
            else
               end_token(".", ".")
               fwd = false
               state = "any"
            end
         elseif state == "got :" then
            local t: TokenKind
            if c == ":" then
               t = "::"
            else
               t = ":"
               fwd = false
            end
            end_token(t, t)
            state = "any"
         elseif state == "got [" then
            if c == "[" then
               state = "string long"
            elseif c == "=" then
               ls_open_lvl = ls_open_lvl + 1
            else
               end_token("[", "[")
               fwd = false
               state = "any"
               ls_open_lvl = 0
            end
         elseif state == "number dec" then
            if lex_decimals[c] or c == "_" then
               -- proceed
            elseif c == "." then
               state = "number decfloat"
            elseif c == "e" or c == "E" then
               state = "number powersign"
            else
               end_token_prev("integer")
               fwd = false
               state = "any"
            end
         elseif state == "got -" then
            if c == "-" then
               state = "got --"
            else
               end_token("op", "-")
               fwd = false
               state = "any"
            end
         elseif state == "got .." then
            if c == "." then
               end_token("...", "...")
            else
               end_token("op", "..")
               fwd = false
            end
            state = "any"
         elseif state == "number hex" then
            if lex_hexadecimals[c] or c == "_" then
               -- proceed
            elseif c == "." then
               state = "number hexfloat"
            elseif c == "p" or c == "P" then
               state = "number powersign"
            else
               end_token_prev("integer")
               fwd = false
               state = "any"
            end
         elseif state == "got --" then
            if c == "[" then
               state = "got --["
            elseif c == "#" then
               state = "pragma"
            else
               fwd = false
               state = "comment short"
               drop_token()
            end
         elseif state == "pragma" then
            if not lex_word[c] then
               end_token_prev("pragma")
               if tokens[nt].tk == "--#pragma" then
                  state = "pragma any"
               else
                  state = "comment short"
                  comments = tokens[nt].comments
                  table.remove(tokens)
                  nt = nt - 1
                  drop_token()
               end
               fwd = false
            end
         elseif state == "pragma any" then
            if c == "\n" then
               state = "any"
            elseif lex_word[c] then
               state = "pragma word"
               begin_token()
            elseif not lex_space[c] then
               begin_token()
               end_token_here("$ERR$")
               add_syntax_error()
            end
         elseif state == "pragma word" then
            if not lex_word[c] then
               end_token_prev("pragma_identifier")
               fwd = false
               state = (c == "\n") and "any" or "pragma any"
            end
         elseif state == "got 0" then
            if c == "x" or c == "X" then
               state = "number hex"
            elseif c == "e" or c == "E" then
               state = "number powersign"
            elseif lex_decimals[c] or c == "_" then
               state = "number dec"
            elseif c == "." then
               state = "number decfloat"
            else
               end_token_prev("integer")
               fwd = false
               state = "any"
            end
         elseif state == "got --[" then
            if c == "[" then
               state = "comment long"
            elseif c == "=" then
               lc_open_lvl = lc_open_lvl + 1
            else
               fwd = false
               state = "comment short"
               drop_token()
               lc_open_lvl = 0
            end
         elseif state == "comment long" then
            if c == "]" then
               state = "comment long got ]"
            end
         elseif state == "comment long got ]" then
            if c == "]" and lc_close_lvl == lc_open_lvl then
               add_comment(input:sub(ti, i))
               drop_token()
               state = "any"
               lc_open_lvl = 0
               lc_close_lvl = 0
            elseif c == "=" then
               lc_close_lvl = lc_close_lvl + 1
            else
               state = "comment long"
               lc_close_lvl = 0
            end
         elseif state == "string double got \\" then
            local skip, valid = lex_string_escape(input, i, c)
            i = i + skip
            if not valid then
               end_token_here("$ERR$")
               add_syntax_error("malformed string")
            end
            x = x + skip
            state = "string double"
         elseif state == "string single" then
            if c == "\\" then
               state = "string single got \\"
            elseif c == "'" then
               end_token_here("string")
               state = "any"
            end
         elseif state == "string single got \\" then
            local skip, valid = lex_string_escape(input, i, c)
            i = i + skip
            if not valid then
               end_token_here("$ERR$")
               add_syntax_error("malformed string")
            end
            x = x + skip
            state = "string single"
         elseif state == "got ~" then
            local t: string
            if c == "=" then
               t = "~="
            else
               t = "~"
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "got <" then
            local t: string
            if c == "=" then
               t = "<="
            elseif c == "<" then
               t = "<<"
            else
               t = "<"
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "got >" then
            local t: string
            if c == "=" then
               t = ">="
            elseif c == ">" then
               t = ">>"
            else
               t = ">"
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "got /" then
            local t: string
            if c == "/" then
               t = "//"
            else
               t = "/"
               fwd = false
            end
            end_token("op", t)
            state = "any"
         elseif state == "string long" then
            if c == "]" then
               state = "string long got ]"
            end
         elseif state == "string long got ]" then
            if c == "]" then
               if ls_close_lvl == ls_open_lvl then
                  end_token_here("string")
                  state = "any"
                  ls_open_lvl = 0
                  ls_close_lvl = 0
               end
            elseif c == "=" then
               ls_close_lvl = ls_close_lvl + 1
            else
               state = "string long"
               ls_close_lvl = 0
            end
         elseif state == "number hexfloat" then
            if c == "p" or c == "P" then
               state = "number powersign"
            elseif not lex_hexadecimals[c] and c ~= "_" then
               end_token_prev("number")
               fwd = false
               state = "any"
            end
         elseif state == "number decfloat" then
            if c == "e" or c == "E" then
               state = "number powersign"
            elseif not lex_decimals[c] and c ~= "_" then
               end_token_prev("number")
               fwd = false
               state = "any"
            end
         elseif state == "number powersign" then
            if c == "-" or c == "+" then
               state = "number power"
            elseif lex_decimals[c] or c == "_" then
               state = "number power"
            else
               end_token_here("$ERR$")
               add_syntax_error("malformed number")
               state = "any"
            end
         elseif state == "number power" then
            if not lex_decimals[c] and c ~= "_" then
               end_token_prev("number")
               fwd = false
               state = "any"
            end
         end
      end

      if in_token then
         if last_token_kind[state] then
            end_token_prev(last_token_kind[state])
            if last_token_kind[state] == "$ERR$" then
               local state_type = state:sub(1, 6)
               if state_type == "string" then
                  add_syntax_error("malformed string")
               elseif state_type == "number" then
                  add_syntax_error("malformed number")
               elseif state_type == "commen" then
                  add_syntax_error("unfinished long comment")
               else
                  add_syntax_error()
               end
            elseif keywords[tokens[nt].tk] then
               tokens[nt].kind = "keyword"
            end
         else
            drop_token()
         end
      end

      -- Input that ran out inside a `--#` run ends it here, exactly as
      -- a newline would have. The run is a pragma when it spells
      -- `--#pragma` and an ordinary short comment when it spells
      -- anything else -- the same test the newline path makes on the
      -- token it builds, made here on the bytes that token is cut
      -- from. Leaving the state at `comment short` hands the bytes to
      -- the next guard, which is where every short comment ends.
      if state == "pragma" then
         if input:sub(ti, i - 1) == "--#pragma" then
            end_token_prev("pragma")
            state = "pragma any"
         else
            state = "comment short"
         end
      end

      -- Input that ran out inside a short comment ends it here, exactly
      -- as the newline would have. `got --` and `got --[` are the same
      -- comment one and two characters in, which is how they are read
      -- when a newline follows them instead of the end of the input.
      if state == "comment short" or state == "got --" or state == "got --[" then
         add_comment(input:sub(ti, i - 1))
      end

      table.insert(tokens, { x = x + 1, y = y, i = i, tk = "$EOF$", kind = "$EOF$", comments = comments })

      return tokens, errs
   end
end

local function binary_search<T, U>(list: {T}, item: U, cmp: function(T, U): boolean): integer, T
   local len <const> = #list
   local mid: integer
   local s, e = 1, len
   while s <= e do
      mid = (s + e) // 2
      local val <const> = list[mid]
      local res <const> = cmp(val, item)
      if res then
         if mid == len then
            return mid, val
         else
            if not cmp(list[mid + 1], item) then
               return mid, val
            end
         end
         s = mid + 1
      else
         e = mid - 1
      end
   end
end

tl.get_token_at = function(tks: {Token}, y: integer, x: integer): string
   local _, found <const> = binary_search(
      tks, nil,
      function(tk: Token): boolean
         return tk.y < y
            or (tk.y == y and tk.x <= x)
      end
   )

   if found
      and found.y == y
      and found.x <= x and x < found.x + #found.tk
   then
      return found.tk
   end
end

--------------------------------------------------------------------------------
-- Recursive descent parser
--------------------------------------------------------------------------------

local last_typeid = 0

local function new_typeid(): integer
   last_typeid = last_typeid + 1
   return last_typeid
end

local enum TypeName
   "generic"
   "typedecl"
   "typevar"
   "typearg"
   "function"
   "array"
   "map"
   "tupletable"
   "record"
   "interface"
   "self"
   "enum"
   "boolean"
   "string"
   "nil"
   "thread"
   "userdata"
   "number"
   "integer"
   "union"
   "nominal"
   "emptytable"
   "literal_table_item"
   "unresolved_emptytable_value"
   "unresolved_typearg"
   "unresolvable_typearg"
   "circular_require"
   "boolean_context"
   "tuple"
   "poly"
   "any"
   "unknown"
   "invalid"
   "none"
   "*"
end

local table_types <total>: {TypeName:boolean} = {
   ["array"] = true,
   ["map"] = true,
   ["record"] = true,
   ["interface"] = true,
   ["self"] = true,
   ["emptytable"] = true,
   ["tupletable"] = true,

   ["generic"] = false,
   ["typedecl"] = false,
   ["typevar"] = false,
   ["typearg"] = false,
   ["function"] = false,
   ["enum"] = false,
   ["boolean"] = false,
   ["string"] = false,
   ["nil"] = false,
   ["thread"] = false,
   ["userdata"] = false,
   ["number"] = false,
   ["integer"] = false,
   ["union"] = false,
   ["nominal"] = false,
   ["literal_table_item"] = false,
   ["unresolved_emptytable_value"] = false,
   ["unresolved_typearg"] = false,
   ["unresolvable_typearg"] = false,
   ["circular_require"] = false,
   ["boolean_context"] = false,
   ["tuple"] = false,
   ["poly"] = false,
   ["any"] = false,
   ["unknown"] = false,
   ["invalid"] = false,
   ["none"] = false,
   ["*"] = false,
}

local enum SpecialFunctionName
   "assert"
   "coroutine.wrap"
   "error"
   "type"
   "ipairs"
   "pairs"
   "pcall"
   "xpcall"
   "rawget"
   "require"
   "setmetatable"
   "string.find"
   "string.format"
   "string.gmatch"
   "string.gsub"
   "string.match"
   "string.pack"
   "string.unpack"
end

local interface Type
   is Where
   where self.typename

   typename: TypeName    -- discriminator
   typeid: integer       -- unique identifier
   inferred_at: Where    -- for error messages
   needs_compat: boolean -- for Lua compatibilty
end

local record GenericType
   is Type
   where self.typename == "generic"

   typeargs: {TypeArgType}
   t: FirstOrderType
   fresh: boolean
end

local interface FirstOrderType
   is Type
end

local type FirstClassType = GenericType | FirstOrderType

local interface StructuralType
   is FirstOrderType
end

local record StringType
   is StructuralType
   where self.typename == "string"

   literal: string
end

local function is_numeric_type(t:Type): boolean
   return t.typename == "number" or t.typename == "integer"
end

local interface NumericType
   is StructuralType
   where is_numeric_type(self)
end

local record IntegerType
   is NumericType
   where self.typename == "integer"
end

local record BooleanType
   is StructuralType
   where self.typename == "boolean"
end

-- This is a special internal type, to be used only as the node.expected
-- type in boolean contexts such as `if _ then`. It behaves exactly like
-- boolean except that type variables do not infer to it.
local record BooleanContextType
   is StructuralType
   where self.typename == "boolean_context"
end

local record TypeDeclType
   is Type
   where self.typename == "typedecl"

   def: FirstClassType
   closed: boolean
   is_alias: boolean
   is_nested_alias: boolean
end

local record LiteralTableItemType
   is Type
   where self.typename == "literal_table_item"

   -- table items
   kname: string
   ktype: FirstClassType
   vtype: FirstClassType
end

local record Scope
   vars: {string:Variable}
   labels: {string:Node}
   pending_labels: {string:{Node}}
   pending_nominals: {string:{NominalType}}
   pending_global_types: {string:boolean}
   narrows: {string:boolean}
   widens: {string:boolean}
   -- The narrowed places a drop removed from this scope, with what did.
   dropped: {string:narrowing.Drop}
   -- The facts of the scopes outside a function literal that its body does
   -- not see, put back when it ends (`narrowing.enter_function`).
   hidden: {narrowing.Hidden}
   is_transaction: boolean
end

local interface HasDeclName
   declname: string
end

local record NominalType
   is FirstOrderType
   where self.typename == "nominal"

   names: {string}
   typevals: {FirstClassType}
   found: TypeDeclType      -- type is found but typeargs are not resolved
   resolved: Type       -- type is found and typeargs are resolved
end

local record SelfType
   is FirstOrderType
   where self.typename == "self"

   -- to be used only in error reports, not for type resolution
   display_type: RecordLikeType
end

local interface ArrayLikeType
   is StructuralType
   where self.elements

   elements: Type
   consttypes: {Type}
   inferred_len: integer
end

local record ArrayType
   is ArrayLikeType
   where self.typename == "array"
end

local interface RecordLikeType
   is StructuralType, HasDeclName, ArrayLikeType
   where self.fields

   interface_list: {ArrayType | NominalType}
   interfaces_expanded: boolean
   fields: {string: Type}
   field_order: {string}
   field_comments: {string: {{Comment}}}
   meta_fields: {string: Type}
   meta_field_order: {string}
   meta_field_comments: {string: {{Comment}}}
   is_userdata: boolean
end

local record RecordType
   is RecordLikeType
   where self.typename == "record"
end

local record InterfaceType
   is RecordLikeType
   where self.typename == "interface"
end

-- producing a new value of this type (not propagating)
-- must always produce a type error
local record InvalidType
   is Type
   where self.typename == "invalid"
end

-- To be used in lax mode only:
-- this represents non-annotated types in .lua files.
local record UnknownType
   is Type
   where self.typename == "unknown"
end

local record TupleType
   is FirstOrderType
   where self.typename == "tuple"

   is_va: boolean
   tuple: {Type}
end

local interface TypeArgType
   is Type
   where self.typename == "typearg"

   typearg: string
   constraint: Type
end

local record UnresolvedTypeArgType
   is TypeArgType
   where self.typename == "unresolved_typearg"
end

local record UnresolvableTypeArgType
   is Type
   where self.typename == "unresolvable_typearg"

   typearg: string
end

local record TypeVarType
   is FirstOrderType
   where self.typename == "typevar"

   typevar: string
   constraint: Type
end

local record MapType
   is StructuralType
   where self.typename == "map"

   keys: Type
   values: Type
end

local record NilType
   is StructuralType
   where self.typename == "nil"
end

local record EmptyTableType
   is Type
   where self.typename == "emptytable"

   declared_at: Node
   assigned_to: string
   keys: Type
end

local record UnresolvedEmptyTableValueType
   is Type
   where self.typename == "unresolved_emptytable_value"

   emptytable_type: EmptyTableType
end

local record FunctionType
   is StructuralType
   where self.typename == "function"

   is_method: boolean
   maybe_method: boolean
   is_record_function: boolean
   min_arity: integer
   args: TupleType
   rets: TupleType
   macroexp: Node
   special_function_handler: SpecialFunctionName -- special handling for format strings etc
   -- A function of the standard library that runs no code of the program's
   -- (see `TypeChecker:runs_no_code`) unless an argument it examines may
   -- dispatch to a metamethod: the arguments it examines are all of them
   -- ("all"), the first only ("first") or none ("none").
   pure_std: string
   never: boolean -- declared `: never`: a call does not return, and `rets` is empty
end

local interface AggregateType
   is StructuralType
   where self.types

   types: {Type}
end

local record UnionType
   is AggregateType
   where self.typename == "union"
end

local record TupleTableType
   is AggregateType
   where self.typename == "tupletable"
end

-- Intersection types, currently restricted to polymorphic functions
-- defined inside records, representing polymorphic Lua APIs.
local record PolyType
   is AggregateType
   where self.typename == "poly"

   types: {FunctionType | GenericType} -- order should match the order of declarations in the record or interface.
end

local record EnumType
   is StructuralType, HasDeclName
   where self.typename == "enum"

   enumset: {string:boolean}
   value_comments: {string:{Comment}}
end

local record Operator
   y: integer
   x: integer
   arity: integer
   op: string
   prec: integer
end

local enum NodeKind
   "op"
   "nil"
   "string"
   "number"
   "integer"
   "boolean"
   "literal_table"
   "literal_table_item"
   "function"
   "expression_list"
   "if"
   "if_block"
   "while"
   "fornum"
   "forin"
   "goto"
   "label"
   "repeat"
   "do"
   "break"
   "return"
   "newtype"
   "argument"
   "type_identifier"
   "variable"
   "variable_list"
   "statements"
   "assignment"
   "argument_list"
   "local_function"
   "global_function"
   "local_type"
   "global_type"
   "record_function"
   "local_declaration"
   "global_declaration"
   "identifier"
   "cast"
   "..."
   "paren"
   "macroexp"
   "local_macroexp"
   "interface"
   "pragma"
   "error_node"
end

local enum KeyParsed
   "short"
   "long"
   "implicit"
end

local enum Attribute
   "const"
   "close"
   "total"
end

local attributes <total>: {Attribute: boolean} = {
   ["const"] = true,
   ["close"] = true,
   ["total"] = true,
}
local is_attribute <const>: {string:boolean} = attributes as {string:boolean}

local record Node
   is {Node}, tl.Node, Where
   where self.kind ~= nil

   record ExpectedContext
      kind: NodeKind
      name: string
   end

   tk: string
   kind: NodeKind
   comments: {Comment}
   symbol_list_slot: integer
   semicolon: boolean
   hashbang: string

   unattached_comments: {Comment}

   is_longstring: boolean

   yend: integer
   xend: integer

   guard: narrowing.Guard

   -- What dropped the narrowing a read of this place would have had.
   dropped: narrowing.Drop
   -- How many call-like expressions the checker had met when it finished
   -- this node, and, on an `if` block, when it began.
   drop_clock: integer
   -- Set by the node that compares clocks of its parts: stamp this one.
   want_clock: boolean
   clock_start: integer
   -- On an `if` block: where the journal of drops was when its body began.
   journal_mark: integer
   tick_mark: integer
   -- The typename of an index's key, for the write `t[k] = v`.
   key_kind: string
   -- On a call: whether it ran no code of the program's, so dropped nothing.
   runs_no_code: boolean
   -- On a call-like expression, a `for ... in` loop (its iterator) or a
   -- call: whether it may run code of the program's, so that a function
   -- made before it may be called by it (see `TypeChecker:drop_all`).
   runs_code: boolean
   -- On a read of a field of a local: the type it was read as, narrowed by
   -- what is known of the field then.
   field_type: Type
   -- On a local declaration: the variables it declares with no value, of a
   -- type that does not admit nil.
   unvalued: {Node}

   -- bidirectional inference
   expected: Type
   expected_context: Node.ExpectedContext

   key: Node
   value: Node
   key_parsed: KeyParsed

   typeargs: {TypeArgType}
   min_arity: integer
   args: Node
   rets: TupleType
   never: boolean
   body: Node
   implicit_global_function: boolean
   is_predeclared_local_function: boolean

   name: Node

   -- statements list in a `repeat`, delay closing scope
   is_repeat: boolean

   -- var declaration
   attribute: Attribute

   fn_owner: Node
   is_method: boolean

   exp: Node
   if_parent: Node
   if_block_n: integer
   if_blocks: {Node}
   if_widens: {string: boolean}
   type_of: Node
   rets_omitted: boolean
   context_type: Type
   context_rets: TupleType
   context_never: boolean
   binds_context: boolean

   -- fornum
   var: Node
   from: Node
   to: Node
   step: Node

   -- forin
   vars: Node
   exps: Node

   -- newtype
   newtype: TypeDeclType
   elide_type: boolean

   -- expressions
   op: Operator
   e1: Node
   e2: Node
   constnum: number
   conststr: string
   failstore: boolean
   discarded_tuple: boolean
   receiver: Type

   -- table literal
   array_len: integer
   is_total: boolean
   omissions_checked: boolean
   missing: {string}

   -- goto
   label: string

   -- label
   used_label: boolean

   casttype: Type

   -- variable
   is_lvalue: boolean

   -- macroexp
   macrodef: Node
   expanded: Node

   argtype: Type
   itemtype: Type
   decltuple: TupleType

   -- pragma
   pkey: string
   pvalue: string

   opt: boolean

   debug_type: Type

   -- run-time checks, set only when the environment asks for them
   -- (CheckOptions.runtime_checks): on an argument, "name=kinds"; on a
   -- return, the kinds of each value, joined by ";"; on the expression
   -- list of an assignment, the check of each value written to a record
   -- field; on the root, the file the checks name.
   rt_check: string
   rt_rets: string
   rt_set: {integer:string}
   rt_file: string
end

local show_type: function(Type, ? boolean, ? {Type:string}): string

local type_mt: metatable<Type> = {
   __tostring = function(t: Type): string
      return show_type(t)
   end
}

local function a_type<T is Type>(w: Where, typename: TypeName, t: T): T
   t.typeid = new_typeid()
   t.f = w.f
   t.x = w.x
   t.y = w.y
   t.typename = typename
   do
      local ty: Type = t
      setmetatable(ty, type_mt)
   end
   return t
end

local function edit_type(w: Where, t: Type, typename: TypeName): Type
   t.typeid = new_typeid()
   t.f = w.f
   t.x = w.x
   t.y = w.y
   t.typename = typename
   setmetatable(t, type_mt)
   return t
end

local macroexp a_typedecl(w: Where, def: Type): TypeDeclType
   return a_type(w, "typedecl", { def = def } as TypeDeclType)
end

local macroexp a_tuple(w: Where, t: {Type}): TupleType
   return a_type(w, "tuple", { tuple = t } as TupleType)
end

local macroexp a_union(w: Where, t: {Type}): UnionType
   return a_type(w, "union", { types = t } as UnionType)
end

local macroexp a_self(w: Where, display_type: Type): SelfType
   return a_type(w, "self", { display_type = display_type } as SelfType)
end

local function a_function(w: Where, t: FunctionType): FunctionType
   assert(t.min_arity)
   return a_type(w, "function", t)
end

local function a_vararg(w: Where, t: {Type}): TupleType
   local typ = a_tuple(w, t)
   typ.is_va = true
   return typ
end

local macroexp an_array(w: Where, t: Type): ArrayType
   return a_type(w, "array", { elements = t } as ArrayType)
end

local macroexp a_map(w: Where, k: Type, v: Type): MapType
   return a_type(w, "map", { keys = k, values = v } as MapType)
end

local macroexp a_nominal(w: Where, names: {string}): NominalType
   return a_type(w, "nominal", { names = names } as NominalType)
end

local macroexp an_invalid(w: Where): InvalidType
   return a_type(w, "invalid", {} as InvalidType)
end

local macroexp an_unknown(w: Where): UnknownType
   return a_type(w, "unknown", {} as UnknownType)
end

local an_operator: function(Node, integer, string): Operator

local function shallow_copy_new_type<T is Type>(t: T): T
   local copy: {any:any} = {}
   for k, v in pairs(t as {any:any}) do
      copy[k] = v
   end
   copy.typeid = new_typeid()
   do
      local ty: Type = copy as T
      setmetatable(ty, type_mt)
   end
   return copy as T
end

local function shallow_copy_table<T>(t: T): T
   local copy: {any:any} = {}
   for k, v in pairs(t as {any:any}) do
      copy[k] = v
   end
   return copy as T
end

-- TODO move to Errors module
local function clear_redundant_errors(errors: {Error})
   local redundant: {integer} = {}
   local lastx, lasty = 0, 0
   for i, err in ipairs(errors) do
      err.i = i
   end
   table.sort(errors, function(a: Error, b: Error): boolean
      local af = assert(a.filename)
      local bf = assert(b.filename)
      return af < bf
             or (af == bf   and (a.y < b.y
             or (a.y == b.y and (a.x < b.x
             or (a.x == b.x and (a.i < b.i))))))
   end)
   for i, err in ipairs(errors) do
      err.i = nil
      if err.x == lastx and err.y == lasty then
         table.insert(redundant, i)
      end
      lastx, lasty = err.x, err.y
   end
   for i = #redundant, 1, -1 do
      table.remove(errors, redundant[i])
   end
end

local simple_types: {TypeName:boolean} = {
   ["nil"] = true,
   ["any"] = true,
   ["number"] = true,
   ["string"] = true,
   ["thread"] = true,
   ["boolean"] = true,
   ["integer"] = true,
   ["self"] = true,
}

local function node_is_require_call(n: Node): string
   if not (n.e1 and n.e2) then
      return nil
   end
   if n.op and n.op.op == "." then
      -- `require("str").something`
      return node_is_require_call(n.e1)
   elseif n.e1.kind == "variable" and n.e1.tk == "require"
      and n.e2.kind == "expression_list" and #n.e2 == 1
      and n.e2[1].kind == "string"
   then
      -- `require("str")`
      return n.e2[1].conststr
   end
   return nil -- table.insert cares about arity
end

local function node_is_funcall(node: Node): boolean
   return node.kind == "op" and node.op.op == "@funcall"
end

local enum ParseLang
   "lua"
   "tl"
end

local enum MetaMode
   "meta"
end

do -----------------------------------------------------------------------------

local record ParseState
   tokens: {Token}
   errs: {Error}
   filename: string
   end_alignment_hint: Error

   required_modules: {string}
   parse_lang: ParseLang
end

local enum ParseTypeListMode
   "rets"
   "decltuple"
   "casttype"
end

-- type names used by parse_type_body_fns
local enum BodyTypeName
   "interface"
   "record"
   "enum"
end

local parse_type_list: function(ParseState, integer, ParseTypeListMode): integer, TupleType = nil
local parse_typeargs_if_any: function(ps: ParseState, i: integer): integer, {TypeArgType} = nil
local parse_expression: function(ParseState, integer): integer, Node, integer = nil
local parse_expression_and_tk: function(ps: ParseState, i: integer, tk: string): integer, Node = nil
local parse_statements: function(ParseState, integer, ? boolean): integer, Node = nil
local parse_argument_list: function(ParseState, integer): integer, Node, integer = nil
local parse_argument_type_list: function(ParseState, integer): integer, TupleType, boolean, integer = nil
local parse_type: function(ParseState, integer): integer, FirstClassType, integer = nil
local parse_type_declaration: function(ps: ParseState, i: integer, node_name: NodeKind): integer, Node = nil
local parse_interface_name: function(ps: ParseState, i: integer): integer, Type, integer = nil

local type ParseBody = function(ps: ParseState, i: integer, def: Type): integer, boolean
local parse_enum_body: function(ps: ParseState, i: integer, def: EnumType): integer, boolean
local parse_record_body: function(ps: ParseState, i: integer, def: Type): integer, boolean
local parse_type_body_fns: {BodyTypeName:ParseBody} = nil

local function fail(ps: ParseState, i: integer, msg: string, details?: Error): integer
   local err: Error = details or ({} as Error)
   err.code = err.code or (msg and msg:sub(1, 12) == "syntax error" and "syntax_error" or "other")
   err.filename = ps.filename
   if not ps.tokens[i] then
      local eof = ps.tokens[#ps.tokens]
      err.y = eof.y
      err.x = eof.x
      err.msg = msg or "unexpected end of file"
      table.insert(ps.errs, err)
      return #ps.tokens
   end
   err.y = ps.tokens[i].y
   err.x = ps.tokens[i].x
   err.msg = assert(msg, "syntax error, but no error message provided")
   table.insert(ps.errs, err)
   return math.min(#ps.tokens, i + 1)
end

local function end_at(node: Node, tk: Token)
   node.yend = tk.y
   node.xend = tk.x + #tk.tk - 1
end

local function verify_tk(ps: ParseState, i: integer, tk: string): integer
   if ps.tokens[i].tk == tk then
      return i + 1
   end
   return fail(ps, i, "syntax error, expected '" .. tk .. "'")
end

local function verify_end(ps: ParseState, i: integer, istart: integer, node: Node): integer
   if ps.tokens[i].tk == "end" then
      local endy, endx = ps.tokens[i].y, ps.tokens[i].x
      node.yend = endy
      node.xend = endx + 2
      if node.kind ~= "function" and endy ~= node.y and endx ~= node.x then
         if not ps.end_alignment_hint then
            ps.end_alignment_hint = { filename = ps.filename, y = node.y, x = node.x, code = "other", msg = "syntax error hint: construct starting here is not aligned with its 'end' at " .. ps.filename .. ":" .. endy .. ":" .. endx .. ":" }
         end
      end
      return i + 1
   end
   end_at(node, ps.tokens[i])
   if ps.end_alignment_hint then
      table.insert(ps.errs, ps.end_alignment_hint)
      ps.end_alignment_hint = nil
   end
   return fail(ps, i, "syntax error, expected 'end' to close construct started at " .. ps.filename .. ":" .. ps.tokens[istart].y .. ":" .. ps.tokens[istart].x .. ":")
end

local node_mt: metatable<Node> = {
   __tostring = function(n: Node): string
      return n.f .. ":" .. n.y .. ":" .. n.x .. " " .. n.kind
   end
}

local function new_node(ps: ParseState, i: integer, kind?: NodeKind): Node
   local t = ps.tokens[i]
   return setmetatable({ f = ps.filename, y = t.y, x = t.x, tk = t.tk, kind = kind or (t.kind as NodeKind) }, node_mt)
end

local function new_type(ps: ParseState, i: integer, typename: TypeName): Type
   local token = ps.tokens[i]
   local t: Type = setmetatable({}, type_mt)
   t.typeid = new_typeid()
   t.f = ps.filename
   t.x = token.x
   t.y = token.y
   t.typename = typename
   return t
end

local function new_first_order_type(ps: ParseState, i: integer, tn: BodyTypeName): FirstOrderType
   return new_type(ps, i, tn as TypeName) as FirstOrderType
end

local function new_generic(ps: ParseState, i: integer, typeargs: {TypeArgType}, typ: FirstOrderType): GenericType
   local gt = new_type(ps, i, "generic") as GenericType
   gt.typeargs = typeargs
   gt.t = typ
   return gt
end

local function new_typedecl(ps: ParseState, i: integer, def: FirstClassType): TypeDeclType
   local t = new_type(ps, i, "typedecl") as TypeDeclType
   t.def = def
   return t
end

local function new_tuple(ps: ParseState, i: integer, types?: {Type}, is_va?: boolean): TupleType, {Type}
   local t = new_type(ps, i, "tuple") as TupleType
   t.is_va = is_va
   t.tuple = types or {}
   return t, t.tuple
end

local function new_nominal(ps: ParseState, i: integer, name?: string): NominalType
   local t = new_type(ps, i, "nominal") as NominalType
   if name then
      t.names = { name }
   end
   return t
end

local function verify_kind(ps: ParseState, i: integer, kind: TokenKind, node_kind?: NodeKind): integer, Node
   if ps.tokens[i].kind == kind then
      return i + 1, new_node(ps, i, node_kind)
   end
   return fail(ps, i, "syntax error, expected " .. kind)
end

local type SkipFunction = function(ParseState, integer): integer, Node | boolean

local function skip(ps: ParseState, i: integer, skip_fn: SkipFunction): integer, Node | boolean
   local err_ps: ParseState = {
      filename = ps.filename,
      tokens = ps.tokens,
      errs = {},
      required_modules = {},
      parse_lang = ps.parse_lang,
   }
   return skip_fn(err_ps, i)
end

local function failskip(ps: ParseState, i: integer, msg: string, skip_fn: SkipFunction, starti?: integer, details?: Error): integer
   local skip_i = skip(ps, starti or i, skip_fn)
   fail(ps, i, msg, details)
   return skip_i
end

local function parse_type_body(ps: ParseState, i: integer, istart: integer, node: Node, tn: BodyTypeName): integer, GenericType | FirstOrderType
   local typeargs: {TypeArgType}
   local def: FirstOrderType
   i, typeargs = parse_typeargs_if_any(ps, i)

   def = new_first_order_type(ps, istart, tn)

   local ok: boolean
   i, ok = parse_type_body_fns[tn](ps, i, def)
   if not ok then
      return fail(ps, i, "expected a type")
   end

   i = verify_end(ps, i, istart, node)

   if typeargs then
      return i, new_generic(ps, istart, typeargs, def)
   end

   return i, def
end

local function skip_type_body(ps: ParseState, i: integer): integer, boolean
   local tn = ps.tokens[i].tk as BodyTypeName
   i = i + 1
   assert(parse_type_body_fns[tn], tn .. " has no parse body function")
   local ii, tt = parse_type_body(ps, i, i - 1, {}, tn)
   return ii, not not tt
end

-- Raised by a look ahead's tokens to end it early.
local look_ended = {}

-- Is a look ahead running? One begun within another (a body's
-- `macroexp` holds a function holding `local y = record`) answers none:
-- its tokens would read through the other's, a call deeper for each.
local looking = false

-- What parse makes of the tokens from i on, or nil where it fails, run
-- on copies so that it leaves the parse to come as it was: a type
-- argument list's `>>` is rewritten to `>` (`record < n >> 1`). The
-- copies are made as they are first read, so a look costs what it
-- reads, and it ends where it would cost more: at a token inserted to
-- recover from an error (a `>` missing at a line break), which shifts
-- every token after it and means the parse fails anyway, and at a
-- `where`, whose clause is an expression, function bodies and all, in
-- which a look of its own could begin.
local function look_ahead<T>(ps: ParseState, i: integer, parse: function(ParseState, integer): (integer, T)): T
   if looking then
      return nil
   end
   local base = ps.tokens
   local tokens: {Token} = setmetatable({} as {Token}, {
      __index = function(t: {Token}, j: integer): Token
         local tk = base[j]
         if j < i or not tk then
            return tk
         end
         if tk.tk == "where" then
            error(look_ended)
         end
         local copy: Token = { x = tk.x, y = tk.y, tk = tk.tk, kind = tk.kind, comments = tk.comments }
         rawset(t, j, copy)
         return copy
      end,
      __newindex = function(_: {Token}, _: integer, _: Token)
         error(look_ended)
      end,
      __len = function(_: {Token}): integer
         return #base
      end,
   } as metatable<{Token}>)
   local err_ps: ParseState = {
      filename = ps.filename,
      tokens = tokens,
      errs = {},
      required_modules = {},
      parse_lang = ps.parse_lang,
   }
   looking = true
   local ok, raised, result = pcall(parse, err_ps, i)
   looking = false
   if not ok then
      if raised ~= look_ended then
         error(raised, 0)
      end
      return nil
   end
   if #err_ps.errs > 0 then
      return nil
   end
   return result as T
end

-- Does the `record`, `interface` or `enum` at i start a type in the
-- syntax 0.7.1 dropped (`local Point = record ... end`), rather than
-- name a variable? Each is a name as well as a keyword, so it does only
-- where a type body parses after it with no error and declares
-- something: a field, a metamethod or an enum value. Neither an
-- expression nor the statements after one parse as such a body: a
-- field (`x: T`) is no statement, and a nested type needs `local`. An
-- empty old declaration (`record end`), or one with a mistake in its
-- body or a `where` clause, is read as a name and loses the hint.
--
-- Strings that close a block after `enum` (`enum "a" end`) read both
-- ways, as an enum and as calls of a function the name holds. They stay
-- the enum: every old enum declaration is spelled so, and would lose
-- its hint to a reading that serves only such a call.
local function is_old_type_syntax(ps: ParseState, i: integer): boolean
   if ps.tokens[i].tk == "enum" then
      -- An enum body is strings and its `end`, so look at the tokens
      -- rather than parse one: a parse records an error for each other
      -- token and goes on to the next `end`.
      local j = i + 1
      while ps.tokens[j].kind == "string" do
         j = j + 1
      end
      return j > i + 1 and ps.tokens[j].tk == "end"
   end
   local tn = ps.tokens[i].tk as BodyTypeName
   local t = look_ahead(ps, i, function(lps: ParseState, li: integer): integer, GenericType | FirstOrderType
      return parse_type_body(lps, li + 1, li, {}, tn)
   end)
   if not t then
      return false
   end
   local def = t is GenericType and t.t or t
   return def is RecordLikeType
      and (#def.field_order > 0 or #(def.meta_field_order or {}) > 0)
end

local function parse_table_value(ps: ParseState, i: integer): integer, Node, integer
   local next_word = ps.tokens[i].tk
   if (next_word == "record" or next_word == "interface") and is_old_type_syntax(ps, i) then
      local skip_i = skip(ps, i, skip_type_body)
      fail(ps, i, next_word == "record"
                  and "syntax error: this syntax is no longer valid; declare nested record inside a record"
                  or  "syntax error: cannot declare interface inside a table; use a statement")
      return skip_i, new_node(ps, i, "error_node")
   elseif next_word == "enum" and is_old_type_syntax(ps, i) then
      i = failskip(ps, i, "syntax error: this syntax is no longer valid; declare nested enum inside a record", skip_type_body)
      return i, new_node(ps, i - 1, "error_node")
   end

   local e: Node
   i, e = parse_expression(ps, i)
   if not e then
      e = new_node(ps, i - 1, "error_node")
   end
   return i, e
end

local function parse_table_item(ps: ParseState, i: integer, n?: integer): integer, Node, integer
   local node = new_node(ps, i, "literal_table_item")
   if ps.tokens[i].kind == "$EOF$" then
      return fail(ps, i, "unexpected eof")
   end

   if ps.tokens[i].tk == "[" then
      node.key_parsed = "long"
      i = i + 1
      i, node.key = parse_expression_and_tk(ps, i, "]")
      i = verify_tk(ps, i, "=")
      i, node.value = parse_table_value(ps, i)
      return i, node, n
   elseif ps.tokens[i].kind == "identifier" then
      if ps.tokens[i+1].tk == "=" then
         node.key_parsed = "short"
         i, node.key = verify_kind(ps, i, "identifier", "string")
         node.key.conststr = node.key.tk
         node.key.tk = '"' .. node.key.tk .. '"'
         i = verify_tk(ps, i, "=")
         i, node.value = parse_table_value(ps, i)
         return i, node, n
      elseif ps.tokens[i+1].tk == ":" then
         node.key_parsed = "short"
         local orig_i = i
         local try_ps: ParseState = {
            filename = ps.filename,
            tokens = ps.tokens,
            errs = {},
            required_modules = ps.required_modules,
            parse_lang = ps.parse_lang,
         }
         i, node.key = verify_kind(try_ps, i, "identifier", "string")
         node.key.conststr = node.key.tk
         node.key.tk = '"' .. node.key.tk .. '"'
         i = verify_tk(try_ps, i, ":")
         i, node.itemtype = parse_type(try_ps, i)
         if node.itemtype and ps.tokens[i].tk == "=" then
            i = verify_tk(try_ps, i, "=")
            i, node.value = parse_table_value(try_ps, i)
            if node.value then
               for _, e in ipairs(try_ps.errs) do
                  table.insert(ps.errs, e)
               end
               return i, node, n
            end
         end
         -- backtrack:
         node.itemtype = nil
         i = orig_i
      end
   end

   node.key = new_node(ps, i, "integer")
   node.key_parsed = "implicit"
   node.key.constnum = n
   node.key.tk = tostring(n)
   i, node.value = parse_expression(ps, i)
   if not node.value then
      return fail(ps, i, "expected an expression")
   end
   return i, node, n + 1
end

local type ParseItem = function<T>(ParseState, integer, ? integer): integer, T, integer

local enum SeparatorMode
   "sep"
   "term"
end

local function parse_list<T>(ps: ParseState, i: integer, list: {T}, close: {string:boolean}, sep: SeparatorMode, parse_item: ParseItem<T>): integer, {T}
   local n = 1
   while ps.tokens[i].kind ~= "$EOF$" do
      if close[ps.tokens[i].tk] then
         end_at(list as Node, ps.tokens[i])
         break
      end
      local item: T
      local oldn = n
      i, item, n = parse_item(ps, i, n)
      n = n or oldn
      table.insert(list, item)
      if ps.tokens[i].tk == "," then
         i = i + 1
         if sep == "sep" and close[ps.tokens[i].tk] then
            fail(ps, i, "unexpected '" .. ps.tokens[i].tk .. "'")
            return i, list
         end
      elseif sep == "term" and ps.tokens[i].tk == ";" then
         i = i + 1
      elseif not close[ps.tokens[i].tk] then
         local options = {}
         for k, _ in pairs(close) do
            table.insert(options, "'" .. k .. "'")
         end
         table.sort(options)
         local first = options[1]:sub(2, -2)
         local msg: string
         -- heuristic for parenthesized lists
         if first == ")" and ps.tokens[i].tk == "=" then
            msg = "syntax error, cannot perform an assignment here (did you mean '=='?)"
            i = failskip(ps, i, msg, parse_expression, i + 1)
         else
            table.insert(options, "','")
            msg = "syntax error, expected one of: " .. table.concat(options, ", ")
            local tokens: {string} = {}
            for _, option in ipairs(options) do
               table.insert(tokens, (option:sub(2, -2)))
            end
            fail(ps, i, msg, { code = "expected_one_of", expected_tokens = tokens } as Error)
         end
         -- heuristic for error recovery to avoid a cascade of errors:
         -- * if we're parsing a bracketed list, assume the missing token is a separator;
         -- * otherwise, if we have a line break, insert expected terminator token.
         if first ~= "}" and ps.tokens[i].y ~= ps.tokens[i-1].y then
            -- FIXME closing token may not be a keyword (but non-keywords are checked with verify_tk, so it should work)
            table.insert(ps.tokens, i, { tk = first, y = ps.tokens[i-1].y, x = ps.tokens[i-1].x + 1, kind = "keyword" })
            return i, list
         end
      end
   end
   return i, list
end

local function parse_bracket_list<T>(ps: ParseState, i: integer, list: {T}, open: string, close: string, sep: SeparatorMode, parse_item: ParseItem<T>): integer, {T}
   i = verify_tk(ps, i, open)
   i = parse_list(ps, i, list, { [close] = true }, sep, parse_item)
   i = verify_tk(ps, i, close)
   return i, list
end

local function parse_table_literal(ps: ParseState, i: integer): integer, Node
   local node = new_node(ps, i, "literal_table")
   return parse_bracket_list(ps, i, node, "{", "}", "term", parse_table_item)
end

local function starts_parameter(ps: ParseState, i: integer): boolean
   local tk, after, third = ps.tokens[i], ps.tokens[i + 1], ps.tokens[i + 2]
   return (tk.kind == "identifier" and after ~= nil and after.tk == ":")
      or (tk.kind == "identifier" and after ~= nil and after.tk == "?" and third ~= nil and third.tk == ":")
      or tk.tk == "?"
      or tk.tk == "..."
end

local function parse_trying_list<T>(ps: ParseState, i: integer, list: {T}, parse_item: ParseItem<T>, ret_lookahead?: boolean): integer, {T}
   local try_ps: ParseState = {
      filename = ps.filename,
      tokens = ps.tokens,
      errs = {},
      required_modules = ps.required_modules,
      parse_lang = ps.parse_lang
   }
   local tryi, item: integer, T = parse_item(try_ps, i)
   if not item then
      return i, list
   end
   for _, e in ipairs(try_ps.errs) do
      table.insert(ps.errs, e)
   end
   i = tryi
   table.insert(list, item)
   while ps.tokens[i].tk == ","
   and (not ret_lookahead or not starts_parameter(ps, i + 1))
   do
      i = i + 1
      i, item = parse_item(ps, i)
      table.insert(list, item)
   end
   return i, list
end

local function parse_anglebracket_list<T is Type>(ps: ParseState, i: integer, parse_item: ParseItem<T>): integer, {T}
   local second = ps.tokens[i+1]
   if second.tk == ">" then
      return fail(ps, i+1, "type argument list cannot be empty")
   elseif second.tk == ">>" then
      -- tokenizer hack: consume one bracket from '>>', don't skip over it
      second.tk = ">"
      fail(ps, i+1, "type argument list cannot be empty")
      return i+1
   end

   local types: {T} = {}
   i = verify_tk(ps, i, "<")
   i = parse_list(ps, i, types, { [">"] = true, [">>"] = true, }, "sep", parse_item)
   if ps.tokens[i].tk == ">" then
      i = i + 1
   elseif ps.tokens[i].tk == ">>" then
      -- tokenizer hack: consume one bracket from '>>', don't increment i
      ps.tokens[i].tk = ">"
   else
      return fail(ps, i, "syntax error, expected '>'")
   end
   return i, types
end

local function refuse_type_named_never(ps: ParseState, i: integer, name: string)
   if name == "never" then
      fail(ps, i, "a type cannot be named 'never': `: never` is the return list of a function that does not return")
   end
end

local function parse_typearg(ps: ParseState, i: integer): integer, TypeArgType, integer
   local name = ps.tokens[i].tk
   refuse_type_named_never(ps, i, name)
   local constraint: Type = nil
   local t = new_type(ps, i, "typearg") as TypeArgType
   i = verify_kind(ps, i, "identifier")
   if ps.tokens[i].tk == "is" then
      i = i + 1
      i, constraint = parse_interface_name(ps, i) -- FIXME what about generic interfaces
   end
   t.typearg = name
   t.constraint = constraint
   return i, t
end

local function is_never_return_list(ps: ParseState, i: integer): boolean
   if ps.tokens[i].tk ~= ":" or ps.tokens[i + 1].tk ~= "never" or ps.tokens[i + 1].kind ~= "identifier" then
      return false
   end
   local after = ps.tokens[i + 2].tk
   return after ~= "." and after ~= "<" and after ~= "|" and after ~= "..."
end

local function parse_return_types(ps: ParseState, i: integer): integer, TupleType, boolean
   local iprev = i - 1
   local t: TupleType
   local never = is_never_return_list(ps, i)
   if never and ps.tokens[i + 2].tk == "," and not starts_parameter(ps, i + 3) then
      fail(ps, i + 2, "'never' is the whole return list: nothing follows it")
      never = false
   end
   if never then
      t = new_tuple(ps, i)
      i = i + 2
   else
      i, t = parse_type_list(ps, i, "rets")
   end
   if #t.tuple == 0 then
      t.x = ps.tokens[iprev].x
      t.y = ps.tokens[iprev].y
   end
   return i, t, never
end

parse_typeargs_if_any = function(ps: ParseState, i: integer): integer, {TypeArgType}
   if ps.tokens[i].tk == "<" then
      return parse_anglebracket_list(ps, i, parse_typearg)
   end
   return i
end

local function parse_function_type(ps: ParseState, i: integer): integer, GenericType | FunctionType
   local typeargs: {TypeArgType}
   local typ = new_type(ps, i, "function") as FunctionType
   i = i + 1

   i, typeargs = parse_typeargs_if_any(ps, i)
   if ps.tokens[i].tk == "(" then
      i, typ.args, typ.maybe_method, typ.min_arity = parse_argument_type_list(ps, i)
      i, typ.rets, typ.never = parse_return_types(ps, i)
   else
      typ.args = new_tuple(ps, i, { new_type(ps, i, "any") }, true)
      typ.rets = new_tuple(ps, i, { new_type(ps, i, "any") }, true)
      typ.is_method = false
      typ.min_arity = 0
   end

   if typeargs then
      return i, new_generic(ps, i, typeargs, typ)
   end

   return i, typ
end

local function parse_simple_type_or_nominal(ps: ParseState, i: integer): integer, FirstOrderType
   local tk = ps.tokens[i].tk
   local st = simple_types[tk as TypeName]
   if st then
      return i + 1, new_type(ps, i, tk as TypeName) as StructuralType
   elseif tk == "table" and ps.tokens[i + 1].tk ~= "."  then
      local typ = new_type(ps, i, "map") as MapType
      typ.keys = new_type(ps, i, "any")
      typ.values = new_type(ps, i, "any")
      return i + 1, typ
   end

   local typ = new_nominal(ps, i, tk)
   i = i + 1
   while ps.tokens[i].tk == "." do
      i = i + 1
      if ps.tokens[i].kind == "identifier" then
         table.insert(typ.names, ps.tokens[i].tk)
         i = i + 1
      else
         return fail(ps, i, "syntax error, expected identifier")
      end
   end

   if ps.tokens[i].tk == "<" then
      i, typ.typevals = parse_anglebracket_list(ps, i, parse_type)
   end
   return i, typ
end

local function parse_base_type(ps: ParseState, i: integer): integer, FirstClassType, integer
   local tk = ps.tokens[i].tk
   if ps.tokens[i].kind == "identifier" then
      return parse_simple_type_or_nominal(ps, i)
   elseif tk == "{" then
      local istart = i
      i = i + 1
      local t: Type
      i, t = parse_type(ps, i)
      if not t then
         return i
      end
      if ps.tokens[i].tk == "}" then
         local decl = new_type(ps, istart, "array") as ArrayType
         decl.elements = t
         end_at(decl as Node, ps.tokens[i])
         i = verify_tk(ps, i, "}")
         return i, decl
      elseif ps.tokens[i].tk == "," then
         local decl = new_type(ps, istart, "tupletable") as TupleTableType
         decl.types = { t }
         local n = 2
         repeat
            i = i + 1
            i, decl.types[n] = parse_type(ps, i)
            if not decl.types[n] then
               break
            end
            n = n + 1
         until ps.tokens[i].tk ~= ","
         end_at(decl as Node, ps.tokens[i])
         i = verify_tk(ps, i, "}")
         return i, decl
      elseif ps.tokens[i].tk == ":" then
         local decl = new_type(ps, istart, "map") as MapType
         i = i + 1
         decl.keys = t
         i, decl.values = parse_type(ps, i)
         if not decl.values then
            return i
         end
         end_at(decl as Node, ps.tokens[i])
         i = verify_tk(ps, i, "}")
         return i, decl
      end
      return fail(ps, i, "syntax error; did you forget a '}'?")
   elseif tk == "function" then
      return parse_function_type(ps, i)
   elseif tk == "nil" then
      return i + 1, new_type(ps, i, "nil") as NilType
   end
   return fail(ps, i, "expected a type")
end

parse_type = function(ps: ParseState, i: integer): integer, FirstClassType, integer
   if ps.tokens[i].tk == "(" then
      i = i + 1
      local t: Type
      i, t = parse_type(ps, i)
      i = verify_tk(ps, i, ")")
      return i, t
   end

   local bt: FirstClassType
   local istart = i
   i, bt = parse_base_type(ps, i)
   if not bt then
      return i
   end
   if ps.tokens[i].tk == "|" then
      local u = new_type(ps, istart, "union") as UnionType
      u.types = { bt }
      while ps.tokens[i].tk == "|" do
         i = i + 1
         i, bt = parse_base_type(ps, i)
         if not bt then
            return i
         end
         table.insert(u.types, bt)
      end
      bt = u
   end
   return i, bt
end

parse_type_list = function(ps: ParseState, i: integer, mode: ParseTypeListMode): integer, TupleType
   local t, list = new_tuple(ps, i)

   local first_token = ps.tokens[i].tk
   if mode == "rets" or mode == "decltuple" then
      if first_token == ":" then
         i = i + 1
      else
         return i, t
      end
   end

   local optional_paren = false
   if ps.tokens[i].tk == "(" then
      optional_paren = true
      i = i + 1
   end

   local prev_i = i
   i = parse_trying_list(ps, i, list, parse_type, mode == "rets")
   if i == prev_i and ps.tokens[i].tk ~= ")" then
      fail(ps, i - 1, "expected a type list", { code = "type_list_expected" } as Error)
   end

   if mode == "rets" and ps.tokens[i].tk == "..." then
      i = i + 1
      local nrets = #list
      if nrets > 0 then
         t.is_va = true
      else
         fail(ps, i, "unexpected '...'")
      end
   end

   if optional_paren then
      i = verify_tk(ps, i, ")")
   end

   return i, t
end

local function parse_function_args_rets_body(ps: ParseState, i: integer, node: Node): integer, Node
   local istart = i - 1
   i, node.typeargs = parse_typeargs_if_any(ps, i)
   i, node.args, node.min_arity = parse_argument_list(ps, i)
   node.rets_omitted = ps.tokens[i].tk ~= ":"
   i, node.rets, node.never = parse_return_types(ps, i)
   i, node.body = parse_statements(ps, i)
   end_at(node, ps.tokens[i])
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function parse_function_value(ps: ParseState, i: integer): integer, Node
   local node = new_node(ps, i, "function")
   i = verify_tk(ps, i, "function")
   return parse_function_args_rets_body(ps, i, node)
end

local function unquote(str: string): string, boolean
   local f = str:sub(1, 1)
   if f == '"' or f == "'" then
      return str:sub(2, -2), false
   end
   f = str:match("^%[=*%[")
   local l = #f + 1
   return str:sub(l, -l), true
end

local function parse_literal(ps: ParseState, i: integer): integer, Node
   local tk = ps.tokens[i].tk
   local kind = ps.tokens[i].kind
   if kind == "identifier" then
      return verify_kind(ps, i, "identifier", "variable")
   elseif kind == "string" then
      local node = new_node(ps, i, "string")
      node.conststr, node.is_longstring = unquote(tk)
      return i + 1, node
   elseif kind == "number" or kind == "integer" then
      local n = tonumber((tk:gsub("_", "")))
      local node: Node
      i, node = verify_kind(ps, i, kind)
      node.constnum = n
      return i, node
   elseif tk == "true" then
      return verify_kind(ps, i, "keyword", "boolean")
   elseif tk == "false" then
      return verify_kind(ps, i, "keyword", "boolean")
   elseif tk == "nil" then
      return verify_kind(ps, i, "keyword", "nil")
   elseif tk == "function" then
      return parse_function_value(ps, i)
   elseif tk == "{" then
      return parse_table_literal(ps, i)
   elseif kind == "..." then
      return verify_kind(ps, i, "...")
   elseif kind == "$ERR$" then
      return fail(ps, i, "invalid token")
   end
   return fail(ps, i, "syntax error")
end

local function node_is_require_call_or_pcall(n: Node): string
   local r = node_is_require_call(n)
   if r then
      return r
   end
   if node_is_funcall(n)
      and n.e1 and n.e1.tk == "pcall"
      and n.e2 and #n.e2 == 2
      and n.e2[1].kind == "variable" and n.e2[1].tk == "require"
      and n.e2[2].kind == "string" and n.e2[2].conststr
   then
      -- `pcall(require, "str")`
      return n.e2[2].conststr
   end
   return nil -- table.insert cares about arity
end

do
   local precedences: {integer:{string:integer}} = {
      [1] = {
         ["not"] = 11,
         ["#"] = 11,
         ["-"] = 11,
         ["~"] = 11,
      },
      [2] = {
         ["or"] = 1,
         ["and"] = 2,
         ["is"] = 3,
         ["<"] = 3,
         [">"] = 3,
         ["<="] = 3,
         [">="] = 3,
         ["~="] = 3,
         ["=="] = 3,
         ["|"] = 4,
         ["~"] = 5,
         ["&"] = 6,
         ["<<"] = 7,
         [">>"] = 7,
         [".."] = 8,
         ["+"] = 9,
         ["-"] = 9,
         ["*"] = 10,
         ["/"] = 10,
         ["//"] = 10,
         ["%"] = 10,
         ["^"] = 12,
         ["as"] = 50,
         ["@funcall"] = 100,
         ["@index"] = 100,
         ["."] = 100,
         [":"] = 100,
      },
   }

   local is_right_assoc: {string:boolean} = {
      ["^"] = true,
      [".."] = true,
   }

   local function new_operator(tk: Token, arity: integer, op: string): Operator
      return { y = tk.y, x = tk.x, arity = arity, op = op, prec = precedences[arity][op] }
   end

   an_operator = function(node: Node, arity: integer, op: string): Operator
      return { y = node.y, x = node.x, arity = arity, op = op, prec = precedences[arity][op] }
   end

   local args_starters: {TokenKind:boolean} = {
      ["("] = true,
      ["{"] = true,
      ["string"] = true,
   }

   local E: function(ParseState, integer, Node, integer): integer, Node = nil

   local function after_valid_prefixexp(ps: ParseState, prevnode: Node, i: integer): boolean
      return ps.tokens[i - 1].kind == ")" -- '(' exp ')'
         or (prevnode.kind == "op"
             and (prevnode.op.op == "@funcall"
                  or prevnode.op.op == "@index"
                  or prevnode.op.op == "."
                  or prevnode.op.op == ":")
             )
         or prevnode.kind == "identifier"
         or prevnode.kind == "variable"
   end

   -- small hack: for the sake of `tl types`, parse an invalid binary exp
   -- as a paren to produce a unary indirection on e1 and save its location.
   local function failstore(ps: ParseState, tkop: Token, e1: Node): Node
      return { f = ps.filename, y = tkop.y, x = tkop.x, kind = "paren", e1 = e1, failstore = true }
   end

   local function P(ps: ParseState, i: integer): integer, Node
      if ps.tokens[i].kind == "$EOF$" then
         return i
      end
      local e1: Node
      local t1 = ps.tokens[i]
      if precedences[1][t1.tk] ~= nil then
         local op: Operator = new_operator(t1, 1, t1.tk)
         i = i + 1
         local prev_i = i
         i, e1 = P(ps, i)
         if not e1 then
            fail(ps, prev_i, "expected an expression")
            return i
         end
         e1 = { f = ps.filename, y = t1.y, x = t1.x, kind = "op", op = op, e1 = e1 }
      elseif ps.tokens[i].tk == "(" then
         i = i + 1
         local prev_i = i
         i, e1 = parse_expression_and_tk(ps, i, ")")
         if not e1 then
            fail(ps, prev_i, "expected an expression")
            return i
         end
         e1 = { f = ps.filename, y = t1.y, x = t1.x, kind = "paren", e1 = e1 }
      else
         i, e1 = parse_literal(ps, i)
      end

      if not e1 then
         return i
      end

      while true do
         local tkop = ps.tokens[i]
         if tkop.kind == "," or tkop.kind == ")" then -- check most common terminators first
            break
         end
         if tkop.tk == "." or tkop.tk == ":" then
            local op: Operator = new_operator(tkop, 2, tkop.tk)

            local prev_i = i

            local key: Node
            i = i + 1
            if ps.tokens[i].kind ~= "identifier" then
               local skipped = skip(ps, i, parse_type as SkipFunction)
               if skipped > i + 1 then
                  fail(ps, i, "syntax error, cannot declare a type here (missing 'local' or 'global'?)")
                  return skipped, failstore(ps, tkop, e1)
               end
            end
            i, key = verify_kind(ps, i, "identifier")
            if not key then
               return i, failstore(ps, tkop, e1)
            end

            if op.op == ":" then
               if not args_starters[ps.tokens[i].kind] then
                  if ps.tokens[i].tk == "=" then
                     fail(ps, i, "syntax error, cannot perform an assignment here (missing 'local' or 'global'?)")
                  else
                     fail(ps, i, "expected a function call for a method")
                  end
                  return i, failstore(ps, tkop, e1)
               end

               if not after_valid_prefixexp(ps, e1, prev_i) then
                  fail(ps, prev_i, "cannot call a method on this expression")
                  return i, failstore(ps, tkop, e1)
               end
            end

            e1 = { f = ps.filename, y = tkop.y, x = tkop.x, kind = "op", op = op, e1 = e1, e2 = key }
         elseif tkop.tk == "(" then
            local prev_tk = ps.tokens[i - 1]
            -- A long string, or a string with an escaped line break,
            -- ends on a later line than it starts on.
            local _, breaks = prev_tk.tk:gsub("\n", "")
            local prev_end_y = prev_tk.y + breaks
            if tkop.y > prev_end_y and ps.parse_lang ~= "lua" then
               local prev_end_x = prev_tk.x + #prev_tk.tk
               if breaks > 0 then
                  prev_end_x = #prev_tk.tk:match("[^\n]*$") + 1
               end
               table.insert(ps.tokens, i, { y = prev_end_y, x = prev_end_x, tk = ";", kind = ";" })
               break
            end

            local op: Operator = new_operator(tkop, 2, "@funcall")

            local prev_i = i

            local args = new_node(ps, i, "expression_list")
            i, args = parse_bracket_list(ps, i, args, "(", ")", "sep", parse_expression)

            if not after_valid_prefixexp(ps, e1, prev_i) then
               fail(ps, prev_i, "cannot call this expression")
               return i, failstore(ps, tkop, e1)
            end

            e1 = { f = ps.filename, y = args.y, x = args.x, kind = "op", op = op, e1 = e1, e2 = args }

            table.insert(ps.required_modules, node_is_require_call_or_pcall(e1))
         elseif tkop.tk == "[" then
            local op: Operator = new_operator(tkop, 2, "@index")

            local prev_i = i

            local idx: Node
            i = i + 1
            i, idx = parse_expression_and_tk(ps, i, "]")

            if not after_valid_prefixexp(ps, e1, prev_i) then
               fail(ps, prev_i, "cannot index this expression")
               return i, failstore(ps, tkop, e1)
            end

            e1 = { f = ps.filename, y = tkop.y, x = tkop.x, kind = "op", op = op, e1 = e1, e2 = idx }
         elseif tkop.kind == "string" or tkop.kind == "{" then
            local op: Operator = new_operator(tkop, 2, "@funcall")

            local prev_i = i

            local args = new_node(ps, i, "expression_list")
            local argument: Node
            if tkop.kind == "string" then
               argument = new_node(ps, i)
               argument.conststr = unquote(tkop.tk)
               i = i + 1
            else
               i, argument = parse_table_literal(ps, i)
            end

            if not after_valid_prefixexp(ps, e1, prev_i) then
               if tkop.kind == "string" then
                  fail(ps, prev_i, "cannot use a string here; if you're trying to call the previous expression, wrap it in parentheses")
               else
                  fail(ps, prev_i, "cannot use a table here; if you're trying to call the previous expression, wrap it in parentheses")
               end
               return i, failstore(ps, tkop, e1)
            end

            table.insert(args, argument)
            e1 = { f = ps.filename, y = args.y, x = args.x, kind = "op", op = op, e1 = e1, e2 = args }

            table.insert(ps.required_modules, node_is_require_call_or_pcall(e1))
         elseif tkop.tk == "as" or tkop.tk == "is" then
            local op: Operator = new_operator(tkop, 2, tkop.tk)

            i = i + 1
            local cast = new_node(ps, i, "cast")
            if ps.tokens[i].tk == "(" then
               i, cast.casttype = parse_type_list(ps, i, "casttype")
            else
               i, cast.casttype = parse_type(ps, i)
            end
            if not cast.casttype then
               return i, failstore(ps, tkop, e1)
            end
            e1 = { f = ps.filename, y = tkop.y, x = tkop.x, kind = "op", op = op, e1 = e1, e2 = cast, conststr = e1.conststr }
         else
            break
         end
      end

      return i, e1
   end

   E = function(ps: ParseState, i: integer, lhs: Node, min_precedence: integer): integer, Node
      local lookahead = ps.tokens[i].tk
      while precedences[2][lookahead] and precedences[2][lookahead] >= min_precedence do
         local t1 = ps.tokens[i]
         local op: Operator = new_operator(t1, 2, t1.tk)
         i = i + 1
         local rhs: Node
         i, rhs = P(ps, i)
         if not rhs then
            fail(ps, i, "expected an expression")
            return i
         end
         lookahead = ps.tokens[i].tk
         while precedences[2][lookahead] and ((precedences[2][lookahead] > (precedences[2][op.op]))
            or (is_right_assoc[lookahead] and (precedences[2][lookahead] == precedences[2][op.op]))) do
            i, rhs = E(ps, i, rhs, precedences[2][lookahead])
            if not rhs then
               fail(ps, i, "expected an expression")
               return i
            end
            lookahead = ps.tokens[i].tk
         end
         lhs = { f = ps.filename, y = t1.y, x = t1.x, kind = "op", op = op, e1 = lhs, e2 = rhs, }
      end
      return i, lhs
   end

   parse_expression = function(ps: ParseState, i: integer): integer, Node, integer
      local lhs: Node
      local istart = i
      i, lhs = P(ps, i)
      if lhs then
         i, lhs = E(ps, i, lhs, 0)
      end
      if lhs then
         return i, lhs, 0
      end
      -- if cursor moved, a more specific error was already thrown
      if i == istart then
         i = fail(ps, i, "expected an expression")
      end
      return i
   end
end

parse_expression_and_tk = function(ps: ParseState, i: integer, tk: string): integer, Node
   local e: Node
   i, e = parse_expression(ps, i)
   if not e then
      e = new_node(ps, i - 1, "error_node")
   end
   if ps.tokens[i].tk == tk then
      i = i + 1
   else
      local msg = "syntax error, expected '" .. tk .. "'"
      if ps.tokens[i].tk == "=" then
         msg = "syntax error, cannot perform an assignment here (did you mean '=='?)"
      end

      -- try to resync the parser for a bit
      for n = 0, 19 do
         local t = ps.tokens[i + n]
         if t.kind == "$EOF$" then
            break
         end
         if t.tk == tk then
            fail(ps, i, msg)
            return i + n + 1, e
         end
      end
      i = fail(ps, i, msg)
   end
   return i, e
end

local function parse_variable_name(ps: ParseState, i: integer): integer, Node, integer
   local node: Node
   i, node = verify_kind(ps, i, "identifier")
   if not node then
      return i
   end
   if ps.tokens[i].tk == "<" then
      i = i + 1
      local annotation: Node
      i, annotation = verify_kind(ps, i, "identifier")
      if annotation then
         if not is_attribute[annotation.tk] then
            fail(ps, i, "unknown variable annotation: " .. annotation.tk)
         end
         node.attribute = annotation.tk as Attribute
      else
         fail(ps, i, "expected a variable annotation")
      end
      i = verify_tk(ps, i, ">")
   end
   return i, node
end

local function parse_argument(ps: ParseState, i: integer): integer, Node, integer
   local node: Node
   if ps.tokens[i].tk == "..." then
      i, node = verify_kind(ps, i, "...", "argument")
      node.opt = true
   else
      i, node = verify_kind(ps, i, "identifier", "argument")
   end
   if ps.tokens[i].tk == "..." then
      fail(ps, i, "'...' needs to be declared as a typed argument")
   end
   if ps.tokens[i].tk == "?" then
      i = i + 1
      node.opt = true
   end
   if ps.tokens[i].tk == ":" then
      i = i + 1
      local argtype: Type

      i, argtype = parse_type(ps, i)

      if node then
         node.argtype = argtype
      end
   end
   return i, node, 0
end

parse_argument_list = function(ps: ParseState, i: integer): integer, Node, integer
   local node = new_node(ps, i, "argument_list")
   i, node = parse_bracket_list(ps, i, node, "(", ")", "sep", parse_argument)
   local opts = false
   local min_arity = 0
   for a, fnarg in ipairs(node) do
      if fnarg.tk == "..." then
         if a ~= #node then
            fail(ps, i, "'...' can only be last argument")
            break
         end
      elseif fnarg.opt then
         opts = true
      elseif opts then
         return fail(ps, i, "non-optional arguments cannot follow optional arguments")
      else
         min_arity = min_arity + 1
      end
   end
   return i, node, min_arity
end

local record ArgumentInfo
   i: integer
   type: Type
   is_va: boolean
   is_self: boolean
   opt: boolean
end

local function parse_argument_type(ps: ParseState, i: integer): integer, ArgumentInfo, integer
   local opt = 0
   local is_va = false
   local is_self = false
   local argument_name: string = nil

   if ps.tokens[i].kind == "identifier" then
      argument_name = ps.tokens[i].tk
      if ps.tokens[i + 1].tk == "?" then
         opt = i + 1
         if ps.tokens[i + 2].tk == ":" then
            i = i + 3
         end
      elseif ps.tokens[i + 1].tk == ":" then
         i = i + 2
      end
   elseif ps.tokens[i].kind == "?" then
      opt = i
      i = i + 1
   elseif ps.tokens[i].tk == "..." then
      if ps.tokens[i + 1].tk == "?" then
         fail(ps, i + 1, "cannot mix '?' and '...' in a declaration; '...' already implies optional")
         i = i + 1
      end
      if ps.tokens[i + 1].tk == ":" then
         i = i + 2
         is_va = true
      else
         return fail(ps, i, "cannot have untyped '...' when declaring the type of an argument")
      end
   end

   local typ: Type; i, typ = parse_type(ps, i)
   if typ then
      if not is_va and ps.tokens[i].tk == "..." then
         i = i + 1
         is_va = true
         if opt > 0 then
            fail(ps, opt, "cannot mix '?' and '...' in a declaration; '...' already implies optional")
         end
      end

      if argument_name == "self" then
         is_self = true
      end
   end

   return i, { i = i, type = typ, is_va = is_va, is_self = is_self, opt = (opt > 0) or is_va }, 0
end

parse_argument_type_list = function(ps: ParseState, i: integer): integer, Type, boolean, integer
   local ars: {ArgumentInfo} = {}
   i = parse_bracket_list(ps, i, ars, "(", ")", "sep", parse_argument_type)
   local t, list = new_tuple(ps, i)
   local n = #ars
   local min_arity = 0
   local opts = false
   for l, ar in ipairs(ars) do
      list[l] = ar.type
      if ar.is_va and l < n then
         fail(ps, ar.i, "'...' can only be last argument")
      end
      if not ar.opt then
         if opts then
            fail(ps, ar.i, "non-optional arguments cannot follow optional arguments")
         end
         min_arity = min_arity + 1
      elseif not ar.is_va then
         opts = true
      end
   end
   if n > 0 and ars[n].is_va then
      t.is_va = true
   end
   return i, t, (n > 0 and ars[1].is_self), min_arity
end

local function parse_identifier(ps: ParseState, i: integer): integer, Node, integer
   if ps.tokens[i].kind == "identifier" then
      return i + 1, new_node(ps, i, "identifier")
   end
   i = fail(ps, i, "syntax error, expected identifier")
   return i, new_node(ps, i, "error_node")
end

local function parse_local_function(ps: ParseState, i: integer): integer, Node
   i = verify_tk(ps, i, "local")
   i = verify_tk(ps, i, "function")
   local node = new_node(ps, i - 2, "local_function")
   i, node.name = parse_identifier(ps, i)
   return parse_function_args_rets_body(ps, i, node)
end

local enum FunctionKind
   "global"
   "record"
end

local function parse_function(ps: ParseState, i: integer, fk: FunctionKind): integer, Node
   local orig_i = i
   i = verify_tk(ps, i, "function")
   local fn = new_node(ps, i - 1, "global_function")
   local names: {Node} = {}
   i, names[1] = parse_identifier(ps, i)
   while ps.tokens[i].tk == "." do
      i = i + 1
      i, names[#names + 1] = parse_identifier(ps, i)
   end
   if ps.tokens[i].tk == ":" then
      i = i + 1
      i, names[#names + 1] = parse_identifier(ps, i)
      fn.is_method = true
   end

   if #names > 1 then
      fn.kind = "record_function"
      local owner = names[1]
      owner.kind = "type_identifier"
      for i2 = 2, #names - 1 do
         local dot = an_operator(names[i2], 2, ".")
         names[i2].kind = "identifier"
         owner = { f = ps.filename, y = names[i2].y, x = names[i2].x, kind = "op", op = dot, e1 = owner, e2 = names[i2] }
      end
      fn.fn_owner = owner
   end
   fn.name = names[#names]

   local selfx, selfy = ps.tokens[i].x, ps.tokens[i].y
   i = parse_function_args_rets_body(ps, i, fn)
   if fn.is_method and fn.args then
      table.insert(fn.args, 1, { f = ps.filename, x = selfx, y = selfy, tk = "self", kind = "identifier", is_self = true })
      fn.min_arity = fn.min_arity + 1
   end

   if not fn.name then
      return orig_i + 1
   end

   if fn.kind == "record_function" and fk == "global" then
      fail(ps, orig_i, "record functions cannot be annotated as 'global'")
   elseif fn.kind == "global_function" and fk == "record" then
      fn.implicit_global_function = true
   end

   return i, fn
end

local function parse_if_block(ps: ParseState, i: integer, n: integer, node: Node, is_else?: boolean): integer, Node
   local block = new_node(ps, i, "if_block")
   i = i + 1
   block.if_parent = node
   block.if_block_n = n
   if not is_else then
      i, block.exp = parse_expression_and_tk(ps, i, "then")
      if not block.exp then
         return i
      end
   end
   i, block.body = parse_statements(ps, i)
   if not block.body then
      return i
   end
   block.yend, block.xend = block.body.yend, block.body.xend
   table.insert(node.if_blocks, block)
   return i, node
end

local function parse_if(ps: ParseState, i: integer): integer, Node
   local istart = i
   local node = new_node(ps, i, "if")
   node.if_blocks = {}
   i, node = parse_if_block(ps, i, 1, node)
   if not node then
      return i
   end
   local n = 2
   while ps.tokens[i].tk == "elseif" do
      i, node = parse_if_block(ps, i, n, node)
      if not node then
         return i
      end
      n = n + 1
   end
   if ps.tokens[i].tk == "else" then
      i, node = parse_if_block(ps, i, n, node, true)
      if not node then
         return i
      end
   end
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function parse_while(ps: ParseState, i: integer): integer, Node
   local istart = i
   local node = new_node(ps, i, "while")
   i = verify_tk(ps, i, "while")
   i, node.exp = parse_expression_and_tk(ps, i, "do")
   i, node.body = parse_statements(ps, i)
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function parse_fornum(ps: ParseState, i: integer): integer, Node
   local istart = i
   local node = new_node(ps, i, "fornum")
   i = i + 1
   i, node.var = parse_identifier(ps, i)
   i = verify_tk(ps, i, "=")
   i, node.from = parse_expression_and_tk(ps, i, ",")
   i, node.to = parse_expression(ps, i)
   if ps.tokens[i].tk == "," then
      i = i + 1
      i, node.step = parse_expression_and_tk(ps, i, "do")
   else
      i = verify_tk(ps, i, "do")
   end
   i, node.body = parse_statements(ps, i)
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function parse_forin(ps: ParseState, i: integer): integer, Node
   local istart = i
   local node = new_node(ps, i, "forin")
   i = i + 1
   node.vars = new_node(ps, i, "variable_list")
   i, node.vars = parse_list(ps, i, node.vars, { ["in"] = true }, "sep", parse_identifier)
   i = verify_tk(ps, i, "in")
   node.exps = new_node(ps, i, "expression_list")
   i = parse_list(ps, i, node.exps, { ["do"] = true }, "sep", parse_expression)
   if #node.exps < 1 then
      return fail(ps, i, "missing iterator expression in generic for")
   elseif #node.exps > 3 then
      return fail(ps, i, "too many expressions in generic for")
   end
   i = verify_tk(ps, i, "do")
   i, node.body = parse_statements(ps, i)
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function parse_for(ps: ParseState, i: integer): integer, Node
   if ps.tokens[i+1].kind == "identifier" and ps.tokens[i+2].tk == "=" then
      return parse_fornum(ps, i)
   else
      return parse_forin(ps, i)
   end
end

local function parse_repeat(ps: ParseState, i: integer): integer, Node
   local node = new_node(ps, i, "repeat")
   i = verify_tk(ps, i, "repeat")
   i, node.body = parse_statements(ps, i)
   node.body.is_repeat = true
   i = verify_tk(ps, i, "until")
   i, node.exp = parse_expression(ps, i)
   end_at(node, ps.tokens[i - 1])
   return i, node
end

local function parse_do(ps: ParseState, i: integer): integer, Node
   local istart = i
   local node = new_node(ps, i, "do")
   i = verify_tk(ps, i, "do")
   i, node.body = parse_statements(ps, i)
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function parse_break(ps: ParseState, i: integer): integer, Node
   local node = new_node(ps, i, "break")
   i = verify_tk(ps, i, "break")
   return i, node
end

local function parse_goto(ps: ParseState, i: integer): integer, Node
   local node = new_node(ps, i, "goto")
   i = verify_tk(ps, i, "goto")
   node.label = ps.tokens[i].tk
   i = verify_kind(ps, i, "identifier")
   return i, node
end

local function parse_label(ps: ParseState, i: integer): integer, Node
   local node = new_node(ps, i, "label")
   i = verify_tk(ps, i, "::")
   node.label = ps.tokens[i].tk
   i = verify_kind(ps, i, "identifier")
   i = verify_tk(ps, i, "::")
   return i, node
end

local stop_statement_list: {string:boolean} = {
   ["end"] = true,
   ["else"] = true,
   ["elseif"] = true,
   ["until"] = true,
}

local stop_return_list: {string:boolean} = {
   [";"] = true,
   ["$EOF$"] = true,
}

for k, v in pairs(stop_statement_list) do
   stop_return_list[k] = v
end

local function parse_return(ps: ParseState, i: integer): integer, Node
   local node = new_node(ps, i, "return")
   i = verify_tk(ps, i, "return")
   node.exps = new_node(ps, i, "expression_list")
   i = parse_list(ps, i, node.exps, stop_return_list, "sep", parse_expression)
   if ps.tokens[i].kind == ";" then
      i = i + 1
      if ps.tokens[i].kind ~= "$EOF$" and not stop_statement_list[ps.tokens[i].tk] then
         return fail(ps, i, "return must be the last statement of its block")
      end
   end
   return i, node
end

local function field_name_follows(ps: ParseState, i: integer): boolean
   local after = ps.tokens[i + 1].tk
   return after == ":" or (after == "?" and ps.tokens[i + 2] ~= nil and ps.tokens[i + 2].tk == ":")
end

local function optional_field_type(ps: ParseState, i: integer, t: Type): Type
   if t is GenericType then
      fail(ps, i, "an optional field cannot have a generic type (a plain field `f: function<T>(T): T` can be left out of a literal anyway)")
      return t
   end
   local members: {Type} = {}
   if t is UnionType then
      for _, m in ipairs(t.types) do
         table.insert(members, m)
      end
   else
      members[1] = t
   end
   for _, m in ipairs(members) do
      if m is NilType then
         return t
      end
   end
   table.insert(members, new_type(ps, i, "nil") as NilType)
   local u = new_type(ps, i, "union") as UnionType
   u.types = members
   return u
end

local function store_field_in_record(ps: ParseState, i: integer, field_name: string, newt: Type, def: RecordLikeType, comments?: {Comment}, meta?: MetaMode): boolean
   local field_order, fields, field_comments: {string}, {string:Type}, {string: {{Comment}}}
   if meta then
      field_order, fields, field_comments = def.meta_field_order, def.meta_fields, def.meta_field_comments
   else
      field_order, fields, field_comments = def.field_order, def.fields, def.field_comments
   end

   if comments and not field_comments then
      field_comments = {}
      if meta then
         def.meta_field_comments = field_comments
      else
         def.field_comments = field_comments
      end
   end

   if not fields[field_name] then
      fields[field_name] = newt
      if comments then
         field_comments[field_name] = {comments}
      end
      table.insert(field_order, field_name)
      return true
   end

   local oldt = fields[field_name]
   local oldf = oldt is GenericType and oldt.t or oldt
   local newf = newt is GenericType and newt.t or newt

   local function store_comment_for_poly(poly: PolyType)
      if comments then
         if not field_comments[field_name] then
            field_comments[field_name] = {}
            for idx = 1, #poly.types - 1 do -- padding for existing types
               field_comments[field_name][idx] = {}
            end
         end
         table.insert(field_comments[field_name], comments)
      elseif field_comments and field_comments[field_name] then
         table.insert(field_comments[field_name], {})
      end
   end

   if newf is FunctionType then
      if oldf is FunctionType then
         local p = new_type(ps, i, "poly") as PolyType
         p.types = { oldt as FunctionType, newt as FunctionType }
         fields[field_name] = p
         store_comment_for_poly(p)
         return true
      elseif oldt is PolyType then
         table.insert(oldt.types, newt as FunctionType)
         store_comment_for_poly(oldt)
         return true
      end
   end
   fail(ps, i, "attempt to redeclare field '" .. field_name .. "' (only functions can be overloaded)")
   return false
end

local function set_declname(def: Type, declname: string)
   if def is GenericType then
      def = def.t
   end

   if def is RecordType or def is InterfaceType or def is EnumType then
      if not def.declname then
         def.declname = declname
      end
   end
end

local function get_attached_comments(token: Token): {Comment}
   if not token.comments then
      return nil
   end

   local function is_long_comment(c: Comment): boolean
      return c.text:match("^%-%-%[(=*)%[") ~= nil
   end
   local last_comment = token.comments[#token.comments]

   -- special case for long comments
   if is_long_comment(last_comment) then
      local _, newlines = string.gsub(last_comment.text, "\n", "")
      local diff_y = token.y - last_comment.y - newlines
      -- we want to attach only long comments that end just before the token
      if diff_y >= 0 and diff_y <= 1 then
         return {last_comment}
      else
         return nil
      end
   end

   local diff_y = token.y - last_comment.y
   if diff_y < 0 or diff_y > 1 then
      return nil
   end
   local first_n = 1
   for i = #token.comments, 2, -1 do
      local prev = token.comments[i - 1]
      if is_long_comment(prev) then
         first_n = i
         break
      end
      -- we want to attach only consecutive comments
      if token.comments[i].y - prev.y > 1 then
         first_n = i
         break
      end
   end

   local attached_comments =
      table.move(token.comments, first_n, #token.comments, 1, {})

   return attached_comments
end

local function parse_nested_type(ps: ParseState, i: integer, def: RecordLikeType, tn: BodyTypeName): integer, boolean
   local istart = i
   i = i + 1 -- skip 'record' or 'enum'
   local iv = i

   local v: Node
   i, v = verify_kind(ps, i, "identifier", "type_identifier")
   if not v then
      return fail(ps, i, "expected a variable name")
   end
   refuse_type_named_never(ps, iv, v.tk)

   local nt: Node = new_node(ps, istart, "newtype")

   local ndef: Type
   i, ndef = parse_type_body(ps, i, istart, nt, tn)
   if not ndef then
      return i
   end

   set_declname(ndef, v.tk)

   nt.newtype = new_typedecl(ps, istart, ndef)

   store_field_in_record(ps, iv, v.tk, nt.newtype, def, get_attached_comments(ps.tokens[istart]))
   return i
end

parse_enum_body = function(ps: ParseState, i: integer, def: EnumType): integer, boolean
   def.enumset = {}
   while ps.tokens[i].tk ~= "$EOF$" and ps.tokens[i].tk ~= "end" do
      local item: Node
      i, item = verify_kind(ps, i, "string", "string")
      if item then
         local name = unquote(item.tk)
         def.enumset[name] = true
         local comments = get_attached_comments(ps.tokens[i - 1])
         if comments then
            if not def.value_comments then
               def.value_comments = {}
            end
            def.value_comments[name] = comments
         end
      end
   end
   return i, true
end

local metamethod_names: {string:boolean} = {
   ["__add"] = true,
   ["__sub"] = true,
   ["__mul"] = true,
   ["__div"] = true,
   ["__mod"] = true,
   ["__pow"] = true,
   ["__unm"] = true,
   ["__idiv"] = true,
   ["__band"] = true,
   ["__bor"] = true,
   ["__bxor"] = true,
   ["__bnot"] = true,
   ["__shl"] = true,
   ["__shr"] = true,
   ["__concat"] = true,
   ["__len"] = true,
   ["__eq"] = true,
   ["__lt"] = true,
   ["__le"] = true,
   ["__index"] = true,
   ["__newindex"] = true,
   ["__call"] = true,
   ["__tostring"] = true,
   ["__pairs"] = true,
   ["__gc"] = true,
   ["__close"] = true,
   ["__is"] = true,
}

local function parse_macroexp(ps: ParseState, istart: integer, iargs: integer): integer, Node
   local node = new_node(ps, istart, "macroexp")

   local i: integer
   if ps.tokens[istart + 1].tk == "<" then
      i, node.typeargs = parse_anglebracket_list(ps, istart + 1, parse_typearg)
   else
      i = iargs
   end

   i, node.args, node.min_arity = parse_argument_list(ps, i)
   i, node.rets, node.never = parse_return_types(ps, i)
   i = verify_tk(ps, i, "return")
   i, node.exp = parse_expression(ps, i)
   end_at(node, ps.tokens[i])
   i = verify_end(ps, i, istart, node)
   return i, node
end

local function parse_where_clause(ps: ParseState, i: integer, def: RecordLikeType): integer, Node
   local node = new_node(ps, i, "macroexp")

   node.is_method = true
   node.args = new_node(ps, i, "argument_list")
   node.args[1] = new_node(ps, i, "argument")
   node.args[1].tk = "self"
   node.args[1].argtype = new_type(ps, i, "self")
   (node.args[1].argtype as SelfType).display_type = def
   node.min_arity = 1
   node.rets = new_tuple(ps, i)
   node.rets.tuple[1] = new_type(ps, i, "boolean")
   i, node.exp = parse_expression(ps, i)
   end_at(node, ps.tokens[i - 1])
   return i, node
end

parse_interface_name = function(ps: ParseState, i: integer): integer, FirstOrderType, integer
   local istart = i
   local typ: FirstOrderType
   i, typ = parse_simple_type_or_nominal(ps, i)
   if not typ is NominalType then
      return fail(ps, istart, "expected an interface")
   end
   return i, typ
end

local function parse_array_interface_type(ps: ParseState, i: integer, def: RecordLikeType): integer, ArrayType
   if def.interface_list then
      local first = def.interface_list[1]
      if first is ArrayType then
         return failskip(ps, i, "duplicated declaration of array element type", parse_type as SkipFunction)
      end
   end
   local t: Type
   i, t = parse_base_type(ps, i)
   if not t then
      return i
   end
   if not t is ArrayType then
      fail(ps, i, "expected an array declaration")
      return i
   end
   def.elements = t.elements
   return i, t
end

-- FIXME (a) GenericType do we need to patch the where-generated __is function into a generic? (see (b))
--local function clone_typeargs(ps: ParseState, i: integer, typeargs: {TypeArgType}): {TypeArgType}
--   local copy = {}
--   for a, ta in ipairs(typeargs) do
--      local cta = new_type(ps, i, "typearg") as TypeArgType
--      cta.typearg = ta.typearg
--      copy[a] = cta
--   end
--   return copy
--end

local function extract_userdata_from_interface_list(ps: ParseState, i: integer, def: RecordLikeType)
   for j = #def.interface_list, 1, -1 do
      local iface = def.interface_list[j]
      if iface is NominalType and #iface.names == 1 and iface.names[1] == "userdata" then
         table.remove(def.interface_list, j)
         if def.is_userdata then
            fail(ps, i, "duplicated 'userdata' declaration")
         end
         def.is_userdata = true
      end
   end
end

parse_record_body = function(ps: ParseState, i: integer, def: RecordLikeType): integer, boolean
   def.fields = {}
   def.field_order = {}

   if ps.tokens[i].tk == "{" then
      local atype: Type
      i, atype = parse_array_interface_type(ps, i, def)
      if atype then
         def.interface_list = { atype }
      end
   end

   if ps.tokens[i].tk == "is" then
      i = i + 1

      if ps.tokens[i].tk == "{" then
         local atype: Type
         i, atype = parse_array_interface_type(ps, i, def)
         if ps.tokens[i].tk == "," then
            i = i + 1
            i, def.interface_list = parse_trying_list(ps, i, {}, parse_interface_name)
         else
            def.interface_list = {}
         end
         if atype then
            table.insert(def.interface_list, 1, atype)
         end
      else
         i, def.interface_list = parse_trying_list(ps, i, {}, parse_interface_name)
      end

      if def.interface_list then
         extract_userdata_from_interface_list(ps, i, def)
      end
   end

   if ps.tokens[i].tk == "where" then
      local wstart = i
      i = i + 1
      local where_macroexp: Node
      i, where_macroexp = parse_where_clause(ps, i, def)

      local typ = new_type(ps, wstart, "function") as FunctionType
      -- FIXME (b) GenericType do we need to patch the where-generated __is function into a generic? (see (a))
      typ.is_method = true
      typ.min_arity = 1
      typ.args = new_tuple(ps, wstart, {
         a_self(where_macroexp, def)
      })
      typ.rets = new_tuple(ps, wstart, { new_type(ps, wstart, "boolean") })
      typ.macroexp = where_macroexp

      def.meta_fields = {}
      def.meta_field_order = {}
      store_field_in_record(ps, i, "__is", typ, def, nil, "meta")
   end

   while not (ps.tokens[i].kind == "$EOF$" or ps.tokens[i].tk == "end") do
      local tn = ps.tokens[i].tk as BodyTypeName
      if ps.tokens[i].tk == "userdata" and not field_name_follows(ps, i) then
         if def.is_userdata then
            fail(ps, i, "duplicated 'userdata' declaration")
         else
            def.is_userdata = true
         end
         i = i + 1
      elseif ps.tokens[i].tk == "{" then
         return fail(ps, i, "syntax error: this syntax is no longer valid; declare array interface at the top with 'is {...}'")
      elseif ps.tokens[i].tk == "type" and not field_name_follows(ps, i) then
         local comments = get_attached_comments(ps.tokens[i])
         i = i + 1
         local iv = i

         local lt: Node
         i, lt = parse_type_declaration(ps, i, "local_type") -- local_type Node will be discarded
         if not lt then
            return fail(ps, i, "expected a type definition")
         end

         local v = lt.var
         if not v then
            return fail(ps, i, "expected a variable name")
         end

         local nt = lt.value
         if not nt or not nt.newtype then
            return fail(ps, i, "expected a type definition")
         end

         local ntt = nt.newtype
         if ntt.is_alias then
            ntt.is_nested_alias = true
         end

         store_field_in_record(ps, iv, v.tk, nt.newtype, def, comments)
      elseif parse_type_body_fns[tn] and not field_name_follows(ps, i) then
         if def.typename == "interface" and tn == "record" then
            i = failskip(ps, i, "interfaces cannot contain record definitions", skip_type_body)
         else
            i = parse_nested_type(ps, i, def, tn)
         end
      else
         local comments = get_attached_comments(ps.tokens[i])
         local is_metamethod = false
         if ps.tokens[i].tk == "metamethod" and not field_name_follows(ps, i) then
            is_metamethod = true
            i = i + 1
         end

         local v: Node
         if ps.tokens[i].tk == "[" then
            i, v = parse_literal(ps, i+1)
            if v and not v.conststr then
               return fail(ps, i, "expected a string literal")
            end
            i = verify_tk(ps, i, "]")
         else
            i, v = verify_kind(ps, i, "identifier", "variable")
         end
         local iv = i
         if not v then
            return fail(ps, i, "expected a variable name")
         end

         local optional = false
         if ps.tokens[i].tk == "?" and ps.tokens[i + 1].tk == ":" then
            if is_metamethod then
               fail(ps, i, "a metamethod cannot be optional")
            end
            optional = true
            i = i + 1
         end

         if ps.tokens[i].tk == ":" then
            i = i + 1
            local type_at = i
            local t: Type
            i, t = parse_type(ps, i)
            if not t then
               return fail(ps, i, "expected a type")
            end
            if t is FunctionType and t.maybe_method then
               t.is_method = true
            end

            local field_name = v.conststr or v.tk
            if is_metamethod then
               if not def.meta_fields then
                  def.meta_fields = {}
                  def.meta_field_order = {}
               end
               if not metamethod_names[field_name] then
                  fail(ps, i - 1, "not a valid metamethod: " .. field_name)
               end
            end

            if ps.tokens[i].tk == "=" and ps.tokens[i + 1].tk == "macroexp" then
               local tt = t is GenericType and t.t or t

               if tt is FunctionType then
                  i, tt.macroexp = parse_macroexp(ps, i + 1, i + 2)
               else
                  fail(ps, i + 1, "macroexp must have a function type")
               end
            end

            if optional then
               t = optional_field_type(ps, type_at, t)
            end

            store_field_in_record(ps, iv, field_name, t, def, comments, is_metamethod and "meta" or nil)
         elseif ps.tokens[i].tk == "=" then
            local next_word = ps.tokens[i + 1].tk
            if next_word == "record" or next_word == "enum" then
               return fail(ps, i, "syntax error: this syntax is no longer valid; use '" .. next_word .. " " .. v.tk .. "'")
            elseif next_word == "functiontype" then
               return fail(ps, i, "syntax error: this syntax is no longer valid; use 'type " .. v.tk .. " = function('...")
            else
               return fail(ps, i, "syntax error: this syntax is no longer valid; use 'type " .. v.tk .. " = '...")
            end
         else
            fail(ps, i, "syntax error: expected ':' for an attribute or '=' for a nested type")
         end
      end
   end
   return i, true
end

parse_type_body_fns = {
   ["interface"] = parse_record_body,
   ["record"] = parse_record_body,
   ["enum"] = parse_enum_body,
}

local function parse_newtype(ps: ParseState, i: integer): integer, Node
   local node: Node = new_node(ps, i, "newtype")
   local def: FirstClassType
   local tn = ps.tokens[i].tk as BodyTypeName
   local istart = i

   if parse_type_body_fns[tn] then
      i, def = parse_type_body(ps, i + 1, istart, node, tn)
   else
      i, def = parse_type(ps, i)
   end
   if not def then
      return fail(ps, i, "expected a type")
   end

   node.newtype = new_typedecl(ps, istart, def)

   if def is NominalType then
      node.newtype.is_alias = true
   elseif def is GenericType then
      local deft = def.t
      if deft is NominalType then
         node.newtype.is_alias = true
      end
   end

   return i, node
end

local function parse_assignment_expression_list(ps: ParseState, i: integer, asgn: Node): integer, Node
   asgn.exps = new_node(ps, i, "expression_list")
   repeat
      i = i + 1
      local val: Node
      i, val = parse_expression(ps, i)
      if not val then
         if #asgn.exps == 0 then
            asgn.exps = nil
         end
         return i
      end
      table.insert(asgn.exps, val)
   until ps.tokens[i].tk ~= ","
   return i, asgn
end

local parse_call_or_assignment: function(ps: ParseState, i: integer): integer, Node
do
   local function is_lvalue(node: Node): boolean
      node.is_lvalue = node.kind == "variable"
                       or (node.kind == "op"
                           and (node.op.op == "@index" or node.op.op == "."))
      return node.is_lvalue
   end

   local function parse_variable(ps: ParseState, i: integer): integer, Node, integer
      local node: Node
      i, node = parse_expression(ps, i)
      if not (node and is_lvalue(node)) then
         return fail(ps, i, "expected a variable")
      end
      return i, node
   end

   parse_call_or_assignment = function(ps: ParseState, i: integer): integer, Node
      local exp: Node
      local istart = i
      i, exp = parse_expression(ps, i)
      if not exp then
         return i
      end

      if node_is_funcall(exp) or exp.failstore then
         return i, exp
      end

      if not is_lvalue(exp) then
         return fail(ps, i, "syntax error")
      end

      local asgn: Node = new_node(ps, istart, "assignment")
      asgn.vars = new_node(ps, istart, "variable_list")
      asgn.vars[1] = exp
      if ps.tokens[i].tk == "," then
         i = i + 1
         i = parse_trying_list(ps, i, asgn.vars, parse_variable)
         if #asgn.vars < 2 then
            return fail(ps, i, "syntax error")
         end
      end

      if ps.tokens[i].tk ~= "=" then
         verify_tk(ps, i, "=")
         return i
      end

      i, asgn = parse_assignment_expression_list(ps, i, asgn)
      return i, asgn
   end
end

local function parse_variable_declarations(ps: ParseState, i: integer, node_name: NodeKind): integer, Node
   local asgn: Node = new_node(ps, i, node_name)

   asgn.vars = new_node(ps, i, "variable_list")
   i = parse_trying_list(ps, i, asgn.vars, parse_variable_name)
   if #asgn.vars == 0 then
      return fail(ps, i, "expected a local variable definition")
   end

   i, asgn.decltuple = parse_type_list(ps, i, "decltuple")

   if ps.tokens[i].tk == "=" then
      -- produce nice error message when using <= 0.7.1 syntax
      local next_word = ps.tokens[i + 1].tk
      local tn = next_word as BodyTypeName
      if parse_type_body_fns[tn] and is_old_type_syntax(ps, i + 1) then
         local scope = node_name == "local_declaration" and "local" or "global"
         return failskip(ps, i + 1, "syntax error: this syntax is no longer valid; use '" .. scope .. " " .. next_word .. " " .. asgn.vars[1].tk .. "'", skip_type_body)
      -- `functiontype(n)` and `functiontype()` read both ways, as a
      -- function type and as a call of a function the name holds, and
      -- stay the type: every old declaration is spelled so, and would
      -- lose its hint to a reading that serves only a variable named
      -- for that keyword.
      elseif next_word == "functiontype" and ps.tokens[i + 2].tk == "("
         and look_ahead(ps, i + 1, parse_function_type) ~= nil then
         local scope = node_name == "local_declaration" and "local" or "global"
         return failskip(ps, i + 1, "syntax error: this syntax is no longer valid; use '" .. scope .. " type " .. asgn.vars[1].tk .. " = function('...", parse_function_type as SkipFunction)
      end

      i, asgn = parse_assignment_expression_list(ps, i, asgn)
   end
   return i, asgn
end

local function parse_type_require(ps: ParseState, i: integer, asgn: Node): integer, Node
   local istart = i
   i, asgn.value = parse_expression(ps, i)
   if not asgn.value then
      return i
   end
   if asgn.value.op and asgn.value.op.op ~= "@funcall" and asgn.value.op.op ~= "." then
      fail(ps, istart, "require() in type declarations cannot be part of larger expressions")
      return i
   end
   if not node_is_require_call(asgn.value) then
      fail(ps, istart, "require() for type declarations must have a literal argument")
      return i
   end
   return i, asgn
end

local function parse_special_type_declaration(ps: ParseState, i: integer, asgn: Node): boolean, integer, Node
   if ps.tokens[i].tk == "require" then
      return true, parse_type_require(ps, i, asgn)
   elseif ps.tokens[i].tk == "pcall" then
      fail(ps, i, "pcall() cannot be used in type declarations")
      return true, i
   end
   return false, i, asgn
end

parse_type_declaration = function(ps: ParseState, i: integer, node_name: NodeKind): integer, Node
   local asgn: Node = new_node(ps, i, node_name)
   local var: Node

   i, var = verify_kind(ps, i, "identifier")
   if not var then
      return fail(ps, i, "expected a type name")
   end
   local typeargs: {TypeArgType}
   local itypeargs = i
   refuse_type_named_never(ps, itypeargs - 1, var.tk)
   i, typeargs = parse_typeargs_if_any(ps, i)

   asgn.var = var

   if node_name == "global_type" and ps.tokens[i].tk ~= "=" then
      return i, asgn
   end

   i = verify_tk(ps, i, "=")
   local istart = i

   if ps.tokens[i].kind == "identifier" then
      local is_done: boolean
      is_done, i, asgn = parse_special_type_declaration(ps, i, asgn)
      if is_done then
         return i, asgn
      end
   end

   i, asgn.value = parse_newtype(ps, i)
   if not asgn.value then
      return i
   end

   local nt = asgn.value.newtype
   if nt is TypeDeclType then
      if typeargs then
         local def = nt.def
         if def is GenericType then
            fail(ps, itypeargs, "cannot declare type arguments twice in type declaration")
         else
            nt.def = new_generic(ps, istart, typeargs, def)
         end
      end

      set_declname(nt.def, asgn.var.tk)
   end

   return i, asgn
end

local function parse_type_constructor(ps: ParseState, i: integer, node_name: NodeKind, tn: BodyTypeName): integer, Node
   local asgn: Node = new_node(ps, i, node_name)
   local nt: Node = new_node(ps, i, "newtype")
   asgn.value = nt
   local istart = i
   local def: Type

   i = i + 2 -- skip `local` or `global`, and the constructor name

   i, asgn.var = verify_kind(ps, i, "identifier")
   if not asgn.var then
      return fail(ps, i, "expected a type name")
   end
   refuse_type_named_never(ps, i - 1, asgn.var.tk)

   i, def = parse_type_body(ps, i, istart, nt, tn)
   if not def then
      return i
   end

   set_declname(def, asgn.var.tk)

   nt.newtype = new_typedecl(ps, istart, def)

   return i, asgn
end

local function skip_type_declaration(ps: ParseState, i: integer): integer, Node
   return parse_type_declaration(ps, i + 1, "local_type")
end

local function parse_local_macroexp(ps: ParseState, i: integer): integer, Node
   local istart = i
   i = i + 2 -- skip `local`
   local node = new_node(ps, i, "local_macroexp")
   i, node.name = parse_identifier(ps, i)
   i, node.macrodef = parse_macroexp(ps, istart, i)
   end_at(node, ps.tokens[i - 1])
   return i, node
end

local function parse_local(ps: ParseState, i: integer): integer, Node
   local comments = get_attached_comments(ps.tokens[i])
   local ntk = ps.tokens[i + 1].tk
   local tn = ntk as TypeName

   local node: Node
   if ntk == "function" then
      i, node = parse_local_function(ps, i)
   elseif ntk == "type" and ps.tokens[i + 2].kind == "identifier" then
      i, node = parse_type_declaration(ps, i + 2, "local_type")
   elseif ntk == "macroexp" and ps.tokens[i+2].kind == "identifier" then
      i, node = parse_local_macroexp(ps, i)
   elseif parse_type_body_fns[tn as BodyTypeName] and ps.tokens[i+2].kind == "identifier" then
      i, node = parse_type_constructor(ps, i, "local_type", tn as BodyTypeName)
   else
      i, node = parse_variable_declarations(ps, i + 1, "local_declaration")
   end
   if node then
      node.comments = comments
   end
   return i, node
end

local function parse_global(ps: ParseState, i: integer): integer, Node
   local comments = get_attached_comments(ps.tokens[i])
   local ntk = ps.tokens[i + 1].tk
   local tn = ntk as TypeName

   local node: Node
   if ntk == "function" then
      i, node = parse_function(ps, i + 1, "global")
   elseif ntk == "type" and ps.tokens[i + 2].kind == "identifier" then
      i, node = parse_type_declaration(ps, i + 2, "global_type")
   elseif parse_type_body_fns[tn as BodyTypeName] and ps.tokens[i+2].kind == "identifier" then
      i, node = parse_type_constructor(ps, i, "global_type", tn as BodyTypeName)
   elseif ps.tokens[i+1].kind == "identifier" then
      i, node = parse_variable_declarations(ps, i + 1, "global_declaration")
   else
      return parse_call_or_assignment(ps, i) -- global is a soft keyword
   end
   if node then
      node.comments = comments
   end
   return i, node
end

local function parse_record_function(ps: ParseState, i: integer): integer, Node
   local comments = get_attached_comments(ps.tokens[i])
   local node: Node
   i, node = parse_function(ps, i, "record")
   if node then
      node.comments = comments
   end
   return i, node
end

local function parse_pragma(ps: ParseState, i: integer): integer, Node
   i = i + 1 -- skip "--#pragma"
   local pragma = new_node(ps, i, "pragma")

   if ps.tokens[i].kind ~= "pragma_identifier" then
      return fail(ps, i, "expected pragma name")
   end
   pragma.pkey = ps.tokens[i].tk
   i = i + 1

   if ps.tokens[i].kind ~= "pragma_identifier" then
      return fail(ps, i, "expected pragma value")
   end
   pragma.pvalue = ps.tokens[i].tk
   i = i + 1

   return i, pragma
end

local parse_statement_fns: {string : function(ParseState, integer):(integer, Node)} = {
   ["--#pragma"] = parse_pragma,
   ["::"] = parse_label,
   ["do"] = parse_do,
   ["if"] = parse_if,
   ["for"] = parse_for,
   ["goto"] = parse_goto,
   ["local"] = parse_local,
   ["while"] = parse_while,
   ["break"] = parse_break,
   ["global"] = parse_global,
   ["repeat"] = parse_repeat,
   ["return"] = parse_return,
   ["function"] = parse_record_function,
}

local function type_needs_local_or_global(ps: ParseState, i: integer): integer, Node
   local tk = ps.tokens[i].tk
   return failskip(ps, i, ("%s needs to be declared with 'local %s' or 'global %s'"):format(tk, tk, tk), skip_type_body, nil,
      { code = "declaration_scope", key = tk } as Error)
end

local needs_local_or_global: {string : function(ParseState, integer):(integer, Node)} = {
   ["type"] = function(ps: ParseState, i: integer): integer, Node
      return failskip(ps, i, "types need to be declared with 'local type' or 'global type'", skip_type_declaration)
   end,
   ["record"] = type_needs_local_or_global,
   ["enum"] = type_needs_local_or_global,
}

local function store_unattached_comments(node: Node, token: Token, item: Node)
   for _, tc in ipairs(token.comments) do
      local is_attached = false
      if item.comments then
         for _, nc in ipairs(item.comments) do
            if tc == nc then
               is_attached = true
               break
            end
         end
      end
      if not is_attached then
         if not node.unattached_comments then
            node.unattached_comments = {}
         end
         table.insert(node.unattached_comments, tc)
      else
         break
      end
   end
end

parse_statements = function(ps: ParseState, i: integer, toplevel?: boolean): integer, Node
   local node = new_node(ps, i, "statements")
   local item: Node = nil
   while true do
      while ps.tokens[i].kind == ";" do
         i = i + 1
         if item then
            item.semicolon = true
         end
      end

      if ps.tokens[i].kind == "$EOF$" then
         break
      end
      local token = ps.tokens[i]
      local tk = token.tk
      if (not toplevel) and stop_statement_list[tk] then
         break
      end

      local fn = parse_statement_fns[tk]
      if not fn then
         local skip_fn = needs_local_or_global[tk]
         if skip_fn and ps.tokens[i + 1].kind == "identifier" then
            fn = skip_fn
         else
            fn = parse_call_or_assignment
         end
      end

      i, item = fn(ps, i)

      if item then
         if toplevel and token.comments then
            store_unattached_comments(node, token, item)
         end
         table.insert(node, item)
      elseif i > 1 then
         -- heuristic to resync at the next line after an invalid statement
         local lasty = ps.tokens[i - 1].y
         while ps.tokens[i].kind ~= "$EOF$" and ps.tokens[i].y == lasty do
            i = i + 1
         end
      end
   end

   end_at(node, ps.tokens[i])
   return i, node
end

function tl.parse_program(tokens: {Token}, errs: {Error}, filename?: string, parse_lang?: ParseLang): tl.Node, {string}
   errs = errs or {}
   local ps: ParseState = {
      tokens = tokens as {Token},
      errs = errs,
      filename = filename or "",
      required_modules = {},
      parse_lang = parse_lang,
   }
   local i = 1
   local hashbang: string = nil
   if ps.tokens[i].kind == "hashbang" then
      hashbang = ps.tokens[i].tk
      i = i + 1
   end
   local _, node = parse_statements(ps, i, true)
   if hashbang then
      node.hashbang = hashbang
   end

   clear_redundant_errors(errs)
   return node, ps.required_modules
end

function tl.parse(input: string, filename: string, parse_lang?: ParseLang): tl.Node, {Error}, {string}
   local tokens, errs = tl.lex(input, filename)
   local node, required_modules = tl.parse_program(tokens, errs, filename, parse_lang)
   return node, errs, required_modules
end

end ----------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- AST traversal
--------------------------------------------------------------------------------

local record VisitorCallbacks<S, N, T>
   before: function(S, N)
   before_exp: function(S, {N}, {T})
   before_arguments: function(S, {N}, {T})
   before_statements: function(S, {N}, {T})
   before_e2: function(S, {N}, {T})
   after: function(S, N, {T}): T
end

local enum VisitorExtraCallback
   "before_arguments"
   "before_statements"
   "before_exp"
   "before_e2"
end

local type VisitorAfter = function<S, N, T>(S, N, {T}, T): T

local record Visitor<S, K, N, T>
   cbs: {K:VisitorCallbacks<S, N, T>}
   after: VisitorAfter<S, N, T>
   allow_missing_cbs: boolean
end

local function fields_of(t: RecordLikeType, meta?: MetaMode): (function(): string, Type)
   local i = 1
   local field_order, fields: {string}, {string:Type}
   if meta then
      field_order, fields = t.meta_field_order, t.meta_fields
   else
      field_order, fields = t.field_order, t.fields
   end
   if not fields then
      return function(): string, Type
      end
   end
   return function(): string, Type
      local name = field_order[i]
      if not name then
         return nil
      end
      i = i + 1
      return name, fields[name]
   end
end

local tl_debug_indent = 0
local record DebugEntry
   mark: string
   y: integer
   x: integer
   msg: string
end
local tl_debug_entry: DebugEntry = nil
local tl_debug_y = 1

local function tl_debug_loc(y: integer, x: integer): string
   return (tostring(y) or "?") .. ":" .. (tostring(x) or "?")
end

local function tl_debug_indent_push(mark: string, y: integer, x: integer, fmt: string, ...: any)
   if tl_debug_entry then
      if tl_debug_entry.y and (tl_debug_entry.y > tl_debug_y) then
         io.stderr:write("\n")
         tl_debug_y = tl_debug_entry.y
      end
      io.stderr:write(("   "):rep(tl_debug_indent) .. tl_debug_entry.mark .. " " ..
                      tl_debug_loc(tl_debug_entry.y, tl_debug_entry.x) .. " " ..
                      tl_debug_entry.msg .. "\n")
      io.stderr:flush()
      tl_debug_entry = nil
      tl_debug_indent = tl_debug_indent + 1
   end
   tl_debug_entry = {
      mark = mark,
      y = y,
      x = x,
      msg = fmt:format(...)
   }
end

local function tl_debug_indent_pop(mark: string, single: string, y: integer, x: integer, fmt?: string, ...: any)
   if tl_debug_entry then
      local msg = tl_debug_entry.msg
      if fmt then
         msg = fmt:format(...)
      end
      if y and (y > tl_debug_y) then
         io.stderr:write("\n")
         tl_debug_y = y
      end
      io.stderr:write(("   "):rep(tl_debug_indent) .. single .. " " .. tl_debug_loc(y, x) .. " " .. msg .. "\n")
      io.stderr:flush()
      tl_debug_entry = nil
   else
      tl_debug_indent = tl_debug_indent - 1
      if fmt then
         io.stderr:write(("   "):rep(tl_debug_indent) .. mark .. " " .. fmt:format(...) .. "\n")
         io.stderr:flush()
      end
   end
end

local recurse_type: function<S, T>(s: S, ast: Type, visit: Visitor<S, TypeName, Type, T>): T = nil

local function aggregate_type_walker<S, T>(s: S, ast: AggregateType, visit: Visitor<S, TypeName, Type, T>): {T}
   local xs: {T} = {}
   for i, child in ipairs(ast.types) do
      xs[i] = recurse_type(s, child, visit)
   end
   return xs
end

local function record_like_type_walker<S, T>(s: S, ast: RecordLikeType, visit: Visitor<S, TypeName, Type, T>): {T}
   local xs: {T} = {}
   if ast.interface_list then
      for _, child in ipairs(ast.interface_list) do
         table.insert(xs, recurse_type(s, child, visit))
      end
   end
   if ast.elements then
      table.insert(xs, recurse_type(s, ast.elements, visit))
   end
   if ast.fields then
      for _, child in fields_of(ast) do
         table.insert(xs, recurse_type(s, child, visit))
      end
   end
   if ast.meta_fields then
      for _, child in fields_of(ast, "meta") do
         table.insert(xs, recurse_type(s, child, visit))
      end
   end
   return xs
end

local type_walkers <total>: {TypeName: boolean | function<S, T>(s: S, ast: Type, visit: Visitor<S, TypeName, Type, T>): {T}} = {
   ["typevar"] = false,
   ["unresolved_typearg"] = false,
   ["unresolvable_typearg"] = false,
   ["self"] = false,
   ["enum"] = false,
   ["boolean"] = false,
   ["string"] = false,
   ["nil"] = false,
   ["thread"] = false,
   ["userdata"] = false,
   ["number"] = false,
   ["integer"] = false,
   ["circular_require"] = false,
   ["boolean_context"] = false,
   ["emptytable"] = false,
   ["unresolved_emptytable_value"] = false,
   ["any"] = false,
   ["unknown"] = false,
   ["invalid"] = false,
   ["none"] = false,
   ["*"] = false,

   ["generic"] = function<S, T>(s: S, ast: GenericType, visit: Visitor<S, TypeName, Type, T>): {T}
      local xs: {T} = {}
      for _, child in ipairs(ast.typeargs) do
         table.insert(xs, recurse_type(s, child, visit))
      end
      table.insert(xs, recurse_type(s, ast.t, visit))
      return xs
   end,
   ["tuple"] = function<S, T>(s: S, ast: TupleType, visit: Visitor<S, TypeName, Type, T>): {T}
      local xs: {T} = {}
      for i, child in ipairs(ast.tuple) do
         xs[i] = recurse_type(s, child, visit)
      end
      return xs
   end,
   ["union"] = aggregate_type_walker,
   ["tupletable"] = aggregate_type_walker,
   ["poly"] = aggregate_type_walker,
   ["map"] = function<S, T>(s: S, ast: MapType, visit: Visitor<S, TypeName, Type, T>): {T}
      return {
         recurse_type(s, ast.keys, visit),
         recurse_type(s, ast.values, visit),
      }
   end,
   ["record"] = record_like_type_walker,
   ["interface"] = record_like_type_walker,
   ["function"] = function<S, T>(s: S, ast: FunctionType, visit: Visitor<S, TypeName, Type, T>): {T}
      local xs: {T} = {}
      if ast.args then
         for _, child in ipairs(ast.args.tuple) do
            table.insert(xs, recurse_type(s, child, visit))
         end
      end
      if ast.rets then
         for _, child in ipairs(ast.rets.tuple) do
            table.insert(xs, recurse_type(s, child, visit))
         end
      end
      return xs
   end,
   ["nominal"] = function<S, T>(s: S, ast: NominalType, visit: Visitor<S, TypeName, Type, T>): {T}
      local xs: {T} = {}
      if ast.typevals then
         for _, child in ipairs(ast.typevals) do
            table.insert(xs, recurse_type(s, child, visit))
         end
      end
      return xs
   end,
   ["typearg"] = function<S, T>(s: S, ast: TypeArgType, visit: Visitor<S, TypeName, Type, T>): {T}
      return {
         ast.constraint and recurse_type(s, ast.constraint, visit)
      }
   end,
   ["array"] = function<S, T>(s: S, ast: ArrayType, visit: Visitor<S, TypeName, Type, T>): {T}
      return {
         recurse_type(s, ast.elements, visit)
      }
   end,
   ["literal_table_item"] = function<S, T>(s: S, ast: LiteralTableItemType, visit: Visitor<S, TypeName, Type, T>): {T}
      return {
         recurse_type(s, ast.ktype, visit),
         recurse_type(s, ast.vtype, visit),
      }
   end,
   ["typedecl"] = function<S, T>(s: S, ast: TypeDeclType, visit: Visitor<S, TypeName, Type, T>): {T}
      return {
         recurse_type(s, ast.def, visit)
      }
   end,
}

recurse_type = function<S, T>(s: S, ast: Type, visit: Visitor<S, TypeName, Type, T>): T
   local kind = ast.typename

   if TL_DEBUG then
      tl_debug_indent_push("---", ast.y, ast.x, "[%s] = %s", kind, show_type(ast))
   end

   local cbs = visit.cbs
   local cbkind = cbs and cbs[kind]
   if cbkind then
      local cbkind_before = cbkind.before
      if cbkind_before then
         cbkind_before(s, ast)
      end
   end

   local xs: {T} = nil
   local walker = type_walkers[ast.typename]
   if not walker is boolean then
      xs = walker(s, ast, visit)
   end

   local ret: T = nil
   local cbkind_after = cbkind and cbkind.after
   if cbkind_after then
      ret = cbkind_after(s, ast, xs)
   end
   local visit_after = visit.after
   if visit_after then
      ret = visit_after(s, ast, xs, ret)
   end

   if TL_DEBUG then
      tl_debug_indent_pop("---", "---", ast.y, ast.x)
   end

   return ret
end

local function recurse_typeargs<S, T>(s: S, ast: Node, visit_type: Visitor<S, TypeName, Type, T>)
   if ast.typeargs then
      for _, typearg in ipairs(ast.typeargs) do
         recurse_type(s, typearg, visit_type)
      end
   end
end

local function extra_callback<S, T>(name: VisitorExtraCallback,
                                    s: S,
                                    ast: Node,
                                    xs: {T},
                                    visit_node: Visitor<S, NodeKind, Node, T>)
   local cbs = visit_node.cbs
   if not cbs then return end
   local nbs = cbs[ast.kind]
   if not nbs then return end
   local bs = nbs[name]
   if not bs then return end
   bs(s, ast, xs)
end

local no_recurse_node: {NodeKind : boolean} = {
   ["..."] = true,
   ["nil"] = true,
   ["cast"] = true,
   ["goto"] = true,
   ["break"] = true,
   ["label"] = true,
   ["number"] = true,
   ["pragma"] = true,
   ["string"] = true,
   ["boolean"] = true,
   ["integer"] = true,
   ["variable"] = true,
   ["error_node"] = true,
   ["identifier"] = true,
   ["type_identifier"] = true,
}

local function recurse_node<S, T>(s: S, root: tl.Node,
                                  visit_node: Visitor<S, NodeKind, Node, T>,
                                  visit_type: Visitor<S, TypeName, Type, T>): T
   if not root then
      -- parse error
      return
   end

   local recurse: function(tl.Node): T = nil

   local function walk_children(ast: Node, xs: {T})
      for i, child in ipairs(ast) do
         xs[i] = recurse(child)
      end
   end

   local function walk_vars_exps(ast: Node, xs: {T})
      xs[1] = recurse(ast.vars)
      if ast.decltuple then
         xs[2] = recurse_type(s, ast.decltuple, visit_type)
      end
      extra_callback("before_exp", s, ast, xs, visit_node)
      if ast.exps then
         xs[3] = recurse(ast.exps)
      end
   end

   local function walk_named_function(ast: Node, xs: {T})
      recurse_typeargs(s, ast, visit_type)
      xs[1] = recurse(ast.name)
      xs[2] = recurse(ast.args)
      xs[3] = recurse_type(s, ast.rets, visit_type)
      extra_callback("before_statements", s, ast, xs, visit_node)
      xs[4] = recurse(ast.body)
   end

   local walkers: {NodeKind : function(Node, {T})} = {
      ["op"] = function(ast: Node, xs: {T})
         xs[1] = recurse(ast.e1)
         local p1 = ast.e1.op and ast.e1.op.prec or nil
         if ast.op.op == ":" and ast.e1.kind == "string" then
            p1 = -999
         end
         xs[2] = p1 as T
         if ast.op.arity == 2 then
            extra_callback("before_e2", s, ast, xs, visit_node)
            if ast.op.op == "is" or ast.op.op == "as" then
               xs[3] = recurse_type(s, ast.e2.casttype, visit_type)
            else
               xs[3] = recurse(ast.e2)
            end
            xs[4] = (ast.e2.op and ast.e2.op.prec) as T
         end
      end,

      ["statements"] = walk_children,
      ["argument_list"] = walk_children,
      ["literal_table"] = walk_children,
      ["variable_list"] = walk_children,
      ["expression_list"] = walk_children,

      ["literal_table_item"] = function(ast: Node, xs: {T})
         xs[1] = recurse(ast.key)
         xs[2] = recurse(ast.value)
         if ast.itemtype then
            xs[3] = recurse_type(s, ast.itemtype, visit_type)
         end
      end,

      ["assignment"] = walk_vars_exps,
      ["local_declaration"] = walk_vars_exps,
      ["global_declaration"] = walk_vars_exps,

      ["local_type"] = function(ast: Node, xs: {T})
         -- TODO need to recurse typeargs
         -- recurse_typeargs(s, ast, visit_type)
         xs[1] = recurse(ast.var)
         xs[2] = recurse(ast.value)
      end,

      ["global_type"] = function(ast: Node, xs: {T})
         -- TODO need to recurse typeargs
         -- recurse_typeargs(s, ast, visit_type)
         xs[1] = recurse(ast.var)
         if ast.value then
            xs[2] = recurse(ast.value)
         end
      end,

      ["if"] = function(ast: Node, xs: {T})
         for _, e in ipairs(ast.if_blocks) do
            table.insert(xs, recurse(e))
         end
      end,

      ["if_block"] = function(ast: Node, xs: {T})
         if ast.exp then
            xs[1] = recurse(ast.exp)
         end
         extra_callback("before_statements", s, ast, xs, visit_node)
         xs[2] = recurse(ast.body)
      end,

      ["while"] = function(ast: Node, xs: {T})
         xs[1] = recurse(ast.exp)
         extra_callback("before_statements", s, ast, xs, visit_node)
         xs[2] = recurse(ast.body)
      end,

      ["repeat"] = function(ast: Node, xs: {T})
         xs[1] = recurse(ast.body)
         xs[2] = recurse(ast.exp)
      end,

      ["macroexp"] = function(ast: Node, xs: {T})
         recurse_typeargs(s, ast, visit_type)
         xs[1] = recurse(ast.args)
         xs[2] = recurse_type(s, ast.rets, visit_type)
         extra_callback("before_exp", s, ast, xs, visit_node)
         xs[3] = recurse(ast.exp)
      end,

      ["function"] = function(ast: Node, xs: {T})
         recurse_typeargs(s, ast, visit_type)
         xs[1] = recurse(ast.args)
         xs[2] = recurse_type(s, ast.rets, visit_type)
         extra_callback("before_statements", s, ast, xs, visit_node)
         xs[3] = recurse(ast.body)
      end,
      ["local_function"] = walk_named_function,
      ["global_function"] = walk_named_function,
      ["record_function"] = function(ast: Node, xs: {T})
         recurse_typeargs(s, ast, visit_type)
         xs[1] = recurse(ast.fn_owner)
         xs[2] = recurse(ast.name)
         extra_callback("before_arguments", s, ast, xs, visit_node)
         xs[3] = recurse(ast.args)
         xs[4] = recurse_type(s, ast.rets, visit_type)
         extra_callback("before_statements", s, ast, xs, visit_node)
         xs[5] = recurse(ast.body)
      end,
      ["local_macroexp"] = function(ast: Node, xs: {T})
         -- TODO: the type arguments of `ast.macrodef` are not walked, so a
         -- generic `local macroexp` is visited without them. The fix is a
         -- `recurse_typeargs(s, ast.macrodef, visit_type)` first, as the
         -- `macroexp` walker above does.
         xs[1] = recurse(ast.name)
         xs[2] = recurse(ast.macrodef.args)
         xs[3] = recurse_type(s, ast.macrodef.rets, visit_type)
         extra_callback("before_exp", s, ast, xs, visit_node)
         xs[4] = recurse(ast.macrodef.exp)
      end,

      ["forin"] = function(ast: Node, xs: {T})
         xs[1] = recurse(ast.vars)
         xs[2] = recurse(ast.exps)
         extra_callback("before_statements", s, ast, xs, visit_node)
         xs[3] = recurse(ast.body)
      end,

      ["fornum"] = function(ast: Node, xs: {T})
         xs[1] = recurse(ast.var)
         xs[2] = recurse(ast.from)
         xs[3] = recurse(ast.to)
         xs[4] = ast.step and recurse(ast.step)
         extra_callback("before_statements", s, ast, xs, visit_node)
         xs[5] = recurse(ast.body)
      end,

      ["return"] = function(ast: Node, xs: {T})
         xs[1] = recurse(ast.exps)
      end,

      ["do"] = function(ast: Node, xs: {T})
         xs[1] = recurse(ast.body)
      end,

      ["paren"] = function(ast: Node, xs:{T})
         xs[1] = recurse(ast.e1)
      end,

      ["newtype"] = function(ast: Node, xs:{T})
         xs[1] = recurse_type(s, ast.newtype, visit_type)
      end,

      ["argument"] = function(ast: Node, xs:{T})
         if ast.argtype then
            xs[1] = recurse_type(s, ast.argtype, visit_type)
         end
      end,
   }

   if not visit_node.allow_missing_cbs and not visit_node.cbs then
      error("missing cbs in visit_node")
   end
   local visit_after = visit_node.after

   recurse = function(ast: Node): T
      local xs: {T} = {}
      local kind = assert(ast.kind)
      local kprint: string = nil

      local cbs = visit_node.cbs
      local cbkind = cbs and cbs[kind]
      if cbkind then
         if cbkind.before then
            cbkind.before(s, ast)
         end
      end

      if TL_DEBUG then
         if ast.y > TL_DEBUG_MAXLINE then
            error("Halting execution at input line " .. ast.y)
         end
         kprint = kind == "op" and "op " .. ast.op.op
                  or kind == "identifier" and "identifier " .. ast.tk
                  or kind
         tl_debug_indent_push("{{{", ast.y, ast.x, "[%s]", kprint)
      end

      local fn = walkers[kind]
      if fn then
         fn(ast, xs)
      else
         assert(no_recurse_node[kind])
      end

      local ret: T = nil
      local cbkind_after = cbkind and cbkind.after
      if cbkind_after then
         ret = cbkind_after(s, ast, xs)
      end
      if visit_after then
         ret = visit_after(s, ast, xs, ret)
      end

      if TL_DEBUG then
         local typ = ast.debug_type and " = " .. show_type(ast.debug_type) or ""
         tl_debug_indent_pop("}}}", "***", ast.y, ast.x, "[%s]%s", kprint, typ)
      end

      return ret
   end

   return recurse(root)
end

--------------------------------------------------------------------------------
-- Lua code generation
--------------------------------------------------------------------------------

local tight_op: {integer:{string:boolean}} = {
   [1] = {
      ["-"] = true,
      ["~"] = true,
      ["#"] = true,
   },
   [2] = {
      ["."] = true,
      [":"] = true,
   },
}

local spaced_op: {integer:{string:boolean}} = {
   [1] = {
      ["not"] = true,
   },
   [2] = {
      ["or"] = true,
      ["and"] = true,
      ["<"] = true,
      [">"] = true,
      ["<="] = true,
      [">="] = true,
      ["~="] = true,
      ["=="] = true,
      ["|"] = true,
      ["~"] = true,
      ["&"] = true,
      ["<<"] = true,
      [">>"] = true,
      [".."] = true,
      ["+"] = true,
      ["-"] = true,
      ["*"] = true,
      ["/"] = true,
      ["//"] = true,
      ["%"] = true,
      ["^"] = true,
   },
}


local default_generate_opts: GenerateOptions = {
   preserve_indent = true,
   preserve_newlines = true,
   preserve_hashbang = false,
}

local fast_generate_opts: GenerateOptions = {
   preserve_indent = false,
   preserve_newlines = true,
   preserve_hashbang = false,
}

local primitive: {TypeName:string} = {
   ["function"] = "function",
   ["enum"] = "string",
   ["boolean"] = "boolean",
   ["string"] = "string",
   ["nil"] = "nil",
   ["number"] = "number",
   ["integer"] = "number",
   ["thread"] = "thread",
}

function tl.generate(ast: tl.Node, gen_target: GenTarget, opts?: GenerateOptions): string, string
   local err: string = nil
   local indent = 0

   opts = opts or default_generate_opts

   local record Output
      {string}
      y: integer
      h: integer
   end

   local save_indent: {integer} = {}

   local function increment_indent(_: nil, node: Node)
      local child = node.body or node[1]
      if not child then
         return
      end
      if child.y ~= node.y then
         if indent == 0 and #save_indent > 0 then
            indent = save_indent[#save_indent] + 1
         else
            indent = indent + 1
         end
      else
         table.insert(save_indent, indent)
         indent = 0
      end
   end

   local function decrement_indent(node: Node, child: Node)
      if child.y ~= node.y then
         indent = indent - 1
      else
         indent = table.remove(save_indent)
      end
   end

   if not opts.preserve_indent then
      increment_indent = nil
      decrement_indent = function() end
   end

   local function add_string(out: Output, s: string)
      table.insert(out, s)
      if string.find(s, "\n", 1, true) then
         for _nl in s:gmatch("\n") do
            out.h = out.h + 1
         end
      end
   end

   local function add_child(out: Output, child: Output, space?: string, current_indent?: integer): integer
      if #child == 0 then
         return
      end

      if child.y ~= -1 and child.y < out.y then
         out.y = child.y
      end

      if child.y > out.y + out.h and opts.preserve_newlines then
         local delta = child.y - (out.y + out.h)
         out.h = out.h + delta
         table.insert(out, ("\n"):rep(delta))
      else
         if space then
            if space ~= "" then
               table.insert(out, space)
            end
            current_indent = nil
         end
      end
      if current_indent and opts.preserve_indent then
         table.insert(out, ("   "):rep(current_indent))
      end
      table.insert(out, child as string)
      out.h = out.h + child.h
   end

   local function concat_output(out: Output): string
      for i, s in ipairs(out) do
         if type(s) == "table" then
            out[i] = concat_output(s as Output)
         end
      end
      return table.concat(out)
   end

   local function print_record_def(typ: RecordLikeType): string
      local out: {string} = { "{" }
      local i = 0
      for fname, ftype in fields_of(typ) do
         if ftype is TypeDeclType then
            local def = ftype.def
            if def is GenericType then
               def = def.t
            end
            if def is RecordType then
               if i > 0 then
                  table.insert(out, ",")
               end
               i = i + 1
               table.insert(out, " ")
               table.insert(out, fname)
               table.insert(out, " = ")
               table.insert(out, print_record_def(def))
            end
         end
      end
      if i > 0 then
         table.insert(out, " ")
      end
      table.insert(out, "}")
      return table.concat(out)
   end

   local visit_node: Visitor<nil, NodeKind, Node, Output> = {}

   local lua_54_attribute <total>: {Attribute:string} = {
      ["const"] = " <const>",
      ["close"] = " <close>",
      ["total"] = " <const>",
   }

   local function emit_exactly(_: nil, node: Node, _children: {Output}): Output
      local out: Output = { y = node.y, h = 0 }
      add_string(out, node.tk)
      return out
   end

   local emit_exactly_visitor_cbs <const>: VisitorCallbacks<nil, Node, Output> = { after = emit_exactly }

   local emit_number_visitor_cbs <const>: VisitorCallbacks<nil, Node, Output> = {
      after = function(_: nil, node: Node, _children: {Output}): Output
         local out: Output = { y = node.y, h = 0 }
         add_string(out, (node.tk:gsub("_", "")))
         return out
      end
   }

   local emit_nothing_visitor_cbs <const>: VisitorCallbacks<nil, Node, Output> = {
      after = function(_: nil, node: Node, _children: {Output}): Output
         local out: Output = { y = node.y, h = 0 }
         return out
      end
   }

   local function starts_with_longstring(n: Node): boolean
      while n.e1 do n = n.e1 end
      return n.is_longstring
   end

   -- The run-time checks (CheckOptions.runtime_checks). Each is a call
   -- of the global `__cosmic_tc`, or of `select` where the program has
   -- none: `select(2, spec, ...)` answers the values after the spec, so
   -- a check the program cannot make leaves them as they were. `spec` is
   -- a string of fields joined by ";": the check's kind ("p" parameters,
   -- "r" return values, "f" a record field written), the file and line,
   -- and for each value its name and kinds. The line is that of the
   -- Lua written, which keeps the Teal's.
   local function runtime_spec(kind: string, node: Node, ...: string): string
      -- The file's name is written so that none of the characters that
      -- split a spec, or a report line, is in it: each is "%" and its
      -- hex.
      local file = ((ast as Node).rt_file or "?"):gsub("[%%;\t\r\n]", function(c: string): string
         return string.format("%%%02X", string.byte(c))
      end)
      local fields: {string} = { kind, file .. ":" .. node.y, ... }
      return string.format("%q", table.concat(fields, ";"))
   end

   local function parameter_check(node: Node, name: string): string
      local checks: {string} = {}
      local names: {string} = {}
      if node.args then
         -- A name a function binds twice (`_: string, _: integer`) holds the
         -- last value of that name: the earlier is out of reach, so only the
         -- last is checked, against its own type.
         local last: {string:integer} = {}
         for i, arg in ipairs(node.args) do
            last[arg.tk] = i
         end
         for i, arg in ipairs(node.args) do
            if arg.rt_check and last[arg.tk] == i then
               table.insert(checks, arg.rt_check)
               table.insert(names, arg.tk)
            end
         end
      end
      if #checks == 0 then
         return ""
      end
      return " (__cosmic_tc or select)(2, " .. runtime_spec("p", node, name, table.unpack(checks))
         .. ", " .. table.concat(names, ", ") .. ");"
   end

   visit_node.cbs = {
      ["statements"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output
            if opts.preserve_hashbang and node.hashbang then
               out = { y = 1, h = 0 }
               table.insert(out, node.hashbang)
            else
               out = { y = node.y, h = 0 }
            end
            local space: string = nil
            for i, child in ipairs(children) do
               add_child(out, child, space, indent)
               if node[i].semicolon then
                  table.insert(out, ";")
                  space = " "
               else
                  space = "; "
               end
            end
            return out
         end
      },
      ["local_declaration"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "local ")
            for i, var in ipairs(node.vars) do
               if i > 1 then
                  add_string(out, ", ")
               end
               add_string(out, var.tk)
               if var.attribute then
                  if gen_target ~= "5.4" and var.attribute == "close" then
                     err = "attempt to emit a <close> attribute for a non 5.4 target"
                  end

                  if gen_target == "5.4" then
                     add_string(out, lua_54_attribute[var.attribute])
                  end
               end
            end
            if children[3] then
               table.insert(out, " =")
               add_child(out, children[3], " ")
            end
            return out
         end,
      },
      ["local_type"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if not node.var.elide_type then
               table.insert(out, "local")
               add_child(out, children[1], " ")
               table.insert(out, " =")
               add_child(out, children[2], " ")
            end
            return out
         end,
      },
      ["global_type"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if children[2] then
               add_child(out, children[1])
               table.insert(out, " =")
               add_child(out, children[2], " ")
            end
            return out
         end,
      },
      ["global_declaration"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if children[3] then
               add_child(out, children[1])
               table.insert(out, " =")
               add_child(out, children[3], " ")
            end
            return out
         end,
      },
      ["assignment"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            add_child(out, children[1])
            table.insert(out, " =")
            add_child(out, children[3], " ")
            return out
         end,
      },
      ["if"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            for i, child in ipairs(children) do
               add_child(out, child, i > 1 and " ", child.y ~= node.y and indent)
            end
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["if_block"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if node.if_block_n == 1 then
               table.insert(out, "if")
            elseif not node.exp then
               table.insert(out, "else")
            else
               table.insert(out, "elseif")
            end
            if node.exp then
               add_child(out, children[1], " ")
               table.insert(out, " then")
            end
            add_child(out, children[2], " ")
            decrement_indent(node, node.body)
            return out
         end,
      },
      ["while"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "while")
            add_child(out, children[1], " ")
            table.insert(out, " do")
            add_child(out, children[2], " ")
            decrement_indent(node, node.body)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["repeat"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "repeat")
            add_child(out, children[1], " ")
            decrement_indent(node, node.body)
            add_child(out, { y = node.yend, h = 0, [1] = "until " }, " ", indent)
            add_child(out, children[2])
            return out
         end,
      },
      ["do"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "do")
            add_child(out, children[1], " ")
            decrement_indent(node, node.body)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["forin"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "for")
            add_child(out, children[1], " ")
            table.insert(out, " in")
            add_child(out, children[2], " ")
            table.insert(out, " do")
            add_child(out, children[3], " ")
            decrement_indent(node, node.body)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["fornum"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "for")
            add_child(out, children[1], " ")
            table.insert(out, " =")
            add_child(out, children[2], " ")
            table.insert(out, ",")
            add_child(out, children[3], " ")
            if children[4] then
               table.insert(out, ",")
               add_child(out, children[4], " ")
            end
            table.insert(out, " do")
            add_child(out, children[5], " ")
            decrement_indent(node, node.body)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["return"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "return")
            if #children[1] > 0 then
               if node.rt_rets then
                  table.insert(out, " (__cosmic_tc or select)(2, "
                     .. runtime_spec("r", node, node.rt_rets) .. ",")
               end
               add_child(out, children[1], " ")
               if node.rt_rets then
                  table.insert(out, ")")
               end
            end
            return out
         end,
      },
      ["break"] = {
         after = function(_: nil, node: Node, _children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "break")
            return out
         end,
      },
      ["variable_list"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            local space: string = nil
            for i, child in ipairs(children) do
               if i > 1 then
                  table.insert(out, ",")
                  space = " "
               end
               if node.rt_set and node.rt_set[i] then
                  local checked: Output = { y = child.y, h = 0 }
                  table.insert(checked, "(__cosmic_tc or select)(2, "
                     .. runtime_spec("f", node[i], node.rt_set[i]) .. ", ")
                  add_child(checked, child)
                  table.insert(checked, ")")
                  child = checked
               end
               add_child(out, child, space, child.y ~= node.y and indent)
            end
            return out
         end,
      },
      ["literal_table"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if #children == 0 then
               table.insert(out, "{}")
               return out
            end
            table.insert(out, "{")
            local n = #children
            for i, child in ipairs(children) do
               add_child(out, child, " ", child.y ~= node.y and indent)
               if i < n or node.yend ~= node.y then
                  table.insert(out, ",")
               end
            end
            decrement_indent(node, node[1])
            add_child(out, { y = node.yend, h = 0, [1] = "}" }, " ", indent)
            return out
         end,
      },
      ["literal_table_item"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if node.key_parsed ~= "implicit" then
               if node.key_parsed == "short" then
                  children[1][1] = children[1][1]:sub(2, -2)
                  add_child(out, children[1])
                  table.insert(out, " = ")
               else
                  table.insert(out, "[")
                  if node.key_parsed == "long" and node.key.is_longstring then
                     table.insert(children[1], 1, " ")
                     table.insert(children[1], " ")
                  end
                  add_child(out, children[1])
                  table.insert(out, "] = ")
               end
            end
            add_child(out, children[2])
            return out
         end,
      },
      ["local_macroexp"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, _children: {Output}): Output
            return { y = node.y, h = 0 }
         end,
      },
      ["local_function"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "local function")
            add_child(out, children[1], " ")
            table.insert(out, "(")
            add_child(out, children[2])
            table.insert(out, ")")
            local check = parameter_check(node, node.name.tk)
            if check ~= "" then
               table.insert(out, check)
            end
            add_child(out, children[4], " ")
            decrement_indent(node, node.body)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["global_function"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "function")
            add_child(out, children[1], " ")
            table.insert(out, "(")
            add_child(out, children[2])
            table.insert(out, ")")
            local check = parameter_check(node, node.name.tk)
            if check ~= "" then
               table.insert(out, check)
            end
            add_child(out, children[4], " ")
            decrement_indent(node, node.body)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["record_function"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "function")
            add_child(out, children[1], " ")
            table.insert(out, node.is_method and ":" or ".")
            add_child(out, children[2])
            table.insert(out, "(")
            if node.is_method then
               -- remove self
               table.remove(children[3], 1)
               if children[3][1] == "," then
                  table.remove(children[3], 1)
                  if children[3][1] == " " then
                     table.remove(children[3], 1)
                  end
               end
            end
            add_child(out, children[3])
            table.insert(out, ")")
            local check = parameter_check(node, node.name.tk)
            if check ~= "" then
               table.insert(out, check)
            end
            add_child(out, children[5], " ")
            decrement_indent(node, node.body)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["function"] = {
         before = increment_indent,
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "function(")
            add_child(out, children[1])
            table.insert(out, ")")
            local check = parameter_check(node, "function")
            if check ~= "" then
               table.insert(out, check)
            end
            add_child(out, children[3], " ")
            decrement_indent(node, node.body)
            add_child(out, { y = node.yend, h = 0, [1] = "end" }, " ", indent)
            return out
         end,
      },
      ["paren"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "(")
            add_child(out, children[1], "", indent)
            table.insert(out, ")")
            return out
         end,
      },
      ["op"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            if node.op.op == "@funcall" then
               add_child(out, children[1], "", indent)
               table.insert(out, "(")
               add_child(out, children[3], "", indent)
               table.insert(out, ")")
            elseif node.op.op == "@index" then
               add_child(out, children[1], "", indent)
               table.insert(out, "[")
               if starts_with_longstring(node.e2) then
                  table.insert(children[3], 1, " ")
                  table.insert(children[3], " ")
               end
               add_child(out, children[3], "", indent)
               table.insert(out, "]")
            elseif node.op.op == "as" then
               add_child(out, children[1], "", indent)
            elseif node.op.op == "is" then
               if node.e2.casttype.typename == "integer" then
                  table.insert(out, "math.type(")
                  add_child(out, children[1], "", indent)
                  table.insert(out, ") == \"integer\"")
               elseif node.e2.casttype.typename == "nil" then
                  add_child(out, children[1], "", indent)
                  table.insert(out, " == nil")
               else
                  table.insert(out, "type(")
                  add_child(out, children[1], "", indent)
                  table.insert(out, ") == \"")
                  add_child(out, children[3], "", indent)
                  table.insert(out, "\"")
               end
            elseif spaced_op[node.op.arity][node.op.op] or tight_op[node.op.arity][node.op.op] then
               local space = spaced_op[node.op.arity][node.op.op] and " " or ""
               if children[2] and node.op.prec > tonumber(children[2]) then
                  table.insert(children[1], 1, "(")
                  table.insert(children[1], ")")
               end
               if node.op.arity == 1 then
                  table.insert(out, node.op.op)
                  add_child(out, children[1], space, indent)
               elseif node.op.arity == 2 then
                  add_child(out, children[1], "", indent)
                  if space == " " then
                     table.insert(out, " ")
                  end
                  table.insert(out, node.op.op)
                  if children[4] and node.op.prec > tonumber(children[4]) then
                     table.insert(children[3], 1, "(")
                     table.insert(children[3], ")")
                  end
                  add_child(out, children[3], space, indent)
               end
            else
               error("unknown node op " .. node.op.op)
            end
            return out
         end,
      },
      ["newtype"] = {
         after = function(_: nil, node: Node, _children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            local nt = node.newtype
            if nt is TypeDeclType then
               local def = nt.def
               if def is RecordLikeType then
                  table.insert(out, print_record_def(def))
               elseif def is NominalType then
                  table.insert(out, table.concat(def.names, "."))
               else
                  table.insert(out, "{}")
               end
            end
            return out
         end,
      },
      ["goto"] = {
         after = function(_: nil, node: Node, _children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "goto ")
            table.insert(out, node.label)
            return out
         end,
      },
      ["label"] = {
         after = function(_: nil, node: Node, _children: {Output}): Output
            local out: Output = { y = node.y, h = 0 }
            table.insert(out, "::")
            table.insert(out, node.label)
            table.insert(out, "::")
            return out
         end,
      },
      ["string"] = {
         after = function(_: nil, node: Node, children: {Output}): Output
            -- translate escape sequences not supported by Lua 5.1
            -- in particular:
            --  - \z : removes trailing whitespace
            --  - \xXX : hex byte
            --  - \u{} : unicode

            if node.tk:sub(1, 1) == "[" or gen_target ~= "5.1" or not node.tk:find("\\", 1, true) then
               return emit_exactly(nil, node, children)
            end

            local str = node.tk
            local replaced: {string} = {}

            local i = 1
            local currstrstart = 1
            while true do
               local slashpos = str:find("\\", i)
               if not slashpos then break end
               local nextc = str:sub(slashpos + 1, slashpos + 1)
               if nextc == "z" then
                  table.insert(replaced, str:sub(currstrstart, slashpos - 1))
                  local wsend = str:find("%S", slashpos + 2) -- next non-whitespace
                  currstrstart = wsend
                  i = currstrstart
               elseif nextc == "x" then
                  table.insert(replaced, str:sub(currstrstart, slashpos - 1))
                  local digits <const> = str:sub(slashpos + 2, slashpos + 3)
                  local byte <const> = tonumber(digits, 16)
                  table.insert(replaced, string.format("\\%03d", byte))
                  currstrstart = slashpos + 4
                  i = currstrstart
               elseif nextc == "u" then
                  table.insert(replaced, str:sub(currstrstart, slashpos - 1))
                  local _, e, hex_digits = str:find("{(.-)}", slashpos + 2)
                  local codepoint <const> = tonumber(hex_digits, 16)
                  local sequence <const> = utf8.char(codepoint)
                  table.insert(replaced, (sequence:gsub(".", function(c: string): string
                     return ("\\%03d"):format(string.byte(c))
                  end)))
                  currstrstart = e + 1
                  i = currstrstart
               else
                  i = slashpos + 2
               end
            end
            if currstrstart <= #str then
               table.insert(replaced, str:sub(currstrstart))
            end

            local h = 0
            local finalstr = table.concat(replaced)
            for _ in finalstr:gmatch("\n") do
               h = h + 1
            end
            return {
               y = node.y,
               h = h,
               finalstr,
            }
         end,
      },

      ["variable"] = emit_exactly_visitor_cbs,
      ["identifier"] = emit_exactly_visitor_cbs,
      ["number"] = emit_number_visitor_cbs,
      ["integer"] = emit_number_visitor_cbs,
      ["nil"] = emit_exactly_visitor_cbs,
      ["boolean"] = emit_exactly_visitor_cbs,
      ["..."] = emit_exactly_visitor_cbs,
      ["argument"] = emit_exactly_visitor_cbs,
      ["type_identifier"] = emit_exactly_visitor_cbs,

      ["cast"] = emit_nothing_visitor_cbs,
      ["pragma"] = emit_nothing_visitor_cbs,
   }

   local visit_type: Visitor<nil, TypeName, Type, Output> = {}
   visit_type.cbs = {}
   local default_type_visitor = {
      after = function(_: nil, typ: Type, _children: {Output}): Output
         local out: Output = { y = typ.y or -1, h = 0 }
         local r = typ is NominalType and typ.resolved or typ
         local lua_type = primitive[r.typename] or "table"
         if r is RecordLikeType and r.is_userdata then
            lua_type = "userdata"
         end
         table.insert(out, lua_type)
         return out
      end,
   }

   visit_type.cbs["string"] = default_type_visitor
   visit_type.cbs["typedecl"] = default_type_visitor
   visit_type.cbs["typevar"] = default_type_visitor
   visit_type.cbs["typearg"] = default_type_visitor
   visit_type.cbs["function"] = default_type_visitor
   visit_type.cbs["thread"] = default_type_visitor
   visit_type.cbs["array"] = default_type_visitor
   visit_type.cbs["map"] = default_type_visitor
   visit_type.cbs["tupletable"] = default_type_visitor
   visit_type.cbs["record"] = default_type_visitor
   visit_type.cbs["enum"] = default_type_visitor
   visit_type.cbs["boolean"] = default_type_visitor
   visit_type.cbs["nil"] = default_type_visitor
   visit_type.cbs["number"] = default_type_visitor
   visit_type.cbs["integer"] = default_type_visitor
   visit_type.cbs["union"] = default_type_visitor
   visit_type.cbs["nominal"] = default_type_visitor
   visit_type.cbs["emptytable"] = default_type_visitor
   visit_type.cbs["literal_table_item"] = default_type_visitor
   visit_type.cbs["unresolved_emptytable_value"] = default_type_visitor
   visit_type.cbs["tuple"] = default_type_visitor
   visit_type.cbs["poly"] = default_type_visitor
   visit_type.cbs["any"] = default_type_visitor
   visit_type.cbs["unknown"] = default_type_visitor
   visit_type.cbs["invalid"] = default_type_visitor
   visit_type.cbs["none"] = default_type_visitor

   visit_node.cbs["expression_list"] = visit_node.cbs["variable_list"]
   visit_node.cbs["argument_list"] = visit_node.cbs["variable_list"]

   local out = recurse_node(nil, ast, visit_node, visit_type)
   if err then
      return nil, err
   end

   local code: Output
   if opts.preserve_newlines then
      code = { y = 1, h = 0 }
      add_child(code, out)
   else
      code = out
   end
   return (concat_output(code):gsub(" *\n", "\n"))
end

--------------------------------------------------------------------------------
-- Type collection for report
--------------------------------------------------------------------------------

local typename_to_typecode <total>: {TypeName:integer} = {
   ["typevar"] = tl.typecodes.TYPE_VARIABLE,
   ["typearg"] = tl.typecodes.TYPE_VARIABLE,
   ["unresolved_typearg"] = tl.typecodes.TYPE_VARIABLE,
   ["unresolvable_typearg"] = tl.typecodes.TYPE_VARIABLE,
   ["function"] = tl.typecodes.FUNCTION,
   ["array"] = tl.typecodes.ARRAY,
   ["map"] = tl.typecodes.MAP,
   ["tupletable"] = tl.typecodes.TUPLE,
   ["interface"] = tl.typecodes.INTERFACE,
   ["self"] = tl.typecodes.SELF,
   ["record"] = tl.typecodes.RECORD,
   ["enum"] = tl.typecodes.ENUM,
   ["boolean"] = tl.typecodes.BOOLEAN,
   ["string"] = tl.typecodes.STRING,
   ["nil"] = tl.typecodes.NIL,
   ["thread"] = tl.typecodes.THREAD,
   ["userdata"] = tl.typecodes.USERDATA,
   ["number"] = tl.typecodes.NUMBER,
   ["integer"] = tl.typecodes.INTEGER,
   ["union"] = tl.typecodes.UNION,
   ["nominal"] = tl.typecodes.NOMINAL,
   ["circular_require"] = tl.typecodes.NOMINAL,
   ["boolean_context"] = tl.typecodes.BOOLEAN,
   ["emptytable"] = tl.typecodes.EMPTY_TABLE,
   ["unresolved_emptytable_value"] = tl.typecodes.EMPTY_TABLE,
   ["poly"] = tl.typecodes.POLY,
   ["any"] = tl.typecodes.ANY,
   ["unknown"] = tl.typecodes.UNKNOWN,
   ["invalid"] = tl.typecodes.INVALID,
   -- types that should be skipped or not present:
   ["none"] = tl.typecodes.UNKNOWN,
   ["tuple"] = tl.typecodes.UNKNOWN,
   ["literal_table_item"] = tl.typecodes.UNKNOWN,
   ["typedecl"] = tl.typecodes.UNKNOWN,
   ["generic"] = tl.typecodes.UNKNOWN,
   ["*"] = tl.typecodes.UNKNOWN,
}

local skip_types: {TypeName: boolean} = {
   ["none"] = true,
   ["tuple"] = true,
   ["literal_table_item"] = true,
}

local function sorted_keys<A,B>(m: {A:B}):{A}
   local keys = {}
   for k, _ in pairs(m) do
      table.insert(keys, k)
   end
   table.sort(keys)
   return keys
end

-- mark array for JSON-encoded reports in `tl types`
local function mark_array<T>(x: T): T
   local arr = x as {boolean}
   arr[0] = false
   return x
end

function tl.new_type_reporter(): TypeReporter
   local self: TypeReporter = setmetatable({
      next_num = 1,
      typeid_to_num = {},
      typename_to_num = {},
      tr = {
         by_pos = {},
         types = {},
         symbols_by_file = {},
         globals = {},
      },
   }, { __index = TypeReporter })

   local names = {}
   for name, _ in pairs(simple_types) do
      table.insert(names, name)
   end
   table.sort(names)

   for _, name in ipairs(names) do
      local ti: TypeInfo = {
         t = assert(typename_to_typecode[name]),
         str = name,
      }
      local n = self.next_num
      self.typename_to_num[name] = n
      self.tr.types[n] = ti
      self.next_num = self.next_num + 1
   end

   return self
end

function TypeReporter:store_function(ti: TypeInfo, rt: FunctionType)
   local args: {{integer, string}} = {}
   for _, fnarg in ipairs(rt.args.tuple) do
      table.insert(args, mark_array { self:get_typenum(fnarg), nil })
   end
   ti.args = mark_array(args)
   local rets: {{integer, string}} = {}
   for _, fnarg in ipairs(rt.rets.tuple) do
      table.insert(rets, mark_array { self:get_typenum(fnarg), nil })
   end
   ti.rets = mark_array(rets)
   ti.vararg = not not rt.args.is_va
   ti.varret = not not rt.rets.is_va
end

function TypeReporter:get_typenum(t: Type): integer
   -- try simple types first
   local n = self.typename_to_num[t.typename]
   if n then
      return n
   end

   assert(t.typeid)
   -- try by typeid
   n = self.typeid_to_num[t.typeid]
   if n then
      return n
   end

   local tr = self.tr

   -- it's a new entry: store and increment
   n = self.next_num

   local rt = t
   if rt is TupleType and #rt.tuple == 1 then
      rt = rt.tuple[1]
   end

   if rt is TypeDeclType then
      return self:get_typenum(rt.def)
   end

   local typeargs: {{string, integer}} = nil
   if rt is GenericType then
      typeargs = mark_array {}
      for _, typearg in ipairs(rt.typeargs) do
         local tn: integer = nil
         if typearg.constraint then
            tn = self:get_typenum(typearg.constraint)
         end
         table.insert(typeargs, mark_array { typearg.typearg, tn })
      end
      rt = rt.t
   end

   local ti: TypeInfo = {
      t = assert(typename_to_typecode[rt.typename]),
      str = show_type(t, true),
      file = t.f,
      y = t.y,
      x = t.x,
      typeargs = typeargs
   }
   tr.types[n] = ti
   self.typeid_to_num[t.typeid] = n
   self.next_num = self.next_num + 1

   if t is NominalType then
      if t.found then
         ti.ref = self:get_typenum(t.found)
      end
      if t.resolved then
         rt = t
      end
   end
   assert(not (rt is TypeDeclType))

   if rt is RecordLikeType then
      -- store record field info
      local r = {}
      for _, k in ipairs(rt.field_order) do
         local v = rt.fields[k]
         r[k] = self:get_typenum(v)
      end
      ti.fields = r
      if rt.meta_fields then
         -- store record metafield info
         local m = {}
         for _, k in ipairs(rt.meta_field_order) do
            local v = rt.meta_fields[k]
            m[k] = self:get_typenum(v)
         end
         ti.meta_fields = m
      end
   end

   if rt is ArrayLikeType then
      ti.elements = self:get_typenum(rt.elements)
   end

   if rt is MapType then
      ti.keys = self:get_typenum(rt.keys)
      ti.values = self:get_typenum(rt.values)
   elseif rt is EnumType then
      ti.enums = mark_array(sorted_keys(rt.enumset))
   elseif rt is FunctionType then
      self:store_function(ti, rt)
   elseif rt is AggregateType then
      local tis = {}
      for _, pt in ipairs(rt.types) do
         table.insert(tis, self:get_typenum(pt))
      end
      ti.types = mark_array(tis)
   end

   return n
end

function TypeReporter:add_field(rtype: RecordLikeType, fname: string, ftype: Type)
   local n = self:get_typenum(rtype)
   local ti = self.tr.types[n]
   assert(ti.fields)
   ti.fields[fname] = self:get_typenum(ftype)
end

function TypeReporter:set_ref(nom: NominalType, resolved: Type)
   local n = self:get_typenum(nom)
   local ti = self.tr.types[n]
   ti.ref = self:get_typenum(resolved)
end

local record TypeCollector
   record Symbol
      x: integer
      y: integer
      name: string
      typ: Type
      skip: boolean
   end

   filename: string
   symbol_list: {Symbol}

   store_type: function(y: integer, x: integer, typ: Type)
   reserve_symbol_list_slot: function(Node)
   add_to_symbol_list: function(node: Node, name: string, t: Type)
   begin_symbol_list_scope: function(node: Node)
   rollback_symbol_list_scope: function()
   end_symbol_list_scope: function(node: Node)
end

function TypeReporter:get_collector(filename: string): TypeCollector
   local collector: TypeCollector = {
      filename = filename,
      symbol_list = {},
   }

   local ft: {integer:{integer:integer}} = {}
   self.tr.by_pos[filename] = ft

   local symbol_list = collector.symbol_list
   local symbol_list_n = 0

   collector.store_type = function(y: integer, x: integer, typ: Type)
      if not typ or skip_types[typ.typename] then
         return
      end

      local yt = ft[y]
      if not yt then
         yt = {}
         ft[y] = yt
      end

      yt[x] = self:get_typenum(typ)
   end

   collector.reserve_symbol_list_slot = function(node: Node)
      symbol_list_n = symbol_list_n + 1
      node.symbol_list_slot = symbol_list_n
   end

   collector.add_to_symbol_list = function(node: Node, name: string, t: Type)
      if not node then
         return
      end
      local slot: integer
      if node.symbol_list_slot then
         slot = node.symbol_list_slot
      else
         symbol_list_n = symbol_list_n + 1
         slot = symbol_list_n
      end
      symbol_list[slot] = { y = node.y, x = node.x, name = name, typ = t }
   end

   collector.begin_symbol_list_scope = function(node: Node)
      symbol_list_n = symbol_list_n + 1
      symbol_list[symbol_list_n] = { y = node.y, x = node.x, name = "@{" }
   end

   collector.rollback_symbol_list_scope = function()
      while symbol_list[symbol_list_n].name ~= "@{" do
         symbol_list[symbol_list_n] = nil
         symbol_list_n = symbol_list_n - 1
      end
   end

   collector.end_symbol_list_scope = function(node: Node)
      if symbol_list[symbol_list_n].name == "@{" then
         symbol_list[symbol_list_n] = nil
         symbol_list_n = symbol_list_n - 1
      else
         symbol_list_n = symbol_list_n + 1
         symbol_list[symbol_list_n] = { y = assert(node.yend), x = assert(node.xend), name = "@}" }
      end
   end

   return collector
end

function TypeReporter:store_result(collector: TypeCollector, globals: {string:Variable})
   local tr = self.tr

   local filename = collector.filename
   local symbol_list = collector.symbol_list

   tr.by_pos[filename][0] = nil

   -- mark unneeded scope blocks to be skipped
   do
      local n = 0 -- number of symbols in current scope
      local p = 0 -- opening position of current scope block
      local n_stack, p_stack = {}, {}
      local level = 0
      for i, s in ipairs(symbol_list) do
         if s.typ then
            n = n + 1
         elseif s.name == "@{" then
            level = level + 1
            n_stack[level], p_stack[level] = n, p -- push current scope
            n, p = 0, i -- begin new scope
         else
            if n == 0 then -- nothing declared in this scope
               symbol_list[p].skip = true -- skip @{
               s.skip = true -- skip @}
            end
            n, p = n_stack[level], p_stack[level] -- pop previous scope
            level = level - 1
         end
      end
   end

   local symbols: {TypeReport.Symbol} = mark_array {}
   tr.symbols_by_file[filename] = symbols

   -- resolve scope cross references, skipping unneeded scope blocks
   do
      local stack = {}
      local level = 0
      local i = 0
      for _, s in ipairs(symbol_list) do
         if not s.skip then
            i = i + 1
            local id: integer
            if s.typ then
               id = self:get_typenum(s.typ)
            elseif s.name == "@{" then
               level = level + 1
               stack[level] = i
               id = -1 -- will be overwritten
            else
               local other = stack[level]
               level = level - 1
               symbols[other][4] = i -- overwrite id from @{
               id = other - 1
            end
            local sym = mark_array({ s.y, s.x, s.name, id })
            table.insert(symbols, sym)
         end
      end
   end

   local gkeys = sorted_keys(globals)
   for _, name in ipairs(gkeys) do
      if name:sub(1, 1) ~= "@" then
         local var = globals[name]
         tr.globals[name] = self:get_typenum(var.t)
      end
   end

   if not tr.symbols then
      tr.symbols = tr.symbols_by_file[filename]
   end
end

function TypeReporter:get_report(): TypeReport
   return self.tr
end


--------------------------------------------------------------------------------
-- Report types
--------------------------------------------------------------------------------

function tl.symbols_in_scope(tr: TypeReport, y: integer, x: integer, filename: string): {string:integer}
   local function find(symbols: {TypeReport.Symbol}, at_y: integer, at_x: integer): integer
      local function le(a: {integer, integer}, b: {integer, integer}): boolean
         return a[1] < b[1]
            or (a[1] == b[1] and a[2] <= b[2])
      end
      return binary_search(symbols, {at_y, at_x}, le) or 0
   end

   local ret: {string:integer} = {}

   local symbols = tr.symbols_by_file[filename]
   if not symbols then
      return ret
   end

   local n = find(symbols, y, x)

   while n >= 1 do
      local s = symbols[n]
      local symbol_name = s[3]
      if symbol_name == "@{" then
         n = n - 1
      elseif symbol_name == "@}" then
         n = s[4]
      else
         if ret[symbol_name] == nil then
            ret[symbol_name] = s[4]
         end
         n = n - 1
      end
   end

   return ret
end

--------------------------------------------------------------------------------
-- Errors
--------------------------------------------------------------------------------

function Errors.new(filename: string): Errors
   local self = {
      errors = {},
      warnings = {},
      unknown_dots = {},
      filename = filename,
   }
   return setmetatable(self, { __index = Errors })
end

local function Err(msg: string, t1?: Type, t2?: Type, t3?: Type): Error
   if t1 then
      local s1, s2, s3: string, string, string = nil, nil, nil
      if t1 is InvalidType then
         return nil
      end
      s1 = show_type(t1)
      if t2 then
         if t2 is InvalidType then
            return nil
         end
         s2 = show_type(t2)
      end
      if t3 then
         if t3 is InvalidType then
            return nil
         end
         s3 = show_type(t3)
      end
      msg = msg:format(s1, s2, s3)
      return {
         msg = msg,
         x = t1.x,
         y = t1.y,
         filename = t1.f,
      }
   end

   return {
      msg = msg,
   }
end

local function Err_at(w: Where, msg: string): Error
   return {
      msg = msg,
      x = assert(w.x),
      y = assert(w.y),
      filename = assert(w.f),
   }
end

-- An error holding the fields of `fields`, a table of those an error of some
-- code names. The cast is the checker's own source being valid upstream Teal,
-- which has no optional record field to write the literal as; that every
-- field set is one `record Error` declares is held by build/teal_test.tl.
function Errors.make(fields?: {string:any}): Error
   return (fields or {}) as Error
end

-- An error of the kind `details` names, with the message and place `Err`
-- gives: `details` carries the fields its code names, and is the error.
function Errors.coded(details: Error, msg: string, t1?: Type, t2?: Type, t3?: Type): Error
   local err = Err(msg, t1, t2, t3)
   if not err then
      return nil
   end
   details.msg = err.msg
   details.x = err.x
   details.y = err.y
   details.filename = err.filename
   return details
end

-- `err`, marked a refusal of a value of type `got` where `expected` is wanted.
function Errors.mismatch(err: Error, got: Type, expected: Type): Error
   if not err then
      return nil
   end
   err.code = "mismatch"
   err.got = show_type(got)
   err.got_kind = got.typename
   err.got_members = Errors.members(got)
   err.expected = show_type(expected)
   err.expected_members = Errors.members(expected)
   if expected is NominalType then
      err.expected_names = expected.names
   end
   return err
end

-- `err`, marked as having words of its own before the mismatch it holds.
function Errors.nest(err: Error): Error
   if err then
      err.nested = true
   end
   return err
end

-- `err`, marked a refusal of a binary operator for operands of types `left` and `right`.
function Errors.operands(err: Error, left: Type, right: Type): Error
   err.left = show_type(left)
   err.left_members = Errors.members(left)
   if left is GenericType then
      local generic = left.t
      err.left_is_generic_function = generic is FunctionType
   end
   err.right = show_type(right)
   err.right_members = Errors.members(right)
   return err
end

-- `err`, marked a refusal of the nominal type `got` for `expected`.
function Errors.not_a(err: Error, got: Type, expected: Type): Error
   if not err then
      return nil
   end
   err.code = "not_a"
   err.got = show_type(got)
   err.expected = show_type(expected)
   return err
end

-- What an error says of a type it is about: its `members` and the `subject`
-- they make, shown less where it was inferred.
function Errors.about(err: Error, t: Type): Error
   if not err or not t then
      return err
   end
   err.members = Errors.members(t)
   -- without where it was inferred, which a message shows and a hint does not
   err.subject = table.concat(err.members, " | ")
   err.subject_kind = t.typename
   return err
end

local function has_nil(members: {string}): boolean
   for _, m in ipairs(members or {}) do
      if m == "nil" then
         return true
      end
   end
   return false
end

-- The drop recorded on the operand `n` reads, through parentheses.
local function dropped_read(n: Node): narrowing.Drop
   while n and n.kind == "paren" do
      n = n.e1
   end
   return n and n.dropped
end

-- What dropped the narrowing of the place that the node `w` reads, when
-- `err` refuses a value that may be nil there: the operand the refusal
-- names, or `w` itself.
local function dropped_for(err: Error, w: Where): narrowing.Drop
   local n = w as Node
   if not n.kind then
      return nil
   end
   local code = err.code
   if code == "operator_binary" then
      if has_nil(err.left_members) then
         return dropped_read(n.e1)
      elseif has_nil(err.right_members) then
         return dropped_read(n.e2)
      end
   elseif code == "operator_unary" then
      if has_nil(err.members) then
         return dropped_read(n.e1)
      end
   elseif code == "mismatch" or code == "not_a" then
      if has_nil(err.got_members) then
         return dropped_read(n)
      end
   elseif code == "cannot_index_key" or code == "cannot_index_object" then
      if has_nil(err.members) then
         return dropped_read(n)
      end
   elseif code == "not_array" or code == "pairs_of_non_table" then
      -- Refused at the arguments of the call, whose first is the table.
      if has_nil(err.members) and n.kind == "expression_list" then
         return dropped_read(n[1])
      end
   elseif code == "for_bound" then
      if has_nil(err.members) then
         return dropped_read(err.index == 2 and n.from or err.index == 3 and n.to or n.step)
      end
   end
   return nil
end

-- `err`, marked as the refusal of a place whose narrowing was dropped,
-- when the node `w` it was made at reads one and the refusal is of the nil
-- the drop let back in.
local function blame_drop(err: Error, w: Where)
   if not w or err.code == "narrowing_dropped" then
      return
   end
   local why = dropped_for(err, w)
   if why then
      err.code = "narrowing_dropped"
      err.dropped_place = why.place
      err.dropped_kind = why.kind
      err.dropped_by = why.text
      err.dropped_y = why.y
      err.dropped_x = why.x
   end
end

local function insert_error(self: Errors, y: integer, x: integer, f: string, err: Error)
   err.code = err.code or "other"

   err.y = assert(y)
   err.x = assert(x)
   err.filename = assert(f)

   if TL_DEBUG then
      io.stderr:write("ERROR:" .. err.y .. ":" .. err.x .. ": " .. err.msg .. "\n")
   end

   table.insert(self.errors, err)
end

function Errors:add(w: Where, msg: string, ...:Type)
   local e = Err(msg, ...)
   if e then
      blame_drop(e, w)
      insert_error(self, w.y, w.x, w.f, e)
   end
end

-- `add` of the error `details` names (see `Errors.coded`).
function Errors:add_coded(w: Where, details: Error, msg: string, ...:Type)
   local e = Errors.coded(details, msg, ...)
   if e then
      blame_drop(e, w)
      insert_error(self, w.y, w.x, w.f, e)
   end
end

local context_name: {NodeKind: string} = {
   ["local_declaration"] = "in local declaration",
   ["global_declaration"] = "in global declaration",
   ["assignment"] = "in assignment",
   ["literal_table_item"] = "in table item",
}

function Errors:get_context(ctx: Node|string, name?: string): string
   if not ctx then
      return ""
   end
   local ec = (ctx is Node)   and ctx.expected_context
   local cn = (ctx is string) and ctx or
              (ctx is Node)   and context_name[ec and ec.kind or ctx.kind]
   return (cn and cn .. ": " or "") .. (ec and ec.name and ec.name .. ": " or "") .. (name and name .. ": " or "")
end

-- What `get_context(ctx, name)` says, structured: an `Error` holding the
-- fields `add_prefixing` copies onto the errors it prefixes. A `name` that describes
-- a place in a table (`described`) rather than naming a variable or a field
-- is words between the context and the error.
function Errors:wrap_of(ctx: Node|string, name?: string, described?: boolean): Error
   if not ctx then
      return Errors.make()
   end
   local ec = (ctx is Node)   and ctx.expected_context
   local label = (ctx is string) and ctx or
                 (ctx is Node)   and context_name[ec and ec.kind or ctx.kind]
   local ec_name = ec and ec.name
   if not label then
      return Errors.make({ nested = ec_name ~= nil or name ~= nil })
   end
   if ec_name and name then
      return Errors.make({ context = label, nested = true })
   end
   return Errors.make({ context = label, context_name = ec_name or name, nested = described or false })
end

function Errors:add_in_context(w: Where, ctx: Node, msg: string, ...:Type)
   local prefix = self:get_context(ctx)
   msg = prefix .. msg

   local e = Err(msg, ...)
   if e then
      insert_error(self, w.y, w.x, w.f, e)
   end
end

-- `add_in_context` of the error `details` names (see `Errors.coded`).
function Errors:add_coded_in_context(w: Where, ctx: Node, details: Error, msg: string)
   self:add_coded(w, details, self:get_context(ctx) .. msg)
end


function Errors:collect(errs: {Error})
   for _, e in ipairs(errs) do
      insert_error(self, e.y, e.x, e.filename, e)
   end
end

function Errors:add_warning(tag: WarningKind, w: Where, fmt: string, ...: any)
   assert(w.y)
   table.insert(self.warnings, {
      y = w.y,
      x = w.x,
      msg = fmt:format(...),
      filename = assert(w.f),
      tag = tag,
      code = "other",
   })
end

-- `add_warning` of the warning `details` names, which is the warning.
function Errors:add_warning_coded(tag: WarningKind, w: Where, details: Error, fmt: string, ...: any)
   assert(w.y)
   details.y = w.y
   details.x = w.x
   details.msg = fmt:format(...)
   details.filename = assert(w.f)
   details.tag = tag
   table.insert(self.warnings, details)
end

-- An error for a key a value lacks, or no index of it takes: `details`
-- names its code and fields, when a kind of error the readers act on.
function Errors:invalid_key_at(w: Where, details: Error, msg: string, ...:Type): InvalidType
   self:add_coded(w, details or Errors.make(), msg, ...)
   return an_invalid(w)
end

function Errors:invalid_at(w: Where, msg: string, ...:Type): InvalidType
   self:add(w, msg, ...)
   return an_invalid(w)
end

-- `invalid_at` of the error `details` names (see `Errors.coded`).
function Errors:invalid_coded(w: Where, details: Error, msg: string, ...:Type): InvalidType
   self:add_coded(w, details, msg, ...)
   return an_invalid(w)
end

-- The one number of arguments `f` takes, when it takes one, and the most
-- its arity names (see `show_arity`).
function Errors.arity_counts(f: FunctionType): integer, integer
   local nfargs = #f.args.tuple
   if f.min_arity < nfargs then
      if f.min_arity > 0 then
         return nil, f.args.is_va and f.min_arity or nfargs
      end
      return nil, f.args.is_va and 0 or nfargs
   end
   return nfargs, nfargs
end

-- A call given `given` arguments for a callee that expects `expects`: the
-- one number of them it takes, when it takes one, and the most it names.
function Errors:arity(w: Where, given: integer, expects: string, exact?: integer, most?: integer): InvalidType
   return self:invalid_coded(w, Errors.make({ code = "arity", given = given, expects = exact, expects_most = most }),
      "wrong number of arguments (given " .. given .. ", expects " .. expects .. ")")
end

function Errors:add_unknown(node: Node, name: string)
   self:add_warning_coded("unknown", node, Errors.make({ code = "unknown_variable", variable = name }),
      "unknown variable: %s", name)
end

function Errors:redeclaration_warning(at: Where, var_name: string, var_kind: string, old_var?: Variable)
   if var_name:sub(1, 1) == "_" then return end

   local short_error = var_kind .. " shadows previous declaration of '%s'"
   local details = Errors.make({ code = "shadows", variable = var_name, declares = var_kind, declared_before = old_var and old_var.declared_at and true or nil })
   if old_var and old_var.declared_at then
      self:add_warning_coded("redeclaration", at, details, short_error .. " (originally declared at %d:%d)", var_name, old_var.declared_at.y, old_var.declared_at.x)
   else
      self:add_warning_coded("redeclaration", at, details, short_error, var_name)
   end
end

local function var_should_be_ignored_for_warnings(name: string, var: Variable): boolean
   local prefix <const> = name:sub(1,1)
   return (not var.declared_at)
      or var.is_specialized == "narrow"
      or prefix == "_"
      or prefix == "@"
end

local function user_facing_variable_description(var: Variable): string
   local t <const> = var.t
   return var.is_func_arg and "argument"
      or t is FunctionType and "function"
      or t is TypeDeclType and "type"
      or "variable"
end

function Errors:unused_warning(name: string, var: Variable)
   if var_should_be_ignored_for_warnings(name, var) then
      return
   end
   local declares = user_facing_variable_description(var)
   self:add_warning_coded(
      "unused",
      var.declared_at,
      Errors.make({ code = "unused", variable = name, declares = declares }),
      "unused %s %s: %s",
      declares,
      name,
      show_type(var.t)
   )
end

function Errors:add_prefixing(w: Where, src: {Error}, prefix: string, dst?: {Error}, wrap?: Error)
   if not src then
      return
   end

   for _, err in ipairs(src) do
      err.msg = prefix .. err.msg
      if wrap and wrap.context then
         if err.context then
            err.nested = true
         else
            err.context = wrap.context
            err.context_name = wrap.context_name
            err.index = wrap.index
         end
         if wrap.nested then
            err.nested = true
         end
      elseif prefix ~= "" or (wrap and wrap.nested) then
         err.nested = true
      end
      if wrap and wrap.type_parameter then
         err.type_parameter = wrap.type_parameter
      end
      if wrap and wrap.signature_of then
         err.signature_of = wrap.signature_of
         err.declared_in = wrap.declared_in
      end
      if w and (
         (err.filename ~= w.f)
         or (not err.y)
         or (w.y > err.y or (w.y == err.y and w.x > err.x))
      ) then
         err.y = w.y
         err.x = w.x
         err.filename = w.f
      end

      if w then
         blame_drop(err, w)
      end

      if dst then
         table.insert(dst, err)
      else
         insert_error(self, err.y, err.x, err.filename, err)
      end
   end
end

local function ensure_not_abstract_type(def: Type, node?: Node): boolean, string
   if def is RecordType then
      return true
   elseif def is GenericType then
      return ensure_not_abstract_type(def.t)
   elseif node and node_is_require_call(node) then
      return nil, "module type is abstract: " .. tostring(def)
   elseif def is InterfaceType then
      return nil, "interfaces are abstract; consider using a concrete record"
   end
   return nil, "cannot use a type definition as a concrete value"
end

local function ensure_not_abstract(t: Type, node?: Node): boolean, string
   if t is FunctionType and t.macroexp then
      return nil, "macroexps are abstract; consider using a concrete function"
   elseif t is GenericType then
      return ensure_not_abstract(t.t, node)
   elseif t is TypeDeclType then
      return ensure_not_abstract_type(t.def, node)
   end
   return true
end

local record UsageWarning
   y: integer
   x: integer
   name: string
   var: Variable
   kind: Kind

   enum Kind
      "unused"
      "written but not read"
   end
end

local function has_var_been_used(var: Variable): boolean
   return var.has_been_read_from or var.has_been_written_to
end

local function check_var_usage(scope: Scope, is_global?: boolean): {UsageWarning}
   local vars = scope.vars
   if not next(vars) then
      return
   end
   local usage_warnings: {UsageWarning} = nil
   for name, var in pairs(vars) do
      local t <const> = var.t
      if not var_should_be_ignored_for_warnings(name, var) then
         if var.has_been_written_to and not var.has_been_read_from then
            usage_warnings = usage_warnings or {}
            table.insert(usage_warnings, {
               y = var.declared_at.y,
               x = var.declared_at.x,
               name = name,
               var = var,
               kind = "written but not read",
            })
         end

      end

      if var.declared_at and not has_var_been_used(var) then
         if var.used_as_type then
            var.declared_at.elide_type = true
         else
            if t is TypeDeclType and not is_global then
               var.declared_at.elide_type = true
            end
            usage_warnings = usage_warnings or {}
            table.insert(usage_warnings, { y = var.declared_at.y, x = var.declared_at.x, name = name, var = var, kind = "unused" })
         end
      elseif has_var_been_used(var) and t is TypeDeclType and var.aliasing then
         var.aliasing.has_been_written_to = var.has_been_written_to
         var.aliasing.has_been_read_from = var.has_been_read_from
         if ensure_not_abstract(t) then
            var.aliasing.declared_at.elide_type = false
         end
      end
   end
   if usage_warnings then
      table.sort(usage_warnings, function(a: UsageWarning, b: UsageWarning): boolean
         return a.y < b.y or (a.y == b.y and a.x < b.x)
      end)
   end
   return usage_warnings
end

function Errors:check_var_usage(scope: Scope, is_global?: boolean)
   local usage_warnings <const> = check_var_usage(scope, is_global)
   if usage_warnings then
      for _, u in ipairs(usage_warnings) do
         if u.kind == "unused" then
            self:unused_warning(u.name, u.var)
         elseif u.kind == "written but not read" then
            self:add_warning(
               "unread",
               u.var.declared_at,
               "%s %s (of type %s) is never read",
               user_facing_variable_description(u.var),
               u.name,
               show_type(u.var.t)
            )
         end
      end
   end

   if scope.labels then
      for name, node in pairs(scope.labels) do
         if not node.used_label then
            self:add_warning_coded("unused", node, Errors.make({ code = "unused", variable = name, declares = "label" }),
               "unused label ::%s::", name)
         end
      end
   end
end

function Errors:add_unknown_dot(node: Node, name: string)
   if not self.unknown_dots[name] then
      self.unknown_dots[name] = true
      self:add_unknown(node, name)
   end
end

function Errors:fail_unresolved_labels(scope: Scope)
   if scope.pending_labels then
      for name, nodes in pairs(scope.pending_labels) do
         for _, node in ipairs(nodes) do
            self:add(node, "no visible label '" .. name .. "' for goto")
         end
      end
   end
end

function Errors:fail_unresolved_nominals(scope: Scope, global_scope: Scope)
   if global_scope and scope.pending_nominals then
      for name, types in pairs(scope.pending_nominals) do
         if not global_scope.pending_global_types[name] then
            for _, typ in ipairs(types) do
               assert(typ.x)
               assert(typ.y)
               self:add_coded(typ, Errors.make({ code = "unknown_type", names = typ.names, subject = show_type(typ) }), "unknown type %s", typ)
            end
         end
      end
   end
end

local type CheckableKey = string | number | boolean

function Errors:check_redeclared_key(w: Where, ctx: Node, seen_keys: {CheckableKey:Where}, key: CheckableKey)
   if key ~= nil then
      local s = seen_keys[key]
      if s then
         self:add_in_context(w, ctx, "redeclared key " .. tostring(key) .. " (previously declared at " .. self.filename .. ":" .. s.y .. ":" .. s.x .. ")")
      else
         seen_keys[key] = w
      end
   end
end

--------------------------------------------------------------------------------
-- Type check
--------------------------------------------------------------------------------

local numeric_binop = {
   ["number"] = {
      ["number"] = "number",
      ["integer"] = "number",
   },
   ["integer"] = {
      ["integer"] = "integer",
      ["number"] = "number",
   },
}

local float_binop = {
   ["number"] = {
      ["number"] = "number",
      ["integer"] = "number",
   },
   ["integer"] = {
      ["integer"] = "number",
      ["number"] = "number",
   },
}

local integer_binop = {
   ["number"] = {
      ["number"] = "integer",
      ["integer"] = "integer",
   },
   ["integer"] = {
      ["integer"] = "integer",
      ["number"] = "integer",
   },
}

local relational_binop = {
   ["number"] = {
      ["integer"] = "boolean",
      ["number"] = "boolean",
   },
   ["integer"] = {
      ["number"] = "boolean",
      ["integer"] = "boolean",
   },
   ["string"] = {
      ["string"] = "boolean",
   },
   ["boolean"] = {
      ["boolean"] = "boolean",
   },
}

local equality_binop = {
   ["number"] = {
      ["number"] = "boolean",
      ["integer"] = "boolean",
      ["nil"] = "boolean",
   },
   ["integer"] = {
      ["number"] = "boolean",
      ["integer"] = "boolean",
      ["nil"] = "boolean",
   },
   ["string"] = {
      ["string"] = "boolean",
      ["nil"] = "boolean",
   },
   ["boolean"] = {
      ["boolean"] = "boolean",
      ["nil"] = "boolean",
   },
   ["record"] = {
      ["emptytable"] = "boolean",
      ["record"] = "boolean",
      ["nil"] = "boolean",
   },
   ["array"] = {
      ["emptytable"] = "boolean",
      ["array"] = "boolean",
      ["nil"] = "boolean",
   },
   ["map"] = {
      ["emptytable"] = "boolean",
      ["map"] = "boolean",
      ["nil"] = "boolean",
   },
   ["thread"] = {
      ["thread"] = "boolean",
      ["nil"] = "boolean",
   }
}

local unop_types: {string:{TypeName:TypeName}} = {
   ["#"] = {
      ["enum"] = "integer",
      ["string"] = "integer",
      ["array"] = "integer",
      ["tupletable"] = "integer",
      ["map"] = "integer",
      ["emptytable"] = "integer",
   },
   ["-"] = {
      ["number"] = "number",
      ["integer"] = "integer",
   },
   ["~"] = {
      ["number"] = "integer",
      ["integer"] = "integer",
   },
   ["not"] = {
      ["string"] = "boolean",
      ["number"] = "boolean",
      ["integer"] = "boolean",
      ["boolean"] = "boolean",
      ["record"] = "boolean",
      ["array"] = "boolean",
      ["tupletable"] = "boolean",
      ["map"] = "boolean",
      ["emptytable"] = "boolean",
      ["thread"] = "boolean",
   },
}

local unop_to_metamethod: {string:string} = {
   ["#"] = "__len",
   ["-"] = "__unm",
   ["~"] = "__bnot",
}

local binop_types: {string:{TypeName:{TypeName:TypeName}}} = {
   ["+"] = numeric_binop,
   ["-"] = numeric_binop,
   ["*"] = numeric_binop,
   ["%"] = numeric_binop,
   ["/"] = float_binop,
   ["//"] = numeric_binop,
   ["^"] = float_binop,
   ["&"] = integer_binop,
   ["|"] = integer_binop,
   ["<<"] = integer_binop,
   [">>"] = integer_binop,
   ["~"] = integer_binop,
   ["=="] = equality_binop,
   ["~="] = equality_binop,
   ["<="] = relational_binop,
   [">="] = relational_binop,
   ["<"] = relational_binop,
   [">"] = relational_binop,
   ["or"] = {
      ["boolean"] = {
         ["boolean"] = "boolean",
      },
      ["number"] = {
         ["integer"] = "number",
         ["number"] = "number",
         ["boolean"] = "boolean",
      },
      ["integer"] = {
         ["integer"] = "integer",
         ["number"] = "number",
         ["boolean"] = "boolean",
      },
      ["string"] = {
         ["string"] = "string",
         ["boolean"] = "boolean",
         ["enum"] = "string",
      },
      ["function"] = {
         ["boolean"] = "boolean",
      },
      ["array"] = {
         ["boolean"] = "boolean",
      },
      ["record"] = {
         ["boolean"] = "boolean",
      },
      ["map"] = {
         ["boolean"] = "boolean",
      },
      ["enum"] = {
         ["string"] = "string",
      },
      ["thread"] = {
         ["boolean"] = "boolean",
      }
   },
   [".."] = {
      ["string"] = {
         ["string"] = "string",
         ["enum"] = "string",
         ["number"] = "string",
         ["integer"] = "string",
      },
      ["number"] = {
         ["integer"] = "string",
         ["number"] = "string",
         ["string"] = "string",
         ["enum"] = "string",
      },
      ["integer"] = {
         ["integer"] = "string",
         ["number"] = "string",
         ["string"] = "string",
         ["enum"] = "string",
      },
      ["enum"] = {
         ["number"] = "string",
         ["integer"] = "string",
         ["string"] = "string",
         ["enum"] = "string",
      }
   },
}

local binop_to_metamethod: {string:string} = {
   ["+"] = "__add",
   ["-"] = "__sub",
   ["*"] = "__mul",
   ["/"] = "__div",
   ["%"] = "__mod",
   ["^"] = "__pow",
   ["//"] = "__idiv",
   ["&"] = "__band",
   ["|"] = "__bor",
   ["~"] = "__bxor",
   ["<<"] = "__shl",
   [">>"] = "__shr",
   [".."] = "__concat",
   ["=="] = "__eq",
   ["<"] = "__lt",
   ["<="] = "__le",
   ["@index"] = "__index",
   ["is"] = "__is",
}

local flip_binop_to_metamethod: {string:string} = {
   [">"] = "__lt",
   [">="] = "__le",
}

local function is_unknown(t: Type): boolean
   return t.typename == "unknown"
       or t.typename == "unresolved_emptytable_value"
end

local function display_typevar(typevar: string, what: TypeName): string
   return TL_DEBUG
      and (what .. " " .. typevar)
      or typevar:gsub("@.*", "")
end

local function show_fields(t: RecordLikeType, show: function(Type):(string)): string
   if t.declname then
      return " " .. t.declname
   end

   local out: {string} = {}
   table.insert(out, " (")
   if t.elements then
      table.insert(out, "{" .. show(t.elements) .. "}")
   end
   local fs = {}
   for _, k in ipairs(t.field_order) do
      local v = t.fields[k]
      table.insert(fs, k .. ": " .. show(v))
   end
   table.insert(out, table.concat(fs, "; "))
   table.insert(out, ")")
   return table.concat(out)
end

local function show_type_base(t: Type, short: boolean, seen: {Type:string}): string
   -- FIXME this is a control for recursively built types, which should in principle not exist
   if seen[t] then
      return seen[t]
   end
   seen[t] = "..."

   local function show(typ: Type): string
      return show_type(typ, short, seen)
   end

   if t is NominalType then
      local ret: string
      if t.typevals then
         local out = { table.concat(t.names, "."), "<" }
         local vals: {string} = {}
         for _, v in ipairs(t.typevals) do
            table.insert(vals, show(v))
         end
         table.insert(out, table.concat(vals, ", "))
         table.insert(out, ">")
         ret = table.concat(out)
      else
         ret = table.concat(t.names, ".")
      end
      if TL_DEBUG then
         ret = "nominal " .. ret
      end
      return ret
   elseif t is SelfType then
      if t.display_type then
         local ret = show_type_base(t.display_type, short, seen)
         if TL_DEBUG then
            ret = "self " .. ret
         end
         return ret
      end
      return "self"
   elseif t is TupleType then
      local out: {string} = {}
      for _, v in ipairs(t.tuple) do
         table.insert(out, show(v))
      end
      local list = table.concat(out, ", ")
      if t.is_va then
         list = list .. "..."
      end
      if short then
         return list
      end
      return "(" .. list .. ")"
   elseif t is TupleTableType then
      local out: {string} = {}
      for _, v in ipairs(t.types) do
         table.insert(out, show(v))
      end
      return "{" .. table.concat(out, ", ") .. "}"
   elseif t is PolyType then
      local out: {string} = {}
      for _, v in ipairs(t.types) do
         table.insert(out, show(v))
      end
      return "polymorphic function (with types " .. table.concat(out, " and ") .. ")"
   elseif t is UnionType then
      local out: {string} = {}
      for _, v in ipairs(t.types) do
         table.insert(out, show(v))
      end
      return table.concat(out, " | ")
   elseif t is EmptyTableType then
      return "{}"
   elseif t is MapType then
      return "{" .. show(t.keys) .. " : " .. show(t.values) .. "}"
   elseif t is ArrayType then
      return "{" .. show(t.elements) .. "}"
   elseif t is EnumType then
      return t.declname or "enum"
   elseif t is RecordLikeType then
      return short and (t.declname or t.typename) or t.typename .. show_fields(t, show)
   elseif t is FunctionType then
      local out: {string} = {"function("}
      local args = {}
      for i, v in ipairs(t.args.tuple) do
         table.insert(args, ((i == #t.args.tuple and t.args.is_va) and "...: "
                            or (i > t.min_arity) and "? "
                            or "") .. show(v))
      end
      table.insert(out, table.concat(args, ", "))
      table.insert(out, ")")
      if t.never then
         table.insert(out, ": never")
      elseif t.rets.tuple and #t.rets.tuple > 0 then
         table.insert(out, ": ")
         local rets = {}
         if #t.rets.tuple > 1 then
            table.insert(out, "(")
         end
         for i, v in ipairs(t.rets.tuple) do
            table.insert(rets, show(v) .. (i == #t.rets.tuple and t.rets.is_va and "..." or ""))
         end
         table.insert(out, table.concat(rets, ", "))
         if #t.rets.tuple > 1 then
            table.insert(out, ")")
         end
      end
      return table.concat(out)
   elseif t is GenericType then
      local out: {string} = {}
      local name, rest: string, string
      local tt = t.t
      if tt is RecordType or tt is InterfaceType or tt is FunctionType then
         name, rest = show(tt):match("^(%a+)(.*)")
         table.insert(out, name)
      else
         rest = " " .. show(tt)
         table.insert(out, "generic")
      end
      table.insert(out, "<")
      local typeargs = {}
      for _, v in ipairs(t.typeargs) do
         table.insert(typeargs, show(v))
      end
      table.insert(out, table.concat(typeargs, ", "))
      table.insert(out, ">")
      table.insert(out, rest)
      return table.concat(out)
   elseif t.typename == "number"
       or t.typename == "integer"
       or t.typename == "boolean"
       or t.typename == "thread" then
      return t.typename
   elseif t is StringType then
      if short then
         return "string"
      else
         return t.typename ..
                (t.literal and string.format(" %q", t.literal) or "")
      end
   elseif t is TypeVarType then
      return display_typevar(t.typevar, "typevar")
   elseif t is TypeArgType then
      local out = display_typevar(t.typearg, "typearg")
      if t.constraint then
         out = out .. " is " .. show(t.constraint)
      end
      return out
   elseif t is UnresolvableTypeArgType then
      return display_typevar(t.typearg, "typearg") .. " (unresolved generic)"
   elseif is_unknown(t) then
      return "<unknown type>"
   elseif t is InvalidType then
      return "<invalid type>"
   elseif t.typename == "any" then
      return "<any type>"
   elseif t is NilType then
      return "nil"
   elseif t.typename == "boolean_context" then
      return "boolean"
   elseif t.typename == "none" then
      return ""
   elseif t is TypeDeclType then
      return (t.is_alias and "type alias to " or "type ") .. show(t.def)
   else
      return "<" .. t.typename .. ">" -- TODO add string.format("%p", t) with compat-5.4
   end
end

local function inferred_msg(t: Type, prefix?: string): string
   return " (" .. (prefix or "") .. "inferred at "..t.inferred_at.f..":"..t.inferred_at.y..":"..t.inferred_at.x..")"
end

show_type = function(t: Type, short?: boolean, seen?: {Type:string}): string
   seen = seen or {}
   if seen[t] then
      return seen[t]
   end
   local ret = show_type_base(t, short, seen)
   if t.inferred_at then
      ret = ret .. inferred_msg(t)
   end
   seen[t] = ret
   return ret
end

-- The members of a union, each shown alone and without where it was
-- inferred; any other type holds itself.
function Errors.members(t: Type): {string}
   local out: {string} = {}
   if t is UnionType then
      for _, member in ipairs(t.types) do
         table.insert(out, show_type_base(member, false, {}))
      end
   else
      table.insert(out, show_type_base(t, false, {}))
   end
   return out
end

local function search_for(module_name: string, suffix: string, path: string, tried: {string}): string, FILE, {string}
   for entry in path:gmatch("[^;]+") do
      local slash_name = module_name:gsub("%.", "/")
      local filename = entry:gsub("?", slash_name)
      local tl_filename = filename:gsub("%.lua$", suffix)
      local fd = io.open(tl_filename, "rb")
      if fd then
         return tl_filename, fd, tried
      end
      table.insert(tried, "no file '" .. tl_filename .. "'")
   end
   return nil, nil, tried
end

tl.search_module = function(module_name: string, search_all: boolean): string, FILE, {string}
   local found: string
   local fd: FILE
   local tried: {string} = {}
   local path = os.getenv("TL_PATH") or tl.path or package.path
   if search_all then
      found, fd, tried = search_for(module_name, ".d.tl", path, tried)
      if found then
         return found, fd
      end
   end
   found, fd, tried = search_for(module_name, ".tl", path, tried)
   if found then
      return found, fd
   end
   if search_all then
      found, fd, tried = search_for(module_name, ".lua", path, tried)
      if found then
         return found, fd
      end
   end
   return nil, nil, tried
end

local function require_module(w: Where, module_name: string, opts: CheckOptions, env: Env): Type, string
   local mod = env.modules[module_name]
   if mod then
      return mod, env.module_filenames[module_name]
   end

   local found, fd = tl.search_module(module_name, true)
   if found and (opts.feat_lax == "on" or found:match("tl$") as boolean) then

      env.module_filenames[module_name] = found
      env.modules[module_name] = a_typedecl(w, a_type(w, "circular_require", {}))

      local save_defaults = env.defaults
      local defaults <total>: CheckOptions = {
         feat_lax = opts.feat_lax or save_defaults.feat_lax,
         feat_arity = opts.feat_arity or save_defaults.feat_arity,
         gen_compat = opts.gen_compat or save_defaults.gen_compat,
         gen_target = opts.gen_target or save_defaults.gen_target,
         run_internal_compiler_checks = opts.run_internal_compiler_checks or save_defaults.run_internal_compiler_checks,
         runtime_checks = opts.runtime_checks or save_defaults.runtime_checks,
      }
      env.defaults = defaults

      local found_result, err: Result, string = tl.check_file(found, env, fd)
      assert(found_result, err)

      env.defaults = save_defaults

      env.modules[module_name] = found_result.type

      return found_result.type, found
   elseif fd then
      fd:close()
   end

   return an_invalid(w), found
end

local compat_code_cache: {string:Node} = {}

local function add_compat_entries(program: Node, used_set: {string: boolean}, gen_compat: GenCompat)
   if gen_compat == "off" or not next(used_set) then
      return
   end

   local tl_debug = TL_DEBUG
   TL_DEBUG = nil

   local used_list: {string} = sorted_keys(used_set)

   local compat_loaded = false

   local n = 1
   local function load_code(name: string, text: string)
      local code: Node = compat_code_cache[name]
      if not code then
         code = tl.parse(text, "@internal", "lua") as Node
         tl.check(code, "@internal", { feat_lax = "off", gen_compat = "off" })
         compat_code_cache[name] = code
      end
      for _, c in ipairs(code) do
         table.insert(program, n, c)
         n = n + 1
      end
   end

   local function req(m: string): string
      return (gen_compat == "optional")
             and "pcall(require, '" .. m .. "')"
             or  "true, require('" .. m .. "')"
   end

   for _, name in ipairs(used_list) do
      if name == "table.unpack" then
         load_code(name, "local _tl_table_unpack = unpack or table.unpack")
      elseif name == "table.pack" then
         load_code(name, [[local _tl_table_pack = table.pack or function(...) return { n = select("#", ...), ... } end]])
      elseif name == "bit32" then
         load_code(name, "local bit32 = bit32; if not bit32 then local p, m = " .. req("bit32") .. "; if p then bit32 = m end")
      elseif name == "mt" then
         load_code(name, "local _tl_mt = function(m, s, a, b) return (getmetatable(s == 1 and a or b)[m](a, b) end")
      elseif name == "math.maxinteger" then
         load_code(name, "local _tl_math_maxinteger = math.maxinteger or math.pow(2,53)")
      elseif name == "math.mininteger" then
         load_code(name, "local _tl_math_mininteger = math.mininteger or -math.pow(2,53) - 1")
      elseif name == "type" then
         load_code(name, "local type = type")
      else
         if not compat_loaded then
            load_code("compat", "local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = " .. req("compat53.module") .. "; if p then _tl_compat = m end")
            compat_loaded = true
         end
         load_code(name, (("local $NAME = _tl_compat and _tl_compat.$NAME or $NAME"):gsub("$NAME", name)))
      end
   end
   program.y = 1

   TL_DEBUG = tl_debug
end

local function get_stdlib_compat(): {string:boolean}
   return {
      ["io"] = true,
      ["math"] = true,
      ["string"] = true,
      ["table"] = true,
      ["utf8"] = true,
      ["coroutine"] = true,
      ["os"] = true,
      ["package"] = true,
      ["debug"] = true,
      ["load"] = true,
      ["loadfile"] = true,
      ["assert"] = true,
      ["pairs"] = true,
      ["ipairs"] = true,
      ["pcall"] = true,
      ["xpcall"] = true,
      ["rawlen"] = true,
   }
end

local bit_operators: {string:string} = {
   ["&"] = "band",
   ["|"] = "bor",
   ["~"] = "bxor",
   [">>"] = "rshift",
   ["<<"] = "lshift",
}

local function node_at(w: Where, n: Node): Node
   n.f = assert(w.f)
   n.x = w.x
   n.y = w.y
   return n
end

-- The place an expression names, for a guard or an assignment to read.
local function place_of(n: Node): narrowing.Place
   return narrowing.place_of(n as narrowing.Node)
end

local function convert_node_to_compat_call(node: Node, mod_name: string, fn_name: string, e1: Node, e2?: Node)
   node.op.op = "@funcall"
   node.op.arity = 2
   node.op.prec = 100
   node.e1 = node_at(node, { kind = "op", op = an_operator(node, 2, ".") })
   node.e1.e1 = node_at(node, { kind = "identifier", tk = mod_name })
   node.e1.e2 = node_at(node, { kind = "identifier", tk = fn_name })
   node.e2 = node_at(node, { kind = "expression_list" })
   node.e2[1] = e1
   node.e2[2] = e2
end

local function convert_node_to_compat_mt_call(node: Node, mt_name: string, which_self: integer, e1: Node, e2?: Node)
   node.op.op = "@funcall"
   node.op.arity = 2
   node.op.prec = 100
   node.e1 = node_at(node, { kind = "identifier", tk = "_tl_mt" })
   node.e2 = node_at(node, { kind = "expression_list" })
   node.e2[1] = node_at(node, { kind = "string", tk = "\"" .. mt_name .. "\"" })
   node.e2[2] = node_at(node, { kind = "integer", tk = tostring(which_self) })
   node.e2[3] = e1
   node.e2[4] = e2
end

local stdlib_globals: {string:Variable} = nil
local globals_typeid = new_typeid()
local fresh_typevar_ctr = 1

local function assert_no_errors(errors: {Error}, msg: string)
   if #errors ~= 0 then
      local out = {}
      for _, err in ipairs(errors) do
         table.insert(out, err.y .. ":" .. err.x .. " " .. err.msg .. "\n")
      end
      error("Internal Compiler Error: " .. msg .. ":\n" .. table.concat(out), 2)
   end
end

local function resolve_for_special_function(t: Type): FunctionType
   if t is PolyType then
      t = t.types[1]
   end
   if t is GenericType then
      t = t.t
   end
   if t is FunctionType then
      return t
   end
end

local function set_special_function(t: Type, fname: SpecialFunctionName)
   t = resolve_for_special_function(t)
   t.special_function_handler = fname
end

tl.new_env = function(opts?: EnvOptions): Env, string
   opts = opts or {}

   local env: Env = {
      modules = {},
      module_filenames = {},
      loaded = {},
      loaded_order = {},
      globals = {},
      defaults = opts.defaults or {},
   }

   if env.defaults.gen_target == "5.4" and env.defaults.gen_compat ~= "off" then
      return nil, "gen-compat must be explicitly 'off' when gen-target is '5.4'"
   end

   if not stdlib_globals then
      local tl_debug = TL_DEBUG
      TL_DEBUG = nil

      do
         local program, syntax_errors = tl.parse(prelude, "prelude.d.tl", "tl")
         assert_no_errors(syntax_errors, "prelude contains syntax errors")
         local result = tl.check(program, "@prelude", {}, env)
         assert_no_errors(result.type_errors, "prelude contains type errors")
      end

      do
         local program, syntax_errors = tl.parse(stdlib, "stdlib.d.tl", "tl")
         assert_no_errors(syntax_errors, "standard library contains syntax errors")
         local result = tl.check(program, "@stdlib", {}, env)
         assert_no_errors(result.type_errors, "standard library contains type errors")
      end

      stdlib_globals = env.globals

      TL_DEBUG = tl_debug

      -- special cases for compatibility
      local math_t = (stdlib_globals["math"].t as TypeDeclType).def as RecordType
      local table_t = (stdlib_globals["table"].t as TypeDeclType).def as RecordType
      math_t.fields["maxinteger"].needs_compat = true
      math_t.fields["mininteger"].needs_compat = true
      table_t.fields["pack"].needs_compat = true
      table_t.fields["unpack"].needs_compat = true

      -- special cased functions
      local string_t = (stdlib_globals["string"].t as TypeDeclType).def as RecordType
      set_special_function(string_t.fields["find"], "string.find")
      set_special_function(string_t.fields["format"], "string.format")
      set_special_function(string_t.fields["gmatch"], "string.gmatch")
      set_special_function(string_t.fields["gsub"], "string.gsub")
      set_special_function(string_t.fields["match"], "string.match")
      set_special_function(string_t.fields["pack"], "string.pack")
      set_special_function(string_t.fields["unpack"], "string.unpack")

      set_special_function(stdlib_globals["assert"].t, "assert")
      set_special_function(((stdlib_globals["coroutine"].t as TypeDeclType).def as RecordType).fields["wrap"], "coroutine.wrap")
      set_special_function(stdlib_globals["ipairs"].t, "ipairs")
      set_special_function(stdlib_globals["pairs"].t, "pairs")
      set_special_function(stdlib_globals["pcall"].t, "pcall")
      set_special_function(stdlib_globals["xpcall"].t, "xpcall")
      set_special_function(stdlib_globals["rawget"].t, "rawget")
      set_special_function(stdlib_globals["require"].t, "require")
      set_special_function(stdlib_globals["setmetatable"].t, "setmetatable")
      set_special_function(stdlib_globals["error"].t, "error")
      set_special_function(stdlib_globals["type"].t, "type")

      -- Functions that run no code of the program's, however it is called,
      -- unless an argument they examine may dispatch to a metamethod.
      --
      -- TODO: these are marked by name here, and a function of the program's
      -- own cannot say it too. It waits on doc/roadmap.md's item that has a
      -- declaration say so, which needs the narrowing declaration's syntax
      -- (strict-teal's open question) to be settled.
      local function pure(t: Type, examines: string)
         if t is PolyType then
            for _, member in ipairs(t.types) do
               pure(member, examines)
            end
            return
         end
         if t is GenericType then
            t = t.t
         end
         if t is FunctionType then
            t.pure_std = examines
         end
      end
      for _, name in ipairs({ "print", "tonumber", "tostring" }) do
         pure(stdlib_globals[name].t, "all")
      end
      for _, name in ipairs({ "next", "rawequal", "rawget", "rawlen", "select" }) do
         pure(stdlib_globals[name].t, "none")
      end
      for _, name in ipairs({ "ipairs", "pairs" }) do
         pure(stdlib_globals[name].t, "first")
      end
      local function pure_fields(library: string, names: {string}, examines: string)
         local record_t = (stdlib_globals[library].t as TypeDeclType).def as RecordType
         for _, name in ipairs(names) do
            pure(record_t.fields[name], examines)
         end
      end
      local function all_fields(library: string): {string}
         return ((stdlib_globals[library].t as TypeDeclType).def as RecordType).field_order
      end
      pure_fields("string", all_fields("string"), "all")
      pure_fields("math", all_fields("math"), "all")
      pure_fields("utf8", all_fields("utf8"), "all")
      pure_fields("os", { "clock", "date", "difftime", "getenv", "time" }, "all")
      pure_fields("table", { "concat" }, "all")
      pure_fields("table", { "insert", "remove", "unpack" }, "first")

      -- only global scope and vararg functions accept `...`:
      -- `@is_va` is an internal sentinel value which is
      -- `any` if `...` is accepted in this scope or `nil` if it isn't.
      local w: Where = { f = "@prelude", x = 1, y = 1 }
      stdlib_globals["..."] = { t = a_vararg(w, { a_type(w, "string", {}) }) }
      stdlib_globals["@is_va"] = { t = a_type(w, "any", {}) }

      env.globals = {}
   end

   local stdlib_compat = get_stdlib_compat()
   for name, var in pairs(stdlib_globals) do
      env.globals[name] = var
      var.needs_compat = stdlib_compat[name]
      local t = var.t
      if t is TypeDeclType then
         -- make standard library tables available as modules for require()
         env.modules[name] = t
      end
   end

   if opts.predefined_modules then
      for _, name in ipairs(opts.predefined_modules) do
         local tc_opts = {
            feat_lax = env.defaults.feat_lax,
            feat_arity = env.defaults.feat_arity,
         }
         local w: Where = { f = "@predefined", x = 1, y = 1 }
         local module_type = require_module(w, name, tc_opts, env)

         if module_type is InvalidType then
            return nil, string.format("Error: could not predefine module '%s'", name)
         end
      end
   end

   return env
end


do
   local type TypeRelations = {TypeName:{TypeName:CompareTypes}}
   local type InvalidOrTupleType = InvalidType | TupleType

   local record TypeChecker
      env: Env
      st: {Scope}

      filename: string
      errs: Errors
      module_type: Type

      subtype_relations: TypeRelations
      eqtype_relations: TypeRelations
      type_priorities: {TypeName:integer}

      all_needs_compat: {string:boolean}
      dependencies: {string:string}
      collector: TypeCollector

      cache_std_metatable_type: Type

      -- How many is_a and same_type comparisons are open, so that the
      -- outermost can compare the never-ness of the types as a whole.
      compare_depth: integer

      receiver_field: FunctionType

      gen_compat: GenCompat
      gen_target: GenTarget
      feat_arity: boolean
      feat_lax: boolean
      runtime_checks: boolean

      -- Reported at an `assert(...)` whose extra values a check refused;
      -- set beside assert_spill_hint.
      assert_spill_message: string

      same_type: function(self, Type, Type): boolean, {Error}
      is_a: function(self, Type, Type): boolean, {Error}

      type_check_funcall: function(TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType

      expand_type: function(TypeChecker, w: Where, old: Type, new: Type): Type
      resolve_self: function(TypeChecker, Type, resolve_interface?: boolean): Type, {Error}

      get_rets: function(TupleType): TupleType

      -- What evaluating a guard asks of this checker, made on first use.
      narrowing_host: narrowing.Host

      -- The call-like expressions met so far (`drop_all`), counted.
      drop_clock: integer
      -- The declarations of the file, whether a function literal assigns
      -- each, and the names assigned in one that no declaration seen
      -- binds (see `find_closure_assigned`).
      root_ast: Node
      closure_binders: {Node:boolean}
      label_back: {Node:boolean}
      closure_assigned: {Node:boolean}
      closure_loose: {string:boolean}
      -- Each binder's assignments in any function, each function literal
      -- and the loops around each binder, by node; and whether the file has
      -- a `goto`, after which the text order says nothing of what runs when.
      assignments: {Node:{Mark}}
      function_marks: {Node:Mark}
      binder_loops: {Node:{integer}}
      has_goto: boolean
      -- Set when an index was served by an `__index` metamethod that runs
      -- code, and by `check_metamethod` for the metamethod it found last.
      index_metamethod: boolean
      metamethod_ran: boolean
      -- What last dropped a fact, which a guard cut after it names, built
      -- from the node and the kind and text it was dropped with when asked
      -- for (`last_dropper`).
      last_drop: narrowing.Drop
      last_drop_node: Where
      last_drop_kind: string
      last_drop_text: string
      -- The loops being checked, innermost last, and a count of the reads
      -- they hold and the drops met, which orders them.
      loops: {narrowing.Loop}
      loop_tick: integer

      -- Declared where the record is, defined by the narrowing code below.
      binder_is_stable: function(TypeChecker, Node, string, Attribute): boolean
      call_text: function(TypeChecker, Node): string
      drop_all: function(TypeChecker, Where, string, ? string)
      last_dropper: function(TypeChecker): narrowing.Drop
      drop_through: function(TypeChecker, Node)
      may_dispatch: function(TypeChecker, Type, ? string): boolean
      may_be_table: function(TypeChecker, Type): boolean
      note_dropped: function(TypeChecker, Node, string)
      guard_before: function(TypeChecker, Node, Node): narrowing.Guard
      droppable: function(TypeChecker, narrowing.Place): boolean
      loop_begin: function(TypeChecker)
      label_is_looped: function(TypeChecker, Node): boolean
      scan_labels: function(TypeChecker, Node, {string:Node})
      loop_end: function(TypeChecker)
      record_read: function(TypeChecker, Node, string, ? Type)
      loop_dropped: function(TypeChecker, integer, string, narrowing.Drop)
      loops_forget_since: function(TypeChecker, integer)
      pure_iterator: function(TypeChecker, Node): boolean
      prune: function(TypeChecker, narrowing.Guard): narrowing.Guard
      runs_no_code: function(TypeChecker, Node, Type, TupleType): boolean
      written_name: function(TypeChecker, Node): string
      find_closure_assigned: function(TypeChecker, Node)
      local_is_fixed: function(TypeChecker, string, Node): boolean
      enter_function_body: function(TypeChecker, Node)
      macroexp_calls: function(TypeChecker, Node): boolean
   end

   local enum VarUse
      "use"
      "lvalue"
      "use_type"
      "check_only"
   end

   local function get_real_var_from_lower_scope(st: {Scope}, i: integer, name: string): Variable
      for j = i - 1, 1, -1 do
         local scope = st[j]
         local sv = scope.vars[name]
         if sv and ((not sv.is_specialized) or (sv.specialized_from)) then
            return sv
         end
      end
   end

   function TypeChecker:find_var(name: string, use?: VarUse): Variable, integer, Attribute
      for i = #self.st, 1, -1 do
         local scope = self.st[i]
         local var = scope.vars[name]
         if var then
            if use == "lvalue" and var.is_specialized and var.is_specialized ~= "localizing" then
               if var.specialized_from then
                  var.has_been_written_to = true
                  return { t = var.specialized_from, attribute = var.attribute }, i, var.attribute
               end
            else
               if i == 1 and var.needs_compat then
                  self.all_needs_compat[name] = true
               end

               local real_var = var
               if var.is_specialized and var.is_specialized ~= "localizing" then
                  real_var = get_real_var_from_lower_scope(self.st, i, name) or real_var
               end
               if use == "use_type" then
                  --var.used_as_type = true
                  real_var.used_as_type = true
               elseif use ~= "check_only" then
                  if use == "lvalue" then
                     --var.has_been_written_to = true
                     real_var.has_been_written_to = true
                  else
                     --var.has_been_read_from = true
                     real_var.has_been_read_from = true
                  end
               end

               return var, i, var.attribute
            end
         end
      end
   end

   function TypeChecker:simulate_g(): RecordType, Attribute
      -- this is a static approximation of _G
      local globals: {string:Type} = {}
      for k, v in pairs(self.st[1].vars) do
         if k:sub(1,1) ~= "@" then
            globals[k] = v.t
         end
      end
      return {
         typeid = globals_typeid,
         typename = "record",
         field_order = sorted_keys(globals),
         fields = globals,
      }, nil
   end

   local type ResolveFunction = function<T is Type>(t: T, all_same: boolean): T, boolean
   local type TypeFunction = function<S>(S, Type, ResolveFunction): Type, boolean
   local type TypeFunctionMap<S> = {TypeName: TypeFunction<S>}
   local map_type: function<S>(s: S, ty: Type, fns: TypeFunctionMap<S>): Type, {Error} = nil

   local fresh_typevar_fns: TypeFunctionMap<{TypeArgType}> = {
      ["typevar"] = function(typeargs: {TypeArgType}, t: TypeVarType, resolve: ResolveFunction): Type, boolean
         for _, ta in ipairs(typeargs) do
            if ta.typearg == t.typevar then
               return a_type(t, "typevar", {
                  typevar = (t.typevar:gsub("@.*", "")) .. "@" .. fresh_typevar_ctr,
                  constraint = t.constraint and resolve(t.constraint, false),
               } as TypeVarType), true
            end
         end
         return t, false
      end,
      ["typearg"] = function(typeargs: {TypeArgType}, t: TypeArgType, resolve: ResolveFunction): Type, boolean
         for _, ta in ipairs(typeargs) do
            if ta.typearg == t.typearg then
               return a_type(t, "typearg", {
                  typearg = (t.typearg:gsub("@.*", "")) .. "@" .. fresh_typevar_ctr,
                  constraint = t.constraint and resolve(t.constraint, false),
               } as TypeArgType), true
            end
         end
         return t, false
      end,
   }

   local function fresh_typeargs(self: TypeChecker, g: GenericType): GenericType
      fresh_typevar_ctr = fresh_typevar_ctr + 1

      local newg, errs = map_type(g.typeargs, g, fresh_typevar_fns)
      if newg is InvalidType then
         self.errs:collect(errs)
         return g
      end
      assert(newg is GenericType, "Internal Compiler Error: error creating fresh type variables")
      assert(newg ~= g)
      newg.fresh = true

      return newg
   end

   local function wrap_generic_if_typeargs<T is Type>(typeargs: {TypeArgType}, t: T): T | GenericType
      if not typeargs then
         return t
      end

      assert(not t is TypeDeclType)

      local gt = a_type(t, "generic", { t = t } as GenericType)
      gt.typeargs = typeargs
      return gt
   end

   function TypeChecker:find_var_type(name: string, use?: VarUse): Type, Attribute, Type
      local var = self:find_var(name, use)
      if var then
         local t = var.t
         if t is UnresolvedTypeArgType then
            return nil, nil, t.constraint
         end

         if t is GenericType then
            t = fresh_typeargs(self, t)
         end

         return t, var.attribute
      end
   end

   local function ensure_not_method<T is Type>(t: T): T

      if t is GenericType then
         local tt = ensure_not_method(t.t)
         if tt ~= t.t then
            local gg = shallow_copy_new_type(t)
            gg.t = tt
            return gg
         end
      end

      if t is FunctionType and t.is_method then
         t = shallow_copy_new_type(t)
         (t as FunctionType).is_method = false
      end
      return t
   end

   local function unwrap_for_find_type(typ: Type): Type
      if typ is NominalType and typ.found then
         return unwrap_for_find_type(typ.found)
      elseif typ is TypeDeclType then
         return unwrap_for_find_type(typ.def)
      elseif typ is GenericType then
         return unwrap_for_find_type(typ.t)
      end
      return typ
   end

   function TypeChecker:find_type(names: {string}): TypeDeclType, TypeArgType
      local typ = self:find_var_type(names[1], "use_type")
      if not typ then
         if #names == 1 and names[1] == "metatable" then
            return self:find_type({"_metatable"})
         end
         return nil
      end
      for i = 2, #names do
         typ = unwrap_for_find_type(typ)
         if typ == nil then
            return nil
         end

         local fields = typ is RecordLikeType and typ.fields
         if not fields then
            return nil
         end

         typ = fields[names[i]]
         if typ == nil then
            return nil
         end
      end

      -- FIXME doing this at the and lets all nominals be used as types (see #891)
      if typ and typ is NominalType then
         typ = typ.found
      end
      if typ == nil then
         return nil
      end

      if typ is TypeDeclType then
         return typ
      elseif typ is TypeArgType then
         return nil, typ
      end
   end

   local function type_for_union(t: Type): string, Type
      if t is TypeDeclType then
         return type_for_union(t.def)
      elseif t is TupleType then
         return type_for_union(t.tuple[1]), t.tuple[1]
      elseif t is NominalType then
         local typedecl = t.found
         if not typedecl then
            return "invalid"
         end
         return type_for_union(typedecl)
      elseif t is RecordLikeType then
         if t.is_userdata then
            return "userdata", t
         end
         return "table", t
      elseif t is GenericType then
         return type_for_union(t.t)
      elseif table_types[t.typename] then
         return "table", t
      else
         return t.typename, t
      end
   end

   local function is_valid_union(typ: UnionType): boolean, string
      -- check for limitations in our union support
      -- due to codegen limitations (we only check with type() so far)
      local n_table_types = 0
      local n_table_is_types = 0
      local n_function_types = 0
      local n_userdata_types = 0
      local n_userdata_is_types = 0
      local n_string_enum = 0
      local has_primitive_string_type = false
      for _, t in ipairs(typ.types) do
         local ut, rt = type_for_union(t)
         if ut == "userdata" then -- must be tested before table_types
            assert(rt is RecordLikeType)
            if rt.meta_fields and rt.meta_fields["__is"] then
               n_userdata_is_types = n_userdata_is_types + 1
               if n_userdata_types > 0 then
                  return false, "cannot mix userdata types with and without __is metamethod: %s"
               end
            else
               n_userdata_types = n_userdata_types + 1
               if n_userdata_types > 1 then
                  return false, "cannot discriminate a union between multiple userdata types: %s"
               end
               if n_userdata_is_types > 0 then
                  return false, "cannot mix userdata types with and without __is metamethod: %s"
               end
            end
         elseif ut == "table" then
            if rt is RecordLikeType and rt.meta_fields and rt.meta_fields["__is"] then
               n_table_is_types = n_table_is_types + 1
               if n_table_types > 0 then
                  return false, "cannot mix table types with and without __is metamethod: %s"
               end
            else
               n_table_types = n_table_types + 1
               if n_table_types > 1 then
                  return false, "cannot discriminate a union between multiple table types: %s"
               end
               if n_table_is_types > 0 then
                  return false, "cannot mix table types with and without __is metamethod: %s"
               end
            end
         elseif ut == "function" then
            n_function_types = n_function_types + 1
            if n_function_types > 1 then
               return false, "cannot discriminate a union between multiple function types: %s"
            end
         elseif ut == "enum" or (ut == "string" and not has_primitive_string_type) then
            n_string_enum = n_string_enum + 1
            if n_string_enum > 1 then
               return false, "cannot discriminate a union between multiple string/enum types: %s"
            end
            if ut == "string" then
               has_primitive_string_type = true
            end
         elseif ut == "invalid" then
            return false, nil -- error message comes from invalid type
         end
      end
      return true
   end

   local function show_arity(f: FunctionType): string
      local nfargs = #f.args.tuple
      if f.min_arity < nfargs then
         if f.min_arity > 0 then
            return "at least " .. f.min_arity .. (f.args.is_va and "" or " and at most " .. nfargs)
         else
            return (f.args.is_va and "any number" or "at most " .. nfargs)
         end
      else
         return tostring(nfargs or 0)
      end
   end

   local function drop_constant_value(t: Type): Type
      if t is StringType and t.literal then
         local ret = shallow_copy_new_type(t)
         ret.literal = nil
         return ret
      elseif t.needs_compat then
         local ret = shallow_copy_new_type(t)
         ret.needs_compat = nil
         return ret
      end
      return t
   end

   local function resolve_typedecl(t: Type): Type
      if t is TypeDeclType then
         return t.def
      else
         return t
      end
   end

   local no_nested_types: {string:boolean} = {
      ["string"] = true,
      ["number"] = true,
      ["integer"] = true,
      ["boolean"] = true,
      ["thread"] = true,
      ["any"] = true,
      ["enum"] = true,
      ["nil"] = true,
      ["unknown"] = true,
   }

   local resolve_typevars: function(self: TypeChecker, t: Type): FirstClassType, {Error}
   do
      local record ResolveTypeVarState
         tc: TypeChecker
         resolved: {string:Type}
      end

      local resolve_typevar_fns: TypeFunctionMap<ResolveTypeVarState> = {
         ["typevar"] = function(s: ResolveTypeVarState, t: TypeVarType): Type, boolean
            local rt = s.tc:find_var_type(t.typevar)
            if not rt then
               return t, false
            end

            rt = drop_constant_value(rt)
            s.resolved[t.typevar] = rt

            return rt, true
         end,
      }

      local function clear_resolved_typeargs(copy: GenericType, resolved: {string:Type}): Type
         for i = #copy.typeargs, 1, -1 do
            local r = resolved[copy.typeargs[i].typearg]
            if r then
               table.remove(copy.typeargs, i)
            end
         end
         if not copy.typeargs[1] then
            return copy.t
         end
         return copy
      end

      resolve_typevars = function(self: TypeChecker, t: Type): Type, {Error}
         local state: ResolveTypeVarState = {
            tc = self,
            resolved = {},
         }
         local rt, errs = map_type(state, t, resolve_typevar_fns)
         if errs then
            return rt, errs
         end

         if rt is GenericType then
            rt = clear_resolved_typeargs(rt, state.resolved)
         end

         return rt
      end
   end

   map_type = function<S>(self: S, ty: Type, fns: TypeFunctionMap<S>): Type, {Error}
      local errs: {Error} = nil
      local seen: {Type:Type} = {}
      local resolve: ResolveFunction = nil

      resolve = function<T is Type>(t: T, all_same: boolean): T, boolean
         local same = true

         -- avoid copies of types that do not contain type variables
         if no_nested_types[t.typename] or (t is NominalType and not t.typevals) then
            return t, all_same
         end

         if seen[t] then
            return seen[t], all_same
         end

         local orig_t = t
         local fn = fns[t.typename]
         if fn then
            local rt, is_resolved = fn(self, t, resolve)
            if rt ~= t then
               if is_resolved then
                  seen[t] = rt
                  return rt, false
               end
               return resolve(rt, false)
            end
         end

         local copy: Type = {}
         seen[orig_t] = copy

         setmetatable(copy, type_mt)
         copy.typename = t.typename
         copy.f = t.f
         copy.x = t.x
         copy.y = t.y

         if t is GenericType then
            assert(copy is GenericType)

            local ct = {}
            for i, tf in ipairs(t.typeargs) do
               ct[i], same = resolve(tf, same)
            end
            copy.typeargs = ct
            copy.t, same = resolve(t.t, same)
         elseif t is ArrayType then
            assert(copy is ArrayType)

            copy.elements, same = resolve(t.elements, same)
            -- inferred_len is not propagated
         elseif t is TypeArgType then
            assert(copy is TypeArgType)
            copy.typearg = t.typearg
            if t.constraint then
               copy.constraint, same = resolve(t.constraint, same)
            end
         elseif t is UnresolvableTypeArgType then
            assert(copy is UnresolvableTypeArgType)
            copy.typearg = t.typearg
         elseif t is UnresolvedEmptyTableValueType then
            assert(copy is UnresolvedEmptyTableValueType)
            copy.emptytable_type = t.emptytable_type
         elseif t is TypeVarType then
            assert(copy is TypeVarType)
            copy.typevar = t.typevar
            if t.constraint then
               copy.constraint, same = resolve(t.constraint, same)
            end
         elseif t is TypeDeclType then
            assert(copy is TypeDeclType)
            copy.def, same = resolve(t.def, same)
            copy.is_alias = t.is_alias
            copy.is_nested_alias = t.is_nested_alias
         elseif t is NominalType then
            assert(copy is NominalType)
            copy.names = t.names
            copy.typevals = {}
            for i, tf in ipairs(t.typevals) do
               copy.typevals[i], same = resolve(tf, same)
            end
            copy.found = t.found
         elseif t is FunctionType then
            assert(copy is FunctionType)
            copy.macroexp = t.macroexp
            copy.min_arity = t.min_arity
            copy.is_method = t.is_method
            copy.is_record_function = t.is_record_function
            copy.args, same = resolve(t.args, same) as (TupleType, boolean)
            copy.rets, same = resolve(t.rets, same) as (TupleType, boolean)
            copy.special_function_handler = t.special_function_handler
            copy.pure_std = t.pure_std
            copy.never = t.never
         elseif t is RecordLikeType then
            assert(copy is RecordType or copy is InterfaceType)
            copy.declname = t.declname

            -- checking array interface
            if t.elements then
               copy.elements, same = resolve(t.elements, same)
            end

            if t.interface_list then
               copy.interface_list = {}
               for i, v in ipairs(t.interface_list) do
                  copy.interface_list[i], same = resolve(v, same)
               end
            end

            copy.is_userdata = t.is_userdata

            copy.fields = {}
            copy.field_order = {}
            copy.field_comments = t.field_comments
            for i, k in ipairs(t.field_order) do
               copy.field_order[i] = k
               copy.fields[k], same = resolve(t.fields[k], same)
            end

            if t.meta_fields then
               copy.meta_fields = {}
               copy.meta_field_order = {}
               copy.meta_field_comments = t.meta_field_comments
               for i, k in ipairs(t.meta_field_order) do
                  copy.meta_field_order[i] = k
                  copy.meta_fields[k], same = resolve(t.meta_fields[k], same)
               end
            end
         elseif t is MapType then
            assert(copy is MapType)
            copy.keys, same = resolve(t.keys, same)
            copy.values, same = resolve(t.values, same)
         elseif t is UnionType then
            assert(copy is UnionType)
            copy.types = {}
            for i, tf in ipairs(t.types) do
               copy.types[i], same = resolve(tf, same)
            end

            local _, err = is_valid_union(copy)
            if err then
               errs = errs or {}
               table.insert(errs, Err(err, copy))
            end
         elseif t is PolyType then
            assert(copy is PolyType)
            copy.types = {}
            for i, tf in ipairs(t.types) do
               copy.types[i], same = resolve(tf, same)
            end
         elseif t is TupleTableType then
            assert(copy is TupleTableType)
            copy.inferred_at = t.inferred_at
            copy.types = {}
            for i, tf in ipairs(t.types) do
               copy.types[i], same = resolve(tf, same)
            end
         elseif t is TupleType then
            assert(copy is TupleType)
            copy.is_va = t.is_va
            copy.tuple = {}
            for i, tf in ipairs(t.tuple) do
               copy.tuple[i], same = resolve(tf, same)
            end
         elseif t is SelfType then
            assert(copy is SelfType)
            if t.display_type ~= nil then
               copy.display_type, same = resolve(t.display_type, same)
            end
         end

         copy.typeid = same and t.typeid or new_typeid()
         return copy, same and all_same
      end

      local copy = resolve(ty, true)
      if errs then
         return an_invalid(ty), errs
      end

      return copy
   end

   function TypeChecker:infer_emptytable(emptytable: EmptyTableType, fresh_t: Type)
      local is_global = (emptytable.declared_at and emptytable.declared_at.kind == "global_declaration")
      local nst = is_global and 1 or #self.st
      for i = nst, 1, -1 do
         local scope = self.st[i]
         if scope.vars[emptytable.assigned_to] then
            scope.vars[emptytable.assigned_to] = { t = fresh_t }
         end
      end
   end

   local function resolve_tuple(t: Type): Type
      local rt = t
      if rt is TupleType then
         rt = rt.tuple[1]
      end
      if rt == nil then
         return a_type(t, "nil", {})
      end
      return rt
   end

   function TypeChecker:check_if_redeclaration(new_name: string, node: Node, t: Type)
      local old: Variable = nil
      if simple_types[new_name as TypeName] then
         if t.typename ~= "typedecl" then
            old = self:find_var(new_name, "check_only")
            local hidden = old and old.t
            if not hidden or not (hidden is TypeDeclType) or hidden.def.typename ~= "record" then
               return
            end
         end
      else
         old = self:find_var(new_name, "check_only")
         if not old then
            return
         end
      end
      local var_name = node.tk
      local var_kind = "variable"
      if node.kind == "local_function" or node.kind == "record_function" then
         var_kind = "function"
         var_name = node.name.tk
      end
      self.errs:redeclaration_warning(node, var_name, var_kind, old)
   end

   local function type_at<T is Type>(w: Where, t: T): T
      t.x = w.x
      t.y = w.y
      return t
   end

   function TypeChecker:assert_resolved_typevars_at(w: Where, t: Type): Type
      local ret, errs = resolve_typevars(self, t)
      if errs then
         assert(w.y)
         self.errs:add_prefixing(w, errs, "")
      end

      -- recurse until fixed point
      if ret.typeid ~= t.typeid then
         return self:assert_resolved_typevars_at(w, ret)
      end

      if ret == t or t is TypeVarType then
         ret = shallow_copy_new_type(ret)
      end
      return type_at(w, ret)
   end

   function TypeChecker:infer_at<T is Type>(w: Where, t: T): T
      local ret = self:assert_resolved_typevars_at(w, t)
      if ret is InvalidType then
         ret = t -- errors are produced by assert_resolved_typevars_at
      end

      if ret == t or t is TypeVarType then
         ret = shallow_copy_new_type(ret)
      end
      assert(w.f)
      ret.inferred_at = w
      return ret
   end

   do
      local function specialize_var(scope: Scope, node: Node, name: string, t: Type, attribute: Attribute, specialization: Specialization): Variable
         local var = scope.vars[name]
         if specialization == "localizing" then
            -- `local x = x` declares a variable of its own, even where the
            -- scope holds one of the name already (a parameter, an earlier
            -- local): not a narrowing of that one.
            var = nil
         end
         if var then
            if var.is_specialized then
               -- A name widened in this scope and narrowed again keeps the
               -- widening, which the end of the scope reads, and so does a
               -- local declared `local x = x` that is narrowed: both record
               -- the type to widen to, or nothing could drop the fact.
               if (var.is_specialized == "widen" or var.is_specialized == "localizing")
                  and specialization ~= "widen" then
                  var.widened_from = var.widened_from or var.t
                  scope.narrows = scope.narrows or {}
                  scope.narrows[name] = true
               end
               var.t = t
               return var
            end

            var.is_specialized = specialization
            var.specialized_from = var.t
            var.t = t
         else
            var = { t = t, attribute = attribute, is_specialized = specialization, declared_at = node }
            scope.vars[name] = var
         end

         if specialization == "widen" then
            scope.widens = scope.widens or {}
            scope.widens[name] = true
         else
            scope.narrows = scope.narrows or {}
            scope.narrows[name] = true
         end

         return var
      end

      function TypeChecker:add_var(node: Node, name: string, t: Type, attribute?: Attribute, specialization?: Specialization): Variable

         if self.feat_lax and node and is_unknown(t) and (name ~= "self" and name ~= "...") and not specialization then
            self.errs:add_unknown(node, name)
         end
         if not attribute then
            t = drop_constant_value(t)
         end

         if self.collector and node then
            self.collector.add_to_symbol_list(node, name, t)
         end

         local scope <const> = self.st[#self.st]
         if specialization then
            return specialize_var(scope, node, name, t, attribute, specialization)
         end

         if node then
            if name ~= "self" and name ~= "..." and name:sub(1, 1) ~= "@" then
               self:check_if_redeclaration(name, node, t)
            end
            if not ensure_not_abstract(t) then
               node.elide_type = true
            end
         end

         local var = scope.vars[name]
         if var and not has_var_been_used(var) then
            -- the old var is removed from the scope and won't be checked when it closes,
            -- so check it here
            self.errs:unused_warning(name, var)
         end

         var = { t = t, attribute = attribute, declared_at = node }
         scope.vars[name] = var

         return var
      end
   end

   local type CompareTypes = function(TypeChecker, Type, Type): boolean, {Error}

   function TypeChecker:has_all_types_of(t1s: {Type}, t2s: {Type}): boolean
      for _, t1 in ipairs(t1s) do
         local found = false
         for _, t2 in ipairs(t2s) do
            if self:same_type(t2, t1) then
               found = true
               break
            end
         end
         if not found then
            return false
         end
      end
      return true
   end

   local function any_errors(all_errs: {Error}): boolean, {Error}
      if #all_errs == 0 then
         return true
      else
         return false, all_errs
      end
   end

   local function close_nested_records(t: TypeDeclType)
      if t.closed then
         return
      end
      local tdef = t.def
      if tdef is RecordLikeType then
         t.closed = true
         for _, ft in pairs(tdef.fields) do
            if ft is TypeDeclType then
               close_nested_records(ft)
            end
         end
      end
   end

   local function close_types(scope: Scope)
      for _, var in pairs(scope.vars) do
         local t = var.t
         if t is TypeDeclType then
            close_nested_records(t)
         end
      end
   end

   -- What is known of a place (checker/narrowing.tl) lives on the scope
   -- stack under the place's key: a variable narrowed from the one below
   -- (`add_var` with "narrow"), listed in its scope's `narrows`. Assigning
   -- a local widens it back to its declared type: `widen_back_var` at the
   -- assignment; `widen_all_unions` for every narrowed name at the start
   -- of a function, at a label and at a function value assigned, and for
   -- the names a loop assigns, at the loop; `widen_all` for the names the
   -- branches of an `if`, or a scope, widened, when it ends. Assigning a
   -- field drops what is known of it before the value is checked
   -- (`narrowing.drop`).
   function TypeChecker:widen_in_scope(n: integer, var: string): boolean
      local scope = self.st[n]
      local v = scope.vars[var]
      assert(v, "no " .. var .. " in scope")
      local specialization = scope.vars[var].is_specialized
      if (specialization == "widen" or specialization == "localizing") and v.widened_from then
         v.t = v.widened_from
         v.widened_from = nil
         if scope.narrows and specialization == "widen" then
            scope.narrows[var] = nil
         end
         return true
      end
      if (not specialization)
         or not (specialization == "narrow"
         or specialization == "narrowed_declaration")
      then
         return false
      end

      local top = #self.st
      if n ~= top then
         local t = v.specialized_from
         if not t then
            local old: Variable
            for i = n - 1, 1, -1 do
               old = self.st[i].vars[var]
               if old then
                  if old.specialized_from then
                     t = old.specialized_from
                     break
                  elseif old.is_specialized == "localizing" or not old.is_specialized then
                     t = old.t
                     break
                  end
               end
            end

            -- this should only trigger in generated compat code
            if not t then
               return false
            end
         end
         self:add_var(nil, var, t, nil, "widen")
         return true
      end

      if v.specialized_from then
         v.t = v.specialized_from
         v.specialized_from = nil
         v.is_specialized = nil
      else
         scope.vars[var] = nil
      end

      if scope.narrows then
         scope.narrows[var] = nil
      end

      return true
   end

   -- Whether no function literal assigns the local that `node`, a binder
   -- the file's pre-pass saw, declares as `name`. A `<const>` or `<close>`
   -- local is assigned by nothing. A binder the pre-pass did not see is
   -- not stable: a call may change it. The pre-pass runs when this is first
   -- asked.
   function TypeChecker:binder_is_stable(node: Node, name: string, attribute?: Attribute): boolean
      if attribute == "const" or attribute == "close" then
         return true
      end
      if not node then
         return false
      end
      if not self.closure_binders then
         self:find_closure_assigned(self.root_ast)
      end
      return self.closure_binders[node] == true
         and not self.closure_assigned[node]
         and not self.closure_loose[name]
   end

   -- Whether a call leaves what is known of the local `name`: no function
   -- literal in its scope assigns it. A name with no declaration of the
   -- file's own (a global) is not stable.
   function TypeChecker:local_is_stable(name: string): boolean
      for i = #self.st, 1, -1 do
         local var = self.st[i].vars[name]
         if var and ((not var.is_specialized) or var.specialized_from or var.is_specialized == "localizing") then
            if var.stable == nil then
               var.stable = self:binder_is_stable(var.declared_at, name, var.attribute)
            end
            return var.stable
         end
      end
      return false
   end

   -- Whether no assignment to the local `name` can run after the function
   -- literal `literal` is made, in any function: the literal may keep a test
   -- of it, as the local is the same whenever the literal runs. An
   -- assignment runs after it if a function literal makes it, if it comes
   -- after the literal in the text, or if both are in a loop that the local
   -- is not declared in (a later pass runs it); a file with a `goto` takes
   -- every assignment to. A name with no declaration of the file's own is
   -- not fixed.
   function TypeChecker:local_is_fixed(name: string, literal: Node): boolean
      for i = #self.st, 1, -1 do
         local var = self.st[i].vars[name]
         if var and ((not var.is_specialized) or var.specialized_from or var.is_specialized == "localizing") then
            local node = var.declared_at
            if var.attribute == "const" or var.attribute == "close" then
               return true
            end
            if not self:binder_is_stable(node, name, var.attribute) then
               return false
            end
            local made = self.function_marks[literal]
            if not made then
               return false
            end
            local writes = self.assignments[node]
            if not writes then
               return true
            end
            if self.has_goto then
               return false
            end
            local outside: {integer:boolean} = {}
            for _, id in ipairs(self.binder_loops[node] or {}) do
               outside[id] = true
            end
            local inside: {integer:boolean} = {}
            for _, id in ipairs(made.loops) do
               if not outside[id] then
                  inside[id] = true
               end
            end
            for _, write in ipairs(writes) do
               if write.order > made.order then
                  return false
               end
               for _, id in ipairs(write.loops) do
                  if inside[id] then
                     return false
                  end
               end
            end
            return true
         end
      end
      return false
   end

   -- Finds, before the file is checked, the locals that a function literal
   -- assigns: a call may run it, so a call drops what is known of them. It
   -- walks the file with the scopes the program has, binding each name
   -- where the checker will declare it, and resolves an assignment's name
   -- to the innermost binding in scope. A binding made in a function
   -- other than the one that assigns it is assigned by a closure.
   -- `closure_loose` holds the names assigned in a function literal that
   -- resolve to no binding seen (a global, or a binder the walk does not
   -- know), which makes every local of the name unstable.
   --
   -- The statements are walked by kind, for the scopes they open and the
   -- names they bind; an expression is walked through every node it holds,
   -- since only a function literal in it matters and a scope is the same
   -- all through it.
   function TypeChecker:find_closure_assigned(root: Node)
      local binders: {Node:boolean} = {}
      local assigned: {Node:boolean} = {}
      local writes: {Node:{Mark}} = {}
      local marks: {Node:Mark} = {}
      local binder_loops: {Node:{integer}} = {}
      local any_goto = false
      local order = 0
      local loop_ids: {integer} = {}
      local loops_made = 0
      local loose: {string:boolean} = {}
      local depth_of: {Node:integer} = {}
      local scopes: {{string:Node}} = {}
      local depth = 0

      local function loops_now(): {integer}
         local copy: {integer} = {}
         for i, id in ipairs(loop_ids) do
            copy[i] = id
         end
         return copy
      end
      local function loop_open()
         loops_made = loops_made + 1
         table.insert(loop_ids, loops_made)
      end
      local function loop_close()
         table.remove(loop_ids)
      end
      local function tick(): integer
         order = order + 1
         return order
      end

      local function bind(node: Node, name: string)
         if name and #scopes > 0 then
            scopes[#scopes][name] = node
            binders[node] = true
            depth_of[node] = depth
            binder_loops[node] = loops_now()
         end
      end
      local function resolve(name: string)
         for i = #scopes, 1, -1 do
            local binder = scopes[i][name]
            if binder then
               local list = writes[binder]
               if not list then
                  list = {}
                  writes[binder] = list
               end
               table.insert(list, { order = tick(), loops = loops_now() })
               if depth_of[binder] < depth then
                  assigned[binder] = true
               end
               return
            end
         end
         if depth > 0 then
            loose[name] = true
         end
      end

      local walk_expression: function(Node) = nil
      local walk_statement: function(Node) = nil
      local walk_block: function(Node) = nil

      -- The body of a function, or the expression of a macro expression,
      -- with its arguments bound.
      local function walk_function(node: Node)
         marks[node] = { order = tick(), loops = loops_now() }
         depth = depth + 1
         table.insert(scopes, {})
         for _, argument in ipairs(node.args or {}) do
            bind(argument, argument.tk)
         end
         if node.body then
            walk_block(node.body)
         end
         if node.exp then
            walk_expression(node.exp)
         end
         table.remove(scopes)
         depth = depth - 1
      end

      walk_expression = function(n: Node)
         local kind = n.kind
         if kind == "function" or kind == "macroexp" then
            walk_function(n)
            return
         end
         for key, child in pairs(n as {any:any}) do
            if key ~= "if_parent" and key ~= "fn_owner" and type(child) == "table" then
               local node = child as Node
               if node.kind then
                  walk_expression(node)
               end
            end
         end
      end

      walk_block = function(block: Node)
         table.insert(scopes, {})
         for _, statement in ipairs(block) do
            walk_statement(statement)
         end
         table.remove(scopes)
      end

      walk_statement = function(s: Node)
         local kind = s.kind
         if kind == "local_declaration" then
            if s.exps then
               walk_expression(s.exps)
            end
            for _, v in ipairs(s.vars) do
               bind(v, v.tk)
            end
         elseif kind == "assignment" then
            if s.exps then
               walk_expression(s.exps)
            end
            for _, v in ipairs(s.vars) do
               if v.kind == "variable" then
                  resolve(v.tk)
               else
                  walk_expression(v)
               end
            end
         elseif kind == "local_function" then
            bind(s, s.name.tk)
            walk_function(s)
         elseif kind == "global_function" or kind == "record_function" then
            walk_function(s)
         elseif kind == "local_macroexp" then
            bind(s, s.name.tk)
            walk_function(s.macrodef)
         elseif kind == "if" then
            for _, block in ipairs(s.if_blocks) do
               if block.exp then
                  walk_expression(block.exp)
               end
               walk_block(block.body)
            end
         elseif kind == "while" then
            loop_open()
            walk_expression(s.exp)
            walk_block(s.body)
            loop_close()
         elseif kind == "repeat" then
            -- The condition sees the body's locals.
            loop_open()
            table.insert(scopes, {})
            for _, statement in ipairs(s.body) do
               walk_statement(statement)
            end
            walk_expression(s.exp)
            table.remove(scopes)
            loop_close()
         elseif kind == "fornum" then
            walk_expression(s.from)
            walk_expression(s.to)
            if s.step then
               walk_expression(s.step)
            end
            loop_open()
            table.insert(scopes, {})
            bind(s.var, s.var.tk)
            walk_block(s.body)
            table.remove(scopes)
            loop_close()
         elseif kind == "forin" then
            walk_expression(s.exps)
            loop_open()
            table.insert(scopes, {})
            for _, v in ipairs(s.vars) do
               bind(v, v.tk)
            end
            walk_block(s.body)
            table.remove(scopes)
            loop_close()
         elseif kind == "do" then
            walk_block(s.body)
         elseif kind == "return" or kind == "global_declaration" then
            if s.exps then
               walk_expression(s.exps)
            end
         elseif kind == "goto" then
            any_goto = true
         elseif kind == "break" or kind == "label" or kind == "local_type"
            or kind == "global_type" or kind == "pragma" then
            return
         else
            walk_expression(s)
         end
      end

      walk_block(root)
      self.closure_binders = binders
      self.closure_assigned = assigned
      self.closure_loose = loose
      self.assignments = writes
      self.function_marks = marks
      self.binder_loops = binder_loops
      self.has_goto = any_goto
   end

   function TypeChecker:widen_back_var(name: string): boolean
      local widened = false
      for i = #self.st, 1, -1 do
         local scope = self.st[i]
         if scope.vars[name] then
            if self:widen_in_scope(i, name) then
               widened = true
            else
               break
            end
         end
      end
      return widened
   end

   function TypeChecker:collect_if_widens(widens: {string:boolean}): {string:boolean}
      local st = self.st
      local scope = st[#st]
      if scope.widens then
         widens = widens or {}
         for k, _ in pairs(scope.widens) do
            widens[k] = true
         end
         scope.widens = nil
      end
      return widens
   end

   function TypeChecker:widen_all(widens: {string:boolean}, widen_types: {string:Type})
      for name, _ in pairs(widens) do
         local curr = self:find_var(name, "check_only")
         local prev = widen_types[name]
         if (not prev) or (curr and not self:same_type(curr.t, prev)) then
            self:widen_back_var(name)
         end
      end
   end

   function TypeChecker:begin_scope(node?: Node)
      table.insert(self.st, { vars = {} })

      if self.collector and node then
         self.collector.begin_symbol_list_scope(node)
      end
   end

   function TypeChecker:end_scope(node?: Node)
      local st = self.st
      local scope = st[#st]

      local widen_types: {string:Type} = nil
      if scope.widens then
         widen_types = {}
         for name, _ in pairs(scope.widens) do
            local var = self:find_var(name, "check_only")
            widen_types[name] = var.t
         end
      end

      table.remove(st)
      local next_scope = st[#st]

      assert(not scope.is_transaction)

      close_types(scope)
      self.errs:check_var_usage(scope)

      if scope.widens then
         self:widen_all(scope.widens, widen_types)
      end

      if self.collector and node then
         self.collector.end_symbol_list_scope(node)
      end

      if not next_scope then
         return
      end

      if scope.pending_labels then
         if next_scope.pending_labels then
            for name, nodes in pairs(scope.pending_labels) do
               for _, n in ipairs(nodes) do
                  next_scope.pending_labels[name] = next_scope.pending_labels[name] or {}
                  table.insert(next_scope.pending_labels[name], n)
               end
            end
         else
            next_scope.pending_labels = scope.pending_labels
         end
      end

      if scope.pending_nominals then
         if next_scope.pending_nominals then
            for name, types in pairs(scope.pending_nominals) do
               for _, typ in ipairs(types) do
                  next_scope.pending_nominals[name] = next_scope.pending_nominals[name] or {}
                  table.insert(next_scope.pending_nominals[name], typ)
               end
            end
         else
            next_scope.pending_nominals = scope.pending_nominals
         end
      end
   end

   function TypeChecker:begin_scope_transaction(node: Node)
      self:begin_scope(node)
      local st = self.st
      st[#st].is_transaction = true
   end

   function TypeChecker:rollback_scope_transaction()
      local st = self.st
      local scope = st[#st]
      assert(scope.is_transaction)

      local vars = scope.vars
      for k, _ in pairs(vars) do
         vars[k] = nil
      end

      if self.collector then
         self.collector.rollback_symbol_list_scope()
      end
   end

   function TypeChecker:commit_scope_transaction(node: Node)
      local st = self.st
      local scope = st[#st]
      local next_scope = st[#st - 1]

      assert(scope.is_transaction)
      assert(not scope.pending_labels)
      assert(not scope.pending_nominals)

      for name, var in pairs(scope.vars) do
         local t = var.t
         next_scope.vars[name] = var
         assert(t)
      end

      table.remove(st)

      if self.collector and node then
         self.collector.end_symbol_list_scope(node)
      end
   end

   -- This type must never be used for any values
   local NONE = a_type({ f = "@none", x = -1, y = -1 }, "none", {})

   local function end_scope_and_none_type(self: TypeChecker, node: Node, _children: {Type}): Type
      self:end_scope(node)
      return NONE
   end

   local function unresolved_typeargs_for(g: GenericType): {Type}
      local ts = {}
      for _, ta in ipairs(g.typeargs) do
         table.insert(ts, a_type(ta, "unresolved_typearg", {
            constraint = ta.constraint
         } as UnresolvedTypeArgType))
      end
      return ts
   end

   function TypeChecker:apply_generic(w: Where, g: GenericType, typeargs?: {Type}): FirstOrderType, {TypeArgType}
      if not g.fresh then
         g = fresh_typeargs(self, g)
      end

      if not typeargs then
         typeargs = unresolved_typeargs_for(g)
      end

      assert(#g.typeargs == #typeargs)

      for i, ta in ipairs(g.typeargs) do
         self:add_var(nil, ta.typearg, typeargs[i])
      end
      local applied, errs = resolve_typevars(self, g)
      if errs then
         self.errs:add_prefixing(w, errs, "")
         return nil
      end

      if applied is GenericType then
         return applied.t, g.typeargs
      else
         return applied, g.typeargs
      end
   end

   local type InvalidOrTypeDeclType = InvalidType | TypeDeclType

   do
      local function check_metatable_contract(self: TypeChecker, tv: Type, ret: Type)
         if not ret or not tv is NominalType then
            return
         end
         local found = tv.found
         if not found then
            return
         end
         local rec = found.def
         if (rec is RecordLikeType or rec is GenericType) and ret is RecordLikeType then
            ret.fields["__index"] = a_union(tv, {
               tv,
               a_function(tv, {
                  min_arity = 2,
                  args = a_tuple(tv, { tv, a_type(tv, "any", {}) }),
                  rets = a_vararg(tv, { a_type(tv, "any", {}) }),
               }),
            })
         end
         -- TODO: hold a generic record's metamethods to a metatable too: meta_fields is read only of a record that is not generic, as T is not yet applied to a generic one's.
         if not (rec is RecordLikeType and rec.meta_fields and ret is RecordLikeType) then
            return
         end
         for fname, ftype in pairs(rec.meta_fields) do
            if ret.fields[fname] then
               if not self:is_a(ftype, ret.fields[fname]) then
                  self.errs:add_coded(ftype, Errors.nest(Errors.mismatch(Errors.make(), ftype, ret.fields[fname])),
                     fname .. " does not follow metatable contract: got %s, expected %s", ftype, ret.fields[fname])
               end
            end
            ret.fields[fname] = ftype
         end
      end

      local function match_typevals(self: TypeChecker, t: NominalType, def: GenericType): Type
         if not t.typevals then
            -- HACK: accept function nominal without arguments
            local deft = def.t
            if (not deft is FunctionType) and (not deft is PolyType) then
               local declared = def.t
               local typeargs: {string} = {}
               for _, typearg in ipairs(def.typeargs) do
                  table.insert(typeargs, show_type(typearg))
               end
               self.errs:add_coded(t, Errors.make({
                  code = "missing_type_arguments",
                  subject_kind = declared.typename,
                  names = declared is RecordLikeType and declared.declname and { declared.declname } or nil,
                  type_arguments = typeargs,
               }), "missing type arguments in %s", def)
               return nil
            end
         elseif #t.typevals ~= #def.typeargs then
            self.errs:add(t, "mismatch in number of type arguments")
            return nil
         end

         self:begin_scope()

         local ret = self:apply_generic(t, def, t.typevals)
         if def == self.cache_std_metatable_type then
            check_metatable_contract(self, t.typevals[1], ret)
         end

         self:end_scope()

         return ret
      end

      local function find_nominal_type_decl(self: TypeChecker, t: NominalType): Type, TypeDeclType
         if t.resolved then
            return t.resolved
         end

         local found = t.found or self:find_type(t.names)
         if not found then
            return self.errs:invalid_coded(t, Errors.make({ code = "unknown_type", names = t.names, subject = show_type(t) }), "unknown type %s", t)
         end

         if found is TypeDeclType and found.is_alias then
            local def = found.def
            if def is NominalType then
               found = def.found
            end
            -- if found.def is GenericType, return found as-is
         end

         if not found then
            return self.errs:invalid_at(t, table.concat(t.names, ".") .. " is not a resolved type")
         end

         if not found is TypeDeclType then
            return self.errs:invalid_at(t, table.concat(t.names, ".") .. " is not a type")
         end

         local def = found.def
         if def.typename == "circular_require" then
            -- return, but do not store resolution
            return def
         end

         assert(not def is NominalType)

         t.found = found

         if self.collector then
            self.env.reporter:set_ref(t, found)
         end

         return nil, found
      end

      local function resolve_decl_in_nominal(self: TypeChecker, t: NominalType, found: TypeDeclType): Type
         local def = found.def
         local resolved: Type
         if def is GenericType then
            resolved = match_typevals(self, t, def)
            if not resolved then
               resolved = an_invalid(t)
            end
         elseif t.typevals then
            resolved = self.errs:invalid_at(t, "unexpected type argument")
         else
            resolved = def
         end

         t.resolved = resolved

         return resolved
      end

      function TypeChecker:resolve_nominal(t: NominalType): Type
         local immediate, found = find_nominal_type_decl(self, t)
         if immediate then
            return immediate
         end

         return resolve_decl_in_nominal(self, t, found)
      end

      function TypeChecker:resolve_typealias(ta: TypeDeclType): InvalidOrTypeDeclType
         local def = ta.def

         local nom = def
         if def is GenericType then
            nom = def.t
         end

         if not nom is NominalType then
            return ta
         end
         -- given a typealias that points to a nominal,

         local immediate, found = find_nominal_type_decl(self, nom)
         -- if it was previously resolved (or a circular require, or an error), return that;
         if immediate and immediate is InvalidOrTypeDeclType then
            return immediate
         end

         -- if nominal has no type arguments, resolve alias to that;
         if not nom.typevals then
            nom.resolved = found
            return found
         end

         -- otherwise, this can't be an alias.

         -- resolve the nominal into a structural type
         local struc = resolve_decl_in_nominal(self, nom, found or nom.found)

         if def is GenericType then
            struc = wrap_generic_if_typeargs(def.typeargs, struc)
         end

         -- wrap it into a new non-alias typedecl
         local td = a_type(ta, "typedecl", { def = struc } as TypeDeclType)
         nom.resolved = td

         -- and return it
         return td
      end
   end

   local enum ArgCheckMode
      "argument"
      "return"
      "self"
   end

   local enum VarianceMode
      "covariant"
      "contravariant"
      "bivariant"
      "invariant"
   end

   function TypeChecker:arg_check(w: Where, all_errs: {Error}, a: Type, b: Type, v: VarianceMode, mode: ArgCheckMode, n?: integer): boolean
      local ok, err, errs: boolean, string, {Error} = nil, nil, nil

      if v == "covariant" then
         ok, errs = self:is_a(a, b)
      elseif v == "contravariant" then
         ok, errs = self:is_a(b, a)
      elseif v == "bivariant" then
         ok, errs = self:is_a(a, b)
         if ok then
            return true
         end
         ok = self:is_a(b, a)
         if ok then
            return true
         end
      elseif v == "invariant" then
         ok, errs = self:same_type(a, b)
      end

      if ok and b is NominalType then
         local rb = self:resolve_nominal(b)
         ok, err = ensure_not_abstract(rb)
         if not ok then
            errs = { Err_at(w, err) }
         end
      end

      if not ok then
         self.errs:add_prefixing(w, errs, mode .. (n and " " .. n or "") .. ": ", all_errs, Errors.make({ context = mode, index = n }))
         return false
      end
      return true
   end

   do
      local function are_same_unresolved_global_type(self: TypeChecker, t1: NominalType, t2: NominalType): boolean
         -- FIXME shouldn't this be allowed only when `#t1.names == 1 and #t2.names == 1`?
         if t1.names[1] == t2.names[1] then
            local global_scope = self.st[1]
            if global_scope.pending_global_types[t1.names[1]] then
               return true
            end
         end
         return false
      end

      local function fail_nominals(self: TypeChecker, t1: NominalType, t2: NominalType): boolean, {Error}
         local t1name = show_type(t1)
         local t2name = show_type(t2)
         if t1name == t2name then
            self:resolve_nominal(t1)
            if t1.found then
               t1name = t1name .. " (defined in " .. t1.found.f .. ":" .. t1.found.y .. ")"
            end
            self:resolve_nominal(t2)
            if t2.found then
               t2name = t2name .. " (defined in " .. t2.found.f .. ":" .. t2.found.y .. ")"
            end
         end
         return false, { Errors.not_a(Err(t1name .. " is not a " .. t2name), t1, t2) }
      end

      local function nominal_found_type(self: TypeChecker, nom: NominalType): Type
         local typedecl = nom.found
         if not typedecl then
            typedecl = self:find_type(nom.names)
            if not typedecl then
               return nil
            end
         end
         local t = typedecl.def

         if t is GenericType then
            t = t.t
         end

         return t
      end

      function TypeChecker:are_same_nominals(t1: NominalType, t2: NominalType): boolean, {Error}
         local t1f = nominal_found_type(self, t1)
         local t2f = nominal_found_type(self, t2)
         if (not t1f or not t2f) then
            if are_same_unresolved_global_type(self, t1, t2) then
               return true
            end

            if not t1f then
               self.errs:add_coded(t1, Errors.make({ code = "unknown_type", names = t1.names, subject = show_type(t1) }), "unknown type %s", t1)
            end
            if not t2f then
               self.errs:add_coded(t2, Errors.make({ code = "unknown_type", names = t2.names, subject = show_type(t2) }), "unknown type %s", t2)
            end
            return false, {} -- errors were already produced
         end

         if t1f.typeid ~= t2f.typeid then
            return fail_nominals(self, t1, t2)
         end

         if t1.typevals == nil and t2.typevals == nil then
            return true
         end

         if t1.typevals and t2.typevals and #t1.typevals == #t2.typevals then
            local errs = {}
            for i = 1, #t1.typevals do
               local _, typeval_errs = self:same_type(t1.typevals[i], t2.typevals[i])
               self.errs:add_prefixing(nil, typeval_errs, "type parameter <" .. show_type(t2.typevals[i]) .. ">: ", errs,
                  Errors.make({ type_parameter = show_type(t2.typevals[i]) }))
            end
            return any_errors(errs)
         end

         -- FIXME what if presence and arities of typevals don't match?...
         return true
      end
   end

   local is_lua_table_type: function(t: Type): boolean

   function TypeChecker:to_structural(t: Type): Type
      assert(not t is TupleType)
      if t is TypeVarType and t.constraint then
         t = t.constraint
      end
      if t is NominalType then
         t = self:resolve_nominal(t)
      end
      return t
   end

   -- The Lua kinds a value of the type `t` can have, joined by "|" in a
   -- fixed order ("nil" among them where `t` admits nil or `optional` is
   -- set), which a run-time check compares a value's with: `type`, and
   -- `math.type` for an integer. Nil where a value cannot be checked by
   -- its kind alone: `any`, a type variable, a type not resolved. A
   -- record is a table, as it is erased, and an interface a table or a
   -- userdata, since a record that is one may implement it. A kind is
   -- only ever added for a type that admits it, so a value a type
   -- declares passes.
   function TypeChecker:runtime_kinds(t: Type, optional?: boolean): string
      local kinds: {string:boolean} = {}
      local function add(u: Type, depth: integer): boolean
         if depth > 6 or u is TupleType or u is TypeVarType or u is TypeArgType then
            return false
         end
         u = self:to_structural(u)
         local name = u.typename
         if name == "union" then
            for _, member in ipairs((u as UnionType).types) do
               if not add(member, depth + 1) then
                  return false
               end
            end
         elseif name == "nil" or name == "boolean" or name == "number" or name == "integer"
            or name == "string" or name == "function" or name == "thread" or name == "userdata" then
            kinds[name] = true
         elseif name == "enum" then
            kinds["string"] = true
         elseif name == "array" or name == "map" or name == "tupletable" or name == "emptytable" then
            kinds["table"] = true
         elseif name == "record" then
            kinds[(u as RecordLikeType).is_userdata and "userdata" or "table"] = true
         elseif name == "interface" then
            kinds["table"] = true
            kinds["userdata"] = true
         else
            return false
         end
         return true
      end
      if not add(t, 1) then
         return nil
      end
      if optional then
         kinds["nil"] = true
      end
      if kinds["number"] then
         kinds["integer"] = nil
      end
      local out: {string} = {}
      for _, kind in ipairs({
         "nil", "boolean", "number", "integer", "string", "table", "function", "userdata", "thread",
      }) do
         if kinds[kind] then
            table.insert(out, kind)
         end
      end
      return table.concat(out, "|")
   end

   local function unite(w: Where, types: {Type}, flatten_constants?: boolean): Type
      if #types == 1 then
         return types[1]
      end

      local ts: {Type} = {}
      local stack: {Type} = {}

      -- Make things like number | number resolve to number
      local types_seen: {(integer|string):boolean} = {}
      -- but never add nil as a type in the union
      types_seen["nil"] = true

      local i = 1
      while types[i] or stack[1] do
         local t: Type
         if stack[1] then
            t = table.remove(stack)
         else
            t = types[i]
            i = i + 1
         end
         t = resolve_tuple(t)
         if t is UnionType then
            for _, s in ipairs(t.types) do
               table.insert(stack, s)
            end
         else
            if primitive[t.typename] and (flatten_constants or (t is StringType and not t.literal)) then
               if not types_seen[t.typename] then
                  types_seen[t.typename] = true
                  table.insert(ts, t)
               end
            else
               local typeid = t.typeid
               if t is NominalType and t.found then
                  typeid = t.found.typeid
               end
               if not types_seen[typeid] then
                  types_seen[typeid] = true
                  table.insert(ts, t)
               end
            end
         end
      end

      if types_seen["invalid"] then
         return a_type(w, "invalid", {})
      end

      if #ts == 1 then
         return ts[1]
      else
         return a_union(w, ts)
      end
   end

   do
      local known_table_types: {TypeName:boolean} = {
         array = true,
         map = true,
         record = true,
         tupletable = true,
         interface = true,
      }

      -- Is the type represented concretely as a Lua table?
      is_lua_table_type = function(t: Type): boolean
         return known_table_types[t.typename]
                and not (t is RecordLikeType and t.is_userdata)
      end
   end

   -- t with its nil member dropped, or nil when t is not a union that
   -- carries nil. `strict` additionally refuses a union whose other
   -- members are not known to be truthy -- boolean, any, unknown,
   -- typevar -- which is what a truthiness guard needs and an `or`
   -- fallback does not.
   local function without_nil(self: TypeChecker, w: Where, t: Type, strict: boolean): Type
      local rt = t
      if rt is NominalType then
         rt = self:resolve_nominal(rt)
      end
      if not rt is UnionType then
         return nil
      end
      local has_nil = false
      local members: {Type} = {}
      for _, m in ipairs(rt.types) do
         local rm = m
         if rm is NominalType then
            rm = self:resolve_nominal(rm)
         end
         if rm is NilType then
            has_nil = true
         elseif strict and (rm is BooleanType or rm.typename == "any" or
            rm is UnknownType or rm is BooleanContextType or
            rm is TypeVarType) then
            return nil
         else
            table.insert(members, m)
         end
      end
      if not has_nil or #members == 0 then
         return nil
      end
      return #members == 1 and members[1] or unite(w, members)
   end

   -- Does t hold nil? nil is a subtype of every type, so this stands in
   -- for is_a wherever a nil member would otherwise pass a target that
   -- cannot hold one.
   local function admits_nil(self: TypeChecker, w: Where, t: Type): boolean
      local rt = t
      if rt is NominalType then
         rt = self:resolve_nominal(rt)
      end
      return rt is NilType or rt.typename == "any" or
         rt is UnknownType or rt is TypeVarType or
         without_nil(self, w, rt, false) ~= nil
   end

   local function refuse_omitted_fields(self: TypeChecker, node: Node, decltype: RecordLikeType, given: function(string): boolean)
      node.omissions_checked = true
      local absent: {string} = {}
      for _, fname in ipairs(decltype.field_order) do
         local ftype = decltype.fields[fname]
         if not given(fname)
            and not (ftype is TypeDeclType)
            and not (ftype is FunctionType and ftype.is_record_function)
            and fname:sub(1, 2) ~= "__"
            and not admits_nil(self, node, ftype) then
            local sft = self:to_structural(ftype)
            if sft is GenericType then
               sft = sft.t
            end
            if not (sft is FunctionType or sft is PolyType) then
               table.insert(absent, fname)
            end
         end
      end
      if #absent > 0 then
         self.errs:add_in_context(node, node, "table literal omits field(s) of " ..
            (decltype is RecordType and "record " or "interface ") ..
            tostring(decltype.declname or "(anonymous)") .. " that do not admit nil: " ..
            table.concat(absent, ", ") .. " (give them, or mark a field that may be absent `name?: T`)")
      end
   end

   local function check_literal_omissions(self: TypeChecker, node: Node, decltype: RecordLikeType)
      local keys: {string:boolean} = {}
      for _, item in ipairs(node) do
         if item.key and item.key.conststr then
            keys[item.key.conststr] = true
         end
      end
      refuse_omitted_fields(self, node, decltype, function(key: string): boolean
         return keys[key] == true
      end)
      for _, item in ipairs(node) do
         local value = item.value
         local key = item.key and item.key.conststr
         if key and value and value.kind == "literal_table" and not value.omissions_checked then
            local field = decltype.fields[key]
            local rf = field and self:to_structural(field)
            if rf is RecordLikeType then
               check_literal_omissions(self, value, rf)
            end
         end
      end
   end

   function TypeChecker:arraytype_from_tuple(w: Where, tupletype: TupleTableType): ArrayType, {Error}
      -- first just try a basic union
      local element_type = unite(w, tupletype.types, true)
      local valid = (not element_type is UnionType) and true or is_valid_union(element_type)
      if valid then
         return an_array(w, element_type)
      end

      -- failing a basic union, expand the types
      local arr_type = an_array(w, tupletype.types[1])
      for i = 2, #tupletype.types do
         local expanded = self:expand_type(w, arr_type, an_array(w, tupletype.types[i]))
         if not expanded is ArrayType then
            return nil, { Err("unable to convert tuple %s to array", tupletype) }
         end
         arr_type = expanded
      end
      return arr_type
   end

   local function compare_true(_: TypeChecker, _: Type, _: Type): boolean, {Error}
      return true
   end

   function TypeChecker:subtype_nominal(a: Type, b: Type): boolean, {Error}
      local ra = a is NominalType and self:resolve_nominal(a) or a
      local rb = b is NominalType and self:resolve_nominal(b) or b
      local ok, errs = self:is_a(ra, rb)
      if errs and #errs == 1 and errs[1].msg:match("^got ") then
         return false -- translate to got-expected error with unresolved types
      end
      return ok, errs
   end

   function TypeChecker:subtype_array(a: ArrayLikeType, b: ArrayLikeType): boolean, {Error}
      if (not a.elements) or (not self:is_a(a.elements, b.elements)) then
         return false
      end
      if a.consttypes and #a.consttypes > 1 then
         -- constant array, check elements (useful for array of enums)
         for _, e in ipairs(a.consttypes) do
            if not self:is_a(e, b.elements) then
               return false, { Err("%s is not a member of %s", e, b.elements) }
            end
         end
      end
      return true
   end

   function TypeChecker:in_interface_list(r: RecordLikeType, iface: Type): boolean
      if not r.interface_list then
         return false
      end

      for _, t in ipairs(r.interface_list) do
         if self:is_a(t, iface) then
            return true
         end
      end

      return false
   end

   function TypeChecker:mark_receiver(field: Type, expected: Type)
      if field is FunctionType and expected is FunctionType then
         self.receiver_field = expected
      end
   end

   function TypeChecker:is_a_field(field: Type, expected: Type): boolean, {Error}
      self:mark_receiver(field, expected)
      local ok, errs = self:is_a(field, expected)
      self.receiver_field = nil
      return ok, errs
   end

   function TypeChecker:subtype_record(a: RecordLikeType, b: RecordLikeType): boolean, {Error}
      -- assert(b.typename == "record")
      if a.elements and b.elements then
         if not self:is_a(a.elements, b.elements) then
            return false, { Err("array parts have incompatible element types") }
         end
      end

      if a.is_userdata ~= b.is_userdata then
         return false, { Err(a.is_userdata and "userdata is not a record"
                                              or  "record is not a userdata") }
      end

      local errs: {Error} = {}
      for _, k in ipairs(a.field_order) do
         local ak = a.fields[k]
         local bk = b.fields[k]
         if bk then
            local ok, fielderrs = self:is_a_field(ak, bk)
            if not ok then
               self.errs:add_prefixing(nil, fielderrs, "record field doesn't match: " .. k .. ": ", errs)
            end
         end
      end
      if #errs > 0 then
         for _, err in ipairs(errs) do
            err.msg = show_type(a) .. " is not a " .. show_type(b) .. ": " .. err.msg
            err.nested = true
         end
         return false, errs
      end

      return true
   end

   function TypeChecker:eqtype_record(a: RecordType, b: RecordType): boolean, {Error}
      -- checking array interface
      if (a.elements ~= nil) ~= (b.elements ~= nil) then
         return false, { Err("types do not have the same array interface") }
      end
      if a.elements then
         local ok, errs = self:same_type(a.elements, b.elements)
         if not ok then
            return ok, errs
         end
      end

      local ok, errs = self:subtype_record(a, b)
      if not ok then
         return ok, errs
      end
      ok, errs = self:subtype_record(b, a)
      if not ok then
         return ok, errs
      end
      return true
   end

   local function compare_map(self: TypeChecker, ak: Type, bk: Type, av: Type, bv: Type, no_hack?: boolean): boolean, {Error}
      local ok1, errs_k = self:is_a(bk, ak)
      local ok2, errs_v = self:is_a(av, bv)

      -- FIXME hack for {any:any}
      if bk.typename == "any" and not no_hack then
         ok1, errs_k = true, nil
      end
      if bv.typename == "any" and not no_hack then
         ok2, errs_v = true, nil
      end

      if ok1 and ok2 then
         return true
      end

      -- combine errs_k and errs_v, prefixing errors
      for i = 1, errs_k and #errs_k or 0 do
         errs_k[i].msg = "in map key: " .. errs_k[i].msg
         errs_k[i].nested = true
      end
      for i = 1, errs_v and #errs_v or 0 do
         errs_v[i].msg = "in map value: " .. errs_v[i].msg
         errs_v[i].nested = true
      end
      if errs_k and errs_v then
         for i = 1, #errs_v do
            table.insert(errs_k, errs_v[i])
         end
         return false, errs_k
      end
      return false, errs_k or errs_v
   end

   -- Whether two types, one nested in a comparison, disagree on whether a
   -- function in the same place never returns (43e5 sets it).
   local nested_never_mismatch: function(a: Type, b: Type): boolean = nil

   function TypeChecker:compare_or_infer_typevar(typevar: string, a: Type, b: Type, cmp: CompareTypes): boolean, {Error}
      -- assert((a == nil and b ~= nil) or (a ~= nil and b == nil))

      -- does the typevar currently match to a type?
      local vt, _, constraint = self:find_var_type(typevar)
      if vt then
         -- If so, compare it to the other type
         if (self.compare_depth or 0) > 1 and nested_never_mismatch(a or vt, b or vt) then
            return false, { Err("got %s, expected %s, which differ in whether the function never returns, inside another type", a or vt, b or vt) }
         end
         return cmp(self, a or vt, b or vt)
      else
         -- otherwise, infer it to the other type
         local other = a or b

         -- but check interface constraint first if present
         if constraint then
            if not self:is_a(other, constraint) then
               return false, { Err("given type %s does not satisfy %s constraint in type variable " .. display_typevar(typevar, "typevar"), other, constraint) }
            end

            if self:same_type(other, constraint) then
               -- do not infer to some type as constraint right away,
               -- to give a chance to more specific inferences
               -- in other arguments/returns
               return true
            end
         end

         local r, errs = resolve_typevars(self, other)
         if errs then
            return false, errs
         end

         -- do not infer a type variable to a boolean_context
         if r is BooleanContextType then
            return true
         end

         if r is TypeVarType and r.typevar == typevar then
            return true
         end
         self:add_var(nil, typevar, r)
         return true
      end
   end

   function TypeChecker:type_of_self(w: Where): Type, TypeDeclType
      local t = self:find_var_type("@self")
      if not t then
         return an_invalid(w), nil
      end
      assert(t is TypeDeclType)
      return t.def, t
   end

   -- ∃ x ∈ xs. t <: x
   function TypeChecker:exists_supertype_in(t: Type, xs: AggregateType): Type
      for _, x in ipairs(xs.types) do
         if self:is_a(t, x) then
            return x
         end
      end
   end

   -- ∀ x ∈ xs, x <: t
   function TypeChecker:forall_are_subtype_of(xs: AggregateType, t: Type): boolean
      for _, x in ipairs(xs.types) do
         if not self:is_a(x, t) then
            return false
         end
      end
      return true
   end

   local function compare_true_inferring_emptytable(self: TypeChecker, a: Type, b: EmptyTableType): boolean, {Error}
      self:infer_emptytable(b, self:infer_at(b, a))
      return true
   end

   local function compare_true_inferring_emptytable_if_not_userdata(self: TypeChecker, a: RecordLikeType, b: EmptyTableType): boolean, {Error}
      if a.is_userdata then
         return false, { Err("{} cannot be used with userdata type %s", a) }
      end
      return compare_true_inferring_emptytable(self, a, b)
   end

   local function infer_emptytable_from_unresolved_value(self: TypeChecker, w: Where, u: UnresolvedEmptyTableValueType, values: Type)
      local et = u.emptytable_type
      assert(et is EmptyTableType, u.typename)
      local keys = et.keys
      if not (values is EmptyTableType or values is UnresolvedEmptyTableValueType) then
         local infer_to = keys is NumericType -- ideally integer only
                          and an_array(w, values)
                          or  a_map(w, keys, values)
         self:infer_emptytable(et, self:infer_at(w, infer_to))
      end
   end

   local function a_is_interface_b(self: TypeChecker, a: NominalType, b: NominalType): boolean, {Error}
      if (not a.found) or (not b.found) then
         return false
      end

      local af = a.found.def
      if af is GenericType then
         af = self:apply_generic(a, af, a.typevals)
      end

      if af is RecordLikeType then
         if self:in_interface_list(af, b) then
            return true
         end
      end

      return self:is_a(a, self:resolve_nominal(b))
   end

   -- emptytable rules are the same in eqtype_relations and subtype_relations
   local emptytable_relations: {TypeName:CompareTypes} = {
      ["emptytable"] = compare_true,
      ["array"] = compare_true,
      ["map"] = compare_true,
      ["tupletable"] = compare_true,
      ["interface"] = function(_self: TypeChecker, _a: Type, b: InterfaceType): boolean, {Error}
         return not b.is_userdata
      end,
      ["record"] = function(_self: TypeChecker, _a: Type, b: RecordType): boolean, {Error}
         return not b.is_userdata
      end,
   }

   TypeChecker.eqtype_relations = {
      ["typevar"] = {
         ["typevar"] = function(self: TypeChecker, a: TypeVarType, b: TypeVarType): boolean, {Error}
            if a.typevar == b.typevar then
               return true
            end

            return self:compare_or_infer_typevar(b.typevar, a, nil, self.same_type)
         end,
         ["*"] = function(self: TypeChecker, a: TypeVarType, b: Type): boolean, {Error}
            return self:compare_or_infer_typevar(a.typevar, nil, b, self.same_type)
         end,
      },
      ["emptytable"] = emptytable_relations,
      ["tupletable"] = {
         ["tupletable"] = function(self: TypeChecker, a: TupleTableType, b: TupleTableType): boolean, {Error}
            for i = 1, math.min(#a.types, #b.types) do
               if not self:same_type(a.types[i], b.types[i]) then
                  return false, { Errors.nest(Errors.mismatch(Err("in tuple entry " .. tostring(i) .. ": got %s, expected %s", a.types[i], b.types[i]), a.types[i], b.types[i])) }
               end
            end
            if #a.types ~= #b.types then
               return false, { Err("tuples have different size", a, b) }
            end
            return true
         end,
         ["emptytable"] = compare_true_inferring_emptytable,
      },
      ["array"] = {
         ["array"] = function(self: TypeChecker, a: ArrayType, b: ArrayType): boolean, {Error}
            return self:same_type(a.elements, b.elements)
         end,
         ["emptytable"] = compare_true_inferring_emptytable,
      },
      ["map"] = {
         ["map"] = function(self: TypeChecker, a: MapType, b: MapType): boolean, {Error}
            return compare_map(self, a.keys, b.keys, a.values, b.values, true)
         end,
         ["emptytable"] = compare_true_inferring_emptytable,
      },
      ["union"] = {
         ["union"] = function(self: TypeChecker, a: UnionType, b: UnionType): boolean, {Error}
            return (self:has_all_types_of(a.types, b.types)
                and self:has_all_types_of(b.types, a.types))
         end,
      },
      ["nominal"] = {
         ["nominal"] = TypeChecker.are_same_nominals,
         ["typedecl"] = function(self: TypeChecker, a: NominalType, b: TypeDeclType): boolean, {Error}
            -- used when resolving type parameters
            return self:same_type(self:resolve_nominal(a), b.def)
         end,
      },
      ["record"] = {
         ["record"] = TypeChecker.eqtype_record,
         ["emptytable"] = compare_true_inferring_emptytable_if_not_userdata,
      },
      ["interface"] = {
         ["interface"] = function(_self:TypeChecker, a: InterfaceType, b: InterfaceType): boolean, {Error}
            return a.typeid == b.typeid
         end,
         ["emptytable"] = compare_true_inferring_emptytable_if_not_userdata,
      },
      ["function"] = {
         ["function"] = function(self:TypeChecker, a: FunctionType, b: FunctionType): boolean, {Error}
            if (not not a.never) ~= (not not b.never) then
               return false, { Err("got %s, expected %s, which differ in whether the function never returns", a, b) }
            end
            local argdelta = a.is_method and 1 or 0
            local naargs, nbargs = #a.args.tuple, #b.args.tuple
            if naargs ~= nbargs then
               if (not not a.is_method) ~= (not not b.is_method) then
                  return false, { Err("different number of input arguments: method and non-method are not the same type") }
               end
               return false, { Err("different number of input arguments: got " .. naargs - argdelta .. ", expected " .. nbargs - argdelta) }
            end
            local narets, nbrets = #a.rets.tuple, #b.rets.tuple
            if narets ~= nbrets then
               return false, { Err("different number of return values: got " .. narets .. ", expected " .. nbrets) }
            end
            local errs = {}
            for i = 1, naargs do
               self:arg_check(a, errs, a.args.tuple[i], b.args.tuple[i], "invariant", "argument", i - argdelta)
            end
            for i = 1, narets do
               self:arg_check(a, errs, a.rets.tuple[i], b.rets.tuple[i], "invariant", "return", i)
            end
            return any_errors(errs)
         end,
      },
      ["self"] = {
         ["self"] = function(_self: TypeChecker, _a: SelfType, _b: SelfType): boolean, {Error}
            return true
         end,
         ["*"] = function(self: TypeChecker, a: SelfType, b: Type): boolean, {Error}
            return self:same_type(self:type_of_self(a), b)
         end,
      },
      ["boolean_context"] = {
         ["boolean"] = compare_true,
      },
      ["generic"] = {
         ["generic"] = function(self: TypeChecker, a: GenericType, b: GenericType): boolean, {Error}
            if #a.typeargs ~= #b.typeargs then
               return false
            end
            for i = 1, #a.typeargs do
               if not self:same_type(a.typeargs[i], b.typeargs[i]) then
                  return false
               end
            end
            return self:same_type(a.t, b.t)
         end,
      },
      ["*"] = {
         ["boolean_context"] = compare_true,
         ["self"] = function(self: TypeChecker, a: Type, b: SelfType): boolean, {Error}
            return self:same_type(a, (self:type_of_self(b)))
         end,
         ["typevar"] = function(self: TypeChecker, a: Type, b: TypeVarType): boolean, {Error}
            return self:compare_or_infer_typevar(b.typevar, a, nil, self.same_type)
         end,
      },
   }

   TypeChecker.subtype_relations = {
      ["nil"] = {
         ["*"] = compare_true,
      },
      ["tuple"] = {
         ["tuple"] = function(self: TypeChecker, a: TupleType, b: TupleType): boolean, {Error}  -- ∀ a[i] ∈ a, b[i] ∈ b. a[i] <: b[i]
            local at, bt = a.tuple, b.tuple                                  -- ──────────────────────────────────
            if #at ~= #bt then                                               --        a tuple <: b tuple
               return false
            end
            for i = 1, #at do
               if not self:is_a(at[i], bt[i]) then
                  return false
               end
            end
            return true
         end,
         ["*"] = function(self: TypeChecker, a: Type, b: Type): boolean, {Error}
            return self:is_a(resolve_tuple(a), b)
         end,
      },
      ["typevar"] = {
         ["typevar"] = function(self: TypeChecker, a: TypeVarType, b: TypeVarType): boolean, {Error}
            if a.typevar == b.typevar then
               return true
            end

            return self:compare_or_infer_typevar(b.typevar, a, nil, self.is_a)
         end,
         ["*"] = function(self: TypeChecker, a: TypeVarType, b: Type): boolean, {Error}
            return self:compare_or_infer_typevar(a.typevar, nil, b, self.is_a)
         end,
      },
      ["union"] = {
         ["nominal"] = function(self: TypeChecker, a: UnionType, b: NominalType): boolean, {Error}
            -- match unions structurally
            local rb = self:resolve_nominal(b)
            if rb is UnionType then
               return self:is_a(a, rb)
            end

            return self:forall_are_subtype_of(a, b)
         end,
         ["union"] = function(self: TypeChecker, a: UnionType, b: UnionType): boolean, {Error} -- ∀ t ∈ a. ∃ u ∈ b. t <: u
            local used = {}                                                 -- ────────────────────────
            for _, t in ipairs(a.types) do                                  --    a union <: b union
               self:begin_scope()
               local u = self:exists_supertype_in(t, b)
               self:end_scope() -- don't preserve failed inferences
               if not u then
                  return false
               end
               if not used[u] then -- FIXME the order of declared union items affects inference behavior
                  used[u] = t
               end
            end
            for u, t in pairs(used) do
               self:is_a(t, u) -- preserve valid inferences
            end
            return true
         end,
         ["*"] = TypeChecker.forall_are_subtype_of as CompareTypes,
      },
      ["poly"] = {
         ["*"] = function(self: TypeChecker, a: PolyType, b: Type): boolean, {Error}    -- ∃ t ∈ a, t <: b
            local rb = b
            if rb is NominalType then
               rb = self:resolve_nominal(rb)
            end
            if rb is FunctionType and rb.never then
               for _, overload in ipairs(a.types) do
                  local fn: Type = overload
                  if fn is GenericType then
                     fn = fn.t
                  end
                  if not (fn is FunctionType and fn.never) then
                     return false, { Err("a polymorphic function with an overload that may return cannot stand for %s, which never returns", b) }
                  end
               end
            end
            local found = false
            for _, overload in ipairs(a.types) do
               if self:is_a(overload, b) then
                  found = true
                  break
               end
            end
            if found then                                      -- ───────────────
               return true                                                              --   a poly <: b
            end
            return false, { Err("cannot match against any alternatives of the polymorphic type") }
         end,
      },
      ["nominal"] = {
         ["nominal"] = function(self: TypeChecker, a: NominalType, b: NominalType): boolean, {Error}
            local ok, errs = self:are_same_nominals(a, b)
            if ok then
               return true
            end

            local ra = self:resolve_nominal(a)
            local rb = self:resolve_nominal(b)

            -- match unions structurally
            local union_a = ra is UnionType
            local union_b = rb is UnionType
            if union_a or union_b then
               return self:is_a(union_a and ra or a, union_b and rb or b)
            end

            -- match interface subtyping
            if rb is InterfaceType then
               return a_is_interface_b(self, a, b)
            end

            -- all other types nominally
            return ok, errs
         end,
         ["union"] = function(self: TypeChecker, a: NominalType, b: UnionType): boolean, {Error}
            -- match unions structurally
            local ra = self:resolve_nominal(a)
            if ra is UnionType then
               return self:is_a(ra, b)
            end

            return not not self:exists_supertype_in(a, b)
         end,
         ["*"] = TypeChecker.subtype_nominal,
      },
      ["enum"] = {
         ["string"] = compare_true,
      },
      ["string"] = {
         ["enum"] = function(_self: TypeChecker, a: StringType, b: EnumType): boolean, {Error}
            if not a.literal then
               return false, { Errors.not_a(Err("%s is not a %s", a, b), a, b) }
            end

            if b.enumset[a.literal] then
               return true
            end

            return false, { Err("%s is not a member of %s", a, b) }
         end,
      },
      ["integer"] = {
         ["number"] = compare_true,
      },
      ["interface"] = {
         ["interface"] = function(self: TypeChecker, a: InterfaceType, b: InterfaceType): boolean, {Error}
            if self:in_interface_list(a, b) then
               return true
            end
            return self:same_type(a, b)
         end,
         ["array"] = TypeChecker.subtype_array,
         ["tupletable"] = function(self: TypeChecker, a: Type, b: Type): boolean, {Error}
            return self.subtype_relations["record"]["tupletable"](self, a, b)
         end,
         ["emptytable"] = compare_true_inferring_emptytable_if_not_userdata,
      },
      ["emptytable"] = emptytable_relations,
      ["tupletable"] = {
         ["tupletable"] = function(self: TypeChecker, a: TupleTableType, b: TupleTableType): boolean, {Error}
            for i = 1, math.min(#a.types, #b.types) do
               if not self:is_a(a.types[i], b.types[i]) then
                  return false, { Errors.nest(Errors.mismatch(Err("in tuple entry "
                     .. tostring(i) .. ": got %s, expected %s",
                     a.types[i], b.types[i]), a.types[i], b.types[i])) }
               end
            end
            if #a.types > #b.types then
               return false, { Err("tuple %s is too big for tuple %s", a, b) }
            end
            return true
         end,
         ["record"] = function(self: TypeChecker, a: Type, b: RecordType): boolean, {Error}
            if b.elements then
               return self.subtype_relations["tupletable"]["array"](self, a, b)
            end
         end,
         ["array"] = function(self: TypeChecker, a: TupleTableType, b: ArrayType): boolean, {Error}
            if b.inferred_len and b.inferred_len > #a.types then
               return false, { Err("incompatible length, expected maximum length of " .. tostring(#a.types) .. ", got " .. tostring(b.inferred_len)) }
            end
            local aa, err = self:arraytype_from_tuple(a.inferred_at or a, a)
            if not aa then
               return false, err
            end
            if not self:is_a(aa, b) then
               return false, { Err("got %s (from %s), expected %s", aa, a, b) }
            end
            return true
         end,
         ["map"] = function(self: TypeChecker, a: TupleTableType, b: MapType): boolean, {Error}
            local aa = self:arraytype_from_tuple(a.inferred_at or a, a)
            if not aa then
               return false, { Err("Unable to convert tuple %s to map", a) }
            end

            return compare_map(self, a_type(a, "integer", {}), b.keys, aa.elements, b.values)
         end,
         ["emptytable"] = compare_true_inferring_emptytable,
      },
      ["record"] = {
         ["record"] = TypeChecker.subtype_record,
         ["interface"] = function(self: TypeChecker, a: RecordType, b: InterfaceType): boolean, {Error}
            if self:in_interface_list(a, b) then
               return true
            end
            if not a.declname then
               -- match inferred table (anonymous record) structurally to interface
               return self:subtype_record(a, b)
            end
         end,
         ["array"] = TypeChecker.subtype_array,
         ["map"] = function(self: TypeChecker, a: RecordType, b: MapType): boolean, {Error}
            if not self:is_a(b.keys, a_type(b, "string", {})) then
               return false, { Err("can't match a record to a map with non-string keys") }
            end

            for _, k in ipairs(a.field_order) do
               local bk = b.keys
               if bk is EnumType and not bk.enumset[k] then
                  return false, { Err("key is not an enum value: " .. k) }
               end
               if not self:is_a(a.fields[k], b.values) then
                  return false, { Err("record is not a valid map; not all fields have the same type") }
               end
            end

            return true
         end,
         ["tupletable"] = function(self: TypeChecker, a: RecordType, b: Type): boolean, {Error}
            if a.elements then
               return self.subtype_relations["array"]["tupletable"](self, a, b)
            end
         end,
         ["emptytable"] = compare_true_inferring_emptytable_if_not_userdata,
      },
      ["array"] = {
         ["array"] = TypeChecker.subtype_array,
         ["record"] = function(self: TypeChecker, a: ArrayType, b: RecordType): boolean, {Error}
            if b.elements then
               return self:subtype_array(a, b)
            end
         end,
         ["map"] = function(self: TypeChecker, a: ArrayType, b: MapType): boolean, {Error}
            return compare_map(self, a_type(a, "integer", {}), b.keys, a.elements, b.values)
         end,
         ["tupletable"] = function(self: TypeChecker, a: ArrayType, b: TupleTableType): boolean, {Error}
            local alen = a.inferred_len or 0
            if alen > #b.types then
               return false, { Err("incompatible length, expected maximum length of " .. tostring(#b.types) .. ", got " .. tostring(alen)) }
            end

            -- for array literals (which is the only case where inferred_len is defined),
            -- only check the entries that are present
            for i = 1, (alen > 0) and alen or #b.types do
               if not self:is_a(a.elements, b.types[i]) then
                  return false, { Err("tuple entry " .. i .. " of type %s does not match type of array elements, which is %s", b.types[i], a.elements) }
               end
            end
            return true
         end,
         ["emptytable"] = compare_true_inferring_emptytable,
      },
      ["map"] = {
         ["map"] = function(self: TypeChecker, a: MapType, b: MapType): boolean, {Error}
            return compare_map(self, a.keys, b.keys, a.values, b.values)
         end,
         ["array"] = function(self: TypeChecker, a: MapType, b: ArrayType): boolean, {Error}
            return compare_map(self, a.keys, a_type(b, "integer", {}), a.values, b.elements)
         end,
         ["emptytable"] = compare_true_inferring_emptytable,
      },
      ["typedecl"] = {
         ["*"] = function(self: TypeChecker, a: TypeDeclType, b: RecordType): boolean, {Error}
            return self:is_a(a.def, b)
         end,
      },
      ["function"] = {
         ["function"] = function(self: TypeChecker, a: FunctionType, b: FunctionType): boolean, {Error}
            local errs = {}

            local receiver = self.receiver_field == b
            self.receiver_field = nil

            local aa, ba = a.args.tuple, b.args.tuple
            if (not b.args.is_va) and (self.feat_arity and (#aa > #ba and a.min_arity > b.min_arity)) then
               table.insert(errs, Err("incompatible number of arguments: got " .. show_arity(a) .. " %s, expected " .. show_arity(b) .. " %s", a.args, b.args))
            else
               for i = ((a.is_method or b.is_method) and 2 or 1), #aa do
                  local ai = aa[i]
                  local bi = ba[i] or (b.args.is_va and ba[#ba])
                  if bi then
                     -- TODO: once cosmic.stream's interfaces declare their methods with a named receiver and
                     -- the records that implement them stop redeclaring them (doc/roadmap.md), compare the
                     -- receiver contravariantly too, which also closes a callback field taking a
                     -- narrower record, and drop `receiver_field`.
                     local variance: VarianceMode = "contravariant"
                     if receiver and i == 1 then
                        local actual, expected = self:to_structural(ai), self:to_structural(bi)
                        if actual is RecordLikeType and expected is RecordLikeType then
                           variance = "bivariant"
                        end
                     end
                     if bi.typename == "any" then
                        variance = "bivariant"
                     end
                     self:arg_check(nil, errs, ai, bi, variance, "argument", i)
                  end
               end
            end

            local ar, br = a.rets.tuple, b.rets.tuple
            local diff_by_va = #br - #ar == 1 and b.rets.is_va
            if b.never and not a.never then
               table.insert(errs, Err("%s may return, where %s never returns", a, b))
            elseif a.never then
               -- it returns nothing, so it fits any list of returns
            elseif #ar < #br and not diff_by_va then
               table.insert(errs, Err("incompatible number of returns: got " .. #ar .. " %s, expected " .. #br .. " %s", a.rets, b.rets))
            else
               local nrets = #br
               if diff_by_va then
                  nrets = nrets - 1
               end
               for i = 1, nrets do
                  self:arg_check(nil, errs, ar[i], br[i], "covariant", "return", i)
               end
            end

            return any_errors(errs)
         end,
      },
      ["self"] = {
         ["self"] = function(_self: TypeChecker, _a: SelfType, _b: SelfType): boolean, {Error}
            return true
         end,
         ["*"] = function(self: TypeChecker, a: SelfType, b: Type): boolean, {Error}
            return self:is_a(self:type_of_self(a), b)
         end,
      },
      ["typearg"] = {
         ["typearg"] = function(_self: TypeChecker, a: TypeArgType, b: TypeArgType): boolean, {Error}
            return a.typearg == b.typearg
         end,
         ["*"] = function(self: TypeChecker, a: TypeArgType, b: Type): boolean, {Error}
            if a.constraint then
               return self:is_a(a.constraint, b)
            end
         end,
      },
      ["boolean_context"] = {
         ["boolean"] = compare_true,
      },
      ["generic"] = {
         ["*"] = function(self: TypeChecker, a: GenericType, b: Type): boolean, {Error}
            -- TODO check if commenting this out causes variable leaks anywhere
            -- self:begin_scope()
            local aa = self:apply_generic(a, a)
            local ok, errs = self:is_a(aa, b)
            -- self:end_scope()
            return ok, errs
         end,
      },
      ["*"] = {
         ["any"] = compare_true,
         ["boolean_context"] = compare_true,
         ["emptytable"] = function(_self: TypeChecker, a: Type, _b: EmptyTableType): boolean, {Error}
            return false, { Err("assigning %s to a variable declared with {}", a) }
         end,
         ["unresolved_emptytable_value"] = function(self: TypeChecker, a: Type, b: UnresolvedEmptyTableValueType): boolean, {Error}
            infer_emptytable_from_unresolved_value(self, b, b, a)
            return true
         end,
         ["generic"] = function(self: TypeChecker, a: Type, b: GenericType): boolean, {Error}
            -- TODO check if commenting this out causes variable leaks anywhere
            -- self:begin_scope()
            local bb = self:apply_generic(b, b)
            local ok, errs = self:is_a(a, bb)
            -- self:end_scope()
            return ok, errs
         end,
         ["self"] = function(self: TypeChecker, a: Type, b: SelfType): boolean, {Error}
            return self:is_a(a, (self:type_of_self(b)))
         end,
         ["tuple"] = function(self: TypeChecker, a: Type, b: Type): boolean, {Error}
            return self:is_a(a_tuple(a, {a}), b)
         end,
         ["typedecl"] = function(self: TypeChecker, a: Type, b: TypeDeclType): boolean, {Error}
            return self:is_a(a, b.def)
         end,
         ["typevar"] = function(self: TypeChecker, a: Type, b: TypeVarType): boolean, {Error}
            return self:compare_or_infer_typevar(b.typevar, a, nil, self.is_a)
         end,
         ["typearg"] = function(self: TypeChecker, a: Type, b: TypeArgType): boolean, {Error}
            if b.constraint then
               return self:is_a(a, b.constraint)
            end
         end,
         ["union"] = TypeChecker.exists_supertype_in as CompareTypes,                   -- ∃ t ∈ b, a <: t
                                                                                        -- ───────────────
                                                                                        --  a <: b union
         ["nominal"] = TypeChecker.subtype_nominal,
         ["poly"] = function(self: TypeChecker, a: Type, b: PolyType): boolean, {Error} -- ∀ t ∈ b, a <: t
            for _, t in ipairs(b.types) do                                              -- ───────────────
               if not self:is_a(a, t) then                                              --   a <: b poly
                  return false, { Err("cannot match against all alternatives of the polymorphic type") }
               end
            end
            return true
         end,
      },
   }

   -- evaluation strategy
   TypeChecker.type_priorities = {
      -- types that have catch-all rules evaluate first
      ["generic"] = -1,
      ["nil"] = 0,
      ["unresolved_emptytable_value"] = 1,
      ["emptytable"] = 2,
      ["self"] = 3,
      ["tuple"] = 4,
      ["typevar"] = 5,
      ["typedecl"] = 6,
      ["any"] = 7,
      ["boolean_context"] = 8,
      ["union"] = 9,
      ["poly"] = 10,
      -- then typeargs
      ["typearg"] = 11,
      -- then nominals
      ["nominal"] = 12,
      -- then base types
      ["enum"] = 13,
      ["string"] = 13,
      ["integer"] = 13,
      ["boolean"] = 13,
      -- then interfaces
      ["interface"] = 14,
      -- then special cases of tables
      ["tupletable"] = 15,
      ["record"] = 15,
      ["array"] = 15,
      ["map"] = 15,
      ["function"] = 15,
   }

   local function compare_types(self: TypeChecker, relations: TypeRelations, t1: Type, t2: Type): boolean, {Error}
      if t1.typeid == t2.typeid then
         return true
      end

      local s1 = relations[t1.typename]
      local fn = s1 and s1[t2.typename]
      if not fn then
         local p1 = self.type_priorities[t1.typename] or 999
         local p2 = self.type_priorities[t2.typename] or 999
         fn = (p1 < p2 and (s1 and s1["*"]) or (relations["*"][t2.typename]))
      end

      local ok, err: boolean, {Error} = nil, nil
      if fn then
         if fn == compare_true then
            return true
         end
         ok, err = fn(self, t1, t2)
      else
         ok = t1.typename == t2.typename
      end

      if (not ok) and not err then
         if t1 is InvalidType or t2 is InvalidType then
            return false, {}
         end
         local show_t1 = show_type(t1)
         local show_t2 = show_type(t2)
         if show_t1 == show_t2 then
            return false, { Err_at(t1, "types are incompatible") }
         else
            return false, { Errors.mismatch(Err_at(t1, "got " .. show_t1 .. ", expected " .. show_t2), t1, t2) }
         end
      end
      return ok, err
   end

   -- Whether t is a function that never returns: true for a function
   -- declared so and for an overloaded one whose every overload is;
   -- false for one that may return; nil for a type that is no function.
   local function never_of(t: Type): boolean
      if t is GenericType then
         t = t.t
      end
      if t is FunctionType then
         return not not t.never
      elseif t is PolyType then
         for _, overload in ipairs(t.types) do
            if not never_of(overload) then
               return false
            end
         end
         return #t.types > 0
      end
      return nil
   end

   -- What a walk looks into in place of t: the type a name was resolved
   -- to, a declaration's definition, a generic's body. A name not
   -- resolved yet stays itself: resolving it here could report an error
   -- the comparison would report, or settle it for the wrong scope.
   local function walk_target(t: Type): Type
      for _ = 1, 16 do
         if t is NominalType then
            local resolved = t.resolved
            if resolved == nil and t.found and not t.typevals then
               resolved = t.found.def
            end
            if resolved == nil then
               return t
            end
            t = resolved
         elseif t is TypeDeclType then
            t = t.def
         elseif t is GenericType then
            t = t.t
         else
            return t
         end
      end
      return t
   end

   -- Walks a and b in step, as a comparison of them would reach their
   -- parts, and answers the first two function types it meets in the same
   -- place that disagree on whether the function never returns, or nil.
   -- The pair at the root is the comparison's own to judge: `root`
   -- holds while the walk has gone through nothing but names and unions.
   local function never_mismatch(a: Type, b: Type, root: boolean, seen: {Type:{Type:boolean}}): Type, Type
      a, b = walk_target(a), walk_target(b)
      if a == b then
         return nil
      end
      if not root then
         local with_a = seen[a]
         if with_a and with_a[b] then
            return nil
         end
         if not with_a then
            with_a = {}
            seen[a] = with_a
         end
         with_a[b] = true
      end

      if a is TupleType or b is TupleType then
         local ats: {Type} = a is TupleType and a.tuple or { a }
         local bts: {Type} = b is TupleType and b.tuple or { b }
         for i = 1, math.min(#ats, #bts) do
            local x, y = never_mismatch(ats[i], bts[i], root, seen)
            if x then
               return x, y
            end
         end
         return nil
      end

      if a is UnionType or b is UnionType then
         local ams: {Type} = a is UnionType and a.types or { a }
         local bms: {Type} = b is UnionType and b.types or { b }
         for _, am in ipairs(ams) do
            for _, bm in ipairs(bms) do
               local x, y = never_mismatch(am, bm, root, seen)
               if x then
                  return x, y
               end
            end
         end
         return nil
      end

      if a is PolyType or b is PolyType then
         if not root then
            local an, bn = never_of(a), never_of(b)
            if an ~= nil and bn ~= nil and an ~= bn then
               return a, b
            end
            return nil
         end
         local aos: {Type} = a is PolyType and a.types or { a }
         local bos: {Type} = b is PolyType and b.types or { b }
         for _, ao in ipairs(aos) do
            for _, bo in ipairs(bos) do
               local x, y = never_mismatch(ao, bo, root, seen)
               if x then
                  return x, y
               end
            end
         end
         return nil
      end

      if a is FunctionType and b is FunctionType then
         if not root and (not not a.never) ~= (not not b.never) then
            return a, b
         end
         local x, y = never_mismatch(a.args, b.args, false, seen)
         if x then
            return x, y
         end
         return never_mismatch(a.rets, b.rets, false, seen)
      end

      if a is ArrayType and b is ArrayType then
         return never_mismatch(a.elements, b.elements, false, seen)
      end

      if a is MapType and b is MapType then
         local x, y = never_mismatch(a.keys, b.keys, false, seen)
         if x then
            return x, y
         end
         return never_mismatch(a.values, b.values, false, seen)
      end

      if a is MapType and b is ArrayType then
         return never_mismatch(a.values, b.elements, false, seen)
      end

      if a is ArrayType and b is MapType then
         return never_mismatch(a.elements, b.values, false, seen)
      end

      if a is TupleTableType and b is TupleTableType then
         for i = 1, math.min(#a.types, #b.types) do
            local x, y = never_mismatch(a.types[i], b.types[i], false, seen)
            if x then
               return x, y
            end
         end
         return nil
      end

      if a is TupleTableType and b is ArrayType then
         for _, at in ipairs(a.types) do
            local x, y = never_mismatch(at, b.elements, false, seen)
            if x then
               return x, y
            end
         end
         return nil
      end

      if a is RecordLikeType and b is RecordLikeType then
         if a.elements and b.elements then
            local x, y = never_mismatch(a.elements, b.elements, false, seen)
            if x then
               return x, y
            end
         end
         for _, k in ipairs(a.field_order) do
            local bf = b.fields[k]
            if bf then
               local x, y = never_mismatch(a.fields[k], bf, false, seen)
               if x then
                  return x, y
               end
            end
         end
         if a.meta_fields and b.meta_fields then
            for _, k in ipairs(a.meta_field_order) do
               local bf = b.meta_fields[k]
               if bf then
                  local x, y = never_mismatch(a.meta_fields[k], bf, false, seen)
                  if x then
                     return x, y
                  end
               end
            end
         end
         return nil
      end

      if a is NominalType and b is NominalType and a.typevals and b.typevals then
         for i = 1, math.min(#a.typevals, #b.typevals) do
            local x, y = never_mismatch(a.typevals[i], b.typevals[i], false, seen)
            if x then
               return x, y
            end
         end
      end

      return nil
   end

   nested_never_mismatch = function(a: Type, b: Type): boolean
      return never_mismatch(a, b, false, {}) ~= nil
   end

   -- compare_types, once the outermost comparison has found that the two
   -- types agree on which of their nested functions never return. A
   -- comparison made inside another is not
   -- the outermost, and walks nothing: the walk covered it.
   local function compare_agreeing(self: TypeChecker, relations: TypeRelations, t1: Type, t2: Type): boolean, {Error}
      local depth = self.compare_depth or 0
      if depth == 0 and t1.typeid ~= t2.typeid
         and not (no_nested_types[t1.typename] and no_nested_types[t2.typename]) then
         local x, y = never_mismatch(t1, t2, true, {})
         if x then
            return false, { Err("got %s, expected %s, which differ in whether the function never returns, inside another type", x, y) }
         end
      end
      self.compare_depth = depth + 1
      local ok, errs = compare_types(self, relations, t1, t2)
      self.compare_depth = depth
      return ok, errs
   end

   -- subtyping comparison
   function TypeChecker:is_a(t1: Type, t2: Type): boolean, {Error}
      return compare_agreeing(self, self.subtype_relations, t1, t2)
   end

   -- invariant type comparison
   function TypeChecker:same_type(t1: Type, t2: Type): boolean, {Error}
      -- except for error messages, behavior is the same as
      -- `return (is_a(t1, t2) and self:is_a(t2, t1))`
      return compare_agreeing(self, self.eqtype_relations, t1, t2)
   end

   if TL_DEBUG then
      local orig_is_a = TypeChecker.is_a
      TypeChecker.is_a = function(self: TypeChecker, t1: Type, t2: Type): boolean, {Error}
         assert(type(t1) == "table")
         assert(type(t2) == "table")

         if t1.typeid == t2.typeid then
            local st1, st2 = show_type_base(t1, false, {}), show_type_base(t2, false, {})
            assert(st1 == st2, st1 .. " ~= " .. st2)
            return true
         end

         return orig_is_a(self, t1, t2)
      end
   end

   function TypeChecker:assert_is_a(w: Where, t1: Type, t2: Type, ctx?: string | Node, name?: string, described?: boolean): boolean
      t1 = resolve_tuple(t1)
      t2 = resolve_tuple(t2)
      if self.feat_lax and (is_unknown(t1) or t2 is UnknownType) then
         return true
      end

      if t2 is EmptyTableType then
         t2 = type_at(w, t2) -- minor hack: tweak point of inference
      end

      local ok, match_errs = self:is_a(t1, t2)
      if not ok then
         self.errs:add_prefixing(w, match_errs, self.errs:get_context(ctx, name), nil, self.errs:wrap_of(ctx, name, described))
      end
      return ok
   end

   local function type_is_closable(t: Type): boolean
      if t is InvalidType then
         return false
      end
      if t is NilType then
         return true
      end
      if t is NominalType then
         t = assert(t.resolved)
      end
      if t is RecordLikeType then
         return t.meta_fields and t.meta_fields["__close"] ~= nil
      end
   end

   local definitely_not_closable_exprs <const>: {NodeKind:boolean} = {
      ["string"] = true,
      ["number"] = true,
      ["integer"] = true,
      ["boolean"] = true,
      ["literal_table"] = true,
   }
   local function expr_is_definitely_not_closable(e: Node): boolean
      return definitely_not_closable_exprs[e.kind]
   end

   function TypeChecker:same_in_all_union_entries<T is Type, F is Type>(u: UnionType, check: function(Type): (T, F)): F
      assert(#u.types > 0)

      local t1, f = check(u.types[1])
      if not t1 then
         return nil
      end
      for i = 2, #u.types do
         local t2 = check(u.types[i])
         if not t2 or not self:same_type(t1, t2) then
            return nil
         end
      end
      return f
   end

   function TypeChecker:same_call_mt_in_all_union_entries(u: UnionType): FunctionType
      return self:same_in_all_union_entries(u, function(t: Type): (TupleType, FunctionType)
         t = self:to_structural(t)
         if t is RecordLikeType then
            local call_mt = t.meta_fields and t.meta_fields["__call"]
            if call_mt is FunctionType then
               local args_tuple = a_tuple(u, {})
               for i = 2, #call_mt.args.tuple do
                  table.insert(args_tuple.tuple, call_mt.args.tuple[i])
               end
               return args_tuple, call_mt
            end
         end
      end)
   end

   function TypeChecker:resolve_for_call(func: Type, args: TupleType, is_method: boolean): Type, boolean
      -- resolve unknown in lax mode, produce a general unknown function
      if self.feat_lax and is_unknown(func) then
         local unk = func
         func = a_function(func, {
            min_arity = 0,
            args = a_vararg(func, { unk }),
            rets = a_vararg(func, { unk })
         })
      end
      -- unwrap if tuple, resolve if nominal
      func = self:to_structural(func)

      if func is GenericType then
         func = self:apply_generic(func, func)
      end

      if func is FunctionType or func is PolyType then
         return func, is_method
      end

      -- resolve if union
      if func is UnionType then
         local r = self:same_call_mt_in_all_union_entries(func)
         if r then
            table.insert(args.tuple, 1, func.types[1]) -- FIXME: is this right?
            return r, true
         end
      -- resolve if prototype
      elseif func is TypeDeclType then
         return self:resolve_for_call(func.def, args, is_method)
      -- resolve if metatable
      elseif func is RecordLikeType and func.meta_fields and func.meta_fields["__call"] then
         table.insert(args.tuple, 1, func)
         func = func.meta_fields["__call"]
         func = self:to_structural(func)
         is_method = true
      end

      if func is GenericType then
         func = self:apply_generic(func, func)
      end

      return func, is_method
   end

   local type OnArgId = function<T>(node: Node, i: integer): T
   local type OnNode = function<S, T>(s: S, node: Node, children: {T}, ret: T): T

   local function traverse_macroexp<T>(macroexp: Node, on_arg_id: OnArgId<T>, on_node: OnNode<nil, T>): T
      local root = macroexp.exp
      local argnames = {}
      for i, a in ipairs(macroexp.args) do
         argnames[a.tk] = i
      end

      local visit_node: Visitor<nil, NodeKind, Node, T> = {
         cbs = {
            ["variable"] = {
               after = function(_: nil, node: Node, _children: {T}): T
                  local i = argnames[node.tk]
                  if not i then
                     return nil
                  end

                  return on_arg_id(node, i)
               end
            },
            ["..."] = {
               after = function(_: nil, node: Node, _children: {T}): T
                  local i = argnames[node.tk]
                  if not i then
                     return nil
                  end

                  return on_arg_id(node, i)
               end
            }
         },
         after = on_node as VisitorAfter<nil, Node, T>,
      }

      return recurse_node(nil, root, visit_node, {})
   end

   local function expand_macroexp(orignode: Node, args: {Node}, macroexp: Node)
      local on_arg_id = function(node: Node, i: integer): {Node, Node}
         if node.kind == '...' then
            -- we have to handle varargs specifically
            local nd: Node = node_at(orignode, {
               kind = "expression_list",
            })
            for n = i, #args do
               nd[n - i + 1] = args[n]
            end
            return { Node, nd }
         else
            -- the function should have already been typechecked for optional
            -- parameters.
            -- this one is optional, so return nil
            local nd: Node = args[i] or node_at(orignode, { kind = "nil", tk = "nil" })
            return { Node, nd }
         end
      end

      local on_node = function(_: nil, node: Node, children: {{Node, Node}}, ret: {Node, Node}): {Node, Node}
         local orig = ret and ret[2] or node

         local out = shallow_copy_table(orig)

         local map = {}
         for _, pair in pairs(children as {integer:{Node, Node}}) do
            if type(pair) == "table" then
               map[pair[1]] = pair[2]
            end
         end

         for k, v in pairs(orig as {any:Node}) do
            if type(v) == "table" and map[v] then
               (out as {any:any})[k] = map[v]
            end
         end

         out.yend = out.yend and (orignode.y + (out.yend - out.y)) or nil
         out.xend = nil
         out.y = orignode.y
         out.x = orignode.x
         return { node, out }
      end

      local p = traverse_macroexp(macroexp, on_arg_id, on_node)
      orignode.expanded = p[2]
   end

   function TypeChecker:check_macroexp_arg_use(macroexp: Node)
      local used: {string:boolean} = {}

      local on_arg_id = function(node: Node, _i: integer): {Node, Node}
         if used[node.tk] then
            self.errs:add(node, "cannot use argument '" .. node.tk .. "' multiple times in macroexp")
         else
            used[node.tk] = true
         end
      end

      traverse_macroexp(macroexp, on_arg_id, nil)
   end

   local function apply_macroexp(orignode: Node)
      local expanded = orignode.expanded
      local saveguard = orignode.guard
      orignode.expanded = nil

      for k, _ in pairs(orignode as {any:any}) do
         (orignode as {any:any})[k] = nil
      end
      for k, v in pairs(expanded as {any:any}) do
         (orignode as {any:any})[k] = v
      end
      orignode.guard = saveguard
   end

   do
      local function mark_invalid_typeargs(self: TypeChecker, typeargs: {TypeArgType})
         for _, a in ipairs(typeargs) do
            if not self:find_var_type(a.typearg) then
               if a.constraint then
                  self:add_var(nil, a.typearg, a.constraint)
               else
                  self:add_var(nil, a.typearg, self.feat_lax and an_unknown(a) or a_type(a, "unresolvable_typearg", {
                     typearg = a.typearg
                  } as UnresolvableTypeArgType))
               end
            end
         end
      end

      local function check_argument_omissions(self: TypeChecker, literal: Node, param: Type, nested: boolean)
         if literal.kind ~= "literal_table" or literal.omissions_checked then
            return
         end
         if param is TypeVarType then
            local bound = self:find_var_type(param.typevar)
            local record = bound and self:to_structural(bound)
            -- A variable bound by the elements of the literal being checked
            -- (`ipairs({ { ok = true }, { ok = false, why = "x" } })`) is
            -- bound to a record that no one declared: only a declared one
            -- is a record to hold an element to.
            if record is RecordLikeType and (not nested or record.declname) then
               check_literal_omissions(self, literal, record)
            end
         elseif param is UnionType then
            -- A table literal can only be the one member that holds a
            -- table or a type variable (`{T} | nil`, `T | string`); with
            -- two such members it is not known which, and none is checked.
            -- TODO: a union of two table members (`{T} | {string:T}`) is
            -- left unchecked: choose the member the literal's keys fit.
            local holder: Type = nil
            local count = 0
            for _, member in ipairs(param.types) do
               if member is TypeVarType or member is ArrayType or member is MapType or member is TupleTableType then
                  holder = member
                  count = count + 1
               end
            end
            if count == 1 then
               check_argument_omissions(self, literal, holder, nested)
            end
         elseif param is ArrayType then
            for _, item in ipairs(literal) do
               if item.value then
                  check_argument_omissions(self, item.value, param.elements, true)
               end
            end
         elseif param is MapType then
            for _, item in ipairs(literal) do
               if item.value then
                  check_argument_omissions(self, item.value, param.values, true)
               end
            end
         elseif param is TupleTableType then
            local position = 0
            for _, item in ipairs(literal) do
               if item.key_parsed == "implicit" then
                  position = position + 1
                  local element = param.types[position]
                  if element and item.value then
                     check_argument_omissions(self, item.value, element, true)
                  end
               end
            end
         end
      end

      local function infer_emptytables(self: TypeChecker, w: Where, wheres: {Where}, xs: TupleType, ys: TupleType, delta: integer)
         local xt, yt = xs.tuple, ys.tuple
         local n_xs = #xt
         local n_ys = #yt
         -- resolve inference of emptytables used as arguments or returns
         for i = 1, n_xs do
            local x = xt[i]
            local literal = wheres and (wheres[i + delta] as Node)
            if literal then
               local param = yt[i] or (ys.is_va and yt[n_ys])
               if param then
                  check_argument_omissions(self, literal, param, false)
               end
            end
            if x is EmptyTableType then
               local y = yt[i] or (ys.is_va and yt[n_ys])
               if y then -- y may not be present when inferring returns
                  local iw = wheres and wheres[i + delta] or w -- for self, a + argdelta is 0
                  local inferred_y = self:infer_at(iw, y)
                  self:infer_emptytable(x, inferred_y)
                  xt[i] = inferred_y
               end
            end
         end
      end

      local enum CallMode
         "method"   -- a method colon-call, e.g. `my_object:my_method()`
         "plain"    -- a plain call or a dot-call, e.g `my_func()` or `my_object.my_func()`
         "type_dot" -- a dot-call where the receiver is a type, e.g. `MyRecord.my_func()`
      end

      local check_call: function(self: TypeChecker, w: Where, wargs: {Where}, f: FunctionType, args: TupleType, expected_rets: TupleType, cm: CallMode, argdelta: integer, or_args: TupleType, or_rets: TupleType): boolean, {Error}
      do
         local check_args_rets: function(TypeChecker, w: Where, wargs: {Where}, f: FunctionType, args: TupleType, expected_rets: TupleType, argdelta: integer, or_args: TupleType, or_rets: TupleType): boolean, {Error}
         do
            -- The parameters of the call being checked that it cannot omit.
            local call_min_arity = 0
            -- check if a tuple `xs` matches tuple `ys`
            local function check_func_type_list(self: TypeChecker, w: Where, wheres: {Where}, xs: TupleType, ys: TupleType, from: integer, delta: integer, v: VarianceMode, mode: ArgCheckMode): boolean, {Error}
               local errs = {}
               local xt, yt = xs.tuple, ys.tuple
               local n_xs = #xt
               local n_ys = #yt

               for i = from, math.max(n_xs, n_ys) do
                  local pos = i + delta
                  local x = xt[i] or (xs.is_va and xt[n_xs]) or a_type(w, "nil", {})
                  local y = yt[i] or (ys.is_va and yt[n_ys])
                  if y then
                     local iw = wheres and wheres[pos] or w
                     if not self:arg_check(iw, errs, x, y, v, mode, pos) then
                        return nil, errs
                     end
                     -- TODO: Teal does not narrow on an assignment at a join, so a
                     -- value made non-nil by one (`if x == nil then x = d end`,
                     -- `if not x then x = d end`, a `while` or `repeat` that assigns
                     -- until it is not nil) is still `T | nil` here and refused, with
                     -- `x = x or d` as the fix. It waits on the facts of a branch and of
                     -- a loop taking the type an assignment gives its variable.
                     if mode == "argument" and v == "contravariant" and (i <= call_min_arity or (xs.is_va and i >= n_xs)) then
                        local taken = x
                        if taken is TypeVarType then
                           taken = self:find_var_type(taken.typevar)
                        end
                        if taken and not admits_nil(self, iw, taken) and
                           not (taken is NominalType and taken.names[1] == "metatable") and
                           (without_nil(self, iw, y, false) ~= nil or y.typename == "nil") then
                           self.errs:add_prefixing(iw, { Errors.mismatch(Err("got %s, expected %s", y, taken), y, taken) }, "argument " .. pos .. ": ", errs,
                              Errors.make({ context = "argument", index = pos }))
                           return nil, errs
                        end
                     end
                  end
               end

               return true
            end

            check_args_rets = function(self: TypeChecker, w: Where, wargs: {Where}, f: FunctionType, args: TupleType, expected_rets: TupleType, argdelta: integer, or_args: TupleType, or_rets: TupleType): boolean, {Error}
               local rets_ok = true
               local args_ok, args_errs: boolean, {Error} = true, nil

               local fargs = or_args or f.args
               local frets = or_rets or f.rets
               call_min_arity = f.min_arity or 0

               local from = 1
               if argdelta == -1 then
                  from = 2
                  local errs = {}
                  local first = fargs.tuple[1]
                  if (not first is SelfType) and not self:arg_check(w, errs, first, args.tuple[1], "contravariant", "self") then
                     return nil, errs
                  end
               end

               -- The call's type variables are bound in the innermost scope,
               -- the call's own transaction: what is bound before the first
               -- order runs is restored for the second.
               local scope = self.st[#self.st]
               local before: {string:Variable} = {}
               if expected_rets then
                  for name, var in pairs(scope.vars) do
                     before[name] = var
                  end
               end

               if expected_rets then
                  expected_rets = self:infer_at(w, expected_rets)
                  infer_emptytables(self, w, nil, expected_rets, frets, 0)

                  rets_ok = check_func_type_list(self, w, nil, frets, expected_rets, 1, 0, "covariant", "return")
               end

               args_ok, args_errs = check_func_type_list(self, w, wargs, fargs, args, from, argdelta, "contravariant", "argument")
               if (not args_ok) or (not rets_ok) then
                  if expected_rets and scope.is_transaction then
                     -- The expected type bound a type variable before the
                     -- arguments did: bind it from them and check the result
                     -- against that.
                     local failed: {string:Variable} = {}
                     for name, var in pairs(scope.vars) do
                        failed[name] = var
                        scope.vars[name] = nil
                     end
                     for name, var in pairs(before) do
                        scope.vars[name] = var
                     end
                     local args_ok2 = check_func_type_list(self, w, wargs, fargs, args, from, argdelta, "contravariant", "argument")
                     if args_ok2 and check_func_type_list(self, w, nil, frets, expected_rets, 1, 0, "covariant", "return") then
                        infer_emptytables(self, w, wargs, args, fargs, argdelta)
                        return true
                     end
                     for name in pairs(scope.vars) do
                        scope.vars[name] = nil
                     end
                     for name, var in pairs(failed) do
                        scope.vars[name] = var
                     end
                  end
                  return nil, args_errs or {}
               end

               infer_emptytables(self, w, wargs, args, fargs, argdelta)

               return true
            end
         end

         local function is_method_mismatch(self: TypeChecker, w: Where, arg1: Type, farg1: Type, cm: CallMode): boolean
            if cm == "method" or not farg1 then
               return false
            end
            if not (arg1 and self:is_a(arg1, farg1)) then
               self.errs:add(w, "invoked method as a regular function: use ':' instead of '.'")
               return true
            end
            if cm == "plain" then
               self.errs:add_warning("hint", w, "invoked method as a regular function: consider using ':' instead of '.'")
            end
            return false
         end

         check_call = function(self: TypeChecker, w: Where, wargs: {Where}, f: FunctionType, args: TupleType, expected_rets: TupleType, cm: CallMode, argdelta: integer, or_args: TupleType, or_rets: TupleType): boolean, {Error}
            local arg1 = args.tuple[1]
            if cm == "method" and arg1 then
               local selftype = arg1
               if selftype is SelfType then
                  selftype = self:type_of_self(selftype)
               end
               self:add_var(nil, "@self", a_typedecl(w, selftype))
            end

            local fargs = (or_args or f.args).tuple
            if f.is_method and is_method_mismatch(self, w, arg1, fargs[1], cm) then
               return false
            end

            local given = #args.tuple
            local wanted = #fargs
            local min_arity = self.feat_arity and f.min_arity or 0

            if given < min_arity or (given > wanted and not (or_args or f.args).is_va) then
               local exact, most = Errors.arity_counts(f)
               local err = Err_at(w, "wrong number of arguments (given " .. given .. ", expects " .. show_arity(f) .. ")")
               err.code, err.given, err.expects, err.expects_most = "arity", given, exact, most
               return nil, { err }
            end

            return check_args_rets(self, w, wargs, f, args, expected_rets, argdelta, or_args, or_rets)
         end
      end

      function TypeChecker:iterate_poly(p: PolyType): function(): integer, FunctionType
         local i = 0
         return function(): integer, FunctionType
            i = i + 1
            local fg = p.types[i]
            if not fg then
               return
            elseif fg is FunctionType then
               return i, fg
            elseif fg is GenericType then
               return i, self:apply_generic(p, fg) as FunctionType
            end
         end
      end

      local check_poly_call: function(self: TypeChecker, w: Where, wargs: {Where}, p: PolyType, args: TupleType, expected_rets: TupleType, cm: CallMode, argdelta: integer, or_args: TupleType, or_rets: TupleType): FunctionType, TupleType, {Error}
      do
         local function fail_poly_call_arity(self: TypeChecker, w: Where, p: PolyType, given: integer): {Error}
            local expects: {string} = {}
            local exact: integer = nil
            local most = 0
            for _, f in self:iterate_poly(p) do
               local only, at_most = Errors.arity_counts(f)
               exact = only
               most = math.max(most, at_most)
               table.insert(expects, show_arity(f))
            end
            table.sort(expects)
            for i = #expects, 1, -1 do
               if expects[i] == expects[i+1] then
                  table.remove(expects, i)
               end
            end
            local err = Err_at(w, "wrong number of arguments (given " .. given .. ", expects " .. table.concat(expects, " or ") .. ")")
            err.code, err.given, err.expects_most = "arity", given, most
            if #expects == 1 then
               err.expects = exact
            end
            return { err }
         end

         check_poly_call = function(self: TypeChecker, w: Where, wargs: {Where}, p: PolyType, args: TupleType, expected_rets: TupleType, cm: CallMode, argdelta: integer, or_args: TupleType, or_rets: TupleType): FunctionType, TupleType, {Error}
            local given = #args.tuple

            local tried: {integer:boolean} = {}
            local first_rets: TupleType = nil
            local first_errs: {Error} = nil

            for pass = 1, 3 do
               for i, f in self:iterate_poly(p) do
                  assert(f is FunctionType, f.typename)
                  assert(f.args)
                  first_rets = first_rets or or_rets or f.rets

                  local wanted = #f.args.tuple
                  local min_arity = self.feat_arity and f.min_arity or 0

                  if (not tried[i]) and
                     -- try exact arity matches first
                     (  (pass == 1 and given == wanted)
                     -- then try adjusting with nils to missing arguments or using '...'
                     or (pass == 2 and (given < wanted and given >= min_arity))
                     -- then finally try vararg functions
                     or (pass == 3 and (f.args.is_va and given > wanted)) )
                  then
                     local ok, errs = check_call(self, w, wargs, f, args, expected_rets, cm, argdelta, or_args, or_rets)
                     if ok then
                        return f, or_rets or f.rets
                     elseif expected_rets then
                        -- revert inferred returns
                        infer_emptytables(self, w, wargs, or_rets or f.rets, or_rets or f.rets, argdelta)
                     end

                     self:rollback_scope_transaction()

                     first_errs = first_errs or errs
                     tried[i] = true
                  end
               end
            end

            if not first_errs then
               return nil, first_rets, fail_poly_call_arity(self, w, p, given)
            end

            return nil, first_rets, first_errs
         end
      end

      local function should_warn_dot(node: Node, e1: Node, is_method: boolean): CallMode
         if is_method then
            return "method"
         end
         if node_is_funcall(node) and e1 and e1.receiver then
            local receiver = e1.receiver
            if receiver is NominalType then
               local resolved = receiver.resolved
               if resolved and resolved is TypeDeclType then
                  return "type_dot"
               end
            end
         end
         return "plain"
      end

      function TypeChecker:type_check_function_call(node: Node, func: Type, args: TupleType, argdelta: integer, or_args ?: TupleType, or_rets ?: TupleType, e1?: Node, e2?: {Node}): InvalidOrTupleType, FunctionType
         e1 = e1 or node.e1
         e2 = e2 or node.e2

         local expected = node.expected
         local expected_rets: TupleType
         if expected and expected is TupleType then
            expected_rets = expected
         else
            expected_rets = a_tuple(node, { node.expected })
         end

         self:begin_scope_transaction(node)

         local g: GenericType = nil
         local typeargs: {TypeArgType} = nil
         if func is GenericType then
            g = func
            func, typeargs = self:apply_generic(node, func)
         end

         local is_method = (argdelta == -1)

         if not (func is FunctionType or func is PolyType) then
            func, is_method = self:resolve_for_call(func, args, is_method)
            if is_method then
               argdelta = -1
            end
         end

         local cm = should_warn_dot(node, e1, is_method)

         local errs: {Error} = nil
         local f, ret: FunctionType, InvalidOrTupleType = nil, nil

         if func is PolyType then
            f, ret, errs = check_poly_call(self, node, e2, func, args, expected_rets, cm, argdelta, or_args, or_rets)
         elseif func is FunctionType then
            local _: boolean
            _, errs = check_call(self, node, e2, func, args, expected_rets, cm, argdelta, or_args, or_rets)
            f, ret = func, or_rets or func.rets
         else
            ret = self.errs:invalid_at(node, "not a function: %s", func)
         end

         if errs then
            self.errs:collect(errs)
         end

         if f and f.never and node_is_funcall(node) then
            flow.mark_never_call(node as flow.Node)
         end

         if g then
            mark_invalid_typeargs(self, typeargs)
         end

         self:commit_scope_transaction(node)

         ret = self:assert_resolved_typevars_at(node, ret) as InvalidOrTupleType

         if self.collector then
            self.collector.store_type(e1.y, e1.x, f)
         end

         if f and f.macroexp then
            local argexps: {Node}
            if is_method then
               argexps = {}
               if e1.kind == "op" then -- obj:method
                  table.insert(argexps, e1.e1)
               else -- __call metamethod
                  table.insert(argexps, e1)
               end
               for _, e in ipairs(e2) do
                  table.insert(argexps, e)
               end
            else
               argexps = e2
            end
            expand_macroexp(node, argexps, f.macroexp)
         end

         return ret, f
      end
   end

   function TypeChecker:check_metamethod(node: Node, method_name: string, a: Type, b: Type, orig_a: Type, orig_b: Type, flipped?: boolean): Type, integer
      if self.feat_lax and ((a and is_unknown(a)) or (b and is_unknown(b))) then
         return an_unknown(node), nil
      end

      local ameta = a is RecordLikeType and a.meta_fields
      local bmeta = b and b is RecordLikeType and b.meta_fields

      if not ameta and not bmeta then
         return nil, nil
      end

      local meta_on_operator = 1
      local metamethod: Type = nil
      if method_name ~= "__is" then
         metamethod = ameta and ameta[method_name or ""]
      end
      if (not metamethod) and b and method_name ~= "__index" then
         metamethod = bmeta and bmeta[method_name or ""]
         meta_on_operator = 2
      end

      if metamethod then
         -- A macro expression (a `where` clause is one) is written in place
         -- of the operator, so it runs code only if its expression calls.
         local runs = not (metamethod is FunctionType and metamethod.macroexp
            and not self:macroexp_calls(metamethod.macroexp.exp))
         self.metamethod_ran = runs
         if method_name == "__index" then
            self.index_metamethod = runs
         end
         local e2 = { node.e1 }
         local args = a_tuple(node, { orig_a })
         if b and method_name ~= "__is" then
            e2[2] = node.e2
            args.tuple[2] = orig_b
         end
         if flipped then
            e2[2], e2[1] = e2[1], e2[2]
         end

         local mtdelta = metamethod is FunctionType and metamethod.is_method and -1 or 0
         local ret_call <const> = self:type_check_function_call(node, metamethod, args, mtdelta, nil, nil, node, e2)
         local ret_unary <const> = resolve_tuple(ret_call)
         local ret <const> = self:to_structural(ret_unary)
         self.metamethod_ran = runs
         return ret, meta_on_operator
      else
         return nil, nil
      end
   end

   local function make_is_node(self: TypeChecker, var: Node, v: Type, t: Type): Node, integer
      local node = node_at(var, { kind = "op", op = { op = "is", arity = 2, prec = 3 } })
      node.e1 = var
      node.e2 = node_at(var, { kind = "cast", casttype = self:infer_at(var, t) })
      local _, has = self:check_metamethod(node, "__is", self:to_structural(v), self:to_structural(t), v, t)
      if node.expanded then
         apply_macroexp(node)
      end
      node.guard = narrowing.type_is(node, narrowing.local_place(var.tk), t as narrowing.Type)
      return node, has
   end

   local function convert_is_of_union_to_or_of_is(self: TypeChecker, node: Node, v: Type, u: UnionType): boolean
      local var = node.e1
      node.op.op = "or"
      node.op.arity = 2
      node.op.prec = 1
      local has_any: integer = nil
      node.e1, has_any = make_is_node(self, var, v, u.types[1])
      local at = node
      local n = #u.types
      for i = 2, n - 1 do
         at.e2 = node_at(var, { kind = "op", op = { op = "or", arity = 2, prec = 1 } })
         local has: integer
         at.e2.e1, has = make_is_node(self, var, v, u.types[i])
         has_any = has_any or has
         node.guard = narrowing.any_of(node, at.e1.guard, at.e2.guard)
         at = at.e2
      end
      at.e2 = make_is_node(self, var, v, u.types[n])
      node.guard = narrowing.any_of(node, at.e1.guard, at.e2.guard)
      return not not has_any
   end

   local function value_fields(t: RecordLikeType): {string}
      local names: {string} = {}
      for name, ft in pairs(t.fields) do
         if not ft is TypeDeclType then
            table.insert(names, name)
         end
      end
      return names
   end

   -- The type of the field `key` of `t`, or, where it has none, the message
   -- saying so and the error's code and fields.
   function TypeChecker:match_record_key(t: Type, rec: Node, key: string): Type, string, Error
      t = self:to_structural(t)

      if t is SelfType then
         t = self:type_of_self(t)
      end

      if t is StringType or t is EnumType then
         -- simulate string metatable
         t = self.env.modules["string"]
         self.all_needs_compat["string"] = true
      end

      if t is TypeDeclType then
         if t.is_nested_alias then
            return nil, "cannot use a nested type alias as a concrete value"
         end
         local def = t.def
         if def is NominalType then
            assert(t.is_alias)
            t = self:resolve_nominal(def)
         else
            t = def
         end
      end

      if t is GenericType then
         t = self:apply_generic(t, t)
      end

      if t is UnionType then
         local ty = self:same_in_all_union_entries(t, function(typ: Type): (Type, Type)
            local v = self:match_record_key(typ, rec, key)
            return v, v
         end)
         if ty then
            return ty
         end
      end

      if (t is TypeVarType or t is TypeArgType) and t.constraint then
         local ty = self:match_record_key(t.constraint, rec, key)
         if ty then
            return ty
         end
      end

      local keyg = key:gsub("%%", "%%%%")

      if t is RecordLikeType then
         assert(t.fields, "record has no fields!?")

         if t.fields[key] then
            return t.fields[key]
         end

         local str = a_type(rec, "string", {})
         local meta_t = self:check_metamethod(rec, "__index", t, str, t, str)
         if meta_t then
            return meta_t
         end

         if rec.kind == "variable" then
            if t is InterfaceType then
               return nil, "invalid key '" .. keyg .. "' in '" .. rec.tk .. "' of interface type %s",
                  Errors.make({ code = "invalid_key", key = key, variable = rec.tk, resolved_kind = t.typename, fields = value_fields(t) })
            else
               return nil, "invalid key '" .. keyg .. "' in record '" .. rec.tk .. "' of type %s",
                  Errors.make({ code = "invalid_key", key = key, variable = rec.tk, resolved_kind = t.typename, fields = value_fields(t) })
            end
         else
            return nil, "invalid key '" .. keyg .. "' in type %s",
               Errors.make({ code = "invalid_key", key = key, resolved_kind = t.typename, fields = value_fields(t) })
         end
      elseif t is EmptyTableType or is_unknown(t) then
         if self.feat_lax then
            return an_unknown(rec)
         end
         return nil, "cannot index a value of unknown type"
      end

      if rec.kind == "variable" then
         return nil, "cannot index key '" .. keyg .. "' in variable '" .. rec.tk .. "' of type %s",
            Errors.make({ code = "cannot_index_key", key = key, variable = rec.tk })
      else
         return nil, "cannot index key '" .. keyg .. "' in type %s",
            Errors.make({ code = "cannot_index_key", key = key })
      end
   end

   -- Whether `root` assigns a local of that name. A field a loop writes is
   -- told when the loop ends (`loop_end`), not here.
   local function assigned_anywhere(name: string, root: Node): boolean
      local visit_node: Visitor<nil, NodeKind, Node, boolean> = {
         cbs = {
            ["assignment"] = {
               after = function(_: nil, node: Node, _children: {boolean}): boolean
                  for _, v in ipairs(node.vars) do
                     if v.kind == "variable" and v.tk == name then
                        return true
                     end
                  end
                  return false
               end
            }
         },
         after = function(_: nil, _node: Node, children: {boolean}, ret: boolean): boolean
            ret = ret or false
            -- an `else` has no condition, which leaves a hole in `children`
            for _, c in pairs(children as {integer:boolean}) do
               local ca = c as any
               if ca is boolean then
                  ret = ret or c
               end
            end
            return ret
         end
      }

      local visit_type: Visitor<nil, TypeName, Type, boolean> = {
         after = function(): boolean
            return false
         end
      }

      return recurse_node(nil, root, visit_node, visit_type)
   end

   function TypeChecker:widen_all_unions(node?: Node)
      for i = #self.st, 1, -1 do
         local scope = self.st[i]
         if scope.narrows then
            for name, _ in pairs(scope.narrows) do
               if not node or assigned_anywhere(name, node) then
                  self:widen_in_scope(i, name)
               end
            end
         end
      end
   end

   function TypeChecker:add_global(node: Node, varname: string, valtype: Type, is_assigning?: boolean): Variable
      if self.feat_lax and is_unknown(valtype) and (varname ~= "self" and varname ~= "...") then
         self.errs:add_unknown(node, varname)
      end

      local is_const = node.attribute ~= nil
      local existing, scope, existing_attr = self:find_var(varname)
      if existing then
         if scope > 1 then
            self.errs:add(node, "cannot define a global when a local with the same name is in scope")
         elseif is_assigning and existing_attr then
            self.errs:add(node, "cannot reassign to <" .. existing_attr .. "> global: " .. varname)
         elseif existing_attr and not is_const then
            self.errs:add(node, "global was previously declared as <" .. existing_attr .. ">: " .. varname)
         elseif (not existing_attr) and is_const then
            self.errs:add(node, "global was previously declared as not <" .. node.attribute .. ">: " .. varname)
         elseif valtype and not self:same_type(existing.t, valtype) then
            self.errs:add(node, "cannot redeclare global with a different type: previous type of " .. varname .. " is %s", existing.t)
         end
         return nil
      end

      local var = { t = valtype, attribute = is_const and "const" or nil }
      self.st[1].vars[varname] = var

      return var
   end

   local record TypeVarSearch
      tc: TypeChecker
      unbound: boolean
   end

   local unbound_typevar_fns: TypeFunctionMap<TypeVarSearch> = {
      ["typevar"] = function(s: TypeVarSearch, tv: TypeVarType): Type, boolean
         local bound = s.tc:find_var_type(tv.typevar, "check_only")
         if not (bound and bound is TypeArgType) then
            s.unbound = true
         end
         return tv, false
      end,
   }

   -- Whether t holds a type variable other than an enclosing generic
   -- function's own: one a generic call applied and no argument has
   -- bound yet, or one bound to another, which a single resolution
   -- leaves in place.
   local function has_unbound_typevars(self: TypeChecker, t: Type): boolean
      local search: TypeVarSearch = { tc = self, unbound = false }
      map_type(search, t, unbound_typevar_fns)
      return search.unbound
   end

   -- The function type a function literal is expected to have: the
   -- expected type with the type variables bound so far applied, or of
   -- a union the one function member. nil for no expectation, a generic
   -- or overloaded one, or a union with more than one function member.
   local function context_function_type(self: TypeChecker, expected: Type): FunctionType
      if not expected then
         return nil
      end
      local resolved, errs = resolve_typevars(self, expected)
      if errs then
         return nil
      end
      local t = self:to_structural(resolved)
      if t is UnionType then
         local found: FunctionType = nil
         for _, m in ipairs(t.types) do
            local rm = self:to_structural(m)
            if rm is FunctionType then
               if found then
                  return nil
               end
               found = rm
            elseif rm is GenericType or rm is PolyType then
               return nil
            end
         end
         return found
      end
      if t is FunctionType then
         return t
      end
      return nil
   end

   -- Binds the type variables of the generic call being checked that
   -- given, an argument's type, binds against expected, its parameter's,
   -- as the call's own check will once every argument is known; only
   -- when given fits, so an argument the call refuses binds nothing.
   -- A nested generic call's result (`f(g(xs), function(x) ... end)`)
   -- binds nothing: its variables are bound only in its own check, and
   -- binding the outer call's to them left a literal a variable bound
   -- to another rather than a type.
   -- TODO: bind from it too, resolving the chain of variables the inner
   -- check commits to the type at its end, so x is xs's element type.
   local function bind_typevars_from(self: TypeChecker, given: Type, expected: Type)
      if has_unbound_typevars(self, given) then
         return
      end
      local st = self.st
      table.insert(st, { vars = {} })
      local ok = self:is_a(given, expected)
      local scope = table.remove(st)
      if ok then
         local outer = st[#st].vars
         for name, var in pairs(scope.vars) do
            outer[name] = var
         end
      end
   end

   function TypeChecker:add_internal_function_variables(node: Node, args: TupleType)
      self:add_var(nil, "@is_va", a_type(node, args.is_va and "any" or "nil", {}))
      self:add_var(nil, "@never", a_type(node, (node.never or node.context_never) and "any" or "nil", {}))
      self:add_var(nil, "@return", node.rets or a_tuple(node, {}))

      if node.typeargs then
         for _, t in ipairs(node.typeargs) do
            local v = self:find_var(t.typearg, "check_only")
            if not v or not v.used_as_type then
               self.errs:add(t, "type argument '%s' is not used in function signature", t)
            end
         end
      end
   end

   function TypeChecker:add_function_definition_for_recursion(node: Node, fnargs: TupleType, feat_arity: boolean)
      self:add_var(nil, node.name.tk, wrap_generic_if_typeargs(node.typeargs, a_function(node, {
         min_arity = feat_arity and node.min_arity or 0,
         args = fnargs,
         rets = self.get_rets(node.rets),
         never = node.never,
      })))
   end

   function TypeChecker:end_function_scope(node: Node)
      self.errs:fail_unresolved_labels(self.st[#self.st])
      local hidden = self.st[#self.st].hidden
      self:end_scope(node)
      if hidden then
         narrowing.leave_function(self.st as {narrowing.Scope}, hidden)
      end
      local def = node.kind == "local_macroexp" and node.macrodef or node
      if def.never then
         if def.kind == "macroexp" then
            if not flow.ends(def.exp as flow.Node) then
               self.errs:add(node, "this macroexp is declared 'never', but its expression is no call that never returns")
            end
         elseif not flow.ends_body(node.body as flow.Node) then
            self.errs:add(node, "this function is declared 'never', but can reach its end: end it with a call that never returns, such as error(...)")
         end
      end
   end

   local function flat_tuple(w: Where, vt: {FirstClassType | TupleType}): TupleType
      local n_vals = #vt
      local ret = a_tuple(w, {})
      local rt = ret.tuple

      if n_vals == 0 then
         return ret
      end

      -- get all arguments except the last...
      for i = 1, n_vals - 1 do
         rt[i] = resolve_tuple(vt[i])
      end

      local last = vt[n_vals]
      if last is TupleType then
         -- ...then unpack the last tuple
         local lt = last.tuple
         for _, v in ipairs(lt) do
            table.insert(rt, v)
         end
         ret.is_va = last.is_va
      else
         rt[n_vals] = vt[n_vals]
      end

      return ret
   end

   local function get_assignment_values(w: Where, vals: TupleType, wanted: integer): TupleType
      if vals == nil then
         return a_tuple(w, {})
      end

      -- ...if the last is vararg, repeat its type until it matches the number of wanted args
      if vals.is_va then
         local vt = vals.tuple
         local n_vals = #vt
         if n_vals > 0 and n_vals < wanted then
            local last = vt[n_vals]
            local ret = a_tuple(w, {})
            local rt = ret.tuple
            for i = 1, n_vals do
               table.insert(rt, vt[i])
            end
            for _ = n_vals + 1, wanted do
               table.insert(rt, last)
            end
            return ret
         end
      end
      return vals
   end

   function TypeChecker:match_all_record_field_names(node: Node, a: RecordLikeType, field_names: {string}, errmsg: string): Type
      local t: Type = nil
      for _, k in ipairs(field_names) do
         local f = a.fields[k]
         if not t then
            t = f
         else
            if not self:same_type(f, t) then
               errmsg = errmsg .. string.format(" (types of fields '%s' and '%s' do not match)", field_names[1], k)
               t = nil
               break
            end
         end
      end
      if t then
         return t
      else
         return self.errs:invalid_at(node, errmsg)
      end
   end

   -- The type a place has now, even the first time a field is narrowed:
   -- a local's is whatever the checker already tracks for it
   -- (find_var_type finds it directly); a field with no narrow recorded
   -- yet falls back to the field's type as declared on the base local's
   -- CURRENT type. This must be a SILENT query -- by the time a guard
   -- composed with another (an `or`, say) is finally applied, the scope
   -- that temporarily narrowed the base local while the guard was built
   -- has already closed, so its current type can be one the field access
   -- that created the guard never actually ran against (`any`,
   -- typically). match_record_key, unlike type_check_index, never adds an
   -- error itself -- it hands nil plus a message back to its caller to
   -- report -- so a base that turns out not to carry this field after
   -- all just answers nil here, the same as an unknown variable would.
   function TypeChecker:place_type(place: narrowing.Place, w: Where): Type
      local typ = self:find_var_type(place.key, "check_only")
      if typ then
         return typ
      end
      if #place.fields == 0 then
         return nil
      end
      local base = self:find_var_type(place.base, "check_only")
      if not base then
         return nil
      end
      for _, field in ipairs(place.fields) do
         base = without_nil(self, w, base, false) or base
         base = (self:match_record_key(base, w as Node, field))
         if not base then
            return nil
         end
      end
      return base
   end

   function TypeChecker:type_check_index(anode: Node, bnode: Node, a: Type, b: Type): Type
      assert(not a is TupleType)
      assert(not b is TupleType)

      local ra = resolve_typedecl(self:to_structural(a))
      local rb = self:to_structural(b)

      if self.feat_lax and is_unknown(a) then
         return a
      end

      local errm: string = nil
      local erra: Type = nil
      local errb: Type = nil
      local errdetails: Error = nil

      if ra is TupleTableType and rb is IntegerType then
         if bnode.constnum then
            if bnode.constnum >= 1 and bnode.constnum <= #ra.types and bnode.constnum == math.floor(bnode.constnum) then
               return ra.types[bnode.constnum as integer]
            end

            errm, erra = "index " .. tostring(bnode.constnum) .. " out of range for tuple %s", ra
         else
            local array_type = self:arraytype_from_tuple(bnode, ra)
            if array_type then
               return array_type.elements
            end

            errm = "cannot index this tuple with a variable because it would produce a union type that cannot be discriminated at runtime"
         end
      elseif ra is SelfType then
         return self:type_check_index(anode, bnode, self:type_of_self(a), b)
      elseif ra is ArrayLikeType and rb is IntegerType then
         return ra.elements
      elseif ra is EmptyTableType then
         if ra.keys == nil then
            ra.keys = self:infer_at(bnode, b)
         end

         if self:is_a(b, ra.keys) then
            return a_type(anode, "unresolved_emptytable_value", {
               emptytable_type = ra
            } as UnresolvedEmptyTableValueType)
         end

         errm, erra, errb = "inconsistent index type: got %s, expected %s" .. inferred_msg(ra.keys, "type of keys "), b, ra.keys
         errdetails = Errors.nest(Errors.mismatch(Errors.make(), b, ra.keys))
      elseif ra is UnresolvedEmptyTableValueType then
         local et = a_type(ra, "emptytable", { keys = b } as EmptyTableType)
         infer_emptytable_from_unresolved_value(self, a, ra, et)
         return a_type(anode, "unresolved_emptytable_value", {
            emptytable_type = et
         } as UnresolvedEmptyTableValueType)
      elseif ra is MapType then
         if self:is_a(b, ra.keys) then
            return ra.values
         end

         errm, erra, errb = "wrong index type: got %s, expected %s", b, ra.keys
         errdetails = Errors.nest(Errors.mismatch(Errors.make(), b, ra.keys))
      elseif rb is StringType and rb.literal then
         local t, e, details = self:match_record_key(a, anode, rb.literal)
         if t then

            if t is FunctionType and t.is_method then
               local t2 = shallow_copy_new_type(t)
               t2.args = shallow_copy_new_type(t.args)
               t2.args.tuple = shallow_copy_table(t2.args.tuple)
               for i, p in ipairs(t2.args.tuple) do
                  if p is SelfType then
                     t2.args.tuple[i] = a
                  end
               end
               return t2
            end

            return t
         end

         errm, erra, errdetails = e, a, Errors.about(details, a)
      elseif ra is RecordLikeType then
         if rb is EnumType then
            local field_names: {string} = sorted_keys(rb.enumset)
            for _, k in ipairs(field_names) do
               if not ra.fields[k] then
                  errm, erra = "enum value '" .. k:gsub("%%", "%%%%") .. "' is not a field in %s", ra
                  break
               end
            end
            if not errm then
               return self:match_all_record_field_names(bnode, ra, field_names,
                         "cannot index, not all enum values map to record fields of the same type")
            end
         elseif rb is StringType then
            errm, erra = "cannot index object of type %s with a string, consider using an enum", a
         else
            errm, erra, errb = "cannot index object of type %s with %s", a, b
            errdetails = Errors.about(Errors.make({ code = "cannot_index_object" }), a)
         end
      else
         errm, erra, errb = "cannot index object of type %s with %s", a, b
         errdetails = Errors.about(Errors.make({ code = "cannot_index_object" }), a)
      end

      local meta_t = self:check_metamethod(anode, "__index", ra, b, a, b)
      if meta_t then
         return meta_t
      end

      return self.errs:invalid_key_at(bnode, errdetails, errm, erra, errb)
   end

   function TypeChecker:expand_type(w: Where, old: Type, new: Type): Type
      if not old or old is NilType then
         return new
      end
      if self:is_a(new, old) then
         return old
      end

      if new is RecordLikeType and (old is MapType or old is RecordLikeType) then
         local keys: Type = nil
         local values: Type = nil
         if old is MapType then
            keys = old.keys
            if not keys is StringType then
               self.errs:add(w, "cannot determine table literal type")
               return old
            end
            values = old.values
         elseif old is RecordLikeType then
            keys = a_type(w, "string", {})
            for _, ftype in fields_of(old) do
               values = self:expand_type(w, values, ftype)
            end
         end

         for _, ftype in fields_of(new) do
            values = self:expand_type(w, values, ftype)
         end

         return a_map(w, keys, values)
      end

      return unite(w, { old, new }, true)
   end

   function TypeChecker:find_record_to_extend(exp: Node): Type, Variable, string
      -- base
      if exp.kind == "type_identifier" then
         local v = self:find_var(exp.tk)
         if not v then
            return nil, nil, exp.tk
         end

         local t = v.t
         if t is TypeDeclType then
            if t.closed then
               return nil, nil, exp.tk
            end

            return t.def, v, exp.tk
         end

         return t, v, exp.tk
      -- recurse
      elseif exp.kind == "op" then -- assert(exp.op.op == ".")
         local t, v, rname = self:find_record_to_extend(exp.e1)
         local fname = exp.e2.tk
         local dname = rname .. "." .. fname
         if not t then
            return nil, nil, dname
         end
         if not t is RecordLikeType then
            return nil, nil, dname
         end
         t = t.fields[fname]

         if t is TypeDeclType then
            local def = t.def
            if def is NominalType then
               assert(t.is_alias)
               t = def.resolved
            else
               t = def
            end
         end

         return t, v, dname
      end
   end

   local function typedecl_to_nominal(w: Where, name: string, t: TypeDeclType, resolved?: Type): Type
      local typevals: {TypeVarType} = nil
      local def = t.def
      if def is GenericType then
         typevals = {}
         for _, a in ipairs(def.typeargs) do
            table.insert(typevals, a_type(a, "typevar", {
               typevar = a.typearg,
               constraint = a.constraint,
            } as TypeVarType))
         end
      end
      local nom = a_nominal(w, { name })
      nom.typevals = typevals
      nom.found = t
      nom.resolved = resolved
      return nom
   end

   function TypeChecker:get_self_type(exp: Node): Type
      -- base
      if exp.kind == "type_identifier" then
         local t = self:find_var_type(exp.tk)
         if not t then
            return nil
         end

         if t is TypeDeclType then
            return typedecl_to_nominal(exp, exp.tk, t)
         else
            return t
         end
      -- recurse
      elseif exp.kind == "op" then -- assert(exp.op.op == ".")
         local t = self:get_self_type(exp.e1)
         if not t then
            return nil
         end

         if t is NominalType then
            local found = t.found
            if found then
               if found is TypeDeclType then
                  local def = found.def
                  if def is RecordLikeType and def.fields[exp.e2.tk] then
                     table.insert(t.names, exp.e2.tk)
                     local ft = def.fields[exp.e2.tk]
                     if ft is TypeDeclType then
                        t.found = ft
                     else
                        return nil
                     end
                  end
               end
            end
         elseif t is RecordLikeType then
            return t.fields and t.fields[exp.e2.tk]
         end
         return t
      end
   end

   -- The checker's side of evaluating a guard (checker/narrowing.tl): what
   -- only it knows of types.
   do
      -- t1 ∪ t2
      local function unite_types(w: Where, t1: Type, t2: Type): Type, string
         return unite(w, {t2, t1})
      end

      -- t1 ∩ t2
      local function intersect_types(self: TypeChecker, w: Where, t1: Type, t2: Type): Type, string
         if t2 is UnionType then
            t1, t2 = t2, t1
         end
         if t1 is UnionType then
            local out = {}
            for _, t in ipairs(t1.types) do
               if self:is_a(t, t2) and (not t is NilType or admits_nil(self, w, t2)) then
                  table.insert(out, t)
               end
            end
            if #out > 0 then
               return unite(w, out)
            end
         end
         if self:is_a(t1, t2) then
            return t1
         elseif self:is_a(t2, t1) then
            return t2
         else
            return a_type(w, "nil", {}) -- because of implicit nil in all unions
         end
      end

      function TypeChecker:resolve_if_union(t: Type): Type
         local rt = self:to_structural(t)
         if rt is UnionType then
            return rt
         end
         return t
      end

      -- t1 - t2
      local function subtract_types(self: TypeChecker, w: Where, t1: Type, t2: Type): Type
         local types: {Type} = {}

         t1 = self:resolve_if_union(t1)

         -- poly are not first-class, so we don't handle them here
         if not t1 is UnionType then
            return t1
         end

         t2 = self:resolve_if_union(t2)
         local t2types = t2 is UnionType and t2.types or { t2 }

         for _, at in ipairs(t1.types) do
            local not_present = true
            for _, bt in ipairs(t2types) do
               if self:same_type(at, bt) then
                  not_present = false
                  break
               end
            end
            if not_present then
               table.insert(types, at)
            end
         end

         if #types == 0 then
            return a_type(w, "nil", {}) -- because of implicit nil in all unions
         end

         return unite(w, types)
      end

      local function narrowing_host(self: TypeChecker): narrowing.Host
         local host = self.narrowing_host
         if host then
            return host
         end
         host = {
            type_of = function(place: narrowing.Place, w: narrowing.Where): narrowing.Type
               return self:place_type(place, w) as narrowing.Type
            end,
            is_a = function(t1: narrowing.Type, t2: narrowing.Type): boolean
               return (self:is_a(t1 as Type, t2 as Type))
            end,
            unite = function(w: narrowing.Where, t1: narrowing.Type, t2: narrowing.Type): narrowing.Type
               return unite_types(w, t1 as Type, t2 as Type) as narrowing.Type
            end,
            intersect = function(w: narrowing.Where, t1: narrowing.Type, t2: narrowing.Type): narrowing.Type
               return intersect_types(self, w, t1 as Type, t2 as Type) as narrowing.Type
            end,
            subtract = function(w: narrowing.Where, t1: narrowing.Type, t2: narrowing.Type): narrowing.Type
               return subtract_types(self, w, t1 as Type, t2 as Type) as narrowing.Type
            end,
            invalid = function(w: narrowing.Where): narrowing.Type
               return an_invalid(w) as narrowing.Type
            end,
            show = function(t: narrowing.Type): string
               return show_type(t as Type)
            end,
            warn_never = function(w: narrowing.Where, who: string, have: narrowing.Type, wanted: narrowing.Type)
               self.errs:add_warning("branch", w, who .. " (of type %s) can never be a %s", show_type(have as Type), show_type(wanted as Type))
            end,
            refuse_never = function(w: narrowing.Where, who: string, have: narrowing.Type, wanted: narrowing.Type)
               self.errs:add(w, who .. " (of type %s) can never be a %s", have as Type, wanted as Type)
            end,
         }
         self.narrowing_host = host
         return host
      end

      -- Narrows the places `guard` is about, in the scope that is open.
      function TypeChecker:apply_guard(w: Where, guard: narrowing.Guard)
         if not guard then
            return
         end

         local facts = narrowing.evaluate(narrowing_host(self), guard)

         for v, f in pairs(facts) do
            local typ = f.typ as Type
            if typ.typename == "invalid" then
               self.errs:add(w, "cannot resolve a type for " .. v .. " here")
            end
            local t = f.no_infer and typ or self:infer_at(w, typ)
            if f.no_infer then
               t.inferred_at = nil
            end
            self:add_var(nil, v, t, "const", "narrow")
            narrowing.renarrowed(self.st as {narrowing.Scope}, v)
         end
      end

      -- The name a call's callee or a write's target is written with
      -- (`clear`, `r.items.add`, `obj:get`), nil for any other expression.
      function TypeChecker:written_name(n: Node): string
         if n.kind == "variable" then
            return n.tk
         elseif n.kind == "op" and (n.op.op == "." or n.op.op == ":") and n.e2 and n.e2.tk then
            local base = self:written_name(n.e1)
            return base and base .. n.op.op .. n.e2.tk
         end
         return nil
      end

      -- Where an expression begins: the callee's name for a call, the base
      -- for a field.
      local function start_of(n: Node): Where
         while n.kind == "op" and n.e1 and n.op.arity == 2 do
            n = n.e1
         end
         return n
      end

      -- A call-like expression has run, at `w`: a call, an operator that
      -- dispatches to a metamethod, a loop whose body does either. What
      -- is known of every field path is dropped (the code may write any
      -- field of any table), and what is known of every narrowed local that
      -- a function literal assigns. `kind` and `text` say what ran, for the
      -- refusal of a use that relied on what was dropped.
      function TypeChecker:drop_all(w: Where, kind: string, text?: string)
         self.drop_clock = self.drop_clock + 1
         -- Marked for `flow.unassigned_read`, which asks of the same
         -- expressions whether a function made before them may be called.
         local at = w as Node
         at.runs_code = true
         self.last_drop, self.last_drop_node, self.last_drop_kind, self.last_drop_text = nil, w, kind, text
         local scopes = self.st as {narrowing.Scope}
         local paths, names = narrowing.narrowed(scopes)
         if not paths and not names then
            return
         end
         local why = self:last_dropper()
         if paths then
            narrowing.drop_paths(scopes, why)
         end
         for _, name in ipairs(names or {}) do
            if not self:local_is_stable(name) then
               narrowing.note(scopes, name, why)
               self:widen_back_var(name)
            end
         end
      end

      -- What dropped last, built only when something wants to say so: most
      -- calls drop nothing.
      function TypeChecker:last_dropper(): narrowing.Drop
         local why = self.last_drop
         if not why and self.last_drop_node then
            local at = start_of(self.last_drop_node as Node)
            local text = self.last_drop_text or self:call_text(self.last_drop_node as Node)
            why = narrowing.because(self.last_drop_kind, text, at.y, at.x)
            self.last_drop = why
         end
         return why
      end

      -- Whether an operation on a value of type `t` may dispatch to a
      -- metamethod, `metamethod` if one is named: `t` is a record, an
      -- interface or a userdata that declares it (any, if none is named),
      -- or `any`, a type variable, or a union with one of these. A value
      -- dispatches only through metamethods its type declares, so a string,
      -- a number, a plain array or map, a function, nil and a record that
      -- declares none never do.
      --
      -- TODO: a metatable attached at run time dispatches whatever its
      -- type declares, so a plain map built by `setmetatable({}, {__index =
      -- f})`, or a record given a metamethod it does not declare, runs code
      -- here unseen. It waits on doc/roadmap.md's item that lets
      -- `setmetatable` attach metamethods only to a record type that
      -- declares them. A `__gc` finalizer, which runs when the collector
      -- chooses, is outside the claim (doc/design.md) and no item closes it.
      function TypeChecker:may_dispatch(t: Type, metamethod?: string): boolean
         local rt = self:to_structural(t)
         if rt is UnionType then
            for _, member in ipairs(rt.types) do
               if self:may_dispatch(member, metamethod) then
                  return true
               end
            end
            return false
         end
         if rt is RecordLikeType then
            local declared = rt.meta_fields
            if not declared then
               return false
            end
            if metamethod then
               return declared[metamethod] ~= nil
            end
            return next(declared) ~= nil
         end
         return rt.typename == "any"
            or rt.typename == "typevar"
            or rt.typename == "typearg"
            or rt.typename == "unknown"
      end

      -- Whether a value of type `t` may be a table (or userdata), the only
      -- operands `==` consults `__eq` for.
      function TypeChecker:may_be_table(t: Type): boolean
         local rt = self:to_structural(t)
         if rt is UnionType then
            for _, member in ipairs(rt.types) do
               if self:may_be_table(member) then
                  return true
               end
            end
            return false
         end
         return rt is RecordLikeType or is_lua_table_type(rt) or self:may_dispatch(rt)
      end

      -- Records on the node `n`, a read of the place `key`, what dropped
      -- the narrowing it would have had, for a refusal to tell.
      function TypeChecker:note_dropped(n: Node, key: string)
         local why = narrowing.dropped_by(self.st as {narrowing.Scope}, key)
         if why then
            n.dropped = { kind = why.kind, text = why.text, y = why.y, x = why.x, place = key }
         end
      end

      -- Whether code that runs may change what a guard says of `place`: a
      -- field path, or a local that a function literal assigns.
      function TypeChecker:droppable(place: narrowing.Place): boolean
         return #place.fields > 0 or not self:local_is_stable(place.base)
      end

      -- The guard of `left`, an operand evaluated before `right`: what it
      -- established holds past `right` only if `right` ran nothing that
      -- may change the places it is about.
      function TypeChecker:guard_before(left: Node, right: Node): narrowing.Guard
         if left.drop_clock ~= nil and right.drop_clock == left.drop_clock then
            return left.guard
         end
         return self:prune(left.guard)
      end

      -- `guard` without what code that has run since may have changed,
      -- remembering in the scope that would have held it what did.
      function TypeChecker:prune(guard: narrowing.Guard): narrowing.Guard
         local scopes = self.st as {narrowing.Scope}
         local why: narrowing.Drop = nil
         for _, place in ipairs(narrowing.places(guard)) do
            if self:droppable(place) then
               why = why or self:last_dropper()
               if why then
                  narrowing.cut(scopes, place.key, why)
               end
            end
         end
         return narrowing.forget(guard, function(place: narrowing.Place): boolean
            return self:droppable(place)
         end)
      end

      -- A function literal's body begins: it runs later, so it begins with
      -- none of what is known of the places outside it that may change
      -- before then (`narrowing.enter_function`): every field path, and each
      -- local that an assignment can change after the literal is made.
      function TypeChecker:enter_function_body(node: Node)
         narrowing.enter_function(self.st as {narrowing.Scope},
            narrowing.because("function", "function", node.y, node.x),
            function(name: string): boolean
               return self:local_is_fixed(name, node)
            end)
      end

      -- Records in `label_back`, for each label of the block `block` and of
      -- the blocks inside it, whether a `goto` below it names it. `visible`
      -- holds the labels of the blocks around, by name.
      function TypeChecker:scan_labels(block: Node, visible: {string:Node})
         local mine: {string:Node} = {}
         for name, label in pairs(visible) do
            mine[name] = label
         end
         for _, stmt in ipairs(block) do
            if stmt.kind == "label" then
               mine[stmt.label] = stmt
               if self.label_back[stmt] == nil then
                  self.label_back[stmt] = false
               end
            elseif stmt.kind == "goto" then
               local label = mine[stmt.label]
               if label then
                  self.label_back[label] = true
               end
            elseif stmt.if_blocks then
               for _, b in ipairs(stmt.if_blocks) do
                  self:scan_labels(b.body, mine)
               end
            elseif stmt.body then
               self:scan_labels(stmt.body, mine)
            end
         end
      end

      -- Whether control may come back to `label` from below it. A label the
      -- scan did not reach (one in a function literal inside an expression)
      -- is taken to be.
      function TypeChecker:label_is_looped(label: Node): boolean
         if not self.label_back then
            self.label_back = {}
            self:scan_labels(self.root_ast, {})
         end
         return self.label_back[label] ~= false
      end

      -- A loop begins: its body is checked once with the facts of the scopes
      -- outside it, and what it reads of them is held until `loop_end`.
      function TypeChecker:loop_begin()
         table.insert(self.loops, { depth = #self.st, reads = {}, dropped = {} })
      end

      -- A read of `key` where a fact narrowed outside a loop stood: it is
      -- held for each loop it is outside of, if the fact told more than the
      -- declared type did (`declared`, where the place has no declaration to
      -- look for).
      function TypeChecker:record_read(node: Node, key: string, declared?: Type)
         local st = self.st
         for i = #st, 1, -1 do
            local var = st[i].vars[key]
            if var then
               if var.is_specialized == "narrow" or var.is_specialized == "narrowed_declaration"
                  or var.widened_from then
                  local was = declared or var.specialized_from or var.widened_from
                  if not was then
                     local real = get_real_var_from_lower_scope(st, i, key)
                     was = real and real.t
                  end
                  if was and not self:same_type(var.t, was) then
                     self.loop_tick = self.loop_tick + 1
                     for _, loop in ipairs(self.loops) do
                        if i <= loop.depth then
                           table.insert(loop.reads, { node = node as narrowing.Node, key = key, clock = self.loop_tick })
                        end
                     end
                  end
               end
               return
            end
         end
      end

      -- A fact held in the scope `index` was dropped: a loop outside which
      -- it was held will read it dropped in its next pass.
      function TypeChecker:loop_dropped(index: integer, key: string, why: narrowing.Drop)
         self.loop_tick = self.loop_tick + 1
         for _, loop in ipairs(self.loops) do
            if index <= loop.depth then
               local events = loop.dropped[key]
               if not events then
                  events = {}
                  loop.dropped[key] = events
               end
               table.insert(events, { clock = self.loop_tick, why = why })
            end
         end
      end

      -- What the loops saw before `tick` need not be told: control left them.
      function TypeChecker:loops_forget_since(tick: integer)
         for _, loop in ipairs(self.loops) do
            for i = #loop.reads, 1, -1 do
               if loop.reads[i].clock > tick then
                  table.remove(loop.reads, i)
               end
            end
            for _, events in pairs(loop.dropped) do
               for i = #events, 1, -1 do
                  if events[i].clock > tick then
                     table.remove(events, i)
                  end
               end
            end
         end
      end

      -- A loop ends, its body (and condition) checked: each read of a fact
      -- from outside it that came before a drop of that fact is of what the
      -- previous pass left, and is refused.
      function TypeChecker:loop_end()
         local loop = table.remove(self.loops)
         for _, read in ipairs(loop.reads) do
            local events = loop.dropped[read.key]
            for _, event in ipairs(events or {}) do
               if event.clock > read.clock then
                  local why = event.why
                  local details = Errors.make({
                     code = "narrowing_dropped", dropped_place = read.key, dropped_kind = "loop",
                     dropped_by = why.text, dropped_y = why.y, dropped_x = why.x,
                  })
                  self.errs:add_coded(read.node as Node, details,
                     ("'%s' was narrowed before this loop, but the loop's previous pass ran %s at %d:%d, " ..
                      "which may have changed it"):format(read.key, why.text:gsub("%%", "%%%%"), why.y, why.x))
                  break
               end
            end
         end
      end

      -- Whether the iterator of a `for ... in` runs none of the program's
      -- code: `pairs`, `ipairs` or `gmatch` of what runs none, or `next`.
      function TypeChecker:pure_iterator(node: Node): boolean
         local exps = node.exps
         local first = exps[1]
         if #exps == 1 and first.kind == "op" and first.op.op == "@funcall" then
            if not first.runs_no_code then
               return false
            end
            local callee = first.e1
            local name = callee.kind == "variable" and callee.tk
               or (callee.kind == "op" and (callee.op.op == "." or callee.op.op == ":") and callee.e2 and callee.e2.tk)
            return name == "pairs" or name == "ipairs" or name == "gmatch"
         end
         if first.kind == "variable" and first.tk == "next" then
            local _, scope = self:find_var("next", "check_only")
            return scope == 1
         end
         return false
      end

      -- Whether the call `node` of `callee`, given `args`, runs no code of
      -- the program's: the callee is a function of the standard library
      -- that examines no argument it could be a metamethod's business to
      -- examine. An argument that may dispatch (a record, `any`, a type
      -- variable) or is a function the callee could call decides against.
      --
      -- TODO: a table given to one may carry a metatable attached at run
      -- time that `may_dispatch` does not see (see its TODO). It waits on
      -- the same roadmap item.
      function TypeChecker:runs_no_code(node: Node, callee: Type, args: TupleType): boolean
         if callee is FunctionType and not callee.pure_std then
            return false
         end
         local members: {Type} = { callee }
         if callee is PolyType then
            members = callee.types
         end
         local examines = "none"
         for _, member in ipairs(members) do
            local f = member
            if f is GenericType then
               f = f.t
            end
            if not (f is FunctionType) or not f.pure_std then
               return false
            end
            if f.pure_std == "all" or (f.pure_std == "first" and examines == "none") then
               examines = f.pure_std
            end
         end
         local given: {Type} = {}
         if node.e1.op and node.e1.op.op == ":" and node.e1.receiver then
            given[1] = node.e1.receiver
         end
         for _, t in ipairs(args.tuple) do
            table.insert(given, t)
         end
         -- A function the callee could call, alone or among a union's members.
         local function callable(rt: Type): boolean
            if rt is UnionType then
               for _, member in ipairs(rt.types) do
                  if callable(self:to_structural(member)) then
                     return true
                  end
               end
               return false
            end
            return rt is FunctionType
         end
         for i, t in ipairs(given) do
            if examines == "all" or (examines == "first" and i == 1) then
               local rt = self:to_structural(resolve_tuple(t))
               if callable(rt) or self:may_dispatch(rt) then
                  return false
               end
            end
         end
         return true
      end

      -- Whether the expression of a macro expression holds a call.
      function TypeChecker:macroexp_calls(n: Node): boolean
         if n.kind == "op" and n.op.op == "@funcall" then
            return true
         end
         for key, child in pairs(n as {any:any}) do
            if key ~= "if_parent" and key ~= "fn_owner" and type(child) == "table" then
               local node = child as Node
               if node.kind and self:macroexp_calls(node) then
                  return true
               end
            end
         end
         return false
      end

      -- The call `node`, as a message shows it: `clear(...)`.
      function TypeChecker:call_text(node: Node): string
         local name = self:written_name(node.e1)
         return (name or "a function") .. "(...)"
      end

      -- A write to `target` has run: a field of that name through any
      -- reference may be one that a narrowed path names, and a write
      -- through a key that may name a field may write any.
      function TypeChecker:drop_through(target: Node)
         if target.kind ~= "op" then
            return
         end
         local scopes = self.st as {narrowing.Scope}
         if not narrowing.has_paths(scopes) then
            return
         end
         local name = self:written_name(target)
         local text = (name or (target.op.op == "." and "(...)." .. target.e2.tk or "(...)[...]")) .. " = ..."
         local at = start_of(target)
         local why = narrowing.because("write", text, at.y, at.x)
         self.last_drop, self.last_drop_node = why, nil
         if target.op.op == "." and target.e2 and target.e2.tk then
            narrowing.drop_written(scopes, target.e2.tk, why)
         elseif target.op.op == "@index" and target.e2 then
            local key = target.e2
            if key.kind == "string" and key.conststr then
               narrowing.drop_written(scopes, key.conststr, why)
            elseif target.key_kind ~= "integer" and target.key_kind ~= "number" then
               -- TODO: a write to an index (`t[k] = v`) drops every index
               -- place, and there are none; a key that is not a number may
               -- be a field name, so it drops every field path. It waits on
               -- doc/roadmap.md's item that makes an index a place and on
               -- the rule that a record is not a map: a `{string:any}` that
               -- holds a record is written through here.
               narrowing.drop_paths(scopes, why)
            end
         end
      end
   end

   function TypeChecker:dismiss_unresolved(name: string)
      for i = #self.st, 1, -1 do
         local scope = self.st[i]
         local uses = scope.pending_nominals and scope.pending_nominals[name]
         if uses then
            for _, t in ipairs(uses) do
               self:resolve_nominal(t)
            end
            scope.pending_nominals[name] = nil
            return
         end
      end
   end

   local function special_pcall_xpcall(self: TypeChecker, node: Node, a: FunctionType, b: TupleType, argdelta?: integer): Type
      local isx = a.special_function_handler == "xpcall"
      local base_nargs = isx and 2 or 1
      local bool = a_type(node, "boolean", {})
      if #node.e2 < base_nargs then
         self.errs:arity(node, #node.e2, "at least " .. base_nargs, nil, base_nargs)
         return a_tuple(node, { bool })
      end

      local ftype = table.remove(b.tuple, 1)

      -- The function called by pcall/xpcall is invoked as a regular function,
      -- so we wish to avoid incorrect error messages / unnecessary warning messages
      -- associated with calling methods as functions
      ftype = ensure_not_method(ftype)

      local fe2: Node = node_at(node.e2, {})
      if isx then
         base_nargs = 2
         local arg2 = node.e2[2]
         local msgh = table.remove(b.tuple, 1)
         local msgh_type = a_function(arg2, {
            min_arity = self.feat_arity and 1 or 0,
            args = a_tuple(arg2, { a_type(arg2, "any", {}) }),
            rets = a_vararg(arg2, { a_type(arg2, "any", {}) })
         })
         self:assert_is_a(arg2, msgh, msgh_type, "in message handler")
      end
      for i = base_nargs + 1, #node.e2 do
         table.insert(fe2, node.e2[i])
      end
      local fnode: Node = node_at(node, {
         kind = "op",
         op = { op = "@funcall" },
         e1 = node.e2[1],
         e2 = fe2,
      })
      local rets = self:type_check_funcall(fnode, ftype, b, argdelta + base_nargs)
      if rets is InvalidType then
         return rets
      end
      table.insert(rets.tuple, 1, bool)
      return rets
   end

   local function pattern_findclassend(pat: string, i: integer, strict: boolean): integer, boolean, string
      local c = pat:sub(i, i)
      if c == "%" then
         local peek = pat:sub(i + 1, i + 1)
         if peek == "f" then
            -- frontier
            if pat:sub(i + 2, i + 2) ~= "[" then
               return nil, nil, "malformed pattern: missing '[' after %f"
            end
            local e, _, err = pattern_findclassend(pat, i + 2, strict)
            if not e then
               return nil, nil, err
            else
               return e, false
            end
         elseif peek == "b" then
            if pat:sub(i + 3, i + 3) == "" then
               return nil, nil, "malformed pattern: need balanced characters"
            end
            return i + 3, false
         elseif peek == "" then
            return nil, nil, "malformed pattern: expected class"
         elseif peek:match"[1-9]" then
            return i + 1, false
         elseif strict and not peek:match"[][^$()%%.*+%-?AaCcDdGgLlPpSsUuWwXxZz]" then
            return nil, nil, "malformed pattern: invalid class '" .. peek .. "'"
         else
            return i + 1, true
         end
      elseif c == "[" then
         if pat:sub(i + 1, i + 1) == "^" then
            i = i + 2 -- skip the inverter
         else
            i = i + 1
         end

         local isfirst = true
         repeat
            local c_ = pat:sub(i, i)
            if c_ == "" then
               return nil, nil, "malformed pattern: missing ']'"
            elseif c_ == "%" then
               if strict and not pat:sub(i + 1, i + 1):match"[][^$()%%.*+%-?AaCcDdGgLlPpSsUuWwXxZz]" then
                  return nil, nil, "malformed pattern: invalid escape"
               end
               i = i + 2
            elseif c_ == "-" and strict and not isfirst then
               return nil, nil, "malformed pattern: unexpected '-'"
            else
               local c2 = pat:sub(i + 1, i + 1)
               local c3 = pat:sub(i + 2, i + 2)
               if c2 == "-" then
                  if strict and c3 == "]" then
                     return nil, nil, "malformed pattern: unexpected ']'"
                  elseif strict and c3 == "-" then
                     return nil, nil, "malformed pattern: unexpected '-'"
                  elseif strict and c3 == "%" then
                     return nil, nil, "malformed pattern: unexpected '%'"
                  end
                  -- don't skip the last one if it is a % or ]
                  i = i + 2
               else
                  i = i + 1
               end
            end
            isfirst = false
         until pat:sub(i, i) == "]"

         return i, true
      else
         return i, true
      end
   end

   local pattern_isop: {string:boolean} = {
      ["?"] = true,
      ["+"] = true,
      ["-"] = true,
      ["*"] = true,
   }

   local function parse_pattern_string(node: Node, pat: string, inclempty: boolean): {Type}, string
      --[[
         Pattern syntax:

         pat <- start? mid* end?
         start <- "^"
         end <- "$"
         mid <- "(" mid* ")"
              | "[" "^"? set "]" rpt?
              | "%" "b" . .
              | "%" "f" "[" "^"? set "]"
              | "%" [1-9]
              | "%" [][^$()%.*+-?AaCcDdGgLlPpSsUuWwXxZz] rpt?
              | [^][^$()%*+-?] rpt?
         set <- setitem1? setitem*
         setitem1 <- "]"
                   | "]" "-" [^]%]
         setitem <- "%" [][^$()%.*+-?AaCcDdGgLlPpSsUuWwXxZz]
                  | [^]%] "-" [^]%]
                  | [^]%-]
         rpt <- [-*+?]
      --]]
      local strict = false

      local results: {Type} = {}

      local i = pat:sub(1, 1) == "^" and 2 or 1
      local unclosed = 0

      while i <= #pat do
         local c = pat:sub(i, i)

         if i == #pat and c == "$" then
            break
         end

         local classend, canhavemul, err = pattern_findclassend(pat, i, strict)
         if not classend then
            return nil, err
         end

         local peek = pat:sub(classend + 1, classend + 1)

         if c == "(" and peek == ")" then
            -- position match
            table.insert(results, a_type(node, "integer", {}))
            i = i + 2
         elseif c == "(" then
            table.insert(results, a_type(node, "string", {}))
            unclosed = unclosed + 1
            i = i + 1
         elseif c == ")" then
            unclosed = unclosed - 1
            if unclosed < 0 then
               return nil, "malformed pattern: unexpected ')'"
            end
            i = i + 1
         elseif strict and c:match"[]^$()*+%-?]" then -- operations that haven't been handled
            return nil, "malformed pattern: character was unexpected: '" .. c .. "'"
         elseif pattern_isop[peek] and canhavemul then
            i = classend + 2
         else
            -- simple match
            i = classend + 1
         end
      end

      if inclempty and not results[1] then
         results[1] = a_type(node, "string", {})
      end
      if unclosed ~= 0 then
         return nil, "malformed pattern: " .. unclosed .. " capture" .. (unclosed == 1 and "" or "s") .. " not closed"
      end
      return results
   end

   local function parse_format_string(node: Node, pat: string): {Type}, string
      local pos = 1
      local results: {Type} = {}
      while pos <= #pat do
         local endc = pat:match("%%[-+#0-9. ]*()", pos)
         if not endc then return results end
         local c = pat:sub(endc, endc)
         if c == "" then
            return nil, "missing pattern specifier at end"
         end
         if c:match"[AaEefGg]" then
            table.insert(results, a_type(node, "number", {}))
         elseif c:match"[cdiouXx]" then
            table.insert(results, a_type(node, "integer", {}))
         elseif c == "q" then
            table.insert(results,
               a_union(node, {
                  a_type(node, "string", {}),
                  a_type(node, "number", {}),
                  a_type(node, "integer", {}),
                  a_type(node, "boolean", {}),
                  a_type(node, "nil", {}),
               })
            )
         elseif c == "p" or c == "s" then
            table.insert(results, a_type(node, "any", {}))
         elseif c == "%" then
            -- escaped percent sign
         else
            return nil, "invalid pattern specifier: '" .. c .. "'"
         end
         pos = endc + 1
      end
      return results
   end

   local function pack_string_skipnum(pos: integer, pat: string): integer
      return pat:match("[0-9]*()", pos)
   end

   local function parse_pack_string(node: Node, pat: string): {Type}, string
      local pos = 1
      local results: {Type} = {}
      local skip_next = false
      while pos <= #pat do
         local c = pat:sub(pos, pos)
         local to_add: Type = nil
         local goto_next: boolean = nil
         if c:match"[<> =x]" then
            -- nothing to do with argument
            if skip_next then
               return nil, "expected argument for 'X'"
            end
            pos = pos + 1
            goto_next = true
         elseif c == "X" then
            if skip_next then
               return nil, "expected argument for 'X'"
            end
            skip_next = true
            pos = pos + 1
            goto_next = true
         elseif c == "!" then
            if skip_next then
               return nil, "expected argument for 'X'"
            end
            pos = pack_string_skipnum(pos + 1, pat)
            goto_next = true
         elseif c:match"[Ii]" then
            pos = pack_string_skipnum(pos + 1, pat)
            to_add = a_type(node, "integer", {})
         elseif c:match"[bBhHlLjJT]" then
            pos = pos + 1
            to_add = a_type(node, "integer", {})
         elseif c:match"[fdn]" then
            pos = pos + 1
            to_add = a_type(node, "number", {})
         elseif c == "z" or c == "s" or c == "c" then
            if c == "z" then
               pos = pos + 1
            else
               pos = pack_string_skipnum(pos + 1, pat)
            end
            -- string.pack accepts numbers here, but unpacks them as strings so we just skip it
            to_add = a_type(node, "string", {})
         else
            return nil, "invalid format option: '" .. c .. "'"
         end
         if not goto_next then
            if skip_next then
               skip_next = false
            else
               table.insert(results, to_add)
            end
         end
      end
      if skip_next then
         return nil, "expected argument for 'X'"
      end
      return results
   end

   -- type_for_union's answer for a member, as type() names its values.
   local lua_type_names: {string:string} = {
      ["string"] = "string",
      ["enum"] = "string",
      ["number"] = "number",
      ["integer"] = "number",
      ["boolean"] = "boolean",
      ["nil"] = "nil",
      ["table"] = "table",
      ["userdata"] = "userdata",
      ["function"] = "function",
      ["poly"] = "function",
      ["thread"] = "thread",
   }

   -- What `type(x) == name` makes x of type t: of a union, the
   -- members whose values type() answers name for, which is what `is`
   -- gives for them; of `any`, the one type the name spells, for the
   -- names that spell exactly one ("table" and "function" spell none).
   -- nil narrows nothing: a member whose Lua type is not known
   -- (an interface, which a userdata record may implement, a type
   -- variable) would make the negation claim what the test never
   -- checked; and where no member answers to name, or t is no union,
   -- the test is left a plain runtime check rather than refused as
   -- `is` would be, since type() is how Lua code checks a value whose
   -- declared type it does not trust (decoded data, a caller's
   -- argument).
   local function type_test_type(self: TypeChecker, w: Where, t: Type, name: string): Type
      local rt = self:to_structural(t)
      if rt.typename == "any" then
         if name == "string" or name == "number" or name == "boolean" or name == "nil" then
            return a_type(w, name as TypeName, {})
         end
         return nil
      end
      if not rt is UnionType then
         return nil
      end
      local members: {Type} = {}
      for _, m in ipairs(rt.types) do
         local rm = self:to_structural(m)
         if rm is InterfaceType or rm is TypeDeclType then
            return nil
         end
         local lua_name = lua_type_names[type_for_union(rm)]
         if not lua_name then
            return nil
         end
         if lua_name == name then
            table.insert(members, m)
         end
      end
      if #members == 0 then
         return nil
      end
      return #members == 1 and members[1] or unite(w, members)
   end

   local special_functions <total>: {SpecialFunctionName : function(TypeChecker, Node, Type, TupleType, ? integer):InvalidOrTupleType } = {
      ["pairs"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         if not b.tuple[1] then
            return self.errs:invalid_at(node, "pairs requires an argument")
         end
         local t = self:to_structural(b.tuple[1])
         if t is ArrayLikeType then
            self.errs:add_warning("hint", node, "hint: applying pairs on an array: did you intend to apply ipairs?")
         end

         if not t is MapType then
            if not (self.feat_lax and is_unknown(t)) then
               if t is RecordLikeType then
                  self:match_all_record_field_names(node.e2, t, t.field_order,
                     "attempting pairs on a record with attributes of different types")
                  local ct = t is RecordType and "{string:any}" or "{any:any}"
                  self.errs:add_warning("hint", node.e2, "hint: if you want to iterate over fields of a record, cast it to " .. ct)
               else
                  self.errs:add_coded(node.e2, Errors.about(Errors.make({ code = "pairs_of_non_table" }), t), "cannot apply pairs on values of type: %s", t)
               end
            end
         end

         return (self:type_check_function_call(node, a, b, argdelta))
      end,

      ["ipairs"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         if not b.tuple[1] then
            return self.errs:invalid_at(node, "ipairs requires an argument")
         end
         local orig_t = b.tuple[1]
         local t = self:to_structural(orig_t)

         if t is TupleTableType then
            local arr_type = self:arraytype_from_tuple(node.e2, t)
            if not arr_type then
               return self.errs:invalid_at(node.e2, "attempting ipairs on tuple that's not a valid array: %s", orig_t)
            end
         elseif not t is ArrayLikeType then
            if not (self.feat_lax and (is_unknown(t) or t is EmptyTableType)) then
               return self.errs:invalid_coded(node.e2, Errors.about(Errors.make({ code = "not_array" }), orig_t), "attempting ipairs on something that's not an array: %s", orig_t)
            end
         end

         return (self:type_check_function_call(node, a, b, argdelta))
      end,

      ["rawget"] = function(self: TypeChecker, node: Node, _a: Type, b: TupleType, _argdelta?: integer): InvalidOrTupleType
         -- TODO should those offsets be fixed by _argdelta?
         if #b.tuple == 2 then
            return a_tuple(node, { self:type_check_index(node.e2[1], node.e2[2], b.tuple[1], b.tuple[2]) })
         else
            return self.errs:invalid_at(node, "rawget expects two arguments")
         end
      end,

      ["require"] = function(self: TypeChecker, node: Node, _a: Type, b: TupleType, _argdelta?: integer): InvalidOrTupleType
         if #b.tuple ~= 1 then
            return self.errs:invalid_at(node, "require expects one literal argument")
         end
         local named = b.tuple[1]
         if named and (named.typename == "nil" or without_nil(self, node, named, false) ~= nil) then
            return self.errs:invalid_coded(node.e2[1], Errors.make({ code = "require_argument", got = show_type(named), got_members = Errors.members(named) }), "require: argument 1: got %s, expected string", named)
         end
         if node.e2[1].kind ~= "string" then
            return a_tuple(node, { a_type(node, "any", {}) })
         end

         local module_name = assert(node.e2[1].conststr)
         local tc_opts: CheckOptions = {
            feat_lax = self.feat_lax and "on" or "off",
            feat_arity = self.feat_arity and "on" or "off",
         }
         local t, module_filename = require_module(node, module_name, tc_opts, self.env)

         if t is InvalidType then
            if not module_filename then
               return self.errs:invalid_coded(node, Errors.make({ code = "module_not_found", key = module_name }), "module not found: '" .. module_name .. "'")
            end

            if self.feat_lax then
               return a_tuple(node, { an_unknown(node) })
            end
            return self.errs:invalid_at(node, "no type information for required module: '" .. module_name .. "'")
         end

         self.dependencies[module_name] = module_filename
         return a_tuple(node, { t })
      end,

      ["coroutine.wrap"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         local r = self:type_check_function_call(node, a, b, argdelta)
         local f = b.tuple[1] and self:to_structural(b.tuple[1])
         if r is InvalidType or not f then
            return r
         end
         local generic: GenericType = nil
         if f is GenericType then
            generic = f
            f = f.t
         end
         if not (f is FunctionType) then
            return r
         end
         local wrapper: Type = a_function(node, {
            min_arity = f.min_arity,
            args = f.args,
            rets = a_vararg(node, { a_type(node, "any", {}) }),
         })
         if generic then
            wrapper = a_type(node, "generic", { typeargs = generic.typeargs, t = wrapper } as GenericType)
         end
         return a_tuple(node, { wrapper })
      end,
      ["setmetatable"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         local r = self:type_check_function_call(node, a, b, argdelta)
         local arg = node.e2 and node.e2[2]
         local given = b.tuple[2]
         local structural = given and self:to_structural(given)
         if arg and arg.kind ~= "literal_table" and given and not (given is NominalType)
            and structural is RecordLikeType then
            local msg = "a metatable that is not written in the call must be typed metatable<%s>, to be checked against %s: declare it `local mt: metatable<%s> = { ... }`"
            local target = r is TupleType and r.tuple[1]
            if not target is NominalType then
               target = nil
            end
            if target then
               self.errs:add(arg, msg, target, target, target)
            else
               self.errs:add(arg, msg:format("T", "T", "T"))
            end
         end
         return r
      end,
      ["pcall"] = special_pcall_xpcall,
      ["xpcall"] = special_pcall_xpcall,
      ["error"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         return (self:type_check_function_call(node, a, b, argdelta))
      end,

      ["type"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         local _, scope, attribute = self:find_var("type", "check_only")
         if node.e1.kind == "variable" and node.e1.tk == "type" and (scope == 1 or attribute == "const")
            and node.e2 and #node.e2 == 1 then
            node.type_of = node.e2[1]
         end
         return (self:type_check_function_call(node, a, b, argdelta))
      end,

      ["assert"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         node.guard = narrowing.truthy
         local r = self:type_check_function_call(node, a, b, argdelta)
         local arg1 = node.e2[1]
         local arg1_place = arg1 and place_of(arg1)
         if arg1_place and not arg1.guard and b.tuple[1] then
            local typ = without_nil(self, arg1, b.tuple[1], true)
            if typ then
               arg1.guard = narrowing.type_is(arg1, arg1_place, typ as narrowing.Type)
            end
         end
         -- The arguments are evaluated before `assert` tests the first: what
         -- the later ones run may change the places it is about.
         local checked = node.e2[1]
         local guard1 = checked and checked.guard
         if checked and (checked.drop_clock == nil or node.e2[#node.e2].drop_clock ~= checked.drop_clock) then
            guard1 = self:guard_before(checked, node.e2[#node.e2])
         end
         self:apply_guard(node, guard1)
         if r and r is TupleType and r.tuple[1] then
            local returned = a_tuple(node, { r.tuple[1] })
            for i = 2, #b.tuple do
               returned.tuple[i] = b.tuple[i]
            end
            returned.is_va = b.is_va
            return returned
         end
         return r
      end,
      ["string.pack"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         if #b.tuple < 1 then
            return self.errs:arity(node, #b.tuple, "at least 1", nil, 1)
         end

         local packstr = b.tuple[1]

         if packstr is StringType and packstr.literal and a is FunctionType then
            local st = packstr.literal
            local items, e = parse_pack_string(node, st)

            if e then
               if items then
                  -- just a warning
                  self.errs:add_warning("hint", packstr, e)
               else
                  return self.errs:invalid_at(packstr, e)
               end
            end

            table.insert(items, 1, a_type(node, "string", {}))

            if #items ~= #b.tuple then
               return self.errs:arity(node, #b.tuple, tostring(#items), #items, #items)
            end

            return (self:type_check_function_call(node, a, b, argdelta, a_tuple(node, items), nil))
         else
            return (self:type_check_function_call(node, a, b, argdelta))
         end
      end,

      ["string.unpack"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         if #b.tuple < 2 or #b.tuple > 3 then
            return self.errs:arity(node, #b.tuple, "2 or 3", nil, 3)
         end

         local packstr = b.tuple[1]

         local rets: TupleType = nil

         if packstr is StringType and packstr.literal then
            local st = packstr.literal
            local items, e = parse_pack_string(node, st)

            if e then
               if items then
                  -- just a warning
                  self.errs:add_warning("hint", packstr, e)
               else
                  return self.errs:invalid_at(packstr, e)
               end
            end

            table.insert(items, a_type(node, "integer", {}))

            -- set the returns to match the response
            rets = a_tuple(node, items)
         end

         return (self:type_check_function_call(node, a, b, argdelta, nil, rets))
      end,

      ["string.format"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         if #b.tuple < 1 then
            return self.errs:arity(node, #b.tuple, "at least 1", nil, 1)
         end

         local fstr = b.tuple[1]

         if fstr is StringType and fstr.literal and a is FunctionType then
            local st = fstr.literal
            local items, e = parse_format_string(node, st)

            if e then
               if items then
                  -- just a warning
                  self.errs:add_warning("hint", fstr, e)
               else
                  return self.errs:invalid_at(fstr, e)
               end
            end

            table.insert(items, 1, a_type(node, "string", {}))

            if #items ~= #b.tuple then
               return self.errs:arity(node, #b.tuple, tostring(#items), #items, #items)
            end

            -- check the arguments now
            return (self:type_check_function_call(node, a, b, argdelta, a_tuple(node, items), nil))
         else
            return (self:type_check_function_call(node, a, b, argdelta))
         end
      end,

      ["string.match"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         if #b.tuple < 2 or #b.tuple > 3 then
            return self.errs:arity(node, #b.tuple, "2 or 3", nil, 3)
         end

         local rets: TupleType = nil
         local pat = b.tuple[2]

         if pat is StringType and pat.literal then
            local st = pat.literal
            local items, e = parse_pattern_string(node, st, true)

            if e then
               if items then
                  -- just a warning
                  self.errs:add_warning("hint", pat, e)
               else
                  return self.errs:invalid_at(pat, e)
               end
            end

            -- set the returns to match the response
            rets = a_tuple(node, items)
         end
         return (self:type_check_function_call(node, a, b, argdelta, nil, rets))
      end,

      ["string.find"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         if #b.tuple < 2 or #b.tuple > 4 then
            return self.errs:arity(node, #b.tuple, "at least 2 and at most 4", nil, 4)
         end

         local plainarg = node.e2[4 + (argdelta or 0)]
         local pat = b.tuple[2]

         local rets: TupleType = nil

         if pat is StringType and pat.literal
            and ((not plainarg) or (plainarg.kind == "boolean" and plainarg.tk == "false")) then
            -- we have a nice constant string that we can modify
            local st = pat.literal

            local items, e = parse_pattern_string(node, st, false)

            if e then
               if items then
                  -- just a warning
                  self.errs:add_warning("hint", pat, e)
               else
                  return self.errs:invalid_at(pat, e)
               end
            end

            table.insert(items, 1, a_type(pat, "integer", {}))
            table.insert(items, 1, a_type(pat, "integer", {}))

            -- set the returns to match the response
            rets = a_tuple(node, items)
         end

         return (self:type_check_function_call(node, a, b, argdelta, nil, rets))
      end,

      ["string.gmatch"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         if #b.tuple < 2 or #b.tuple > 3 then
            return self.errs:arity(node, #b.tuple, "2 or 3", nil, 3)
         end

         local rets: TupleType = nil
         local pat = b.tuple[2]

         if pat is StringType and pat.literal then
            local st = pat.literal
            local items, e = parse_pattern_string(node, st, true)

            if e then
               if items then
                  -- just a warning
                  self.errs:add_warning("hint", pat, e)
               else
                  return self.errs:invalid_at(pat, e)
               end
            end

            -- set the returns to match the response
            rets = a_tuple(node, {
               a_function(node, {
                  min_arity = 0,
                  args = a_tuple(node, {}),
                  rets = a_tuple(node, items),
               })
            })
         end

         return (self:type_check_function_call(node, a, b, argdelta, nil, rets))
      end,

      ["string.gsub"] = function(self: TypeChecker, node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
         -- if the second argument is a literal, we can parse it and change the matchers
         -- gsub: function(string, string, <matcher>, ? integer): string, integer

         if #b.tuple < 3 or #b.tuple > 4 then
            return self.errs:arity(node, #b.tuple, "3 or 4", nil, 4)
         end
         local pat = b.tuple[2]
         local orig_t = b.tuple[3]
         local trepl = self:to_structural(orig_t)

         local has_fourth = b.tuple[4]

         local args: TupleType = nil

         if pat is StringType and pat.literal then
            local st = pat.literal
            local items, e = parse_pattern_string(node, st, true)

            if e then
               if items then
                  -- just a warning
                  self.errs:add_warning("hint", pat, e)
               else
                  return self.errs:invalid_at(pat, e)
               end
            end

            local i1 = items[1]

            -- we expect replarg to be one of:
            -- string
            -- {(items[1]):string}
            -- function(table.unpack(items)): ((string|integer|number)...)

            local replarg_type: Type = nil

            local expected_pat_return = a_union(node, {
               a_type(node, "string", {}),
               a_type(node, "integer", {}),
               a_type(node, "number", {}),
            })
            if self:is_a(trepl, expected_pat_return) then
               -- fine
               replarg_type = expected_pat_return
            elseif trepl is MapType then
               replarg_type = a_map(node, i1, expected_pat_return)
            elseif trepl is RecordLikeType then
               if not (i1 is StringType) then
                  self.errs:invalid_at(trepl, "expected a table with integers as keys")
               end
               replarg_type = a_map(node, i1, expected_pat_return)
            elseif trepl is ArrayLikeType then
               if not (i1 is IntegerType) then
                  self.errs:invalid_at(trepl, "expected a table with strings as keys")
               end
               replarg_type = an_array(node, expected_pat_return)
            elseif trepl is FunctionType then
               local validftype = a_function(node, {
                  min_arity = self.feat_arity and #items or 0,
                  args = a_tuple(node, items),
                  rets = a_vararg(node, { expected_pat_return }),
               })
               replarg_type = validftype
            end
            -- other types should be taken care of by the type_check_function_call below

            if replarg_type then
               args = a_tuple(node, {
                  a_type(node, "string", {}),
                  a_type(node, "string", {}),
                  replarg_type,
                  has_fourth and a_type(node, "integer", {}) or nil,
               })
            end
         end

         return (self:type_check_function_call(node, a, b, argdelta, args, nil))
      end,
   }

   -- Reported at an `assert(...)` in the last position of an argument
   -- list, a table constructor, or a return, when the values it expands
   -- to beyond the first are what the surrounding check refused.
   -- `cosmic fix` parenthesizes the call it names.
   TypeChecker.assert_spill_message = "assert(...) passes on every value it was given, not only the first; write (assert(...)) to keep only the first (`cosmic fix` writes the parentheses)"

   -- Adds that report at `exp` when `exp` is an assert(...) call and a
   -- check since the error count `before` failed.
   function TypeChecker:assert_spill_hint(exp: Node, before: integer)
      if exp and node_is_funcall(exp) and exp.e1.kind == "variable" and
         exp.e1.tk == "assert" and #self.errs.errors > before then
         self.errs:add(exp, TypeChecker.assert_spill_message)
      end
   end

   -- A callee as written (`Json.decode`, `obj:get`, `f`); nil for any other
   -- expression.
   local function callee_text(n: Node): string | nil
      if n.kind == "variable" then
         return n.tk
      end
      if n.kind == "op" and n.op and (n.op.op == "." or n.op.op == ":") and n.e1 and n.e2 and n.e2.tk then
         local left = callee_text(n.e1)
         if left then
            return left .. n.op.op .. n.e2.tk
         end
      end
      return nil
   end

   -- Appends to the first "wrong number of arguments" error since the error
   -- count `before` that `exp`, the last argument of the call, is a call
   -- returning `values` (more than one) and passes them all on.
   function TypeChecker:spill_arity_hint(exp: Node, before: integer, values: integer)
      if not (exp and node_is_funcall(exp)) then
         return
      end
      local callee = callee_text(exp.e1)
      local call = (callee or "the call") .. "(...)"
      local said: string
      if callee == "assert" then
         said = " -- the last argument assert(...) passes on every value it was given, so " ..
            "the call is given " .. values .. " there: write (assert(...)) to keep only the first " ..
            "(`cosmic fix` writes the parentheses)"
      else
         said = " -- the last argument " .. call .. " returns " .. values .. " values and the call is " ..
            "given them all: wrap it in parentheses to pass only the first, `(" .. call .. ")`, " ..
            "or assign it to a local first"
      end
      for i = before + 1, #self.errs.errors do
         local err = self.errs.errors[i]
         if err.code == "arity" then
            -- Only too many arguments, for a callee that takes some, is
            -- cured by passing one value; a handler that re-enters this
            -- check has already said so.
            local most = err.expects_most
            if err.given > most and most >= 1 and not err.advised then
               err.msg = err.msg .. said
               err.advised = true
            end
            return
         end
      end
   end

   function TypeChecker:type_check_funcall(node: Node, a: Type, b: TupleType, argdelta?: integer): InvalidOrTupleType
      if node.e1.op and node.e1.op.op == ":" then
         table.insert(b.tuple, 1, node.e1.receiver)
         argdelta = -1
      else
         argdelta = argdelta or 0
      end

      local before = #self.errs.errors
      local given = node.e2 and #node.e2 or 0
      local receiver = argdelta == -1 and 1 or 0
      local spilled = #b.tuple > given + receiver
      local values = #b.tuple - receiver - (given - 1)

      local sa = resolve_for_special_function(a)
      if sa then
         local special_tyck = special_functions[sa.special_function_handler]
         if special_tyck then
            local ret = special_tyck(self, node, a, b, argdelta)
            if spilled then
               self:assert_spill_hint(node.e2[given], before)
               if not b.is_va then self:spill_arity_hint(node.e2[given], before, values) end
            end
            return ret
         end
      end

      local ret = self:type_check_function_call(node, a, b, argdelta)
      if spilled then
         self:assert_spill_hint(node.e2[given], before)
         if not b.is_va then self:spill_arity_hint(node.e2[given], before, values) end
      end
      return ret
   end

   -- is the i-th assignment in a local declaration of the form `x = x` ?
   local function is_localizing_a_variable(node: Node, i: integer): boolean
      return node.exps
         and node.exps[i]
         and node.exps[i].kind == "variable"
         and node.exps[i].tk == node.vars[i].tk
   end

   function TypeChecker:missing_initializer(node: Node, i: integer, name: string): (InvalidType | UnknownType)
      if self.feat_lax then
         return an_unknown(node)
      else
         if node.exps then
            -- The call that gave the variable no value, when it is one to a
            -- function that never returns.
            local exp = node.exps[math.min(i, #node.exps)]
            local never_call = exp and node_is_funcall(exp) and flow.ends(exp as flow.Node) and exp.e1
            return self.errs:invalid_coded(node.vars[i], Errors.make({
               code = "no_initial_value",
               variable = name,
               callee = never_call and callee_text(exp.e1) or nil,
               callee_never = never_call and callee_text(exp.e1) ~= nil or nil,
            }), "assignment in declaration did not produce an initial value for variable '" .. name .. "'")
         else
            return self.errs:invalid_coded(node.vars[i], Errors.make({
               code = "no_type",
               variable = name,
            }), "variable '" .. name .. "' has no type or initial value")
         end
      end
   end

   local function set_expected_types_to_decltuple(self: TypeChecker, node: Node, children: {Type})
      local decltuple = node.kind == "assignment" and children[1] or node.decltuple
      assert(decltuple is TupleType)
      local decls = decltuple.tuple
      if decls and node.exps then
         local ndecl = #decls
         local nexps = #node.exps
         for i = 1, nexps do
            local typ: Type
            typ = decls[i]
            if typ then
               if i == nexps and ndecl > nexps and node_is_funcall(node.exps[i]) then
                  typ = a_tuple(node, {})
                  for a = i, ndecl do
                     table.insert(typ.tuple, decls[a])
                  end
               end
               node.exps[i].expected = typ
               -- More types than variables (`local x: T, y = 1, 2` reads
               -- `y` as a second type) leaves a type with no variable.
               local var = node.vars[i]
               node.exps[i].expected_context = { kind = node.kind, name = var and var.tk }
            end
         end
      end

      if node.decltuple then
         local ndecltuple = #node.decltuple.tuple
         local nvars = #node.vars
         if ndecltuple > nvars then
            self.errs:add(node.decltuple.tuple[nvars + 1], "number of types exceeds number of variables")
         end
      end
   end

   local function is_positive_int(n: number): boolean
      return n and n >= 1 and math.floor(n) == n
   end

   local function infer_table_literal(self: TypeChecker, node: Node, children: {LiteralTableItemType}): Type
      local is_record = false
      local is_array = false
      local is_map = false

      local is_tuple = false
      local is_not_tuple = false

      local last_array_idx = 1
      local largest_array_idx = -1

      local seen_keys: {CheckableKey:Where} = {}

      -- array, tupletable
      local types: {Type} = nil
      -- record
      local fields: {string:Type} = nil
      local field_order: {string} = nil
      -- array, record
      local elements: Type = nil
      -- map
      local keys, values: Type, Type = nil, nil

      for i, child in ipairs(children) do
         local ck = child.kname
         local cktype = child.ktype
         local key: CheckableKey = ck
         local n: number = nil
         if not key then
            n = node[i].key.constnum
            key = n
            if not key and node[i].key.kind == "boolean" then
               key = (node[i].key.tk == "true")
            end
         end

         self.errs:check_redeclared_key(node[i], nil, seen_keys, key)

         local uvtype = resolve_tuple(child.vtype)
         if ck then
            is_record = true
            if not fields then
               fields = {}
               field_order = {}
            end
            fields[ck] = uvtype
            table.insert(field_order, ck)
         elseif cktype is NumericType then
            is_array = true
            if not is_not_tuple then
               is_tuple = true
            end
            if not types then
               types = {}
            end

            if node[i].key_parsed == "implicit" then
               local cv = child.vtype
               if i == #children and cv is TupleType then
                  -- need to expand last item in an array (e.g { 1, 2, 3, f() })
                  for _, c in ipairs(cv.tuple) do
                     elements = self:expand_type(node, elements, c)
                     types[last_array_idx] = resolve_tuple(c)
                     last_array_idx = last_array_idx + 1
                  end
               else
                  types[last_array_idx] = uvtype
                  last_array_idx = last_array_idx + 1
                  elements = self:expand_type(node, elements, uvtype)
               end
            else -- explicit
               if not is_positive_int(n) then
                  elements = self:expand_type(node, elements, uvtype)
                  is_not_tuple = true
               elseif n then
                  types[n as integer] = uvtype
                  if n > largest_array_idx then
                     largest_array_idx = n as integer
                  end
                  elements = self:expand_type(node, elements, uvtype)
               end
            end

            if last_array_idx > largest_array_idx then
               largest_array_idx = last_array_idx
            end
            if not elements then
               is_array = false
            end
         else
            is_map = true
            keys = self:expand_type(node, keys, drop_constant_value(cktype))
            values = self:expand_type(node, values, uvtype)
         end
      end

      local t: Type = nil

      if is_array and is_map then
         self.errs:add(node, "cannot determine type of table literal")
         t = a_map(node,
            self:expand_type(node, keys, a_type(node, "integer", {})),
            self:expand_type(node, values, elements)
         )
      elseif is_record and is_array then
         t = a_type(node, "record", {
            fields = fields,
            field_order = field_order,
            elements = elements,
            interface_list = {
               an_array(node, elements)
            }
         } as RecordType)
         -- TODO adopt logic from self:is_array below when we accept tupletable as an interface
      elseif is_record and is_map then
         if keys is StringType then
            for _, fname in ipairs(field_order) do
               values = self:expand_type(node, values, fields[fname])
            end
            t = a_map(node, keys, values)
         else
            self.errs:add(node, "cannot determine type of table literal")
         end
      elseif is_array then
         local pure_array = true
         if not is_not_tuple then
            local last_t: Type = nil
            for _, current_t in pairs(types as {integer:Type}) do
               if last_t then
                  if not self:same_type(last_t, current_t) then
                     pure_array = false
                     break
                  end
               end
               last_t = current_t
            end
         end
         if pure_array then
            t = an_array(node, elements)
            t.consttypes = types
            t.inferred_len = largest_array_idx - 1
         else
            t = a_type(node, "tupletable", { inferred_at = node }) as TupleTableType
            t.types = types
         end
      elseif is_record then
         t = a_type(node, "record", {
            fields = fields,
            field_order = field_order,
         } as RecordType)
      elseif is_map then
         t = a_map(node, keys, values)
      elseif is_tuple then
         t = a_type(node, "tupletable", { inferred_at = node }) as TupleTableType
         t.types = types
         if not types or #types == 0 then
            self.errs:add(node, "cannot determine type of tuple elements")
         end
      end

      if not t then
         t = a_type(node, "emptytable", {})
      end

      return type_at(node, t)
   end

   -- Applies the guard of control reaching past the first `n` branches of
   -- `ifnode`: none of their conditions held. A condition's test holds past
   -- the conditions after it only if they ran nothing that may change the
   -- places it is about.
   function TypeChecker:infer_negation_of_if_blocks(w: Where, ifnode: Node, n: integer)
      local blocks = ifnode.if_blocks
      local kept: {narrowing.Node} = {}
      local later = 0
      for e = n, 1, -1 do
         local block = blocks[e]
         if later > 0 and block.exp then
            kept[e] = { exp = { guard = self:prune(block.exp.guard) } } as narrowing.Node
         else
            kept[e] = block as narrowing.Node
         end
         if block.exp then
            -- A condition that was not stamped is taken to have run code.
            local ended = block.exp.drop_clock
            later = later + (ended and ended - block.clock_start or 1)
         end
      end
      self:apply_guard(w, narrowing.none_of(w, kept, n))
   end

   function TypeChecker:determine_declaration_type(var: Node, node: Node, infertypes: TupleType, i: integer): boolean, Type, boolean
      local ok = true
      local name = var.tk
      local infertype = infertypes and infertypes.tuple[i]
      if self.feat_lax and infertype and infertype is NilType then
         infertype = nil
      end

      local decltype = node.decltuple and node.decltuple.tuple[i]
      if decltype then
         local rdecltype = self:to_structural(decltype)
         if rdecltype is InvalidType then
            decltype = rdecltype
         end

         if infertype then
            local w = node.exps and node.exps[i] or node.vars[i]
            ok = self:assert_is_a(w, infertype, decltype, context_name[node.kind], name)
         end
      else
         if infertype then
            if infertype is UnresolvableTypeArgType then
               ok = false
               infertype = self.errs:invalid_at(node.vars[i], "cannot infer declaration type; an explicit type annotation is necessary")
            else
               -- If we assign a method to a variable, e.g:
               -- `local myfunc = myobj.dothing`,
               -- the variable should not be treated as a method
               infertype = ensure_not_method(infertype)
            end
         end
      end

      if var.attribute == "total" then
         local rd = decltype and self:to_structural(decltype)
         if rd and (not rd is MapType) and (not rd is RecordType) then
            self.errs:add(var, "attribute <total> only applies to maps and records")
            ok = false
         elseif not infertype then
            self.errs:add(var, "variable declared <total> does not declare an initialization value")
            ok = false
         else
            local valnode = node.exps[i]
            if not valnode or valnode.kind ~= "literal_table" then
               self.errs:add(var, "attribute <total> only applies to literal tables")
               ok = false
            else
               if not valnode.is_total then
                  local missing = ""
                  if valnode.missing then
                     missing = " (missing: " .. table.concat(valnode.missing, ", ") .. ")"
                  end
                  local ri = self:to_structural(infertype)
                  if ri is MapType then
                     self.errs:add(var, "map variable declared <total> does not declare values for all possible keys" .. missing)
                     ok = false
                  elseif ri is RecordType then
                     self.errs:add(var, "record variable declared <total> does not declare values for all fields" .. missing)
                     ok = false
                  end
               end
            end
         end
      end

      local t = decltype or infertype
      if t == nil then
         t = self:missing_initializer(node, i, name)
      elseif t is EmptyTableType then
         t.declared_at = node
         t.assigned_to = name
      elseif t is ArrayLikeType then
         t.inferred_len = nil
      elseif t is NominalType then
         self:resolve_nominal(t)
         local rt = t.resolved
         if rt and rt is TypeDeclType then
            t.resolved = rt.def
         end
      end

      return ok, t, infertype ~= nil
   end

   -- Whether a local of type `t` declared with no value is nil where it is
   -- first read, so that read must not come before an assignment: its type
   -- does not admit nil. A type variable might be any type, so it is not
   -- taken to admit nil here.
   local function needs_value(self: TypeChecker, w: Where, t: Type): boolean
      local rt = t
      if rt is NominalType then
         rt = self:resolve_nominal(rt)
      end
      if rt is InvalidType then
         return false
      end
      return rt is TypeVarType or not admits_nil(self, w, t)
   end

   local function kind_of_skip(by: flow.Node): string
      local kind = by.kind
      if kind == "if_block" then
         return "branch"
      end
      return kind == "if" and "if" or "loop"
   end

   -- Refuses a read of a local declared with no value in `body`, a block,
   -- along a path that has not assigned it. `tail` is the `until` of a
   -- `repeat` body, in the scope of the body's locals.
   function TypeChecker:check_assigned(body: Node, tail?: Node)
      for i, stmt in ipairs(body) do
         local vars = stmt.kind == "local_declaration" and stmt.unvalued
         if vars then
            for _, var in ipairs(vars) do
               local found, skipped, ran, how = flow.unassigned_read(body as flow.Node, i + 1, var.tk, tail as flow.Node)
               if found then
                  local read = found as Node
                  local closure = read.kind ~= "variable"
                  local details = Errors.make({
                     code = "not_assigned",
                     variable = var.tk,
                     closure = closure or nil,
                     ran_kind = closure and how or nil,
                  })
                  if ran then
                     details.ran_y = (ran as Node).y
                     details.ran_x = (ran as Node).x
                  end
                  if skipped then
                     local by = skipped as Node
                     details.skipped_kind = kind_of_skip(skipped)
                     details.skipped_y = by.y
                     details.skipped_x = by.x
                  end
                  self.errs:add_coded(read, details,
                     ("'%s' may be read before it is assigned%s"):format(var.tk,
                        closure and ": the function made here names it" or ""))
               end
            end
         end
      end
   end

   local function aliasing_variable(self: TypeChecker, def: Type): Variable
      if def is NominalType then
         return (self:find_var(def.names[1], "use_type"))
      end

      if def is GenericType then
         local nom = def.t
         if nom is NominalType then
            return (self:find_var(nom.names[1], "use_type"))
         end
      end
   end

   local function recurse_type_declaration(self: TypeChecker, n: Node): InvalidOrTypeDeclType, Variable
      if n.kind == "op" then
         -- recursive case: e1.e2
         if n.op.op == "." then
            local ty = recurse_type_declaration(self, n.e1)
            if not ty is TypeDeclType then
               return ty
            end
            local def = ty.def
            if not def is RecordType then
               return self.errs:invalid_at(n.e1, "type is not a record")
            end
            local t = def.fields[n.e2.tk]
            if t and t is TypeDeclType then
               return t
            end
            return self.errs:invalid_at(n.e2, "nested type '" .. n.e2.tk .. "' not found in record")
         -- base case: require(e2)
         elseif n.op.op == "@funcall"
            and n.e1.kind == "variable"
            and n.e1.tk == "require"
         then
            local ty = resolve_tuple(
               special_functions["require"](
                  self, n, self:find_var_type("require"),
                  a_tuple(n.e2, { a_type(n.e2[1], "string", {}) })
               )
            )
            if not ty is TypeDeclType then
               return self.errs:invalid_coded(n.e1, Errors.make({ code = "require_not_type", got = show_type(ty), got_kind = ty.typename }), "'require' did not return a type, got %s", ty)
            end
            if ty.is_alias then
               return self:resolve_typealias(ty)
            end
            return ty
         end
      end
      -- base case: type
      local newtype = n.newtype
      if newtype.is_alias then
         return self:resolve_typealias(newtype), aliasing_variable(self, newtype.def)
      end
      return newtype, nil
   end

   function TypeChecker:get_typedecl(value: Node): InvalidOrTypeDeclType, Variable
      local resolved, aliasing = recurse_type_declaration(self, value)
      local nt = value.newtype
      if nt and nt.is_alias and resolved is TypeDeclType then
         local ntdef = nt.def
         local rdef = resolved.def
         if ntdef is GenericType and rdef is GenericType then
            -- FIXME this looks sketchy; not sure if just overwriting the
            -- type variables in a resolved alias won't have bad side-effects.
            -- Is it guaranteed to be a fresh type?
            ntdef.typeargs = rdef.typeargs
         end
      end
      return resolved, aliasing
   end

   local function total_check_key(key: CheckableKey, seen_keys: {CheckableKey:Where}, is_total: boolean, missing: {string}): boolean, {string}
      if not seen_keys[key] then
         missing = missing or {}
         table.insert(missing, tostring(key))
         return false, missing
      end
      return is_total, missing
   end

   local function total_record_check(t: RecordLikeType, seen_keys: {CheckableKey:Where}): boolean, {string}
      local is_total = true
      local missing: {string} = nil
      for _, key in ipairs(t.field_order) do
         local ftype = t.fields[key]
         if not (ftype is TypeDeclType or (ftype is FunctionType and ftype.is_record_function)) then
            is_total, missing = total_check_key(key, seen_keys, is_total, missing)
         end
      end
      return is_total, missing
   end

   local function total_map_check(keys: Type, seen_keys: {CheckableKey:Where}): boolean, {string}
      local is_total = true
      local missing: {string} = nil
      if keys is EnumType then
         for _, key in ipairs(sorted_keys(keys.enumset)) do
            is_total, missing = total_check_key(key, seen_keys, is_total, missing)
         end
      elseif keys is BooleanType then
         for _, key in ipairs({ true, false }) do
            is_total, missing = total_check_key(key, seen_keys, is_total, missing)
         end
      else
         is_total = false
      end
      return is_total, missing
   end

   local enum MissingError
      "missing"
   end

   function TypeChecker:check_assignment(varnode: Node, vartype: Type, valtype: Type): Type, Type, MissingError
      local varname = varnode.tk
      local attr = varnode.attribute

      if varname and varnode.kind == "variable" then
         for i = #self.st, 1, -1 do
            local declared = self.st[i].vars[varname]
            if declared and declared.is_loop_control then
               self.errs:add(varnode, "cannot assign to for-loop variable '" .. varname ..
                  "': it is read-only; copy it to a local first")
               return nil
            elseif declared and (declared.is_loop_control == false or
               (not declared.is_specialized) or declared.specialized_from) then
               break
            end
         end
      end

      if varname then
         if self:widen_back_var(varname) then
            vartype, attr = self:find_var_type(varname)
            if not vartype then
               self.errs:add(varnode, "unknown variable")
               return nil
            end
         end
      end
      if attr == "close" or attr == "const" or attr == "total" then
         self.errs:add(varnode, "cannot assign to <" .. attr .. "> variable")
         return nil
      end

      local var = self:to_structural(vartype)
      if var is TypeDeclType then
         self.errs:add(varnode, "cannot reassign a type")
         return nil
      end

      if not valtype then
         self.errs:add(varnode, "variable is not being assigned a value")
         return nil, nil, "missing"
      end

      if varnode.kind == "op" and varnode.op.op == "." then
         self:mark_receiver(valtype, vartype)
      end
      self:assert_is_a(varnode, valtype, vartype, "in assignment")
      self.receiver_field = nil

      local val = self:to_structural(valtype)

      return var, val
   end

   local function discard_tuple(node: Node, t: Type, b: Type): Type
      if b is TupleType then
         node.discarded_tuple = true
      end
      return resolve_tuple(t)
   end

   local visit_node: Visitor<TypeChecker, NodeKind, Node, Type> = {}

   visit_node.cbs = {
      ["statements"] = {
         before = function(self: TypeChecker, node: Node)
            self:begin_scope(node)
         end,
         after = function(self: TypeChecker, node: Node, _children: {Type}): Type
            -- if at the top level
            if #self.st == 2 then
               self.errs:fail_unresolved_labels(self.st[2])
               self.errs:fail_unresolved_nominals(self.st[2], self.st[1])
            end

            if not node.is_repeat then
               self:check_assigned(node)
               self:end_scope(node)
            end

            return NONE
         end
      },
      ["local_type"] = {
         before = function(self: TypeChecker, node: Node)
            local name = node.var.tk
            local resolved, aliasing = self:get_typedecl(node.value)
            local var = self:add_var(node.var, name, resolved, node.var.attribute)
            if aliasing then
               var.aliasing = aliasing
            end
         end,
         after = function(self: TypeChecker, node: Node, _children: {Type}): Type
            self:dismiss_unresolved(node.var.tk)
            return NONE
         end,
      },
      ["global_type"] = {
         before = function(self: TypeChecker, node: Node)
            local global_scope = self.st[1]
            local name = node.var.tk
            if node.value then
               local resolved, aliasing = self:get_typedecl(node.value)
               local added = self:add_global(node.var, name, resolved)
               if resolved is InvalidType then
                  return
               end
               node.value.newtype = resolved
               if aliasing then
                  added.aliasing = aliasing
               end

               if global_scope.pending_global_types[name] then
                  global_scope.pending_global_types[name] = nil
               end
            else
               if not self.st[1].vars[name] then
                  global_scope.pending_global_types[name] = true
               end
            end
         end,
         after = function(self: TypeChecker, node: Node, _children: {Type}): Type
            self:dismiss_unresolved(node.var.tk)
            return NONE
         end,
      },
      ["local_declaration"] = {
         before = function(self: TypeChecker, node: Node)
            if self.collector then
               for _, var in ipairs(node.vars) do
                  self.collector.reserve_symbol_list_slot(var)
               end
            end
         end,
         before_exp = set_expected_types_to_decltuple,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            local valtuple = children[3] as TupleType -- may be nil

            local encountered_close = false
            local infertypes = get_assignment_values(node, valtuple, #node.vars)
            local given = node.exps and #node.exps or 0
            -- A last value that is a call or `...` may give the rest.
            local spread = given > 0 and (node.exps[given].kind == "..." or node_is_funcall(node.exps[given]))
            for i, var in ipairs(node.vars) do
               if var.attribute == "close" then
                  if self.gen_target == "5.4" then
                     if encountered_close then
                        self.errs:add(var, "only one <close> per declaration is allowed")
                     else
                        encountered_close = true
                     end
                  else
                     self.errs:add(var, "<close> attribute is only valid for Lua 5.4 (current target is " .. tostring(self.gen_target) .. ")")
                  end
               end

               local ok, t = self:determine_declaration_type(var, node, infertypes, i)

               if var.attribute == "close" then
                  if not type_is_closable(t) then
                     self.errs:add_coded(var, Errors.about(Errors.make({ code = "not_closable", variable = var.tk }), t), "to-be-closed variable " .. var.tk .. " has a non-closable type %s", t)
                  elseif node.exps and node.exps[i] and expr_is_definitely_not_closable(node.exps[i]) then
                     self.errs:add(var, "to-be-closed variable " .. var.tk .. " assigned a non-closable value")
                  end
               end

               assert(var)
               if i > given and not spread and needs_value(self, var, t) then
                  node.unvalued = node.unvalued or {}
                  table.insert(node.unvalued, var)
               end
               local declared = self:add_var(var, var.tk, t, var.attribute, is_localizing_a_variable(node, i) and "localizing")
               declared.is_loop_control = false
               if var.elide_type then
                  self.errs:add_warning("hint", node, "hint: consider using 'local type' instead")
               end

               local infertype = infertypes.tuple[i]
               if ok and infertype then
                  local w = node.exps[i] or node.exps

                  local rt = self:to_structural(t)
                  if (not rt is EnumType)
                     and ((not t is NominalType) or (rt is UnionType))
                     and not self:same_type(t, infertype)
                  then
                     t = self:infer_at(w, infertype)
                     self:add_var(w, var.tk, t, "const", "narrowed_declaration")
                  end
               end

               if self.collector then
                  self.collector.store_type(var.y, var.x, t)
               end

               self:dismiss_unresolved(var.tk)
            end
            return NONE
         end,
      },
      ["global_declaration"] = {
         before_exp = set_expected_types_to_decltuple,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            local valtuple = children[3] as TupleType -- may be nil

            local infertypes = get_assignment_values(node, valtuple, #node.vars)
            for i, var in ipairs(node.vars) do
               local _, t, is_inferred = self:determine_declaration_type(var, node, infertypes, i)

               if var.attribute == "close" then
                  self.errs:add(var, "globals may not be <close>")
               end

               self:add_global(var, var.tk, t, is_inferred)
               if var.elide_type then
                  self.errs:add_warning("hint", node, "hint: consider using 'global type' instead")
               end

               self:dismiss_unresolved(var.tk)
            end
            return NONE
         end,
      },
      ["assignment"] = {
         before = function(self: TypeChecker, node: Node)
            -- TODO: after `x.f = v` with v not nil, narrow `x.f` to v's
            -- type instead of only dropping the narrow, and keep that
            -- narrow across the end of an `if x.f == nil then x.f = {} end`:
            -- as it is, `local h = x.f` below that still reads `T | nil`,
            -- so cosmic's own code binds `x.f or {}` to a local first.
            for _, varnode in ipairs(node.vars) do
               local assigned = narrowing.target_of(varnode as narrowing.Node)
               if assigned then
                  local scopes = self.st as {narrowing.Scope}
                  local at = varnode
                  while at.kind == "op" and at.e1 and at.op.arity == 2 do
                     at = at.e1
                  end
                  local why = narrowing.because("assignment", assigned.key .. " = ...", at.y, at.x)
                  if #assigned.fields == 0 then
                     narrowing.note(scopes, assigned.key, why)
                  end
                  narrowing.drop(scopes, assigned, why)
               end
            end
         end,
         before_exp = set_expected_types_to_decltuple,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            local vartuple = children[1]
            assert(vartuple is TupleType)
            local vartypes = vartuple.tuple
            local valtuple = children[3]
            assert(valtuple is TupleType)
            local valtypes = get_assignment_values(node, valtuple, #vartypes)
            -- Every value is evaluated before any target is written, so a
            -- narrowed read in a value has seen what the write drops.
            for _, target in ipairs(node.vars) do
               self:drop_through(target)
            end
            for i, vartype in ipairs(vartypes) do
               local varnode = node.vars[i]
               local varname = varnode.tk
               local valtype = valtypes.tuple[i]
               local rvar, rval, err = self:check_assignment(varnode, vartype, valtype)
               if err == "missing" then
                  if #node.exps == 1 and node_is_funcall(node.exps[1]) then
                     local msg = #valtuple.tuple == 1
                                 and "only 1 value is returned by the function"
                                 or ("only " .. #valtuple.tuple .. " values are returned by the function")
                     self.errs:add_warning("hint", varnode, msg)
                  end
               end

               if rval and rvar then
                  -- assigning a function
                  if rval is FunctionType then
                     self:widen_all_unions()
                  end

                  if varname and (rvar is UnionType or rvar is InterfaceType) then
                     -- narrow unions and interfaces
                     self:add_var(varnode, varname, valtype, nil, "narrow")
                  end

                  if self.collector then
                     self.collector.store_type(varnode.y, varnode.x, valtype)
                  end
               end

               if self.runtime_checks and i <= #node.exps
                  and (i < #node.exps or #node.exps >= #vartypes)
                  and varnode.op and varnode.op.op == "." and varnode.receiver then
                  local receiver = varnode.receiver
                  local rt = not receiver is TupleType and self:to_structural(receiver)
                  if rt is TypeDeclType then
                     rt = rt.def
                  end
                  local key = varnode.e2.tk
                  -- TODO: check a write to a field the record inherits from an
                  -- interface, or that a generic record declares: both are left
                  -- out here, which looks only at the fields a plain record lists
                  -- itself. Resolve the field with `match_record_key` once it can
                  -- be asked without reporting an error to the program being checked.
                  if rt is RecordType and rt.fields[key] then
                     local kinds = self:runtime_kinds(rt.fields[key])
                     if kinds then
                        node.exps.rt_set = node.exps.rt_set or {}
                        node.exps.rt_set[i] = (rt.declname or "?") .. "." .. key .. ";" .. kinds
                     end
                  end
               end
            end

            return NONE
         end,
      },
      ["if"] = {
         after = function(self: TypeChecker, node: Node, _children: {Type}): Type
            if node.if_widens then
               -- TODO we could collect the types from each if_block
               -- and narrow the type to their union
               self:widen_all(node.if_widens, {})
            end

            if flow.ends_all(node.if_blocks as {flow.Node}) then
               -- TODO: the negation below does not distribute over a
               -- condition that is an `or`: after `if p == nil or p == ""
               -- then return end`, p is still `string | nil`, though
               -- `not (a or b)` is `not a and not b`; two ifs narrow it.
               -- cosmic's own code splits such guards or defaults first
               -- (`local p = x.p or ""`).
               self:infer_negation_of_if_blocks(node, node, #node.if_blocks)
            end

            return NONE
         end,
      },
      ["if_block"] = {
         before = function(self: TypeChecker, node: Node)
            node.clock_start = self.drop_clock
            if node.exp then
               node.exp.want_clock = true
            end
            self:begin_scope(node)
            if node.if_block_n > 1 then
               self:infer_negation_of_if_blocks(node, node.if_parent, node.if_block_n - 1)
            end
            if node.exp then
               node.exp.expected = a_type(node, "boolean_context", {})
            end
         end,
         before_statements = function(self: TypeChecker, node: Node)
            if node.exp then
               self:apply_guard(node.exp, node.exp.guard)
            end
            node.journal_mark = narrowing.mark(self.st as {narrowing.Scope})
            node.tick_mark = self.loop_tick
         end,
         after = function(self: TypeChecker, node: Node, _children: {Type}): Type
            node.if_parent.if_widens = self:collect_if_widens(node.if_parent.if_widens)

            -- Control reaches the code after the `if` only if this branch
            -- was not taken, so what the branch dropped is dropped for the
            -- code in it alone.
            if node.journal_mark and flow.leaves_body(node.body as flow.Node) then
               narrowing.undo(self.st as {narrowing.Scope}, node.journal_mark)
               self:loops_forget_since(node.tick_mark)
            end

            self:end_scope(node)

            return NONE
         end
      },
      ["while"] = {
         before = function(self: TypeChecker, node: Node)
            -- widen all narrowed variables because we don't calculate a fixpoint yet
            self:widen_all_unions(node)
            self:loop_begin()
            node.exp.expected = a_type(node, "boolean_context", {})
         end,
         before_statements = function(self: TypeChecker, node: Node)
            self:begin_scope(node)
            self:apply_guard(node.exp, node.exp.guard)
         end,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            self:loop_end()
            self:check_assigned(node.body, node.exp)
            return end_scope_and_none_type(self, node, children)
         end,
      },
      ["label"] = {
         before = function(self: TypeChecker, node: Node)
            -- widen all narrowed variables because we don't calculate a fixpoint yet
            self:widen_all_unions()
            -- A `goto` below the label reaches it from code that may have
            -- changed any field. One above it does not: what that path
            -- dropped stays dropped (a branch that ends in `goto` undoes
            -- nothing).
            if self:label_is_looped(node) then
               narrowing.drop_paths(self.st as {narrowing.Scope},
                  narrowing.because("label", "::" .. node.label .. "::", node.y, node.x))
            end
            local label_id = node.label
            do
               local scope = self.st[#self.st]
               scope.labels = scope.labels or {}
               if scope.labels[label_id] then
                  self.errs:add(node, "label '" .. node.label .. "' already defined")
               else
                  scope.labels[label_id] = node
               end
            end

            --for i = #self.st, 1, -1 do
               local scope = self.st[#self.st]
               if scope.pending_labels and scope.pending_labels[label_id] then
                  node.used_label = true
                  scope.pending_labels[label_id] = nil
                  --break
               end
            --end
         end,
         after = function(): Type
            return NONE
         end
      },
      ["goto"] = {
         after = function(self: TypeChecker, node: Node, _children: {Type}): Type
            local label_id = node.label
            local found_label: Node = nil
            for i = #self.st, 1, -1 do
               local scope = self.st[i]
               if scope.labels and scope.labels[label_id] then
                  found_label = scope.labels[label_id]
                  break
               end
            end

            if found_label then
               found_label.used_label = true
            else
               local scope = self.st[#self.st]
               scope.pending_labels = scope.pending_labels or {}
               scope.pending_labels[label_id] = scope.pending_labels[label_id] or {}
               table.insert(scope.pending_labels[label_id], node)
            end

            return NONE
         end,
      },
      ["repeat"] = {
         before = function(self: TypeChecker, node: Node)
            -- widen all narrowed variables because we don't calculate a fixpoint yet
            self:widen_all_unions(node)
            self:loop_begin()
            node.exp.expected = a_type(node, "boolean_context", {})
         end,
         -- only end scope after checking `until`, `statements` in repeat body has is_repeat == true
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            self:loop_end()
            return end_scope_and_none_type(self, node, children)
         end,
      },
      ["forin"] = {
         before = function(self: TypeChecker, node: Node)
            self:begin_scope(node)
         end,
         before_statements = function(self: TypeChecker, node: Node, children: {Type})
            self:loop_begin()
            local exptuple = children[2]
            assert(exptuple is TupleType)
            local exptypes = exptuple.tuple

            local exp1 = node.exps[1]
            if #exptypes < 1 then
               self.errs:invalid_at(exp1, "expression in 'for' statement does not return any values")
               return
            end

            self:widen_all_unions(node)
            -- The iterator runs before every pass, and the body runs again.
            -- `pairs`, `ipairs` and `gmatch` of what runs no code are the
            -- iterators that run none of the program's.
            if not self:pure_iterator(node) then
               self:drop_all(node, "call", "the iterator of this loop")
            end

            local args = a_tuple(node.exps, {
               node.exps[2] and exptypes[2],
               node.exps[3] and exptypes[3]
            })
            local exp1type = self:resolve_for_call(exptypes[1], args, false)

            if exp1type is PolyType then
               local _r, f: Type, Type
               _r, f = self:type_check_function_call(exp1, exp1type, args, 0, nil, nil, exp1, {node.exps[2], node.exps[3]})
               if f then
                  exp1type = f
               else
                  self.errs:add(exp1, "cannot resolve polymorphic function given arguments")
               end
            end

            if exp1type is FunctionType then
               -- TODO: an iterator whose parameters cannot take what a generic
               -- for passes (optional self, explicit iterator, state) is
               -- accepted, as exp1type.args is not checked against them. The
               -- fix is that check here.
               local last: Type = nil
               local rets = exp1type.rets
               for i, v in ipairs(node.vars) do
                  local r = rets.tuple[i]
                  if not r then
                     if rets.is_va then
                        r = last
                     else
                        r = self.feat_lax and an_unknown(v) or an_invalid(v)
                     end
                  end
                  local var = self:add_var(v, v.tk, r)
                  var.is_loop_control = i == 1

                  if self.collector then
                     self.collector.store_type(v.y, v.x, r)
                  end

                  last = r
               end
               local nrets = #rets.tuple
               if (not self.feat_lax) and (not rets.is_va and #node.vars > nrets) then
                  local at = node.vars[nrets + 1]
                  local n_values = nrets == 1 and "1 value" or tostring(nrets) .. " values"
                  self.errs:add(at, "too many variables for this iterator; it produces " .. n_values)
               end
            else
               if not (self.feat_lax and is_unknown(exp1type)) then
                  self.errs:add(exp1, "expression in for loop does not return an iterator")
               end
            end
         end,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            self:loop_end()
            return end_scope_and_none_type(self, node, children)
         end,
      },
      ["fornum"] = {
         before_statements = function(self: TypeChecker, node: Node, children: {Type})
            self:widen_all_unions(node)
            self:loop_begin()
            self:begin_scope(node)
            for bound = 2, 4 do
               if children[bound] then
                  local bound_t = resolve_tuple(children[bound])
                  if without_nil(self, node, bound_t, false) ~= nil then
                     self.errs:add_coded(node, Errors.about(Errors.make({ code = "for_bound", index = bound }), bound_t), "cannot use %s as the 'for' " .. (bound == 2 and "start" or bound == 3 and "limit" or "step"), bound_t)
                  end
               end
            end
            local from_t = self:to_structural(resolve_tuple(children[2]))
            local to_t = self:to_structural(resolve_tuple(children[3]))
            local step_t = children[4] and self:to_structural(children[4])
            local typename: TypeName = (from_t is IntegerType and
                                        to_t is IntegerType and
                                        (not step_t or step_t is IntegerType))
                                       and "integer"
                                       or  "number"
            local var = self:add_var(node.var, node.var.tk, a_type(node.var, typename, {}))
            var.is_loop_control = true
         end,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            self:loop_end()
            return end_scope_and_none_type(self, node, children)
         end,
      },
      ["return"] = {
         before = function(self: TypeChecker, node: Node)
            local never = self:find_var_type("@never")
            if never and not (never is NilType) then
               self.errs:add(node, "this function is declared 'never' and cannot return")
            end
            local rets = self:find_var_type("@return")
            if rets and rets is TupleType then
               for i, exp in ipairs(node.exps) do
                  exp.expected = rets.tuple[i]
               end
            end
         end,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            local got = children[1]
            assert(got is TupleType)
            local got_t = got.tuple
            local n_got = #got_t

            local expected = self:find_var_type("@return") as TupleType
            if not expected then
               -- if at the toplevel
               local module_type = resolve_tuple(got)
               if module_type is NominalType then
                  self:resolve_nominal(module_type)
                  self.module_type = module_type.resolved
               else
                  self.module_type = drop_constant_value(module_type)
               end

               expected = self:infer_at(node, got)
               self.st[2].vars["@return"] = { t = expected }
            end
            local expected_t = expected.tuple

            local what = "in return value"
            if expected.inferred_at then
               what = what .. inferred_msg(expected)
            end

            local n_expected = #expected_t
            local vatype: Type = nil
            if n_expected > 0 then
               vatype = expected.is_va and expected.tuple[n_expected]
            end

            -- A `return f(x)` is a tail call, which a check around it would
            -- end: the frame it would add moves the level an `error` in the
            -- callee blames. The callee's own returns are checked.
            -- TODO: check the values a `return f(x)` returns where f checks none
            -- of them itself (a Lua or C function with no declared returns). It
            -- waits on a way to see them without a frame of the check's own
            -- between f and the caller, which Lua gives only to a caller that
            -- does not tail call.
            if self.runtime_checks and not expected.inferred_at
               and not (#node.exps == 1 and node_is_funcall(node.exps[1])) then
               local checks: {string} = {}
               local checked = false
               for i, expected_i in ipairs(expected_t) do
                  local kinds: string = nil
                  -- TODO: check the values of a declared vararg return
                  -- (`...: T`) too, each as T. It waits on the check taking a
                  -- kind for all the values from a position on, which a spec
                  -- of one kind a position cannot say.
                  if not (expected.is_va and i == n_expected) then
                     kinds = self:runtime_kinds(resolve_tuple(expected_i))
                  end
                  checked = checked or kinds ~= nil
                  table.insert(checks, kinds or "-")
               end
               node.rt_rets = checked and table.concat(checks, ";") or nil
            end

            local spill_before = #self.errs.errors
            if n_got > n_expected and (not self.feat_lax) and not vatype then
               self.errs:add(node, what ..": excess return values, expected " .. n_expected .. " %s, got " .. n_got .. " %s", expected, got)
            end
            if n_got > #node.exps then
               self:assert_spill_hint(node.exps[#node.exps], spill_before)
            end

            if n_expected > 1
            and #node.exps == 1
            and node.exps[1].kind == "op"
            and (node.exps[1].op.op == "and" or node.exps[1].op.op == "or")
            and node.exps[1].discarded_tuple then
               self.errs:add_warning("hint", node.exps[1].e2, "additional return values are being discarded due to '" .. node.exps[1].op.op .. "' expression; suggest parentheses if intentional")
            end

            for i = 1, n_got do
               local e = expected_t[i] or vatype
               if e then
                  e = resolve_tuple(e)
                  local w = (node.exps[i] and node.exps[i].x)
                            and node.exps[i]
                            or  node.exps
                  assert(w and w.x)
                  self:assert_is_a(w, got_t[i], e, what)
               end
            end

            return NONE
         end,
      },
      ["variable_list"] = {
         after = function(self: TypeChecker, node: Node, children: {FirstClassType | TupleType}): Type
            local tuple = flat_tuple(node, children)

            for i, t in ipairs(tuple.tuple) do
               local ok, err = ensure_not_abstract(t, node[i])
               if not ok then
                  self.errs:add(node[i], err)
               end
            end

            return tuple
         end,
      },
      ["literal_table"] = {
         before = function(self: TypeChecker, node: Node)
            if node.expected then
               local decltype = self:to_structural(node.expected)

               if decltype is TypeVarType and decltype.constraint then
                  decltype = resolve_typedecl(self:to_structural(decltype.constraint))
               end

               if decltype is GenericType then
                  decltype = self:apply_generic(node, decltype)
               end

               if decltype is TupleTableType then
                  for _, child in ipairs(node) do
                     local n = child.key.constnum
                     if n and is_positive_int(n) then
                        child.value.expected = decltype.types[n as integer]
                     end
                  end
               elseif decltype is ArrayLikeType then
                  for _, child in ipairs(node) do
                     if child.key.constnum then
                        child.value.expected = decltype.elements
                     end
                  end
               elseif decltype is MapType then
                  for _, child in ipairs(node) do
                     child.key.expected = decltype.keys
                     child.value.expected = decltype.values
                  end
               end

               if decltype is RecordLikeType then
                  for _, child in ipairs(node) do
                     if child.key.conststr then
                        child.value.expected = decltype.fields[child.key.conststr]
                     end
                  end
               end
            end
         end,
         after = function(self: TypeChecker, node: Node, children: {LiteralTableItemType}): Type
            node.guard = narrowing.truthy

            if not node.expected then
               return infer_table_literal(self, node, children)
            end

            local decltype = self:to_structural(node.expected)

            local constraint: Type = nil
            if decltype is TypeVarType and decltype.constraint then
               constraint = resolve_typedecl(decltype.constraint)
               decltype = self:to_structural(constraint)
            end

            if decltype is GenericType then
               decltype = self:apply_generic(node, decltype)
            end

            local serves_in_place_of_function = false
            if decltype is UnionType then
               local single_table_type: Type = nil
               local single_table_rt: Type = nil

               if #decltype.types == 2 then
                  for _, t in ipairs(decltype.types) do
                     local ft = self:to_structural(t)
                     if ft is FunctionType
                        and #ft.args.tuple == 2
                        and ft.args.tuple[2].typename == "any"
                        and ft.rets.tuple[1]
                        and ft.rets.tuple[1].typename == "any" then
                        serves_in_place_of_function = true
                     end
                  end
               end

               for _, t in ipairs(decltype.types) do
                  local rt = self:to_structural(t)
                  if is_lua_table_type(rt) then
                     if single_table_type then
                        -- multiple table types in union, give up
                        single_table_type = nil
                        single_table_rt = nil
                        break
                     end

                     single_table_type = t
                     single_table_rt = rt
                  end
               end

               if single_table_type then
                  node.expected = single_table_type
                  decltype = single_table_rt
               end
            end

            if not is_lua_table_type(decltype) then
               return infer_table_literal(self, node, children)
            end

            if decltype is RecordLikeType then
               self:begin_scope()
               self:add_var(nil, "@self", a_typedecl(node, decltype))
               decltype = self:resolve_self(decltype, true)
               self:end_scope()
            end

            local force_array: Type = nil

            local seen_keys: {CheckableKey:Where} = {}

            for i, child in ipairs(children) do
               local cvtype = resolve_tuple(child.vtype)
               local ck = child.kname
               local cktype = child.ktype
               local n = node[i].key.constnum
               local b: boolean = nil
               if cktype is BooleanType then
                  b = (node[i].key.tk == "true")
               end
               self.errs:check_redeclared_key(node[i], node, seen_keys, ck or n or b)
               if decltype is RecordLikeType and ck then
                  local df = decltype.fields[ck]
                  if not df then
                     self.errs:add_coded_in_context(node[i], node, Errors.make({
                        code = "unknown_field",
                        key = ck,
                        subject = decltype.declname,
                        fields = value_fields(decltype),
                     }), "unknown field " .. ck)
                  else
                     if df is TypeDeclType then
                        self.errs:add_in_context(node[i], node, "cannot reassign a type")
                     else
                        self:mark_receiver(cvtype, df)
                        self:assert_is_a(node[i], cvtype, df, "in record field", ck)
                        self.receiver_field = nil
                     end
                  end
               elseif decltype is TupleTableType and cktype is NumericType then
                  local dt = decltype.types[n as integer]
                  if not n then
                     self.errs:add_in_context(node[i], node, "unknown index in tuple %s", decltype)
                  elseif not dt then
                     self.errs:add_in_context(node[i], node, "unexpected index " .. n .. " in tuple %s", decltype)
                  else
                     self:assert_is_a(node[i], cvtype, dt, node, "in tuple: at index " .. tostring(n), true)
                  end
               elseif decltype is ArrayLikeType and cktype is NumericType then
                  local cv = child.vtype
                  if cv is TupleType and i == #children and node[i].key_parsed == "implicit" then
                     -- need to expand last item in an array (e.g { 1, 2, 3, f() })
                     local spill_before: integer = nil
                     for ti, tt in ipairs(cv.tuple) do
                        if ti == 2 then spill_before = #self.errs.errors end
                        self:assert_is_a(node[i], tt, decltype.elements, node, "expected an array: at index " .. tostring(i + ti - 1), true)
                     end
                     if spill_before then
                        self:assert_spill_hint(node[i].value, spill_before)
                     end
                  else
                     self:assert_is_a(node[i], cvtype, decltype.elements, node, "expected an array: at index " .. tostring(n), true)
                  end
               elseif node[i].key_parsed == "implicit" then
                  if decltype is MapType then
                     self:assert_is_a(node[i].key, a_type(node[i].key, "integer", {}), decltype.keys, node, "in map key", true)
                     self:assert_is_a(node[i].value, cvtype, decltype.values, node, "in map value", true)
                  end
                  force_array = self:expand_type(node[i], force_array, child.vtype)
               elseif decltype is MapType then
                  force_array = nil
                  self:assert_is_a(node[i].key, cktype, decltype.keys, node, "in map key", true)
                  self:assert_is_a(node[i].value, cvtype, decltype.values, node, "in map value", true)
               else
                  self.errs:add_in_context(node[i], node, "unexpected key of type %s in table of type %s", cktype, decltype)
               end
            end

            local t = force_array and an_array(node, force_array) or node.expected
            t = self:infer_at(node, t)

            if decltype is RecordLikeType then
               node.omissions_checked = true
               if not serves_in_place_of_function then
                  refuse_omitted_fields(self, node, decltype, function(key: string): boolean
                     return seen_keys[key] ~= nil
                  end)
               end
            end

            if decltype is RecordType then
               local rt = self:to_structural(t)
               if rt is RecordType then
                  node.is_total, node.missing = total_record_check(decltype, seen_keys)
               end
            elseif decltype is MapType then
               local rt = self:to_structural(t)
               if rt is MapType then
                  local rk = self:to_structural(rt.keys)
                  node.is_total, node.missing = total_map_check(rk, seen_keys)
               end
            end

            if constraint then
               return constraint
            end

            return t
         end,
      },
      ["literal_table_item"] = {
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            local kname = node.key.conststr
            local ktype = children[1]
            local vtype = children[2]
            if node.itemtype then
               vtype = node.itemtype
               self:assert_is_a(node.value, children[2], node.itemtype, node)
            end
            -- If we assign a method to a table item, e.g.
            -- `local a = { myfunc = myobj.dothing }`
            -- the table item should not be treated as a method
            vtype = ensure_not_method(vtype)
            return a_type(node, "literal_table_item", {
               kname = kname,
               ktype = ktype,
               vtype = vtype,
            } as LiteralTableItemType)
         end,
      },
      ["local_function"] = {
         before = function(self: TypeChecker, node: Node)
            -- TODO: keep the facts a function expression keeps (`local_is_fixed`)
            -- here and in `global_function` and `record_function`, once narrowing
            -- holds its facts apart from declared types and a body is checked
            -- against the facts that can still hold when it runs; until then a
            -- declaration widens every narrowed name, which refuses
            -- `opts = opts or {}; local function f() return opts.x end`.
            self:widen_all_unions()
            if self.collector then
               self.collector.reserve_symbol_list_slot(node)
            end
            self:begin_scope(node)
            self:enter_function_body(node)
         end,
         before_statements = function(self: TypeChecker, node: Node, children: {Type})
            local args = children[2]
            assert(args is TupleType)

            self:add_internal_function_variables(node, args)
            self:add_function_definition_for_recursion(node, args, self.feat_arity)
         end,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            local args = children[2]
            assert(args is TupleType)
            local rets = children[3]
            assert(rets is TupleType)

            self:end_function_scope(node)

            local t = wrap_generic_if_typeargs(node.typeargs, a_function(node, {
               min_arity = self.feat_arity and node.min_arity or 0,
               args = args,
               rets = self.get_rets(rets),
               never = node.never,
            }))

            self:add_var(node, node.name.tk, t)
            return t
         end,
      },
      ["local_macroexp"] = {
         before = function(self: TypeChecker, node: Node)
            self:widen_all_unions()
            if self.collector then
               self.collector.reserve_symbol_list_slot(node)
            end
            self:begin_scope(node)
         end,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            local args = children[2]
            assert(args is TupleType)
            local rets = children[3]
            assert(rets is TupleType)

            self:end_function_scope(node)

            self:check_macroexp_arg_use(node.macrodef)

            local t = wrap_generic_if_typeargs(node.typeargs, a_function(node, {
               min_arity = self.feat_arity and node.macrodef.min_arity or 0,
               args = args,
               rets = self.get_rets(rets),
               macroexp = node.macrodef,
            }))

            self:add_var(node, node.name.tk, t)
            return t
         end,
      },
      ["global_function"] = {
         before = function(self: TypeChecker, node: Node)
            self:widen_all_unions()
            self:begin_scope(node)
            self:enter_function_body(node)
            if node.implicit_global_function then
               local typ = self:find_var_type(node.name.tk)
               if typ then
                  if typ is FunctionType then
                     node.is_predeclared_local_function = true
                  elseif not self.feat_lax then
                     self.errs:add(node, "cannot declare function: type of " .. node.name.tk .. " is %s", typ)
                  end
               elseif not self.feat_lax then
                  self.errs:add(node, "functions need an explicit 'local' or 'global' annotation")
               end
            end
         end,
         before_statements = function(self: TypeChecker, node: Node, children: {Type})
            local args = children[2]
            assert(args is TupleType)

            self:add_internal_function_variables(node, args)
            self:add_function_definition_for_recursion(node, args, self.feat_arity)
         end,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            local args = children[2]
            assert(args is TupleType)
            local rets = children[3]
            assert(rets is TupleType)

            self:end_function_scope(node)
            if node.is_predeclared_local_function then
               return NONE
            end

            self:add_global(node, node.name.tk, wrap_generic_if_typeargs(node.typeargs, a_function(node, {
               min_arity = self.feat_arity and node.min_arity or 0,
               args = args,
               rets = self.get_rets(rets),
               never = node.never,
            })))

            return NONE
         end,
      },
      ["record_function"] = {
         before = function(self: TypeChecker, node: Node)
            self:widen_all_unions()
            self:begin_scope(node)
            self:enter_function_body(node)
         end,
         before_arguments = function(self: TypeChecker, _node: Node, children: {Type})
            local rtype = self:to_structural(resolve_typedecl(children[1]))

            -- add type arguments from the record implicitly
            if rtype is GenericType then
               for _, typ in ipairs(rtype.typeargs) do
                  self:add_var(nil, typ.typearg, a_type(typ, "typearg", {
                     typearg = typ.typearg,
                     constraint = typ.constraint,
                  } as TypeArgType))
               end
            end
         end,
         before_statements = function(self: TypeChecker, node: Node, children: {Type})
            local args = children[3]
            assert(args is TupleType)
            local rets = children[4]
            assert(rets is TupleType)

            local t = children[1]
            local rtype = self:to_structural(resolve_typedecl(t))

            if rtype is GenericType then
               rtype = rtype.t
            end

            do
               local ok, err = ensure_not_abstract(t)
               if not ok then
                  self.errs:add(node, err)
               end
            end

            if self.feat_lax and rtype is UnknownType then
               return
            end

            if rtype is EmptyTableType then
               edit_type(rtype, rtype, "record")
               local r = rtype as RecordType
               r.fields = {}
               r.field_order = {}
            end

            if not rtype is RecordLikeType then
               self.errs:add(node, "not a record: %s", rtype)
               return
            end

            local selftype = self:get_self_type(node.fn_owner)
            if node.is_method then
               if not selftype then
                  self.errs:add(node, "could not resolve type of self")
                  return
               end
               args.tuple[1] = a_self(node, selftype)
               self:add_var(nil, "self", selftype)
               self:add_var(nil, "@self", a_typedecl(node, selftype))
               if self.collector then
                  self.collector.add_to_symbol_list(node.fn_owner, "self", selftype)
               end
            end

            local fn_type = wrap_generic_if_typeargs(node.typeargs, a_function(node, {
               min_arity = self.feat_arity and node.min_arity or 0,
               is_method = node.is_method,
               args = args,
               rets = self.get_rets(rets),
               never = node.never,
               is_record_function = true,
            }))

            local open_t, open_v, owner_name = self:find_record_to_extend(node.fn_owner)
            local open_k = owner_name .. "." .. node.name.tk
            local rfieldtype = rtype.fields[node.name.tk]
            if rfieldtype then
               rfieldtype = self:to_structural(rfieldtype)

               if open_v and open_v.implemented and open_v.implemented[open_k] then
                  self.errs:redeclaration_warning(node, node.name.tk, "function")
               end

               if fn_type is GenericType and not rfieldtype is GenericType then
                  self:begin_scope()
                  fn_type = self:apply_generic(node, fn_type) as FunctionType
                  self:end_scope()
               end

               local ok, err = self:same_type(fn_type, rfieldtype)
               if not ok then
                  if rfieldtype is PolyType then
                     self.errs:add_prefixing(node, err, "type signature does not match declaration: field has multiple function definitions (such polymorphic declarations are intended for Lua module interoperability): ")
                     return
                  end

                  local shortname = selftype and show_type(selftype) or owner_name
                  local msg = "type signature of '" .. node.name.tk .. "' does not match its declaration in " .. shortname .. ": "
                  self.errs:add_prefixing(node, err, msg, nil,
                     Errors.make({ signature_of = node.name.tk, declared_in = shortname }))
                  return
               end
            else
               if open_t and open_t is GenericType then
                  open_t = open_t.t
               end
               if self.feat_lax or rtype == open_t then
                  -- TODO is this needed?
                  -- if fn_type is GenericType then
                  --    fn_type = fresh_typeargs(self, fn_type)
                  -- end

                  rtype.fields[node.name.tk] = fn_type
                  table.insert(rtype.field_order, node.name.tk)

                  if self.collector then
                     self.env.reporter:add_field(rtype, node.name.tk, fn_type)
                  end
               else
                  self.errs:add(node, "cannot add undeclared function '" .. node.name.tk .. "' outside of the scope where '" .. owner_name .. "' was originally declared")
                  return
               end

            end

            if open_v then
               if not open_v.implemented then
                  open_v.implemented = {}
               end
               open_v.implemented[open_k] = true
            end

            self:add_internal_function_variables(node, args)
         end,
         after = function(self: TypeChecker, node: Node, _children: {Type}): Type
            self:end_function_scope(node)
            return NONE
         end,
      },
      ["function"] = {
         before = function(self: TypeChecker, node: Node)
            self:widen_all_unions(node)
            self:begin_scope(node)
            self:enter_function_body(node)

            local expected = node.expected
            if expected and expected is FunctionType then
               for i, t in ipairs(expected.args.tuple) do
                  if node.args[i] then
                     node.args[i].expected = t
                  end
               end
            end

            local context = not self.feat_lax and context_function_type(self, expected)
            if context then
               local cargs = context.args.tuple
               for i, arg in ipairs(node.args) do
                  local t = cargs[i]
                  if arg.tk == "..." and not (context.args.is_va and i == #cargs) then
                     t = nil
                  end
                  if t and not (t is SelfType or t is InvalidType) and not has_unbound_typevars(self, t) then
                     arg.context_type = t
                  end
               end
               node.context_never = node.rets_omitted and context.never
               if node.rets_omitted and not has_unbound_typevars(self, context.rets) then
                  local rets = a_tuple(node, {})
                  for i, r in ipairs(context.rets.tuple) do
                     rets.tuple[i] = r
                  end
                  rets.is_va = context.rets.is_va
                  node.context_rets = rets
               end
            end
         end,
         before_statements = function(self: TypeChecker, node: Node, children: {Type})
            local args = children[1]
            assert(args is TupleType)

            self:add_internal_function_variables(node, args)
            if node.context_rets then
               self:add_var(nil, "@return", node.context_rets)
            end
         end,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            local args = children[1]
            assert(args is TupleType)
            local rets = children[2]
            assert(rets is TupleType)

            self:end_function_scope(node)

            if node.context_rets then
               rets = node.context_rets
               local required = #rets.tuple - (rets.is_va and 1 or 0)
               local body = node.body
               if node.context_never then
                  if not flow.ends_body(body as flow.Node) then
                     self.errs:add(node, "missing never: this function can reach its end, where a function that never returns is expected of it: end it with a call that never returns, or declare its return types")
                  end
               elseif required > 0 and not flow.ends_body(body as flow.Node) then
                  self.errs:add(node, "missing return: this function can reach its end, where %s is expected of it: return a value there, or declare its return types", rets)
               end
            end

            return wrap_generic_if_typeargs(node.typeargs, a_function(node, {
               min_arity = self.feat_arity and node.min_arity or 0,
               args = args,
               rets = self.get_rets(rets),
               never = node.never or node.context_never,
            }))
         end,
      },
      ["macroexp"] = {
         before = function(self: TypeChecker, node: Node)
            self:widen_all_unions(node)
            self:begin_scope(node)
         end,
         before_exp = function(self: TypeChecker, node: Node, children: {Type})
            local args = children[1]
            assert(args is TupleType)

            self:add_internal_function_variables(node, args)
         end,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            local args = children[1]
            assert(args is TupleType)
            local rets = children[2]
            assert(rets is TupleType)

            self:end_function_scope(node)
            return wrap_generic_if_typeargs(node.typeargs, a_function(node, {
               min_arity = self.feat_arity and node.min_arity or 0,
               args = args,
               rets = rets,
               never = node.never,
            }))
         end,
      },
      ["cast"] = {
         after = function(_self: TypeChecker, node: Node, _children: {Type}): Type
            return node.casttype
         end
      },
      ["paren"] = {
         before = function(_self: TypeChecker, node: Node)
            node.e1.expected = node.expected
         end,
         after = function(_self: TypeChecker, node: Node, children: {Type}): Type
            node.guard = node.e1 and node.e1.guard
            return resolve_tuple(children[1])
         end,
      },
      ["op"] = {
         before = function(self: TypeChecker, node: Node)
            self:begin_scope()
            local operator = node.op.op
            if operator == "and" or operator == "or" then
               node.e1.want_clock, node.e2.want_clock = true, true
            elseif operator == "@funcall" and node.e1.kind == "variable" and node.e1.tk == "assert" and node.e2[1] then
               node.e2[1].want_clock, node.e2[#node.e2].want_clock = true, true
            end
            if node.expected then
               if node.op.op == "and" then
                  node.e2.expected = node.expected
               elseif node.op.op == "or" then
                  node.e1.expected = node.expected
                  if not (node.e2.kind == "literal_table" and #node.e2 == 0) then
                     node.e2.expected = node.expected
                  end
               end
            end
            if node.op.op == "not" then
               node.e1.expected = a_type(node, "boolean_context", {})
            end
         end,
         before_e2 = function(self: TypeChecker, node: Node, children: {Type})
            local e1type = children[1]

            if node.op.op == "and" then
               -- The left operand read for its truthiness: a local, or a field
               -- of one.
               local e1_place = not node.e1.guard and place_of(node.e1)
               local e1_type = e1_place and resolve_tuple(e1type)
               local e1_typ = e1_type and without_nil(self, node.e1, e1_type, true)
               if e1_typ then
                  node.e1.guard = narrowing.type_is(node.e1, e1_place, e1_typ as narrowing.Type)
               end
               self:apply_guard(node, node.e1.guard)
            elseif node.op.op == "or" then
               self:apply_guard(node, narrowing.negate(node, node.e1.guard))

               -- special-case `v is T and v or _` when T is a truthy type
               if node.e1.kind == "op" and node.e1.op.op == "and"
                  and node.e1.e1.kind == "op" and node.e1.e1.op.op == "is"
                  and node.e1.e2.kind == "variable"
                  and node.e1.e2.tk == node.e1.e1.e1.tk
                  and node.e1.e1.e2.casttype.typename ~= "boolean"
                  and node.e1.e1.e2.casttype.typename ~= "nil"
               then
                  self:apply_guard(node, narrowing.negate(node, narrowing.type_is(node, narrowing.local_place(node.e1.e1.e1.tk), node.e1.e1.e2.casttype as narrowing.Type)))
               end

            elseif node.op.op == "@funcall" then
               if e1type is GenericType then
                  e1type = self:apply_generic(node, e1type)
               end
               if e1type is FunctionType then
                  local argdelta = (node.e1.op and node.e1.op.op == ":") and -1 or 0
                  if node.expected then
                     local has_literal = false
                     local lat = argdelta
                     for _, typ in ipairs(e1type.args.tuple) do
                        lat = lat + 1
                        local arg = node.e2[lat]
                        if arg and arg.kind == "literal_table" and has_unbound_typevars(self, typ) then
                           has_literal = true
                        end
                     end
                     if has_literal then
                        -- Try the result-first binding in a scratch scope: if
                        -- it refuses a variable argument, bind from those first.
                        local vars_at: {integer:Type} = {}
                        local refused = false
                        local st = self.st
                        table.insert(st, { vars = {} })
                        self:is_a(e1type.rets, node.expected)
                        lat = argdelta
                        for _, typ in ipairs(e1type.args.tuple) do
                           lat = lat + 1
                           local arg = node.e2[lat]
                           if arg and arg.kind == "variable" then
                              local given = self:find_var_type(arg.tk)
                              if given and not given is GenericType and not has_unbound_typevars(self, given) then
                                 vars_at[lat] = given
                                 if not self:is_a(given, self:infer_at(arg, typ)) then
                                    refused = true
                                 end
                              end
                           end
                        end
                        table.remove(st)
                        if refused then
                           lat = argdelta
                           for _, typ in ipairs(e1type.args.tuple) do
                              lat = lat + 1
                              if vars_at[lat] then
                                 bind_typevars_from(self, vars_at[lat], typ)
                              end
                           end
                        end
                     end
                     -- this forces typevars in function return types
                     self:is_a(e1type.rets, node.expected)
                  end
                  local e1args = e1type.args.tuple
                  local at = argdelta
                  for _, typ in ipairs(e1args) do
                     at = at + 1
                     if node.e2[at] then
                        node.e2[at].expected = self:infer_at(node.e2[at], typ)
                     end
                  end
                  if e1type.args.is_va then
                     local typ = e1args[#e1args]
                     for i = at + 1, #node.e2 do
                        node.e2[i].expected = self:infer_at(node.e2[i], typ)
                     end
                  end
                  -- TODO: a literal before the arguments binding its type
                  -- variables (`map(function(x) ... end, xs)`) reads none,
                  -- and a call whose result goes where `any` is expected
                  -- (`print(apply(v, function(x) ... end))`) has them bound
                  -- to any by its expected returns above; both wait on
                  -- checking a literal after the arguments that bind them.
                  for k, arg in ipairs(node.e2) do
                     if arg.kind == "function" and arg.expected and has_unbound_typevars(self, arg.expected) then
                        for j = 1, k - 1 do
                           node.e2[j].binds_context = true
                        end
                     end
                  end
               elseif e1type is PolyType then
                  -- TODO: an overload with a generic function gives no
                  -- context; it waits on applying each generic member's
                  -- type variables, as a single generic callee's are.
                  local argdelta = (node.e1.op and node.e1.op.op == ":") and -1 or 0
                  for k, arg in ipairs(node.e2) do
                     if arg.kind == "function" then
                        local agreed: Type = nil
                        for _, f in ipairs(e1type.types) do
                           local p: Type = nil
                           if f is FunctionType then
                              local fargs = f.args.tuple
                              p = fargs[k - argdelta]
                              if not p and f.args.is_va then
                                 p = fargs[#fargs]
                              end
                           end
                           if not p or (agreed and not self:same_type(p, agreed)) then
                              agreed = nil
                              break
                           end
                           agreed = p
                        end
                        if agreed then
                           arg.expected = self:infer_at(arg, agreed)
                        end
                     end
                  end
               end
            elseif node.op.op == "@index" then
               if e1type is MapType then
                  node.e2.expected = e1type.keys
               end
            end
         end,
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            self:end_scope()

            -- given a and b: may be TupleType
            local ga: Type = children[1]
            local gb: Type = children[3]

            -- unary a and b: not TupleType
            local ua = resolve_tuple(ga)
            local ub: Type = nil

            -- resolved a and b: not NominalType
            local ra: Type = self:to_structural(ua)
            local rb: Type = nil

            if ra.typename == "circular_require" or (ra is TypeDeclType and ra.def and ra.def.typename == "circular_require") then
               return self.errs:invalid_at(node, "cannot dereference a type from a circular require")
            end

            if node.op.op == "@funcall" then
               if self.feat_lax and is_unknown(ua) then
                  if node.e1.op and node.e1.op.op == ":" and node.e1.e1.kind == "variable" then
                     self.errs:add_unknown_dot(node, node.e1.e1.tk .. "." .. node.e1.e2.tk)
                  end
               end
               assert(gb is TupleType)
               local t = self:type_check_funcall(node, ua, gb)
               -- `assert` and `type` run no code of the program's, and a call
               -- of a function that never returns has no code after it to
               -- see what was dropped. A call of another function runs code,
               -- and drops what is known after it.
               local special = resolve_for_special_function(ua)
               local handler = special and special.special_function_handler
               if handler == "assert" or handler == "type" or (special and special.never)
                  or self:runs_no_code(node, ra, gb) then
                  node.runs_no_code = true
               else
                  self:drop_all(node, "call")
               end
               return t

            elseif node.op.op == "as" then
               local ok, err = ensure_not_abstract(ra)
               if not ok then
                  return self.errs:invalid_at(node.e1, err)
               end
               return gb

            elseif node.op.op == "is" and ra is TypeDeclType then
               return self.errs:invalid_at(node, "can only use 'is' on variables, not types")
            end

            local ok, err = ensure_not_abstract(ra)
            if not ok then
               return self.errs:invalid_at(node.e1, err)
            end
            if ra is TypeDeclType and ra.def.typename == "record" then
               ra = ra.def
            end

            -- "@funcall" and "as" are the only operators that use tuples, and always in the b position;
            -- after they are handled above, we can resolve b's tuple and only use that instead.
            if gb then
               ub = resolve_tuple(gb)
               rb = self:to_structural(ub)
               ok, err = ensure_not_abstract(rb)
               if not ok then
                  return self.errs:invalid_at(node.e2, err)
               end
               if rb is TypeDeclType and rb.def.typename == "record" then
                  rb = rb.def
               end
            end

            if node.op.op == "." then
               node.receiver = ua

               assert(node.e2.kind == "identifier")
               local bnode: Node = node_at(node.e2, {
                  tk = node.e2.tk,
                  kind = "string",
               })
               local btype = a_type(node.e2, "string", { literal = node.e2.tk } as StringType)
               bnode.dropped = node.e1.dropped
               self.index_metamethod = false
               local t = self:type_check_index(node.e1, bnode, ua, btype)
               if self.index_metamethod then
                  self.index_metamethod = false
                  self:drop_all(node, "operator", "." .. node.e2.tk .. " served by __index")
               end

               -- A prior narrow recorded for this field is read back
               -- here, which is what lets a chain like `o.sub.x` see a
               -- narrow recorded on `o.sub` through `o.sub`'s own
               -- return value. A truthy read here (`if x.field then`,
               -- or any other read in a boolean context) then sets the
               -- fact for reads that follow; `==`/`~=` nil and `assert`
               -- set it at their own call sites, keyed the same way.
               local field_place = place_of(node)
               if field_place then
                  local narrowed = self:find_var_type(field_place.key, "check_only")
                  if narrowed then
                     if #self.loops > 0 and not node.is_lvalue then
                        self:record_read(node, field_place.key, t)
                     end
                     t = narrowed
                  elseif not node.is_lvalue then
                     self:note_dropped(node, field_place.key)
                  end
                  node.field_type = t
                  if node.expected and node.expected.typename == "boolean_context" then
                     local typ = without_nil(self, node, t, true)
                     if typ then
                        node.guard = narrowing.type_is(node, field_place, typ as narrowing.Type)
                     end
                  end
               end

               if t.needs_compat and self.gen_compat ~= "off" then
                  -- only apply to a literal use, not a propagated type
                  if node.e1.kind == "variable" and node.e2.kind == "identifier" then
                     local key = node.e1.tk .. "." .. node.e2.tk
                     node.kind = "variable"
                     node.tk = "_tl_" .. node.e1.tk .. "_" .. node.e2.tk
                     self.all_needs_compat[key] = true
                  end
               end

               return t
            end

            if node.op.op == "@index" then
               node.key_kind = rb and rb.typename
               self.index_metamethod = false
               local t = self:type_check_index(node.e1, node.e2, ua, ub)
               if self.index_metamethod then
                  self.index_metamethod = false
                  self:drop_all(node, "operator", "[...] served by __index")
               end
               return t
            end

            if node.op.op == "is" then
               local add_type = false
               if rb is IntegerType then
                  self.all_needs_compat["math"] = true
               elseif not rb is NilType then
                  add_type = true
               end
               if ra is TypeDeclType then
                  self.errs:add(node, "can only use 'is' on variables, not types")
               elseif node.e1.kind == "variable" then
                  local has_meta: boolean
                  if rb is UnionType then
                     has_meta = convert_is_of_union_to_or_of_is(self, node, ra, rb)
                  else
                     local _, meta = self:check_metamethod(node, "__is", ra, resolve_typedecl(rb), ua, ub)
                     node.guard = narrowing.type_is(node, narrowing.local_place(node.e1.tk), ub as narrowing.Type)
                     has_meta = not not meta
                     if meta and self.metamethod_ran then
                        self:drop_all(node, "operator", "is")
                     end
                  end
                  if has_meta then
                     add_type = false
                  end
               else
                  self.errs:add(node, "can only use 'is' on variables")
               end
               if add_type then
                  self.all_needs_compat["type"] = true
               end
               return a_type(node, "boolean", {})
            end

            if node.op.op == ":" then
               node.receiver = ua

               -- we handle ':' separately from '.' because ':' is specific to records,
               -- so we produce different error messages
               if self.feat_lax and (is_unknown(ua) or ua is TypeVarType) then
                  if node.e1.kind == "variable" then
                     self.errs:add_unknown_dot(node.e1, node.e1.tk .. "." .. node.e2.tk)
                  end
                  return an_unknown(node)
               end

               node.e2.dropped = node.e1.dropped
               local t, e, details = self:match_record_key(ra, node.e1, node.e2.conststr or node.e2.tk)
               if not t then
                  return self.errs:invalid_key_at(node.e2, Errors.about(details, ua), e, ua)
               end

               return t
            end

            if node.op.op == "not" then
               node.guard = narrowing.negate(node, node.e1.guard)
               return a_type(node, "boolean", {})
            end

            if node.op.op == "and" then
               node.guard = narrowing.both(node, self:guard_before(node.e1, node.e2), node.e2.guard)
               local t = discard_tuple(node, ub, gb)
               -- TODO: a left operand that may be false (a boolean, or a union
               -- with boolean) ends the `and` as false, which is not modelled:
               -- `(flag and "x") .. "a"` passes. Model it once the checker has
               -- a false literal type it can unite and narrow (`a or b` and the
               -- truthiness facts would drop it as they drop nil), so that
               -- `boolean` is no longer taken for a truthy-or-falsy unknown.
               if t is InvalidType then
                  return t
               end
               if without_nil(self, node, ua, false) and not admits_nil(self, node, t) then
                  local members: {Type} = {}
                  if t is UnionType then
                     for _, m in ipairs(t.types) do
                        table.insert(members, m)
                     end
                  else
                     members[1] = t
                  end
                  table.insert(members, a_type(node, "nil", {}))
                  t = a_union(node, members)
               end
               return t
            end

            if node.op.op == "or" then
               local t: Type = nil

               local expected = node.expected and self:to_structural(resolve_tuple(node.expected))

               -- a reaches the result only when truthy, so never as nil.
               -- b of type nil is left to its own case below, which
               -- keeps a's type whole.
               local a_sans_nil = not ub is NilType and without_nil(self, node, ua, false)
               if a_sans_nil then
                  ua = a_sans_nil
                  ra = self:to_structural(ua)
               end

               if ub is NilType then
                  node.guard = nil
                  t = ua

               elseif is_lua_table_type(ra) and rb is EmptyTableType then
                  node.guard = nil
                  t = ua

               elseif ((ra is EnumType and rb is StringType and self:is_a(rb, ra))
                  or (ra is StringType and rb is EnumType and self:is_a(ra, rb))) then
                  node.guard = nil
                  t = (ra is EnumType and ra or rb)

               elseif expected and expected is UnionType then
                  -- must be checked after string/enum above
                  node.guard = narrowing.either(node, self:guard_before(node.e1, node.e2), node.e2.guard)
                  -- TODO: two different table types still refuse "cannot
                  -- discriminate a union between multiple table types"
                  -- when the context is a declared `T | nil` (an optional
                  -- field): `{ env = given or default }` with both a
                  -- `{string:string}` variable, or a record and a
                  -- literal of it, needs the union to take them as one
                  -- member. cosmic's own code binds the `or` to a local
                  -- first.
                  local u = unite(node, {a_sans_nil or ra, rb}, true)
                  if u is UnionType then
                     ok, err = is_valid_union(u)
                     if not ok then
                        u = err and self.errs:invalid_at(node, err, u) or an_invalid(node)
                     end
                  end
                  t = u

               -- prefer the union type if it already works and the other one isn't a union
               elseif ra is UnionType and not (rb is UnionType) and self:is_a(rb, ra) then
                  -- convert it to the union type
                  t = drop_constant_value(ra)

               elseif rb is UnionType and not (ra is UnionType) and self:is_a(ra, rb) then
                  -- convert it to the union type
                  t = drop_constant_value(rb)

               else
                  -- these compare using the unresolved type to prevent nominal types resolving into
                  -- each other.
                  local a_ge_b = self:is_a(ub, ua)
                  local b_ge_a = self:is_a(ua, ub)
                  node.guard = narrowing.either(node, self:guard_before(node.e1, node.e2), node.e2.guard)
                  -- TODO: compare the unresolved types (ua, ub) here, as a_ge_b and
                  -- b_ge_a do, not the resolved ra and rb. The change is untried
                  -- against a table literal and a nominal type, which it must
                  -- keep working with.
                  local is_same = self:same_type(ra, rb)

                  -- we can have some types that can be converted into either
                  local ambiguous = a_ge_b and b_ge_a and not is_same

                  -- prefer a type that we can easily work out rather than defaulting to the expected one
                  -- (the expected one might need to be collapsed later with special functions)
                  if is_same then
                     t = ua
                  elseif (a_ge_b or b_ge_a) and not ambiguous then
                     local larger_type = b_ge_a and ub or ua
                     t = larger_type
                  elseif expected and self:is_a(ua, expected) and self:is_a(ub, expected) then
                     t = self:infer_at(node, expected)
                  end

                  if ambiguous and not t then
                     if TL_DEBUG then
                        self.errs:add_warning("debug", node, "the resulting type is ambiguous: %s or %s", ua, ub)
                        self.errs:add_warning("debug", node, "currently choosing %s", ub)
                     end
                     -- workaround to keep existing code working
                     t = ub
                  end
                  if t then
                     t = drop_constant_value(t)
                  end

                  if expected and expected is BooleanContextType then
                     t = a_type(node, "boolean", {})
                  end
               end

               if t then
                  return discard_tuple(node, t, gb)
               end
               -- else fallthrough to general binop handler
            end

            if node.op.op == "==" or node.op.op == "~=" then
               if is_lua_table_type(ra) and is_lua_table_type(rb) then
                  self:check_metamethod(node, binop_to_metamethod[node.op.op], ra, rb, ua, ub)
               end
               -- Two values that may carry `__eq`: the comparison may run it.
               if self:may_be_table(ra) and self:may_be_table(rb)
                  and (self:may_dispatch(ra, "__eq") or self:may_dispatch(rb, "__eq")) then
                  self:drop_all(node, "operator", node.op.op)
               end

               if ra is EnumType and rb is StringType then
                  if not (rb.literal and ra.enumset[rb.literal]) then
                     return self.errs:invalid_at(node, "%s is not a member of %s", ub, ua)
                  end
               elseif ra is TupleTableType and rb is TupleTableType and #ra.types ~= #rb.types then
                  return self.errs:invalid_at(node, "tuples are not the same size")
               elseif self:is_a(ub, ua) or ua is TypeVarType then
                  -- Comparing a variable against nil is an exact type
                  -- test: __eq never fires with a nil operand. So it
                  -- carries a type test, whose negation narrows, rather
                  -- than a value test, whose negation says nothing. The
                  -- same test on `x.field` narrows the field, placed
                  -- the same way a truthy read on it is -- but only
                  -- when the field's own declared type admits nil (see
                  -- this record's note).
                  local e1_place = place_of(node.e1)
                  if e1_place and not (node.e1.kind == "variable")
                     and not admits_nil(self, node, ua) then
                     e1_place = nil
                  end
                  if e1_place and rb is NilType then
                     local f = narrowing.type_is(node, e1_place, rb as narrowing.Type)
                     node.guard = node.op.op == "==" and f or narrowing.negate(node, f)
                  elseif node.op.op == "==" and e1_place then
                     node.guard = narrowing.value_is(node, e1_place, ub as narrowing.Type)
                  end
               elseif self:is_a(ua, ub) or ub is TypeVarType then
                  local e2_place = place_of(node.e2)
                  if e2_place and not (node.e2.kind == "variable")
                     and not admits_nil(self, node, ub) then
                     e2_place = nil
                  end
                  if e2_place and ra is NilType then
                     local f = narrowing.type_is(node, e2_place, ra as narrowing.Type)
                     node.guard = node.op.op == "==" and f or narrowing.negate(node, f)
                  elseif node.op.op == "==" and e2_place then
                     node.guard = narrowing.value_is(node, e2_place, ua as narrowing.Type)
                  end
               elseif self.feat_lax and (is_unknown(ua) or is_unknown(ub)) then
                  return an_unknown(node)
               else
                  return self.errs:invalid_at(node, "types are not comparable for equality: %s and %s", ua, ub)
               end

               local call, name = node.e1, node.e2
               if not call.type_of then
                  call, name = node.e2, node.e1
               end
               local arg = call.type_of
               if arg and name.kind == "string" and lua_type_names[name.conststr] ~= name.conststr then
                  self.errs:add(name, "type() never answers \"" .. name.conststr .. "\": it answers nil, boolean, number, string, table, function, thread or userdata, and math.type tells \"integer\" from \"float\"")
               elseif arg and place_of(arg) and name.kind == "string" then
                  -- A local, or a field of one, whose type now is what the
                  -- argument was checked as.
                  local place = place_of(arg)
                  local t = #place.fields == 0 and self:find_var_type(arg.tk, "check_only") or arg.field_type
                  local typ = t and type_test_type(self, node, t, name.conststr)
                  if typ then
                     local f = narrowing.type_is(node, place, typ as narrowing.Type)
                     node.guard = node.op.op == "==" and f or narrowing.negate(node, f)
                  end
               end

               return a_type(node, "boolean", {})
            end

            do
               local op = node.op.op
               if op ~= "or" and ((node.op.arity == 1 and unop_types[op]) or (node.op.arity == 2 and binop_types[op])) then
                  if node.op.arity == 1 then
                     if without_nil(self, node, ua, false) ~= nil then
                        return self.errs:invalid_coded(node, Errors.about(Errors.make({ code = "operator_unary", operator = op }), ua), "cannot use operator '" .. op:gsub("%%", "%%%%") .. "' on type %s", ua)
                     end
                  elseif without_nil(self, node, ua, false) ~= nil or without_nil(self, node, ub, false) ~= nil then
                     return self.errs:invalid_coded(node, Errors.operands(Errors.make({ code = "operator_binary", operator = op }), ua, ub), "cannot use operator '" .. op:gsub("%%", "%%%%") .. "' for types %s and %s", ua, ub)
                  end
               end
            end

            if node.op.arity == 1 and unop_types[node.op.op] then
               if ra is UnionType then
                  ra = unite(node, ra.types, true) -- squash unions of string constants
               end

               local types_op = unop_types[node.op.op]

               local tn = types_op[ra.typename]
               local t = tn and a_type(node, tn, {})

               -- we need to check if we have a macroexp that overrides any interfaces first
               local meta_on_operator: integer = nil
               if not t then
                  local mt_name = unop_to_metamethod[node.op.op]
                  if mt_name then
                     t, meta_on_operator = self:check_metamethod(node, mt_name, ra, nil, ua, nil)
                     if meta_on_operator and self.metamethod_ran then
                        self:drop_all(node, "operator", node.op.op)
                     end
                  end
               end

               if not t and ra is RecordLikeType then
                  if ra.interface_list then
                     for _, iface in ipairs(ra.interface_list) do
                        if types_op[iface.typename] then
                           t = a_type(node, types_op[iface.typename], {})
                           break
                        end
                     end
                  end
               end

               if ra is MapType then
                  if ra.keys.typename == "number" or ra.keys.typename == "integer" then
                      self.errs:add_warning("hint", node, "using the '#' operator on a map with numeric key type may produce unexpected results")
                  else
                      self.errs:add(node, "using the '#' operator on this map will always return 0")
                  end
               end

               if node.op.op == "~" and self.gen_target == "5.1" then
                  if meta_on_operator then
                     self.all_needs_compat["mt"] = true
                     convert_node_to_compat_mt_call(node, unop_to_metamethod[node.op.op], 1, node.e1)
                  else
                     self.all_needs_compat["bit32"] = true
                     convert_node_to_compat_call(node, "bit32", "bnot", node.e1)
                  end
               end

               if not t then
                  return self.errs:invalid_coded(node, Errors.about(Errors.make({ code = "operator_unary", operator = node.op.op }), ua), "cannot use operator '" .. node.op.op:gsub("%%", "%%%%") .. "' on type %s", ua)
               end

               if not (t is BooleanType or is_unknown(t)) then
                  node.guard = narrowing.truthy
               end

               return t
            end

            if node.op.arity == 2 and binop_types[node.op.op] then
               if node.op.op == "or" then
                  node.guard = narrowing.either(node, self:guard_before(node.e1, node.e2), node.e2.guard)
               end

               if ra is UnionType then
                  ra = unite(ra, ra.types, true) -- squash unions of string constants
               end
               if rb is UnionType then
                  rb = unite(rb, rb.types, true) -- squash unions of string constants
               end

               local types_op = binop_types[node.op.op]

               local tn = types_op[ra.typename] and types_op[ra.typename][rb.typename]
               local t = tn and a_type(node, tn, {})

               local meta_on_operator: integer = nil
               if not t then
                  local mt_name = binop_to_metamethod[node.op.op]
                  local flipped = false
                  if not mt_name then
                     mt_name = flip_binop_to_metamethod[node.op.op]
                     if mt_name then
                        flipped = true
                        ra, rb = rb, ra
                        ua, ub = ub, ua
                     end
                  end
                  if mt_name then
                     t, meta_on_operator = self:check_metamethod(node, mt_name, ra, rb, ua, ub, flipped)
                     if meta_on_operator and self.metamethod_ran then
                        self:drop_all(node, "operator", node.op.op)
                     end
                     if flipped and not meta_on_operator then
                        ra, rb = rb, ra
                        ua, ub = ub, ua
                     end
                  end
               end

               if (not t) and ua is NominalType and ub is NominalType and not meta_on_operator then
                  if self:is_a(ua, ub) then
                     t = ua
                  end
               end

               if types_op == numeric_binop or node.op.op == ".." then
                  node.guard = narrowing.truthy
               end

               if node.op.op == "//" and self.gen_target == "5.1" then
                  if meta_on_operator then
                     self.all_needs_compat["mt"] = true
                     convert_node_to_compat_mt_call(node, "__idiv", meta_on_operator, node.e1, node.e2)
                  else
                     local div: Node = node_at(node, { kind = "op", op = an_operator(node, 2, "/"), e1 = node.e1, e2 = node.e2 })
                     convert_node_to_compat_call(node, "math", "floor", div)
                  end
               elseif bit_operators[node.op.op] and self.gen_target == "5.1" then
                  if meta_on_operator then
                     self.all_needs_compat["mt"] = true
                     convert_node_to_compat_mt_call(node, binop_to_metamethod[node.op.op], meta_on_operator, node.e1, node.e2)
                  else
                     self.all_needs_compat["bit32"] = true
                     convert_node_to_compat_call(node, "bit32", bit_operators[node.op.op], node.e1, node.e2)
                  end
               end

               if not t then
                  if node.op.op == "or" then
                     local u = unite(node, {ua, ub})
                     if u is UnionType and is_valid_union(u) then
                        self.errs:add_warning("hint", node, "if a union type was intended, consider declaring it explicitly")
                     end
                  end
                  return self.errs:invalid_coded(node, Errors.operands(Errors.make({ code = "operator_binary", operator = node.op.op }), ua, ub), "cannot use operator '" .. node.op.op:gsub("%%", "%%%%") .. "' for types %s and %s", ua, ub)
               end

               return t
            end

            error("unknown node op " .. node.op.op)
         end,
      },
      ["variable"] = {
         after = function(self: TypeChecker, node: Node, _children: {Type}): Type
            if node.tk == "..." then
               local va_sentinel = self:find_var_type("@is_va")
               if not va_sentinel or va_sentinel is NilType then
                  return self.errs:invalid_at(node, "cannot use '...' outside a vararg function")
               end
            end

            local t: Type
            if node.tk == "_G" then
               t, node.attribute = self:simulate_g()
               t.f, t.x, t.y = node.f, node.x, node.y
            else
               local use: VarUse = node.is_lvalue and "lvalue" or "use"
               t, node.attribute = self:find_var_type(node.tk, use)
            end
            if not t then
               if self.feat_lax then
                  self.errs:add_unknown(node, node.tk)
                  return an_unknown(node)
               end

               return self.errs:invalid_coded(node, Errors.make({ code = "unknown_variable", variable = node.tk }), "unknown variable: " .. node.tk)
            end

            if t is TypeDeclType then
               t = typedecl_to_nominal(node, node.tk, t, t)
            end

            if not node.is_lvalue then
               self:note_dropped(node, node.tk)
               if #self.loops > 0 then
                  self:record_read(node, node.tk)
               end
            end

            -- A plain variable read for its truthiness carries a
            -- truthiness fact. Lua has no falsy tables, so for a union
            -- of nil with non-boolean members truthy means exactly "not
            -- nil": the positive branch narrows to the members, and the
            -- negated early-return shape narrows below the guard.
            if node.expected and node.expected.typename == "boolean_context" then
               local typ = without_nil(self, node, t, true)
               if typ then
                  node.guard = narrowing.type_is(node, narrowing.local_place(node.tk), typ as narrowing.Type)
               end
            end

            return t
         end,
      },
      ["type_identifier"] = {
         after = function(self: TypeChecker, node: Node, _children: {Type}): Type
            local typ, attr = self:find_var_type(node.tk)
            node.attribute = attr
            if typ then
               return typ
            end

            if self.feat_lax then
               self.errs:add_unknown(node, node.tk)
               return an_unknown(node)
            end

            return self.errs:invalid_coded(node, Errors.make({ code = "unknown_variable", variable = node.tk }), "unknown variable: " .. node.tk)
         end,
      },
      ["argument"] = {
         after = function(self: TypeChecker, node: Node, children: {Type}): Type
            local t = children[1]
            if not t then
               if node.expected and node.tk == "self" then
                  t = node.expected
               elseif node.context_type then
                  t = node.context_type
               else
                  t = self.feat_lax
                      and an_unknown(node)
                      or  a_type(node, "any", {})
               end
            end
            -- TODO: check the values of a vararg parameter (`...: T`) too, each as
            -- T; it waits on the same kind for all the values from a position on
            -- that a vararg return does (see the `return` check).
            if self.runtime_checks and node.tk ~= "..." and node.tk ~= "self" then
               local declared = children[1] or node.context_type
               local kinds: string = nil
               if declared then
                  kinds = self:runtime_kinds(declared, node.opt)
               end
               node.rt_check = kinds and (node.tk .. "=" .. kinds) or nil
            end
            if node.tk == "..." then
               t = a_vararg(node, { t })
            end
            self:add_var(node, node.tk, t).is_func_arg = true
            return t
         end,
      },
      ["identifier"] = {
         after = function(_self: TypeChecker, _node: Node, _children: {Type}): Type
            return NONE -- type is resolved elsewhere
         end,
      },
      ["newtype"] = {
         after = function(_self: TypeChecker, node: Node, _children: {Type}): Type
            return node.newtype
         end,
      },
      ["pragma"] = {
         after = function(self: TypeChecker, node: Node, _children: {Type}): Type
            if node.pkey == "arity" then
               if node.pvalue == "on" then
                  self.feat_arity = true
               elseif node.pvalue == "off" then
                  self.feat_arity = false
               else
                  return self.errs:invalid_at(node, "invalid value for pragma 'arity': " .. node.pvalue)
               end
            else
               return self.errs:invalid_at(node, "invalid pragma: " .. node.pkey)
            end
            return NONE
         end,
      },
      ["error_node"] = {
         after = function(_self: TypeChecker, node: Node, _children: {Type}): Type
            return an_invalid(node)
         end,
      }
   }

   visit_node.cbs["break"] = {
      after = function(_self: TypeChecker, _node: Node, _children: {Type}): Type
         return NONE
      end,
   }
   visit_node.cbs["do"] = {
      after = function(_self: TypeChecker, _node: Node, _children: {Type}): Type
         return NONE
      end,
   }

   local function after_literal(_self: TypeChecker, node: Node): Type
      node.guard = narrowing.truthy
      return a_type(node, node.kind as TypeName, {})
   end

   visit_node.cbs["string"] = {
      after = function(self: TypeChecker, node: Node, _children: {Type}): Type
         local t = after_literal(self, node) as StringType
         t.literal = node.conststr

         local expected = node.expected and self:to_structural(node.expected)
         if expected and expected is EnumType and self:is_a(t, expected) then
            return node.expected
         end

         return t
      end,
   }
   visit_node.cbs["number"] = { after = after_literal }
   visit_node.cbs["integer"] = { after = after_literal }

   visit_node.cbs["boolean"] = {
      after = function(self: TypeChecker, node: Node, _children: {Type}): Type
         local t = after_literal(self, node)
         node.guard = (node.tk == "true") and narrowing.truthy or nil
         return t
      end,
   }
   visit_node.cbs["nil"] = visit_node.cbs["boolean"]

   visit_node.cbs["..."] = visit_node.cbs["variable"]
   visit_node.cbs["argument_list"] = visit_node.cbs["variable_list"]
   visit_node.cbs["expression_list"] = visit_node.cbs["variable_list"]

   visit_node.after = function(self: TypeChecker, node: Node, _children: {Type}, t: Type): Type
      -- Expanding a macro expression replaces the node's fields.
      local clock = node.want_clock and self.drop_clock
      if node.expanded then
         apply_macroexp(node)
      end
      if clock then
         node.drop_clock = clock
      end

      if node.binds_context and node.expected and t then
         local given = resolve_tuple(t)
         if not given is InvalidType then
            bind_typevars_from(self, given, node.expected)
         end
      end

      return t
   end

   function TypeChecker:resolve_self(t: Type, resolve_interface?: boolean): Type, {Error}
      local selftype, selfdecl = self:type_of_self(t)
      local checktype = selftype
      if selftype is GenericType then
         checktype = selftype.t
      end

      if (resolve_interface and checktype is InterfaceType) or checktype is RecordType then
         local declname = checktype.declname
         return map_type(self, t, {
            ["self"] = function(_: TypeChecker, typ: SelfType): Type, boolean
               return typedecl_to_nominal(typ, declname, selfdecl)
            end,
         })
      else
         return t
      end
   end

   do
      local function add_interface_fields(self: TypeChecker, fields: {string:Type}, field_order: {string}, resolved: RecordLikeType, named: NominalType, list?: MetaMode)
         for fname, ftype in fields_of(resolved, list) do
            if fields[fname] then
               if not self:is_a_field(fields[fname], ftype) then
                  local what = list == "meta" and "metamethod" or "field"
                  self.errs:add(fields[fname], what .." '" .. fname .. "' does not match definition in interface %s", named)
               end
            else
               table.insert(field_order, fname)
               if ftype is TypeDeclType then
                  fields[fname] = ftype
               else
                  fields[fname] = self:resolve_self(ftype)
               end
            end
         end
      end

      local function collect_interfaces(self: TypeChecker, list: {ArrayType | NominalType}, t: RecordLikeType, seen:{Type:boolean}): {ArrayType | NominalType}
         if t.interface_list then
            for _, iface in ipairs(t.interface_list) do
               if iface is NominalType then
                  local ri = self:resolve_nominal(iface)
                  if ri is InterfaceType then
                     table.insert(list, iface)
                     if ri.interfaces_expanded and not seen[ri] then
                        seen[ri] = true
                        collect_interfaces(self, list, ri, seen)
                     end
                  else
                     self.errs:add(iface, "attempted to use %s as interface, but its type is %s", iface, ri)
                  end
               else
                  if not seen[iface] then
                     seen[iface] = true
                     table.insert(list, iface)
                  end
               end
            end
         end
         return list
      end

      function TypeChecker:expand_interfaces(t: RecordLikeType)
         if t.interfaces_expanded then
            return
         end
         t.interfaces_expanded = true

         t.interface_list = collect_interfaces(self, {}, t, {})

         for _, iface in ipairs(t.interface_list) do
            if iface is NominalType then
               local ri = self:resolve_nominal(iface)
               assert(ri is InterfaceType)
               add_interface_fields(self, t.fields, t.field_order, ri, iface)
               if ri.meta_fields then
                  t.meta_fields = t.meta_fields or {}
                  t.meta_field_order = t.meta_field_order or {}
                  add_interface_fields(self, t.meta_fields, t.meta_field_order, ri, iface, "meta")
               end
            else
               if not t.elements then
                  t.elements = iface.elements
               else
                  if not self:same_type(iface.elements, t.elements) then
                     self.errs:add(t, "incompatible array interfaces")
                  end
               end
            end
         end
      end
   end

   function TypeChecker:begin_temporary_record_types(typ: RecordType)
      self:add_var(nil, "@self", a_typedecl(typ, typ))

      for fname, ftype in fields_of(typ) do
         if ftype is TypeDeclType then
            local def = ftype.def
            if def is NominalType then
               assert(ftype.is_alias)
               self:resolve_nominal(def)
            end
            self:add_var(nil, fname, ftype)
         end
      end
   end

   function TypeChecker:end_temporary_record_types(typ: RecordType)
      -- drop @self and nested records from scope
      -- to avoid closing them prematurely in end_scope()
      local scope = self.st[#self.st]
      scope.vars["@self"] = nil
      for fname, ftype in fields_of(typ) do
         if ftype is TypeDeclType then
            scope.vars[fname] = nil
         end
      end
   end

   local function ensure_is_method_self(typ: RecordLikeType, selfarg: Type, g?: GenericType): boolean
      if selfarg is SelfType then
         return true
      end
      if not selfarg is NominalType then
         return false
      end

      if #selfarg.names ~= 1 or selfarg.names[1] ~= typ.declname then
         return false
      end

      if g then
         if not selfarg.typevals then
            return false
         end

         if g.t.typeid ~= typ.typeid then
            return false
         end

         for j=1,#g.typeargs do
            local tv = selfarg.typevals[j]
            if not (tv and tv is TypeVarType and tv.typevar == g.typeargs[j].typearg) then
               return false
            end
         end
      end

      return true
   end

   local metamethod_is_method: {string: boolean} = {
      ["__bnot"] = true,
      ["__call"] = true,
      ["__close"] = true,
      ["__gc"] = true,
      ["__index"] = true,
      ["__is"] = true,
      ["__len"] = true,
      ["__newindex"] = true,
      ["__pairs"] = true,
      ["__tostring"] = true,
      ["__unm"] = true,
   }

   local visit_type: Visitor<TypeChecker, TypeName, Type, Type> = nil
   visit_type = {
      cbs = {
         ["generic"] = {
            before = function(self: TypeChecker, typ: GenericType)
               self:begin_scope()
               self:add_var(nil, "@generic", typ)
            end,
            after = function(self: TypeChecker, typ: GenericType, _children: {Type}): Type
               self:end_scope()
               return fresh_typeargs(self, typ)
            end,
         },
         ["function"] = {
            after = function(self: TypeChecker, typ: FunctionType, _children: {Type}): Type
               if self.feat_arity == false then
                  typ.min_arity = 0
               end
               return typ
            end
         },
         ["record"] = {
            before = function(self: TypeChecker, typ: RecordType)
               self:begin_scope()
               self:begin_temporary_record_types(typ)
            end,
            after = function(self: TypeChecker, typ: RecordType, children: {Type}): Type
               local i = 1
               if typ.interface_list then
                  for j, _ in ipairs(typ.interface_list) do
                     local iface = children[i]
                     if iface is ArrayType then
                        typ.interface_list[j] = iface
                     elseif iface is NominalType then
                        local ri = self:resolve_nominal(iface)
                        if ri is InterfaceType then
                           typ.interface_list[j] = iface
                        else
                           self.errs:add(children[i], "%s is not an interface", children[i])
                        end
                     end
                     i = i + 1
                  end
               end
               if typ.elements then
                  typ.elements = children[i]
                  i = i + 1
               end
               local fmacros: {FunctionType} = nil
               local g: Variable = nil
               for name, _ in fields_of(typ) do
                  local ftype = children[i]
                  if ftype is FunctionType then
                     if ftype.macroexp then
                        fmacros = fmacros or {}
                        table.insert(fmacros, ftype)
                     end

                     if ftype.is_method then
                        local fargs = ftype.args.tuple
                        if fargs[1] then
                           if not g then
                              g = self:find_var("@generic")
                           end
                           ftype.is_method = ensure_is_method_self(typ, fargs[1], g and g.t as GenericType)
                           if ftype.is_method then
                              fargs[1] = a_self(fargs[1], typ)
                           end
                        end
                     end
                  elseif ftype is TypeDeclType and ftype.is_alias then
                     self:resolve_typealias(ftype)
                  end

                  typ.fields[name] = ftype
                  i = i + 1
               end
               for name, _ in fields_of(typ, "meta") do
                  local ftype = children[i]
                  if ftype is FunctionType then
                     if ftype.macroexp then
                        fmacros = fmacros or {}
                        table.insert(fmacros, ftype)
                     end
                     ftype.is_method = metamethod_is_method[name]
                  end
                  typ.meta_fields[name] = ftype
                  i = i + 1
               end

               if typ.interface_list then
                  self:expand_interfaces(typ)

                  if self.collector then
                     for fname, ftype in fields_of(typ) do
                        self.env.reporter:add_field(typ, fname, ftype)
                     end
                  end
               end

               if fmacros then
                  for _, t in ipairs(fmacros) do
                     local macroexp_type = recurse_node(self, t.macroexp, visit_node, visit_type)

                     self:check_macroexp_arg_use(t.macroexp)

                     if not self:is_a(macroexp_type, t) then
                        self.errs:add(macroexp_type, "macroexp type does not match declaration")
                     end
                  end
               end

               self:end_temporary_record_types(typ)
               self:end_scope()

               return typ
            end,
         },
         ["typearg"] = {
            after = function(self: TypeChecker, typ: TypeArgType, _children: {Type}): Type
               local name = typ.typearg
               local old <const> = self:find_var(name, "check_only")
               if old then
                  self.errs:redeclaration_warning(typ, name, "type argument", old)
               end
               if simple_types[name as TypeName] then
                  self.errs:add(typ, "cannot use base type name '" .. name .. "' as a type variable")
               end

               self:add_var(nil, name, a_type(typ, "typearg", {
                  typearg = name,
                  constraint = typ.constraint,
               } as TypeArgType))
               return typ
            end,
         },
         ["typevar"] = {
            after = function(self: TypeChecker, typ: TypeVarType, _children: {Type}): Type
               if not self:find_var_type(typ.typevar) then
                  self.errs:add(typ, "undefined type variable " .. typ.typevar)
               end
               return typ
            end,
         },
         ["nominal"] = {
            after = function(self: TypeChecker, typ: NominalType, _children: {Type}): Type
               if typ.found then
                  return typ
               end

               local t, typearg = self:find_type(typ.names)
               if t then
                  local def = t.def
                  if t.is_alias then
                     if def is GenericType then
                        def = def.t
                     end
                     if def is NominalType then
                        typ.found = def.found
                     end
                  elseif def.typename ~= "circular_require" then
                     typ.found = t
                  end
               elseif typearg then
                  -- convert nominal into a typevar
                  typ.names = nil
                  edit_type(typ, typ, "typevar")
                  local tv = typ as TypeVarType
                  tv.typevar = typearg.typearg
                  tv.constraint = typearg.constraint
               else
                  local name = typ.names[1]
                  local scope = self.st[#self.st]
                  scope.pending_nominals = scope.pending_nominals or {}
                  scope.pending_nominals[name] = scope.pending_nominals[name] or {}
                  table.insert(scope.pending_nominals[name], typ)
               end
               return typ
            end,
         },
         ["union"] = {
            after = function(self: TypeChecker, typ: UnionType, _children: {Type}): Type
               local _, err = is_valid_union(typ)
               if err then
                  return self.errs:invalid_at(typ, err, typ)
               end
               return typ
            end
         },
      },
   }

   local default_type_visitor = {
      after = function(_self: TypeChecker, typ: Type, _children: {Type}): Type
         return typ
      end,
   }

   visit_type.cbs["interface"] = visit_type.cbs["record"]

   visit_type.cbs["typedecl"] = default_type_visitor
   visit_type.cbs["self"] = default_type_visitor
   visit_type.cbs["string"] = default_type_visitor
   visit_type.cbs["tupletable"] = default_type_visitor
   visit_type.cbs["array"] = default_type_visitor
   visit_type.cbs["map"] = default_type_visitor
   visit_type.cbs["enum"] = default_type_visitor
   visit_type.cbs["boolean"] = default_type_visitor
   visit_type.cbs["nil"] = default_type_visitor
   visit_type.cbs["number"] = default_type_visitor
   visit_type.cbs["integer"] = default_type_visitor
   visit_type.cbs["thread"] = default_type_visitor
   visit_type.cbs["emptytable"] = default_type_visitor
   visit_type.cbs["literal_table_item"] = default_type_visitor
   visit_type.cbs["unresolved_emptytable_value"] = default_type_visitor
   visit_type.cbs["tuple"] = default_type_visitor
   visit_type.cbs["poly"] = default_type_visitor
   visit_type.cbs["any"] = default_type_visitor
   visit_type.cbs["unknown"] = default_type_visitor
   visit_type.cbs["invalid"] = default_type_visitor
   visit_type.cbs["none"] = default_type_visitor

   local type VisitorAfterPatcher = function<S, N, T>(VisitorAfter<S, N, T>): VisitorAfter<S, N, T>

   local function internal_compiler_check<S, N>(fn: VisitorAfter<S, N, Type>): VisitorAfter<S, N, Type>
      return function(s: S, n: N, children: {Type}, t: Type): Type
         t = fn and fn(s, n, children, t) or t

         if type(t) ~= "table" then
            error(((n as Node).kind or (n as Type).typename) .. " did not produce a type")
         end
         if type(t.typename) ~= "string" then
            error(((n as Node).kind or (n as Type).typename) .. " type does not have a typename")
         end

         return t
      end
   end

   local function store_type_after<N>(fn: VisitorAfter<TypeChecker, N, Type>): VisitorAfter<TypeChecker, N, Type>
      return function(self: TypeChecker, n: N, children: {Type}, t: Type): Type
         t = fn and fn(self, n, children, t) or t

         local w = n as Where

         if w.y then
            self.collector.store_type(w.y, w.x, t)
         end

         return t
      end
   end

   local function debug_type_after<S>(fn: VisitorAfter<S, Node, Type>): VisitorAfter<S, Node, Type>
      return function(s: S, node: Node, children: {Type}, t: Type): Type
         t = fn and fn(s, node, children, t) or t

         node.debug_type = t
         return t
      end
   end

   local function patch_visitors(my_visit_node: Visitor<TypeChecker, NodeKind, Node, Type>,
                                 after_node: VisitorAfterPatcher<TypeChecker, Node, Type>,
                                 my_visit_type?: Visitor<TypeChecker, TypeName, Type, Type>,
                                 after_type?: VisitorAfterPatcher<TypeChecker, Type, Type>):
                                 Visitor<TypeChecker, NodeKind, Node, Type>,
                                 Visitor<TypeChecker, TypeName, Type, Type>
      if my_visit_node == visit_node then
         my_visit_node = shallow_copy_table(my_visit_node)
      end
      my_visit_node.after = after_node(my_visit_node.after)
      if my_visit_type then
         if my_visit_type == visit_type then
            my_visit_type = shallow_copy_table(my_visit_type)
         end
         my_visit_type.after = after_type(my_visit_type.after)
      else
         my_visit_type = visit_type
      end
      return my_visit_node, my_visit_type
   end

   local function set_feat(feat: Feat, default: boolean): boolean
      if feat then
         return (feat == "on")
      else
         return default
      end
   end

   tl.check = function(ast: Node, filename?: string, opts?: CheckOptions, env?: Env): Result, string
      filename = filename or "?"

      opts = opts or {}

      if not env then
         local err: string
         env, err = tl.new_env({ defaults = opts })
         if err then
            return nil, err
         end
      end

      local self: TypeChecker = {
         filename = filename,
         env = env,
         st = {
            {
               vars = env.globals,
               pending_global_types = {},
            },
         },
         errs = Errors.new(filename),
         all_needs_compat = {},
         dependencies = {},
         subtype_relations = TypeChecker.subtype_relations,
         eqtype_relations = TypeChecker.eqtype_relations,
         type_priorities = TypeChecker.type_priorities,
         drop_clock = 0,
         loops = {},
         loop_tick = 0,
      }

      (self.st[1] as narrowing.Scope).on_drop = function(index: integer, key: string, why: narrowing.Drop)
         self:loop_dropped(index, key, why)
      end

      self.cache_std_metatable_type = env.globals["metatable"] and (env.globals["metatable"].t as TypeDeclType).def

      setmetatable(self, {
         __index = TypeChecker,
         __tostring = function(): string return "TypeChecker" end,
      })

      self.feat_lax   = set_feat(opts.feat_lax   or env.defaults.feat_lax,   false)
      self.feat_arity = set_feat(opts.feat_arity or env.defaults.feat_arity, true)
      self.gen_compat = opts.gen_compat or env.defaults.gen_compat or DEFAULT_GEN_COMPAT
      self.gen_target = opts.gen_target or env.defaults.gen_target or DEFAULT_GEN_TARGET
      self.runtime_checks = opts.runtime_checks or env.defaults.runtime_checks

      if self.feat_lax then
         self.feat_arity = false
      end

      if self.gen_target == "5.4" and self.gen_compat ~= "off" then
         return nil, "gen-compat must be explicitly 'off' when gen-target is '5.4'"
      end

      if self.feat_lax then
         self.type_priorities = shallow_copy_table(self.type_priorities)
         self.type_priorities["unknown"] = 0

         self.subtype_relations = shallow_copy_table(self.subtype_relations)

         self.subtype_relations["unknown"] = {}
         self.subtype_relations["unknown"]["*"] = compare_true

         self.subtype_relations["*"] = shallow_copy_table(self.subtype_relations["*"])
         self.subtype_relations["*"]["unknown"] = compare_true
         -- in .lua files, all values can be used in a boolean context
         self.subtype_relations["*"]["boolean"] = compare_true

         self.get_rets = function(rets: TupleType): TupleType
            if #rets.tuple == 0 then
               return a_vararg(rets, { an_unknown(rets) })
            end
            return rets
         end
      else
         self.get_rets = function(rets: TupleType): TupleType
            return rets
         end
      end

      if env.report_types then
         env.reporter = env.reporter or tl.new_type_reporter()
         self.collector = env.reporter:get_collector(filename)
      end

      local visit_node, visit_type = visit_node, visit_type
      if opts.run_internal_compiler_checks then
         visit_node, visit_type = patch_visitors(
            visit_node, internal_compiler_check,
            visit_type, internal_compiler_check
         )
      end
      if self.collector then
         visit_node, visit_type = patch_visitors(
            visit_node, store_type_after,
            visit_type, store_type_after
         )
      end
      if TL_DEBUG then
         visit_node, visit_type = patch_visitors(
            visit_node, debug_type_after
         )
      end

      assert(ast.kind == "statements")
      if self.runtime_checks then
         ast.rt_file = filename
      end
      self.root_ast = ast
      recurse_node(self, ast, visit_node, visit_type)

      local global_scope = self.st[1]
      close_types(global_scope)
      self.errs:check_var_usage(global_scope, true)

      clear_redundant_errors(self.errs.errors)

      add_compat_entries(ast, self.all_needs_compat, self.gen_compat)

      local result = {
         ast = ast,
         env = env,
         type = self.module_type or a_type(ast, "boolean", {}),
         filename = filename,
         warnings = self.errs.warnings,
         type_errors = self.errs.errors,
         dependencies = self.dependencies,
      }

      env.loaded[filename] = result
      table.insert(env.loaded_order, filename or "")

      if self.collector then
         env.reporter:store_result(self.collector, env.globals)
      end

      return result
   end
end

--------------------------------------------------------------------------------
-- High-level API
--------------------------------------------------------------------------------

local function read_full_file(fd: FILE): string, string
   local bom <const> = "\239\187\191" -- "\xEF\xBB\xBF"
   local content, err = fd:read("*a")
   if not content then
      return nil, err
   end

   if content:sub(1, bom:len()) == bom then
      content = content:sub(bom:len() + 1)
   end
   return content, err
end

local function lang_heuristic(filename?: string, input?: string): ParseLang
   if filename then
      local pattern <const> = "(.*)%.([a-z]+)$"
      local _, extension = filename:match(pattern)
      extension = extension and extension:lower()

      if extension == "tl" then
         return "tl"
      elseif extension == "lua" then
         return "lua"
      end
   end
   if input then
      return (input:match("^#![^\n]*lua[^\n]*\n")) and "lua" or "tl"
   end
   return "tl"
end

local function feat_lax_heuristic(lang: ParseLang): Feat
   return lang == "tl" and "off" or "on"
end

tl.check_file = function(filename: string, env?: Env, fd?: FILE): Result, string
   if env and env.loaded and env.loaded[filename] then
      return env.loaded[filename]
   end

   local input, err: string, string

   if not fd then
      fd, err = io.open(filename, "rb")
      if not fd then
         return nil, "could not open " .. filename .. ": " .. err
      end
   end

   input, err = read_full_file(fd)
   fd:close()
   if not input then
      return nil, "could not read " .. filename .. ": " .. err
   end

   return tl.check_string(input, env, filename)
end

function tl.target_from_lua_version(str: string): GenTarget
   if str == "Lua 5.1"
      or str == "Lua 5.2" then
      return "5.1"
   elseif str == "Lua 5.3" then
      return "5.3"
   elseif str == "Lua 5.4" then
      return "5.4"
   end
end

local function default_env_opts(runtime: boolean, parse_lang: ParseLang): EnvOptions
   local gen_target = runtime and tl.target_from_lua_version(_VERSION) or DEFAULT_GEN_TARGET
   local gen_compat: GenCompat = (gen_target == "5.4") and "off" or DEFAULT_GEN_COMPAT
   return {
      defaults = {
         feat_lax = feat_lax_heuristic(parse_lang),
         gen_target = gen_target,
         gen_compat = gen_compat,
         run_internal_compiler_checks = false,
      }
   }
end

function tl.check_string(input: string, env?: Env, filename?: string, parse_lang?: ParseLang): Result
   parse_lang = parse_lang or lang_heuristic(filename, input)
   env = env or tl.new_env(default_env_opts(false, parse_lang))

   if env.loaded and env.loaded[filename] then
      return env.loaded[filename]
   end
   filename = filename or ""

   local program, syntax_errors = tl.parse(input, filename, parse_lang)

   if (not env.keep_going) and #syntax_errors > 0 then
      local result = {
         ok = false,
         filename = filename,
         type = a_type({ f = filename, y = 1, x = 1 }, "boolean", {}),
         type_errors = {},
         syntax_errors = syntax_errors,
         env = env
      }
      env.loaded[filename] = result
      table.insert(env.loaded_order, filename)
      return result
   end

   local result = tl.check(program, filename, env.defaults, env)

   result.syntax_errors = syntax_errors

   return result
end

tl.gen = function(input: string, env?: Env, opts?: GenerateOptions, parse_lang?: ParseLang): string, Result
   parse_lang = parse_lang or lang_heuristic(nil, input)
   env = env or assert(tl.new_env(default_env_opts(false, parse_lang)), "Default environment initialization failed")
   local result = tl.check_string(input, env)

   if (not result.ast) or #result.syntax_errors > 0 then
      return nil, result
   end

   local code: string
   code, result.gen_error = tl.generate(result.ast, env.defaults.gen_target, opts)
   return code, result
end

local function tl_package_loader(module_name: string): any, any
   local found_filename, fd, tried = tl.search_module(module_name, false)
   if found_filename then
      local parse_lang = lang_heuristic(found_filename)
      local input = read_full_file(fd)
      if not input then
         return table.concat(tried, "\n\t")
      end
      fd:close()
      local program, errs = tl.parse(input, found_filename, parse_lang)
      if #errs > 0 then
         error(found_filename .. ":" .. errs[1].y .. ":" .. errs[1].x .. ": " .. errs[1].msg)
      end

      local env = tl.package_loader_env
      if not env then
         tl.package_loader_env = assert(tl.new_env(), "Default environment initialization failed")
         env = tl.package_loader_env
      end

      local opts = default_env_opts(true, parse_lang)

      local w = { f = found_filename, x = 1, y = 1 }
      env.modules[module_name] = a_typedecl(w, a_type(w, "circular_require", {}))

      local result = tl.check(program, found_filename, opts.defaults, env)

      env.modules[module_name] = result.type

      -- TODO: a generator failure here raises through the assert, where a
      -- Lua file with a syntax error in it is a loader error. If that is
      -- wanted, the fix is to answer the generate error as the loader's
      -- failure.
      local code = assert(tl.generate(program, opts.defaults.gen_target, fast_generate_opts))
      local chunk, err = load(code, "@" .. found_filename, "t")
      if chunk then
         return function(modname: string, loader_data: string): any
            if loader_data == nil then
               loader_data = found_filename
            end
            local ret = chunk(modname, loader_data)
            return ret
         end, found_filename
      else
         error("Internal Compiler Error: Teal generator produced invalid Lua. Please report a bug at https://github.com/teal-language/tl\n\n" .. err)
      end
   end
   return table.concat(tried, "\n\t")
end

function tl.loader()
   if package.searchers then
      table.insert(package.searchers, 2, tl_package_loader)
   else
      table.insert(package.loaders, 2, tl_package_loader)
   end
end

local function env_for(opts: EnvOptions, env_tbl: {any:any}): Env
   if not env_tbl then
      if not tl.package_loader_env then
         tl.package_loader_env = tl.new_env(opts)
      end
      return tl.package_loader_env
   end

   if not tl.load_envs then
      tl.load_envs = setmetatable({}, { __mode = "k" })
   end

   tl.load_envs[env_tbl] = tl.load_envs[env_tbl] or tl.new_env(opts)
   return tl.load_envs[env_tbl]
end

tl.load = function(input: string, chunkname?: string, mode?: LoadMode, ...: {any:any}): LoadFunction, string
   local parse_lang = lang_heuristic(chunkname)
   local program, errs = tl.parse(input, chunkname, parse_lang)
   if #errs > 0 then
      return nil, (chunkname or "") .. ":" .. errs[1].y .. ":" .. errs[1].x .. ": " .. errs[1].msg
   end

   local opts = default_env_opts(true, parse_lang)

   if not tl.package_loader_env then
      tl.package_loader_env = tl.new_env(opts)
   end

   local filename = chunkname or ("string \"" .. input:sub(45) .. (#input > 45 and "..." or "") .. "\"")
   local result = tl.check(program, filename, opts.defaults, env_for(opts, ...))

   if mode and mode:match("c") then
      if #result.type_errors > 0 then
         local errout = {}
         for _, err in ipairs(result.type_errors) do
            table.insert(errout, err.filename .. ":" .. err.y .. ":" .. err.x .. ": " .. (err.msg or ""))
         end
         return nil, table.concat(errout, "\n")
      end

      mode = mode:gsub("c", "") as LoadMode
   end

   local code, err = tl.generate(program, opts.defaults.gen_target, fast_generate_opts)
   if not code then
      return nil, err
   end

   return load(code, chunkname, mode, ...)
end

tl.version = function(): string
   return VERSION
end

--------------------------------------------------------------------------------
-- Backwards compatibility
--------------------------------------------------------------------------------

function tl.get_types(result: Result): TypeReport, TypeReporter
   return result.env.reporter:get_report(), result.env.reporter
end

tl.init_env = function(lax?: boolean, gen_compat?: boolean | GenCompat, gen_target?: GenTarget, predefined?: {string}): Env, string
   local opts = {
      defaults = {
         feat_lax = (lax and "on" or "off") as Feat,
         gen_compat = ((gen_compat is GenCompat) and gen_compat) or
                       (gen_compat == false and "off") or
                       (gen_compat == true or gen_compat == nil) and "optional",
         gen_target = gen_target or
                      ((_VERSION == "Lua 5.1" or _VERSION == "Lua 5.2") and "5.1") or
                      "5.3",
      },
      predefined_modules = predefined,
   }

   return tl.new_env(opts)
end

tl.type_check = function(ast: Node, tc_opts?: tl.TypeCheckOptions): Result, string
   local opts: CheckOptions = {
      feat_lax = tc_opts.lax and "on" or "off",
      feat_arity = tc_opts.env and tc_opts.env.defaults.feat_arity or "on",
      gen_compat = tc_opts.gen_compat,
      gen_target = tc_opts.gen_target,
      run_internal_compiler_checks = tc_opts.run_internal_compiler_checks,
      runtime_checks = tc_opts.env and tc_opts.env.defaults.runtime_checks or false,
   }
   return tl.check(ast, tc_opts.filename, opts, tc_opts.env)
end

tl.pretty_print_ast = function(ast: Node, gen_target?: tl.TargetMode, mode?: boolean | tl.PrettyPrintOptions): string, string
   local opts: GenerateOptions
   if mode is tl.PrettyPrintOptions then
      opts = mode
   elseif mode == true then
      opts = fast_generate_opts
   else
      opts = default_generate_opts
   end

   return tl.generate(ast, gen_target, opts)
end

tl.process = function(filename: string, env?: Env, fd?: FILE): Result, string
   return tl.check_file(filename, env, fd)
end

tl.process_string = function(input: string, is_lua: boolean, env: Env, filename: string, _module_name: string): Result
   return tl.check_string(input, env or tl.init_env(is_lua), filename)
end

return tl
