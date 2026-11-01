--- What the tests of [`cosmic.vector`] and its SQL functions share
--- (cosmic/vector_*_test.tl). Test support.

local Sqlite = require("cosmic.sqlite")

local record vector_fixture
end

--- `dims` numbers drawn from `next_number`.
--- @param next_number the source of numbers
--- @param dims how many to draw
--- @return the vector, unpacked
function vector_fixture.random_vector(next_number: function(): number, dims: integer): mut {number}
  local out: mut {number} = {}
  for _ = 1, dims do
    out[#out + 1] = next_number()
  end
  return out
end

--- What a query refuses with; fails the test where it runs.
--- @param db the database
--- @param sql the statement
--- @param values the statement's parameters
--- @return the refusal
function vector_fixture.refusal(db: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): string
  local rows, trouble = Sqlite.rows(db, sql, values)
  assert(rows == nil, sql)
  return trouble
end

return vector_fixture
