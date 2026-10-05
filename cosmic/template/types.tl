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
  --- `text`, `attr` and `url` are the three places a slot can stand in
  --- an `html` template (see `markup`).
  enum Slot
    "plain"
    "text"
    "attr"
    "url"
  end

  --- What a node of the tree is. `if` and `with` hold their branches,
  --- `range` its body; `interp` is a `{{.a.b}}` and `text` literal text.
  enum Kind
    "text"
    "interp"
    "if"
    "range"
    "with"
  end

  --- What a word inside an action is: a dotted field path starting with
  --- `.`, a bare word, or the `|` between pipeline stages.
  enum Part
    "field"
    "word"
    "pipe"
  end

  --- One word of an action, with where it began (a byte column, from 1).
  record Token
    --- What the word is.
    kind: Part
    --- The word as written.
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

  --- A value: a path of fields from dot (empty for dot itself), then
  --- each stage applied to what came before.
  record Pipeline
    --- The field names after dot, none for dot itself.
    path: {string}
    --- The stages, applied first to last.
    stages: {Stage}
  end

  --- One arm of an `if` or `with`: its condition (none for `else`), its
  --- body and where its action stands.
  record Branch
    --- The condition or value, nil for `else`.
    pipeline: Pipeline
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
    pipeline: Pipeline
    --- A block's arms: `if`'s in order, `with`'s and `range`'s first.
    branches: {Branch}
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
    --- What the template makes.
    mode: Mode
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
