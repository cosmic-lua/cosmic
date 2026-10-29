--- One mutable value that a function and the code around it share. A
--- function may read a local of the code around it but not assign it
--- (`captured_assigned`), so a counter or a result a callback fills in
--- lives in a [`Cell`] both hold: the function assigns `cell.value`, the
--- code around it reads it. Declare it with its type,
--- `local seen: Cell<integer> = { value = 0 }`; a literal alone is a map
--- of strings, whose `.value` is refused (`map_field`). A value that
--- starts out absent is a `Cell<T?>`, `{ value = nil }`.
---
--- Hold one only for that: a value no function assigns is a plain local.
local record Cell<T>
  --- The value both the function and the code around it read and assign.
  mut value: T
end

-- TODO: replace Cells (every [`Cell`] use) with plain locals once captured_assigned lets a closure assign a captured local it never narrows.

return Cell
