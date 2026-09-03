## Evidence

Re-run 2026-09-03 against `origin/main` (`96afd807`):

    git show origin/main:docs/design/cast-sites.tsv | awk -F'\t' '$3=="sqlite row column read"{print $1":"$2}'
    cosmic/sqlite/extras_test.tl:48
    cosmic/sqlite/lifecycle_test.tl:12

2 sites, matching the outcome's Evidence section. The lines, with
their function bodies for context (`sed -n`):

    cosmic/sqlite/extras_test.tl:46-49
      local function count(db: sqlite.Database): number
        -- cast: a row column is `any`
        return check.must(db:query_one("SELECT COUNT(*) AS n FROM t")).n as number
      end

    cosmic/sqlite/lifecycle_test.tl:10-13
      local function count_rows(db: sqlite.Database): integer
        -- cast: a row column is `any`
        return check.must(db:query_one("SELECT COUNT(*) AS n FROM t")).n as integer
      end

`_build/casts_baseline.tl` rows this lowers:

    grep -F -e '"cosmic/sqlite/extras_test.tl"' -e '"cosmic/sqlite/lifecycle_test.tl"' _build/casts_baseline.tl
    ["cosmic/sqlite/extras_test.tl"] = 1,
    ["cosmic/sqlite/lifecycle_test.tl"] = 1,

Both files' entire cast count is this one site each — both drop to 0.

**The mechanism this class's "What closes it here" names already
exists and is already used elsewhere in this tree**: typed column
readers on a `Row` (`{string: any}`), implemented in
`cosmic/sqlite/column.tl` and re-exported on the `sqlite` module
(`cosmic/sqlite/init.tl:461-463`):

    column_text: function(row: {string: any}, column: string): string | nil, string
    column_number: function(row: {string: any}, column: string): number | nil, string
    column_integer: function(row: {string: any}, column: string): integer | nil, string

Each narrows with `is` internally (`column.tl:42`, `v is string`), so
reading through them costs no cast at all — not even inside the
accessor. `sqlite.column_integer(row, "n")` is the drop-in replacement
for `row.n as integer`; `sqlite.column_number(row, "n")` for
`row.n as number`. No new accessor needs to be written — these two
sites are exactly the case `column.tl`'s doc comment describes,
already being read but not yet used at these two call sites. (`docs/design/casts.md`'s "What closes it here" also names a `blob`
reader; none exists yet, but neither of these two sites needs one —
out of scope here.)

## Change

- **`cosmic/sqlite/lifecycle_test.tl:10-13`** — replace
  `check.must(db:query_one(...)).n as integer` with
  `check.must(sqlite.column_integer(check.must(db:query_one(...)), "n"))`,
  or, more readably, bind the row to a local first:

  ```teal
  local function count_rows(db: sqlite.Database): integer
    local row = check.must(db:query_one("SELECT COUNT(*) AS n FROM t"))
    return check.must(sqlite.column_integer(row, "n"))
  end
  ```

  Delete the `-- cast: a row column is \`any\`` comment with it.

- **`cosmic/sqlite/extras_test.tl:46-49`** — the same rewrite with
  `sqlite.column_number`, since this file's `count` is declared to
  return `number`:

  ```teal
  local function count(db: sqlite.Database): number
    local row = check.must(db:query_one("SELECT COUNT(*) AS n FROM t"))
    return check.must(sqlite.column_number(row, "n"))
  end
  ```

Confirm `sqlite` (the `require("cosmic.sqlite")` local) is already
imported in both files before writing the calls — both already call
other `sqlite.*` functions in the same file, so no new import is
needed.

Regenerate and reconcile:

    bin/cosmic --make run _build/casts.tl --baseline
    bin/cosmic --make run _build/cast_sites.tl --reconcile

Confirm the class is empty:

    git show HEAD:docs/design/cast-sites.tsv | awk -F'\t' '$3=="sqlite row column read"'   # (after committing) — empty

and delete the now-empty `### sqlite row column read` heading (through
its body, to the next `###` or `##`) from `docs/design/casts.md`,
following the precedent
`git show cf416d85 -- docs/design/casts.md | grep '^-###'` (that
commit deleted `### proved-value narrowing` in the same PR that
emptied its class).

Gate with `bin/cosmic --make ci`; `_build/cast_sites_test.tl` checks
the reconciled tsv against a fresh lexer walk and every remaining
`### ` heading.
