## Change

`_cli/nilreturn.tl:318-325` treats EVERY identifier spelled `type` as a
possible alias and hands it to `skip_type_alias` (118-134), which decides by
what FOLLOWS: `NAME =` then a type. A field access `t.type` at the end of a
line, followed by a statement `name = ...`, has the same three tokens, so the
alias path consumes the right-hand side as a TYPE: `name = function(): string
... end` is eaten by `parse_type` (no `fn` frame opens, the body's `end` pops
the frame beneath it, and the lie inside is charged to nobody), and `name =
record ...` opens a `fields` frame no `end` ever pops. Both unbalance the walk
(Evidence), which `_build/nil_returns_test.tl`'s tree-wide balance gate turns
into a failing `--make ci` for whoever writes that shape. The same class
`d639b092` closed for `record`/`interface`/`enum`/`macroexp` with a
previous-token tell (`opens_body`, 175-200).

`_cli/nilreturn.tl` (371 lines): in `walk`, gate the `type` branch on the
previous token exactly as `opens_body` does — take a new
`opens_alias(tokens, i, stack): boolean` beside `opens_body`: `tokens[i]` is
the identifier `type`, `tokens[i+1]` is an identifier, and either `tokens[i-1].tk`
is `local`/`global`, or the top frame is `fields` and `ends_item(tokens[i-1])`
(a record body's `type Foo = ...` item). Call it from the `elseif` at 318;
when it is false fall through to the `i = i + 1` default. `skip_type_alias`
keeps its body but drops the now-redundant `name.kind ~= "identifier"` guard
(keep the `eq` guard). Update the doc at 101-117 and the `skip_declaration_head`
note at 59-66 (which already names `type` as a stop word) to say the walk
reaches `type` only after `local`/`global` or at item start.

One-line alignment in `_cli/returns.tl:286-301`: `opens_macroexp` there
accepts `macroexp NAME` with no previous-token check, while
`_cli/nilreturn.tl:231-232` requires `local`/`global` before it; give
`returns.tl`'s the same `prev.tk == "local" or prev.tk == "global"` condition
so the two readers of one grammar agree (harmless today only because
`params_open` is same-line, 251-270).

Tests the diff carries, in `_build/nil_returns_test.tl` (428 lines; add to
the existing fixture root rather than a new test if the file nears the cap):
- fixture `type_access.tl` = the first snippet below; expect
  `got["cosmic/type_access.tl"] == 1` (handler's lie counted) and the file
  absent from `nilret.unbalanced(root)`.
- fixture `type_record_assign.tl` = the second snippet; expect no count and
  balanced.
- control: `local type Alias = integer` at module scope and `type Inner =
  record ... end` inside a record body still open/consume as today
  (the `field_access` fixture from `d639b092` already covers the record half;
  add the module-scope alias line to it).
- `_cli/returns_test.tl` (221 lines): `local x = t.macroexp` followed by a
  line `foo(1)` yields no diagnostic before and after — pins the alignment
  is behaviour-preserving.

## Evidence

Tree `_cli/nilreturn.tl` and `_cli/returns.tl` compiled from `origin/main`
and run under `o/bootstrap/cosmic probe2.lua` (`teal.compile_cached` on both
files, then `walk` on each fixture):
```
type_then_assign: lines= residual=0 underflow=1
type_then_record_assign: lines= residual=1 underflow=0
```
where `type_then_assign` is
```
local function outer(): string | nil
  local t = {type = 1}
  local k = t.type
  handler = function(): string
    return nil
  end
  return k and "x" or nil
end
print(outer())
```
(expected: `lines=5`, balanced — `handler` lies) and `type_then_record_assign` is
```
local t = {type = 1}
local k = t.type
record = record or {}
print(k)
```
(expected: no lines, balanced). The gate that turns this into a CI failure:
`git show origin/main:_build/nil_returns_test.tl | grep -n "unbalanced"` —
`test_the_walk_balances_over_every_committed_file` asserts `#bad == 0`.
Branch under change: `git show origin/main:_cli/nilreturn.tl | sed -n 318,325p`
```
    elseif t.kind == "identifier" and tk == "type" then
      local after, body = skip_type_alias(tokens, i)
```
Divergence: `sed -n 286,301p` of `_cli/returns.tl` vs `sed -n 217,236p` of `_cli/nilreturn.tl` on `origin/main`.

## Non-goals

`parse_atom` (`_cli/returns.tl:150-165`) still reads a named alias as never
admitting nil, so `local type Maybe = string | nil` + `return nil` counts as a
lie (measured in the same probe: `control_local_type: lines=3`). Different
rule, different item.
