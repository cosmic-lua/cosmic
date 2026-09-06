--- Function signatures read from a module's own AST, not from its
--- source text.
---
--- `cosmic.ast.parse`'s `local_function`/`global_function`/
--- `record_function` nodes name a function, its declared parameter
--- list (`args`), and its declared return types (`rets`) directly —
--- so a signature split across several lines is exactly as easy to
--- read as a one-liner, where a text scan of the SIGNATURE STRING
--- (counting commas outside parens) has to find the boundary between
--- params and returns for itself and can lose a return type that
--- spilled onto its own line. `init.tl`'s `parse` calls
--- `function_signatures` to find every function definition in a
--- module; `_build/doc_returns_test.tl` calls it again, one real
--- source file at a time, to check a function's `@return` tag count
--- against its ACTUAL declared return slot count — the one fact this
--- module reads that the published index does not carry, since the
--- index only ever stored the signature TEXT, never a parsed count.
local ast = require("cosmic.ast")

local type Node = ast.Node

local BYTE_NEWLINE = string.byte("\n")
local BYTE_LPAREN = string.byte("(")
local BYTE_RPAREN = string.byte(")")

--- A declared return-type list: always kind `"tuple"` in practice
--- (verified against every function in `cosmic/**` — none carry a
--- bare vararg return type, tl's one other shape here), `#tuple` the
--- declared return slot count.
local record TypeList
  tuple: {Node}
end

--- The tl AST fields a function-defining node carries that
--- `cosmic.ast.Node` does not model — `local_function`,
--- `global_function`, and `record_function` all share this shape.
--- One narrow view, cast once here, the same discipline
--- `cosmic/ast/node.tl`'s own doc comment names for every consumer
--- that needs fields beyond the nine kinds it covers.
local record FnNode
  --- The function's own bare name, as an "identifier" leaf node.
  name: Node
  --- "record_function" only: the record (or nested field chain) the
  --- function is defined on, e.g. `M` in `function M.bar(...)` or
  --- `M.Sub` in `function M.Sub.bar(...)`.
  fn_owner: Node
  --- "record_function" only: true for `function M:baz(...)` colon
  --- (method) sugar, nil for the plain dot form.
  is_method: boolean
  --- The declared return types, always a "tuple" — `#rets.tuple` is
  --- the number of declared return slots, 0 when the function
  --- declares none at all.
  rets: TypeList
end

--- One function declaration read from a module's AST.
local record Signature
  --- The name as `init.tl`'s FunctionDoc has always recorded it: bare
  --- for a local or a dot-defined record function, `Owner:name` for a
  --- colon-defined method.
  name: string
  --- True for a `local_function` node, false for `global_function` or
  --- `record_function`.
  is_local: boolean
  --- The node's 1-based source line — the same line
  --- `extract_doc_comment` and `extract_signature` start from.
  line: integer
  --- Byte offset of the function's own first token, for
  --- `extract_doc_comment` to search backward from.
  doc_pos: integer
  --- The signature text, extracted exactly as `init.tl` always
  --- extracted it: from the first `(` after `doc_pos` through the end
  --- of the line the parameter list's closing `)` is on.
  signature: string
  --- `#rets.tuple` — the number of return slots this function's OWN
  --- declaration carries, read from the AST rather than counted out
  --- of the signature text.
  return_slots: integer
end

--- Extract a function's signature text starting from its own first
--- token. Unchanged from the byte-scanning `init.tl` always used —
--- only where `start_pos` comes from changes: an AST node's own
--- location instead of a regex match's captured position.
--- @param source string The source code
--- @param start_pos integer Position to start searching from
--- @return string The extracted signature
local function extract_signature(source: string, start_pos: integer): string
  local sig_start = source:find("%(", start_pos)
  if not sig_start then return "()" end
  local sig_end = sig_start
  local depth = 0
  for i = sig_start, #source do
    local b = source:byte(i)
    if b == BYTE_LPAREN then depth = depth + 1
    elseif b == BYTE_RPAREN then
      depth = depth - 1
      if depth == 0 then
        sig_end = i
        local j = i + 1
        while j <= #source do
          if source:byte(j) == BYTE_NEWLINE then break end
          sig_end = j
          j = j + 1
        end
        break
      end
    end
  end
  return source:sub(sig_start, sig_end)
end

--- The full dotted text of a record-function's owner chain: `M` for a
--- plain identifier, `M.Sub` for a nested field reached through a `.`
--- op node. Recurses on `e1`/`e2` — fields `cosmic.ast.Node` already
--- models for every "op" node, so no extra cast is needed here.
--- @param owner Node The `fn_owner` node
--- @return string The owner chain, dot-joined
local function owner_text(owner: Node): string
  if owner.op and owner.op.op == "." and owner.e1 and owner.e2 then
    return owner_text(owner.e1) .. "." .. owner_text(owner.e2)
  end
  return owner.tk or ""
end

--- The name `init.tl` has always recorded for a `record_function`:
--- bare for the dot form (owner dropped, whatever its own depth), the
--- full `Owner:name` for the colon (method) form. Mirrors the old
--- text extractor's own rule exactly — strip one leading identifier
--- segment from the dotted owner chain, keep any remainder — since a
--- deeper rewrite is not this item's Change.
--- @param node FnNode A "record_function" node
--- @return string The function's recorded name
local function record_function_name(node: FnNode): string
  local bare = node.name.tk
  if node.is_method then
    return owner_text(node.fn_owner) .. ":" .. bare
  end
  local owner = owner_text(node.fn_owner)
  local rest = owner:match("^[%w_]+%.(.+)$")
  if rest then
    return rest .. "." .. bare
  end
  return bare
end

--- Every local/global/record function definition in `source`'s AST,
--- in source order — `Example*` functions excluded, exactly as
--- `init.tl`'s own two text-scanning loops always excluded them (they
--- get their own separate treatment there).
--- @param source string The source code to parse
--- @param file_path string Path to the file being parsed, for diagnostics
--- @return {Signature}|nil Every function definition found
--- @return string Error message on failure
local function function_signatures(source: string, file_path: string): {Signature} | nil, string
  local parsed, err = ast.parse(source, file_path)
  if not parsed then return nil, err end
  local starts = ast.line_starts(source)
  local sigs: {Signature} = {}
  ast.walk(parsed.node, function(n: Node)
      if n.kind == "local_function" or n.kind == "global_function"
      or n.kind == "record_function" then
        local fn = n as FnNode -- cast: local_function/global_function/record_function fields cosmic.ast.Node doesn't model
        local name: string
        local is_local = n.kind == "local_function"
        if n.kind == "record_function" then
          name = record_function_name(fn)
        else
          name = fn.name.tk
        end
        if not name:match("^Example") then
          local doc_pos = ast.offset_of(starts, n.y, n.x)
          sigs[#sigs + 1] = {
            name = name, is_local = is_local, line = n.y, doc_pos = doc_pos,
            signature = extract_signature(source, doc_pos),
            return_slots = #fn.rets.tuple,
          }
        end
      end
    end)
  return sigs, nil
end

local record SignatureModule
  type Signature = Signature
  function_signatures: function(source: string, file_path: string): {Signature} | nil, string
end

local M: SignatureModule = {
  function_signatures = function_signatures,
}

return M
