--- Structural rewrite over [`build.syntax_match`] patterns: every match in a tree found, and a replacement template
--- spliced over the original source bytes.
---
--- The result is the raw spliced source: byte for byte the original wherever no hit landed, the template's bytes where
--- one did, nothing reflowed. Rendering is the caller's: [`build.fix`] parses the spliced source again and writes it
--- through its renderer, and rendering here too would render twice.
---
--- A `keep` predicate narrows the hits before anything is spliced. A rewrite that would delete a comment is refused
--- instead of applied ([`dropped_comments`]), and the refusal reported. It is one pass over one file: no fixpoint, no
--- project-wide loop.
---
--- A replacement of exactly `""` against a call that is a statement removes the whole line range of the call, not only
--- its bytes, so deleting `test_a()` leaves no blank line; the comments of that wider range are held to the same refusal.
--- A call inside a larger statement is an expression, and an empty replacement removes its bytes only.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Match = require("build.syntax_match")
local Node = require("build.syntax_node")

local record Rewrite
  --- A match found in a file, with the captures of the pattern.
  type Hit = Match.Hit

  --- A hit left alone because its replacement would delete a comment.
  record Refusal
    node: Ast.Node
    --- The comments that would have gone, as written.
    comments: {string}
  end

  --- What one rewrite did.
  record Result
    --- The source with every accepted hit replaced; the bytes of a refused hit are as they were.
    code: string
    refused: {Refusal}
    --- The accepted hits, in source order, with the nodes of the original tree.
    edits: {Hit}
  end

  --- Every match of `pattern` in the tree of `chunk`, in source order.
  find_all: function(pattern: Match.Pattern, chunk: Ast.Chunk): {Hit}

  --- Replaces each match of `pattern` in `source`, a file named `name`, with `replacement`, written in the pattern's
  --- `$NAME` syntax: a capture stands for the bytes it matched, comments included. Splicing runs back to front so
  --- that offsets stay valid. `keep` limits the hits replaced. nil and why where `source` does not parse.
  rewrite: function(source: string, name: string, pattern: Match.Pattern, replacement: string,
                    keep?: function(Ast.Node): boolean): Result?, string
end

function Rewrite.find_all(pattern: Match.Pattern, chunk: Ast.Chunk): {Match.Hit}
  local hits = Match.find_all(pattern, chunk, chunk)
  -- An outer node comes before one it holds that starts at the same token: its id is lower.
  table.sort(hits, function(a: Match.Hit, b: Match.Hit): boolean
    local af, bf = Node.base(a.node).first, Node.base(b.node).first
    if af ~= bf then
      return af < bf
    end
    return Node.base(a.node).id < Node.base(b.node).id
  end)
  return hits
end

--- The 1-based byte offset of the start of each line of `source`; a line break is `\n`, `\r`, `\r\n` or `\n\r`, as the
--- lexer reads it.
local function line_starts(source: string): {integer}
  local starts: mut {integer} = { 1 }
  local pos = 1
  while true do
    local at = source:find("[\r\n]", pos)
    if at == nil then
      break
    end
    local this = source:sub(at, at)
    local after = source:sub(at + 1, at + 1)
    if (after == "\r" or after == "\n") and after ~= this then
      at = at + 1
    end
    starts[#starts + 1] = at + 1
    pos = at + 1
  end
  return starts
end

--- A byte range, inclusive.
local type Span = Node.Range

--- A capture that took nothing stands for no source.
local function empty(capture: Match.Capture): boolean
  return capture.last < capture.first
end

local function capture_span(chunk: Ast.Chunk, capture: Match.Capture): Span
  local tokens = chunk.tokens
  return { first = Lexer.offset(tokens, capture.first), last = Lexer.stop(tokens, capture.last) - 1 }
end

--- The bytes of the next whole identifier `name` in `text` at or after `init`: a capture name that prefixes another
--- (`_X` in `_XS`) is not an occurrence of it.
local function find_name(text: string, name: string, init: integer): integer?, integer?
  local pos = init
  while pos <= #text + 1 do
    local a, b = text:find(name, pos, true)
    if a == nil or b == nil then
      return nil, nil
    end
    local before = a > 1 and text:sub(a - 1, a - 1) or ""
    local after = b < #text and text:sub(b + 1, b + 1) or ""
    if not before:match("[%w_]") and not after:match("[%w_]") then
      return a, b
    end
    pos = a + 1
  end
  return nil, nil
end

--- `text` with each whole-identifier `name` replaced by `value`, as literal bytes.
local function substitute(text: string, name: string, value: string): string
  local out: mut {string} = {}
  local pos = 1
  while true do
    local a, b = find_name(text, name, pos)
    if a == nil or b == nil then
      out[#out + 1] = text:sub(pos)
      break
    end
    out[#out + 1] = text:sub(pos, a - 1)
    out[#out + 1] = value
    pos = b + 1
  end
  return table.concat(out)
end

--- The byte ranges of the captures the template reuses: the source a rewrite carries forward.
local function kept_ranges(chunk: Ast.Chunk, caps: {string: Match.Capture}, template: string): {Span}
  local kept: mut {Span} = {}
  for name, capture in pairs(caps) do
    if find_name(template, name, 1) ~= nil and not empty(capture) then
      kept[#kept + 1] = capture_span(chunk, capture)
    end
  end
  return kept
end

--- The comments in the bytes `a` to `b` that no kept range covers, as written: those a rewrite there would delete.
local function dropped_comments(chunk: Ast.Chunk, a: integer, b: integer, kept: {Span}): {string}
  local dropped: mut {string} = {}
  local comments_at = chunk.tokens.comments
  for token = 1, #chunk.tokens.kind do
    for _, comment in ipairs(comments_at[token] or {}) do
      if comment.offset >= a and comment.offset <= b then
        local covered = false
        for _, range in ipairs(kept) do
          if comment.offset >= range.first and comment.offset <= range.last then
            covered = true
            break
          end
        end
        if not covered then
          dropped[#dropped + 1] = comment.text
        end
      end
    end
  end
  return dropped
end

--- The bytes of the lines `node` touches, indentation and the break after the last included (none at the end of the
--- file), so that removing them leaves no blank line.
local function line_range(chunk: Ast.Chunk, starts: {integer}, length: integer, node: Ast.Node): integer, integer
  local base = Node.base(node)
  local tokens = chunk.tokens
  local a = starts[Lexer.y(tokens, base.first)]
  local b = length
  local last_end = Lexer.yend(tokens, base.last)
  if last_end + 1 <= #starts then
    b = starts[last_end + 1] - 1
  end
  return a, b
end

function Rewrite.rewrite(source: string, name: string, pattern: Match.Pattern, replacement: string,
                         keep?: function(Ast.Node): boolean): Rewrite.Result?, string
  local chunk, why = Node.parse(source, name)
  if chunk == nil then
    return nil, why
  end
  local template = Match.desugar(replacement)
  local hits: mut {Match.Hit} = {}
  for _, hit in ipairs(Rewrite.find_all(pattern, chunk)) do
    if keep == nil or keep(hit.node) then
      hits[#hits + 1] = hit
    end
  end
  local parents = Node.parents(chunk)
  local starts = line_starts(source)
  local out = source
  local refused: mut {Rewrite.Refusal} = {}
  local edits: mut {Match.Hit} = {}
  for i = #hits, 1, -1 do
    local hit = hits[i]
    local parent = parents[Node.base(hit.node).id]
    local whole = Node.range(chunk, hit.node)
    local a, b = whole.first, whole.last
    if template == "" and parent ~= nil and (parent.kind == "CallStat") then
      a, b = line_range(chunk, starts, #source, parent)
    end
    local dropped = dropped_comments(chunk, a, b, kept_ranges(chunk, hit.caps, template))
    if #dropped > 0 then
      refused[#refused + 1] = { node = hit.node, comments = dropped }
    else
      local text = template
      for capture_name, capture in pairs(hit.caps) do
        local value = ""
        if not empty(capture) then
          local span = capture_span(chunk, capture)
          value = source:sub(span.first, span.last)
        end
        text = substitute(text, capture_name, value)
      end
      out = out:sub(1, a - 1) .. text .. out:sub(b + 1)
      table.insert(edits, 1, hit)
    end
  end
  return { code = out, refused = refused, edits = edits }, ""
end

return Rewrite
