local Cell = require("cosmic.cell")

local function test_a_function_assigns_the_value_the_code_around_it_reads()
  local seen: Cell<integer> = { value = 0 }
  local function note(n: integer)
    seen.value = seen.value + n
  end
  note(2)
  note(3)
  assert(seen.value == 5)
end

local function test_a_cell_of_an_optional_starts_absent_and_is_filled_by_a_callback()
  local found: Cell<string?> = { value = nil }
  local function fill()
    found.value = "late"
  end
  assert(found.value == nil)
  fill()
  assert(found.value == "late")
end

local function test_two_functions_share_one_cell()
  local count: Cell<integer> = { value = 0 }
  local function up() count.value = count.value + 1 end
  local function down() count.value = count.value - 1 end
  up()
  up()
  down()
  assert(count.value == 1)
end
