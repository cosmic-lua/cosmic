# fuzzy

 Fuzzy string matching utilities.
 Approximate (edit-distance) matching. For exact plain-text search
 see cosmic.string; for pattern-based matching see cosmic.re.

## Types

### Match

 One similar candidate: the value and the edit distance the search
 already computed for it (previously thrown away, which forced the
 one caller wanting a ranked score to re-run the DP itself).

```teal
local record Match
  value: string
  distance: integer
end
```

### Options

 Options for find_similar.

```teal
local record Options
  --  Maximum edit distance to consider (default 3).
  max_distance: integer
  --  Keep at most this many matches (default all).
  limit: integer
end
```

### FuzzyModule

```teal
local record FuzzyModule
  distance: function(a: string, b: string): integer
  find_similar: function(query: string, candidates: {string}, opts?: Options): {Match}
  --  DEPRECATED (D20 transition, #1002): alias of distance, kept while
  --  the pinned bootstrap's require_hints still calls it; deleted at
  --  the next pin advance alongside errno's aliases (#981).
  levenshtein: function(a: string, b: string): integer
end
```

## Functions

### distance

```teal
function distance(a: string, b: string): integer
```

 Compute the edit distance between two strings (Levenshtein).
 Uses a two-row algorithm with O(min(n,m)) memory and string.byte
 for fast character comparison.

**Parameters:**

- `a` (string) - First string
- `b` (string) - Second string

**Returns:**

- integer - Edit distance

### find_similar

```teal
function find_similar(query: string, candidates: {string}, opts?: Options): {Match}
```

 Find similar strings from a list by edit distance (case-insensitive,
 deduplicated on the lowercased form).

**Parameters:**

- `query` (string) - The search query
- `candidates` ({string}) - List of strings to match against
- `opts` (Options?) - max_distance (default 3), limit (default all)

**Returns:**

- {Match} - Matches with their distances, sorted by distance then value
