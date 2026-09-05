--- Experiment: ast-grep-style structural search & replace for Teal, built
--- directly on tl's own lexer/parser. Not a cosmic module -- a spike run
--- with `bin/cosmic tlgrep.tl <pattern> <file> [replacement]`.
---
--- The pattern is parsed with the SAME parser as the target, so it is a
--- real (partial) Teal AST rather than a regex. `$NAME` is a single-node
--- capture, `$$$NAME` a rest-capture matching zero or more trailing list
--- elements (ast-grep's own spelling) -- rewritten to valid Teal
--- identifiers (`_NAME` / `___NAME`) before lexing, since `$` itself
--- isn't a legal identifier character and the pattern must parse as real
--- Teal to become a real AST. Matching is a fully generic recursive
--- structural walk: every named field the PATTERN specifies must match
--- (subset matching -- a partial pattern like `if $C then ... end` need
--- not spell out every elseif/else block), so it isn't special-cased per
--- node kind and generalizes to statement/block patterns for free.
--- A match's span is computed by recursing to the leftmost/rightmost
--- descendant token (tl only sets yend/xend at ~12 parser call sites),
--- precise enough to splice the ORIGINAL bytes outside the matched
--- range. The spliced result is re-run through cosmic.format so
--- replace doesn't need to hand-preserve inter-argument whitespace, and
--- a match that would silently drop a comment inside it (in the
--- "connective tissue" between captures) is refused rather than applied.
local tl = require("tl")
local fs = require("cosmic.fs")
local format = require("cosmic.format")

local type M = {any: any} -- generic AST node/map view, matching lines.tl's style

--- Set once in `main`, before any span computation -- see `node_end`'s
--- gate on trusting a node's own `yend`/`xend`, which needs to peek at
--- the actual source character there to tell a real delimiter from
--- contaminated bookkeeping (see `node_end`'s own comment). A file-level
--- upvalue rather than a threaded parameter: acceptable for a
--- single-file spike script, not something a real module should do.
local g_source: string
local g_line_starts: {integer}

--- Is the character at 1-based (y, x) one of the close-bracket
--- characters that legitimately terminate a bracketed list (a call's
--- `)`, a table constructor's `}`, an index's `]`)?
local function is_close_bracket_at(y: integer, x: integer): boolean
  if not g_source or not g_line_starts or not g_line_starts[y] then
    return false
  end
  local ch = g_source:sub(g_line_starts[y] + x - 1, g_line_starts[y] + x - 1)
  return ch == ")" or ch == "]" or ch == "}"
end

--- Positional/bookkeeping fields no pattern should ever compare
--- generically: source position (differs between pattern and target by
--- construction), the lexer's per-token comment attachments (handled
--- separately, not part of structural identity), and `tk` -- which IS
--- semantic on a "variable"/"identifier"/"string" leaf (compared
--- explicitly for those kinds below) but is otherwise just whichever
--- token happened to open a compound node ("statements", "if_block")
--- and differs incidentally between pattern and target even on a real
--- structural match, confirmed by inspection (see the "if" spike).
local IGNORE_KEYS: {string: boolean} = {
  y = true, x = true, yend = true, xend = true, f = true, comments = true,
  tk = true,
}

--- Is `tk` a capture-name spelling: leading underscore, then uppercase?
--- (`$NAME` in surface syntax, rewritten before lexing -- see `desugar`.)
local function is_capture(tk: any): boolean
  return tk is string and tk:match("^_[A-Z][A-Z0-9_]*$") ~= nil
end

--- Is `tk` a rest-capture spelling: three leading underscores, then
--- uppercase -- matches a run of zero or more trailing list elements.
--- (`$$$NAME` in surface syntax.)
local function is_rest_capture(tk: any): boolean
  return tk is string and tk:match("^___[A-Z][A-Z0-9_]*$") ~= nil
end

--- Rewrite ast-grep-style `$NAME`/`$$$NAME` metavariables into valid Teal
--- identifiers so the pattern lexes as real source. Safe because pattern
--- text is only ever MATCHED, never spliced back into anything -- the
--- byte positions this substitution shifts are never used for output.
local function desugar(pattern_src: string): string
  local out = pattern_src:gsub("%$%$%$([%u_][%w_]*)", "___%1")
  out = out:gsub("%$([%u_][%w_]*)", "_%1")
  return out
end

--- Array part of a mixed AST table.
local function arr(t: M): {any}
  return t as {any} -- cast: array view of a mixed ast map
end

--- The start position of `node`'s own SPAN. tl's own y/x on a node is
--- where the PARSER CONSTRUCTED it, which for a call/index/binary-op
--- node is often mid-expression -- e.g. `os.execute(cmd)`'s "op"/
--- "@funcall" node records the position right after "(", not "os"'s.
--- The real start is the minimum position over the whole subtree.
local function node_start(node: M, seen: {any: boolean}): integer, integer
  local by, bx = node["y"] as integer, node["x"] as integer
  if seen[node] then
    return by, bx
  end
  seen[node] = true
  -- A child field is either a real node (has its own "y") or a BARE
  -- array of nodes (`if_blocks`, a block's own array part) with no
  -- position of its own -- Teal's `is M` matches any table at runtime
  -- (`M = {any:any}` structurally covers `{any}` too), so this must
  -- branch on the actual "y" field, not on an `is {any}` check that
  -- would never be reached (`collect`'s walk gets this right the same
  -- way; the original version here didn't, and silently never
  -- descended into if_blocks/etc. at all).
  local function consider(child: any)
    if not (child is M) then
      return
    end
    local ct = child as M
    local cy0 = ct["y"]
    if cy0 is integer then
      local cy, cx = node_start(ct, seen)
      if cy < by or (cy == by and cx < bx) then
        by, bx = cy, cx
      end
    else
      for _, e in ipairs(arr(ct)) do
        consider(e)
      end
    end
  end
  for _, v in ipairs(arr(node)) do
    consider(v)
  end
  for k, v in pairs(node) do
    if not (k is integer) then
      consider(v)
    end
  end
  return by, bx
end

--- The end position of `node`'s own SPAN (inclusive last column of its
--- last token). `yend`/`xend` need a two-way gate, confirmed by reading
--- tl's parser, not by guessing:
---   - a "statements" (block) node's yend/xend IS its true end -- the
---     terminator that stopped it (`end`/`else`/`until`) is the ONLY
---     place a block's true close lives, since an empty or short block
---     has no descendant token that reaches it (`parse_statements`,
---     tl.lua:4777).
---   - any OTHER node's yend/xend comes from `parse_list`'s generic
---     `end_at(list, ps.tokens[i])` (tl.lua:2776-2781) -- correct when
---     the terminator is a real delimiter belonging to this node itself
---     (a call's `)`, a table's `}`), but for a BARE list with no
---     delimiter of its own (`return a + b`'s expression_list, stopped
---     only by the ENCLOSING block's `end` three lines later) it's
---     someone else's terminator entirely. There's no kind that always
---     tells the two apart -- "expression_list" is both -- so gate on
---     the actual character at that position: trust it only when it's
---     a close-bracket, otherwise fall back to leaf recursion.
--- Cycle guard for the same reason `_tool/coverage/lines.tl`'s walk
--- needs one -- tl ASTs share tables by identity.
local function node_end(node: M, seen: {any: boolean}): integer, integer
  local by, bx = node["y"] as integer, node["x"] as integer
  local btk = node["tk"]
  if btk is string then
    bx = bx + #btk - 1
  end
  local yend, xend = node["yend"], node["xend"]
  if yend is integer and xend is integer then
    if node["kind"] == "statements" or is_close_bracket_at(yend, xend) then
      if yend > by or (yend == by and xend > bx) then
        by, bx = yend, xend
      end
    end
  end
  if seen[node] then
    return by, bx
  end
  seen[node] = true
  -- Same "bare array field" fix as node_start's consider() -- see its
  -- comment for why the `is {any}` fallback below it used to be dead.
  local function consider(child: any)
    if not (child is M) then
      return
    end
    local ct = child as M
    local cy0 = ct["y"]
    if cy0 is integer then
      local cy, cx = node_end(ct, seen)
      if cy > by or (cy == by and cx > bx) then
        by, bx = cy, cx
      end
    else
      for _, e in ipairs(arr(ct)) do
        consider(e)
      end
    end
  end
  for _, v in ipairs(arr(node)) do
    consider(v)
  end
  for k, v in pairs(node) do
    if not (k is integer) then
      consider(v)
    end
  end
  return by, bx
end

--- A synthetic span-only node: not real AST, just enough (y/x/yend/xend)
--- for node_start/node_end to treat it like one. Used to capture a
--- rest-capture's whole matched slice as one substitutable span.
local function span_node(first: M, last: M): M
  local fy, fx = node_start(first, {})
  local ly, lx = node_end(last, {})
  return {y = fy, x = fx, yend = ly, xend = lx}
end

--- The rest-capture NAME if `node` is a rest-capture marker, else nil.
--- Two surface shapes, because "a bare capture name" isn't always a
--- legal Teal statement: `$$$NAME` in an expression position (call
--- args, a table's items) desugars to the bare identifier `___NAME`,
--- which parses fine as an expression but NOT as a statement (Lua/Teal
--- has no bare-expression statements). In a statement-LIST position (a
--- block, an if-branch's body) the same `$$$NAME` marker instead needs
--- to look like `___NAME()` -- a zero-arg call, which IS a valid
--- statement -- so a block pattern like `if $C then $$$BODY end` parses.
local function rest_capture_name(node: M): string | nil
  if node["kind"] == "variable" and is_rest_capture(node["tk"]) then
    return node["tk"] as string
  end
  if node["kind"] == "op" then
    local op = node["op"] as M
    local e1 = node["e1"] as M
    if op["op"] == "@funcall" and e1["kind"] == "variable" and is_rest_capture(e1["tk"])
    and #arr(node["e2"] as M) == 0 then
      return e1["tk"] as string
    end
  end
  return nil
end

local match_value: function(pv: any, nv: any, caps: {string: M}, seen: {any: boolean}): boolean

--- Match two arrays positionally. If the pattern's LAST element is a
--- rest-capture marker (see `rest_capture_name`), it swallows every
--- remaining candidate element (zero or more) instead of requiring equal
--- length -- this is reused both for a node's own array part (call args,
--- table items) and for any named array-shaped field (`if_blocks`, a
--- block's statement list), since both are just Lua arrays once extracted.
local function match_list(pa: {any}, na: {any}, caps: {string: M},
    seen: {any: boolean}): boolean
  if #pa > 0 then
    local last_raw = pa[#pa]
    if last_raw is M then
      local rest_name = rest_capture_name(last_raw as M)
      if rest_name then
        local prefix_n = #pa - 1
        if #na < prefix_n then
          return false
        end
        for i = 1, prefix_n do
          if not match_value(pa[i], na[i], caps, seen) then
            return false
          end
        end
        if #na > prefix_n then
          caps[rest_name] = span_node(na[prefix_n + 1] as M, na[#na] as M)
        elseif prefix_n > 0 then
          -- zero elements matched: an empty, zero-width span right after
          -- the last fixed element, so the template can still substitute
          -- an empty string instead of leaving the marker text behind
          local py, px = node_end(na[prefix_n] as M, {})
          caps[rest_name] = {y = py, x = px + 1, yend = py, xend = px}
        end
        return true
      end
    end
  end
  if #pa ~= #na then
    return false
  end
  for i = 1, #pa do
    if not match_value(pa[i], na[i], caps, seen) then
      return false
    end
  end
  return true
end

--- Match one pattern VALUE against one candidate value -- a node, a
--- named field's value (which might itself be a node, a list of nodes,
--- or a scalar like `op.op`), or an array element. This one function
--- replaces per-kind special-casing: a node is "kind + array part +
--- every other named field the pattern sets", recursively, so a new tl
--- node kind needs no new code here, and a statement/block pattern
--- (`if $C then ... end`, matching against `if_blocks`) falls out of the
--- same recursion that handles a call's arguments.
match_value = function(pv: any, nv: any, caps: {string: M}, seen: {any: boolean}): boolean
  if pv == nil then
    return nv == nil
  end
  if not (pv is M) then
    return pv == nv -- scalar: string/number/boolean
  end
  local pt = pv as M
  if pt["kind"] == "variable" and is_capture(pt["tk"]) then
    if not (nv is M) then
      return false
    end
    local nt = nv as M
    local name = pt["tk"] as string
    local prev = caps[name]
    if prev then
      -- linear pattern: a repeated $X must bind the same subtree twice
      return prev["kind"] == nt["kind"] and prev["tk"] == nt["tk"]
    end
    caps[name] = nt
    return true
  end
  if not (nv is M) then
    return false
  end
  local nt = nv as M
  -- cycle guard: an if_block's `if_parent` points back at its own "if"
  -- statement (confirmed by inspection, not just theoretical -- tl's
  -- AST really does this), so unguarded field recursion loops forever.
  -- Treat a revisit as trivially matching, the same tradeoff
  -- node_start/node_end/collect already make for shared/cyclic nodes.
  if seen[nt] then
    return true
  end
  seen[nt] = true
  local pkind = pt["kind"]
  if pkind and pkind ~= nt["kind"] then
    return false
  end
  if pkind == "variable" or pkind == "identifier" or pkind == "string" then
    return pt["tk"] == nt["tk"]
  end
  if not match_list(arr(pt), arr(nt), caps, seen) then
    return false
  end
  for k, sub_pv in pairs(pt) do
    if not (k is integer) and not IGNORE_KEYS[k as string] then
      if not match_value(sub_pv, nt[k], caps, seen) then
        return false
      end
    end
  end
  return true
end

--- One search hit: the matched node plus its capture bindings.
local record Hit
  node: M
  caps: {string: M}
end

--- Recursively collect every node matching `pattern`. Cycle guard: tl
--- ASTs share/repeat tables by identity (`_types/tlast_gen.tl`'s
--- serializer exists because of exactly this).
local function collect(node: M, pattern: M, seen: {any: boolean}, out: {Hit})
  if seen[node] then
    return
  end
  seen[node] = true
  local caps: {string: M} = {}
  if match_value(pattern, node, caps, {}) then
    out[#out + 1] = {node = node, caps = caps}
  end
  for _, v in pairs(node) do
    if v is M then
      if v["kind"] then
        collect(v, pattern, seen, out)
      else
        for _, e in ipairs(arr(v)) do
          if e is M and e["kind"] then
            collect(e, pattern, seen, out)
          end
        end
      end
    end
  end
end

--- Parse Teal/Lua source. Returns the raw AST as a generic map plus the
--- token stream (comment-loss checking needs the tokens, not the AST --
--- comments live on the token that follows them, not in the tree).
local function parse(source: string, name: string): M | nil, {tl.Token}, string
  local tokens, lex_errs = tl.lex(source, name)
  if not tokens then
    return nil, nil, name .. ": lexer failed"
  end
  if lex_errs and #lex_errs > 0 then
    local e = lex_errs[1]
    return nil, nil, string.format("%s:%d:%d: %s", name, e.y or 0, e.x or 0, e.msg or "lex error")
  end
  local parse_errs: {tl.Error} = {}
  local ast = tl.parse_program(tokens, parse_errs, name)
  if #parse_errs > 0 then
    local e = parse_errs[1]
    return nil, nil, string.format("%s:%d:%d: %s", name, e.y or 0, e.x or 0, e.msg or "parse error")
  end
  return ast as M, tokens, nil
end

--- Byte offset (1-based) of line `y`, column `x` (tl's columns are
--- 1-based, confirmed empirically: the first character of a line is x=1)
--- in `source`, via a precomputed table of each line's starting offset.
local function line_starts(source: string): {integer}
  local starts: {integer} = {1}
  local pos = 1
  while true do
    local nl = source:find("\n", pos, true)
    if not nl then
      break
    end
    starts[#starts + 1] = nl + 1
    pos = nl + 1
  end
  return starts
end

local function offset_of(starts: {integer}, y: integer, x: integer): integer
  return starts[y] + x - 1
end

--- A bare expression parses as a one-statement block whose statement IS
--- the expression node (an expression-statement) -- unwrap so the
--- pattern's top kind is the expression's own ("op", "variable", ...).
--- A statement pattern (`if ... end`) needs no unwrap: `program[1]` is
--- already the statement itself either way.
local function unwrap_pattern(program: M): M
  return arr(program)[1] as M
end

--- Byte ranges [a, b] (inclusive) whose capture NAME appears literally in
--- the replacement template -- i.e. the source text a rewrite actually
--- carries forward, as opposed to a captured span the template discards.
local function kept_ranges(caps: {string: M}, replacement: string,
    starts: {integer}): {{integer, integer}}
  local kept: {{integer, integer}} = {}
  for name, cap in pairs(caps) do
    if replacement:find(name, 1, true) then
      local cy, cx = node_start(cap, {})
      local cyend, cxend = node_end(cap, {})
      kept[#kept + 1] = {offset_of(starts, cy, cx), offset_of(starts, cyend, cxend)}
    end
  end
  return kept
end

--- Comment texts inside byte range [a, b] that no `kept` range covers --
--- exactly the comments a rewrite would silently delete: one attached to
--- a token in the "connective tissue" of the match (the pattern's own
--- literal text, or the gaps between captures) rather than inside a
--- capture the replacement actually reuses.
local function dropped_comments(tokens: {tl.Token}, starts: {integer},
    a: integer, b: integer, kept: {{integer, integer}}): {string}
  local dropped: {string} = {}
  for _, t in ipairs(tokens) do
    if t.comments then
      for _, c in ipairs(t.comments) do
        local coff = offset_of(starts, c.y, c.x)
        if coff >= a and coff <= b then
          local covered = false
          for _, r in ipairs(kept) do
            if coff >= r[1] and coff <= r[2] then
              covered = true
              break
            end
          end
          if not covered then
            dropped[#dropped + 1] = c.text
          end
        end
      end
    end
  end
  return dropped
end

local function main(argv: {string})
  local pattern_src = argv[1]
  local target_path = argv[2]
  if not pattern_src or not target_path then
    io.stderr:write("usage: tlgrep.tl '<pattern>' <file> ['<replacement>']\n")
    os.exit(1)
  end
  -- the replacement template uses the same $NAME/$$$NAME surface syntax
  -- as the pattern, and must be desugared the same way so its literal
  -- text lines up with the capture names collected during matching
  local replacement = argv[3] and desugar(argv[3])

  local pattern_ast, _ptoks, perr = parse(desugar(pattern_src), "<pattern>")
  if not pattern_ast then
    io.stderr:write("pattern: " .. (perr or "?") .. "\n")
    os.exit(1)
  end
  local pattern = unwrap_pattern(pattern_ast)

  local source, rerr = fs.read(target_path)
  if not source then
    io.stderr:write(target_path .. ": " .. (rerr or "cannot read") .. "\n")
    os.exit(1)
  end
  g_source = source
  g_line_starts = line_starts(source)
  local ast, tokens, aerr = parse(source, target_path)
  if not ast then
    io.stderr:write(aerr or "?")
    os.exit(1)
  end

  local hits: {Hit} = {}
  collect(ast, pattern, {}, hits)

  -- Deterministic order: `collect`'s own traversal falls back to `pairs`
  -- over a node's non-array fields (if_blocks, body, ...) once the array
  -- part is exhausted, and Lua's hash-part iteration order is NOT
  -- guaranteed stable across runs -- sort by source position so search
  -- output (and rewrite application order) doesn't depend on it.
  table.sort(hits, function(p: Hit, q: Hit): boolean
    local py, px = node_start(p.node, {})
    local qy, qx = node_start(q.node, {})
    return py < qy or (py == qy and px < qx)
  end)

  io.stderr:write(string.format("%s: %d match(es) for `%s`\n",
    target_path, #hits, pattern_src))
  local starts = g_line_starts
  for _, h in ipairs(hits) do
    local y, x = node_start(h.node, {})
    local yend, xend = node_end(h.node, {})
    local a, b = offset_of(starts, y, x), offset_of(starts, yend, xend)
    io.stderr:write(string.format("  %d:%d-%d:%d  %s\n", y, x, yend, xend, source:sub(a, b)))
  end

  if not replacement then
    return
  end

  -- Splice back-to-front so earlier offsets stay valid; refuse (skip,
  -- don't silently drop) any hit whose match would delete a comment the
  -- replacement template doesn't carry forward.
  local descending: {Hit} = {}
  for i = #hits, 1, -1 do
    descending[#descending + 1] = hits[i]
  end
  local out = source
  local refused = 0
  for _, h in ipairs(descending) do
    local ny, nx = node_start(h.node, {})
    local nyend, nxend = node_end(h.node, {})
    local a, b = offset_of(starts, ny, nx), offset_of(starts, nyend, nxend)
    local kept = kept_ranges(h.caps, replacement, starts)
    local dropped = dropped_comments(tokens, starts, a, b, kept)
    if #dropped > 0 then
      refused = refused + 1
      io.stderr:write(string.format(
        "  refusing %d:%d-%d:%d: would drop comment(s): %s\n",
        ny, nx, nyend, nxend, table.concat(dropped, " | ")))
    else
      local text = replacement
      for name, cap in pairs(h.caps) do
        local cy, cx = node_start(cap, {})
        local cyend, cxend = node_end(cap, {})
        local ca, cb = offset_of(starts, cy, cx), offset_of(starts, cyend, cxend)
        text = text:gsub(name, (source:sub(ca, cb):gsub("%%", "%%%%")))
      end
      out = out:sub(1, a - 1) .. text .. out:sub(b + 1)
    end
  end
  if refused > 0 then
    io.stderr:write(string.format("%d hit(s) refused; re-run after resolving\n", refused))
  end

  -- Lean on the existing formatter instead of hand-preserving whitespace
  -- between captures: it also doubles as a validity check on the splice
  -- (it reparses; a syntax error here means the rewrite produced garbage).
  local result = format.format(out, target_path)
  if not result.ok then
    io.stderr:write("warning: spliced output does not parse -- writing unformatted\n")
    io.stderr:write(format.format_issues(result.errors))
    io.write(out)
    return
  end
  io.write(result.code)
end

main(arg)
