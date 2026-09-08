# Cosmic checks, fixes, and formatting: review and design

Review date: 2026-09-08. Proposal; no implementation or board changes made.

**Recommendation:** make one source snapshot the shared input to `cosmic.ast`, `cosmic.teal`, and `cosmic.format`. Add a small rule runner and a transactional edit layer above them. Keep Teal responsible for parsing and inference. Give checks typed access to syntax, bindings, and inferred types; make formatting consume the same syntax and edit machinery. Pay for semantic analysis only when a rule needs it.

The immediate prerequisite is correctness. The existing matcher and rewriter are useful foundations, but their current contracts are too weak for unattended fixes.

## 1. What I reviewed

Source: [cosmic at 772508c](https://github.com/cosmic-lua/cosmic/tree/772508c4ed924ce0bf51185e9a55c1625ca05996), especially `cosmic/ast/*`, `cosmic/format/*`, `cosmic/teal.tl`, `_teal_engine`, `_teal_discard`, `_types/gentl`, `_cli/lint`, `_cli/rewrite`, `_make/check`, `_tool/seam`, and the formatter/checker performance scenarios. I also read the goals and relevant decisions, including D5, D19, D21, and D29.

I read the current `items/*` and `ended/*` refs in cosmic-lua/work: 1,243 items at retrieval. The board's ordinary `main` was `810ad912639000eae52cf50752f56f9d272d88dd`; that SHA alone does **not** identify its independently versioned item refs. Links below pin individual item snapshots.

The recent gitboard friction log supplies practical requirements: affected-module checking, complete diagnostics, useful shadowing explanations, and static import boundaries. Its observation that aggregate validation stopped early should not be generalized to every checker entry point: today's `_cli/check.run` and `_make/check.check_files` both continue across selected files. Build convergence can still fail before that aggregation runs.

For the executable probes, I used the verified repository pin, `2026-09-07-2b2002d` (SHA-256 `b4bb8bde84fc54c4298e4d63d949a1af071d2ff5a2e1ba095fa70d9e342ee434`), explicitly compiling and loading the reviewed HEAD's AST and formatter modules. This avoids accidentally testing the binary's embedded module copies. These were focused probes, not a full build or CI run. The upstream API inspection used Teal v0.24.8, the version in `3p/tl/tl_pin.tl`; Cosmic's carried patches remain part of the actual checker.

## 2. Existing pieces and missing contracts

| Piece | Useful today | Missing for the proposed foundation |
| --- | --- | --- |
| `cosmic.ast.parse` | Real Teal parse; AST and comment-bearing tokens returned together | Source/revision ownership, reliable byte ranges, full structured syntax diagnostics, syntax for type annotations, explicit dialect consistency |
| `walk` and spans | Cycle termination; coverage of unfamiliar table shapes | Grammar-defined child edges, parent/role context, deterministic traversal, precomputed ranges; reflection follows parent backlinks |
| `match` | Parsed patterns, captures, trailing list captures, name predicates, cast-target matching | Structural equality, compiler-metadata exclusion, typed captures for expressions/types/lists, owned compiled patterns, explicit unsupported cases |
| `rewrite` | Original-source capture splicing; comment-loss refusal; final formatting | Edit plans, conflict handling, expression context, scope hygiene, atomic fix groups, revision checks, semantic validation |
| `cosmic.format` | Comment-aware token emission; house-style behavior; parser validation | It discards the AST, then reconstructs type/block context heuristically; needs shared syntax roles and token-boundary correctness |
| `cosmic.teal` | Strict checks; warnings as errors; cached environments; pre-parsed stdlib; compile from checked AST | Public analysis session, structured type queries, dependency revisions, complete scoped results, checked-AST entry point |
| `_teal_discard` | A working type-aware policy check | It walks untyped maps, classifies rendered function-type strings, and recognizes error consumers by spelling |
| Existing lint | Many real policies worth keeping | Repeated lexing/parsing, different diagnostic records, custom type grammar, no common rule/fix protocol |

These findings are visible in the [AST facade](https://github.com/cosmic-lua/cosmic/blob/772508c4ed924ce0bf51185e9a55c1625ca05996/cosmic/ast/init.tl), [formatter](https://github.com/cosmic-lua/cosmic/blob/772508c4ed924ce0bf51185e9a55c1625ca05996/cosmic/format/init.tl), [engine](https://github.com/cosmic-lua/cosmic/blob/772508c4ed924ce0bf51185e9a55c1625ca05996/cosmic/_teal_engine.tl), and [discard rule](https://github.com/cosmic-lua/cosmic/blob/772508c4ed924ce0bf51185e9a55c1625ca05996/cosmic/_teal_discard.tl).

### Reproduced correctness problems

| Probe | Observed result | Required correction |
| --- | --- | --- |
| Match `f($X, $X)` against `f(a+b, c*d)` | One hit | Repeated captures must compare the complete syntax subtree. Current comparison checks only `kind` and `tk`; compound operators have no `tk`. |
| Match `local x: integer = 1` against a separately parsed identical declaration | Zero hits | Ignore per-parse `typeid` and other compiler bookkeeping when comparing source structure. |
| Walk only the first branch of `if x then f() else g() end` | Visits both `f` and `g`; branch span reaches the enclosing `end` | Follow child edges, never `if_parent`; compute a branch's own range. |
| Replace `f($X)` with empty text in `local answer = f(1)` followed by `return answer` | Deletes the entire declaration; leaves `return answer` | Statement removal must require statement-list membership. A call kind alone does not establish that context. |
| Replace `f($X)` with `$X * 2` in `return f(a + b)` | Produces `return a + b * 2` | Instantiate an expression template and preserve grouping; reparsing alone does not preserve meaning. |
| Replace `f($X)` with `g("$X", $X)` in `f(hello)` | Produces `g("hello", hello)` | Recognize placeholders as template syntax; do not substitute within literal strings/comments. |
| Format `local x = - -1` followed by `return x` | Returns `ok=true` with `local x = --1`; formatting that result fails | Enforce lexical separation and validate emitted output. Input parse success is insufficient. |

The declaration and unary-minus defects already have board items. The other probes expose requirements not supplied by the existing rewrite contract. Relevant implementations: [matcher](https://github.com/cosmic-lua/cosmic/blob/772508c4ed924ce0bf51185e9a55c1625ca05996/cosmic/ast/match.tl), [walk](https://github.com/cosmic-lua/cosmic/blob/772508c4ed924ce0bf51185e9a55c1625ca05996/cosmic/ast/walk.tl), [rewrite](https://github.com/cosmic-lua/cosmic/blob/772508c4ed924ce0bf51185e9a55c1625ca05996/cosmic/ast/rewrite.tl), [format rules](https://github.com/cosmic-lua/cosmic/blob/772508c4ed924ce0bf51185e9a55c1625ca05996/cosmic/format/rules.tl).

Other inspected gaps: overlapping matches have no explicit conflict policy; each replacement copies the whole source prefix/suffix; capture spans can be synthetic; and cast type captures currently carry a whole cast node rather than a distinct type-syntax range. The CLI also reports some read/parse/write failures as zero applied and zero refused, allowing another successful file to determine the overall status. These need explicit outcomes.

## 3. Compose around a source snapshot

Use these responsibilities; new API names here are proposed, not available today.

| Layer | Owns | Must not own |
| --- | --- | --- |
| `cosmic.ast` | Source snapshots, token/trivia tape, syntax/type-syntax nodes, child roles, traversal, structural patterns | Type inference or project policy |
| `cosmic.teal` | Analysis session, resolver, checking, type facts and semantic diagnostics | Formatting or source mutation |
| `cosmic.edit` (new) | Expression/type templates, edit plans, conflict/refusal rules, application and diffs | Implicit checking or formatting after each edit |
| `cosmic.format` | Syntax-directed layout; formatting edits over a snapshot | Inferring types, applying semantic refactors, regenerating source with `tl.generate` |
| `cosmic.analysis` (new) | Rule registration, required capabilities, shared traversal, diagnostic aggregation, fix pipeline | A second parser or type checker |
| `_cli` / `_make` | Project discovery, generated test seam, command behavior, file writes and reporting | Independent implementations of the analysis |

Keep compiler-only implementation shards internal. Public rule authors use public facades; no dependency from `cosmic/**` into `_cli` or `_make`. In particular, formatting must import the low syntax layer, not the present `cosmic.ast` facade while that facade eagerly imports rewrite, which imports formatting. Move orchestration upward and remove that dependency cycle before migration.

### Snapshot contract

A `Snapshot` owns the exact source bytes, logical and resolved filename, dialect, source digest, line starts, tokens, comments/trivia, syntax root, and syntax diagnostics. Every node, capture, diagnostic range, and edit is associated with its snapshot. Byte ranges are **1-based, half-open** `[start_byte, end_byte)`, matching Lua string indexing while making insertion an empty range. Convert to display columns or editor UTF-16 positions only at the adapter boundary.

Retain raw source slices for whitespace, comments, literals, line endings, and shebangs. A no-edit emission is byte-identical. Formatting may deliberately normalize house-style whitespace, but edit planning does not normalize incidental bytes. Test CRLF, UTF-8, multiline strings/comments, and EOF explicitly.

Represent syntax as a thin, typed view over Teal's parser, with explicit child fields and source roles: callee, argument, return value, declared type, cast target, generic parameter, block body, and declaration name. A type annotation is syntax even when its name cannot resolve. Inferred `TypeRef` and source `TypeSyntax` are different things.

Avoid inventing a second full concrete-syntax parser. Teal's type payloads are not ordinary `Node` children and its present endpoints are insufficient for this contract. First audit the pinned grammar and record token boundaries at its parse sites where exact spans cannot be recovered. Use small, canary-tested D21 patches for missing parser ranges/roles if required. Do not derive ownership by taking the minimum and maximum over every reachable table.

The syntax schema defines deterministic children, excludes backlinks and compiler fields, and preserves meaningful distinctions such as parentheses and declaration attributes. Unknown unsupported shapes may be inspected as opaque source regions; they must not be silently classified or rewritten. Traversal supports enter/leave, pruning, and parent/role context. Pattern compilation returns an owned `Pattern` including its metadata, rather than storing predicate state globally.

### Parse once, check optionally

The needed Teal entry point already exists: `tl.check(ast, filename, options, env)`. A direct probe on the bundled checker returned zero type errors and performed **zero additional lexes and parses** on an already parsed file. It returned the same AST object. The curated declaration generator exposes `process_string` but currently omits `check`; extend the adapter and its verified API declaration accordingly. See the [pinned Teal API](https://github.com/teal-language/tl/blob/v0.24.8/tl.tl).

Teal mutates its AST while checking, so “share” cannot mean letting the checker mutate the syntax objects under pattern matching and formatting. Start with one checker-owned graph copy per checked snapshot, preserving sharing, metatables, and an origin map to syntax nodes. Syntax-only work pays no copy. Measure that cost; reduce copying only after a mutation audit and equivalence tests. Code generation consumes the checked graph; formatting consumes the source snapshot.

Imports must use the same session resolver and parsed-file cache. Calling `tl.check` on the root alone does not stop Teal from independently reading/parsing dependencies. Route its dependency loader through the session, retain actual dependency results, and make generated declarations and compiler options explicit inputs. This is necessary for the project-level parse-once claim.

Runner-mode tests need the D29 generated tail. Keep `_tool/seam` as an internal producer of a derived checker input; map original nodes/ranges to it and mark synthetic nodes. Diagnostics on the tail are attributed to generated input, and no user fix can edit it. Formatting continues to see the original source only. Count this derived input separately in instrumentation.

## 4. Types and bindings as optional capabilities

### Start with the existing type report

Complete the existing `_teal_types` extraction, then expose a narrow, typed public result through `cosmic.teal.analyze`. The report already provides union members, function arguments/returns, record fields, and container element types; don't parse display strings to recover those structures. A report lookup itself is cheap; the expensive work is checking.

Proposed operations: `type_of(expression)`, `declared_type(declaration)`, `members(type)`, `returns(function_type)`, `contains_nil(type)`, and `describe(type)` for display. Use opaque `TypeRef`s scoped to a checked revision. Distinguish expression tuples, adjusted single values, and declared function return lists; Lua's multi-return rules matter to checks and fixes.

The existing position report is a useful first adapter, not a guarantee that every arbitrary node has a unique type at `node.y/node.x`. Its map has one slot per source position and can overwrite a prior store. Use only verified node-role-to-position mappings initially, expose missing/ambiguous results, and add origin-keyed inference events if needed. Never use nearest-position lookup as semantic evidence.

Queries need an explicit unavailable/unknown result. In particular, do not generalize the pending helper's `is_nilable_at = false` on a missing report into a public proof that a value cannot be nil. `any`, absent inference, compiler errors, and ambiguous position mappings do not establish safety. A mandatory rule whose required analysis is unavailable makes the run **incomplete**, with a reason; it does not quietly pass.

Do not initially promise a general assignability or effect solver from `TypeInfo`: report records are not a public subtype engine. When a rule needs actual assignability, instantiated expected argument types, or flow facts beyond the report, expose a narrow checker query/event under the adapter, with tested semantics and explicit unsupported cases.

### Bindings are a separate service

Implement lexical scope and reference resolution over the syntax tree. The completed rename investigation established that `symbols_in_scope` identifies types, not declarations; equal type IDs cannot distinguish shadowed variables. A `BindingId` must identify a declaration in this snapshot.

Cover local initializer visibility, recursive local functions, parameters, loop variables and iterator/control expressions, nested closures, repeat-body scope in the `until` condition, implicit `self`, and `_ENV`. Keep labels/gotos and Teal's type-name namespace distinct from ordinary value references. Test shadowing with identical types.

Resolve direct import origins through bindings. The current `ast.requires` helper intentionally knows only top-level alias spelling; it does not track reassignment or shadowing. A fix must either prove the import binding still applies at the use or refuse. Follow straight-line immutable aliases first; branch-dependent assignments and dynamic module/table mutation return unknown until supported.

A safe local rename collects the declaration and its resolved references, then proves the new name causes no capture or collision at any affected use, including closures. It does not rename every matching token or every member key. Exported record fields, dynamic access, and cross-module API renames need separately defined support.

### What this means for nil-flow

The board correctly rejected replacing the nil-flow census with syntax patterns alone. Even a nilability query is insufficient: a rule must know whether a sink forbids nil, how multi-return adjustment works, and what the checker knows after guards. The checker currently has permissive nil behavior; reusing its ordinary assignability answer would reproduce that permissiveness.

Build the census as syntax-selected sink sites plus actual and expected types and relevant flow facts. Where the report has erased information (including the documented operand-union behavior), instrument the appropriate existing inference/check boundary. Keep the sink taxonomy explicit. Validate against the prior strict-checker method, including return-versus-break and `and`/`or` cases; explain every census difference. Do not relabel a smaller syntactic approximation as the old census.

## 5. Make rules small and ordinary

Use typed Teal records and functions, with a small `define` helper. No string-based type-expression language or general query DSL is needed. Support patterns for convenient syntax selection and visitors for rules whose context is clearer in code.

Illustrative proposed API, not executable on current Cosmic:

```teal
local analysis = require("cosmic.analysis")

return analysis.define({
  id = "fallible-statement",
  needs = {"syntax", "types"},
  pattern = "$CALL($$$ARGS)",
  visit = function(ctx: analysis.Context, hit: analysis.Hit)
    if not ctx.syntax:is_statement(hit.node) then return end
    local signature = ctx.types:callee_signature(hit.node)
    if signature == nil then
      ctx:incomplete(hit.node, "callee signature unavailable")
      return
    end
    if ctx.policy:is_fallible(signature) == "yes" then
      ctx:report({
        node = hit.node,
        message = "capture and handle the error return",
      })
    end
  end,
})
```

The proposed policy helper centralizes Cosmic's fallible-return convention, including structured failures, and reports uncertainty for unsupported types. This rule intentionally has no automatic fix: introducing a guard, throwing, or ignoring the error is a behavior decision. The tool can offer explicit suggestions without silently choosing one.

A simpler policy can be data: a forbidden import edge with a path scope and module origin. Another rule can select cast syntax and consult a structural type predicate. Fix-producing rules return `ctx.edit:replace_expression(node, template, captures)` or `replace_type(...)`; comment-only policies need only the token/comment capability. Rule fixtures contain input, expected diagnostics, expected fix or refusal, and optional semantic preconditions.

Rule metadata consists of `id`, capabilities (`text`, `tokens`, `syntax`, `bindings`, `types`, `project`), scope, default severity, and selectors/visitor. Compile patterns once, bucket selectors by root kind/operator, and dispatch compatible visitors in one traversal. Rules cannot independently read or overwrite files; declared read-only inputs go through the session so the cache can track them. Explicitly configured local rule modules are code; don't auto-execute newly discovered repository files.

A diagnostic contains a stable rule/code, severity, message, primary byte range, related ranges/messages, optional fix groups, and source revision. Messages omit duplicated filename prefixes. Adapters render human output, JSON, or editor diagnostics from this one record. Keep warnings-as-errors a policy of the result, without throwing away the original severity.

## 6. Fixes are plans before they are writes

An `Edit` names a snapshot, range, and replacement. A `Fix` groups all edits that must succeed together, its applicability (`safe`, `suggested`, or `unsafe`), and required preconditions. “Safe” is a rule-specific claim, never inferred just because output parses or type-checks.

The pipeline:

1. Analyze a fixed input revision and collect diagnostics/fix proposals without mutation.
2. Validate captures and preconditions. Resolve identical edits by deduplication; refuse overlapping edits, conflicting same-position insertions, or incompatible fix groups. Report rule IDs and ranges. Independent edits can still be offered separately.
3. Instantiate typed templates. Preserve expression precedence and associativity, including explicit parentheses that force single-value adjustment. Type replacements target type syntax; list replacements own separators and empty-list behavior. Only placeholders in template code are substituted.
4. Apply accepted edits in one ascending segment assembly. Keep capture-origin and comment ownership information. Preserve comments or refuse; whole-line deletion is allowed only when the whole removed line belongs to that statement and owns no unrelated text.
5. Parse the candidate into a new revision. For type-dependent fixes, recheck affected modules and dependents against the candidate inputs. With pre-existing failures, offer a suggestion unless the rule's local safety proof is independently sufficient; never advertise whole-project semantic validation on an incomplete run.
6. If one fix enables another, rerun on the new revision. Use an explicit small pass cap and content-hash cycle detection; report remaining findings and oscillating rule IDs. No stale nodes, capture offsets, or type facts survive an edit.
7. Format the final candidate once, validate, and emit the diff. Re-run syntax/layout rules after formatting. If formatting preserves the checked syntax and literal values, carry semantic results forward with mapped ranges; otherwise recheck or refuse.
8. For apply mode, reverify all source digests before writing, stage outputs, and replace files safely. Stage multi-file fix groups together; journal and report interrupted partial writes. Filesystem rename is atomic per file, not magically across a project.

Default to previewing the exact proposed diff for semantic fixes. Keep formatting's existing in-place command behavior. The preview and apply paths use the same validated plan; parse/read/write failures always affect the aggregate exit status. No push or other network action is part of fixing source.

For transformations such as upgrade wrapper inlining, type correctness is only one precondition. Preserve argument evaluation count/order, varargs, multiple returns, optional-argument behavior, and lexical bindings. If the wrapper duplicates or drops an effectful expression, use a supported temporary-binding transform or refuse. The existing top-level alias map is insufficient evidence for all uses of that alias.

## 7. Formatting builds on syntax and type syntax

Replace `format/types.tl`'s carried type-position heuristics with parser-derived token roles. Use the same roles for function-type versus function-body classification, record/interface/enum declarations, generic brackets, `<const>/<close>`, and call/table layout. Retain the current emitter and established house style initially; changing structural analysis need not redesign line breaking or introduce a mandatory width gate.

**Ordinary formatting must work with unresolved imports and type errors.** It needs parsed type syntax, not successful inference. A user can request a semantic fix pipeline that supplies types, then format its result; inferred types should not cause ordinary formatting to change annotations or spelling implicitly.

Implement formatting as edits to layout gaps over the shared token/trivia tape. For literal/comment normalization already promised by style, make that policy explicit and preserve literal meaning and comment ownership. A lexer-boundary safety rule overrides tight-spacing preferences: token concatenation must not create comments, compound operators, different numerals, or long-bracket delimiters.

The output contract needs more than idempotence:

- output parses in the same dialect;
- semantic token sequence and normalized syntax, including parentheses and attributes, are preserved;
- string/numeric literal values, comment ownership/content policy, and shebang behavior are preserved;
- formatting twice is byte-identical;
- expected-layout fixtures verify actual indentation, since malformed indentation can itself be idempotent.

Reuse the validation parse as the final snapshot when the caller continues checking. A standalone formatter pays that validation cost; it should not pay a type check. Strengthen `_perf/bench/format_bench.tl`'s functional check, which currently establishes success and idempotence rather than full preservation.

## 8. Make the common paths fast, with sound invalidation

Existing work already amortizes compiler environment construction, pre-parses stdlib ASTs, runs selected files in-process, and reuses strict-compilation proofs. Preserve those gains. The missing optimization is shared work across consumers.

A probe of three dependent calls to the current `rewrite` API counted **six lexes and six parses**, excluding pattern compilation. That includes formatting after every rule. This is a work-count observation, not a latency benchmark or claimed speedup. Independent rules in the proposed runner share one input parse and one batched candidate parse; dependent rules still require a new revision per round. Syntax-only checking pays no type check.

| Work | Proposed cost/ownership |
| --- | --- |
| Read/hash, line starts, lex, parse | Once per changed source revision and dialect |
| Child/role/range index | One traversal, cached for that revision |
| Patterns | Once per rule version; candidate filtering by root kind/operator |
| Span queries | Constant-time indexed ranges, not repeated subtree walks during sort |
| Comment ownership | Index once; range queries instead of scanning all tokens for every hit |
| Edit application | Sort edits, then one output assembly; no full-string copy per hit |
| Type inference | Once per necessary module per semantic revision; reports borrowed only within that revision |
| Formatting | Once after the fix rounds, plus output validation |

The present engine's cache assumes source dependencies do not change mid-process and evicts only `env.loaded[root_name]`. A fix loop or editor invalidates that assumption: modules, globals, reports, and reverse dependents can remain stale. Replace implicit process-global caching with session-owned, revisioned state before adding a long-lived fixer.

Initially, a source change may conservatively rebuild the semantic environment for the affected session while retaining unchanged syntax snapshots. Do not partially evict a Teal environment until every related cache is understood. Then implement tested invalidation over the dependency graph: changed files plus reverse dependents, considering both old and new edges for deletions/renames; cyclic groups together; resolver, ambient/global declarations, compiler or feature changes invalidate the wider environment. Optimize to public-interface hashes only after their sufficiency is demonstrated.

Resolution in project mode is explicit: selected workspace/overlay sources precede embedded release snapshots; pinned dependencies and generated declarations are recorded. Cache keys include canonical path/root, source digest, dialect, checker and patch identity, resolver/include-path configuration, resolved dependencies and missing-module lookups, rule implementation/configuration, declared extra reads, and generated test-input identity. A citation-rule result depends on the cited source too, not just the document bytes.

Reuse `_make`'s graph and selection rather than creating another project scanner. A selected-root run checks the roots and needed dependency closure; a changed-impact run additionally checks reverse dependents. Report roots, inspected dependencies, excluded files, reused proofs, and incomplete analyses in the result. A strict-compile proof can satisfy the identical type-check obligation; it does not prove new custom rules.

Performance acceptance must cover cold process, warm same-process, unchanged project, one leaf edit, one public-signature edit, large generated declarations, many independent rules, many hits, and overlapping/dependent rules. Measure wall time, CPU, memory, bytes, and lex/parse/check counts. Extend the existing `_perf` harness with deterministic fixtures and preservation checks; use its A/A noise floor and compare discipline. Set numerical regression budgets from measured baselines in the formatter spike, not invented millisecond promises. A persistent daemon, parallel workers, serialized semantic graphs, and incremental parsing are later options only if these measurements justify them.

## 9. Fit the existing board; fill these gaps

| Existing item | State at review | Proposed treatment |
| --- | --- | --- |
| [HpoM_Gzj7 — AST/search/rewrite](https://github.com/cosmic-lua/work/blob/21075ee2b63160470a4d4f95b9766b6be67308c2/spec.md) | Open outcome; foundational children completed | Extend the shipped work with explicit syntax/edit contracts. |
| [R4YG_rV28 — declaration metadata mismatch](https://github.com/cosmic-lua/work/blob/a422d4446753af804f6210e27c046c04f11a7e7f/spec.md) | Open | Fix first alongside repeated-capture equality; remove the `requires` workaround when verified. |
| [ha5l_jXYz — formatter unary minus](https://github.com/cosmic-lua/work/blob/15171242d4831a847a2e7f8c3cc87ff8211fcbf9/spec.md) | Open | Land the narrow correction independently; add the general token-preservation contract. |
| [Pzk1_xFDD / PJEr_yoNh — formatter reconsideration and spike](https://github.com/cosmic-lua/work/blob/3e851cb91b1ed1b256032d544033c9712fb27d59/spec.md) | Open | Use as the experiment before structural migration. Audit real type-syntax ranges first; today's generic spans are not sufficient. |
| [8b2w_hfv3 — type-report research](https://github.com/cosmic-lua/work/blob/2603e40c11ad7f3d4327e88a80c505deef2d2e69/spec.md) | Completed | Preserve its findings; build on the reachable report. |
| [1ND6_Eum9 — `_teal_types`](https://github.com/cosmic-lua/work/blob/31de5cdf0abef9095bfb2be6cf6467a40cd9de24/spec.md) | Open | First extraction slice; follow with typed public analysis and explicit unknown semantics. The existing item deliberately stops at an internal helper. |
| [HlZW_zWbs — semantic rename research](https://github.com/cosmic-lua/work/blob/21bcac810170e95b4694873f1036e10ed104fd9c/spec.md) | Completed | Add lexical binding/resolution work; do not reopen type-ID-based rename. |
| [X4Uy_DCTW — require aliases](https://github.com/cosmic-lua/work/blob/89936348eee0d9ffff0cd1d65eeb0ed71ca3799a/spec.md) | Completed | Retain its narrow contract; safe semantic fixes require the binding service above it. |
| [Xp0T_KLQ0 — nil-flow premise correction](https://github.com/cosmic-lua/work/blob/80a5644060e681934c836f36cff27d7392a0fa15/spec.md) | Open | Respecify using sink/type/flow facts; never replace it with a smaller syntax census. |
| [BDFQ_7gGe — upgrade apply](https://github.com/cosmic-lua/work/blob/036636457dd86749c7daaa07fab0e4bc126094b7/spec.md) | Open | Make a consumer of safe edit plans; add grouping, evaluation, and binding preconditions before automatic inlining. |
| [MsXN_oznh — cast classification in lint](https://github.com/cosmic-lua/work/blob/188b49c037963ddaae8b34d69e725b4ca50d04fe/spec.md) | Completed | Migrate as an initial syntax rule, preserving the existing classification policy. |
| [6E8g_QpIb — stale citation lint cache](https://github.com/cosmic-lua/work/blob/a17e923a2082abdfb4716e359bd0aa15413ec35c/spec.md) | Open | Include non-source rule reads in dependency invalidation. |

The links, full refs, and SHA-pinned source take precedence over abbreviated display handles. No items were filed, re-ranked, claimed, or edited by this review.

### Implementation sequence and acceptance

1. **Correctness floor.** Fix the reproduced matcher, deletion, template, and lexical-boundary failures. Add overlapping-edit refusal and honest aggregate failure reporting. Acceptance: each reproduction becomes a regression test; unexpected syntax/type shapes refuse rather than silently match or mutate.
2. **Shared syntax snapshot.** Introduce owned source/ranges, child/role traversal, type-syntax spans, and owned patterns. Route parse consumers through it. Acceptance: subtree walks cannot reach siblings via backlinks; fixture roles/ranges cover the supported grammar; no-op emission preserves bytes.
3. **Teal analysis session.** Complete `_teal_types`, add checked-AST entry and typed public queries, session resolver and conservative invalidation. Acceptance: parse-once counters, cold/warm result equivalence, dependency-edit freshness, unknown reporting, generated-tail mapping, and structured-failure return queries.
4. **Edit plans and initial rules.** Migrate cast policy and the type-shape portion of discarded-error checking. Introduce batched templates and fix preview/apply. Acceptance: rule authoring needs no raw `tl`, no type-string parsing, no private AST casts, and no file-write code; negative/refusal fixtures pass.
5. **Bindings and semantic fixes.** Implement lexical declarations/references and import-origin checks; add configurable import boundaries, resolve discarded-error consumer exemptions by binding, and ship safe local rename as the proving fix. Acceptance: shadowing, closures, recursion, loop/repeat scope, reassignment refusal, and capture-avoiding rename; upgrade transformations wait for their own evaluation-preservation cases.
6. **Formatter structural migration.** Complete the existing type-position spike over the actual project file set, adjudicate token-role disagreements, measure overhead, and draft the required decision record. Then replace one heuristic category at a time. Acceptance: preservation, golden layout, idempotence, real regressions, and the measured performance budget.
7. **Changed-impact and harder type policies.** Add sound reverse-dependency invalidation and scoped machine-readable results. Implement the nil-flow census only after required inference facts are available and validated against its original method. Acceptance: changed API errors appear in callers; unchanged sessions reuse work; missing prerequisites never yield a clean verdict.

Proposed CLI additions should extend the existing vocabulary: `--check lint` and `--make lint` run registered rules; their explicit fix/preview options use this pipeline. `--find` and `--rewrite` become adapters over the same selection/edit core. `--fix` continues to mean formatting in place unless a separately documented command change is adopted. A project `--changed` selection reports its impact closure. Do not invent a new spelling for the same gate.

Stage public-record and checker changes through Cosmic's existing cold-build/release/pin sequence. A converged warm build alone does not prove bootstrap compatibility. The formatter's board item explicitly calls for measured spike evidence and a decision record before its core replacement; this note supplies the proposed architecture and acceptance work, not a claim that that experiment has completed.

## 10. The design tradeoff

The proposed decision is to share an owned source model and an optional Teal semantic session across checks, edits, and formatting. This gives ordinary rule authors a small, typed interface while concentrating parser/checker compatibility work in one place.

It accepts maintenance of a syntax schema, range instrumentation where needed, and a measured checker-copy cost. Continuing to patch independent token heuristics costs less initially but preserves the recurring ambiguity and duplicated work. Replacing Teal with another checker contradicts D5 and would duplicate inference. Requiring inference for formatting makes basic editing depend on project type health. A universal query DSL or full new incremental syntax framework adds complexity before a measured need.

Revisit the implementation choices if the parser cannot expose reliable ranges with a small maintained adapter, or the measured copy/index costs dominate realistic workloads. Preserve the contracts even if the implementation changes: exact source ownership, explicit unknowns, sound edit preconditions, and no duplicate analysis that a shared revision can reuse.
