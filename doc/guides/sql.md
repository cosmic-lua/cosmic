# SQL functions

Every SQLite handle cosmic opens, through [`cosmic.sqlite`] or [`cosmic.store`],
answers the SQL functions, table-valued functions, virtual tables and
collations listed here, with no extension to load, and no others.

Each entry starts with the name in backticks. An entry for SQLite's own
functions is short and links to SQLite's page for the rest. An entry for
what cosmic adds says what a caller needs.

```teal
local Sqlite = require("cosmic.sqlite")

local db = assert(Sqlite.memory())
local rows = assert(Sqlite.text_rows(db, [[
  SELECT sqrt(16), median(value), decimal_add('0.1', '0.2'), 'v1.2' REGEXP '^v[0-9.]+$'
  FROM generate_series(1, 4)]]))
print(table.concat(rows[1], " "))
```

```output
4.0 2.5 0.3 1
```

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

## introspection

- `dbstat`: a virtual table of every table's and index's pages and bytes,
  [as SQLite describes it](https://sqlite.org/dbstat.html).
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
print(table.concat(rows[1], " "))
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
  blob is read as a big-endian real, here and in the next two; any other X
  is read as a real, with NULL and text that is no number as 0.0.
- `ieee754(M, E)`: the real M × 2^E, truncated toward zero to the 53 bits
  a real holds: -0.0 for a negative M that underflows, ±Inf past the
  largest real. M and E are read as integers: a real is truncated, and
  held to the 64-bit range. M of -2^63 or less gives NULL.
- `ieee754_mantissa(X)`: the M of `ieee754(X)`.
- `ieee754_exponent(X)`: the E of `ieee754(X)`.
- `ieee754_to_blob(X)`: a number's 8 bytes as a real, big-endian.
- `ieee754_from_blob(B)`: the real 8 big-endian bytes hold; NULL for any
  other length, or for bytes that hold a NaN.
- `ieee754_to_int(X)`: a real's 8 bytes as one signed 64-bit integer; NULL
  unless X is a real.
- `ieee754_from_int(N)`: the real whose 8 bytes are the integer N's; NULL
  unless N is an integer, or for an N whose bytes hold a NaN.
- `ieee754_inc(X, N)`: the real whose 8 bytes, as an integer, are X's plus
  N, wrapping past the 64-bit range: for a small N, N representable steps
  away from zero, or toward it for a negative N; a step past the largest
  real or past zero gives Inf or NULL. X is read as `ieee754(X)` reads it.
- `tointeger(X)`: X as an integer when no value is lost, else NULL. A real
  converts when it is a whole number an integer holds; text when it is an
  integer literal, a sign and digits alone, that an integer holds; an
  8-byte blob as a little-endian integer.
- `toreal(X)`: X as a real, or NULL. An integer converts when a real holds
  it exactly. Text converts when SQLite reads all of it as a number, as
  `CAST` does, with no space before or after, rounded as `CAST` rounds it;
  it is NULL when it is an integer literal that a real does not hold
  exactly, overflows to an infinity, or is a nonzero number that
  underflows to zero. An 8-byte blob is read as a big-endian
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

[`cosmic.hash`]: ../../cosmic/hash.tl
[`cosmic.json`]: ../../cosmic/json.tl
[`cosmic.sqlite`]: ../../cosmic/sqlite.tl
[`cosmic.store`]: ../../cosmic/store.tl
