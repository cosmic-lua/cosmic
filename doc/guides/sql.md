# SQL functions

Every SQLite handle cosmic opens, through [`cosmic.sqlite`] or [`cosmic.store`],
answers the SQL functions, table-valued functions, virtual tables and
collations listed here, with no extension to load, and no others.

Each entry starts with the name in backticks. An entry for SQLite's own
functions is short and links to SQLite's page for the rest. An entry for
what cosmic adds says what a caller needs.

A caller's own SQL may use every name here. A view or trigger that a
database file holds may not use some of them, so that reading a file does
not run what its author chose:

- `bytecode`, `tables_used`, `dbstat`, `csv`, cosmic's own functions but the [vector](#vector-search) ones,
  `base64`, `base85`, `sha1_query`, `sha3_query` and `sqlite_log` are
  direct-only: only the caller's own SQL uses them. A `csv` table may
  only be made in the `temp` schema, which no database file holds.
- The rest that SQLite does not mark innocuous, since cosmic turns
  SQLite's [`trusted_schema`](https://sqlite.org/pragma.html#pragma_trusted_schema)
  off on every handle: the percentile aggregates, FTS5's `bm25`,
  `highlight`, `snippet`, `fts5()` and `fts5_get_locale`, `MATCH` against
  an FTS5 table, `rtreecheck`, `rtreenode` and `rtreedepth`, and the
  `pragma_*`, `fts5vocab` and `carray` tables. A trigger may still write to an FTS5
  table or an R*Tree, and a view may still read an R*Tree.
  `PRAGMA trusted_schema = 1` on a [`cosmic.sqlite`] handle allows these
  again, for a file the caller trusts; a [`cosmic.store`] handle, which
  answers queries alone, refuses it.

```teal
local Sqlite = require("cosmic.sqlite")

local db = assert(Sqlite.memory())
local rows = assert(Sqlite.text_rows(db, [[
  SELECT sqrt(16), median(value), decimal_add('0.1', '0.2'), 'v1.2' REGEXP '^v[0-9.]+$'
  FROM generate_series(1, 4)]]))
print(table.concat(assert(rows[1]):texts(), " "))
```

```output
4.0 2.5 0.3 1
```

## quoting

Double quotes always name an identifier: cosmic builds SQLite with
`SQLITE_DQS=0`, so `"abc"` is a column or table, never a string, and
`WHERE name = "bob"` fails with "no such column". A string takes single
quotes, `'bob'`, with a quote inside it doubled (`'it''s'`). This holds
for [`cosmic.sqlite`], [`cosmic.store`] and `cosmic sql`.

## core functions

SQLite's [core functions](https://sqlite.org/lang_corefunc.html).

- `abs(X)`: the absolute value of a number.
- `changes()`: the rows the last INSERT, UPDATE or DELETE changed.
- `char(X, ...)`: the text of the given Unicode code points.
- `coalesce(X, Y, ...)`: the first argument that is not NULL.
- `concat(X, ...)`: its arguments as text, joined, NULLs skipped.
- `concat_ws(SEP, X, ...)`: as `concat`, with SEP between each.
- `format(FORMAT, ...)`: printf-style formatting.
- `glob(PATTERN, X)`: the `X GLOB PATTERN` operator, case-sensitive with `*` and `?`.
- `hex(X)`: the upper-case hexadecimal of a blob, or of text's UTF-8.
- `if(X, Y, Z)`: Y if X is true, else Z. `iif` is the same function.
- `ifnull(X, Y)`: X, or Y if X is NULL.
- `iif(X, Y, Z)`: Y if X is true, else Z.
- `instr(X, Y)`: the 1-based position of Y in X, or 0.
- `last_insert_rowid()`: the rowid of the last row inserted.
- `length(X)`: characters in text, bytes in a blob.
- `like(PATTERN, X, ESCAPE)`: the `X LIKE PATTERN` operator.
- `likelihood(X, P)`: X, with a hint to the planner that it is true with probability P.
- `likely(X)`: X, hinted as usually true.
- `lower(X)`: X in lower case, for ASCII letters.
- `ltrim(X, Y)`: X without the leading characters in Y (spaces by default).
- `max(X, Y, ...)`: the largest argument; with one argument, the aggregate below.
- `min(X, Y, ...)`: the smallest argument; with one argument, the aggregate below.
- `nullif(X, Y)`: NULL if X equals Y, else X.
- `octet_length(X)`: the bytes of X's text or blob.
- `printf(FORMAT, ...)`: the same as `format`.
- `quote(X)`: X as an SQL literal.
- `random()`: a pseudo-random 64-bit integer.
- `randomblob(N)`: N pseudo-random bytes.
- `replace(X, Y, Z)`: X with every Y replaced by Z.
- `round(X, N)`: X rounded to N digits after the point.
- `rtrim(X, Y)`: X without the trailing characters in Y.
- `sign(X)`: -1, 0 or 1 by X's sign, or NULL for a non-number.
- `sqlite_compileoption_get(N)`: the Nth compile-time option this SQLite was built with.
- `sqlite_compileoption_used(NAME)`: whether this SQLite was built with an option.
- `sqlite_log(CODE, MSG)`: sends MSG to SQLite's error log. cosmic sets no logger, so it has no effect.
- `sqlite_source_id()`: the check-in this SQLite was built from.
- `sqlite_version()`: this SQLite's version.
- `substr(X, Y, Z)`: Z characters of X from position Y.
- `substring(X, Y, Z)`: the same as `substr`.
- `subtype(X)`: the subtype a function attached to X.
- `total_changes()`: rows changed since the connection opened.
- `trim(X, Y)`: X without the leading and trailing characters in Y.
- `typeof(X)`: `null`, `integer`, `real`, `text` or `blob`.
- `unhex(X, Y)`: the blob the hexadecimal X spells, skipping characters in Y, or NULL.
- `unicode(X)`: the code point of X's first character.
- `unistr(X)`: X with its `\uXXXX`-style escapes decoded.
- `unistr_quote(X)`: as `quote`, writing control characters as a `unistr` call.
- `unlikely(X)`: X, hinted as usually false.
- `upper(X)`: X in upper case, for ASCII letters.
- `zeroblob(N)`: a blob of N zero bytes.
- `match(X, Y)`: the `X MATCH Y` operator, which a full-text table answers.
- `->`: the JSON operator `X -> PATH`, the JSON at PATH.
- `->>`: the JSON operator `X ->> PATH`, the SQL value at PATH.

## date and time

SQLite's [date and time functions](https://sqlite.org/lang_datefunc.html).

- `date(TIME, MODIFIER, ...)`: the date, `YYYY-MM-DD`.
- `time(TIME, MODIFIER, ...)`: the time, `HH:MM:SS`.
- `datetime(TIME, MODIFIER, ...)`: both, `YYYY-MM-DD HH:MM:SS`.
- `julianday(TIME, MODIFIER, ...)`: the Julian day number.
- `unixepoch(TIME, MODIFIER, ...)`: seconds since 1970-01-01 UTC.
- `strftime(FORMAT, TIME, MODIFIER, ...)`: the time in a format of its own.
- `timediff(A, B)`: the time from B to A, as `+YYYY-MM-DD HH:MM:SS.SSS`.
- `current_date`: today, as `date('now')`.
- `current_time`: now, as `time('now')`.
- `current_timestamp`: now, as `datetime('now')`.

## aggregate functions

SQLite's [aggregate functions](https://sqlite.org/lang_aggfunc.html). The
percentile aggregates have [their own section](#percentiles).

- `avg(X)`: the mean of the non-NULL values.
- `count(X)`: how many values are not NULL; `count(*)` counts rows.
- `group_concat(X, SEP)`: the values joined by SEP (a comma by default).
- `string_agg(X, SEP)`: the same as `group_concat`.
- `sum(X)`: the sum, or NULL for no values; an integer overflow fails.
- `total(X)`: the sum as a real, 0.0 for no values.

## window functions

SQLite's [window functions](https://sqlite.org/windowfunctions.html).

- `row_number()`: the row's number in its partition, from 1.
- `rank()`: the row's rank, with gaps after ties.
- `dense_rank()`: the row's rank, without gaps.
- `percent_rank()`: `(rank - 1) / (rows - 1)`.
- `cume_dist()`: the share of rows at or before this one.
- `ntile(N)`: which of N buckets the row falls in.
- `lag(X, OFFSET, DEFAULT)`: X from OFFSET rows before.
- `lead(X, OFFSET, DEFAULT)`: X from OFFSET rows after.
- `first_value(X)`: X at the frame's first row.
- `last_value(X)`: X at the frame's last row.
- `nth_value(X, N)`: X at the frame's Nth row.

## math

SQLite's [math functions](https://sqlite.org/lang_mathfunc.html). Each
answers NULL for an argument outside its domain, such as `sqrt(-1)`.

- `acos(X)`: arccosine, in radians.
- `acosh(X)`: inverse hyperbolic cosine.
- `asin(X)`: arcsine.
- `asinh(X)`: inverse hyperbolic sine.
- `atan(X)`: arctangent.
- `atan2(Y, X)`: the arctangent of Y/X, by quadrant.
- `atanh(X)`: inverse hyperbolic tangent.
- `ceil(X)`: the least integer not below X.
- `ceiling(X)`: the same as `ceil`.
- `cos(X)`: cosine.
- `cosh(X)`: hyperbolic cosine.
- `degrees(X)`: radians to degrees.
- `exp(X)`: e to the power X.
- `floor(X)`: the greatest integer not above X.
- `ln(X)`: natural logarithm.
- `log(B, X)`: the logarithm of X to base B; `log(X)` is base 10.
- `log10(X)`: base-10 logarithm.
- `log2(X)`: base-2 logarithm.
- `mod(X, Y)`: the remainder of X/Y, with X's sign.
- `pi()`: π.
- `pow(X, Y)`: X to the power Y.
- `power(X, Y)`: the same as `pow`.
- `radians(X)`: degrees to radians.
- `sin(X)`: sine.
- `sinh(X)`: hyperbolic sine.
- `sqrt(X)`: square root.
- `tan(X)`: tangent.
- `tanh(X)`: hyperbolic tangent.
- `trunc(X)`: X with its fraction dropped, toward zero.

## percentiles

SQLite's [percentile aggregates](https://sqlite.org/percentile.html).
Each is also a window function.

- `median(X)`: the middle value, interpolated between two.
- `percentile(X, P)`: the Pth percentile, P from 0 to 100, interpolated.
- `percentile_cont(X, P)`: the same with P from 0 to 1.
- `percentile_disc(X, P)`: the first value at or past fraction P, never interpolated.

## JSON

SQLite's [JSON functions](https://sqlite.org/json1.html). They read JSON5,
and in cosmic's SQLite `#` line comments too, as [`cosmic.json`] does
given `hash_comments`. A `jsonb_` function below does what its `json_`
namesake does, writing SQLite's binary JSON instead of text.

A JSON value passed through a scalar subquery arrives as text: wrap it in
`json()` to embed it as JSON.

- `json(X)`: X as minified JSON text.
- `json_array(X, ...)`: a JSON array of its arguments.
- `json_array_insert(J, PATH, X, ...)`: J with X inserted into the array at PATH.
- `json_array_length(J, PATH)`: the length of the array at PATH.
- `json_error_position(J)`: 0 for well-formed JSON, else where the first error is.
- `json_extract(J, PATH, ...)`: the values at the PATHs.
- `json_group_array(X)`: an aggregate: the values as a JSON array.
- `json_group_object(NAME, X)`: an aggregate: the pairs as a JSON object.
- `json_insert(J, PATH, X, ...)`: J with X at PATH, where nothing is.
- `json_object(NAME, X, ...)`: a JSON object of the pairs.
- `json_patch(J, PATCH)`: J with the RFC 7396 merge patch applied.
- `json_pretty(J, INDENT)`: J indented for reading.
- `json_quote(X)`: X as a JSON value.
- `json_remove(J, PATH, ...)`: J without what is at the PATHs.
- `json_replace(J, PATH, X, ...)`: J with X at PATH, where something is.
- `json_set(J, PATH, X, ...)`: J with X at PATH, either way.
- `json_type(J, PATH)`: the type of the value at PATH.
- `json_valid(J, FLAGS)`: whether J is well-formed, by the kinds FLAGS allows.
- `jsonb(X)`: X as binary JSON.
- `jsonb_array(X, ...)`: as `json_array`, in binary JSON.
- `jsonb_array_insert(J, PATH, X, ...)`: as `json_array_insert`, in binary JSON.
- `jsonb_extract(J, PATH, ...)`: as `json_extract`, in binary JSON.
- `jsonb_group_array(X)`: as `json_group_array`, in binary JSON.
- `jsonb_group_object(NAME, X)`: as `json_group_object`, in binary JSON.
- `jsonb_insert(J, PATH, X, ...)`: as `json_insert`, in binary JSON.
- `jsonb_object(NAME, X, ...)`: as `json_object`, in binary JSON.
- `jsonb_patch(J, PATCH)`: as `json_patch`, in binary JSON.
- `jsonb_remove(J, PATH, ...)`: as `json_remove`, in binary JSON.
- `jsonb_replace(J, PATH, X, ...)`: as `json_replace`, in binary JSON.
- `jsonb_set(J, PATH, X, ...)`: as `json_set`, in binary JSON.
- `json_each(J, PATH)`: a table of the members of the array or object at PATH.
- `json_tree(J, PATH)`: a table of every value under PATH, recursively.
- `jsonb_each(J, PATH)`: as `json_each`, its values in binary JSON.
- `jsonb_tree(J, PATH)`: as `json_tree`, its values in binary JSON.

## full-text search

SQLite's [FTS5](https://sqlite.org/fts5.html).

- `fts5`: the virtual table, `CREATE VIRTUAL TABLE t USING fts5(columns)`.
- `fts5vocab`: a virtual table of an FTS5 table's terms and counts.
- `bm25(T)`: a row's relevance to the query, lower is better.
- `highlight(T, COLUMN, OPEN, CLOSE)`: the column's text with each match wrapped.
- `snippet(T, COLUMN, OPEN, CLOSE, ELLIPSIS, TOKENS)`: a short excerpt around the matches.
- `fts5_source_id()`: the check-in FTS5 was built from.
- `fts5_locale(LOCALE, TEXT)`: TEXT tagged with LOCALE for a locale-aware tokenizer.
- `fts5_get_locale(T, COLUMN)`: the locale a column's value was tagged with.
- `fts5_insttoken(TEXT)`: a query term matched against token instances only.

An external-content table (`content='t'`) kept in step by triggers is
not updated by `INSERT OR REPLACE` on its content table: the delete
trigger does not fire for the replaced row unless `PRAGMA
recursive_triggers` is on, so the old row's postings stay: a `MATCH`
still finds the replaced text, and `INSERT INTO fts(fts, rank)
VALUES('integrity-check', 1)`, which compares the index with the
content table, reports the database malformed. Write the upsert as
`INSERT ... ON CONFLICT(id) DO UPDATE`, which runs the update trigger.

## R*Tree

SQLite's [R*Tree](https://sqlite.org/rtree.html): an index of boxes, from
one dimension (a range) to five, that answers which boxes overlap or lie
within another.

- `rtree`: the virtual table, `CREATE VIRTUAL TABLE t USING rtree(id,
  min0, max0, ...)`, with an integer id and a minimum and maximum for
  each dimension. Coordinates are kept as 32-bit reals, rounded outward,
  so a box is never smaller than the one given.
- `rtree_i32`: the same, with 32-bit integer coordinates: a real is
  truncated toward zero, so a box may shrink, and a value past the
  32-bit range is held to it.
- `rtreecheck(T)`: `ok`, or what is wrong with the R*Tree T's structure;
  `rtreecheck(S, T)` checks T in schema S. A T that is not an R*Tree
  fails the query. The check reads each node once: a damaged tree that
  leads it back to a node it has read, or to a node number below 1, is
  reported, not walked.
- `rtreenode(D, B)`: an R*Tree node of D dimensions, from its blob in the
  `_node` table, as text, its coordinates read as 32-bit reals even for
  `rtree_i32`; NULL for D outside 1 to 5 or a blob too short to be a
  node.
- `rtreedepth(B)`: the depth of an R*Tree, from its root node's blob; a
  B that is not a blob of at least 2 bytes fails the query.

## CSV

- `csv`: SQLite's [CSV virtual table](https://sqlite.org/csv.html), made
  only in the `temp` schema: `CREATE VIRTUAL TABLE temp.t USING
  csv(filename='rows.csv')`, or `data='...'` for the text itself. Its
  columns are `c0`, `c1`, ... and its first record is row 1, unless
  `header=yes` names the columns from its first line, or `schema=` names
  them, and `delimiter='X'` reads the one byte X between fields, a TSV's
  tab written as a tab between the quotes; a quote, CR, LF or anything
  but one byte is refused. Every cell is TEXT.
  [`cosmic.csv`]'s `load` copies a CSV into a table through it, naming
  and typing the columns, and `cosmic sql --from` a csv or tsv file.

  It reads as [`cosmic.csv`] reads, with a comma or the delimiter between
  fields: a quoted field holds the delimiter, quotes as `""` and line
  breaks; a record ends at LF
  or CRLF, and a lone CR is data; a UTF-8 byte order mark at the start is
  dropped. A blank line is a row of NULLs, an empty field `''`, and a
  field a record lacks NULL. The width is `columns=N`, or else the field
  count of the first record, which without `header=yes` or `schema=` is
  the first that is not a blank line; then a wider record fails the
  query, and with `columns=` or `schema=` its fields past the width are
  dropped. A quote inside an unquoted field, anything but the delimiter or
  a line end after a closing quote, a quote never closed, a NUL byte in a
  file's record, and a file that cannot be read fail the query, naming
  the line or record where the reader knows it; with `header=yes`, lines
  count from the one after the header.

## bound lists

- `carray(?N)`: a table of the elements of the list bound at parameter
  N, in its `value` column, in order: a [`cosmic.sqlite`] Value of
  `integers`, `numbers`, `texts` or `blobs`, as `{ integers = { 1, 2 } }`.
  A NaN in `numbers` reads as NULL. `x IN carray(?1)` tests membership in
  the list. Any other value at N gives no rows, and a list used as a
  value, compared, stored or returned, is NULL. The forms that take a
  count and a C type, which [SQLite describes](https://sqlite.org/carray.html),
  read only an array C binds: from SQL they give no rows, or fail for a
  type they do not name.

## introspection

- `dbstat`: a virtual table of every table's and index's pages and bytes,
  [as SQLite describes it](https://sqlite.org/dbstat.html).
- `bytecode(SQL)`: a table of the program SQLite compiles the first
  statement in SQL into, one row per instruction: `addr`, `opcode`, `p1`
  to `p5` and `subprog`, as [SQLite describes them](https://sqlite.org/bytecodevtab.html).
  The statement is compiled, not run, but a PRAGMA that changes a setting
  of the connection, such as `query_only` or `cache_size`, changes it as
  it compiles; one that acts when run, such as `user_version`, does not.
  A trigger's program, or a foreign key action's, follows the
  statement's, named in `subprog`, its `addr` from 0 again. `comment` is
  NULL and `nexec` and `ncycle` are 0 in cosmic's SQLite. SQL that holds
  no statement, or does not compile, fails the query, without SQLite's
  reason. Neither this table nor the next can be used in a view or a
  trigger stored in a database file; a TEMP one can use both.
- `tables_used(SQL)`: a table of the tables and indexes the program for
  the first statement in SQL opens, compiled as `bytecode` compiles it,
  one row for each open: `type` (`table` or `index`), `schema`, `name`,
  `wr` (1 where it writes) and `subprog`. An open the program decides as
  it runs is not listed, so neither is the table or index a `CREATE`
  makes, nor anything `VACUUM` touches; a virtual table has no row. The
  schema table is named `sqlite_master`, and a `WITHOUT ROWID` table's key
  is named as the table.
- `pragma_*`: each [PRAGMA](https://sqlite.org/pragma.html) that answers
  rows is a table-valued function of its own name, such as
  `pragma_table_info('t')`.

## cosmic's functions

cosmic's own functions. Each answers NULL for a NULL argument.

- `sha256(X)`: the 32-byte SHA-256 digest of a text or blob.
- `digest(A, X)`: the digest of X under the algorithm A names (a
  [`cosmic.hash`] `Algorithm`).
- `hmac(A, K, X)`: the HMAC of X under the key K, over the algorithm A.
- `deflate(X)`: the raw deflate of X, as `Compress.deflate("raw", X)` writes it.
- `inflate(X)`: a raw deflate stream decoded, to a blob.

## vector search

Functions for embeddings, under [pgvector](https://github.com/pgvector/pgvector)'s
names. A vector is a blob of little-endian 32-bit floats, what an
embedding API's base64 `float32` decodes to, or wherever one is read, a
text such as `'[1, 2.5, -3]'`, of 1 to 16000 finite numbers. Each answers
NULL for a NULL argument, and refuses vectors of different dimensions.
Unlike cosmic's other functions
they are innocuous, so a view, a generated column or an expression index
in a database file may use them.

- `vector(X)`: X as a blob of floats, so a text is parsed once. It
  refuses a blob that holds a NaN or an infinity; the distance functions
  do not look, to keep a scan fast, and answer NaN for such a vector.
- `vector_text(X)`: X as text, `[1,2.5,-3]`.
- `vector_dims(X)`: the number of dimensions.
- `l2_distance(A, B)`: the Euclidean distance.
- `l1_distance(A, B)`: the taxicab distance, the sum of the differences.
- `inner_product(A, B)`: the dot product; the cosine, for normalized vectors.
- `cosine_distance(A, B)`: one minus the cosine, from 0 to 2; NULL for a
  vector of zeros.
- `l2_normalize(X)`: X scaled to length 1.
- `subvector(X, S, N)`: N dimensions from the Sth, counted from 1: the
  head of a Matryoshka embedding. The range is clipped as SQL's
  `substr` clips it, and it is an error only to leave no dimension.
- `binary_quantize(X)`: a bit per dimension, set where it is above zero,
  the first in the high bit of the first byte.
- `hamming_distance(A, B)`: how many bits two bit vectors of the same
  length differ in. A bit vector is only its bytes, so one of 9 bits and
  one of 16 have the same length and compare.
- `jaccard_distance(A, B)`: one minus the share of set bits two bit
  vectors of the same length have in common.
- `vector_block(ID, X [, STORAGE])`: an aggregate: the rows of its group
  packed into one blob, a [block](#packed-rows), or NULL for no rows. ID
  is an integer. X is a vector, which must be finite, and as wide as the
  group's first. STORAGE is `'f32'` (the default), `'f16'` or `'int8'`, how
  the block holds the numbers, as [`cosmic.vector`]'s corpus does; for
  `'f16'` X holds numbers under 65520 in magnitude. A row whose X is NULL
  is left out.
- `vector_block_search(BLOCK, QUERY, K [, METRIC])`: a table-valued
  function: the K rows of BLOCK nearest to QUERY, as `id` and `distance`,
  nearest first, equal distances in order of the lower id. METRIC is
  `'inner_product'` (the default), `'cosine'` or `'l2'`. The distance is
  lower for nearer rows: the negative inner product (pgvector's `<#>`,
  so `ORDER BY distance` ranks the rows `inner_product(A, B) DESC`
  would), `cosine_distance` (NULL for a vector of zeros, which comes
  last) or `l2_distance`. The scores are those of a
  [`cosmic.vector`] corpus of the block's storage, so they agree with a
  corpus's to the bit (a cosine that rounds just past 1 is clamped, as
  `cosine_distance` clamps it, and rows at the same distance then rank by
  id) and with the per-row functions to the rounding of a float sum; an
  `'int8'` block's are those of the quantized numbers. A NULL BLOCK,
  QUERY or K answers no rows. QUERY must have the block's dimensions and
  hold finite numbers, K is an integer from 1, and a block is checked
  before any of it is read ([layout](#packed-rows)). The arguments are
  hidden columns named `block`, `query`, `k` and `metric`, so a table that
  joins it and has a column of one of those names is qualified
  (`blocks.block`). `k` and `metric` read back what was given (`metric`
  the default's name when it was left out); `block` and `query` read NULL.
  A NULL METRIC is an error. List the tables that supply the arguments
  before the function: a comma join does, and a `CROSS JOIN` the other way
  round has no plan for the block ("no query solution") and answers no rows
  for a metric.

A search is an `ORDER BY` over every row a `WHERE` keeps, so a filter
never loses a match, and a hybrid search blends it with FTS5's ranking.
Write `NULLS LAST` after an `ORDER BY` over `cosine_distance`: SQLite
sorts NULL before every number, so without it the rows of zeros, which
have no direction and so no distance, would rank first.
Reading the rows costs more than the arithmetic: a 768-dimension vector
is 3 KB, about a whole 4096-byte page, so a scan reads a page per row,
and reading any other column of that row, such as bits stored beside
the floats, costs the same. Bit vectors in a table of their own pack
about 40 rows to a page, which a first pass reads without touching the
floats.
`Example.vector_search` in [`cosmic/sqlite_example.tl`] runs one end to
end. The [semantic search guide](semantic-search.md) builds a whole
corpus: embeddings from an API, chunking, hybrid search, an in-memory
corpus and IVF.

```text
CREATE TABLE chunks (id INTEGER PRIMARY KEY, body TEXT, tenant TEXT, embedding BLOB);
INSERT INTO chunks VALUES (1, 'cats purr', 'a', l2_normalize('[0.1, 0.9, 0.2]'));

SELECT id, body FROM chunks WHERE tenant = 'a'
ORDER BY cosine_distance(embedding, '[0.2, 0.8, 0.1]') NULLS LAST LIMIT 10;

-- A bit vector per row, 32 times smaller, then the floats to rerank.
CREATE TABLE chunk_bits (id INTEGER PRIMARY KEY, bits BLOB);
INSERT INTO chunk_bits SELECT id, binary_quantize(embedding) FROM chunks;

SELECT c.id FROM (
  SELECT id FROM chunk_bits ORDER BY hamming_distance(bits, binary_quantize(?1)) LIMIT 100
) b JOIN chunks c ON c.id = b.id
ORDER BY cosine_distance(c.embedding, ?1) NULLS LAST LIMIT 10;
```

### packed rows

A table with a row per vector reads a page per row (above), however few
bytes the scan wants. A block holds many vectors in one row, so a scan
reads one row for a few dozen and the arithmetic is what remains.
`vector_block` packs the rows of a group, `vector_block_search` joins the
blocks and answers each one's nearest rows, and an `ORDER BY` with a
`LIMIT` over them is the global nearest. A `WHERE` on the table of
blocks drops whole blocks, so filter on columns the block table keeps
(a tenant, a range of ids) and group by them.

```text
CREATE TABLE blocks AS
  SELECT tenant, (seq - 1) / 32 AS n, min(id) AS lo, max(id) AS hi,
         vector_block(id, embedding, 'int8') AS vectors
  FROM chunks GROUP BY tenant, n;

SELECT h.id, h.distance
FROM blocks, vector_block_search(blocks.vectors, ?1, 10, 'cosine') AS h
WHERE blocks.tenant = 'a'
ORDER BY h.distance NULLS LAST, h.id LIMIT 10;
```

A block is derived data: rebuild the blocks a change touched, or search
the rows not yet packed with the per-row functions beside them. The
[semantic search guide](semantic-search.md#packed-rows) has the numbers, the
sizes to pack and an example that does both. [`Vector.load_blocks`]
fills a corpus from the blocks without reading the vectors one by one.

A block is the following, little-endian, each section starting at a
multiple of 8 bytes, and nothing after it, so its length is a function
of its header:

- The bytes `VBLK`, a byte for the storage (0 `f32`, 1 `f16`, 2 `int8`), three
  zero bytes, the dimensions and the count of vectors, each a 32-bit
  integer;
- the ids, a 64-bit integer each;
- the inverse of each vector's length, a 32-bit float each (0 for a
  vector of zeros), which `cosine` reads;
- for `int8` only, each vector's scale, sum of its squared codes and sum
  of its codes, 12 bytes each;
- the vectors back to back: `dims` numbers each, 32-bit floats, 16-bit
  floats or signed bytes.

A function that is given anything else, a blob of another length than
its header's, a header it does not write, or a length or scale out of
range (not a number, negative, or for a scale over what makes a code
a finite number), refuses it by name and reads nothing. A search does not
read a vector's own numbers or an int8 vector's sums again, as the
aggregate wrote them: a block made by hand that lies about them ranks its
rows by whatever the kernels make of the lie, which may differ between
processors, and [`Vector.load_blocks`] refuses such a block (numbers that
are not finite, an int8 sum that is not its codes').

A statement scanning blocks ends with the error `interrupted` when a
[`Signal.guard`] of [`cosmic.signal`] has caught SIGINT or SIGTERM,
within a few hundred vectors of work.

## SQLite's extensions

Extensions from SQLite's source tree (`ext/misc/`), compiled into the
core.

```teal
local Sqlite = require("cosmic.sqlite")

local db = assert(Sqlite.memory())
local rows = assert(Sqlite.text_rows(db, [[
  SELECT group_concat(value, ','), sha1('abc'), uuid_str(uuid_blob('{A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11}')),
    decimal_mul('1.10', '3')
  FROM generate_series(0, 20, 10)]]))
print(table.concat(assert(rows[1]):texts(), " "))
```

```output
0,10,20 a9993e364706816aba3e25717850c26c9cd0d89d a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11 3.3
```

- `generate_series(START, STOP, STEP)`: a table of the integers from START
  to STOP by STEP (1 by default), in its `value` column.
- `regexp(PATTERN, X)`: the `X REGEXP PATTERN` operator. The pattern
  language is a small one of SQLite's own: `.`, `*`, `+`, `?`, `{n,m}`,
  `|`, `()`, `[...]`, `^`, `$`, `\d`, `\w`, `\s` and `\b`. A malformed
  pattern fails the statement.
- `regexpi(PATTERN, X)`: as `regexp`, ignoring ASCII case.
- `decimal(X)`: X as exact decimal text. A real is expanded in full.
- `decimal_exp(X)`: X in exponential notation, as `+1.2345e+03`.
- `decimal_add(X, Y)`: the exact sum of two decimals.
- `decimal_sub(X, Y)`: the exact difference.
- `decimal_mul(X, Y)`: the exact product.
- `decimal_cmp(X, Y)`: -1, 0 or 1 as X is below, equal to or above Y.
- `decimal_sum(X)`: an aggregate: the exact sum.
- `decimal_pow2(N)`: 2 to the power N, exactly, in exponential notation; NULL unless N is an integer.
- `ieee754(X)`: a real as the text `ieee754(M,E)`, where X is exactly
  M × 2^E: M is made odd while E stays below zero, and zero is
  `ieee754(0,-1075)`. -0.0 and the infinities get pairs of their own that
  `ieee754(M, E)` reads back; the pair for a NaN means nothing. An 8-byte
  blob is read as a big-endian real, here and in `ieee754_mantissa` and
  `ieee754_exponent`; any other X is read as SQLite reads a value as a
  real: NULL as 0.0, text as the number it begins with, if any, else 0.0.
- `ieee754(M, E)`: the real M × 2^E, truncated toward zero to the 53 bits
  a real holds: -0.0 for a negative M that underflows, ±Inf past the
  largest real. M and E are read as integers: a real is truncated, and
  held to the 64-bit range. M of -2^63 or less gives NULL.
- `ieee754_mantissa(X)`: the M of `ieee754(X)`.
- `ieee754_exponent(X)`: the E of `ieee754(X)`.
- `ieee754_to_blob(X)`: a number's 8 bytes as a real, big-endian; NULL for
  anything that is not a number.
- `ieee754_from_blob(B)`: the real 8 big-endian bytes hold; NULL for any
  other length, or for bytes that hold a NaN.
- `ieee754_to_int(X)`: a real's 8 bytes as one signed 64-bit integer; NULL
  unless X is a real.
- `ieee754_from_int(N)`: the real whose 8 bytes are the integer N's; NULL
  unless N is an integer, or for an N whose bytes hold a NaN.
- `ieee754_inc(X, N)`: the real whose 8 bytes, as a 64-bit integer, are
  X's plus N, wrapping around the 64-bit range: for a small N, N
  representable steps away from zero, or toward it for a negative N.
  Bytes that hold a NaN give NULL. X is read as SQLite reads a value as a
  real, a blob as text.
- `tointeger(X)`: X as an integer when no value is lost, else NULL. A real
  converts when it is a whole number an integer holds; text when it is an
  integer literal, a sign and digits alone, that an integer holds; an
  8-byte blob as a little-endian integer.
- `toreal(X)`: X as a real, or NULL. An integer converts when a real holds
  it exactly. Text converts when SQLite reads all of it as a number, as
  `CAST` does, with no space before or after, rounded as `CAST` rounds it;
  it is NULL when it is an integer literal in the 64-bit range that a real
  does not hold exactly, overflows to an infinity, or is a nonzero number
  that underflows to zero. An 8-byte blob is read as a big-endian
  real.
- `uuid()`: a random version 4 UUID, as text.
- `uuid_str(X)`: a UUID in its canonical text, from a 16-byte blob or text, or NULL.
- `uuid_blob(X)`: a UUID as a 16-byte blob, from text or a blob, or NULL.
- `sha1(X)`: the SHA-1 of a text or blob, as lower-case hexadecimal.
- `sha1b(X)`: the same, as a 20-byte blob.
- `sha1_query(SQL)`: the SHA-1 of every statement in SQL: its text and the rows it yields.
- `sha3(X, SIZE)`: the SHA-3 of a text or blob, as a blob, SIZE 224, 256 (the default), 384 or 512 bits.
- `sha3_agg(X, SIZE)`: an aggregate: the SHA-3 of the values in order.
- `sha3_query(SQL, SIZE)`: the SHA-3 of every statement in SQL: its text and the rows it yields.
- `base64(X)`: a blob as base64 text, in lines; or such text as a blob.
- `base85(X)`: a blob as SQLite's base85 text, in lines; or such text as a blob.
- `is_base85(X)`: whether the text is base85 that `base85` reads.
- `compress(X)`: X's length, in a prefix of `compress`'s own, then X's zlib stream.
- `uncompress(X)`: what `compress` wrote, decoded; NULL for a blob it
  cannot read, or whose length claims more than its stream holds.

## collations

SQLite's [built-in collations](https://sqlite.org/datatype3.html#collation),
and `decimal` and `uint` from [SQLite's extensions](#sqlites-extensions).

- `BINARY`: compares bytes; the default.
- `NOCASE`: ignores the case of ASCII letters.
- `RTRIM`: ignores trailing spaces.
- `decimal`: orders text by its decimal value, so `'1.0' = '1' COLLATE decimal`.
- `uint`: orders text with its runs of digits compared as numbers, so
  `file2` sorts before `file10` and `'x00123y' = 'x123y' COLLATE uint`.
  Everything else compares as bytes, signs and decimal points too: `'-5'`
  differs from `'5'`, and `'a1.05' = 'a1.5' COLLATE uint`.

[`cosmic.csv`]: ../../cosmic/csv.tl
[`cosmic.hash`]: ../../cosmic/hash.tl
[`cosmic.json`]: ../../cosmic/json.tl
[`cosmic.signal`]: ../../cosmic/signal.tl
[`cosmic.sqlite`]: ../../cosmic/sqlite.tl
[`cosmic.store`]: ../../cosmic/store.tl
[`cosmic.vector`]: ../../cosmic/vector.tl
[`cosmic/sqlite_example.tl`]: ../../cosmic/sqlite_example.tl
[`Signal.guard`]: ../../cosmic/signal.tl
[`Vector.load_blocks`]: ../../cosmic/vector.tl
