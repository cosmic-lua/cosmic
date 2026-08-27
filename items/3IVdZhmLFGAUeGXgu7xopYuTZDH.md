`_cli/returns.tl` is 24 lines under the hard 500-line cap: `wc -l <
_cli/returns.tl` is 476 after whilp/cosmic#1471 added the nil-return detector
beside the return-list parser (286 before, 393 at the PR's first head, 476
after the consuming-walk rework review asked for).

The file now carries two invariants that share one parser rather than one:
`check_fallible_returns` (a fallible return declares at most two slots) and
`nil_return_lines` (a declared slot 1 that cannot be nil must not return nil).
The seam between them is already visible in the file's own ordering — the
shared type-grammar half (`skip_balanced`, `parse_atom`, `parse_type`,
`parse_list`, `params_open`, about 200 lines) sits above two independent
consumers of it.

The split that follows the seam is a shared parser module with the two rules
beside it, which is what the next rule to need a declared return type will
want anyway. Note that moving the parser out means exporting `parse_list`,
`parse_type` and `params_open`, which are local today; that is the cost, and
it is why this is worth deciding rather than doing reflexively.
