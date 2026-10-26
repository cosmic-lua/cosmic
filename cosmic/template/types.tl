--- The shapes [`cosmic.template`]'s stages hand one another: tokens, the
--- items the lexer cuts a template into, and the tree the parser makes of
--- them. They are all data with no behavior, in a module of their own so
--- that the stages stay apart (`lex`, `parse`, `context`, `codegen`) and
--- none imports another's internals. Private to [`cosmic.template`].

local record Types
  --- The two kinds of output a template makes. `html` escapes by the
  --- markup around each slot and returns an HTML value; `text` escapes
  --- nothing and returns a string.
  enum Mode
    "html"
    "text"
  end

  --- What an interpolation's value is made into where it lands.
  --- `plain` is any slot of a `text` template: it is spliced as it is.
  --- `text`, `rtext` (the text of `<title>` and `<textarea>`, which
  --- takes no markup), `ftext` (text inside `<svg>`, `<math>` or
  --- `<select>`, which takes no markup either), `attr`, `url` (a whole URL),
  --- `url_local` (a whole URL that must be a same-origin reference, in an
  --- attribute a dialect says so of), `urlpart` (a piece of one, after
  --- literal text), `json` (the whole value, a `SafeJson`) and `selector`
  --- (an identifier after `#` or `.` in a CSS selector) are the places a
  --- slot can stand in an `html` template (see `markup`).
  enum Slot
    "plain"
    "text"
    "rtext"
    "ftext"
    "attr"
    "url"
    "url_local"
    "urlpart"
    "json"
    "selector"
  end

  --- What a slot is in an attribute that a dialect classifies. `url` and
  --- `url_local` take a URL (a whole one, or a part after literal text),
  --- `json` the whole value as JSON, `selector` an identifier piece of a CSS
  --- selector, and `refused` nothing: a slot there is an error.
  enum Class
    "url"
    "url_local"
    "json"
    "selector"
    "refused"
  end

  --- How a dialect treats a slot in one attribute (or family of them).
  record Rule
    --- What a slot there is.
    class: Class
    --- For `refused`, the end of the refusal after "a slot in the 'x'
    --- attribute ": what a slot there would be. Else "".
    why: string
  end

  --- A rule for every attribute whose name begins with `prefix`.
  record Prefix
    --- The start of the attribute names, lower case.
    prefix: string
    --- What a slot in them is.
    rule: Rule
  end

  --- The attribute vocabulary of one dialect, as data: see
  --- [`cosmic.template.dialect`].
  record Def
    --- The name `{{use name}}` gives it.
    name: string
    --- The version of the framework whose source the table was read from.
    targets: string
    --- The rule of each attribute that has one, by lower case name.
    exact: {string: Rule}
    --- The rules of families of attributes; the longest prefix wins.
    prefixes: {Prefix}
    --- The attribute name families the framework also reads with a `data-`
    --- prefix (`hx-`).
    families: {string}
    --- The attributes of the framework the dialect has looked at and found
    --- to need no rule: a slot in one is escaped as any attribute's is.
    plain: {string}
  end

  --- What a node of the tree is. `if`, `with` and `range` hold their
  --- branches; `interp` is a value such as `{{.a.b}}` and `text` literal
  --- text.
  enum Kind
    "text"
    "interp"
    "if"
    "range"
    "with"
  end

  --- What a word inside an action is: a dotted field path starting with
  --- `.`, a variable starting with `$` (and any field path after it), a
  --- bare word, the `|` between pipeline stages, a quoted string, or the
  --- `,` and `:=` of a range's bindings.
  enum Part
    "field"
    "variable"
    "word"
    "pipe"
    "string"
    "comma"
    "declare"
  end

  --- One word of an action, with where it began (a byte column, from 1).
  record Token
    --- What the word is.
    kind: Part
    --- The word as written; a string's bytes, its quotes and escapes gone.
    value: string
    --- Where it begins: its line, from 1.
    line: integer
    --- Its column, a byte in the line, from 1.
    col: integer
  end

  --- What the lexer cuts a template into: a run of literal text (after
  --- any trim marker has been applied, so `line` and `col` are where its
  --- first byte is) or one `{{ ... }}` action, whose `line` and `col` are
  --- those of its `{{` and `end_line` the line of its `}}`.
  record Item
    --- True for an action, false for literal text.
    action: boolean
    --- The text of literal text, with trimmed whitespace gone.
    text: string
    --- The words of an action, in order, without its braces.
    tokens: {Token}
    --- The line of the item's first byte (of an action, its `{{`).
    line: integer
    --- Its column.
    col: integer
    --- The line the item ends on: an action's `}}`.
    end_line: integer
  end

  --- The lexer's answer: its items, and how many lines the template
  --- has (one more than its newlines).
  record Lexed
    --- The items, in the order they stand in the template.
    items: {Item}
    --- The template's line count.
    lines: integer
  end

  --- A pipeline stage: the function `func` of the module `module_path`.
  record Stage
    --- The module's import path, as `require` is given it.
    module_path: string
    --- The function's name in that module.
    func: string
  end

  --- What a pipeline's path starts from: dot, `$` (the value `render` is
  --- given), or a variable a range binds.
  enum Head
    "dot"
    "root"
    "variable"
  end

  --- A value: a path of fields from its head (empty for the head itself),
  --- then each stage applied to what came before.
  record Pipeline
    --- What the path starts from.
    head: Head
    --- The variable's name, without its `$`, when `head` is `variable`;
    --- else "".
    name: string
    --- The field names after the head, none for the head itself.
    path: {string}
    --- The stages, applied first to last.
    stages: {Stage}
  end

  --- One arm of an `if`, `with` or `range`: its condition (none for
  --- `else`), the variables a range's own arm binds, its body and where
  --- its action stands.
  record Branch
    --- The condition or value, nil for `else`.
    pipeline?: Pipeline
    --- The name a range binds each element's index to, without its `$`,
    --- or "".
    index: string
    --- The name a range binds each element to, without its `$`, or "".
    element: string
    --- What the arm holds.
    body: {Node}
    --- Where the arm's action begins.
    line: integer
    --- Its column.
    col: integer
    --- The line its action ends on.
    end_line: integer
  end

  --- A node of the tree. `line` and `col` are where it starts, `end_line`
  --- the line its action ends on, and for a block `close_line` the line
  --- of its `{{end}}`. `ctx` is set by `context` on every interpolation.
  record Node
    --- What the node is.
    kind: Kind
    --- Where it starts: its line.
    line: integer
    --- Its column.
    col: integer
    --- The line its action ends on.
    end_line: integer
    --- The line of a block's `{{end}}`.
    close_line: integer
    --- A text node's literal text.
    text: string
    --- An interpolation's value.
    pipeline?: Pipeline
    --- A block's arms in order: a `with` or `range` has its own first and
    --- then its `else`, if any.
    branches: mut {Branch}
    --- Where an interpolation's value lands, once `context` has run.
    ctx: Slot
  end

  --- The names that cannot follow a `.` in Lua (`global`, which Lua 5.5
  --- reserves, among them): a field with one is written `d["end"]` rather
  --- than `d.end`, and a record cannot be named one.
  keywords: {string: boolean}

  --- A parsed template: the record it takes, where from, its mode, its
  --- body, and its line count.
  record Template
    --- The record's name in its module.
    type_name: string
    --- The module's import path.
    import_path: string
    --- The line of the `{{type}}` action, after any blank lines.
    line: integer
    --- What the template makes.
    mode: Mode
    --- The dialects it uses (`{{use name}}`), in order.
    dialects: {string}
    --- The nodes after the declaration.
    body: {Node}
    --- The template's line count.
    lines: integer
  end
end

local types: Types = {
  keywords = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
    ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true,
    ["global"] = true, ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true,
    ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true,
  },
}

return types
