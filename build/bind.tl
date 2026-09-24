--- What the build's SQL shares: a value to bind, of each kind it binds,
--- and a statement run once.

local Sqlite = require("cosmic.sqlite")

local record bind
end

--- `value`, bound as TEXT.
function bind.text(value: string): Sqlite.Value
  return { text = value }
end

--- `value`, bound as INTEGER.
function bind.integer(value: integer): Sqlite.Value
  return { integer = value }
end

--- Runs a statement that yields no rows, once, and readies it to run
--- again with other parameters.
function bind.once(statement: Sqlite.Statement): boolean, string
  local state, trouble = statement:step()
  if state == nil then
    return false, trouble
  end
  return statement:reset()
end

return bind
