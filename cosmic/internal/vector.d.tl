-- Packed vectors and an in-memory corpus at the Lua boundary, as the core
-- provides them. A vector is a string of little-endian 32-bit floats.

local record vector
  -- n vectors of one dimension count in one buffer, each with an id.
  record Corpus
    userdata

    -- Raises on a vector of another length or a number that is not finite.
    add: function(Corpus, id: integer, v: string)
    count: function(Corpus): integer
    -- k centroids by spherical k-means (k-means++ seeding from `seed`).
    -- Raises on k outside 1 to count, on iterations under 1, and on a
    -- corpus whose every vector is zero. A zero vector is no cluster's.
    -- Once a signal guard has caught a signal it answers nil, "interrupted"
    -- instead, leaving the corpus as it was and the signal untaken.
    kmeans: function(Corpus, k: integer, seed: integer, iterations: integer): {string}?, string?
    -- The ids and scores of the k best, best first. `metric` is
    -- "inner_product", "cosine" or "l2" (the score is the distance);
    -- `candidates` and `allow` may be nil. Raises on k < 1, a vector of
    -- another length, or another metric. Once a signal guard has caught a
    -- signal it answers nil, "interrupted" instead (the corpus as it was,
    -- the signal untaken). The corpus's buffers are Lua userdata, so any
    -- call here may raise "not enough memory", leaving it as it was.
    search: function(Corpus, query: string, k: integer, metric: string,
      candidates: integer?, allow: {integer}?): {integer}?, {number} | string
  end

  -- `storage` is "f32" (the default), "f16" or "int8". Raises on a
  -- dimension count outside 1 to 16000 and on another storage. An f16
  -- corpus's `add` also raises on a number of 65520 or more in magnitude.
  corpus: function(dims: integer, storage: string?): Corpus
  -- Raises on an entry that is not a finite number.
  pack: function(numbers: {number}): string
  -- Raises on a string that is not a whole number of floats.
  unpack: function(v: string): {number}
  -- The vector `[0.1, 0.2]` spells, or nil and why not.
  from_json: function(text: string): string?, string
  -- The 1-based indexes of the n centroids nearest v by inner product,
  -- ties to the lower. Raises on no centroids, n under 1, a centroid
  -- that is not a string of the query's length, and a query or centroid
  -- holding a number that is not finite.
  nearest: function(centroids: {string}, v: string, n: integer): {integer}
  -- The vector scaled to length 1; all zeros stays all zeros.
  normalize: function(v: string): string
end

return vector
