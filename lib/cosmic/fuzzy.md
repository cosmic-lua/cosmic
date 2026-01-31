# fuzzy

 Fuzzy string matching utilities.

## Types

### FuzzyModule

```teal
local record FuzzyModule
  levenshtein: function(a: string, b: string): integer
  find_similar: function(query: string, candidates: {string}, max_distance?: integer): {string}
end
```

## Functions

### levenshtein

```teal
function levenshtein(a: string, b: string): integer
```

 Compute Levenshtein distance between two strings.

**Parameters:**

- `a` (string) - First string
- `b` (string) - Second string

**Returns:**

- integer - Edit distance

### find_similar

```teal
function find_similar(query: string, candidates: {string}, max_distance?: integer): {string}
```

 Find similar strings from a list using Levenshtein distance.

**Parameters:**

- `query` (string) - The search query
- `candidates` ({string}) - List of strings to match against
- `max_distance` (integer) - Maximum edit distance to consider (default 3)

**Returns:**

- {string} - List of similar values, sorted by distance then alphabetically
