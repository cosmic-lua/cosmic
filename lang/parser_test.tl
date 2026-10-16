--- The parser of the new checker's grammar ([`lang.parser`]): the tree each
--- construct makes, written as the text [`lang.ast_dump`] gives it, and the
--- places where the draft's lookahead rules decide. The refusals and the
--- recovery are in [`lang.parser_error_test`]. Every source here is also held
--- to [`lang.parser_cover`], which asks that its tree tile its tokens.
local Ast = require("lang.ast")
local Cover = require("lang.parser_cover")
local Dump = require("lang.ast_dump")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")

local record Case
  source: string
  want: string
end

--- The parse of `source`, which is held to the cover check.
local function parse(source: string, dialect?: Ast.Dialect): Parser.Parsed
  local parsed = Parser.parse(Lexer.lex(source, "t.tl"), "t.tl", dialect or "tl")
  local ok, why = Cover.check(source, parsed)
  assert(ok, why .. " in " .. source)
  return parsed
end

--- The parse of `source`, which has no error.
local function clean(source: string, dialect?: Ast.Dialect): Parser.Parsed
  local parsed = parse(source, dialect)
  local first = parsed.errors[1]
  assert(first == nil, "error " .. (first and first.code or "") .. ": " .. (first and first.msg or "") .. " in " .. source)
  return parsed
end

--- The statements of `source` as text, one after the other.
local function tree(source: string, dialect?: Ast.Dialect): string
  local stats = clean(source, dialect).chunk.body.stats
  local parts: {string} = {}
  for i, stat in ipairs(stats) do
    parts[i] = Dump.dump(stat)
  end
  return table.concat(parts, " ")
end

--- The first local of `source`, which is `local x ... = ...` and nothing else.
local function the_local(source: string): Ast.Local
  local stat = clean(source).chunk.body.stats[1]
  assert(stat is Ast.Local, "not a local: " .. source)
  return stat
end

local function same(got: string, want: string, source: string)
  assert(got == want, source .. "\n   got: " .. got .. "\n  want: " .. want)
end

-- statements
local STATEMENTS <const>: {Case} = {
  { source = "local a",
    want = "(Local \"local\" [(Binding \"a\")])" },
  { source = "local a, b <const>, c <close>: T, U = f()",
    want = "(Local \"local\" [(Binding \"a\") (Binding \"b\" \"const\") (Binding \"c\" \"close\")] [(TypeName [\"T\"]) (TypeName [\"U\"])] [(Call (Name \"f\"))])" },
  { source = "x, t.k, t[i] = 1, 2",
    want = "(Assign [(Name \"x\") (Field (Name \"t\") \"k\") (Index (Name \"t\") (Name \"i\"))] [(Integer 1) (Integer 2)])" },
  { source = "f(x)\nobj:m(y)",
    want = "(CallStat (Call (Name \"f\") [(Name \"x\")])) (CallStat (MethodCall (Name \"obj\") \"m\" [(Name \"y\")]))" },
  { source = "do local x = 1 end",
    want = "(Do (Block [(Local \"local\" [(Binding \"x\")] _ [(Integer 1)])]))" },
  { source = "while a < b do a = a + 1 end",
    want = "(While (Binary \"<\" (Name \"a\") (Name \"b\")) (Block [(Assign [(Name \"a\")] [(Binary \"+\" (Name \"a\") (Integer 1))])]))" },
  { source = "repeat local done = f() until done",
    want = "(Repeat (Block [(Local \"local\" [(Binding \"done\")] _ [(Call (Name \"f\"))])]) (Name \"done\"))" },
  { source = "if a then b() elseif c then d() else e() end",
    want = "(If [(Arm (Name \"a\") (Block [(CallStat (Call (Name \"b\")))])) (Arm (Name \"c\") (Block [(CallStat (Call (Name \"d\")))]))] (Block [(CallStat (Call (Name \"e\")))]))" },
  { source = "for i = 1, 10, 2 do end",
    want = "(ForNum (Binding \"i\") (Integer 1) (Integer 10) (Integer 2) (Block))" },
  { source = "for k, v in pairs(t) do print(k, v) end",
    want = "(ForIn [(Binding \"k\") (Binding \"v\")] [(Call (Name \"pairs\") [(Name \"t\")])] (Block [(CallStat (Call (Name \"print\") [(Name \"k\") (Name \"v\")]))]))" },
  { source = "return",
    want = "(Return)" },
  { source = "return 1, f()",
    want = "(Return [(Integer 1) (Call (Name \"f\"))])" },
  { source = "local function f<T>(a: T, ...: any): T return a end",
    want = "(LocalFunction (Binding \"f\") [(TypeParam (Binding \"T\"))] (Fn [(Param (Binding \"a\") _ (TypeName [\"T\"])) (Param _ _ (TypeName [\"any\"]) variadic)] (Rets [[(TypeName [\"T\"])]]) (Block [(Return [(Name \"a\")])])))" },
  { source = "function Stack.push(s: Stack, v: any) end",
    want = "(Function [(Name \"Stack\") (Name \"push\")] _ (Fn [(Param (Binding \"s\") _ (TypeName [\"Stack\"])) (Param (Binding \"v\") _ (TypeName [\"any\"]))] _ (Block)))" },
  { source = "for _, x in ipairs(xs) do if x == skip then continue end n = n + 1 end",
    want = "(ForIn [(Binding \"_\") (Binding \"x\")] [(Call (Name \"ipairs\") [(Name \"xs\")])] (Block [(If [(Arm (Binary \"==\" (Name \"x\") (Name \"skip\")) (Block [(Continue)]))]) (Assign [(Name \"n\")] [(Binary \"+\" (Name \"n\") (Integer 1))])]))" },
  { source = "while true do break end",
    want = "(While (Boolean true) (Block [(Break)]))" },
  { source = "repeat if c then continue end until c",
    want = "(Repeat (Block [(If [(Arm (Name \"c\") (Block [(Continue)]))])]) (Name \"c\"))" },
  { source = "match fetch() do\n  | (true, body) then print(body)\n  | (false, why) then print(\"failed: \" .. why)\nend",
    want = "(Match (Call (Name \"fetch\")) [(MatchArm [(PatBool true) (PatBind (Binding \"body\"))] (Block [(CallStat (Call (Name \"print\") [(Name \"body\")]))])) (MatchArm [(PatBool false) (PatBind (Binding \"why\"))] (Block [(CallStat (Call (Name \"print\") [(Binary \"..\" (String \"failed: \") (Name \"why\"))]))]))])" },
  { source = "match s:read() do\n  | (true, _, n) then return n\n  | (false, e) then error(e)\nend",
    want = "(Match (MethodCall (Name \"s\") \"read\") [(MatchArm [(PatBool true) (PatBind (Binding \"_\")) (PatBind (Binding \"n\"))] (Block [(Return [(Name \"n\")])])) (MatchArm [(PatBool false) (PatBind (Binding \"e\"))] (Block [(CallStat (Call (Name \"error\") [(Name \"e\")]))]))])" },
  { source = "local y = if a then 1 else 2 end\n",
    want = "(Local \"local\" [(Binding \"y\")] _ [(IfExp [(ExpArm (Name \"a\") (Integer 1))] (Integer 2))])" },
}

local function test_each_statement_makes_its_tree()
  for _, case in ipairs(STATEMENTS) do
    same(tree(case.source), case.want, case.source)
  end
end

-- expressions: `local x = <source>`, the one value
local EXPRESSIONS <const>: {Case} = {
  { source = "a or b and c",
    want = "(Binary \"or\" (Name \"a\") (Binary \"and\" (Name \"b\") (Name \"c\")))" },
  { source = "a < b == c",
    want = "(Binary \"==\" (Binary \"<\" (Name \"a\") (Name \"b\")) (Name \"c\"))" },
  { source = "a | b ~ c & d << e .. f + g * h",
    want = "(Binary \"|\" (Name \"a\") (Binary \"~\" (Name \"b\") (Binary \"&\" (Name \"c\") (Binary \"<<\" (Name \"d\") (Binary \"..\" (Name \"e\") (Binary \"+\" (Name \"f\") (Binary \"*\" (Name \"g\") (Name \"h\"))))))))" },
  { source = "a .. b .. c",
    want = "(Binary \"..\" (Name \"a\") (Binary \"..\" (Name \"b\") (Name \"c\")))" },
  { source = "a - b - c",
    want = "(Binary \"-\" (Binary \"-\" (Name \"a\") (Name \"b\")) (Name \"c\"))" },
  { source = "a // b % c / d",
    want = "(Binary \"/\" (Binary \"%\" (Binary \"//\" (Name \"a\") (Name \"b\")) (Name \"c\")) (Name \"d\"))" },
  { source = "-a ^ 2",
    want = "(Unary \"-\" (Binary \"^\" (Name \"a\") (Integer 2)))" },
  { source = "a ^ b ^ c",
    want = "(Binary \"^\" (Name \"a\") (Binary \"^\" (Name \"b\") (Name \"c\")))" },
  { source = "2 ^ -3",
    want = "(Binary \"^\" (Integer 2) (Unary \"-\" (Integer 3)))" },
  { source = "not a == b",
    want = "(Binary \"==\" (Unary \"not\" (Name \"a\")) (Name \"b\"))" },
  { source = "#t + 1",
    want = "(Binary \"+\" (Unary \"#\" (Name \"t\")) (Integer 1))" },
  { source = "~a ~ ~b",
    want = "(Binary \"~\" (Unary \"~\" (Name \"a\")) (Unary \"~\" (Name \"b\")))" },
  { source = "- - a",
    want = "(Unary \"-\" (Unary \"-\" (Name \"a\")))" },
  { source = "a + b < c .. d",
    want = "(Binary \"<\" (Binary \"+\" (Name \"a\") (Name \"b\")) (Binary \"..\" (Name \"c\") (Name \"d\")))" },
  { source = "not a is T",
    want = "(Unary \"not\" (IsTest (Name \"a\") (TypeName [\"T\"])))" },
  { source = "a == b is T",
    want = "(Binary \"==\" (Name \"a\") (IsTest (Name \"b\") (TypeName [\"T\"])))" },
  { source = "a is {string}",
    want = "(IsTest (Name \"a\") (TypeArray (TypeName [\"string\"])))" },
  { source = "a as any as integer",
    want = "(Cast (Cast (Name \"a\") (TypeName [\"any\"])) (TypeName [\"integer\"]))" },
  { source = "(a + b) * c",
    want = "(Binary \"*\" (Paren (Binary \"+\" (Name \"a\") (Name \"b\"))) (Name \"c\"))" },
  { source = "a.b.c[d](e):f(g).h",
    want = "(Field (MethodCall (Call (Index (Field (Field (Name \"a\") \"b\") \"c\") (Name \"d\")) [(Name \"e\")]) \"f\" [(Name \"g\")]) \"h\")" },
  { source = "f{ 1, 2 }",
    want = "(Call (Name \"f\") [(Table [(Positional (Integer 1)) (Positional (Integer 2))])])" },
  { source = "{ 1, [k] = 2, n = 3, f = function() end, }",
    want = "(Table [(Positional (Integer 1)) (Keyed (Name \"k\") (Integer 2)) (Named \"n\" (Integer 3)) (Named \"f\" (FunctionLit (Fn _ _ (Block))))])" },
  { source = "if a then b elseif c then d else e end",
    want = "(IfExp [(ExpArm (Name \"a\") (Name \"b\")) (ExpArm (Name \"c\") (Name \"d\"))] (Name \"e\"))" },
  { source = "function(a, b?: T, ...: any): R return a end",
    want = "(FunctionLit (Fn [(Param (Binding \"a\")) (Param (Binding \"b\") optional (TypeName [\"T\"])) (Param _ _ (TypeName [\"any\"]) variadic)] (Rets [[(TypeName [\"R\"])]]) (Block [(Return [(Name \"a\")])])))" },
  { source = "0xFF + 1.5 + 2e3 + .5",
    want = "(Binary \"+\" (Binary \"+\" (Binary \"+\" (Integer 255) (Float 1.5)) (Float 2000.0)) (Float 0.5))" },
  { source = "\"a\\n\" .. 'b' .. [[c]] .. [==[d]==]",
    want = "(Binary \"..\" (String \"a\\n\") (Binary \"..\" (String \"b\") (Binary \"..\" (String \"c\" long) (String \"d\" long))))" },
  { source = "nil, true, false, ...",
    want = "(Nil) (Boolean true) (Boolean false) (Vararg)" },
  { source = "a and b or c",
    want = "(Binary \"or\" (Binary \"and\" (Name \"a\") (Name \"b\")) (Name \"c\"))" },
  { source = "a >> b > c\n\n",
    want = "(Binary \">\" (Binary \">>\" (Name \"a\") (Name \"b\")) (Name \"c\"))" },
}

local function test_each_expression_makes_its_tree_with_its_precedence_and_associativity()
  for _, case in ipairs(EXPRESSIONS) do
    local values = the_local("local x = " .. case.source).values
    local parts: {string} = {}
    for i, value in ipairs(values) do
      parts[i] = Dump.dump(value)
    end
    same(table.concat(parts, " "), case.want, case.source)
  end
end

-- types: `local x: <source>`, the one type
local TYPES <const>: {Case} = {
  { source = "string",
    want = "(TypeName [\"string\"])" },
  { source = "Stream.Reader",
    want = "(TypeName [\"Stream\" \"Reader\"])" },
  { source = "Cache<K, List<V>>",
    want = "(TypeName [\"Cache\"] [(TypeName [\"K\"]) (TypeName [\"List\"] [(TypeName [\"V\"])])])" },
  { source = "Map<string, Cache<K, List<V>>>",
    want = "(TypeName [\"Map\"] [(TypeName [\"string\"]) (TypeName [\"Cache\"] [(TypeName [\"K\"]) (TypeName [\"List\"] [(TypeName [\"V\"])])])])" },
  { source = "T?",
    want = "(TypeOptional (TypeName [\"T\"]))" },
  { source = "A | B",
    want = "(TypeUnion [(TypeName [\"A\"]) (TypeName [\"B\"])])" },
  { source = "A | B?",
    want = "(TypeUnion [(TypeName [\"A\"]) (TypeOptional (TypeName [\"B\"]))])" },
  { source = "(A | B)?",
    want = "(TypeOptional (TypeUnion [(TypeName [\"A\"]) (TypeName [\"B\"])]))" },
  { source = "{T}",
    want = "(TypeArray (TypeName [\"T\"]))" },
  { source = "{T}?",
    want = "(TypeOptional (TypeArray (TypeName [\"T\"])))" },
  { source = "{K: V}",
    want = "(TypeMap (TypeName [\"K\"]) (TypeName [\"V\"]))" },
  { source = "mut {T}",
    want = "(TypeMut (TypeArray (TypeName [\"T\"])))" },
  { source = "mut {T}?",
    want = "(TypeOptional (TypeMut (TypeArray (TypeName [\"T\"]))))" },
  { source = "nil",
    want = "(TypeNil)" },
  { source = "true | false",
    want = "(TypeUnion [(TypeBool true) (TypeBool false)])" },
  { source = "function()",
    want = "(TypeFunction)" },
  { source = "function(a: A, b?: B, ...: C): R",
    want = "(TypeFunction _ [(PType \"a\" _ _ (TypeName [\"A\"])) (PType \"b\" optional _ (TypeName [\"B\"])) (PType _ _ variadic (TypeName [\"C\"]))] (Rets [[(TypeName [\"R\"])]]))" },
  { source = "function(A, B): R",
    want = "(TypeFunction _ [(PType _ _ _ (TypeName [\"A\"])) (PType _ _ _ (TypeName [\"B\"]))] (Rets [[(TypeName [\"R\"])]]))" },
  { source = "function<T, U is Ordered>(x: T): U",
    want = "(TypeFunction [(TypeParam (Binding \"T\")) (TypeParam (Binding \"U\") (TypeName [\"Ordered\"]))] [(PType \"x\" _ _ (TypeName [\"T\"]))] (Rets [[(TypeName [\"U\"])]]))" },
  { source = "function(): A, B",
    want = "(TypeFunction _ _ (Rets [[(TypeName [\"A\"]) (TypeName [\"B\"])]]))" },
  { source = "function(): A, B...",
    want = "(TypeFunction _ _ (Rets [[(TypeName [\"A\"]) (TypeName [\"B\"])]] variadic))" },
  { source = "function(): (A, B)",
    want = "(TypeFunction _ _ (Rets [[(TypeName [\"A\"]) (TypeName [\"B\"])]]))" },
  { source = "function(): (true, R) | (false, E)",
    want = "(TypeFunction _ _ (Rets [[(TypeBool true) (TypeName [\"R\"])] [(TypeBool false) (TypeName [\"E\"])]]))" },
  { source = "function(): ()",
    want = "(TypeFunction _ _ (Rets [[]]))" },
  { source = "function(): (A | B)?",
    want = "(TypeFunction _ _ (Rets [[(TypeOptional (TypeUnion [(TypeName [\"A\"]) (TypeName [\"B\"])]))]]))" },
  { source = "function(): (A)?",
    want = "(TypeFunction _ _ (Rets [[(TypeOptional (TypeName [\"A\"]))]]))" },
  { source = "function(f: function(): A, b: B)",
    want = "(TypeFunction _ [(PType \"f\" _ _ (TypeFunction _ _ (Rets [[(TypeName [\"A\"])]]))) (PType \"b\" _ _ (TypeName [\"B\"]))])" },
  { source = "function(f: function(): A, B)",
    want = "(TypeFunction _ [(PType \"f\" _ _ (TypeFunction _ _ (Rets [[(TypeName [\"A\"]) (TypeName [\"B\"])]])))])" },
  { source = "function(v: any): v is Reader",
    want = "(TypeFunction _ [(PType \"v\" _ _ (TypeName [\"any\"]))] (Rets [[(Narrows \"v\" (TypeName [\"Reader\"]))]]))" },
  { source = "function(v: T?, message?: string): asserts v is T",
    want = "(TypeFunction _ [(PType \"v\" _ _ (TypeOptional (TypeName [\"T\"]))) (PType \"message\" optional _ (TypeName [\"string\"]))] (Rets [[(Narrows \"v\" (TypeName [\"T\"]) asserts)]]))" },
  { source = "function(): ({T}, {K: V})",
    want = "(TypeFunction _ _ (Rets [[(TypeArray (TypeName [\"T\"])) (TypeMap (TypeName [\"K\"]) (TypeName [\"V\"]))]]))" },
  { source = "{function(x: T): U}",
    want = "(TypeArray (TypeFunction _ [(PType \"x\" _ _ (TypeName [\"T\"]))] (Rets [[(TypeName [\"U\"])]])))" },
  { source = "function(x: T): function(y: U): V\n",
    want = "(TypeFunction _ [(PType \"x\" _ _ (TypeName [\"T\"]))] (Rets [[(TypeFunction _ [(PType \"y\" _ _ (TypeName [\"U\"]))] (Rets [[(TypeName [\"V\"])]]))]]))" },
}

local function test_each_type_makes_its_tree()
  for _, case in ipairs(TYPES) do
    same(Dump.dump(the_local("local x: " .. case.source).types[1]), case.want, case.source)
  end
end

-- declarations
local DECLARATIONS <const>: {Case} = {
  { source = "local record Point\n  x: integer\n  mut y: integer\n  tag?: string\n  [\"end\"]: string\nend",
    want = "(Record \"local\" (Binding \"Point\") _ _ _ [(FieldDecl (Binding \"x\") _ _ (TypeName [\"integer\"])) (FieldDecl (Binding \"y\") mut _ (TypeName [\"integer\"])) (FieldDecl (Binding \"tag\") _ omittable (TypeName [\"string\"])) (FieldDecl (Binding \"end\") _ _ (TypeName [\"string\"]))])" },
  { source = "local record Node is {Node}\nend",
    want = "(Record \"local\" (Binding \"Node\") _ _ (TypeArray (TypeName [\"Node\"])))" },
  { source = "local record Pair<K, V is Ordered> is Base<K>\n  key: K\n  record Inner\n    n: integer\n  end\n  enum Kind \"a\" \"b\" end\n  type Alias = {K}\nend",
    want = "(Record \"local\" (Binding \"Pair\") [(TypeParam (Binding \"K\")) (TypeParam (Binding \"V\") (TypeName [\"Ordered\"]))] [(TypeName [\"Base\"] [(TypeName [\"K\"])])] _ [(FieldDecl (Binding \"key\") _ _ (TypeName [\"K\"])) (Record _ (Binding \"Inner\") _ _ _ [(FieldDecl (Binding \"n\") _ _ (TypeName [\"integer\"]))]) (Enum _ (Binding \"Kind\") [(EnumValue \"a\") (EnumValue \"b\")]) (Alias _ (Binding \"Alias\") _ (TypeArray (TypeName [\"K\"])))])" },
  { source = "local interface Conn is Stream.Reader, Stream.Writer\n  name: string\n  read: function(self: Conn, n: integer): string?\nend",
    want = "(Interface \"local\" (Binding \"Conn\") _ [(TypeName [\"Stream\" \"Reader\"]) (TypeName [\"Stream\" \"Writer\"])] [(FieldDecl (Binding \"name\") _ _ (TypeName [\"string\"])) (FieldDecl (Binding \"read\") _ _ (TypeFunction _ [(PType \"self\" _ _ (TypeName [\"Conn\"])) (PType \"n\" _ _ (TypeName [\"integer\"]))] (Rets [[(TypeOptional (TypeName [\"string\"]))]])))])" },
  { source = "local class Counter is Resettable\n  label: string\n  mut count: integer\n  seen: mut {string}\n  function bump(self, by: integer): integer\n    self.count = self.count + by\n    return self.count\n  end\n  function __close(self) end\nend",
    want = "(Class \"local\" (Binding \"Counter\") _ [(TypeName [\"Resettable\"])] [(FieldDecl (Binding \"label\") _ _ (TypeName [\"string\"])) (FieldDecl (Binding \"count\") mut _ (TypeName [\"integer\"])) (FieldDecl (Binding \"seen\") _ _ (TypeMut (TypeArray (TypeName [\"string\"])))) (Method (Binding \"bump\") [(Param (Binding \"self\")) (Param (Binding \"by\") _ (TypeName [\"integer\"]))] (Rets [[(TypeName [\"integer\"])]]) (Block [(Assign [(Field (Name \"self\") \"count\")] [(Binary \"+\" (Field (Name \"self\") \"count\") (Name \"by\"))]) (Return [(Field (Name \"self\") \"count\")])])) (Method (Binding \"__close\") [(Param (Binding \"self\"))] _ (Block))])" },
  { source = "local class Box<T>\n  mut item: T\n  function get(self): T return self.item end\nend",
    want = "(Class \"local\" (Binding \"Box\") [(TypeParam (Binding \"T\"))] _ [(FieldDecl (Binding \"item\") mut _ (TypeName [\"T\"])) (Method (Binding \"get\") [(Param (Binding \"self\"))] (Rets [[(TypeName [\"T\"])]]) (Block [(Return [(Field (Name \"self\") \"item\")])]))])" },
  { source = "local enum Mode\n  -- the read mode\n  \"r\"\n  \"w\"\nend",
    want = "(Enum \"local\" (Binding \"Mode\") [(EnumValue \"r\") (EnumValue \"w\")])" },
  { source = "local type Key<T> = Types.Key<T>",
    want = "(Alias \"local\" (Binding \"Key\") [(TypeParam (Binding \"T\"))] (TypeName [\"Types\" \"Key\"] [(TypeName [\"T\"])]))" },
  { source = "local type Reply = function(): (true, string) | (false, string)",
    want = "(Alias \"local\" (Binding \"Reply\") _ (TypeFunction _ _ (Rets [[(TypeBool true) (TypeName [\"string\"])] [(TypeBool false) (TypeName [\"string\"])]])))" },
  { source = "local type sqlite = require(\"cosmic.internal.sqlite\")",
    want = "(Import \"local\" (Binding \"sqlite\") \"cosmic.internal.sqlite\")" },
  { source = "local class = 1\nlocal type, x = 2, 3\nlocal record, interface = 4, 5",
    want = "(Local \"local\" [(Binding \"class\")] _ [(Integer 1)]) (Local \"local\" [(Binding \"type\") (Binding \"x\")] _ [(Integer 2) (Integer 3)]) (Local \"local\" [(Binding \"record\") (Binding \"interface\")] _ [(Integer 4) (Integer 5)])" },
  { source = "local record R\n  userdata: boolean\n  match?: integer\n  mut mut: T\n  goto: V\n  record: W\nend",
    want = "(Record \"local\" (Binding \"R\") _ _ _ [(FieldDecl (Binding \"userdata\") _ _ (TypeName [\"boolean\"])) (FieldDecl (Binding \"match\") _ omittable (TypeName [\"integer\"])) (FieldDecl (Binding \"mut\") mut _ (TypeName [\"T\"])) (FieldDecl (Binding \"goto\") _ _ (TypeName [\"V\"])) (FieldDecl (Binding \"record\") _ _ (TypeName [\"W\"]))])" },
  { source = "local record M\n  mut: U\nend",
    want = "(Record \"local\" (Binding \"M\") _ _ _ [(FieldDecl (Binding \"mut\") _ _ (TypeName [\"U\"]))])" },
  { source = "local record R\n  mut [\"k\"]: T\n  mut a?: T\nend\n",
    want = "(Record \"local\" (Binding \"R\") _ _ _ [(FieldDecl (Binding \"k\") mut _ (TypeName [\"T\"])) (FieldDecl (Binding \"a\") mut omittable (TypeName [\"T\"]))])" },
}

local function test_each_declaration_makes_its_tree()
  for _, case in ipairs(DECLARATIONS) do
    same(tree(case.source), case.want, case.source)
  end
end

-- the same grammar in a declaration file
local DECLARATION_FILES <const>: {Case} = {
  { source = "local record hash\n  record Hasher\n    userdata\n    update: function(Hasher, data: string)\n    digest: function(Hasher): string?, string\n  end\n  next: function<K, V>({K: V}, K?): (K, V)\n  next: function<A>({A}, integer?): (integer, A)\n  digest: function(algorithm: string, data: string): string\nend\nreturn hash",
    want = "(Record \"local\" (Binding \"hash\") _ _ _ [(Record _ (Binding \"Hasher\") _ _ _ [(Userdata) (FieldDecl (Binding \"update\") _ _ (TypeFunction _ [(PType _ _ _ (TypeName [\"Hasher\"])) (PType \"data\" _ _ (TypeName [\"string\"]))])) (FieldDecl (Binding \"digest\") _ _ (TypeFunction _ [(PType _ _ _ (TypeName [\"Hasher\"]))] (Rets [[(TypeOptional (TypeName [\"string\"])) (TypeName [\"string\"])]])))]) (FieldDecl (Binding \"next\") _ _ (TypeFunction [(TypeParam (Binding \"K\")) (TypeParam (Binding \"V\"))] [(PType _ _ _ (TypeMap (TypeName [\"K\"]) (TypeName [\"V\"]))) (PType _ _ _ (TypeOptional (TypeName [\"K\"])))] (Rets [[(TypeName [\"K\"]) (TypeName [\"V\"])]]))) (FieldDecl (Binding \"next\") _ _ (TypeFunction [(TypeParam (Binding \"A\"))] [(PType _ _ _ (TypeArray (TypeName [\"A\"]))) (PType _ _ _ (TypeOptional (TypeName [\"integer\"])))] (Rets [[(TypeName [\"integer\"]) (TypeName [\"A\"])]]))) (FieldDecl (Binding \"digest\") _ _ (TypeFunction _ [(PType \"algorithm\" _ _ (TypeName [\"string\"])) (PType \"data\" _ _ (TypeName [\"string\"]))] (Rets [[(TypeName [\"string\"])]])))]) (Return [(Name \"hash\")])" },
  { source = "global record coroutine\n  type Function = function(...: any): any...\n  close: function(thread): boolean, string\nend\nglobal assert <const> = Library.assert\nlocal sqlite = require(\"cosmic.internal.sqlite\")\nlocal type Row = require(\"cosmic.row\")",
    want = "(Record \"global\" (Binding \"coroutine\") _ _ _ [(Alias _ (Binding \"Function\") _ (TypeFunction _ [(PType _ _ variadic (TypeName [\"any\"]))] (Rets [[(TypeName [\"any\"])]] variadic))) (FieldDecl (Binding \"close\") _ _ (TypeFunction _ [(PType _ _ _ (TypeName [\"thread\"]))] (Rets [[(TypeName [\"boolean\"]) (TypeName [\"string\"])]])))]) (Local \"global\" [(Binding \"assert\" \"const\")] _ [(Field (Name \"Library\") \"assert\")]) (Local \"local\" [(Binding \"sqlite\")] _ [(Call (Name \"require\") [(String \"cosmic.internal.sqlite\")])]) (Import \"local\" (Binding \"Row\") \"cosmic.row\")" },
  { source = "do\n  local enum FileMode\n    \"a\" \"l\"\n  end\n  global interface Closer\n    close: function(self: Closer)\n  end\nend\nreturn Library\n",
    want = "(Do (Block [(Enum \"local\" (Binding \"FileMode\") [(EnumValue \"a\") (EnumValue \"l\")]) (Interface \"global\" (Binding \"Closer\") _ _ [(FieldDecl (Binding \"close\") _ _ (TypeFunction _ [(PType \"self\" _ _ (TypeName [\"Closer\"]))]))])])) (Return [(Name \"Library\")])" },
}

local function test_each_declaration_file_makes_its_tree()
  for _, case in ipairs(DECLARATION_FILES) do
    same(tree(case.source, "decl"), case.want, case.source)
  end
end

-- places where a token decides what follows

local function test_a_call_opens_on_its_line()
  -- A `(` that begins a line begins a statement, so a call is not continued
  -- onto the next line by accident.
  same(tree("local x = f()\n(g)()"),
    "(Local \"local\" [(Binding \"x\")] _ [(Call (Name \"f\"))]) (CallStat (Call (Paren (Name \"g\"))))", "newline")
  same(tree("local x = f()(g)"),
    "(Local \"local\" [(Binding \"x\")] _ [(Call (Call (Name \"f\")) [(Name \"g\")])])", "same line")
end

local function test_a_bar_that_begins_a_line_in_a_match_arm_starts_the_next_arm()
  -- Else `return v` would take `| (false, e)` for a bitwise or.
  same(tree("match f() do\n  | (true, v) then return v\n  | (false, e) then error(e)\nend"),
    "(Match (Call (Name \"f\")) [(MatchArm [(PatBool true) (PatBind (Binding \"v\"))] (Block [(Return [(Name \"v\")])])) " ..
      "(MatchArm [(PatBool false) (PatBind (Binding \"e\"))] (Block [(CallStat (Call (Name \"error\") [(Name \"e\")]))]))])",
    "arms")
  -- A type alias before the next arm does not take the bar for a union.
  local arms = clean("match f() do\n  | (true, v) then local type A = T?\n  | (false, e) then local type B = function(): (X)\nend").chunk.body.stats[1]
  assert(arms is Ast.Match and #arms.arms == 2, "two arms")
  same(tree("local x = a\n| b"), "(Local \"local\" [(Binding \"x\")] _ [(Binary \"|\" (Name \"a\") (Name \"b\"))])", "outside a match")
  same(tree("match f() do\n  | (true, v) then local g = function() return v\n    | w end\nend"),
    "(Match (Call (Name \"f\")) [(MatchArm [(PatBool true) (PatBind (Binding \"v\"))] (Block [(Local \"local\" [(Binding \"g\")] _ " ..
      "[(FunctionLit (Fn _ _ (Block [(Return [(Binary \"|\" (Name \"v\") (Name \"w\"))])])))])]))])", "in a function in an arm")
end

local function test_a_reserved_word_stands_where_a_field_name_does()
  same(tree("s:match(p)\nt.continue = t.userdata\nx.goto = x.as"),
    "(CallStat (MethodCall (Name \"s\") \"match\" [(Name \"p\")])) " ..
      "(Assign [(Field (Name \"t\") \"continue\")] [(Field (Name \"t\") \"userdata\")]) " ..
      "(Assign [(Field (Name \"x\") \"goto\")] [(Field (Name \"x\") \"as\")])", "after . and :")
  same(Dump.dump(the_local("local t = { match = 1, as = 2, goto = 3, ['k'] = 4 }").values[1]),
    "(Table [(Named \"match\" (Integer 1)) (Named \"as\" (Integer 2)) (Named \"goto\" (Integer 3)) (Keyed (String \"k\") (Integer 4))])",
    "before =")
end

local function test_a_name_followed_by_an_equals_in_a_table_is_a_key_and_any_other_name_begins_an_expression()
  same(Dump.dump(the_local("local t = { a == 1, a = 1, a }").values[1]),
    "(Table [(Positional (Binary \"==\" (Name \"a\") (Integer 1))) (Named \"a\" (Integer 1)) (Positional (Name \"a\"))])", "table")
end

local function test_a_comma_in_a_type_list_ends_it_where_a_parameter_begins()
  -- The type of `f` returns `A, B` and `c` is the next parameter.
  same(Dump.dump(the_local("local x: function(f: function(): A, B, c: C)").types[1]),
    "(TypeFunction _ [(PType \"f\" _ _ (TypeFunction _ _ (Rets [[(TypeName [\"A\"]) (TypeName [\"B\"])]]))) (PType \"c\" _ _ (TypeName [\"C\"]))])",
    "name and colon")
  same(Dump.dump(the_local("local x: function(f: function(): A, c?: C)").types[1]),
    "(TypeFunction _ [(PType \"f\" _ _ (TypeFunction _ _ (Rets [[(TypeName [\"A\"])]]))) (PType \"c\" optional _ (TypeName [\"C\"]))])",
    "name, question mark and colon")
  same(Dump.dump(the_local("local x: function(f: function(): A, ...: C)").types[1]),
    "(TypeFunction _ [(PType \"f\" _ _ (TypeFunction _ _ (Rets [[(TypeName [\"A\"])]]))) (PType _ _ variadic (TypeName [\"C\"]))])",
    "rest")
  same(Dump.dump(the_local("local a, b: integer, string = f()").types[1]), "(TypeName [\"integer\"])", "in a local")
end

-- the tree around the nodes

local function the_record(source: string): Ast.Record
  local stat = clean(source).chunk.body.stats[1]
  assert(stat is Ast.Record, "not a record: " .. source)
  return stat
end

local function lines(comments: {Lexer.Comment} | nil): string
  local texts: {string} = {}
  for i, c in ipairs(comments or {}) do
    texts[i] = c.text
  end
  return table.concat(texts, "|")
end

local function test_a_doc_comment_is_the_run_of_comments_on_the_lines_before_a_declaration()
  same(lines(the_local("-- a\n-- b\nlocal x = 1").bindings[1].doc), "-- a|-- b", "local")
  same(lines(the_local("-- a\n\nlocal x = 1").bindings[1].doc), "", "a blank line ends the run")
  same(lines(the_local("-- a\n\n-- b\nlocal x = 1").bindings[1].doc), "-- b", "only the last run")
  local after = clean("local y = 1 -- trailing\nlocal x = 2").chunk.body.stats[2]
  assert(after is Ast.Local)
  same(lines(after.bindings[1].doc), "", "the end of a line of code is no doc")
  same(lines(the_record("-- the record\nlocal record R\n  -- the field\n  a: integer\nend").name.doc), "-- the record", "record")
  local r = the_record("local record R\n  -- the field\n  a: integer\n  -- never\n\n  b: integer\nend")
  local a, b = r.members[1], r.members[2]
  assert(a is Ast.FieldDecl and b is Ast.FieldDecl)
  same(lines(a.doc), "-- the field", "field")
  same(lines(b.doc), "", "field after a blank line")
  local c = clean("local class C\n  -- the method\n  function m(self) end\nend").chunk.body.stats[1]
  assert(c is Ast.Class)
  local m = c.members[1]
  assert(m is Ast.Method)
  same(lines(m.doc), "-- the method", "method")
  local e = clean("local enum E\n  -- first\n  \"a\"\n  \"b\"\nend").chunk.body.stats[1]
  assert(e is Ast.Enum)
  same(lines(e.values[1].doc) .. "/" .. lines(e.values[2].doc), "-- first/", "enum values")
  local f = clean("-- the function\nlocal function f() end").chunk.body.stats[1]
  assert(f is Ast.LocalFunction)
  same(lines(f.name.doc), "-- the function", "local function")
end

--- The node with `id` below `node`, or nil.
local function find(node: Ast.Node, id: integer): Ast.Node
  local base: Ast.Base = node
  if base.id == id then
    return node
  end
  local found: {Ast.Node} = {}
  Ast.children(node, function(child: Ast.Node)
    if found[1] == nil then
      found[1] = find(child, id)
    end
  end)
  return found[1]
end

local function test_nodes_are_numbered_in_a_pre_order_walk_from_the_chunk()
  local chunk = clean("local a = 1 + 2").chunk
  local local_stat = chunk.body.stats[1]
  assert(local_stat is Ast.Local)
  local value = local_stat.values[1]
  assert(value is Ast.Binary)
  assert(chunk.id == 1 and chunk.body.id == 2 and local_stat.id == 3, "chunk, block, local")
  assert(local_stat.bindings[1].id == 4 and value.id == 5 and value.left.id == 6, "binding, binary, left")
  local right = value.right
  local last: Ast.Base = right
  assert(last.id == 7, "right is the last node")
  assert(Ast.number(chunk) == 7, "number answers how many")
end

local function test_a_require_with_a_literal_module_is_listed_with_its_node()
  local chunk = clean("local a = require(\"m.one\")\nlocal b = require(name)\nlocal type t = require(\"m.two\")\nrequire(\"m.three\").f()").chunk
  local modules: {string} = {}
  for i, r in ipairs(chunk.requires) do
    modules[i] = r.module
    local node = find(chunk, r.node)
    assert(node is Ast.Call or node is Ast.Import, "node " .. r.node .. " of " .. r.module)
  end
  same(table.concat(modules, " "), "m.one m.two m.three", "requires")
end

local function test_a_node_spans_its_tokens_and_a_block_its_terminator()
  local chunk = clean("local x = f(1)\nif x then\n  y()\nend").chunk
  local first = chunk.body.stats[1]
  local second = chunk.body.stats[2]
  assert(first is Ast.Local and second is Ast.If)
  local call = first.values[1]
  local span = Ast.span(chunk, call)
  assert(span.y == 1 and span.x == 11 and span.yend == 1 and span.xend == 14, "the call f(1)")
  span = Ast.span(chunk, first)
  assert(span.x == 1 and span.xend == 14, "the local")
  local body = second.arms[1].body
  span = Ast.span(chunk, body)
  assert(span.y == 3 and span.yend == 4 and span.x == 3 and span.xend == 3, "the block ends at the end")
  assert(body.close == body.last and chunk.tokens[body.close].text == "end", "close is the terminator")
  span = Ast.span(chunk, second)
  assert(span.y == 2 and span.yend == 4, "the if")
  assert(chunk.first == 1 and chunk.last == #chunk.tokens and chunk.body.last == #chunk.tokens, "the chunk ends at EOF")
end

local function test_the_elseif_arms_of_an_if_do_not_overlap()
  local stat = clean("if a then b() elseif c then d() else e() end").chunk.body.stats[1]
  assert(stat is Ast.If)
  local else_body = stat.else_body
  assert(else_body ~= nil)
  local one, two = stat.arms[1], stat.arms[2]
  assert(one.last < two.first, "an arm ends at its `elseif` and the next begins after it")
  assert(two.last < else_body.first, "the last arm ends at `else`")
end

local function test_the_inner_type_ends_at_the_token_that_closes_two_lists()
  local t = the_local("local x: A<B<C>>").types[1]
  assert(t is Ast.TypeName)
  local inner = t.args[1]
  assert(inner is Ast.TypeName)
  assert(inner.last == t.last, "both end at the one `>>`")
end

local function test_a_function_with_a_colon_or_a_long_path_is_a_function_statement_in_the_tree()
  local colon = parse("function R:m() end")
  assert(colon.errors[1].code == "method_in_record")
  assert(Dump.dump(colon.chunk.body.stats[1]) == "(Function [(Name \"R\") (Name \"m\")] _ (Fn _ _ (Block)))", "still a Function")
end

local function test_every_code_is_catalogued_once_with_the_lexers_first()
  local seen: {string: boolean} = {}
  for _, code in ipairs(Parser.codes) do
    assert(not seen[code], "twice: " .. code)
    seen[code] = true
  end
  for i, code in ipairs(Lexer.codes) do
    assert(tostring(Parser.codes[i]) == tostring(code), "the lexer's codes come first: " .. code)
  end
  assert(#Parser.codes > #Lexer.codes)
end

local function test_a_node_of_no_token_is_empty_at_the_token_it_stands_before()
  local parsed = parse("local x =\nlocal y = 1")
  local stat = parsed.chunk.body.stats[1]
  assert(stat is Ast.Local)
  local missing = stat.values[1]
  assert(missing is Ast.Error)
  local span = Ast.span(parsed.chunk, missing)
  assert(span.y == 2 and span.x == 1 and span.yend == 2 and span.xend == 0, "empty before `local`")
end
